import Foundation

/// Coding agents Liova can hook into.
public enum AgentKind: String, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case geminiCLI = "gemini-cli"
    case cursor

    /// Name for people, e.g. in `liova agents status`.
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .geminiCLI: "Gemini CLI"
        case .cursor: "Cursor"
        }
    }

    /// Whether the agent lets a hook answer its permission prompts, so the user can approve
    /// or deny from the notch. The others show "waiting for you" at most.
    public var supportsApprovals: Bool {
        switch self {
        case .claudeCode, .codex: true
        case .geminiCLI, .cursor: false
        }
    }

    /// The settings file the installer edits by default, relative to the home directory.
    public var defaultSettingsRelativePath: String {
        switch self {
        case .claudeCode: ".claude/settings.json"
        case .codex: ".codex/hooks.json"
        case .geminiCLI: ".gemini/settings.json"
        case .cursor: ".cursor/hooks.json"
        }
    }

    /// The default settings file, with the home directory from the password database.
    public func defaultSettingsURL(homeDirectory: String? = nil) -> URL {
        URL(fileURLWithPath: homeDirectory ?? IPCPaths.realHomeDirectory, isDirectory: true)
            .appendingPathComponent(defaultSettingsRelativePath, isDirectory: false)
    }

    /// The adapter that translates this agent's hook input.
    public func adapter(permissionTimeout: TimeInterval = 300) -> any AgentHookAdapter {
        switch self {
        case .claudeCode: ClaudeCodeHookAdapter(permissionTimeout: permissionTimeout)
        case .codex: CodexHookAdapter(permissionTimeout: permissionTimeout)
        case .geminiCLI: GeminiCLIHookAdapter()
        case .cursor: CursorHookAdapter()
        }
    }

    /// The editor for this agent's hook configuration file.
    public var settingsEditor: any AgentSettingsEditing {
        switch self {
        case .claudeCode: ClaudeCodeSettingsEditor.editor
        case .codex: CodexSettings.editor
        case .geminiCLI: GeminiCLISettings.editor
        case .cursor: CursorHooksEditor()
        }
    }
}
