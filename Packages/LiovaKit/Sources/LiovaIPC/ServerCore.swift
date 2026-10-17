import Darwin
import Dispatch
import Foundation
import LiovaPluginKit

/// The server's state machine. Every mutable property is only touched on `queue`, which is
/// what makes the `@unchecked Sendable` sound: public entry points hop onto the queue with
/// `sync`, and dispatch sources deliver their events on it.
final class ServerCore: @unchecked Sendable {
    let queue = DispatchQueue(label: "app.liova.ipc.server", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let socketPath: String
    private let configuration: IPCServer.Configuration
    private let handler: any IPCRequestHandler

    private var running = false
    private var listenSource: (any DispatchSourceRead)?
    private var listenSuspended = false
    private var boundIdentity: UnixSocket.FileIdentity?
    private var connections: [UInt64: ServerConnection] = [:]
    private var nextConnectionID: UInt64 = 1

    init(socketPath: String, configuration: IPCServer.Configuration, handler: any IPCRequestHandler) {
        self.socketPath = socketPath
        self.configuration = configuration
        self.handler = handler
        queue.setSpecific(key: queueKey, value: true)
    }

    private func onQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) == true ? body() : queue.sync(execute: body)
    }

    var isRunning: Bool {
        onQueue { running }
    }

    var connectionCount: Int {
        onQueue { connections.count }
    }

    func start() throws(IPCServerError) {
        try onQueue { () -> Result<Void, IPCServerError> in
            Result { () throws(IPCServerError) in try startOnQueue() }
        }.get()
    }

    func stop() {
        onQueue { stopOnQueue() }
    }

    // MARK: Startup

    private func startOnQueue() throws(IPCServerError) {
        guard !running else { throw .alreadyStarted }
        let address = try socketAddress()
        try SocketDirectory.prepare((socketPath as NSString).deletingLastPathComponent)
        try removeStaleSocket(at: socketPath, address: address)

        let fd: Int32
        do {
            fd = try UnixSocket.makeStreamSocket(nonBlocking: true)
        } catch {
            throw .system(error)
        }
        guard UnixSocket.bind(fd, to: address) == 0 else {
            let code = errno
            close(fd)
            if code == EADDRINUSE {
                throw .alreadyRunning(socketPath: socketPath)
            }
            throw .system(SystemCallError("bind", code: code))
        }
        // The directory is already 0700, so nobody else can reach the socket between bind
        // and chmod.
        let identity = UnixSocket.lstatIdentity(socketPath)?.identity
        let setupError: SystemCallError? = if chmod(socketPath, 0o600) != 0 {
            SystemCallError("chmod")
        } else if listen(fd, configuration.listenBacklog) != 0 {
            SystemCallError("listen")
        } else {
            nil
        }
        if let setupError {
            close(fd)
            unlinkIfOurs(identity)
            throw .system(setupError)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPendingConnections(listenFD: fd) }
        source.setCancelHandler { close(fd) }
        source.activate()

        listenSource = source
        listenSuspended = false
        boundIdentity = identity
        running = true
    }

    private func socketAddress() throws(IPCServerError) -> sockaddr_un {
        do {
            return try UnixSocket.address(for: socketPath)
        } catch {
            switch error {
            case .pathTooLong:
                throw .socketPathTooLong(socketPath: socketPath, maxBytes: UnixSocket.maxPathBytes)
            case .emptyPath:
                throw .insecureDirectory(path: socketPath, reason: "the socket path is empty")
            }
        }
    }

    /// If a socket file is already there, find out whether anybody is home, and remove it
    /// only when nobody is.
    private func removeStaleSocket(at path: String, address: sockaddr_un) throws(IPCServerError) {
        guard let existing = UnixSocket.lstatIdentity(path) else {
            let code = errno
            if code == ENOENT {
                return
            }
            throw .system(SystemCallError("lstat", code: code))
        }
        guard UnixSocket.isSocket(existing.mode) else { throw .pathOccupied(socketPath: path) }
        guard try !isAnswering(address) else { throw .alreadyRunning(socketPath: path) }

        // Nobody is listening: a previous run crashed or was killed. Reclaim the path, but
        // only if it is still the same file we probed.
        guard let current = UnixSocket.lstatIdentity(path), current.identity == existing.identity else {
            return
        }
        if unlink(path) != 0, errno != ENOENT {
            throw .system(SystemCallError("unlink"))
        }
    }

    /// Probes a socket path with a non-blocking connect.
    ///
    /// A Darwin Unix socket refuses connections both when nobody listens and, briefly, when a
    /// live server's backlog is full, so a refusal is retried a few times before the socket is
    /// declared stale. A connect that would block also means somebody is there.
    private func isAnswering(_ address: sockaddr_un) throws(IPCServerError) -> Bool {
        for attempt in 0 ..< 3 {
            if attempt > 0 {
                usleep(20000)
            }
            let probe: Int32
            do {
                probe = try UnixSocket.makeStreamSocket(nonBlocking: true)
            } catch {
                throw .system(error)
            }
            let result = UnixSocket.connect(probe, to: address)
            let code = errno
            close(probe)
            if result == 0 {
                return true
            }
            switch code {
            case EINPROGRESS, EAGAIN, EINTR:
                return true
            case ECONNREFUSED:
                continue
            case ENOENT:
                return false
            default:
                throw .system(SystemCallError("connect", code: code))
            }
        }
        return false
    }

    // MARK: Shutdown

    private func stopOnQueue() {
        guard running else { return }
        running = false
        if let listenSource {
            // A suspended source never runs its cancel handler, which would leak the fd.
            if listenSuspended {
                listenSource.resume()
            }
            listenSource.cancel()
        }
        listenSource = nil
        listenSuspended = false
        for connection in Array(connections.values) {
            connection.close()
        }
        connections.removeAll()
        unlinkIfOurs(boundIdentity)
        boundIdentity = nil
    }

    /// Unlinks the socket path only if it is still the file we bound, so stopping never
    /// removes a socket that a newer instance has since put there.
    private func unlinkIfOurs(_ identity: UnixSocket.FileIdentity?) {
        guard let identity, let current = UnixSocket.lstatIdentity(socketPath), current.identity == identity else {
            return
        }
        unlink(socketPath)
    }

    // MARK: Accepting

    private func acceptPendingConnections(listenFD: Int32) {
        guard running else { return }
        while running {
            let fd = accept(listenFD, nil, nil)
            if fd >= 0 {
                admit(fd)
                continue
            }
            switch errno {
            case EINTR, ECONNABORTED:
                continue
            case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                // The pending connection stays queued and the source would fire again
                // immediately; back off instead of spinning.
                pauseAccepting(for: 1)
                return
            default:
                return // EAGAIN: drained.
            }
        }
    }

    private func admit(_ fd: Int32) {
        do {
            try UnixSocket.configure(fd, nonBlocking: true)
        } catch {
            close(fd)
            return
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
            reject(fd, .failure(.forbidden, "Connections from other users are not allowed."))
            return
        }
        guard connections.count < configuration.maxConnections else {
            reject(fd, .failure(.busy, "Too many open connections (\(configuration.maxConnections)). Try again."))
            return
        }
        let id = nextConnectionID
        nextConnectionID += 1
        let connection = ServerConnection(
            fd: fd,
            client: IPCClientInfo(connectionID: id, pid: UnixSocket.peerPID(fd), uid: uid),
            configuration: configuration,
            handler: handler,
            queue: queue
        ) { [weak self] closedID in
            self?.connections[closedID] = nil
        }
        connections[id] = connection
        connection.start()
    }

    /// Best-effort explanation, then hang up. Never blocks: the socket is non-blocking, and a
    /// fresh connection's send buffer always has room for one short line.
    private func reject(_ fd: Int32, _ response: IPCResponse) {
        if let line = try? LiovaWire.encodeLine(response) {
            _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
        close(fd)
    }

    private func pauseAccepting(for seconds: TimeInterval) {
        guard let source = listenSource, !listenSuspended else { return }
        source.suspend()
        listenSuspended = true
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, running, listenSuspended, listenSource === source else { return }
            listenSuspended = false
            source.resume()
        }
    }
}
