import Darwin
import Foundation

/// A failed system call, with its `errno`.
public struct SystemCallError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The call that failed, e.g. `bind`.
    public var call: String
    public var code: Int32

    public init(_ call: String, code: Int32 = errno) {
        self.call = call
        self.code = code
    }

    public var description: String {
        "\(call) failed: \(String(cString: strerror(code))) (errno \(code))"
    }
}

/// Small, safe wrappers around the BSD socket calls both sides need.
enum UnixSocket {
    /// `sun_path` is 104 bytes on Darwin, including the terminating NUL.
    static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    enum AddressError: Error {
        case pathTooLong(byteCount: Int)
        case emptyPath
    }

    static func address(for path: String) throws(AddressError) -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty else { throw .emptyPath }
        guard bytes.count <= maxPathBytes else { throw .pathTooLong(byteCount: bytes.count) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// Creates a stream socket with close-on-exec, no SIGPIPE and, optionally, non-blocking I/O.
    static func makeStreamSocket(nonBlocking: Bool) throws(SystemCallError) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SystemCallError("socket") }
        do {
            try configure(fd, nonBlocking: nonBlocking)
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    /// Applies close-on-exec, `SO_NOSIGPIPE` and, optionally, `O_NONBLOCK` to an fd.
    static func configure(_ fd: Int32, nonBlocking: Bool) throws(SystemCallError) {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw SystemCallError("fcntl(F_SETFD)") }
        // Writing to a socket whose peer has gone must return EPIPE, not kill the process.
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SystemCallError("setsockopt(SO_NOSIGPIPE)")
        }
        if nonBlocking {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw SystemCallError("fcntl(O_NONBLOCK)")
            }
        }
    }

    static func bind(_ fd: Int32, to address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func connect(_ fd: Int32, to address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// The peer's process ID, or `nil` if the kernel won't say.
    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return nil }
        return pid
    }

    /// File identity used to make sure we only ever unlink the socket we created.
    struct FileIdentity: Equatable {
        var device: dev_t
        var inode: ino_t
    }

    static func lstatIdentity(_ path: String) -> (identity: FileIdentity, mode: mode_t)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (FileIdentity(device: info.st_dev, inode: info.st_ino), info.st_mode)
    }

    static func isSocket(_ mode: mode_t) -> Bool {
        (mode & S_IFMT) == S_IFSOCK
    }
}
