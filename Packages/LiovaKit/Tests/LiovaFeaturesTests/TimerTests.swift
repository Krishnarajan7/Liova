import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaPluginKit
import Testing

/// A clock the tests move by hand.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 3_000_000)
    var now: Date {
        lock.withLock { value }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value += seconds }
    }
}

@MainActor
struct TimerTests {
    let clock = ManualClock()
    let engine: ActivityEngine
    var sounds = 0

    init() {
        let clock = clock
        engine = ActivityEngine(now: { clock.now })
    }

    private func makeFeature(onSound: @escaping @MainActor () -> Void = {}) -> TimerFeature {
        let clock = clock
        return TimerFeature(engine: engine, now: { clock.now }, playSound: onSound)
    }

    @Test func startShowsARunningCountdownAboveMusic() throws {
        let feature = makeFeature()
        let timer = try #require(feature.start(duration: 300))
        let activity = try #require(engine.current)
        #expect(activity.id == TimerPolicy.activityID(for: timer.id))
        #expect(activity.priority == .normal)
        #expect(activity.title == "5 min timer")
        #expect(activity.expiresAt == clock.now + 300)
    }

    @Test func pauseFreezesAndResumeContinues() throws {
        let feature = makeFeature()
        let timer = try #require(feature.start(duration: 120))
        clock.advance(30)
        feature.pause(timer.id)
        #expect(feature.timer(timer.id)?.remaining(at: clock.now + 500) == 90)
        #expect(engine.current?.subtitle == "Paused · 1:30")
        #expect(engine.current?.expiresAt == nil)
        #expect(engine.current?.priority == .low)
        clock.advance(1000)
        feature.resume(timer.id)
        #expect(feature.timer(timer.id)?.endDate == clock.now + 90)
    }

    @Test func extendAddsTime() throws {
        let feature = makeFeature()
        let timer = try #require(feature.start(duration: 60))
        feature.extend(timer.id, by: 60)
        #expect(feature.timer(timer.id)?.endDate == clock.now + 120)
        #expect(feature.timer(timer.id)?.duration == 120)
    }

    @Test func finishingFlashesAndPlaysASound() throws {
        var played = 0
        let feature = makeFeature { played += 1 }
        let timer = try #require(feature.start(duration: 60, label: "Tea"))
        feature.finish(timer.id)
        #expect(feature.timers.isEmpty)
        #expect(engine.current?.id == TimerPolicy.finishedID)
        #expect(engine.current?.title == "Tea done")
        #expect(played == 1)
    }

    @Test func realAlarmFiresOnTime() async throws {
        let engine = ActivityEngine()
        var played = 0
        let feature = TimerFeature(engine: engine, playSound: { played += 1 })
        feature.start(duration: 1)
        for _ in 0 ..< 60 where played == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(played == 1)
        #expect(feature.timers.isEmpty)
    }

    @Test func cancelEndsQuietly() throws {
        var played = 0
        let feature = makeFeature { played += 1 }
        let timer = try #require(feature.start(duration: 60))
        feature.cancel(timer.id)
        #expect(engine.current == nil)
        #expect(played == 0)
    }

    @Test func limitsAndValidation() {
        let feature = makeFeature()
        #expect(feature.start(duration: 0) == nil)
        for _ in 0 ..< TimerFeature.maxTimers {
            #expect(feature.start(duration: 60) != nil)
        }
        #expect(feature.start(duration: 60) == nil)
    }

    @Test(arguments: [(65.0, "1:05"), (3723, "1:02:03"), (0.2, "0:01"), (0, "0:00")])
    func formatting(seconds: Double, text: String) {
        #expect(TimerPolicy.format(seconds) == text)
    }

    @Test(arguments: [(300.0, "5 min timer"), (3600, "1 h timer"), (5400, "1 h 30 min timer")])
    func labels(duration: Double, label: String) {
        #expect(TimerPolicy.label(for: duration) == label)
    }
}
