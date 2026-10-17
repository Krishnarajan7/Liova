import Darwin
import LiovaPluginKit

/// Executes validated commands for the ``IPCServer``.
///
/// The server calls this once per request, from a background task, after it has decoded the
/// line, checked the protocol version and run ``LiovaValidation`` (so `system.*` sources and
/// malformed fields never get here). Requests on one connection are handled one at a time,
/// in order; different connections may call concurrently.
///
/// `ping` is answered by the server itself and never reaches the handler.
///
/// Responsibilities left to the handler:
/// - `update`, `end`: reply `notFound` when the ID doesn't exist, and `forbidden` when the
///   target activity's source is reserved (``LiovaValidation/isReservedSource(_:)``).
/// - `endAll`: end the source's activities (an unknown source can simply succeed).
/// - `list`: return the live activities in ``IPCResponse/activities``, in display order
///   (the first one is what the notch is showing).
public protocol IPCRequestHandler: Sendable {
    func handle(_ command: IPCCommand, client: IPCClientInfo) async -> IPCResponse
}

/// Who sent a request.
public struct IPCClientInfo: Sendable, Hashable, CustomStringConvertible {
    /// Unique per connection for the server's lifetime.
    public var connectionID: UInt64
    /// The peer's process ID, if the kernel reported it. Informational only; never use it for
    /// authorization (PIDs are reused).
    public var pid: pid_t?
    /// The peer's effective user ID. Always the current user: other users are rejected.
    public var uid: uid_t

    public init(connectionID: UInt64, pid: pid_t?, uid: uid_t) {
        self.connectionID = connectionID
        self.pid = pid
        self.uid = uid
    }

    public var description: String {
        "connection #\(connectionID) (pid \(pid.map(String.init) ?? "?"), uid \(uid))"
    }
}

/// Adapts a closure to ``IPCRequestHandler``.
public struct IPCClosureHandler: IPCRequestHandler {
    private let body: @Sendable (IPCCommand, IPCClientInfo) async -> IPCResponse

    public init(_ body: @escaping @Sendable (IPCCommand, IPCClientInfo) async -> IPCResponse) {
        self.body = body
    }

    public func handle(_ command: IPCCommand, client: IPCClientInfo) async -> IPCResponse {
        await body(command, client)
    }
}
