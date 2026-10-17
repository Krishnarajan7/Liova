import Foundation
import LiovaCore
import LiovaPluginKit
import Testing

/// A clock tests can move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000_000)

    var now: Date {
        lock.withLock { value }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value += seconds }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var value: Bool {
        lock.withLock { raised }
    }

    func set() {
        lock.withLock { raised = true }
    }
}

private func activity(
    _ id: String,
    source: String = "test",
    priority: ActivityPriority = .normal,
    title: String? = nil,
    expiresAt: Date? = nil
) -> Activity {
    Activity(id: ActivityID(id), source: source, priority: priority, title: title ?? id, expiresAt: expiresAt)
}

@MainActor
struct ActivityEngineTests {
    let clock = TestClock()

    func makeEngine(limits: ActivityEngine.Limits = .init()) -> ActivityEngine {
        let clock = clock
        return ActivityEngine(limits: limits, now: { clock.now })
    }

    @Test func emptyEngineShowsNothing() {
        #expect(makeEngine().current == nil)
    }

    @Test func higherPriorityPreemptsAndRestores() throws {
        let engine = makeEngine()
        try engine.start(activity("music"))
        try engine.start(activity("volume", priority: .critical))
        #expect(engine.current?.id == "volume")
        engine.end("volume")
        #expect(engine.current?.id == "music")
    }

    @Test func lowerPriorityDoesNotPreempt() throws {
        let engine = makeEngine()
        try engine.start(activity("timer", priority: .high))
        try engine.start(activity("download", priority: .low))
        #expect(engine.current?.id == "timer")
        #expect(engine.activities.map(\.id) == ["timer", "download"])
    }

    @Test func newestWinsAmongEqualPriority() throws {
        let engine = makeEngine()
        try engine.start(activity("a"))
        try engine.start(activity("b"))
        #expect(engine.current?.id == "b")
        engine.end("b")
        #expect(engine.current?.id == "a")
    }

    @Test func updatingDoesNotStealFocus() throws {
        let engine = makeEngine()
        try engine.start(activity("build"))
        try engine.start(activity("music"))
        try engine.update("build") { $0.progress = 0.5 }
        #expect(engine.current?.id == "music")
        #expect(engine.activity("build")?.progress == 0.5)
    }

    @Test func restartingSameIDUpdatesInPlace() throws {
        let engine = makeEngine()
        try engine.start(activity("build", title: "Building"))
        try engine.start(activity("build", title: "Testing"))
        #expect(engine.activities.count == 1)
        #expect(engine.current?.title == "Testing")
    }

    @Test func priorityChangeReordersStack() throws {
        let engine = makeEngine()
        try engine.start(activity("agent"))
        try engine.start(activity("music"))
        try engine.update("agent") { $0.priority = .high }
        #expect(engine.current?.id == "agent")
    }

    @Test func updateCannotChangeIdentity() throws {
        let engine = makeEngine()
        try engine.start(activity("a"))
        try engine.update("a") { $0.id = "b" }
        #expect(engine.activity("a") != nil)
        #expect(engine.activity("b") == nil)
    }

    @Test func updateUnknownThrows() {
        let engine = makeEngine()
        #expect(throws: ActivityEngine.Failure.notFound("ghost")) {
            try engine.update("ghost") { $0.title = "boo" }
        }
    }

    @Test func endAllRemovesOnlyThatSource() throws {
        let engine = makeEngine()
        try engine.start(activity("a", source: "cli"))
        try engine.start(activity("b", source: "cli"))
        try engine.start(activity("c", source: "system.battery"))
        engine.endAll(source: "cli")
        #expect(engine.activities.map(\.id) == ["c"])
    }

    @Test func expiredActivityIsRejected() {
        let engine = makeEngine()
        #expect(throws: ActivityEngine.Failure.alreadyExpired) {
            try engine.start(activity("old", expiresAt: clock.now - 1))
        }
    }

    @Test func purgeRemovesExpiredAndRestores() throws {
        let engine = makeEngine()
        try engine.start(activity("music"))
        try engine.start(activity("hud", priority: .critical, expiresAt: clock.now + 1.5))
        #expect(engine.current?.id == "hud")
        clock.advance(2)
        engine.purgeExpired()
        #expect(engine.current?.id == "music")
    }

    @Test func expiryFiresWithoutPolling() async throws {
        let engine = ActivityEngine()
        try engine.start(activity("flash", expiresAt: Date() + 0.05))
        #expect(engine.current != nil)
        for _ in 0 ..< 50 where engine.current != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.current == nil)
    }

    @Test func perSourceLimitIsEnforced() throws {
        let engine = makeEngine(limits: .init(maxActivitiesPerSource: 2, maxActivities: 10))
        try engine.start(activity("1", source: "spammy"))
        try engine.start(activity("2", source: "spammy"))
        #expect(throws: ActivityEngine.Failure.tooManyForSource("spammy")) {
            try engine.start(activity("3", source: "spammy"))
        }
        try engine.start(activity("4", source: "polite"))
        #expect(engine.activities.count == 3)
    }

    @Test func globalLimitIsEnforced() throws {
        let engine = makeEngine(limits: .init(maxActivitiesPerSource: 10, maxActivities: 1))
        try engine.start(activity("1"))
        #expect(throws: ActivityEngine.Failure.tooManyActivities) {
            try engine.start(activity("2", source: "other"))
        }
    }

    @Test func identicalStartDoesNotNotifyObservers() throws {
        let engine = makeEngine()
        try engine.start(activity("a"))
        let notified = Flag()
        withObservationTracking {
            _ = engine.activities
        } onChange: {
            notified.set()
        }
        try engine.start(activity("a"))
        #expect(!notified.value)
    }
}
