import Darwin
import Foundation
import LiovaCore
import LiovaPluginKit
import LiovaProviders
import Observation

/// Notices what's heating up the Mac or filling its memory, says which, and offers to quit
/// it from the notch: one heavy app, macOS's own background work (Photos analyzing the
/// library), or several apps that add up with no single one to blame.
///
/// Reads every app's usage once a minute (about a millisecond of work), so it costs nothing
/// noticeable, and only speaks up about steady load: a spike while an app launches or
/// exports is normal, three minutes of most of a core is not.
@MainActor
@Observable
public final class ResourceAlertFeature {
    public private(set) var alert: ResourceAlert?
    public private(set) var quitState = QuitState.running

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let reader: AppUsageReader
    @ObservationIgnored private let quitter: AppQuitter
    @ObservationIgnored private let isRunning: @MainActor (AppUsage) -> Bool
    @ObservationIgnored private let isHot: @Sendable () -> Bool
    @ObservationIgnored private let onBattery: @Sendable () -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let totalMemory: UInt64
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var quitCheck: Task<Void, Never>?
    @ObservationIgnored private var streaks: [String: Int] = [:]
    @ObservationIgnored private var lastAlerted: [String: Date] = [:]
    /// Apps the user said to leave alone, until Liova restarts.
    @ObservationIgnored private var ignored: Set<String> = []

    public init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        reader: AppUsageReader = AppUsageReader(),
        quitter: AppQuitter = .system,
        isRunning: @escaping @MainActor (AppUsage) -> Bool = ResourceAlertFeature.anyProcessRunning,
        // A fanless Mac reports "fair" as soon as it's warm to the touch.
        isHot: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.thermalState != .nominal },
        onBattery: @escaping @Sendable () -> Bool = PowerSnapshot.isOnBattery,
        now: @escaping @Sendable () -> Date = Date.init,
        totalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.totalMemory = totalMemory
        self.engine = engine
        self.settings = settings
        self.reader = reader
        self.quitter = quitter
        self.isRunning = isRunning
        self.isHot = isHot
        self.onBattery = onBattery
        self.now = now
    }

    public func syncWithSettings() {
        guard settings.resourceAlertsEnabled else {
            stop()
            return
        }
        guard task == nil else { return }
        let reader = reader
        let onBattery = onBattery
        task = Task { [weak self] in
            await Task.detached(priority: .utility) { _ = reader.sample() }.value
            while !Task.isCancelled {
                try? await Task.sleep(for: ResourceAlertPolicy.interval, tolerance: .seconds(10))
                guard !Task.isCancelled else { return }
                let (apps, memory, battery) = await Task.detached(priority: .utility) {
                    (reader.sample(), SystemMetricsReader.memoryUsage(), onBattery())
                }.value
                guard let self else { return }
                receive(apps, memoryUsed: memory, hot: isHot(), onBattery: battery)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        streaks = [:]
        endAlert()
    }

    // MARK: - Actions

    public func quit() {
        guard let app = alert?.app, app.canQuit else { return }
        quitter.quit(app)
        quitState = .quitting
        quitCheck?.cancel()
        quitCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppQuitter.patience))
            guard !Task.isCancelled, let self, alert?.app.id == app.id else { return }
            if isRunning(app) {
                quitState = .notResponding
            } else {
                endAlert()
            }
        }
    }

    /// Quits one of the apps adding up to a `.together` alert. The next reading shows
    /// whether that was enough.
    public func quit(_ app: AppUsage) {
        guard app.canQuit else { return }
        quitter.quit(app)
    }

    public func forceQuit() {
        guard let app = alert?.app, app.canQuit else { return }
        quitter.forceQuit(app)
        endAlert()
    }

    /// Leave this app (or, for `.together`, the Mac as a whole) alone until Liova restarts.
    public func ignore() {
        guard let alert else { return }
        ignored.insert(alert.key)
        endAlert()
    }

    // MARK: - Readings

    func receive(_ apps: [AppUsage], memoryUsed: Double, hot: Bool, onBattery: Bool = true) {
        streaks = ResourceAlertPolicy.streaks(streaks, apps: apps, hot: hot)
        let conditions = ResourceAlertPolicy.Conditions(
            hot: hot, memoryUsed: memoryUsed, totalMemory: totalMemory, onBattery: onBattery
        )

        if let current = alert {
            // Waiting on a quit: the check after `patience` decides.
            guard quitState == .running else { return }
            if let still = ResourceAlertPolicy.stillHolds(
                current,
                apps: apps,
                streaks: streaks,
                conditions: conditions
            ) {
                show(still)
            } else {
                // Calmed down or quit.
                endAlert()
            }
            return
        }

        let date = now()
        let next = ResourceAlertPolicy.alert(apps: apps, streaks: streaks, conditions: conditions) { id in
            ignored.contains(id)
                || lastAlerted[id].map { date.timeIntervalSince($0) < ResourceAlertPolicy.cooldown } ?? false
        }
        guard let next else { return }
        lastAlerted[next.key] = date
        show(next)
    }

    private func show(_ new: ResourceAlert) {
        alert = new
        try? engine.start(ResourceAlertPolicy.activity(for: new))
    }

    private func endAlert() {
        quitCheck?.cancel()
        quitCheck = nil
        alert = nil
        quitState = .running
        engine.end(ResourceAlertPolicy.alertID)
    }

    public static func anyProcessRunning(_ app: AppUsage) -> Bool {
        app.pids.contains { kill($0, 0) == 0 }
    }
}
