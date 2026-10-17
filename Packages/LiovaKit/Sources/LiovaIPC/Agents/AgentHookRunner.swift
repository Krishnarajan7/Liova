import Darwin
import Foundation
import LiovaPluginKit

/// Coding agents Liova can hook into.
public enum AgentKind: String, CaseIterable, Sendable {
    case claudeCode = "claude-code"

    /// Name for people, e.g. in `liova agents status`.
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        }
    }
}

/// What Claude Code expects on stdout from a `PermissionRequest` hook.
public enum ClaudeCodeHookOutput {
    /// The message Claude Code shows (and tells the model) when the user denies from the notch.
    public static let denyMessage = "Denied from the Liova notch."

    /// The decision JSON to print, or `nil` to print nothing so Claude Code shows its own
    /// prompt (for ``AgentDecision/ask``).
    public static func permissionDecision(_ decision: AgentDecision) -> String? {
        switch decision {
        case .allow:
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        case .deny:
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","#
                + #""message":"\#(denyMessage)"}}}"#
        case .ask:
            nil
        }
    }
}

/// The body of `liova hook <agent>`: adapt the hook input, tell Liova, and work out what to
/// print. Never throws and never blocks the agent for longer than its budget.
///
/// I/O is injected (input bytes in, stdout text out, a log closure for debugging), so the
/// whole path runs in-process in tests against a real server.
public struct AgentHookRunner: Sendable {
    /// Hook input larger than this is ignored (it is drained, not parsed).
    public static let maxInputBytes = 1024 * 1024
    /// Total time an event may take: connect, send and read the acknowledgement.
    public static let defaultEventBudget: TimeInterval = 0.3
    /// Extra time to wait beyond the permission timeout, so Liova's own `ask` on timeout
    /// still arrives instead of the client giving up first.
    public static let permissionGrace: TimeInterval = 5
    /// Environment variable that turns on stderr logging.
    public static let debugEnvironmentKey = "LIOVA_HOOK_DEBUG"

    public var agent: AgentKind
    public var socketURL: URL
    public var permissionTimeout: TimeInterval
    public var eventBudget: TimeInterval
    /// Receives debug messages. Only called when debugging is on.
    public var log: (@Sendable (String) -> Void)?

    public init(
        agent: AgentKind = .claudeCode,
        socketURL: URL = IPCPaths.defaultSocketURL,
        permissionTimeout: TimeInterval = 300,
        eventBudget: TimeInterval = AgentHookRunner.defaultEventBudget,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.agent = agent
        self.socketURL = socketURL
        self.permissionTimeout = permissionTimeout
        self.eventBudget = eventBudget
        self.log = log
    }

    /// Whether `environment` asks for hook debugging (`LIOVA_HOOK_DEBUG=1`).
    public static func isDebugEnabled(_ environment: [String: String]) -> Bool {
        guard let value = environment[debugEnvironmentKey]?.lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(value)
    }

    /// Runs the hook for one input and returns what to print on stdout (`nil`: nothing).
    /// `input` is `nil` when stdin couldn't be read or was too large.
    public func run(input: Data?) -> String? {
        guard let input else {
            log?("No usable input on stdin; ignoring.")
            return nil
        }
        let action = adapt(input)
        switch action {
        case let .ignore(reason):
            log?("Ignored: \(reason)")
            return nil
        case let .event(event):
            send(.agentEvent(event), timeout: eventBudget, label: "\(event.kind.rawValue) event")
            return nil
        case let .permission(request):
            let timeout = request.timeout + Self.permissionGrace
            guard let response = send(.agentPermission(request), timeout: timeout, label: "permission request")
            else { return nil }
            guard let decision = response.decision else {
                log?("Liova answered without a decision; deferring to the terminal prompt.")
                return nil
            }
            log?("Decision: \(decision.rawValue).")
            return ClaudeCodeHookOutput.permissionDecision(decision)
        }
    }

    func adapt(_ input: Data) -> AgentHookAction {
        switch agent {
        case .claudeCode: ClaudeCodeHookAdapter(permissionTimeout: permissionTimeout).adapt(input)
        }
    }

    /// Sends one command. Returns the response only if Liova accepted it.
    @discardableResult
    private func send(_ command: IPCCommand, timeout: TimeInterval, label: String) -> IPCResponse? {
        do {
            try LiovaValidation.validate(command)
        } catch {
            log?("Not sending invalid \(label): \(error.message)")
            return nil
        }
        let start = ContinuousClock.now
        let client = IPCClient(socketURL: socketURL, timeout: timeout)
        do {
            let response = try client.send(command)
            let elapsed = ContinuousClock.now - start
            guard response.ok else {
                log?("Liova rejected the \(label) after \(elapsed): \(response.error?.description ?? "unknown error")")
                return nil
            }
            log?("Sent \(label) in \(elapsed).")
            return response
        } catch {
            log?("Couldn't send \(label): \(error.description)")
            return nil
        }
    }
}

/// Reads a hook's stdin.
public enum AgentHookInput {
    /// Reads `descriptor` to the end. Returns `nil` if it holds more than `limit` bytes (the
    /// rest is drained so the writer never sees a broken pipe) or can't be read. Returns `nil`
    /// at once for a terminal, so running the hook by hand doesn't hang.
    public static func read(
        from descriptor: Int32 = STDIN_FILENO,
        limit: Int = AgentHookRunner.maxInputBytes
    ) -> Data? {
        if isatty(descriptor) == 1 {
            return nil
        }
        var data = Data()
        var overflowed = false
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, chunkSize) }
            if count > 0 {
                if !overflowed {
                    data.append(contentsOf: chunk[..<count])
                    if data.count > limit {
                        overflowed = true
                        data = Data()
                    }
                }
                continue
            }
            if count == 0 {
                break
            }
            switch errno {
            case EINTR:
                continue
            case EAGAIN:
                // A non-blocking stdin: wait for data, but never forever.
                var descriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 5000) > 0 else { return nil }
            default:
                return nil
            }
        }
        return overflowed ? nil : data
    }
}
