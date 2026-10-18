import Foundation
import LiovaPluginKit

/// Translates Cursor agent hook input (`~/.cursor/hooks.json`) into Liova's agent vocabulary.
///
/// Status only. Cursor's permission hooks (`beforeShellExecution`, `beforeMCPExecution`,
/// `preToolUse`) reliably enforce only `deny`: an `allow` doesn't skip Cursor's own approval
/// and `ask` isn't enforced, so approving from the notch would either ask twice or not hold.
/// Liova therefore never prints a decision for Cursor; empty output leaves Cursor's own
/// behaviour unchanged.
///
/// Privacy: prompts, agent messages and thoughts, file contents, edits and tool output are
/// never forwarded.
public struct CursorHookAdapter: AgentHookAdapter {
    /// The agent name Liova sees.
    public static let agentName = "cursor"

    public init() {}

    /// Hook events this adapter understands. ``registered`` lists the ones the installer adds.
    public enum HookEvent: String, CaseIterable, Sendable {
        case sessionStart
        case beforeSubmitPrompt
        case preToolUse
        case postToolUse
        case postToolUseFailure
        case stop
        case sessionEnd
        // Older, narrower events; understood if wired up by hand.
        case beforeShellExecution
        case beforeMCPExecution
        case afterShellExecution
        case afterMCPExecution
        case afterFileEdit

        /// The events `liova agents install cursor` registers, in order.
        public static let registered: [HookEvent] = [
            .sessionStart, .beforeSubmitPrompt, .preToolUse, .postToolUse, .postToolUseFailure, .stop, .sessionEnd,
        ]
    }

    public func adapt(_ input: Data) -> AgentHookAction {
        switch AgentHookFields.object(input) {
        case let .success(object): adapt(object)
        case let .failure(reason): .ignore(reason: reason.text)
        }
    }

    /// Liova never answers Cursor's permission hooks (see the type's documentation).
    public func output(for _: AgentDecision) -> String? {
        nil
    }

    func adapt(_ input: HookInput) -> AgentHookAction {
        guard let eventName = input.string("hook_event_name") else {
            return .ignore(reason: "Missing hook_event_name.")
        }
        guard let event = HookEvent(rawValue: eventName) else {
            return .ignore(reason: "Unhandled hook event '\(eventName)'.")
        }
        guard let sessionID = AgentHookFields.sessionID(input.string("conversation_id"))
            ?? AgentHookFields.sessionID(input.string("session_id"))
        else {
            return .ignore(reason: "Missing conversation_id.")
        }
        guard let (kind, detail) = Self.eventKind(event, input: input) else {
            return .ignore(reason: "\(eventName) isn't reported.")
        }
        return .event(AgentEvent(
            agent: Self.agentName,
            sessionID: sessionID,
            project: Self.project(input),
            kind: kind,
            detail: AgentHookFields.detail(detail)
        ))
    }

    private static func eventKind(_ event: HookEvent, input: HookInput) -> (AgentEventKind, String?)? {
        switch event {
        case .sessionStart:
            (.sessionStarted, nil)
        case .beforeSubmitPrompt:
            (.working, nil) // Never the prompt itself.
        case .preToolUse:
            (.toolStarted, toolDetail(tool: input.string("tool_name") ?? "", input: input.object("tool_input")))
        case .beforeShellExecution:
            (.toolStarted, AgentHookFields.runningDetail(input.string("command")))
        case .beforeMCPExecution:
            (.toolStarted, input.string("mcp_server_name").map { "Using \($0)" } ?? "Using a tool")
        case .postToolUse, .postToolUseFailure, .afterShellExecution, .afterMCPExecution, .afterFileEdit:
            (.toolFinished, nil)
        case .stop:
            (.finished, stopDetail(input.string("status")))
        case .sessionEnd:
            (.sessionEnded, nil)
        }
    }

    /// The workspace folder's name. `workspace_roots` is on every event, so a session keeps one
    /// project name even when a tool runs in a subfolder.
    private static func project(_ input: HookInput) -> String? {
        AgentHookFields.project(fromPath: input.firstString("workspace_roots"))
            ?? AgentHookFields.project(fromPath: input.string("cwd"))
    }

    private static func stopDetail(_ status: String?) -> String? {
        switch status {
        case "aborted": "Stopped"
        case "error": "Stopped with an error"
        default: nil
        }
    }

    // MARK: Summaries

    static let editTools: Set<String> = ["Write", "Edit", "StrReplace", "MultiEdit"]
    static let searchTools: Set<String> = ["Grep", "Glob", "LS", "SemanticSearch", "Search"]

    /// A short, human description of a `preToolUse` call for the notch.
    static func toolDetail(tool: String, input: HookInput?) -> String {
        let path = input?.string("file_path") ?? input?.string("target_file") ?? input?.string("path")
        switch tool {
        case "Shell":
            return AgentHookFields.runningDetail(input?.string("command"))
        case "Read":
            return AgentHookFields.fileDetail("Reading", path: path, fallback: "Reading a file")
        case _ where editTools.contains(tool):
            return AgentHookFields.fileDetail("Editing", path: path, fallback: "Editing a file")
        case "Delete":
            return AgentHookFields.fileDetail("Deleting", path: path, fallback: "Deleting a file")
        case _ where searchTools.contains(tool):
            return "Searching"
        case "Task":
            return "Running a subagent"
        case _ where tool.hasPrefix("MCP:"):
            let name = tool.dropFirst("MCP:".count).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "Using a tool" : "Using \(name)"
        default:
            return tool.isEmpty ? "Using a tool" : "Using \(tool)"
        }
    }
}
