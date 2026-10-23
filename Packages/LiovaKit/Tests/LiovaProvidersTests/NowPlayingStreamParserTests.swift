import Foundation
@testable import LiovaProviders
import Testing

private func line(_ json: String) -> Data {
    Data(json.utf8)
}

/// A real first message from the adapter (Spotify), with artwork shortened.
private let fullPayload = line("""
{"type":"data","diff":false,"payload":{"playbackRate":1,"album":"Maryan","elapsedTime":3.977,\
"timestamp":"2026-10-17T18:20:58Z","bundleIdentifier":"com.spotify.client","title":"Nenjae Yezhu",\
"duration":283.12,"artist":"A.R. Rahman","playing":true,"artworkData":"iVBORw0KGgo="}}
""")

struct NowPlayingStreamParserTests {
    @Test func fullPayloadProducesInfo() throws {
        var parser = NowPlayingStreamParser()
        let output = try parser.consume(fullPayload)
        guard case let .info(info?) = output else {
            Issue.record("expected info, got \(output)")
            return
        }
        #expect(info.title == "Nenjae Yezhu")
        #expect(info.artist == "A.R. Rahman")
        #expect(info.bundleIdentifier == "com.spotify.client")
        #expect(info.isPlaying)
        #expect(info.duration == 283.12)
        #expect(info.elapsedTime == 3.977)
        #expect(info.timestamp == Date(timeIntervalSince1970: 1_792_261_258))
        #expect(info.artworkData == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    @Test func diffMergesIntoState() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(fullPayload)
        let output = try parser
            .consume(line(#"{"type":"data","diff":true,"payload":{"playing":false,"playbackRate":0}}"#))
        guard case let .info(info?) = output else {
            Issue.record("expected info")
            return
        }
        #expect(!info.isPlaying)
        #expect(info.title == "Nenjae Yezhu")
        #expect(info.playbackRate == 0)
    }

    @Test func artworkSurvivesDiffsAndIsDecodedOnce() throws {
        var parser = NowPlayingStreamParser()
        let diff = line(#"{"type":"data","diff":true,"payload":{"elapsedTime":9}}"#)
        guard case let .info(first?) = try parser.consume(fullPayload),
              case let .info(second?) = try parser.consume(diff),
              let firstArtwork = first.artworkData, let secondArtwork = second.artworkData
        else {
            Issue.record("expected artwork in both")
            return
        }
        // Same bytes, not a fresh decode: the storage is shared.
        let firstAddress = firstArtwork.withUnsafeBytes { $0.baseAddress }
        let secondAddress = secondArtwork.withUnsafeBytes { $0.baseAddress }
        #expect(firstAddress == secondAddress)
    }

    @Test func fullPayloadWithoutArtworkClearsIt() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(fullPayload)
        let output = try parser.consume(line("""
        {"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","title":"Other"}}
        """))
        guard case let .info(info?) = output else {
            Issue.record("expected info")
            return
        }
        #expect(info.artworkData == nil)
    }

    @Test func fractionalTimestampsParse() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(fullPayload)
        let output = try parser
            .consume(line(#"{"type":"data","diff":true,"payload":{"timestamp":"2026-10-17T18:20:58.500Z"}}"#))
        guard case let .info(info?) = output else {
            Issue.record("expected info")
            return
        }
        #expect(info.timestamp == Date(timeIntervalSince1970: 1_792_261_258.5))
    }

    @Test func nullInDiffRemovesKey() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(fullPayload)
        let output = try parser
            .consume(line(#"{"type":"data","diff":true,"payload":{"artworkData":null,"album":null}}"#))
        guard case let .info(info?) = output else {
            Issue.record("expected info")
            return
        }
        #expect(info.artworkData == nil)
        #expect(info.album == nil)
        #expect(info.artist == "A.R. Rahman")
    }

    @Test func nonDiffReplacesState() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(fullPayload)
        let output = try parser.consume(line("""
        {"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","title":"Other","playing":true}}
        """))
        guard case let .info(info?) = output else {
            Issue.record("expected info")
            return
        }
        #expect(info.album == nil)
        #expect(info.artist == nil)
        #expect(info.bundleIdentifier == "com.apple.Music")
    }

    @Test func emptyPayloadMeansNothingPlaying() throws {
        var parser = NowPlayingStreamParser()
        _ = try parser.consume(fullPayload)
        #expect(try parser.consume(line(#"{"type":"data","diff":false,"payload":{}}"#)) == .info(nil))
    }

    @Test func missingTitleMeansNothingPlaying() throws {
        var parser = NowPlayingStreamParser()
        let output = try parser
            .consume(line(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"x","playing":true}}"#))
        #expect(output == .info(nil))
    }

    @Test func otherMessageTypesAreIgnored() throws {
        var parser = NowPlayingStreamParser()
        #expect(try parser.consume(line(#"{"type":"log","payload":{}}"#)) == .unchanged)
    }

    @Test func garbageThrows() {
        var parser = NowPlayingStreamParser()
        #expect(throws: NowPlayingStreamParser.ParseError.notJSON) { try parser.consume(line("not json")) }
        #expect(throws: NowPlayingStreamParser.ParseError.unexpectedShape) {
            try parser.consume(line(#"{"type":"data","payload":5}"#))
        }
    }
}

struct NowPlayingInfoTests {
    let start = Date(timeIntervalSince1970: 1000)

    @Test func elapsedExtrapolatesWhilePlaying() {
        let info = NowPlayingInfo(
            bundleIdentifier: "x", title: "t", duration: 100, elapsedTime: 10, timestamp: start, isPlaying: true
        )
        #expect(info.elapsed(at: start + 5) == 15)
    }

    @Test func elapsedIsFrozenWhilePaused() {
        let info = NowPlayingInfo(
            bundleIdentifier: "x", title: "t", duration: 100, elapsedTime: 10, timestamp: start,
            playbackRate: 0, isPlaying: false
        )
        #expect(info.elapsed(at: start + 50) == 10)
    }

    @Test func elapsedNeverPassesDuration() {
        let info = NowPlayingInfo(
            bundleIdentifier: "x", title: "t", duration: 100, elapsedTime: 98, timestamp: start, isPlaying: true
        )
        #expect(info.elapsed(at: start + 60) == 100)
    }

    @Test func sameTrackIgnoresPosition() {
        let first = NowPlayingInfo(bundleIdentifier: "x", title: "t", artist: "a", elapsedTime: 1, isPlaying: true)
        var second = first
        second.elapsedTime = 50
        second.isPlaying = false
        #expect(first.isSameTrack(as: second))
        second.title = "u"
        #expect(!first.isSameTrack(as: second))
    }
}
