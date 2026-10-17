import Foundation
import LiovaPluginKit
import LiovaProviders

/// Turns power-state changes into activity changes. Pure, so every rule is unit-tested.
///
/// - Plugging in shows a brief "Charging" activity; unplugging a brief "On Battery".
/// - Reaching full charge while plugged in shows a brief "Fully Charged".
/// - Below the low-battery threshold and unplugged, a persistent "Low Battery"
///   activity stays until the Mac is plugged in or the charge recovers.
public enum BatteryActivityPolicy {
    public enum Action: Equatable, Sendable {
        case start(Activity)
        case end(ActivityID)
    }

    public static let source = "system.battery"
    public static let transientID: ActivityID = "system.battery.transient"
    public static let lowBatteryID: ActivityID = "system.battery.low"

    /// How long brief activities stay on screen.
    public static let transientDuration: TimeInterval = 3

    public static func actions(
        from old: PowerSnapshot?,
        to new: PowerSnapshot,
        lowThreshold: Int,
        now: Date
    ) -> [Action] {
        guard new.hasBattery else {
            return [.end(transientID), .end(lowBatteryID)]
        }
        var actions: [Action] = []

        // Brief feedback only on a real change, never on launch.
        if let old, old.hasBattery {
            if !old.isPluggedIn, new.isPluggedIn {
                actions.append(.start(transient(
                    title: "Charging",
                    snapshot: new,
                    symbol: "bolt.fill",
                    tint: .green,
                    now: now
                )))
            } else if old.isPluggedIn, !new.isPluggedIn {
                actions.append(.start(transient(
                    title: "On Battery",
                    snapshot: new,
                    symbol: batterySymbol(for: new.percentage),
                    tint: tint(for: new, lowThreshold: lowThreshold),
                    now: now
                )))
            } else if new.isPluggedIn, !old.isFullyCharged, new.isFullyCharged {
                actions.append(.start(transient(
                    title: "Fully Charged",
                    snapshot: new,
                    symbol: "battery.100percent.bolt",
                    tint: .green,
                    now: now
                )))
            }
        }

        if !new.isPluggedIn, new.percentage <= lowThreshold {
            actions.append(.start(Activity(
                id: lowBatteryID,
                source: source,
                priority: new.percentage <= lowThreshold / 2 ? .high : .normal,
                title: "Low Battery",
                subtitle: timeDescription(for: new) ?? "\(new.percentage)% remaining",
                symbol: batterySymbol(for: new.percentage),
                progress: Double(new.percentage) / 100,
                tint: tint(for: new, lowThreshold: lowThreshold)
            )))
        } else {
            actions.append(.end(lowBatteryID))
        }
        return actions
    }

    public static func batterySymbol(for percentage: Int) -> String {
        switch percentage {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    /// "1 hr 5 min until full" or "40 min left", when macOS has an estimate.
    public static func timeDescription(for snapshot: PowerSnapshot) -> String? {
        guard let minutes = snapshot.minutesRemaining, !snapshot.isFullyCharged else { return nil }
        let duration = minutes >= 60
            ? "\(minutes / 60) hr" + (minutes % 60 == 0 ? "" : " \(minutes % 60) min")
            : "\(minutes) min"
        return snapshot.isCharging ? "\(duration) until full" : "\(duration) left"
    }

    static func tint(for snapshot: PowerSnapshot, lowThreshold: Int) -> ActivityTint {
        if snapshot.isPluggedIn {
            return .green
        }
        if snapshot.percentage <= lowThreshold / 2 {
            return .red
        }
        if snapshot.percentage <= lowThreshold {
            return .orange
        }
        return snapshot.isLowPowerMode ? .yellow : .gray
    }

    private static func transient(
        title: String,
        snapshot: PowerSnapshot,
        symbol: String,
        tint: ActivityTint,
        now: Date
    ) -> Activity {
        Activity(
            id: transientID,
            source: source,
            priority: .high,
            title: title,
            subtitle: timeDescription(for: snapshot) ?? "\(snapshot.percentage)%",
            symbol: symbol,
            progress: Double(snapshot.percentage) / 100,
            tint: tint,
            expiresAt: now + transientDuration
        )
    }
}
