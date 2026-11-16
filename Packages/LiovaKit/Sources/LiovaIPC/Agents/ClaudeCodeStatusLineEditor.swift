import Foundation

/// Liova's status line in Claude Code's `settings.json`: how Claude Code's usage reaches
/// the notch.
///
/// Claude Code has one status line. If you already have one, Liova's command takes its
/// place, carries yours along (`--then`, Base64 so no quoting can break it) and runs it, so
/// your status line looks exactly as before; uninstalling puts yours back. If you had none,
/// Liova prints a short one of its own. Everything else in `statusLine` (padding, refresh
/// interval) is left as it is. Pure, so every case is unit-tested.
public enum ClaudeCodeStatusLineEditor {
    static let key = "statusLine"
    static let flag = " --statusline"
    static let thenFlag = " --then "

    /// The command to register: Liova's, then `original` if there was one.
    public static func command(executablePath: String, original: String?) -> String {
        let base = ClaudeCodeSettingsEditor.command(executablePath: executablePath) + flag
        guard let original, !original.isEmpty else { return base }
        return base + thenFlag + Data(original.utf8).base64EncodedString()
    }

    /// Whether `command` is Liova's status line command.
    public static func isLiovaCommand(_ command: String) -> Bool {
        guard let range = command.range(of: flag) else { return false }
        let after = command[range.upperBound...]
        return (after.isEmpty || after.hasPrefix(" "))
            && ClaudeCodeSettingsEditor.isLiovaCommand(String(command[..<range.lowerBound]))
    }

    /// The user's own status line command carried inside Liova's, if any.
    public static func original(in command: String) -> String? {
        guard isLiovaCommand(command), let range = command.range(of: thenFlag) else { return nil }
        return decode(String(command[range.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    /// Decodes a `--then` value. `nil` for anything that isn't Base64 text.
    public static func decode(_ encoded: String?) -> String? {
        guard let encoded, let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }

    public static func isInstalled(_ root: OrderedJSON) -> Bool {
        root[key]?["command"]?.stringValue.map(isLiovaCommand) ?? false
    }

    /// `root` with Liova's status line, wrapping the one already there.
    public static func installing(
        _ root: OrderedJSON, executablePath: String
    ) throws(AgentSettingsShapeError) -> OrderedJSON {
        guard root.members != nil else { throw AgentSettingsShapeError("The settings file isn't a JSON object.") }
        var result = root
        guard var statusLine = root[key], statusLine.members != nil else {
            if let existing = root[key], existing != .null {
                throw AgentSettingsShapeError("'statusLine' isn't a JSON object.")
            }
            result.set(key, .object([
                .init("type", .string("command")),
                .init("command", .string(command(executablePath: executablePath, original: nil))),
            ]))
            return result
        }
        let current = statusLine["command"]?.stringValue
        // Reinstalling keeps the status line Liova already carries, never wraps itself.
        var carried = current
        if let current, isLiovaCommand(current) {
            carried = Self.original(in: current)
        }
        statusLine.set("type", .string("command"))
        statusLine.set("command", .string(command(executablePath: executablePath, original: carried)))
        result.set(key, statusLine)
        return result
    }

    /// `root` without Liova's status line: the user's own comes back, or the key goes.
    public static func uninstalling(_ root: OrderedJSON) -> OrderedJSON {
        guard var statusLine = root[key], let current = statusLine["command"]?.stringValue,
              isLiovaCommand(current)
        else { return root }
        var result = root
        if let carried = original(in: current) {
            statusLine.set("command", .string(carried))
            result.set(key, statusLine)
        } else {
            result.set(key, nil)
        }
        return result
    }
}

/// Reads and writes ``ClaudeCodeStatusLineEditor``'s change in the real settings file, with
/// the same backup and atomic write as the hooks.
public struct ClaudeCodeUsageInstaller: Sendable {
    public var settingsURL: URL
    public var executablePath: String

    public init(settingsURL: URL? = nil, executablePath: String) {
        self.settingsURL = settingsURL ?? AgentKind.claudeCode.defaultSettingsURL()
        self.executablePath = executablePath
    }

    public func isInstalled() throws(AgentInstallerError) -> Bool {
        let target = AgentSettingsFile.resolvingSymlinks(settingsURL)
        let root = try AgentSettingsFile.parse(AgentSettingsFile.read(target), path: target.path(percentEncoded: false))
        return ClaudeCodeStatusLineEditor.isInstalled(root)
    }

    public func plan(_ operation: AgentInstallPlan.Operation) throws(AgentInstallerError) -> AgentInstallPlan {
        let target = AgentSettingsFile.resolvingSymlinks(settingsURL)
        let path = target.path(percentEncoded: false)
        let original = try AgentSettingsFile.read(target)
        let root = try AgentSettingsFile.parse(original, path: path)
        let edited: OrderedJSON
        switch operation {
        case .install:
            do {
                edited = try ClaudeCodeStatusLineEditor.installing(root, executablePath: executablePath)
            } catch {
                throw .unexpectedShape(path: path, detail: error.message)
            }
        case .uninstall:
            edited = ClaudeCodeStatusLineEditor.uninstalling(root)
        }
        return AgentInstallPlan(
            operation: operation,
            targetURL: target,
            original: original,
            newContents: edited.prettyPrinted(),
            changes: [],
            needsWrite: original == nil ? operation == .install : edited != root,
            command: ClaudeCodeStatusLineEditor.command(executablePath: executablePath, original: nil)
        )
    }

    @discardableResult
    public func apply(_ plan: AgentInstallPlan, now: Date = Date()) throws(AgentInstallerError) -> AgentInstallResult {
        try AgentSettingsFile.apply(plan, now: now)
    }
}
