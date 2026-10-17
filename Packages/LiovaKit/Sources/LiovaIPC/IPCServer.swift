import Foundation
import LiovaPluginKit

/// Why the ``IPCServer`` couldn't start.
public enum IPCServerError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Another server (probably another copy of Liova) is answering on the socket.
    case alreadyRunning(socketPath: String)
    /// The path doesn't fit in `sockaddr_un` (see ``IPCPaths/maxSocketPathBytes``).
    case socketPathTooLong(socketPath: String, maxBytes: Int)
    /// The socket's directory is a symlink, belongs to someone else, or can't be made private.
    case insecureDirectory(path: String, reason: String)
    /// The socket's directory doesn't exist and couldn't be created.
    case cannotCreateDirectory(path: String, reason: String)
    /// Something that isn't a socket already exists at the socket path; it is left alone.
    case pathOccupied(socketPath: String)
    /// `start()` was called on a running server.
    case alreadyStarted
    case system(SystemCallError)

    public var description: String {
        switch self {
        case let .alreadyRunning(path):
            "Another Liova server is already listening on \(path)."
        case let .socketPathTooLong(path, max):
            "Socket path is \(path.utf8.count) bytes, but Unix sockets allow at most \(max): \(path)"
        case let .insecureDirectory(path, reason):
            "Refusing to use socket directory \(path): \(reason)"
        case let .cannotCreateDirectory(path, reason):
            "Couldn't create socket directory \(path): \(reason)"
        case let .pathOccupied(path):
            "\(path) exists and is not a socket; move it away or choose another path with LIOVA_SOCKET."
        case .alreadyStarted:
            "The IPC server is already running."
        case let .system(error):
            error.description
        }
    }
}

/// The tier 1 plugin server: newline-delimited JSON over a Unix domain socket.
///
/// Fully event-driven: with no clients connected it holds one listening descriptor and does
/// no work at all. All socket I/O runs on a private serial queue; requests are handed to the
/// ``IPCRequestHandler`` in a task, so a slow handler never blocks other connections.
///
/// Security: the socket's directory is forced to `0700` and must be a real directory owned by
/// the current user; the socket is `0600`; every connection's peer UID is checked with
/// `getpeereid` and other users are rejected; lines are capped (``Configuration/maxLineBytes``),
/// connections are capped, idle connections time out, and each connection is rate-limited.
public final class IPCServer: Sendable {
    /// Limits. The defaults suit production; tests shrink them.
    public struct Configuration: Sendable, Equatable {
        /// Largest request line accepted, newline excluded. Larger lines get `tooLarge` and the
        /// connection is closed.
        public var maxLineBytes: Int
        /// Concurrent connections. Further clients get `busy` and are disconnected.
        public var maxConnections: Int
        /// A connection with no traffic for this long (and no request in flight) is closed.
        public var idleTimeout: TimeInterval
        /// Requests a connection may send in a burst before being rate-limited.
        public var rateLimitBurst: Int
        /// Sustained requests per second per connection.
        public var rateLimitPerSecond: Double
        /// `listen(2)` backlog.
        public var listenBacklog: Int32

        public init(
            maxLineBytes: Int = LiovaWire.maxRequestLineBytes,
            maxConnections: Int = 32,
            idleTimeout: TimeInterval = 30,
            rateLimitBurst: Int = 100,
            rateLimitPerSecond: Double = 50,
            listenBacklog: Int32 = 16
        ) {
            self.maxLineBytes = maxLineBytes
            self.maxConnections = maxConnections
            self.idleTimeout = idleTimeout
            self.rateLimitBurst = rateLimitBurst
            self.rateLimitPerSecond = rateLimitPerSecond
            self.listenBacklog = listenBacklog
        }
    }

    public let socketURL: URL
    public let configuration: Configuration
    private let core: ServerCore

    /// Creates a stopped server. Call ``start()`` to begin listening.
    public init(
        socketURL: URL = IPCPaths.defaultSocketURL,
        configuration: Configuration = Configuration(),
        handler: some IPCRequestHandler
    ) {
        self.socketURL = socketURL
        self.configuration = configuration
        core = ServerCore(
            socketPath: socketURL.path(percentEncoded: false),
            configuration: configuration,
            handler: handler
        )
    }

    deinit {
        core.stop()
    }

    /// Prepares the directory, recovers a stale socket file, binds and starts accepting.
    ///
    /// Throws ``IPCServerError/alreadyRunning(socketPath:)`` if a live server answers on the
    /// path. Safe to call again after ``stop()``.
    public func start() throws(IPCServerError) {
        try core.start()
    }

    /// Stops accepting, closes every connection and removes the socket file. Idempotent, and
    /// safe to call from any thread, including from inside a handler.
    ///
    /// When it returns, the socket path is gone and no new request will reach the handler.
    /// Handler calls already in flight are cancelled (cooperatively) and their responses dropped.
    public func stop() {
        core.stop()
    }

    public var isRunning: Bool {
        core.isRunning
    }

    /// Number of open client connections.
    public var connectionCount: Int {
        core.connectionCount
    }
}
