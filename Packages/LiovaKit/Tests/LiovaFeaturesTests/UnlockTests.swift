import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaPluginKit
import LiovaProviders
import Testing

@MainActor
final class FakeScreenLock: ScreenLockWatching {
    private var onChange: (@MainActor (Bool) -> Void)?
    private(set) var isStarted = false

    func start(onChange: @escaping @MainActor (Bool) -> Void) {
        isStarted = true
        self.onChange = onChange
    }

    func stop() {
        isStarted = false
        onChange = nil
    }

    func send(locked: Bool) {
        onChange?(locked)
    }
}

struct UnlockPolicyTests {
    @Test func awayText() {
        #expect(UnlockPolicy.awayText(59) == nil)
        #expect(UnlockPolicy.awayText(60) == "1m")
        #expect(UnlockPolicy.awayText(42 * 60 + 30) == "42m")
        #expect(UnlockPolicy.awayText(2 * 3600) == "2h")
        #expect(UnlockPolicy.awayText(2 * 3600 + 5 * 60) == "2h 5m")
        #expect(UnlockPolicy.awayText(3 * 86400 + 100) == "3d")
        #expect(UnlockPolicy.awayText(.nan) == nil)
    }
}

@MainActor
struct UnlockFeatureTests {
    let engine = ActivityEngine()
    let monitor = FakeScreenLock()
    let settings: LiovaSettings
    let feature: UnlockFeature
    let clock = TestClock()
    private let scratch = ScratchDefaults()

    final class TestClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    init() {
        settings = LiovaSettings(defaults: scratch.defaults)
        let clock = clock
        feature = UnlockFeature(
            engine: engine, settings: settings, monitor: monitor,
            isAvailable: { true }, now: { clock.now }
        )
    }

    @Test func onByDefault() {
        #expect(settings.unlockAnimationEnabled)
        feature.syncWithSettings()
        #expect(monitor.isStarted)
    }

    @Test func unlockingShowsHowLongYouWereAway() throws {
        feature.syncWithSettings()
        monitor.send(locked: true)
        #expect(engine.current == nil)
        clock.now += 42 * 60
        monitor.send(locked: false)
        let activity = try #require(engine.current)
        #expect(activity.id == UnlockPolicy.activityID)
        #expect(activity.subtitle == "Away 42m")
        #expect(activity.expiresAt == clock.now + UnlockPolicy.duration)
        #expect(abs((feature.lastUnlock?.away ?? 0) - 42 * 60) < 0.001)
    }

    @Test func unlockWithoutASeenLockHasNoTime() throws {
        feature.syncWithSettings()
        monitor.send(locked: false)
        let activity = try #require(engine.current)
        #expect(activity.subtitle == nil)
        #expect(feature.lastUnlock?.lockedAt == nil)
    }

    @Test func lockingAgainEndsTheMoment() {
        feature.syncWithSettings()
        monitor.send(locked: false)
        monitor.send(locked: true)
        #expect(engine.current == nil)
    }

    @Test func turningItOffStopsListening() {
        feature.syncWithSettings()
        monitor.send(locked: false)
        settings.unlockAnimationEnabled = false
        feature.syncWithSettings()
        #expect(!monitor.isStarted)
        #expect(engine.current == nil)
    }

    @Test func offWhileThePreviewIsOff() {
        let hidden = UnlockFeature(engine: engine, settings: settings, monitor: monitor, isAvailable: { false })
        hidden.syncWithSettings()
        #expect(!monitor.isStarted)
    }
}
