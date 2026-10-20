import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaProviders
import Testing

/// Answers lookups from a table and counts them.
actor FakeLyricsFetcher: LyricsFetching {
    private(set) var queries: [LyricsQuery] = []
    var answer: LyricsResult
    var fails = false

    init(answer: LyricsResult) {
        self.answer = answer
    }

    func lyrics(for query: LyricsQuery) async throws -> LyricsResult {
        queries.append(query)
        if fails {
            throw URLError(.notConnectedToInternet)
        }
        return answer
    }

    func setFails(_ value: Bool) {
        fails = value
    }
}

@MainActor
struct LyricsFeatureTests {
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    let settings: LiovaSettings
    let clock = Clock()
    let fetcher: FakeLyricsFetcher
    let feature: LyricsFeature
    let synced = SyncedLyrics(lines: [
        .init(time: 0, text: "one"), .init(time: 2, text: "two"), .init(time: 4, text: ""), .init(
            time: 6,
            text: "four"
        ),
    ])

    init() throws {
        settings = try LiovaSettings(defaults: #require(UserDefaults(suiteName: "lyrics.\(UUID())")))
        fetcher = FakeLyricsFetcher(answer: .synced(synced))
        let clock = clock
        feature = LyricsFeature(
            settings: settings, fetcher: fetcher, cache: LyricsCache(directory: nil), now: { clock.now }
        )
    }

    private func song(
        _ title: String = "Yellow", elapsed: TimeInterval = 0, playing: Bool = true, duration: TimeInterval? = 266
    ) -> NowPlayingInfo {
        NowPlayingInfo(
            bundleIdentifier: "com.spotify.client", title: title, artist: "Coldplay", duration: duration,
            elapsedTime: elapsed, timestamp: clock.now, playbackRate: playing ? 1 : 0, isPlaying: playing
        )
    }

    /// Lets the lookup task (debounce included) finish.
    private func settle() async throws {
        try await Task.sleep(for: LyricsFeature.lookupDelay + .milliseconds(300))
    }

    @Test func offByDefaultAndNeverAsks() async throws {
        #expect(!settings.lyricsEnabled)
        feature.update(song())
        try await settle()
        #expect(feature.status == .off)
        #expect(await fetcher.queries.isEmpty)
    }

    @Test func turningOnLooksUpTheSongPlaying() async throws {
        feature.update(song())
        feature.setEnabled(true)
        #expect(feature.status == .loading)
        try await settle()
        #expect(feature.lyrics == synced)
        #expect(await fetcher.queries == [LyricsQuery(title: "Yellow", artist: "Coldplay", duration: 266)])
    }

    @Test func skippingThroughTracksAsksOnlyForTheOneThatStays() async throws {
        settings.lyricsEnabled = true
        feature.update(song("One"))
        feature.update(song("Two"))
        feature.update(song("Three"))
        try await settle()
        #expect(await fetcher.queries.map(\.title) == ["Three"])
    }

    @Test func positionUpdatesDoNotLookUpAgain() async throws {
        settings.lyricsEnabled = true
        feature.update(song())
        try await settle()
        feature.update(song(elapsed: 3))
        feature.update(song(elapsed: 3, playing: false))
        try await settle()
        #expect(await fetcher.queries.count == 1)
    }

    @Test func aSongPlayedAgainComesFromTheCache() async throws {
        settings.lyricsEnabled = true
        feature.update(song("Yellow"))
        try await settle()
        feature.update(song("Fix You"))
        try await settle()
        feature.update(song("Yellow"))
        #expect(feature.status == .loading)
        try await Task.sleep(for: .milliseconds(50)) // no debounce for cache hits
        #expect(feature.lyrics == synced)
        #expect(await fetcher.queries.map(\.title) == ["Yellow", "Fix You"])
    }

    @Test func currentLineFollowsThePosition() async throws {
        settings.lyricsEnabled = true
        feature.update(song(elapsed: 0))
        try await settle()
        feature.update(song(elapsed: 2.5))
        #expect(feature.lineIndex == 1)
        // The line shows a beat early.
        feature.update(song(elapsed: 3.9))
        #expect(feature.lineIndex == 2)
    }

    @Test func linesAdvanceOnTheirOwnWhileShown() async throws {
        settings.lyricsEnabled = true
        let start = Date()
        clock.now = start
        feature.update(song(elapsed: 1.7))
        try await settle()
        // `settle` took real time but the fake clock hasn't moved; move it with real time.
        feature.viewerAppeared()
        #expect(feature.lineIndex == 0)
        clock.now = start + 0.2
        try await Task.sleep(for: .milliseconds(400))
        #expect(feature.lineIndex == 1)
        feature.viewerLeft()
    }

    @Test func noSyncedLyricsIsUnavailable() async throws {
        await fetcher.setAnswerForTest(.unsynced)
        settings.lyricsEnabled = true
        feature.update(song())
        try await settle()
        #expect(feature.status == .unavailable)
        #expect(feature.lyrics == nil)
    }

    @Test func offlineIsUnavailableButNotRemembered() async throws {
        await fetcher.setFails(true)
        settings.lyricsEnabled = true
        feature.update(song())
        try await settle()
        #expect(feature.status == .unavailable)
        await fetcher.setFails(false)
        feature.update(song("Other"))
        feature.update(song())
        try await settle()
        #expect(feature.lyrics == synced)
    }

    @Test func thingsThatAreNotSongsAreSkipped() async throws {
        settings.lyricsEnabled = true
        feature.update(song(duration: nil))
        feature.update(song(duration: 3600 * 2))
        var podcast = song()
        podcast.bundleIdentifier = "com.apple.podcasts"
        feature.update(podcast)
        try await settle()
        #expect(feature.status == .idle)
        #expect(await fetcher.queries.isEmpty)
    }

    @Test func turningOffClears() async throws {
        settings.lyricsEnabled = true
        feature.update(song())
        try await settle()
        feature.setEnabled(false)
        #expect(feature.status == .off)
        #expect(feature.lyrics == nil)
        #expect(!settings.lyricsEnabled)
    }
}

extension FakeLyricsFetcher {
    func setAnswerForTest(_ result: LyricsResult) {
        answer = result
    }
}
