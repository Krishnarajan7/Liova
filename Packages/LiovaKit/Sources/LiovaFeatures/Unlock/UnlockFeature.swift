import Foundation
import LiovaCore
import LiovaPluginKit
import LiovaProviders
import Observation

/// A short moment in the notch when the Mac is unlocked: Liova's face wakes up, and says
/// how long you were away.
@MainActor
@Observable
public final class UnlockFeature {
    /// The last unlock, for the views: when the screen locked and how long it stayed locked.
    public private(set) var lastUnlock: Unlock?

    public struct Unlock: Equatable, Sendable {
        /// Nil when Liova didn't see the screen lock (it started while locked).
        public var lockedAt: Date?
        public var unlockedAt: Date

        public var away: TimeInterval? {
            lockedAt.map { unlockedAt.timeIntervalSince($0) }
        }
    }

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let monitor: any ScreenLockWatching
    @ObservationIgnored private let isAvailable: @MainActor () -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var lockedAt: Date?

    public init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        monitor: any ScreenLockWatching = SystemScreenLock(),
        isAvailable: @escaping @MainActor () -> Bool = { PreviewFeature.unlock.isEnabled() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.engine = engine
        self.settings = settings
        self.monitor = monitor
        self.isAvailable = isAvailable
        self.now = now
    }

    public var isEnabled: Bool {
        settings.unlockAnimationEnabled && isAvailable()
    }

    public func syncWithSettings() {
        guard isEnabled else {
            stop()
            return
        }
        guard !isRunning else { return }
        isRunning = true
        monitor.start { [weak self] isLocked in self?.lockChanged(isLocked) }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        monitor.stop()
        lockedAt = nil
        lastUnlock = nil
        engine.endAll(source: UnlockPolicy.source)
    }

    func lockChanged(_ isLocked: Bool) {
        let date = now()
        if isLocked {
            // Locking again before the moment ends: it isn't needed any more.
            lockedAt = lockedAt ?? date
            engine.end(UnlockPolicy.activityID)
            return
        }
        let unlock = Unlock(lockedAt: lockedAt, unlockedAt: date)
        lockedAt = nil
        lastUnlock = unlock
        try? engine.start(UnlockPolicy.activity(for: unlock))
    }
}

public enum UnlockPolicy {
    public static let source = "system.unlock"
    public static let activityID: ActivityID = "system.unlock.welcome"
    public static let duration: TimeInterval = 3.3

    static func activity(for unlock: UnlockFeature.Unlock) -> Activity {
        Activity(
            id: activityID,
            source: source,
            priority: .normal,
            title: "Welcome back",
            subtitle: unlock.away.flatMap(awayText).map { "Away \($0)" },
            symbol: "face.smiling",
            tint: .accent,
            expiresAt: unlock.unlockedAt + duration
        )
    }

    /// "4m", "2h 5m", "3d". Nil under a minute: a quick lock isn't worth a number.
    public static func awayText(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds >= 60 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "\(minutes)m"
        }
        if minutes < 24 * 60 {
            let rest = minutes % 60
            return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
        }
        return "\(minutes / (24 * 60))d"
    }
}
