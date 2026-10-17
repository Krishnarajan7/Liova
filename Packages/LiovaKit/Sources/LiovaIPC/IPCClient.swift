import Darwin
import Foundation
import LiovaPluginKit

/// Why a client request didn't get a response.
public enum IPCClientError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Nothing is listening at the socket path: Liova isn't running (or uses another path).
    case serverNotRunning(socketPath: String)
    /// The socket exists but this user may not connect to it.
    case permissionDenied(socketPath: String)
    case socketPathTooLong(socketPath: String, maxBytes: Int)
    /// No complete response arrived in time.
    case timedOut(after: TimeInterval)
    /// The server hung up before sending a complete response.
    case connectionClosed
    /// The response line exceeded ``IPCClient/maxResponseBytes``.
    case responseTooLarge
    /// The server sent something that isn't a valid response.
    case invalidResponse(String)
    /// The request couldn't be encoded (e.g. a NaN progress value).
    case encodingFailed(String)
    case system(SystemCallError)

    public var description: String {
        switch self {
        case let .serverNotRunning(path):
            "Liova isn't running. Open Liova.app and try again. (Nothing is listening on \(path); "
                + "set \(IPCPaths.environmentKey) if Liova uses a different socket.)"
        case let .permissionDenied(path):
            "Permission denied connecting to \(path). The socket belongs to another user."
        case let .socketPathTooLong(path, max):
            "Socket path is \(path.utf8.count) bytes, but Unix sockets allow at most \(max): \(path)"
        case let .timedOut(seconds):
            "Liova didn't respond within \(seconds.formatted()) s."
        case .connectionClosed:
            "Liova closed the connection without responding."
        case .responseTooLarge:
            "Liova's response was too large."
        case let .invalidResponse(detail):
            "Liova sent an invalid response: \(detail)"
        case let .encodingFailed(detail):
            "Couldn't encode the request: \(detail)"
        case let .system(error):
            error.description
        }
    }
}

/// A blocking client for the tier 1 socket, used by the `liova` CLI and tests.
///
/// ```swift
/// let client = IPCClient()
/// let response = try client.send(.start(Activity(id: "build", source: "ci", title: "Building")))
/// ```
///
/// Each ``send(_:)-swift.method`` opens a fresh connection. Use ``connect()`` to send several
/// requests over one connection. Never call it from the main thread of an app: it blocks.
public struct IPCClient: Sendable {
    /// Responses larger than this are rejected (a `list` of many activities fits easily).
    public static let maxResponseBytes = 8 * 1024 * 1024

    public var socketURL: URL
    /// Upper bound for the whole exchange: connect, write and read.
    public var timeout: TimeInterval

    public init(socketURL: URL = IPCPaths.defaultSocketURL, timeout: TimeInterval = 5) {
        self.socketURL = socketURL
        self.timeout = timeout
    }

    /// Sends one command on a new connection and waits for its response.
    public func send(_ command: IPCCommand) throws(IPCClientError) -> IPCResponse {
        try send(IPCRequest(command: command))
    }

    /// Sends one request on a new connection and waits for its response.
    public func send(_ request: IPCRequest) throws(IPCClientError) -> IPCResponse {
        let connection = try connect()
        defer { connection.close() }
        return try connection.send(request)
    }

    /// Opens a connection for several requests.
    public func connect() throws(IPCClientError) -> IPCClientConnection {
        try IPCClientConnection(socketPath: socketURL.path(percentEncoded: false), timeout: timeout)
    }
}

/// One open client connection. Not thread-safe: use it from one thread at a time.
public final class IPCClientConnection {
    private var fd: Int32
    private let timeout: TimeInterval
    private var buffer: [UInt8] = []

