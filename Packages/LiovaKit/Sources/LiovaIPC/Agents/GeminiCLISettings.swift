import Foundation

/// Liova's hooks for Gemini CLI, in the `hooks` object of `~/.gemini/settings.json`.
public enum GeminiCLISettings {
    /// Milliseconds Gemini CLI gives each hook (Gemini's unit). They take a few; this only
    /// bounds a hang.
    public static let eventTimeoutMilliseconds = 5000
    /// The handler `name`, so `/hooks disable liova` and `/hooks enable liova` work.
    public static let handlerName = "liova"

    public static let editor = MatcherGroupHooksEditor(
        agent: GeminiCLIHookAdapter.agentName,
        events: GeminiCLIHookAdapter.HookEvent.allCases.map { event in
            .init(
                name: event.rawValue,
                timeout: eventTimeoutMilliseconds,
                matchesTools: event == .beforeTool || event == .afterTool
            )
        },
        handlerName: handlerName
    )

    /// Settings in the same file that stop Liova's hooks from running.
    public static func warnings(_ root: OrderedJSON) -> [String] {
        var warnings: [String] = []
        let config = root["hooksConfig"]
        if config?["enabled"] == .bool(false) {
            warnings.append(
                "Gemini CLI's hooks are turned off (\"hooksConfig\": {\"enabled\": false}). "
                    + "Set it to true for Liova to see Gemini CLI."
            )
        }
        let disabled = config?["disabled"]?.elements?.compactMap(\.stringValue) ?? []
        if disabled.contains(handlerName) || disabled.contains(where: editor.isLiovaCommand) {
            warnings.append("Liova's hooks are disabled in Gemini CLI. Turn them back on with /hooks enable liova.")
        }
        return warnings
    }
}
