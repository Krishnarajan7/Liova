import Foundation
import LiovaPluginKit

/// One countdown.
public struct NotchTimer: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var label: String
    /// The full length, for progress.
    public var duration: TimeInterval
    /// When it ends, while running.
    public var endDate: Date?
    /// Time left, while paused.
    public var pausedRemaining: TimeInterval?

    public var isPaused: Bool {
        pausedRemaining != nil
    }

    public func remaining(at date: Date) -> TimeInterval {
        if let pausedRemaining {
            return pausedRemaining
        }
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSince(date))
    }

    public init(
        id: UUID = UUID(),
        label: String,
        duration: TimeInterval,
        endDate: Date?,
        pausedRemaining: TimeInterval? = nil
    ) {
        self.id = id
        self.label = label
        self.duration = duration
        self.endDate = endDate
        self.pausedRemaining = pausedRemaining
    }
}

/// Maps timers to activities. Pure, so it's unit-tested.
///
/// A running timer is `.normal` (above music and downloads). A paused one drops to `.low`.
/// Finishing flashes a brief `.high` "Timer done".
public enum TimerPolicy {
    public static let source = "system.timers"
    static let prefix = "system.timers."
    public static let finishedID: ActivityID = "system.timers.done"
    public static let finishedDuration: TimeInterval = 6

    public static func activityID(for id: UUID) -> ActivityID {
        ActivityID(prefix + id.uuidString.lowercased())
    }

    public static func timerID(from activityID: ActivityID) -> UUID? {
        guard activityID.rawValue.hasPrefix(prefix), activityID != finishedID else { return nil }
        return UUID(uuidString: String(activityID.rawValue.dropFirst(prefix.count)))
    }

    public static func activity(for timer: NotchTimer, now: Date) -> Activity {
        let remaining = timer.remaining(at: now)
        return Activity(
            id: activityID(for: timer.id),
            source: source,
            priority: timer.isPaused ? .low : .normal,
            title: timer.label,
            subtitle: timer.isPaused ? "Paused · \(format(remaining))" : nil,
            symbol: timer.isPaused ? "pause.circle.fill" : "timer",
            progress: timer.duration > 0 ? 1 - remaining / timer.duration : nil,
            tint: .orange,
            // Running timers end themselves exactly on time; the feature also schedules the
            // "done" flash and sound for the same moment.
            expiresAt: timer.isPaused ? nil : timer.endDate
        )
    }

    public static func finishedActivity(label: String, now: Date) -> Activity {
        Activity(
            id: finishedID, source: source, priority: .high, title: "\(label) done",
            subtitle: "Time's up", symbol: "bell.fill", tint: .orange,
            expiresAt: now + finishedDuration
        )
    }

    /// "4:05", "1:02:03".
    public static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(
            format: "%d:%02d",
            minutes,
            secs
        )
    }

    /// A friendly default label for a length: "5 min timer", "1 h 30 min timer".
    public static func label(for duration: TimeInterval) -> String {
        let minutes = Int((duration / 60).rounded())
        if minutes < 60 {
            return "\(minutes) min timer"
        }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h timer" : "\(hours) h \(rest) min timer"
    }
}
