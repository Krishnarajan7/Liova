import Foundation

/// A file kept on the Shelf. Liova keeps a reference (a bookmark), never a copy, so the
/// file stays where it is and the Shelf follows it if it's moved or renamed.
public struct ShelfItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var bookmark: Data
    /// Last known location and name, shown if the bookmark can't be resolved.
    public var lastKnownPath: String
    public var addedAt: Date

    public var name: String {
        (lastKnownPath as NSString).lastPathComponent
    }

    public init(id: UUID = UUID(), bookmark: Data, lastKnownPath: String, addedAt: Date) {
        self.id = id
        self.bookmark = bookmark
        self.lastKnownPath = lastKnownPath
        self.addedAt = addedAt
    }
}

/// Saves the Shelf to `~/Library/Application Support/Liova/shelf.json`.
///
/// Writes are atomic and the file holds only bookmarks and paths. Never file contents.
public struct ShelfStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var standard: ShelfStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ShelfStore(fileURL: support.appendingPathComponent("Liova/shelf.json"))
    }

    public func load() -> [ShelfItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ShelfItem].self, from: data)) ?? []
    }

    public func save(_ items: [ShelfItem]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(items).write(to: fileURL, options: .atomic)
    }
}

/// Bookmark helpers, isolated for testing.
public enum ShelfBookmarks {
    public static func make(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The file's current location, or nil if it's gone. `refreshed` is a new bookmark when
    /// the old one went stale (the file moved), so callers can update the stored item.
    public static func resolve(_ item: ShelfItem) -> (url: URL, refreshed: Data?)? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: item.bookmark,
            options: [.withoutUI],
            bookmarkDataIsStale: &stale
        ),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return (url, stale ? make(for: url) : nil)
    }
}
