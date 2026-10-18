import Foundation
import LiovaPluginKit

/// Translates Gemini CLI hook input (`hooks` in `~/.gemini/settings.json`) into Liova's agent
/// vocabulary.
///
/// Status only: a Gemini CLI hook can block a tool or force its confirmation, but an `allow`
/// doesn't answer Gemini's own approval prompt, so approving from the notch would ask twice.
/// When Gemini asks for approval, its `Notification` hook (`ToolPermission`) makes the notch
/// show that it's waiting for you, and you answer in the terminal.
///
/// Privacy: the prompt (`BeforeAgent`), the response (`AfterAgent`), tool output and the
/// diff or file contents in a `ToolPermission` notification are never forwarded.
public struct GeminiCLIHookAdapter: AgentHookAdapter {
    /// The agent name Liova sees.
    public static let agentName = "gemini-cli"

    public init() {}

    /// Hook events this adapter understands, in the order the installer registers them.
    public enum HookEvent: String, CaseIterable, Sendable {
        case sessionStart = "SessionStart"
        case beforeAgent = "BeforeAgent"
        case beforeTool = "BeforeTool"
        case afterTool = "AfterTool"
        case notification = "Notification"
        case afterAgent = "AfterAgent"
        case sessionEnd = "SessionEnd"
    }

    public func adapt(_ input: Data) -> AgentHookAction {
        switch AgentHookFields.object(input) {
        case let .success(object): adapt(object)
        case let .failure(reason): .ignore(reason: reason.text)
        }
    }

    /// Gemini CLI never asks a hook for a decision, so there is nothing to print.
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
        guard let sessionID = AgentHookFields.sessionID(input.string("session_id")) else {
            return .ignore(reason: "Missing session_id.")
        }
        guard let (kind, detail) = Self.eventKind(event, input: input) else {
            return .ignore(reason: Self.ignoreReason(event, input: input))
        }
        return .event(AgentEvent(
            agent: Self.agentName,
            sessionID: sessionID,
            project: AgentHookFields.project(fromPath: input.string("cwd")),
            kind: kind,
            detail: AgentHookFields.detail(detail)
        ))
    }

    /// The event kind and raw detail, or `nil` to ignore the event.
    private static func eventKind(_ event: HookEvent, input: HookInput) -> (AgentEventKind, String?)? {
        switch event {
        case .sessionStart:
            (.sessionStarted, nil)
        case .beforeAgent:
            (.working, nil) // Never the prompt itself.
        case .beforeTool:
            (.toolStarted, toolDetail(input))
        case .afterTool:
            (.toolFinished, nil)
        case .notification:
            input.string("notification_type") == "ToolPermission"
                ? (.waitingForUser, approvalDetail(input.object("details")))
                : nil
        case .afterAgent:
            input.bool("stop_hook_active") == true ? nil : (.finished, nil)
        case .sessionEnd:
            (.sessionEnded, nil)
        }
    }

    private static func ignoreReason(_ event: HookEvent, input: HookInput) -> String {
        switch event {
        case .notification: "Notification of type '\(input.string("notification_type") ?? "unknown")'."
        case .afterAgent: "AfterAgent while a stop hook is already active."
        default: "\(event.rawValue) isn't reported."
        }
    }

    // MARK: Summaries

    static let editTools: Set<String> = ["write_file", "replace", "edit"]
    static let readTools: Set<String> = ["read_file"]
    static let searchTools: Set<String> = ["glob", "grep_search", "search_file_content", "list_directory"]
    static let webTools: Set<String> = ["web_fetch", "google_web_search"]
    static let subagentTools: Set<String> = ["invoke_agent", "delegate_to_agent"]

    /// A short, human description of a `BeforeTool` call for the notch.
    static func toolDetail(_ input: HookInput) -> String {
        let tool = input.string("tool_name") ?? ""
        let arguments = input.object("tool_input")
        let path = arguments?.string("file_path") ?? arguments?.string("absolute_path") ?? arguments?.string("path")
        switch tool {
        case "run_shell_command":
            return AgentHookFields.runningDetail(arguments?.string("command"))
        case _ where editTools.contains(tool):
            return AgentHookFields.fileDetail("Editing", path: path, fallback: "Editing a file")
        case _ where readTools.contains(tool):
            return AgentHookFields.fileDetail("Reading", path: path, fallback: "Reading a file")
        case "read_many_files":
            return "Reading files"
        case _ where searchTools.contains(tool):
            return "Searching"
        case _ where webTools.contains(tool):
            return "Browsing the web"
        case _ where subagentTools.contains(tool):
            return "Running a subagent"
        default:
            if let server = input.object("mcp_context")?.string("server_name"), !server.isEmpty {
                return "Using \(server)"
            }
            return tool.isEmpty ? "Using a tool" : "Using \(tool)"
        }
    }

    /// What Gemini is asking to do, from a `ToolPermission` notification's `details`. Only the
    /// command, file name or server is used; the diff and file contents there are dropped.
    static func approvalDetail(_ details: HookInput?) -> String {
        let action: String? = switch details?.string("type") {
        case "exec":
            details?.string("command").map { AgentHookFields.runningDetail($0) }
        case "edit":
            details?.string("fileName").flatMap(AgentText.lastPathComponent).map { "Editing \($0)" }
                ?? details?.string("filePath").flatMap(AgentText.lastPathComponent).map { "Editing \($0)" }
        case "mcp":
            details?.string("serverName").map { "Using \($0)" }
        case "info":
            "Fetching from the web"
        default:
            nil
        }
        guard let action else { return "Needs your approval" }
        return "Approve? \(action)"
    }
}