    init(socketPath: String, timeout: TimeInterval) throws(IPCClientError) {
        self.timeout = timeout
        let address: sockaddr_un
        do {
            address = try UnixSocket.address(for: socketPath)
        } catch {
            switch error {
            case .pathTooLong: throw .socketPathTooLong(socketPath: socketPath, maxBytes: UnixSocket.maxPathBytes)
            case .emptyPath: throw .serverNotRunning(socketPath: socketPath)
            }
        }
        do {
            fd = try UnixSocket.makeStreamSocket(nonBlocking: true)
        } catch {
            throw .system(error)
        }
        do {
            try establish(address, socketPath: socketPath)
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    private func establish(_ address: sockaddr_un, socketPath: String) throws(IPCClientError) {
        var code: Int32 = UnixSocket.connect(fd, to: address) == 0 ? 0 : errno
        // Unix-domain connects normally complete or fail at once. If one is still in progress
        // (or was interrupted), wait for it and read the outcome from SO_ERROR.
        if code == EINPROGRESS || code == EINTR {
            try wait(for: Int16(POLLOUT), deadline: Date(timeIntervalSinceNow: timeout))
            var pending: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &pending, &length) == 0 else {
                throw .system(SystemCallError("getsockopt(SO_ERROR)"))
            }
            code = pending
        }
        switch code {
        case 0:
            return
        case ENOENT, ECONNREFUSED, ENOTDIR:
            throw .serverNotRunning(socketPath: socketPath)
        case EACCES, EPERM:
            throw .permissionDenied(socketPath: socketPath)
        default:
            throw .system(SystemCallError("connect", code: code))
        }
    }

    /// Closes the connection. Further calls throw ``IPCClientError/connectionClosed``.
    public func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Half-closes the connection: tells the server no more requests are coming, while
    /// responses can still be read. The server answers what it has, then hangs up.
    public func finishWriting() {
        if fd >= 0 {
            shutdown(fd, SHUT_WR)
        }
    }

    /// Sends a command and waits for its response.
    public func send(_ command: IPCCommand) throws(IPCClientError) -> IPCResponse {
        try send(IPCRequest(command: command))
    }

    /// Sends a request and waits for its response.
    public func send(_ request: IPCRequest) throws(IPCClientError) -> IPCResponse {
        let line: Data
        do {
            line = try LiovaWire.encodeLine(request)
        } catch {
            throw .encodingFailed(LiovaWire.describe(error))
        }
        let reply = try exchange(line)
        do {
            return try LiovaWire.makeDecoder().decode(IPCResponse.self, from: reply)
        } catch {
            throw .invalidResponse(LiovaWire.describe(error))
        }
    }

    /// Writes raw bytes (no newline is added) and returns the next response line, without its
    /// newline. Useful for debugging and for testing the server against hostile input.
    public func exchange(_ bytes: Data) throws(IPCClientError) -> Data {
        let deadline = Date(timeIntervalSinceNow: timeout)
        do {
            try write(bytes, deadline: deadline)
        } catch .connectionClosed {
            // The server may have explained itself (e.g. `busy` or `tooLarge`) before hanging up.
            if let parting = try? readLine(deadline: deadline) {
                return parting
            }
            throw .connectionClosed
        }
        return try readLine(deadline: deadline)
    }

    /// Writes raw bytes without waiting for a response.
    public func write(_ bytes: Data, deadline: Date) throws(IPCClientError) {
        var offset = 0
        let bytes = [UInt8](bytes)
        while offset < bytes.count {
            guard fd >= 0 else { throw .connectionClosed }
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
                continue
            }
            switch written == 0 ? EAGAIN : errno {
            case EINTR: continue
            case EAGAIN: try wait(for: Int16(POLLOUT), deadline: deadline)
            case EPIPE, ECONNRESET, ENOTCONN: throw .connectionClosed
            default: throw .system(SystemCallError("write"))
            }
        }
    }

    /// Reads the next line, without its newline.
    public func readLine(deadline: Date) throws(IPCClientError) -> Data {
        var scanned = 0
        while true {
            if let newline = buffer[scanned...].firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            scanned = buffer.count
            guard buffer.count <= IPCClient.maxResponseBytes else { throw .responseTooLarge }
            try fill(deadline: deadline)
        }
    }

    /// Reads at least one more byte into `buffer`, waiting until the deadline if necessary.
    private func fill(deadline: Date) throws(IPCClientError) {
        while true {
            guard fd >= 0 else { throw .connectionClosed }
            let count = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64 * 1024) { chunk -> Int in
                let count = Darwin.read(fd, chunk.baseAddress, chunk.count)
                if count > 0 {
                    buffer.append(contentsOf: chunk[..<count])
                }
                return count
            }
            if count > 0 {
                return
            }
            if count == 0 {
                throw .connectionClosed
            }
            switch errno {
            case EINTR: continue
            case EAGAIN: try wait(for: Int16(POLLIN), deadline: deadline)
            case ECONNRESET, ENOTCONN: throw .connectionClosed
            default: throw .system(SystemCallError("read"))
            }
        }
    }

    /// Blocks until the socket is ready or the deadline passes.
    private func wait(for events: Int16, deadline: Date) throws(IPCClientError) {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw .timedOut(after: timeout) }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up))
            let result = poll(&descriptor, 1, milliseconds)
            if result > 0 {
                return
            } // Readable, writable or hung up: the next call reports which.
            if result == 0 {
                throw .timedOut(after: timeout)
            }
            if errno != EINTR {
                throw .system(SystemCallError("poll"))
            }
        }
    }
}
