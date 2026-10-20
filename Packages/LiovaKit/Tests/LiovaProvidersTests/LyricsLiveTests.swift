import Foundation
@testable import LiovaProviders
import Testing

/// Talks to the real lrclib.net. Off unless `LIOVA_LIVE_TESTS=1`, so CI never depends on it:
///
///     LIOVA_LIVE_TESTS=1 swift test --filter LyricsLiveTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIOVA_LIVE_TESTS"] == "1"))
struct LyricsLiveTests {
    let client = LRCLibClient()

    @Test func exactMatch() async throws {
        let result = try await client.lyrics(for: LyricsQuery(
            title: "Yellow", artist: "Coldplay", album: "Parachutes", duration: 266
        ))
        guard case let .synced(lyrics) = result else {
            Issue.record("expected synced lyrics, got \(result)")
            return
        }
        #expect(lyrics.lines.count > 20)
        #expect(lyrics.lines.contains { $0.text.lowercased().contains("stars") })
    }

    @Test func webPlayerTitleFindsTheSongBySearch() async throws {
        let result = try await client.lyrics(for: LyricsQuery(
            title: "Coldplay - Yellow (Official Video)", artist: "ColdplayVEVO", duration: 269
        ))
        guard case .synced = result else {
            Issue.record("expected synced lyrics, got \(result)")
            return
        }
    }

    @Test func nonsenseIsNotFound() async throws {
        let result = try await client.lyrics(for: LyricsQuery(
            title: "zzqx no such song 4815162342", artist: "nobody qqq", duration: 200
        ))
        #expect(result == .notFound)
    }
}
