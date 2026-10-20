import Foundation
@testable import LiovaProviders
import Testing

struct LRCParserTests {
    @Test func basicLines() throws {
        let lyrics = try #require(LRCParser.parse("""
        [ar: Someone]
        [00:12.34] First line
        [00:15.5]Second line
        [01:02.123] Third
        [01:10]
        """))
        #expect(lyrics.lines.map(\.text) == ["First line", "Second line", "Third", ""])
        #expect(lyrics.lines.map(\.time) == [12.34, 15.5, 62.123, 70])
    }

    @Test func severalTimestampsOnOneLine() throws {
        let lyrics = try #require(LRCParser.parse("[00:30.00][00:10.00] Chorus\n[00:20.00] Verse"))
        #expect(lyrics.lines.map(\.text) == ["Chorus", "Verse", "Chorus"])
        #expect(lyrics.lines.map(\.time) == [10, 20, 30])
    }

    @Test func offsetMovesLinesEarlier() throws {
        let lyrics = try #require(LRCParser.parse("[offset:+500]\n[00:10.00] A\n[00:00.20] B"))
        #expect(lyrics.lines.map(\.time) == [0, 9.5])
    }

    @Test func wordStampsAreDropped() throws {
        let lyrics = try #require(LRCParser.parse("[00:01.00] <00:01.00>Hello <00:01.50>world"))
        #expect(lyrics.lines.first?.text == "Hello world")
    }

    @Test func notLRC() {
        #expect(LRCParser.parse("Just plain lyrics\nwith no times") == nil)
        #expect(LRCParser.parse("") == nil)
        #expect(LRCParser.parse("[ti: Title only]") == nil)
    }

    @Test func malformedStampsAreIgnored() throws {
        let lyrics = try #require(LRCParser.parse("[00:75.00] bad\n[xx:10] bad\n[00:05.00] good"))
        #expect(lyrics.lines.map(\.text) == ["good"])
    }

    @Test func windowsLineEndings() throws {
        let lyrics = try #require(LRCParser.parse("[00:01.00] A\r\n[00:02.00] B\r\n"))
        #expect(lyrics.lines.map(\.text) == ["A", "B"])
    }
}

struct SyncedLyricsTests {
    let lyrics = SyncedLyrics(lines: [
        .init(time: 5, text: "a"),
        .init(time: 10, text: "b"),
        .init(time: 15, text: "c"),
    ])

    @Test func lineAtTime() {
        #expect(lyrics.lineIndex(at: 0) == nil)
        #expect(lyrics.lineIndex(at: 5) == 0)
        #expect(lyrics.lineIndex(at: 9.99) == 0)
        #expect(lyrics.lineIndex(at: 10) == 1)
        #expect(lyrics.lineIndex(at: 500) == 2)
    }

    @Test func nextLine() {
        #expect(lyrics.nextLineTime(after: 0) == 5)
        #expect(lyrics.nextLineTime(after: 7) == 10)
        #expect(lyrics.nextLineTime(after: 15) == nil)
    }
}

struct LyricsQueryCleanerTests {
    private func cleaned(_ title: String, by artist: String) -> LyricsQuery {
        LyricsQueryCleaner.clean(LyricsQuery(title: title, artist: artist, duration: 200))
    }

    @Test func videoNoise() {
        #expect(cleaned("Blinding Lights (Official Video)", by: "TheWeekndVEVO").title == "Blinding Lights")
        #expect(cleaned("Blinding Lights (Official Video)", by: "TheWeekndVEVO").artist == "TheWeeknd")
        #expect(cleaned("Song [Lyrics] (HD)", by: "A").title == "Song")
        #expect(cleaned("Song (Remix) (Official Audio)", by: "A").title == "Song (Remix)")
    }

    @Test func artistPrefixedTitles() {
        let query = cleaned("Coldplay - Yellow (Official Video)", by: "Coldplay")
        #expect(query.title == "Yellow")
    }

    @Test func topicChannels() {
        #expect(cleaned("Yellow", by: "Coldplay - Topic").artist == "Coldplay")
    }

    @Test func versionSuffixes() {
        #expect(cleaned("Here Comes the Sun - Remastered 2009", by: "The Beatles").title == "Here Comes the Sun")
        #expect(cleaned("Song - 2011", by: "A").title == "Song")
        // A real dash in the name stays.
        #expect(cleaned("Love - Hate", by: "A").title == "Love - Hate")
    }

    @Test func featuring() {
        #expect(cleaned("Song (feat. Someone)", by: "A").title == "Song")
        #expect(cleaned("Song [ft. Someone]", by: "A").title == "Song")
    }

    @Test func plainTitlesAreUntouched() {
        #expect(cleaned("Nenjae Yezhu", by: "A.R. Rahman") == LyricsQuery(
            title: "Nenjae Yezhu",
            artist: "A.R. Rahman",
            duration: 200
        ))
    }

    @Test func cacheKeyIgnoresCaseAndSpacing() {
        let one = LyricsQuery(title: "Yellow", artist: "Coldplay", duration: 266.4)
        let two = LyricsQuery(title: "yellow ", artist: "COLDPLAY", duration: 266.2)
        #expect(one.cacheKey == two.cacheKey)
        #expect(one.cacheKey != LyricsQuery(title: "Yellow", artist: "Coldplay", duration: 300).cacheKey)
    }
}

struct LRCLibChoiceTests {
    typealias Record = LRCLibClient.Record

    @Test func syncedWins() {
        let records = [
            Record(trackName: "A", duration: 200, plainLyrics: "x"),
            Record(trackName: "A", duration: 201, syncedLyrics: "[00:01.00] x"),
        ]
        let best = LRCLibClient.bestMatch(in: records, for: LyricsQuery(title: "A", artist: "B", duration: 200))
        #expect(best?.syncedLyrics != nil)
    }

    @Test func wrongLengthIsRejected() {
        let records = [Record(trackName: "A", duration: 260, syncedLyrics: "[00:01.00] x")]
        #expect(LRCLibClient.bestMatch(in: records, for: LyricsQuery(title: "A", artist: "B", duration: 200)) == nil)
    }

    @Test func closestLengthAmongSynced() {
        let records = [
            Record(trackName: "far", duration: 202.5, syncedLyrics: "[00:01.00] far"),
            Record(trackName: "near", duration: 200.4, syncedLyrics: "[00:01.00] near"),
        ]
        let best = LRCLibClient.bestMatch(in: records, for: LyricsQuery(title: "A", artist: "B", duration: 200))
        #expect(best?.trackName == "near")
    }

    @Test func results() {
        #expect(LRCLibClient.result(from: Record(instrumental: true)) == .instrumental)
        #expect(LRCLibClient.result(from: Record(plainLyrics: "words")) == .unsynced)
        #expect(LRCLibClient.result(from: Record()) == .notFound)
        if case .synced = LRCLibClient.result(from: Record(syncedLyrics: "[00:01.00] x")) {} else {
            Issue.record("expected synced")
        }
    }

    @Test func decodesLRCLibJSON() throws {
        let json = #"{"id":1,"trackName":"Yellow","artistName":"Coldplay","albumName":"Parachutes","#
            + #""duration":266.0,"instrumental":false,"plainLyrics":"Look at the stars","#
            + #""syncedLyrics":"[00:33.62] Look at the stars"}"#
        let record = try JSONDecoder().decode(Record.self, from: Data(json.utf8))
        #expect(record.trackName == "Yellow")
        #expect(record.duration == 266)
        #expect(record.syncedLyrics == "[00:33.62] Look at the stars")
    }
}

struct LyricsCacheTests {
    let query = LyricsQuery(title: "Yellow", artist: "Coldplay", duration: 266)
    let synced = LyricsResult.synced(SyncedLyrics(lines: [.init(time: 1, text: "x")]))

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @Test func remembersInMemory() async {
        let cache = LyricsCache(directory: nil)
        #expect(await cache.result(for: query) == nil)
        await cache.store(synced, for: query)
        #expect(await cache.result(for: query) == synced)
    }

    @Test func survivesRelaunchOnDisk() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        await LyricsCache(directory: directory).store(synced, for: query)
        #expect(await LyricsCache(directory: directory).result(for: query) == synced)
    }

    @Test func notFoundIsForgottenAfterAWeek() async {
        let clock = Clock()
        let cache = LyricsCache(directory: nil, now: { clock.now })
        await cache.store(.notFound, for: query)
        clock.now += 6 * 24 * 3600
        #expect(await cache.result(for: query) == .notFound)
        clock.now += 2 * 24 * 3600
        #expect(await cache.result(for: query) == nil)
    }
}
