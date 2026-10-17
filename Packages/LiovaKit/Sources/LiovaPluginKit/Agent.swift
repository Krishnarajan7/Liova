import Foundation

/// Something a coding agent (Claude Code, Codex, Cursor, Gemini CLI…) is doing.
///
/// Agent-specific hook formats are translated into these on the client side (the `liova`
/// CLI), so Liova itself only knows this one vocabulary.
public struct AgentEvent: Codable, Sendable, Equatable {
    /// Which agent, e.g. `claude-code`. Lowercase identifier.
    public var agent: String
    /// The agent's own session identifier. Groups events into one session.
    public var sessionID: String
    /// Human-readable project name, usually the working directory's last path component.
    public var project: String?
    public var kind: AgentEventKind
    /// Short description of the current step, e.g. `Running npm test` or `Editing App.swift`.
    public var detail: String?

    public init(agent: String, sessionID: String, project: String? = nil, kind: AgentEventKind, detail: String? = nil) {
        self.agent = agent
        self.sessionID = sessionID
        self.project = project
        self.kind = kind
        self.detail = detail
    }
}

public enum AgentEventKind: String, Codable, Sendable, CaseIterable {
    /// A session started or resumed.
    case sessionStarted
    /// The user sent a prompt; the agent is working.
    case working
    /// The agent started a tool (see `detail`).
    case toolStarted
    /// A tool finished; the agent keeps working.
    case toolFinished
    /// The agent is waiting for the user (e.g. idle at its prompt).
    case waitingForUser
    /// The agent finished its turn.
    case finished
    /// The session ended.
    case sessionEnded
}

/// An agent asking whether it may do something.
public struct AgentPermissionRequest: Codable, Sendable, Equatable {
    public var agent: String
    public var sessionID: String
    public var project: String?
    /// The tool or capability, e.g. `Bash`, `Edit`, `WebFetch`.
    public var tool: String
    /// What exactly it wants to do, e.g. the shell command. Shown verbatim (truncated).
    public var summary: String
    /// How long Liova may wait for an answer before deferring to the agent's own prompt.
    public var timeout: TimeInterval

    public init(
        agent: String,
        sessionID: String,
        project: String? = nil,
        tool: String,
        summary: String,
        timeout: TimeInterval = 300
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.project = project
        self.tool = tool
        self.summary = summary
        self.timeout = timeout
    }
}

/// The answer to an `AgentPermissionRequest`.
public enum AgentDecision: String, Codable, Sendable, CaseIterable {
    case allow
    case deny
    /// No decision from Liova: let the agent show its own prompt (timeout, Liova busy,
    /// or the user chose to answer in the terminal).
    case ask
}

public extension LiovaValidation {
    static let maxAgentNameLength = 64
    static let maxSessionIDLength = 256
    static let maxProjectLength = 200
    static let maxDetailLength = 300
    static let maxSummaryLength = 2000
    static let agentTimeoutRange: ClosedRange<TimeInterval> = 1 ... 3600

    static func validate(_ event: AgentEvent) throws(IPCErrorInfo) {
        try validateAgentIdentity(agent: event.agent, sessionID: event.sessionID, project: event.project)
        if let detail = event.detail, detail.count > maxDetailLength {
            throw IPCErrorInfo(.badRequest, "'detail' is longer than \(maxDetailLength) characters.")
        }
    }

    static func validate(_ request: AgentPermissionRequest) throws(IPCErrorInfo) {
        try validateAgentIdentity(agent: request.agent, sessionID: request.sessionID, project: request.project)
        guard !request.tool.isEmpty, request.tool.count <= maxAgentNameLength else {
            throw IPCErrorInfo(.badRequest, "'tool' must be 1–\(maxAgentNameLength) characters.")
        }
        guard request.summary.count <= maxSummaryLength else {
            throw IPCErrorInfo(.badRequest, "'summary' is longer than \(maxSummaryLength) characters.")
        }
        guard agentTimeoutRange.contains(request.timeout) else {
            throw IPCErrorInfo(.badRequest, "'timeout' must be between 1 and 3600 seconds.")
        }
    }

    private static func validateAgentIdentity(agent: String, sessionID: String, project: String?) throws(IPCErrorInfo) {
        guard !agent.isEmpty, agent.count <= maxAgentNameLength,
              agent.unicodeScalars.allSatisfy(isIdentifierCharacter)
        else {
            throw IPCErrorInfo(.badRequest, "'agent' must be 1–\(maxAgentNameLength) characters of [A-Za-z0-9._-].")
        }
        guard !sessionID.isEmpty, sessionID.count <= maxSessionIDLength else {
            throw IPCErrorInfo(.badRequest, "'sessionID' must be 1–\(maxSessionIDLength) characters.")
        }
        if let project, project.count > maxProjectLength {
            throw IPCErrorInfo(.badRequest, "'project' is longer than \(maxProjectLength) characters.")
        }
    }
}
