import Darwin
import Foundation

/// Where the running `liova` binary lives, for writing hook commands.
public enum AgentExecutable {
    /// The running executable's absolute path with symlinks resolved, or `nil` if the system
    /// won't say.
    public static func currentPath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        guard let resolved = realpath(buffer, nil) else {
            return string(fromNulTerminated: buffer)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Decodes a C string buffer, stopping at the first NUL.
    static func string(fromNulTerminated buffer: [CChar]) -> String {
        buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { String(cString: $0) } ?? ""
        }
    }

    /// Why hooks shouldn't point at `path`, or `nil` if it's a fine place.
    ///
    /// A quarantined app run from Downloads is moved to a random read-only location by
    /// Gatekeeper (App Translocation); that path disappears, and so would the hooks.
    public static func installProblem(for path: String) -> String? {
        if path.contains("/AppTranslocation/") {
            return "Liova is running from a temporary location (macOS App Translocation). "
                + "Move Liova.app to /Applications, open it once, and run this command again."
        }
        return nil
    }

    /// Something worth mentioning about hooks pointing at `path`, or `nil`.
    public static func installWarning(for path: String) -> String? {
        if path.contains("/.build/") {
            return "This is a development build (\(path)). "
                + "The hooks stop working if you delete it or build somewhere else."
        }
        if path.hasPrefix("/Volumes/") {
            return "Liova is on an external volume (\(path)). The hooks only work while it is mounted."
        }
        return nil
    }
}
