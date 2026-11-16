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
    /// How much of the agent's limits is used. Sent with ``AgentEventKind/usage``.
    public var usage: AgentUsage?

    public init(
        agent: String,
        sessionID: String,
        project: String? = nil,
        kind: AgentEventKind,
        detail: String? = nil,
        usage: AgentUsage? = nil
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.project = project
        self.kind = kind
        self.detail = detail
        self.usage = usage
    }
}

/// How much of an agent's limits a session has used, as the agent itself reports it.
/// Every part is optional: agents report what they know (Claude Code reports rate limits
/// only to subscribers, and only after the session's first reply).
public struct AgentUsage: Codable, Sendable, Equatable {
    /// One rate-limit window.
    public struct Window: Codable, Sendable, Equatable {
        /// 0 to 100.
        public var usedPercentage: Double
        /// When the window starts over, in seconds since 1970.
        public var resetsAt: TimeInterval?

        public init(usedPercentage: Double, resetsAt: TimeInterval? = nil) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }
    }

    public var fiveHour: Window?
    public var sevenDay: Window?
    /// How full the model's context window is, 0 to 100.
    public var contextUsedPercentage: Double?
    /// The session's estimated cost in US dollars.
    public var costUSD: Double?
    /// The model's display name.
    public var model: String?

    public init(
        fiveHour: Window? = nil,
        sevenDay: Window? = nil,
        contextUsedPercentage: Double? = nil,
        costUSD: Double? = nil,
        model: String? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.contextUsedPercentage = contextUsedPercentage
        self.costUSD = costUSD
        self.model = model
    }

    public var isEmpty: Bool {
        fiveHour == nil && sevenDay == nil && contextUsedPercentage == nil && costUSD == nil
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
    /// How much of its limits the agent has used (see ``AgentEvent/usage``). Says nothing
    /// about what the agent is doing.
    case usage
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
        if let usage = event.usage {
            try validate(usage)
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

    private static func validate(_ usage: AgentUsage) throws(IPCErrorInfo) {
        let percentages = [usage.fiveHour?.usedPercentage, usage.sevenDay?.usedPercentage, usage.contextUsedPercentage]
        guard percentages.compactMap(\.self).allSatisfy({ (0 ... 100).contains($0) }) else {
            throw IPCErrorInfo(.badRequest, "Usage percentages must be between 0 and 100.")
        }
        let amounts = [usage.costUSD, usage.fiveHour?.resetsAt, usage.sevenDay?.resetsAt]
        guard amounts.compactMap(\.self).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw IPCErrorInfo(.badRequest, "Usage amounts must be finite and not negative.")
        }
        if let model = usage.model, model.count > maxAgentNameLength {
            throw IPCErrorInfo(.badRequest, "'model' is longer than \(maxAgentNameLength) characters.")
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
