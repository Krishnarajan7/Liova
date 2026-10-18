import Foundation

/// Why the installer couldn't read or change a settings file.
public enum AgentInstallerError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The file exists but isn't valid JSON. It is left untouched.
    case invalidJSON(path: String, detail: String)
    /// The JSON doesn't have the shape the agent uses (e.g. `hooks` isn't an object).
    case unexpectedShape(path: String, detail: String)
    case unreadable(path: String, detail: String)
    case writeFailed(path: String, detail: String)
    /// Something else changed the file while we were working; nothing was written.
    case changedConcurrently(path: String)

    public var description: String {
        switch self {
        case let .invalidJSON(path, detail):
            "\(path) isn't valid JSON (\(detail)). Fix or move the file, then try again; "
                + "Liova won't overwrite it."
        case let .unexpectedShape(path, detail):
            "Can't safely edit \(path): \(detail) Fix the file by hand, then try again; Liova won't overwrite it."
        case let .unreadable(path, detail):
            "Couldn't read \(path): \(detail)"
        case let .writeFailed(path, detail):
            "Couldn't write \(path): \(detail)"
        case let .changedConcurrently(path):
            "\(path) changed while Liova was updating it, so nothing was written. Run the command again."
        }
    }
}

/// A computed change to a settings file, ready to show (`--dry-run`) or ``AgentHookInstaller/apply(_:now:)``.
public struct AgentInstallPlan: Equatable, Sendable {
    public enum Operation: String, Sendable {
        case install, uninstall
    }

    public var operation: Operation
    /// The file that will be written: the settings path with symlinks resolved.
    public var targetURL: URL
    /// The file's bytes before the change, or `nil` if it doesn't exist.
    public var original: Data?
    /// The full new file contents.
    public var newContents: String
    public var changes: [AgentHookChange]
    /// `false` when the file already says the same thing; nothing will be written.
    public var needsWrite: Bool
    /// The hook command being installed.
    public var command: String
}

/// What ``AgentHookInstaller/apply(_:now:)`` did.
public struct AgentInstallResult: Equatable, Sendable {
    public var written: Bool
    /// Copy of the previous file, if there was one and it was changed.
    public var backupURL: URL?
}
