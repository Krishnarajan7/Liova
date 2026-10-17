import Darwin
import Foundation

/// Why the installer couldn't read or change a settings file.
public enum AgentInstallerError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The file exists but isn't valid JSON. It is left untouched.
    case invalidJSON(path: String, detail: String)
    /// The JSON doesn't have the shape Claude Code uses (e.g. `hooks` isn't an object).
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

/// A computed change to a settings file, ready to show (`--dry-run`) or ``ClaudeCodeHookInstaller/apply(_:now:)``.
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

/// What ``ClaudeCodeHookInstaller/apply(_:now:)`` did.
public struct AgentInstallResult: Equatable, Sendable {
    public var written: Bool
    /// Copy of the previous file, if there was one and it was changed.
    public var backupURL: URL?
}

/// Installs and removes Liova's Claude Code hooks in a `settings.json`.
///
/// Safe by construction: unknown keys and other hooks are kept, an invalid file is never
/// overwritten, the previous file is backed up before every write, and the write is atomic
/// (temporary file plus rename) with the original permissions. A symlinked settings file
/// (common with dotfile managers) is edited at its target, so the link survives.
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
        URL(fileURLWithPath: homeDirectory ?? IPCPaths.realHomeDirectory, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    /// The hook command for ``executablePath``.
    public var command: String {
        ClaudeCodeSettingsEditor.command(executablePath: executablePath)
    }

    // MARK: Planning

    public func plan(_ operation: AgentInstallPlan.Operation) throws(AgentInstallerError) -> AgentInstallPlan {
        let target = Self.resolvingSymlinks(settingsURL)
        let path = target.path(percentEncoded: false)
        let original = try Self.read(target)
        let root = try Self.parse(original, path: path)
        let edited: (result: OrderedJSON, changes: [AgentHookChange])
        do {
            switch operation {
            case .install: edited = try ClaudeCodeSettingsEditor.installing(root, command: command)
            case .uninstall: edited = try ClaudeCodeSettingsEditor.uninstalling(root)
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

    /// Whether the hooks are installed and current.
    public func status() throws(AgentInstallerError) -> AgentHookStatus {
        let target = Self.resolvingSymlinks(settingsURL)
        let root = try Self.parse(Self.read(target), path: target.path(percentEncoded: false))
        return ClaudeCodeSettingsEditor.status(root, expectedCommand: command)
    }

    // MARK: Writing

    /// Writes the plan: backup, then an atomic replace. Does nothing if nothing changed.
    @discardableResult
    public func apply(_ plan: AgentInstallPlan, now: Date = Date()) throws(AgentInstallerError) -> AgentInstallResult {
        guard plan.needsWrite else { return AgentInstallResult(written: false, backupURL: nil) }
        let target = plan.targetURL
        let path = target.path(percentEncoded: false)
        let directory = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .writeFailed(path: path, detail: error.localizedDescription)
        }
        // Refuse to clobber edits made since the plan was computed (e.g. by Claude Code itself).
        guard try Self.read(target) == plan.original else { throw .changedConcurrently(path: path) }

        var mode: mode_t = 0o600
        var backupURL: URL?
        if let original = plan.original {
            var info = stat()
            if stat(path, &info) == 0 {
                mode = info.st_mode & 0o7777
            }
            backupURL = try Self.writeBackup(of: original, beside: target, mode: mode, now: now)
        }
        try Self.atomicWrite(Data(plan.newContents.utf8), to: target, mode: mode)
        return AgentInstallResult(written: true, backupURL: backupURL)
    }

    /// The backup file name for a settings file, e.g. `settings.json.liova-backup-20261018-142501`.
    public static func backupName(for fileName: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(fileName).liova-backup-\(formatter.string(from: date))"
    }

    private static func writeBackup(
        of data: Data,
        beside target: URL,
        mode: mode_t,
        now: Date
    ) throws(AgentInstallerError) -> URL {
        let base = backupName(for: target.lastPathComponent, at: now)
        let directory = target.deletingLastPathComponent()
        for attempt in 0 ..< 100 {
            let name = attempt == 0 ? base : "\(base)-\(attempt + 1)"
            let url = directory.appendingPathComponent(name, isDirectory: false)
            // O_EXCL: never overwrite an earlier backup.
            let fd = open(url.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode & 0o777)
            if fd < 0 {
                if errno == EEXIST {
                    continue
                }
                throw .writeFailed(path: url.path(percentEncoded: false), detail: SystemCallError("open").description)
            }
            defer { close(fd) }
            try writeAll(data, to: fd, path: url.path(percentEncoded: false))
            return url
        }
        throw .writeFailed(path: target.path(percentEncoded: false), detail: "Too many backups with the same name.")
    }

    private static func atomicWrite(_ data: Data, to target: URL, mode: mode_t) throws(AgentInstallerError) {
        let path = target.path(percentEncoded: false)
        let directory = target.deletingLastPathComponent().path(percentEncoded: false)
        var template = Array("\(directory)/.\(target.lastPathComponent).liova-XXXXXX".utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress) }
        guard fd >= 0 else { throw .writeFailed(path: path, detail: SystemCallError("mkstemp").description) }
        let temporaryPath = AgentExecutable.string(fromNulTerminated: template)
        var succeeded = false
        defer {
            if !succeeded {
                unlink(temporaryPath)
            }
        }
        do {
            defer { close(fd) }
            try writeAll(data, to: fd, path: path)
            guard fchmod(fd, mode) == 0 else {
                throw AgentInstallerError.writeFailed(path: path, detail: SystemCallError("fchmod").description)
            }
            guard fsync(fd) == 0 else {
                throw AgentInstallerError.writeFailed(path: path, detail: SystemCallError("fsync").description)
            }
        }
        guard rename(temporaryPath, path) == 0 else {
            throw .writeFailed(path: path, detail: SystemCallError("rename").description)
        }
        succeeded = true
    }

    private static func writeAll(_ data: Data, to fd: Int32, path: String) throws(AgentInstallerError) {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                throw .writeFailed(path: path, detail: SystemCallError("write").description)
            }
        }
    }

    // MARK: Reading

    /// The file's contents, or `nil` if it doesn't exist.
    static func read(_ url: URL) throws(AgentInstallerError) -> Data? {
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        guard !isDirectory.boolValue else { throw .unreadable(path: path, detail: "It is a directory.") }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw .unreadable(path: path, detail: error.localizedDescription)
        }
    }

    /// Parses a settings file. A missing or blank file is an empty object.
    static func parse(_ data: Data?, path: String) throws(AgentInstallerError) -> OrderedJSON {
        guard let data else { return .object([]) }
        let isBlank = data.allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) }
            || data == Data([0xEF, 0xBB, 0xBF])
        if isBlank {
            return .object([])
        }
        let root: OrderedJSON
        do {
            root = try OrderedJSON.parse(data)
        } catch {
            throw .invalidJSON(path: path, detail: error.description)
        }
        guard root.members != nil else {
            throw .unexpectedShape(path: path, detail: "The top level isn't a JSON object.")
        }
        return root
    }

    /// `url` with a final symlink chain followed (relative links resolve against their
    /// directory). A dangling link resolves to its missing target, which will be created.
    static func resolvingSymlinks(_ url: URL) -> URL {
        var current = url.standardizedFileURL
        for _ in 0 ..< 32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(
                atPath: current.path(percentEncoded: false)
            ) else { return current }
            current = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination)
            current = current.standardizedFileURL
        }
        return current
    }
}
