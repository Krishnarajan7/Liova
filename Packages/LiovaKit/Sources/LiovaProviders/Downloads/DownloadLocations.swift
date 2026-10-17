import Foundation

/// The only folders the download sources look at.
public enum DownloadLocations {
    /// Telegram for macOS' shared container (App Store and direct builds share it).
    static let telegramContainer = "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram"

    /// The user's real home from the password database, so `HOME` overrides don't matter.
    public static var homeDirectory: String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            let path = String(cString: directory)
            if !path.isEmpty {
                return path
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    public static func downloadsDirectory(home: String = homeDirectory) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Downloads", isDirectory: true)
    }

    /// `~/Downloads`, plus each Telegram account's `postbox/media` folder when
    /// `includeTelegram` is on and they exist.
    ///
    /// Telegram's folders are found by listing directory names only, two levels deep
    /// (`<build>/account-<id>/postbox/media`); nothing else in the container is touched.
    /// Listing another app's container can make macOS ask the user for permission (and block
    /// the calling thread while it does), so callers run this off the main thread and only
    /// when the user turned Telegram downloads on.
    public static func partialFileRoots(
        home: String = homeDirectory,
        includeTelegram: Bool = true
    ) -> [PartialFileDownloadSource.Root] {
        var roots: [PartialFileDownloadSource.Root] = []
        let downloads = downloadsDirectory(home: home).path
        if isDirectory(downloads) {
            roots.append(.init(path: downloads, kind: .downloads))
        }
        guard includeTelegram else { return roots }
        let container = (home as NSString).appendingPathComponent(telegramContainer)
        for media in telegramMediaDirectories(container: container) {
            roots.append(.init(path: media, kind: .telegramMedia))
        }
        return roots
    }

    static func telegramMediaDirectories(container: String) -> [String] {
        guard isDirectory(container) else { return [] }
        let manager = FileManager.default
        var result: [String] = []
        for build in (try? manager.contentsOfDirectory(atPath: container)) ?? [] where !build.hasPrefix(".") {
            let buildPath = (container as NSString).appendingPathComponent(build)
            guard isDirectory(buildPath) else { continue }
            for account in (try? manager.contentsOfDirectory(atPath: buildPath)) ?? []
                where account.hasPrefix("account-")
            {
                let media = (buildPath as NSString).appendingPathComponent("\(account)/postbox/media")
                if isDirectory(media) {
                    result.append(media)
                }
            }
        }
        return result.sorted()
    }

    /// The canonical path of an existing directory (`/var/…` → `/private/var/…`), matching
    /// what FSEvents reports. `nil` if it isn't a directory.
    static func resolvedDirectory(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        return isDirectory(canonical) ? canonical : nil
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
