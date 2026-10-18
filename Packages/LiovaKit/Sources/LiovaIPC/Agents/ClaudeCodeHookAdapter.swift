import Foundation
import LiovaPluginKit

/// Translates Claude Code hook input (the JSON object on the hook's stdin) into Liova's
/// agent vocabulary. Pure: no I/O, no clock, so every mapping is unit-tested.
///
/// Parsing is tolerant: unknown fields are ignored and missing optional fields are fine.
/// Every string is trimmed to ``LiovaValidation`` limits instead of failing.
///
/// Privacy: prompt text, assistant messages, file contents and tool output are never
/// forwarded. Events carry the kind, the project folder name and a short tool summary.
public struct ClaudeCodeHookAdapter: AgentHookAdapter {
    /// The agent name Liova sees.
    public static let agentName = "claude-code"
    /// Longest command shown in an event's detail.
    public static let maxCommandPreviewLength = AgentHookFields.maxCommandPreviewLength

    /// How long Liova may take to answer a permission request.
    public var permissionTimeout: TimeInterval

    public init(permissionTimeout: TimeInterval = 300) {
        self.permissionTimeout = permissionTimeout
    }

    /// Hook events this adapter understands, in the order the installer registers them.
    public enum HookEvent: String, CaseIterable, Sendable {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case permissionRequest = "PermissionRequest"
        case notification = "Notification"
        case stop = "Stop"
        case sessionEnd = "SessionEnd"
    }

    /// Permission modes in which Claude Code doesn't want the user asked.
    static let silentPermissionModes: Set<String> = ["bypassPermissions", "dontAsk"]

    /// Adapts one hook input.
    public func adapt(_ input: Data) -> AgentHookAction {
        switch AgentHookFields.object(input) {
        case let .success(object): adapt(object)
        case let .failure(reason): .ignore(reason: reason.text)
        }
    }

    public func output(for decision: AgentDecision) -> String? {
        ClaudeCodeHookOutput.permissionDecision(decision)
    }

    func adapt(_ input: HookInput) -> AgentHookAction {
        guard let eventName = input.string("hook_event_name") else {
            return .ignore(reason: "Missing hook_event_name.")
        }
        guard let event = HookEvent(rawValue: eventName) else {
            return .ignore(reason: "Unhandled hook event '\(eventName)'.")
        }
        guard let sessionID = AgentHookFields.sessionID(input.string("session_id")) else {
            return .ignore(reason: "Missing session_id.")
        }
        let project = AgentHookFields.project(fromPath: input.string("cwd"))
        if event == .permissionRequest {
            return permission(input, sessionID: sessionID, project: project)
        }
        // Subagents report their own tool use; the notch follows the main conversation.
        if let agentID = input.string("agent_id"), !agentID.isEmpty {
            return .ignore(reason: "\(eventName) from subagent \(agentID).")
        }
        guard let (kind, detail) = Self.eventKind(event, input: input) else {
            return .ignore(reason: Self.ignoreReason(event, input: input))
        }
        return .event(AgentEvent(
            agent: Self.agentName,
            sessionID: sessionID,
            project: project,
            kind: kind,
            detail: AgentHookFields.detail(detail)
        ))
    }

    /// The event kind and raw detail for a non-permission event, or `nil` to ignore it.
    private static func eventKind(_ event: HookEvent, input: HookInput) -> (AgentEventKind, String?)? {
        switch event {
        case .sessionStart:
            (.sessionStarted, nil)
        case .userPromptSubmit:
            (.working, nil) // Never the prompt itself.
        case .preToolUse:
            (.toolStarted, toolDetail(tool: input.string("tool_name") ?? "", input: input.object("tool_input")))
        case .postToolUse:
            (.toolFinished, nil)
        case .notification:
            isIdleNotification(input) ? (.waitingForUser, input.string("message")) : nil
        case .stop:
            input.bool("stop_hook_active") == true ? nil : (.finished, nil)
        case .sessionEnd:
            (.sessionEnded, nil)
        case .permissionRequest:
            nil
        }
    }

