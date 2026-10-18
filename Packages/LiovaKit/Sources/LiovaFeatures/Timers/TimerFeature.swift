import AppKit
import Foundation
import LiovaCore
import LiovaPluginKit
import Observation

/// Countdown timers you start from the notch.
///
/// Nothing ticks inside Liova while a timer runs: the activity carries its end date (the
/// engine ends it on time), the countdown text is drawn with SwiftUI's timer text, and one
/// task per timer sleeps until it's done to play the sound and flash.
@MainActor
@Observable
public final class TimerFeature {
    public private(set) var timers: [NotchTimer] = []

    public static let pageID = "timers"
    public static let maxTimers = 4
    public static let presets: [TimeInterval] = [60, 5 * 60, 10 * 60, 25 * 60]

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let playSound: @MainActor () -> Void
    @ObservationIgnored private var alarms: [UUID: Task<Void, Never>] = [:]

    public init(
        engine: ActivityEngine,
        now: @escaping @Sendable () -> Date = Date.init,
        playSound: @escaping @MainActor () -> Void = { NSSound(named: "Glass")?.play() }
    ) {
        self.engine = engine
        self.now = now
        self.playSound = playSound
    }

    @discardableResult
    public func start(duration: TimeInterval, label: String? = nil) -> NotchTimer? {
        guard duration >= 1, timers.count < Self.maxTimers else { return nil }
        let timer = NotchTimer(
            label: label ?? TimerPolicy.label(for: duration),
            duration: duration,
            endDate: now() + duration
        )
        timers.append(timer)
        publish(timer)
        scheduleAlarm(for: timer)
        Log.feature.info("Timer started: \(Int(duration))s")
        return timer
    }

    public func pause(_ id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }), !timers[index].isPaused else { return }
        timers[index].pausedRemaining = timers[index].remaining(at: now())
        timers[index].endDate = nil
        alarms.removeValue(forKey: id)?.cancel()
        publish(timers[index])
    }

    public func resume(_ id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }), let remaining = timers[index].pausedRemaining
        else { return }
        timers[index].endDate = now() + remaining
        timers[index].pausedRemaining = nil
        publish(timers[index])
        scheduleAlarm(for: timers[index])
    }

    /// Adds time to a running or paused timer.
    public func extend(_ id: UUID, by seconds: TimeInterval) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[index].duration += seconds
        if let remaining = timers[index].pausedRemaining {
            timers[index].pausedRemaining = remaining + seconds
        } else if let endDate = timers[index].endDate {
            timers[index].endDate = endDate + seconds
            scheduleAlarm(for: timers[index])
        }
        publish(timers[index])
    }

    public func cancel(_ id: UUID) {
        timers.removeAll { $0.id == id }
        alarms.removeValue(forKey: id)?.cancel()
        engine.end(TimerPolicy.activityID(for: id))
    }

    public func timer(_ id: UUID) -> NotchTimer? {
        timers.first { $0.id == id }
    }

    public func stop() {
        alarms.values.forEach { $0.cancel() }
        alarms.removeAll()
        timers.removeAll()
        engine.endAll(source: TimerPolicy.source)
    }

    // MARK: - Internals

    private func publish(_ timer: NotchTimer) {
        do {
            try engine.start(TimerPolicy.activity(for: timer, now: now()))
        } catch {
            Log.feature.error("Timer activity rejected: \(String(describing: error), privacy: .public)")
        }
    }

    private func scheduleAlarm(for timer: NotchTimer) {
        alarms.removeValue(forKey: timer.id)?.cancel()
        guard let endDate = timer.endDate else { return }
        let delay = max(0, endDate.timeIntervalSince(now()))
        alarms[timer.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.finish(timer.id)
        }
    }

    func finish(_ id: UUID) {
        guard let timer = timers.first(where: { $0.id == id }) else { return }
        timers.removeAll { $0.id == id }
        alarms.removeValue(forKey: id)
        engine.end(TimerPolicy.activityID(for: id))
        try? engine.start(TimerPolicy.finishedActivity(label: timer.label, now: now()))
        playSound()
        Log.feature.info("Timer finished")
    }
}
