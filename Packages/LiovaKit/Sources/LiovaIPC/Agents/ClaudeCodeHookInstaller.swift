import Foundation

/// Installs and removes Liova's Claude Code hooks in a `settings.json`. An
/// ``AgentHookInstaller`` for ``AgentKind/claudeCode``.
public struct ClaudeCodeHookInstaller: Sendable {
    /// `settings.json` itself. Inject a temporary path in tests.
    public var settingsURL: URL
    /// Absolute path of the `liova` binary the hooks should run.
    public var executablePath: String

    public init(settingsURL: URL = ClaudeCodeHookInstaller.defaultSettingsURL(), executablePath: String) {
        self.settingsURL = settingsURL
        self.executablePath = executablePath
    }

    /// `~/.claude/settings.json`, with the home directory from the password database.
    public static func defaultSettingsURL(homeDirectory: String? = nil) -> URL {
        AgentKind.claudeCode.defaultSettingsURL(homeDirectory: homeDirectory)
    }

    private var installer: AgentHookInstaller {
        AgentHookInstaller(agent: .claudeCode, settingsURL: settingsURL, executablePath: executablePath)
    }

    /// The hook command for ``executablePath``.
    public var command: String {
        installer.command
    }

    public func plan(_ operation: AgentInstallPlan.Operation) throws(AgentInstallerError) -> AgentInstallPlan {
        try installer.plan(operation)
    }

    /// Whether the hooks are installed and current.
    public func status() throws(AgentInstallerError) -> AgentHookStatus {
        try installer.status()
    }

    /// Writes the plan: backup, then an atomic replace. Does nothing if nothing changed.
    @discardableResult
    public func apply(_ plan: AgentInstallPlan, now: Date = Date()) throws(AgentInstallerError) -> AgentInstallResult {
        try installer.apply(plan, now: now)
    }

    /// The backup file name for a settings file, e.g. `settings.json.liova-backup-20261018-142501`.
    public static func backupName(for fileName: String, at date: Date) -> String {
        AgentSettingsFile.backupName(for: fileName, at: date)
    }
}