    private static func ignoreReason(_ event: HookEvent, input: HookInput) -> String {
        switch event {
        case .notification: "Notification of type '\(input.string("notification_type") ?? "unknown")'."
        case .stop: "Stop while a stop hook is already active."
        default: "\(event.rawValue) isn't reported."
        }
    }

    private func permission(_ input: HookInput, sessionID: String, project: String?) -> AgentHookAction {
        if let mode = input.string("permission_mode"), Self.silentPermissionModes.contains(mode) {
            return .ignore(reason: "Permission mode '\(mode)' doesn't ask the user.")
        }
        guard let tool = AgentHookFields.toolName(input.string("tool_name")) else {
            return .ignore(reason: "PermissionRequest without tool_name.")
        }
        let summary = Self.permissionSummary(tool: tool, input: input.object("tool_input"))
        return .permission(AgentPermissionRequest(
            agent: Self.agentName,
            sessionID: sessionID,
            project: project,
            tool: tool,
            summary: AgentHookFields.summary(summary),
            timeout: AgentHookFields.permissionTimeout(permissionTimeout)
        ))
    }

    // MARK: Summaries

    static let fileEditingTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    static let searchTools: Set<String> = ["Grep", "Glob"]
    static let webTools: Set<String> = ["WebFetch", "WebSearch"]
    static let subagentTools: Set<String> = ["Task", "Agent"]

    /// A short, human description of a tool call for the notch, e.g. "Editing App.swift".
    static func toolDetail(tool: String, input: HookInput?) -> String {
        switch tool {
        case "Bash":
            return AgentHookFields.runningDetail(input?.string("command"))
        case _ where fileEditingTools.contains(tool):
            return filePath(input).flatMap(AgentText.lastPathComponent).map { "Editing \($0)" } ?? "Editing a file"
        case "Read":
            return filePath(input).flatMap(AgentText.lastPathComponent).map { "Reading \($0)" } ?? "Reading a file"
        case _ where searchTools.contains(tool):
            return "Searching"
        case _ where webTools.contains(tool):
            return "Browsing the web"
        case _ where subagentTools.contains(tool):
            return "Running a subagent"
        default:
            if let server = mcpServer(tool) {
                return "Using \(server)"
            }
            return tool.isEmpty ? "Using a tool" : "Using \(tool)"
        }
    }

    /// What exactly the tool wants to do, shown verbatim when asking for permission.
    static func permissionSummary(tool: String, input: HookInput?) -> String {
        switch tool {
        case "Bash":
            if let command = input?.string("command") {
                return command
            }
        case _ where fileEditingTools.contains(tool) || tool == "Read":
            if let path = filePath(input) {
                return path
            }
        case "WebFetch":
            if let url = input?.string("url") {
                return url
            }
        case "WebSearch":
            if let query = input?.string("query") {
                return query
            }
        default:
            break
        }
        return AgentHookFields.compactJSON(input?.raw) ?? ""
    }

    /// `server` for an MCP tool named `mcp__server__tool`.
    static func mcpServer(_ tool: String) -> String? {
        guard tool.hasPrefix("mcp__") else { return nil }
        let rest = tool.dropFirst("mcp__".count)
        let server = rest.components(separatedBy: "__").first ?? ""
        return server.isEmpty ? nil : server
    }

    private static func filePath(_ input: HookInput?) -> String? {
        input?.string("file_path") ?? input?.string("notebook_path") ?? input?.string("path")
    }

    private static func isIdleNotification(_ input: HookInput) -> Bool {
        if let type = input.string("notification_type") {
            return type == "idle_prompt"
        }
        // Older Claude Code versions send no type; the idle message is fixed text.
        return input.string("message")?.localizedCaseInsensitiveContains("waiting for your input") == true
    }
}
