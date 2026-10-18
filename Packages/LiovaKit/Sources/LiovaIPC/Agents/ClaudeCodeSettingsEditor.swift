import Foundation

/// Liova's hooks in Claude Code's `settings.json`. A ``MatcherGroupHooksEditor`` with Claude
/// Code's events; these statics are kept for callers that only deal with Claude Code.
public enum ClaudeCodeSettingsEditor {
    public typealias HookEvent = ClaudeCodeHookAdapter.HookEvent

    /// The arguments after the binary in every Liova hook command.
    public static let hookArguments = "hook claude-code"
    /// Seconds Claude Code gives event hooks. They take milliseconds; this only bounds a hang.
    public static let eventTimeout = 5
    /// Seconds Claude Code gives the permission hook: the 300 s wait plus slack.
    public static let permissionTimeout = 310

    /// Events whose matcher filters by tool name; we register them with `*`.
    static let toolEvents: Set<HookEvent> = [.preToolUse, .postToolUse, .permissionRequest]

    public static let editor = MatcherGroupHooksEditor(
        agent: ClaudeCodeHookAdapter.agentName,
        events: HookEvent.allCases.map {
            .init(name: $0.rawValue, timeout: timeout(for: $0), matchesTools: toolEvents.contains($0))
        }
    )

    /// The command to register for a `liova` binary at `executablePath`.
    public static func command(executablePath: String) -> String {
        editor.command(executablePath: executablePath)
    }

    public static func timeout(for event: HookEvent) -> Int {
        event == .permissionRequest ? permissionTimeout : eventTimeout
    }

    /// Whether `command` runs a `liova` binary's `hook claude-code`.
    public static func isLiovaCommand(_ command: String) -> Bool {
        editor.isLiovaCommand(command)
    }

    public static func installing(
        _ root: OrderedJSON,
        command: String
    ) throws(AgentSettingsShapeError) -> (result: OrderedJSON, changes: [AgentHookChange]) {
        try editor.installing(root, command: command)
    }

    public static func uninstalling(
        _ root: OrderedJSON
    ) throws(AgentSettingsShapeError) -> (result: OrderedJSON, changes: [AgentHookChange]) {
        try editor.uninstalling(root)
    }

    public static func status(_ root: OrderedJSON, expectedCommand: String) -> AgentHookStatus {
        editor.status(root, expectedCommand: expectedCommand)
    }
}
