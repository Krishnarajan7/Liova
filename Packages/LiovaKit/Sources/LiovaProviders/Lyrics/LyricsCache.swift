import CryptoKit
import Foundation

/// Lyrics already looked up, so a song is fetched once. In memory for the session and on
/// disk in Liova's Caches folder (which macOS may clear when space runs low).
///
/// "Not found" is remembered too, for a week, so a song lrclib doesn't have isn't asked
/// about every time it plays; network errors aren't remembered. Disk work runs on this
/// actor, never the main thread.
public actor LyricsCache {
    private struct Entry: Codable {
        var result: LyricsResult
        var storedAt: Date
    }

    private var memory: [String: Entry] = [:]
    private var order: [String] = []
    private let directory: URL?
    private let now: @Sendable () -> Date

    static let memoryLimit = 64
    static let notFoundLifetime: TimeInterval = 7 * 24 * 3600

    /// `directory: nil` keeps everything in memory (tests).
    public init(directory: URL? = LyricsCache.defaultDirectory, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    public static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("app.liova.Liova/Lyrics", isDirectory: true)
    }

    public func result(for query: LyricsQuery) -> LyricsResult? {
        let key = query.cacheKey
        let entry = memory[key] ?? readFromDisk(key)
        guard let entry, isFresh(entry) else { return nil }
        remember(entry, for: key)
        return entry.result
    }

    public func store(_ result: LyricsResult, for query: LyricsQuery) {
        let key = query.cacheKey
        let entry = Entry(result: result, storedAt: now())
        remember(entry, for: key)
        writeToDisk(entry, key)
    }

    private func isFresh(_ entry: Entry) -> Bool {
        switch entry.result {
        case .notFound: now().timeIntervalSince(entry.storedAt) < Self.notFoundLifetime
        default: true
        }
    }

    private func remember(_ entry: Entry, for key: String) {
        if memory.updateValue(entry, forKey: key) == nil {
            order.append(key)
        }
        while order.count > Self.memoryLimit {
            memory[order.removeFirst()] = nil
        }
    }

    // MARK: - Disk

    private func fileURL(_ key: String) -> URL? {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(digest).appendingPathExtension("json")
    }

    private func readFromDisk(_ key: String) -> Entry? {
        guard let url = fileURL(key), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func writeToDisk(_ entry: Entry, _ key: String) {
        guard let directory, let url = fileURL(key), let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
