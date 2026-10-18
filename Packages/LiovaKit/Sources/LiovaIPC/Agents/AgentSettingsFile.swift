import Darwin
import Foundation

/// Careful reading and writing of an agent's settings file: symlinks followed, invalid files
/// refused, a backup before every write, and atomic replacement with the original permissions.
enum AgentSettingsFile {
    // MARK: Writing

    /// Writes the plan: backup, then an atomic replace. Does nothing if nothing changed.
    @discardableResult
    static func apply(_ plan: AgentInstallPlan, now: Date) throws(AgentInstallerError) -> AgentInstallResult {
        guard plan.needsWrite else { return AgentInstallResult(written: false, backupURL: nil) }
        let target = plan.targetURL
        let path = target.path(percentEncoded: false)
        let directory = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .writeFailed(path: path, detail: error.localizedDescription)
        }
        // Refuse to clobber edits made since the plan was computed (e.g. by the agent itself).
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
    static func backupName(for fileName: String, at date: Date) -> String {
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
