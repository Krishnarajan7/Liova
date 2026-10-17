import Foundation
import LiovaPluginKit

/// What a hook invocation should do once its input is understood.
public enum AgentHookAction: Equatable, Sendable {
    /// Report the event to Liova and print nothing.
    case event(AgentEvent)
    /// Ask Liova for a decision and print it for the agent.
    case permission(AgentPermissionRequest)
    /// Nothing to send. The reason is only for `LIOVA_HOOK_DEBUG` logging.
    case ignore(reason: String)
}

/// Translates Claude Code hook input (the JSON object on the hook's stdin) into Liova's
/// agent vocabulary. Pure: no I/O, no clock, so every mapping is unit-tested.
///
/// Parsing is tolerant: unknown fields are ignored and missing optional fields are fine.
/// Every string is trimmed to ``LiovaValidation`` limits instead of failing.
///
/// Privacy: prompt text, assistant messages, file contents and tool output are never
/// forwarded. Events carry the kind, the project folder name and a short tool summary.
public struct ClaudeCodeHookAdapter: Sendable {
    /// The agent name Liova sees.
    public static let agentName = "claude-code"
    /// Longest command shown in an event's detail.
    public static let maxCommandPreviewLength = 80
    /// Byte caps that keep a request far below the 64 KiB wire limit whatever the input.
    static let maxDetailBytes = 2048
    static let maxSummaryBytes = 16 * 1024

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
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
                return .ignore(reason: "Hook input is not a JSON object.")
            }
            object = parsed
        } catch {
            return .ignore(reason: "Hook input is not valid JSON.")
        }
        return adapt(HookInput(object))
    }

    func adapt(_ input: HookInput) -> AgentHookAction {
        guard let eventName = input.string("hook_event_name") else {
            return .ignore(reason: "Missing hook_event_name.")
        }
        guard let event = HookEvent(rawValue: eventName) else {
            return .ignore(reason: "Unhandled hook event '\(eventName)'.")
        }
        guard let sessionID = Self.sessionID(input) else {
            return .ignore(reason: "Missing session_id.")
        }
        let project = Self.project(input)
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
            detail: detail.map(Self.detailText).flatMap { $0.isEmpty ? nil : $0 }
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

    private static func sessionID(_ input: HookInput) -> String? {
        guard let raw = input.string("session_id") else { return nil }
        let sessionID = AgentText.truncate(
            AgentText.singleLine(raw),
            maxCharacters: LiovaValidation.maxSessionIDLength,
            maxBytes: 1024
        )
        return sessionID.isEmpty ? nil : sessionID
    }

    private static func project(_ input: HookInput) -> String? {
        guard let name = input.string("cwd").flatMap(AgentText.lastPathComponent) else { return nil }
        let project = AgentText.truncate(
            AgentText.singleLine(name),
            maxCharacters: LiovaValidation.maxProjectLength,
            maxBytes: 1024
        )
        return project.isEmpty ? nil : project
    }

    private func permission(_ input: HookInput, sessionID: String, project: String?) -> AgentHookAction {
        if let mode = input.string("permission_mode"), Self.silentPermissionModes.contains(mode) {
            return .ignore(reason: "Permission mode '\(mode)' doesn't ask the user.")
        }
        guard let rawTool = input.string("tool_name"), case let tool = AgentText.singleLine(rawTool), !tool.isEmpty
        else {
            return .ignore(reason: "PermissionRequest without tool_name.")
        }
        let summary = Self.permissionSummary(tool: tool, input: input.object("tool_input"))
        return .permission(AgentPermissionRequest(
            agent: Self.agentName,
            sessionID: sessionID,
            project: project,
            tool: AgentText.truncate(tool, maxCharacters: LiovaValidation.maxAgentNameLength, maxBytes: 512),
            summary: AgentText.truncate(
                AgentText.removingControlCharacters(summary).trimmingCharacters(in: .whitespacesAndNewlines),
                maxCharacters: LiovaValidation.maxSummaryLength,
                maxBytes: Self.maxSummaryBytes
            ),
            timeout: min(
                max(permissionTimeout, LiovaValidation.agentTimeoutRange.lowerBound),
                LiovaValidation.agentTimeoutRange.upperBound
            )
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
            guard let command = input?.string("command").flatMap(AgentText.firstNonBlankLine) else {
                return "Running a command"
            }
            let preview = AgentText.truncate(
                AgentText.singleLine(command),
                maxCharacters: maxCommandPreviewLength,
                maxBytes: 1024
            )
            return "Running `\(preview)`"
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
        return compactJSON(input?.raw) ?? ""
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

    private static func detailText(_ text: String) -> String {
        AgentText.truncate(
            AgentText.singleLine(text),
            maxCharacters: LiovaValidation.maxDetailLength,
            maxBytes: maxDetailBytes
        )
    }

    /// One line of JSON with sorted keys, or `nil` if there's nothing to show.
    static func compactJSON(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [
                  .sortedKeys,
                  .withoutEscapingSlashes,
              ])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Typed, forgiving access to a hook's JSON object: wrong types read as missing.
struct HookInput {
    let raw: [String: Any]

    init(_ raw: [String: Any]) {
        self.raw = raw
    }

    func string(_ key: String) -> String? {
        raw[key] as? String
    }

    func bool(_ key: String) -> Bool? {
        // JSONSerialization represents booleans as NSNumber; only accept real booleans.
        guard let number = raw[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    func object(_ key: String) -> HookInput? {
        (raw[key] as? [String: Any]).map(HookInput.init)
    }
}
