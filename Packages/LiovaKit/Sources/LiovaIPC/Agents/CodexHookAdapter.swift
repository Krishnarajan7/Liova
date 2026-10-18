import Foundation
import LiovaPluginKit

/// Translates Codex CLI hook input into Liova's agent vocabulary.
///
/// Codex's hooks (`~/.codex/hooks.json`) use the same shape as Claude Code's: one JSON object
/// on stdin with `session_id`, `cwd`, `hook_event_name`, `tool_name` and `tool_input`, and a
/// `PermissionRequest` hook that answers with `hookSpecificOutput.decision.behavior`.
///
/// It also understands the older `notify` program payload (`{"type":"agent-turn-complete",
/// ...}`, passed as an argument), so `notify = ["…/liova", "hook", "codex"]` keeps working on
/// Codex versions without hooks.
///
/// Privacy: prompts, `last-assistant-message`, `input-messages`, patch contents and tool output
/// are never forwarded. A patch is reduced to the files it touches.
public struct CodexHookAdapter: AgentHookAdapter {
    /// The agent name Liova sees.
    public static let agentName = "codex"
    /// The message Codex shows (and tells the model) when the user denies from the notch.
    public static let denyMessage = ClaudeCodeHookOutput.denyMessage

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
        case stop = "Stop"
        case sessionEnd = "SessionEnd"
    }

    /// The `type` of the `notify` payload sent when a turn completes.
    public static let notifyTurnComplete = "agent-turn-complete"

    /// Permission modes in which Codex doesn't want the user asked.
    static let silentPermissionModes: Set<String> = ["bypassPermissions", "dontAsk"]

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
            if let type = input.string("type") {
                return notify(input, type: type)
            }
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
        // Subagents report their own tool use; the notch follows the main thread.
        if let agentID = input.string("agent_id"), !agentID.isEmpty {
            return .ignore(reason: "\(eventName) from subagent \(agentID).")
        }
        guard let (kind, detail) = Self.eventKind(event, input: input) else {
            return .ignore(reason: "Stop while a stop hook is already active.")
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
        case .stop:
            input.bool("stop_hook_active") == true ? nil : (.finished, nil)
        case .sessionEnd:
            (.sessionEnded, nil)
        case .permissionRequest:
            nil
        }
    }

    /// The legacy `notify` payload: only turn completion exists.
    private func notify(_ input: HookInput, type: String) -> AgentHookAction {
        guard type == Self.notifyTurnComplete else {
            return .ignore(reason: "Unhandled notify type '\(type)'.")
        }
        // Old Codex versions send no thread ID; one shared session per project is the best
        // grouping available then.
        let project = AgentHookFields.project(fromPath: input.string("cwd"))
        let sessionID = AgentHookFields.sessionID(input.string("thread-id"))
            ?? AgentHookFields.sessionID("notify-\(project ?? "codex")")
            ?? "codex"
        return .event(AgentEvent(agent: Self.agentName, sessionID: sessionID, project: project, kind: .finished))
    }

    private func permission(_ input: HookInput, sessionID: String, project: String?) -> AgentHookAction {
        if let mode = input.string("permission_mode"), Self.silentPermissionModes.contains(mode) {
            return .ignore(reason: "Permission mode '\(mode)' doesn't ask the user.")
        }
        guard let tool = AgentHookFields.toolName(input.string("tool_name")) else {
            return .ignore(reason: "PermissionRequest without tool_name.")
        }
        return .permission(AgentPermissionRequest(
            agent: Self.agentName,
            sessionID: sessionID,
            project: project,
            tool: tool,
            summary: AgentHookFields.summary(Self.permissionSummary(tool: tool, input: input.object("tool_input"))),
            timeout: AgentHookFields.permissionTimeout(permissionTimeout)
        ))
    }

    // MARK: Summaries

    /// Names Codex has used for its shell tool. Current versions report `Bash`.
    static let shellTools: Set<String> = ["Bash", "shell", "local_shell", "exec_command", "unified_exec"]
    static let patchTools: Set<String> = ["apply_patch", "Edit", "Write"]

    /// A short, human description of a tool call for the notch.
    static func toolDetail(tool: String, input: HookInput?) -> String {
        switch tool {
        case _ where shellTools.contains(tool):
            return AgentHookFields.runningDetail(AgentHookFields.command(input?.raw["command"]))
        case _ where patchTools.contains(tool):
            let files = patchFiles(input).filter { $0.action != "Move to" }
            switch files.count {
            case 0: return "Editing files"
            case 1: return AgentHookFields.fileDetail("Editing", path: files[0].path, fallback: "Editing a file")
            default: return "Editing \(files.count) files"
            }
        default:
            if let server = ClaudeCodeHookAdapter.mcpServer(tool) {
                return "Using \(server)"
            }
            return tool.isEmpty ? "Using a tool" : "Using \(tool)"
        }
    }

    /// What exactly the tool wants to do, shown verbatim when asking for permission. For a
    /// patch that's the list of files and what happens to them, never the patch itself.
    static func permissionSummary(tool: String, input: HookInput?) -> String {
        switch tool {
        case _ where shellTools.contains(tool):
            if let command = AgentHookFields.command(input?.raw["command"]) {
                return command
            }
        case _ where patchTools.contains(tool):
            let files = patchFiles(input)
            if !files.isEmpty {
                return files.map { "\($0.action) \($0.path)" }.joined(separator: "\n")
            }
            if let path = input?.string("file_path") ?? input?.string("path") {
                return path
            }
            return "Apply a patch"
        default:
            break
        }
        return AgentHookFields.compactJSON(input?.raw) ?? ""
    }

    /// A file touched by an `apply_patch` call.
    struct PatchFile: Equatable {
        /// `Add`, `Update`, `Delete` or `Move to`.
        var action: String
        var path: String
    }

    /// The files named in an `apply_patch` envelope (`*** Update File: path` and friends).
    /// Only these header lines are read; the patch body is never kept.
    static func patchFiles(_ input: HookInput?) -> [PatchFile] {
        guard let patch = input?.string("command") ?? input?.string("patch") ?? input?.string("input") else {
            return []
        }
        let markers = [
            ("*** Add File: ", "Add"),
            ("*** Update File: ", "Update"),
            ("*** Delete File: ", "Delete"),
            ("*** Move to: ", "Move to"),
        ]
        var files: [PatchFile] = []
        for line in patch.split(whereSeparator: \.isNewline) where line.hasPrefix("*** ") {
            for (marker, action) in markers where line.hasPrefix(marker) {
                let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty {
                    files.append(PatchFile(action: action, path: path))
                }
            }
            if files.count >= 50 {
                break
            }
        }
        return files
    }
}
