import Foundation
import os

/// What to look lyrics up by.
public struct LyricsQuery: Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String?
    /// Seconds. lrclib matches within about two seconds of it.
    public var duration: TimeInterval?

    public init(title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    /// The same song, so lookups and the cache treat it as one: case and spacing ignored,
    /// duration to the second.
    public var cacheKey: String {
        let parts = [title, artist].map { $0.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return parts.joined(separator: "\u{1F}") + "\u{1F}" + (duration.map { String(Int($0.rounded())) } ?? "")
    }
}

/// What a lookup found.
public enum LyricsResult: Equatable, Sendable, Codable {
    case synced(SyncedLyrics)
    /// The song has lyrics, but none with timings.
    case unsynced
    case instrumental
    case notFound
}

public protocol LyricsFetching: Sendable {
    func lyrics(for query: LyricsQuery) async throws -> LyricsResult
}

/// lrclib.net, a free, open database of synced lyrics. Sends only the song's title, artist,
/// album and length; no account, no key, nothing about the user.
///
/// Tries an exact match first (`/api/get`, which needs the duration), then a search with
/// cleaned-up names (`/api/search`), picking the result whose length is closest.
public struct LRCLibClient: LyricsFetching {
    private let session: URLSession
    private let base = URL(string: "https://lrclib.net/api/")!
    private static let log = Logger(subsystem: "app.liova.Liova", category: "lyrics")
    /// lrclib asks clients to identify themselves.
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Liova/\(version) (https://github.com/Krishnarajan7/Liova)"
    }()

    /// How far a search result's length may be from the track's and still count.
    static let durationTolerance: TimeInterval = 3

    public init(session: URLSession? = nil) {
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
            configuration.waitsForConnectivity = false
            return URLSession(configuration: configuration)
        }()
    }

    public func lyrics(for query: LyricsQuery) async throws -> LyricsResult {
        if query.duration != nil, let exact = try await get(query) {
            return Self.result(from: exact)
        }
        let cleaned = LyricsQueryCleaner.clean(query)
        let candidates = try await search(cleaned)
        guard let best = Self.bestMatch(in: candidates, for: cleaned) else { return .notFound }
        return Self.result(from: best)
    }

    // MARK: - Requests

    struct Record: Decodable, Equatable {
        var trackName: String?
        var artistName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    private func get(_ query: LyricsQuery) async throws -> Record? {
        var items = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
        ]
        if let album = query.album {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if let duration = query.duration {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        let (data, status) = try await fetch("get", items)
        // A miss comes back as 404 or, when lrclib's own outside lookup fails, 503. Either way
        // there's no exact match, and the search below still has a chance.
        guard status == 200 else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func search(_ query: LyricsQuery) async throws -> [Record] {
        let (data, status) = try await fetch("search", [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
        ])
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode([Record].self, from: data)
    }

    private func fetch(_ path: String, _ items: [URLQueryItem]) async throws -> (Data, Int) {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = items
        let (data, response) = try await session.data(from: components.url!)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - Choosing

    static func result(from record: Record) -> LyricsResult {
        if let synced = record.syncedLyrics.flatMap(LRCParser.parse) {
            return .synced(synced)
        }
        if record.instrumental == true {
            return .instrumental
        }
        if let plain = record.plainLyrics, !plain.isEmpty {
            return .unsynced
        }
        return .notFound
    }

    /// Synced lyrics first, then closest length. Results too far from a known length are out.
    static func bestMatch(in records: [Record], for query: LyricsQuery) -> Record? {
        let usable = records.filter { record in
            guard let duration = query.duration else { return true }
            guard let candidate = record.duration else { return false }
            return abs(candidate - duration) <= durationTolerance
        }
        return usable.min { lhs, rhs in
            let lhsSynced = lhs.syncedLyrics?.isEmpty == false
            let rhsSynced = rhs.syncedLyrics?.isEmpty == false
            if lhsSynced != rhsSynced {
                return lhsSynced
            }
            guard let duration = query.duration else { return false }
            return abs((lhs.duration ?? 0) - duration) < abs((rhs.duration ?? 0) - duration)
        }
    }
}

/// Turns what web players report into what a lyrics database knows: "Song (Official Video)"
/// by "ArtistVEVO" becomes "Song" by "Artist". Pure, so it's unit-tested.
public enum LyricsQueryCleaner {
    /// Bracketed words that mark a version of the video, not part of the song's name.
    private static let noise = [
        "official", "video", "audio", "lyric", "lyrics", "visualizer", "visualiser", "hd", "4k", "mv",
        "music video", "remaster", "remastered", "live", "explicit", "clean", "color coded",
    ]

    public static func clean(_ query: LyricsQuery) -> LyricsQuery {
        var artist = query.artist
        for suffix in [" - Topic", "VEVO", "Vevo", " Official"] where artist.hasSuffix(suffix) {
            artist = String(artist.dropLast(suffix.count))
        }
        var title = stripNoise(query.title)
        // "Artist - Song" titles from video sites.
        let artistPrefix = artist.trimmingCharacters(in: .whitespaces) + " - "
        if title.lowercased().hasPrefix(artistPrefix.lowercased()) {
            title = String(title.dropFirst(artistPrefix.count))
        }
        // "Song - Remastered 2011", "Song - Single Version".
        if let dash = title.range(of: " - "), isNoise(String(title[dash.upperBound...])) {
            title = String(title[..<dash.lowerBound])
        }
        // "(feat. Someone)" isn't in most databases' titles.
        title = removeBracketed(title) { $0.lowercased().hasPrefix("feat") || $0.lowercased().hasPrefix("ft.") }
        return LyricsQuery(
            title: title.trimmingCharacters(in: .whitespaces),
            artist: artist.trimmingCharacters(in: .whitespaces),
            album: query.album,
            duration: query.duration
        )
    }

    private static func stripNoise(_ title: String) -> String {
        removeBracketed(title, where: isNoise)
    }

    private static func isNoise(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return noise.contains { lowered.contains($0) } || lowered
            .range(of: #"^\d{4}$"#, options: .regularExpression) != nil
    }

    /// Removes every `( … )` and `[ … ]` group whose inside matches; keeps the others.
    private static func removeBracketed(_ text: String, where matches: (String) -> Bool) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let close: Character? = character == "(" ? ")" : character == "[" ? "]" : nil
            if let close, let end = text[text.index(after: index)...].firstIndex(of: close) {
                let inside = String(text[text.index(after: index) ..< end])
                if matches(inside) {
                    index = text.index(after: end)
                    continue
                }
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}
