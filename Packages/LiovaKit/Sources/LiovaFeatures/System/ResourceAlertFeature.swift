import Darwin
import Foundation
import LiovaCore
import LiovaPluginKit
import LiovaProviders
import Observation

/// Notices when one app is heating up the Mac or filling its memory, says which, and offers
/// to quit it from the notch.
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
        isHot: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.thermalState.rawValue >= 2 },
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
        self.now = now
    }

    public func syncWithSettings() {
        guard settings.resourceAlertsEnabled else {
            stop()
            return
        }
        guard task == nil else { return }
        let reader = reader
        task = Task { [weak self] in
            await Task.detached(priority: .utility) { _ = reader.sample() }.value
            while !Task.isCancelled {
                try? await Task.sleep(for: ResourceAlertPolicy.interval, tolerance: .seconds(10))
                guard !Task.isCancelled else { return }
                let (apps, memory) = await Task.detached(priority: .utility) {
                    (reader.sample(), SystemMetricsReader.memoryUsage())
                }.value
                guard let self else { return }
                receive(apps, memoryUsed: memory, hot: isHot())
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
        guard let app = alert?.app else { return }
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

    public func forceQuit() {
        guard let app = alert?.app else { return }
        quitter.forceQuit(app)
        endAlert()
    }

    /// Leave this app alone until Liova restarts.
    public func ignore() {
        guard let app = alert?.app else { return }
        ignored.insert(app.id)
        endAlert()
    }

    // MARK: - Readings

    func receive(_ apps: [AppUsage], memoryUsed: Double, hot: Bool) {
        streaks = ResourceAlertPolicy.streaks(streaks, apps: apps, hot: hot)
        let conditions = ResourceAlertPolicy.Conditions(hot: hot, memoryUsed: memoryUsed, totalMemory: totalMemory)

        if let current = alert {
            // Waiting on a quit: the check after `patience` decides.
            guard quitState == .running else { return }
            if let app = apps.first(where: { $0.id == current.app.id }),
               let still = ResourceAlertPolicy.stillHolds(current, app: app, streaks: streaks, conditions: conditions)
            {
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
        lastAlerted[next.app.id] = date
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

/// One app worth telling the user about.
public struct ResourceAlert: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// Busy for this many minutes in a row.
        case cpu(minutes: Int)
        case memory
    }

    public var app: AppUsage
    public var reason: Reason
    /// The Mac itself reports it's running hot.
    public var hot: Bool
    public var totalMemory: UInt64

    public var title: String {
        switch reason {
        case .cpu: "\(app.name) is heating up your Mac"
        case .memory: "\(app.name) is filling your memory"
        }
    }

    /// "145% CPU for 5 min", "Using 6.2 GB of 16 GB".
    public var detail: String {
        switch reason {
        case let .cpu(minutes):
            let usage = "\(AppUsageText.cpu(app.cpu)) CPU"
            return hot ? "\(usage) · your Mac is running hot" : "\(usage) for \(minutes) min, draining battery"
        case .memory:
            let total = Int((Double(totalMemory) / 1_073_741_824).rounded())
            return "Using \(AppUsageText.memory(app.memory)) of \(total) GB"
        }
    }

    /// The short reading for the closed notch.
    public var reading: String {
        switch reason {
        case .cpu: AppUsageText.cpu(app.cpu)
        case .memory: AppUsageText.memory(app.memory)
        }
    }
}

/// When an app is worth an alert. Pure, so it's unit-tested.
public enum ResourceAlertPolicy {
    public static let source = "system.resources"
    public static let alertID: ActivityID = "system.resources.alert"

    static let interval: Duration = .seconds(60)
    /// Most of a core, minute after minute: the fans and the battery feel it.
    static let heavyCPU = 0.8
    static let sustainedMinutes = 3
    /// Once the Mac reports it's hot, less is enough, and sooner.
    static let hotCPU = 0.5
    static let hotMinutes = 1
    /// Memory is only worth mentioning when the Mac is running short, and one app holds a
    /// big part of it.
    static let memoryPressure = 0.85
    static let memoryShare = 0.25
    /// The same app isn't brought up again within this long.
    static let cooldown: TimeInterval = 3600

    struct Conditions {
        var hot: Bool
        var memoryUsed: Double
        var totalMemory: UInt64

        var cpuThreshold: Double {
            hot ? hotCPU : heavyCPU
        }

        var minutesNeeded: Int {
            hot ? hotMinutes : sustainedMinutes
        }

        func holdsMuchMemory(_ app: AppUsage) -> Bool {
            totalMemory > 0 && Double(app.memory) / Double(totalMemory) >= memoryShare
        }
    }

    /// Minutes in a row each app has been busy. An app that calms down starts over.
    static func streaks(_ previous: [String: Int], apps: [AppUsage], hot: Bool) -> [String: Int] {
        let threshold = hot ? hotCPU : heavyCPU
        var next: [String: Int] = [:]
        for app in apps where app.cpu >= threshold {
            next[app.id] = (previous[app.id] ?? 0) + 1
        }
        return next
    }

    /// The busiest app that's been busy long enough; failing that, the biggest memory user
    /// when memory is running short.
    static func alert(
        apps: [AppUsage],
        streaks: [String: Int],
        conditions: Conditions,
        skip: (String) -> Bool
    ) -> ResourceAlert? {
        let busy = apps
            .filter { (streaks[$0.id] ?? 0) >= conditions.minutesNeeded && !skip($0.id) }
            .max { $0.cpu < $1.cpu }
        if let busy {
            return ResourceAlert(
                app: busy, reason: .cpu(minutes: streaks[busy.id] ?? 0), hot: conditions.hot,
                totalMemory: conditions.totalMemory
            )
        }
        guard conditions.memoryUsed >= memoryPressure else { return nil }
        let biggest = apps.filter { conditions.holdsMuchMemory($0) && !skip($0.id) }.max { $0.memory < $1.memory }
        return biggest.map {
            ResourceAlert(app: $0, reason: .memory, hot: conditions.hot, totalMemory: conditions.totalMemory)
        }
    }

    /// The alert with fresh numbers, or nil once the app has calmed down.
    static func stillHolds(
        _ alert: ResourceAlert,
        app: AppUsage,
        streaks: [String: Int],
        conditions: Conditions
    ) -> ResourceAlert? {
        var updated = alert
        updated.app = app
        updated.hot = conditions.hot
        switch alert.reason {
        case .cpu:
            guard let minutes = streaks[app.id] else { return nil }
            updated.reason = .cpu(minutes: minutes)
        case .memory:
            guard conditions.holdsMuchMemory(app) else { return nil }
        }
        return updated
    }

    static func activity(for alert: ResourceAlert) -> Activity {
        let isCPU = if case .cpu = alert.reason {
            true
        } else {
            false
        }
        return Activity(
            id: alertID,
            source: source,
            priority: .normal,
            title: alert.title,
            subtitle: alert.detail,
            symbol: isCPU ? "flame.fill" : "memorychip.fill",
            tint: .orange
        )
    }
}
