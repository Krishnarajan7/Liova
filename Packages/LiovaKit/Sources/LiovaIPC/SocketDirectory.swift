import Darwin
import Foundation

/// Creates and checks the directory that holds the socket.
///
/// The directory must be a real directory (not a symlink), owned by the current user, and
/// mode `0700`. A directory that is too open is tightened, except the home folder and `/`,
/// which are refused instead. Checks and the `chmod` go through one descriptor opened with
/// `O_NOFOLLOW`, so the directory can't be swapped for a symlink between check and use.
enum SocketDirectory {
    static func prepare(_ rawPath: String) throws(IPCServerError) {
        let path = normalized(rawPath)
        try createIfMissing(path)

        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            guard code == ELOOP || code == ENOTDIR else { throw .system(SystemCallError("open", code: code)) }
            // Darwin reports a symlink as ENOTDIR when O_DIRECTORY is set, so ask lstat.
            var info = stat()
            let isLink = lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
            throw .insecureDirectory(path: path, reason: isLink ? "it is a symbolic link" : "it is not a directory")
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .system(SystemCallError("fstat")) }
        try check(info, path: path)
        guard info.st_mode & 0o077 != 0 else { return }
        try refuseSharedLocations(path)
        guard fchmod(fd, 0o700) == 0 else {
            let failure = SystemCallError("fchmod")
            throw .insecureDirectory(path: path, reason: "couldn't restrict it to mode 0700 (\(failure))")
        }
    }

    private static func normalized(_ path: String) -> String {
        var path = path.isEmpty ? "." : path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func createIfMissing(_ path: String) throws(IPCServerError) {
        var info = stat()
        guard lstat(path, &info) != 0 else { return }
        guard errno == ENOENT else { throw .system(SystemCallError("lstat")) }
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            do {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            } catch {
                throw .cannotCreateDirectory(path: parent, reason: (error as NSError).localizedDescription)
            }
        }
        if mkdir(path, 0o700) != 0, errno != EEXIST {
            throw .cannotCreateDirectory(path: path, reason: String(cString: strerror(errno)))
        }
    }

    private static func check(_ info: stat, path: String) throws(IPCServerError) {
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw .insecureDirectory(path: path, reason: "it is not a directory")
        }
        guard info.st_uid == geteuid() else {
            throw .insecureDirectory(path: path, reason: "it is owned by uid \(info.st_uid), not the current user")
        }
    }

    /// Never tighten the home folder or the root: the socket needs a dedicated directory.
    private static func refuseSharedLocations(_ path: String) throws(IPCServerError) {
        let standardized = (path as NSString).standardizingPath
        let home = (IPCPaths.realHomeDirectory as NSString).standardizingPath
        guard standardized != home, standardized != "/" else {
            throw .insecureDirectory(
                path: path,
                reason: "it is shared with other users; put the socket in a dedicated directory"
            )
        }
    }
}
