import AppKit
import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaPluginKit
import LiovaProviders
import Testing

private let now = Date(timeIntervalSince1970: 2_000_000)

private func track(_ title: String = "Nenjae Yezhu", playing: Bool = true) -> NowPlayingInfo {
    NowPlayingInfo(
        bundleIdentifier: "com.spotify.client", title: title, artist: "A.R. Rahman",
        duration: 283, elapsedTime: 10, timestamp: now, playbackRate: playing ? 1 : 0, isPlaying: playing
    )
}

struct NowPlayingPolicyTests {
    @Test func playingIsLowPriorityAndPersistent() throws {
        let activity = try #require(NowPlayingPolicy.activity(for: track(), previous: nil, now: now))
        #expect(activity.id == NowPlayingPolicy.activityID)
        #expect(activity.priority == .low)
        #expect(activity.expiresAt == nil)
        #expect(activity.title == "Nenjae Yezhu")
        #expect(activity.subtitle == "A.R. Rahman")
    }

    @Test func pausedExpiresAfterGrace() throws {
        let activity = try #require(NowPlayingPolicy.activity(for: track(playing: false), previous: nil, now: now))
        #expect(activity.expiresAt == now + NowPlayingPolicy.pausedGrace)
    }

    @Test func pausedUpdatesKeepTheOriginalDeadline() throws {
        let first = try #require(NowPlayingPolicy.activity(for: track(playing: false), previous: nil, now: now))
        let later = try #require(NowPlayingPolicy.activity(for: track(playing: false), previous: first, now: now + 60))
        #expect(later.expiresAt == first.expiresAt)
    }

    @Test func newPausedTrackGetsAFreshDeadline() throws {
        let first = try #require(NowPlayingPolicy.activity(for: track(playing: false), previous: nil, now: now))
        let other = try #require(NowPlayingPolicy.activity(
            for: track("Other", playing: false), previous: first, now: now + 60
        ))
        #expect(other.expiresAt == now + 60 + NowPlayingPolicy.pausedGrace)
    }

    @Test func nothingPlayingMeansNoActivity() {
        #expect(NowPlayingPolicy.activity(for: nil, previous: nil, now: now) == nil)
    }

    @Test(arguments: [(0.0, "0:00"), (59.9, "0:59"), (187, "3:07"), (3723, "1:02:03"), (-1, "--:--")])
    func formatting(seconds: Double, text: String) {
        #expect(NowPlayingPolicy.format(seconds) == text)
    }
}

@MainActor
final class FakeNowPlaying: NowPlayingProviding {
    private var onChange: (@MainActor (NowPlayingInfo?) -> Void)?
    private(set) var commands: [NowPlayingCommand] = []
    private(set) var seeks: [TimeInterval] = []
    private(set) var isStarted = false

    func start(onChange: @escaping @MainActor (NowPlayingInfo?) -> Void) {
        isStarted = true
        self.onChange = onChange
    }

    func stop() {
        isStarted = false
        onChange = nil
    }

    func send(_ command: NowPlayingCommand) {
        commands.append(command)
    }

    func seek(to seconds: TimeInterval) {
        seeks.append(seconds)
    }

    func emit(_ info: NowPlayingInfo?) {
        onChange?(info)
    }
}

@MainActor
struct NowPlayingFeatureTests {
    let engine = ActivityEngine(now: { now })
    let provider = FakeNowPlaying()
    let settings: LiovaSettings
    let feature: NowPlayingFeature

    private let scratch = ScratchDefaults()

    init() throws {
        settings = LiovaSettings(defaults: scratch.defaults)
        feature = NowPlayingFeature(engine: engine, settings: settings, provider: provider, now: { now })
    }

    @Test func playingMusicShowsMediaActivity() {
        feature.start()
        provider.emit(track())
        #expect(engine.current?.id == NowPlayingPolicy.activityID)
        #expect(feature.info?.title == "Nenjae Yezhu")
    }

    @Test func otherActivitiesPreemptMusicAndRestoreIt() throws {
        feature.start()
        provider.emit(track())
        try engine.start(Activity(id: "build", source: "cli", title: "Building"))
        #expect(engine.current?.id == "build")
        engine.end("build")
        #expect(engine.current?.id == NowPlayingPolicy.activityID)
    }

    @Test func stoppingPlaybackEndsActivity() {
        feature.start()
        provider.emit(track())
        provider.emit(nil)
        #expect(engine.current == nil)
        #expect(feature.info == nil)
    }

    @Test func togglePlayPauseIsOptimistic() {
        feature.start()
        provider.emit(track())
        feature.togglePlayPause()
        #expect(feature.info?.isPlaying == false)
        #expect(provider.commands == [.togglePlayPause])
        #expect(engine.current?.symbol == "pause.fill")
    }

    @Test func seekUsesTrackDuration() {
        feature.start()
        provider.emit(track())
        feature.seek(toFraction: 0.5)
        #expect(provider.seeks == [141.5])
        #expect(feature.info?.elapsedTime == 141.5)
    }

    @Test func disablingInSettingsStopsAndClears() {
        feature.syncWithSettings()
        provider.emit(track())
        settings.nowPlayingEnabled = false
        feature.syncWithSettings()
        #expect(!provider.isStarted)
        #expect(engine.current == nil)
    }

    @Test func missingProviderIsUnavailable() {
        let feature = NowPlayingFeature(engine: engine, settings: settings, provider: nil)
        feature.start()
        #expect(!feature.isAvailable)
        #expect(!feature.isRunning)
    }

    @Test func artworkIsDecodedOffMainAndDownsampled() async throws {
        let png = try #require(Self.makePNG(width: 600, height: 600))
        var info = track()
        info.artworkData = png
        feature.start()
        provider.emit(info)
        for _ in 0 ..< 100 where feature.artwork == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let artwork = try #require(feature.artwork)
        #expect(max(artwork.size.width, artwork.size.height) <= CGFloat(NowPlayingFeature.artworkPixelSize))
    }

    static func makePNG(width: Int, height: Int) -> Data? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}
