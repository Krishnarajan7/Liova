import Foundation
import LiovaPluginKit
import LiovaProviders

/// When headphones get a moment in the notch, and what it says. Pure, so it's unit-tested.
///
/// - Connecting shows the headphones with their battery for a few seconds. Battery often
///   arrives a moment after the connection; the same activity then fills it in, keeping
///   its original deadline.
/// - Disconnecting (unplugging, or turning them off) shows them leaving, briefly.
/// - Low battery alerts once when the lower bud (or the single level) reaches
///   `lowThreshold`, and not again until it has charged past `rearmThreshold`, so a level
///   bouncing between 10% and 11% never nags.
public enum HeadphonesPolicy {
    public static let source = "system.headphones"
    public static let connectedID: ActivityID = "system.headphones.connected"
    public static let lowBatteryID: ActivityID = "system.headphones.low"
    public static let disconnectedID: ActivityID = "system.headphones.disconnected"
    public static let pageID = "headphones"

    public static let connectedDuration: TimeInterval = 4
    public static let lowBatteryDuration: TimeInterval = 5
    public static let disconnectedDuration: TimeInterval = 2.5
    public static let lowThreshold = 10
    public static let rearmThreshold = 20
    /// The level at which battery shows in red.
    public static let warningLevel = 20

    public struct Outcome: Equatable {
        /// Newly connected headphones, in arrival order.
        public var connected: [HeadphonesState] = []
        /// Headphones that just went away, as they were last seen.
        public var disconnected: [HeadphonesState] = []
        /// Headphones whose battery just ran low.
        public var lowBattery: [HeadphonesState] = []
        /// IDs alerted for low battery and not yet re-armed.
        public var alerted: Set<String> = []
    }

    public static func changes(
        from old: [HeadphonesState],
        to new: [HeadphonesState],
        alerted: Set<String>
    ) -> Outcome {
        let oldIDs = Set(old.map(\.id))
        let newIDs = Set(new.map(\.id))
        var outcome = Outcome()
        outcome.disconnected = old.filter { !newIDs.contains($0.id) }
        // Disconnecting forgets the alert; reconnecting low shows red in the connect card.
        var alerted = alerted.intersection(new.map(\.id))
        for device in new {
            let isNew = !oldIDs.contains(device.id)
            if isNew {
                outcome.connected.append(device)
            }
            guard let level = device.battery.lowest else { continue }
            if alerted.contains(device.id) {
                if level >= rearmThreshold {
                    alerted.remove(device.id)
                }
            } else if level <= lowThreshold {
                alerted.insert(device.id)
                if !isNew {
                    outcome.lowBattery.append(device)
                }
            }
        }
        outcome.alerted = alerted
        return outcome
    }

    public static func connectedActivity(for device: HeadphonesState, expiresAt: Date) -> Activity {
        Activity(
            id: connectedID,
            source: source,
            priority: .normal,
            title: device.name,
            subtitle: batterySummary(device.battery) ?? (device.isWired ? "Wired" : "Connected"),
            symbol: device.kind.symbol,
            progress: progress(device.battery),
            tint: isLow(device.battery) ? .red : .blue,
            expiresAt: expiresAt
        )
    }

    public static func disconnectedActivity(for device: HeadphonesState, now: Date) -> Activity {
        Activity(
            id: disconnectedID,
            source: source,
            priority: .normal,
            title: device.name,
            subtitle: "Disconnected",
            symbol: device.kind.symbol,
            tint: .gray,
            expiresAt: now + disconnectedDuration
        )
    }

    public static func lowBatteryActivity(for device: HeadphonesState, now: Date) -> Activity {
        Activity(
            id: lowBatteryID,
            source: source,
            priority: .high,
            title: "\(device.name) battery low",
            subtitle: batterySummary(device.battery),
            symbol: device.kind.symbol,
            progress: progress(device.battery),
            tint: .red,
            expiresAt: now + lowBatteryDuration
        )
    }

    /// The level that runs out first, as progress, so compact places (the open notch's
    /// header chip, the queue) show one short "78%".
    static func progress(_ battery: HeadphonesState.Battery) -> Double? {
        battery.lowest.map { Double($0) / 100 }
    }

    public static func isLow(_ battery: HeadphonesState.Battery) -> Bool {
        battery.lowest.map { $0 <= warningLevel } ?? false
    }

    /// "L 80%  R 75%  Case 40%", or "60%" for a single level. Nil when nothing is known yet.
    public static func batterySummary(_ battery: HeadphonesState.Battery) -> String? {
        var parts: [String] = []
        if let left = battery.left {
            parts.append("L \(left)%")
        }
        if let right = battery.right {
            parts.append("R \(right)%")
        }
        if let single = battery.single, battery.left == nil, battery.right == nil {
            parts.append("\(single)%")
        }
        if let caseLevel = battery.caseLevel {
            parts.append("Case \(caseLevel)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}
