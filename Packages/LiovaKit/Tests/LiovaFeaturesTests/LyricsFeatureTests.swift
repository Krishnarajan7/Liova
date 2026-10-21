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

    private let scratch = ScratchDefaults()

    init() throws {
        settings = LiovaSettings(defaults: scratch.defaults)
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

    // MARK: - Under the closed notch

    @Test func closedNotchLineFollowsTheSinging() {
        let line = { (position: TimeInterval) in
            LyricsFeature.compactLine(in: synced, at: position, isPlaying: true)
        }
        #expect(line(0.5) == "one")
        #expect(line(2) == "two")
        // A two-second break keeps the strip, with a note.
        #expect(line(4.5) == "♪")
        #expect(line(6.5) == "four")
        // Paused, nothing: the strip folds away.
        #expect(LyricsFeature.compactLine(in: synced, at: 0.5, isPlaying: false) == nil)
    }

    @Test func closedNotchFoldsAwayWhenThereIsNothingToSing() {
        let song = SyncedLyrics(lines: [
            .init(time: 5, text: "first"), .init(time: 8, text: ""), .init(time: 30, text: "back"),
            .init(time: 40, text: ""),
        ])
        let line = { (position: TimeInterval) in
            LyricsFeature.compactLine(in: song, at: position, isPlaying: true)
        }
        #expect(line(1) == nil) // the intro
        #expect(line(9) == nil) // a long solo
        #expect(line(27) == "♪") // …until the singing is about to come back
        #expect(line(31) == "back")
        #expect(line(41) == nil) // an empty last line
        // A last line with words gets its moment, then the outro is music.
        #expect(LyricsFeature.compactLine(in: synced, at: 6 + LyricsFeature.lastLineHold - 0.1, isPlaying: true)
            == "four")
        #expect(LyricsFeature.compactLine(in: synced, at: 6 + LyricsFeature.lastLineHold, isPlaying: true) == nil)
    }

    @Test func nextChangeIncludesTheLastLineRunningOut() {
        #expect(LyricsFeature.nextChange(in: synced, after: 1) == 2)
        #expect(LyricsFeature.nextChange(in: synced, after: -3) == 0)
        #expect(LyricsFeature.nextChange(in: synced, after: 6.5) == 6 + LyricsFeature.lastLineHold)
        #expect(LyricsFeature.nextChange(in: synced, after: 6 + LyricsFeature.lastLineHold) == nil)
    }

    @Test func closedNotchShowsTheLineWhilePlaying() async throws {
        settings.lyricsEnabled = true
        #expect(feature.isShownInClosedNotch)
        feature.update(song(elapsed: 0))
        #expect(!feature.showsCompactLine) // still looking it up
        try await settle()
        #expect(feature.showsCompactLine)
        #expect(feature.compactLine == "one")
        feature.update(song(elapsed: 2.5))
        #expect(feature.compactLine == "two")
        // Pausing folds the strip but keeps the text, so it fades out with its words.
        feature.update(song(elapsed: 2.5, playing: false))
        #expect(!feature.showsCompactLine)
        #expect(feature.compactLine == "two")
        // A new song folds it until its lyrics arrive.
        feature.update(song(elapsed: 2.5))
        #expect(feature.showsCompactLine)
        feature.update(song("Fix You", elapsed: 2.5))
        #expect(!feature.showsCompactLine)
    }

    @Test func closedNotchLineCanBeTurnedOffOnItsOwn() async throws {
        settings.lyricsEnabled = true
        feature.update(song(elapsed: 0.5))
        try await settle()
        #expect(feature.showsCompactLine)
        settings.lyricsInClosedNotch = false
        feature.syncWithSettings()
        #expect(!feature.isShownInClosedNotch)
        #expect(!feature.showsCompactLine)
        #expect(feature.lyrics == synced) // the open notch still has them
        settings.lyricsInClosedNotch = true
        feature.syncWithSettings()
        #expect(feature.showsCompactLine)
        // Turning lyrics off takes the line with it.
        feature.setEnabled(false)
        #expect(!feature.showsCompactLine)
        #expect(!feature.isShownInClosedNotch)
    }

    @Test func closedNotchFoldsOnItsOwnAfterTheLastLine() async throws {
        settings.lyricsEnabled = true
        let start = Date()
        clock.now = start
        // Just before the last line's moment runs out (the line shows `lead` early).
        feature.update(song(elapsed: 6 + LyricsFeature.lastLineHold - LyricsFeature.lead - 0.2))
        try await settle()
        feature.viewerAppeared()
        #expect(feature.showsCompactLine)
        clock.now = start + 0.25
        try await Task.sleep(for: .milliseconds(450))
        #expect(!feature.showsCompactLine)
        feature.viewerLeft()
    }
}

extension FakeLyricsFetcher {
    func setAnswerForTest(_ result: LyricsResult) {
        answer = result
    }
}
