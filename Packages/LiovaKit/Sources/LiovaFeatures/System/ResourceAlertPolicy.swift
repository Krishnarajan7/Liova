import Foundation
import LiovaPluginKit
import LiovaProviders

/// Something worth telling the user about: one app, or several adding up.
public struct ResourceAlert: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// Busy for this many minutes in a row.
        case cpu(minutes: Int)
        case memory
        /// No one app is to blame, but together they've kept the Mac busy this many minutes.
        case together(minutes: Int)
    }

    /// The app; for `.together`, the biggest part.
    public var app: AppUsage
    public var reason: Reason
    /// The Mac itself reports it's warm (or worse).
    public var hot: Bool
    /// What the load costs then is battery life.
    public var onBattery: Bool
    public var totalMemory: UInt64
    /// For `.together`: what adds up to it, busiest first.
    public var crowd: [AppUsage] = []

    /// What Ignore and the cooldown remember: the app, or the Mac as a whole.
    var key: String {
        if case .together = reason {
            return ResourceAlertPolicy.everything
        }
        return app.id
    }

    public var title: String {
        switch reason {
        case .cpu:
            guard let work = app.work else { return "\(app.name) is heating up your Mac" }
            return "\(work.name) is \(work.activity.prefix(1).lowercased() + work.activity.dropFirst())"
        case .memory: return "\(app.name) is filling your memory"
        case .together: return "Your Mac is working hard"
        }
    }

    /// "145% CPU for 5 min, draining battery", "Using 6.2 GB of 16 GB",
    /// "Simulator 82% · Photos 46% · Chrome 40%".
    public var detail: String {
        switch reason {
        case let .cpu(minutes):
            let usage = "\(AppUsageText.cpu(app.cpu)) CPU"
            if hot {
                return "\(usage) · your Mac is getting warm"
            }
            if app.work != nil {
                return "\(usage) for \(minutes) min · it stops when it's done"
            }
            return "\(usage) for \(minutes) min, \(onBattery ? "draining battery" : "warming your Mac")"
        case .memory:
            let total = Int((Double(totalMemory) / 1_073_741_824).rounded())
            return "Using \(AppUsageText.memory(app.memory)) of \(total) GB"
        case .together:
            return crowd.map { "\($0.name) \(AppUsageText.cpu($0.cpu))" }.joined(separator: " · ")
        }
    }

    /// The short reading for the closed notch.
    public var reading: String {
        switch reason {
        case .cpu: AppUsageText.cpu(app.cpu)
        case .memory: AppUsageText.memory(app.memory)
        case .together: AppUsageText.cpu(crowd.reduce(0) { $0 + $1.cpu })
        }
    }
}

/// When something is worth an alert. Pure, so it's unit-tested.
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
    /// Several apps adding up to a whole core (most of one when it's hot) warm a fanless Mac
    /// as much as one heavy app, with nothing over `heavyCPU` to point at.
    static let togetherCPU = 1.0
    static let hotTogetherCPU = 0.7
    /// Once a streak has started, it lasts while the load stays above this share of what
    /// started it: an app hovering around the line (80%, 75%, 82%) is still busy.
    static let keepShare = 0.6
    /// What counts as a real part of that; the rest is noise.
    static let partCPU = 0.15
    /// The streak and memory key for the Mac as a whole. No app's id looks like it.
    static let everything = "*"
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
        var onBattery = false

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

    /// Minutes in a row each app, and everything together, has been busy. Whatever calms
    /// down starts over; a small dip doesn't (`keepShare`).
    static func streaks(_ previous: [String: Int], apps: [AppUsage], hot: Bool) -> [String: Int] {
        var next: [String: Int] = [:]
        func count(_ key: String, _ cpu: Double, threshold: Double) {
            let started = previous[key] != nil
            guard cpu >= (started ? threshold * keepShare : threshold) else { return }
            next[key] = (previous[key] ?? 0) + 1
        }
        for app in apps {
            count(app.id, app.cpu, threshold: hot ? hotCPU : heavyCPU)
        }
        count(everything, apps.reduce(0) { $0 + $1.cpu }, threshold: hot ? hotTogetherCPU : togetherCPU)
        return next
    }

    /// The busiest app that's been busy long enough; failing that, several adding up;
    /// failing that, the biggest memory user when memory is running short.
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
            return make(busy, .cpu(minutes: streaks[busy.id] ?? 0), conditions)
        }
        if let minutes = streaks[everything], minutes >= conditions.minutesNeeded, !skip(everything),
           case let parts = crowd(apps), parts.count >= 2
        {
            var alert = make(parts[0], .together(minutes: minutes), conditions)
            alert.crowd = parts
            return alert
        }
        guard conditions.memoryUsed >= memoryPressure else { return nil }
        let biggest = apps.filter { conditions.holdsMuchMemory($0) && !skip($0.id) }.max { $0.memory < $1.memory }
        return biggest.map { make($0, .memory, conditions) }
    }

    /// The alert with fresh numbers, or nil once it has calmed down.
    static func stillHolds(
        _ alert: ResourceAlert,
        apps: [AppUsage],
        streaks: [String: Int],
        conditions: Conditions
    ) -> ResourceAlert? {
        var updated = alert
        updated.hot = conditions.hot
        updated.onBattery = conditions.onBattery
        switch alert.reason {
        case .together:
            let parts = crowd(apps)
            guard let minutes = streaks[everything], parts.count >= 2 else { return nil }
            updated.reason = .together(minutes: minutes)
            updated.app = parts[0]
            updated.crowd = parts
        case .cpu:
            guard let app = apps.first(where: { $0.id == alert.app.id }), let minutes = streaks[app.id]
            else { return nil }
            updated.app = app
            updated.reason = .cpu(minutes: minutes)
        case .memory:
            guard let app = apps.first(where: { $0.id == alert.app.id }), conditions.holdsMuchMemory(app)
            else { return nil }
            updated.app = app
        }
        return updated
    }

    /// The real parts of the load, busiest first: the three that explain most of it.
    static func crowd(_ apps: [AppUsage]) -> [AppUsage] {
        Array(apps.filter { $0.cpu >= partCPU }.sorted { $0.cpu > $1.cpu }.prefix(3))
    }

    private static func make(
        _ app: AppUsage,
        _ reason: ResourceAlert.Reason,
        _ conditions: Conditions
    ) -> ResourceAlert {
        ResourceAlert(
            app: app, reason: reason, hot: conditions.hot, onBattery: conditions.onBattery,
            totalMemory: conditions.totalMemory
        )
    }

    static func activity(for alert: ResourceAlert) -> Activity {
        Activity(
            id: alertID,
            source: source,
            priority: .normal,
            title: alert.title,
            subtitle: alert.detail,
            symbol: alert.reason == .memory ? "memorychip.fill" : "flame.fill",
            tint: .orange
        )
    }
}
