import Darwin
import Foundation

/// Where the tier 1 socket lives.
public enum IPCPaths {
    /// Environment variable that overrides the socket path, for both the app and clients.
    public static let environmentKey = "LIOVA_SOCKET"

    /// Longest socket path, in UTF-8 bytes, that fits in `sockaddr_un.sun_path` (103 on macOS).
    public static var maxSocketPathBytes: Int {
        UnixSocket.maxPathBytes
    }

    /// `~/Library/Application Support/Liova/liova.sock`, or `$LIOVA_SOCKET` when set.
    public static var defaultSocketURL: URL {
        socketURL(environment: ProcessInfo.processInfo.environment)
    }

    /// The socket URL for a given environment. `~` in `LIOVA_SOCKET` is expanded; a relative
    /// path is resolved against the current directory.
    public static func socketURL(environment: [String: String], homeDirectory: String? = nil) -> URL {
        if let override = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            let expanded = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        let home = homeDirectory ?? realHomeDirectory
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Liova", isDirectory: true)
            .appendingPathComponent("liova.sock", isDirectory: false)
    }

    /// The user's real home from the password database, so the app and the CLI agree even if
    /// `HOME` is changed or one of them were ever sandboxed.
    static var realHomeDirectory: String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            let path = String(cString: directory)
            if !path.isEmpty {
                return path
            }
        }
        return NSHomeDirectory()
    }
}
