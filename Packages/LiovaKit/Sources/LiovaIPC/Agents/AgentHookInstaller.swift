import Foundation

/// Installs and removes Liova's hooks in one agent's configuration file.
///
/// Safe by construction: unknown keys and other hooks are kept, an invalid file is never
/// overwritten, the previous file is backed up before every write, and the write is atomic
/// (temporary file plus rename) with the original permissions. A symlinked settings file
/// (common with dotfile managers) is edited at its target, so the link survives.
public struct AgentHookInstaller: Sendable {
    public var agent: AgentKind
    /// The agent's hook configuration file. Inject a temporary path in tests.
    public var settingsURL: URL
    /// Absolute path of the `liova` binary the hooks should run.
    public var executablePath: String

    public init(agent: AgentKind, settingsURL: URL? = nil, executablePath: String) {
        self.agent = agent
        self.settingsURL = settingsURL ?? agent.defaultSettingsURL()
        self.executablePath = executablePath
    }

    /// The hook command for ``executablePath``.
    public var command: String {
        agent.settingsEditor.command(executablePath: executablePath)
    }

    // MARK: Planning

    public func plan(_ operation: AgentInstallPlan.Operation) throws(AgentInstallerError) -> AgentInstallPlan {
        let target = AgentSettingsFile.resolvingSymlinks(settingsURL)
        let path = target.path(percentEncoded: false)
        let original = try AgentSettingsFile.read(target)
        let root = try AgentSettingsFile.parse(original, path: path)
        let editor = agent.settingsEditor
        let edited: (result: OrderedJSON, changes: [AgentHookChange])
        do {
            switch operation {
            case .install: edited = try editor.installing(root, command: command)
            case .uninstall: edited = try editor.uninstalling(root)
            }
        } catch {
            throw .unexpectedShape(path: path, detail: error.message)
        }
        // Compare values, not text, so a differently formatted but unchanged file is left alone.
        let needsWrite = original == nil ? operation == .install : edited.result != root
        return AgentInstallPlan(
            operation: operation,
            targetURL: target,
            original: original,
            newContents: edited.result.prettyPrinted(),
            changes: edited.changes,
            needsWrite: needsWrite,
            command: command
        )
    }

    /// Whether the hooks are installed and current, plus anything that stops them running.
    public func status() throws(AgentInstallerError) -> AgentHookStatus {
        let target = AgentSettingsFile.resolvingSymlinks(settingsURL)
        let root = try AgentSettingsFile.parse(AgentSettingsFile.read(target), path: target.path(percentEncoded: false))
        var status = agent.settingsEditor.status(root, expectedCommand: command)
        status.warnings = warnings(root: root)
        return status
    }

    /// Settings outside Liova's hooks that stop them from running. Never fails: anything that
    /// can't be read is simply not reported.
    public func warnings() -> [String] {
        let target = AgentSettingsFile.resolvingSymlinks(settingsURL)
        let root = (try? AgentSettingsFile.read(target)).flatMap {
            try? AgentSettingsFile.parse($0, path: target.path(percentEncoded: false))
        }
        return warnings(root: root ?? .object([]))
    }

    private func warnings(root: OrderedJSON) -> [String] {
        switch agent {
        case .claudeCode, .cursor:
            return []
        case .geminiCLI:
            return GeminiCLISettings.warnings(root)
        case .codex:
            let config = CodexSettings.configURL(besideHooksAt: AgentSettingsFile.resolvingSymlinks(settingsURL))
            guard let data = try? AgentSettingsFile.read(config), let text = String(data: data, encoding: .utf8)
            else { return [] }
            return CodexSettings.warnings(configTOML: text)
        }
    }

    // MARK: Writing

    /// Writes the plan: backup, then an atomic replace. Does nothing if nothing changed.
    @discardableResult
    public func apply(_ plan: AgentInstallPlan, now: Date = Date()) throws(AgentInstallerError) -> AgentInstallResult {
        try AgentSettingsFile.apply(plan, now: now)
    }

    /// The backup file name for a settings file, e.g. `settings.json.liova-backup-20261018-142501`.
    public static func backupName(for fileName: String, at date: Date) -> String {
        AgentSettingsFile.backupName(for: fileName, at: date)
    }
}
