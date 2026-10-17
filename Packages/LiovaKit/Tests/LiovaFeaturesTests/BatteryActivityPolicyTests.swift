import Foundation
import LiovaFeatures
import LiovaPluginKit
import LiovaProviders
import Testing

private let now = Date(timeIntervalSince1970: 1_000_000)

private func power(_ percentage: Int, plugged: Bool, charged: Bool = false) -> PowerSnapshot {
    PowerSnapshot(
        hasBattery: true,
        percentage: percentage,
        isPluggedIn: plugged,
        isCharging: plugged && !charged,
        isFullyCharged: charged
    )
}

private func started(_ actions: [BatteryActivityPolicy.Action]) -> [Activity] {
    actions.compactMap {
        if case let .start(activity) = $0 {
            activity
        } else {
            nil
        }
    }
}

struct BatteryActivityPolicyTests {
    @Test func launchShowsNoTransientFeedback() {
        let actions = BatteryActivityPolicy.actions(from: nil, to: power(80, plugged: true), lowThreshold: 20, now: now)
        #expect(started(actions).isEmpty)
    }

    @Test func pluggingInShowsBriefChargingActivity() throws {
        let actions = BatteryActivityPolicy.actions(
            from: power(76, plugged: false), to: power(76, plugged: true), lowThreshold: 20, now: now
        )
        let activity = try #require(started(actions).first)
        #expect(activity.title == "Charging")
        #expect(activity.subtitle == "76%")
        #expect(activity.progress == 0.76)
        #expect(activity.expiresAt == now + BatteryActivityPolicy.transientDuration)
        #expect(activity.priority == .high)
    }

    @Test func unpluggingShowsOnBattery() {
        let actions = BatteryActivityPolicy.actions(
            from: power(50, plugged: true), to: power(50, plugged: false), lowThreshold: 20, now: now
        )
        #expect(started(actions).first?.title == "On Battery")
    }

    @Test func reachingFullChargeShowsFullyCharged() {
        let actions = BatteryActivityPolicy.actions(
            from: power(99, plugged: true), to: power(100, plugged: true, charged: true), lowThreshold: 20, now: now
        )
        #expect(started(actions).first?.title == "Fully Charged")
    }

    @Test func percentageTickShowsNothingNew() {
        let actions = BatteryActivityPolicy.actions(
            from: power(60, plugged: false), to: power(59, plugged: false), lowThreshold: 20, now: now
        )
        #expect(started(actions).isEmpty)
        #expect(actions == [.end(BatteryActivityPolicy.lowBatteryID)])
    }

    @Test func lowBatteryIsPersistentAndEscalates() throws {
        let low = try #require(started(BatteryActivityPolicy.actions(
            from: power(21, plugged: false), to: power(20, plugged: false), lowThreshold: 20, now: now
        )).first)
        #expect(low.id == BatteryActivityPolicy.lowBatteryID)
        #expect(low.expiresAt == nil)
        #expect(low.priority == .normal)
        #expect(low.tint == .orange)

        let critical = try #require(started(BatteryActivityPolicy.actions(
            from: power(11, plugged: false), to: power(10, plugged: false), lowThreshold: 20, now: now
        )).first)
        #expect(critical.priority == .high)
        #expect(critical.tint == .red)
    }

    @Test func pluggingInEndsLowBattery() {
        let actions = BatteryActivityPolicy.actions(
            from: power(15, plugged: false), to: power(15, plugged: true), lowThreshold: 20, now: now
        )
        #expect(actions.contains(.end(BatteryActivityPolicy.lowBatteryID)))
    }

    @Test func desktopMacsShowNothing() {
        let actions = BatteryActivityPolicy.actions(from: nil, to: .noBattery, lowThreshold: 20, now: now)
        #expect(started(actions).isEmpty)
    }

    @Test func subtitleShowsTimeRemainingWhenKnown() {
        var snapshot = power(40, plugged: true)
        snapshot.minutesRemaining = 65
        #expect(BatteryActivityPolicy.timeDescription(for: snapshot) == "1 hr 5 min until full")
        snapshot = power(40, plugged: false)
        snapshot.minutesRemaining = 40
        #expect(BatteryActivityPolicy.timeDescription(for: snapshot) == "40 min left")
        snapshot.minutesRemaining = 120
        #expect(BatteryActivityPolicy.timeDescription(for: snapshot) == "2 hr left")
        snapshot.minutesRemaining = nil
        #expect(BatteryActivityPolicy.timeDescription(for: snapshot) == nil)
    }

    @Test(arguments: [
        (0, "battery.0percent"),
        (25, "battery.25percent"),
        (50, "battery.50percent"),
        (80, "battery.75percent"),
        (100, "battery.100percent")
    ])
    func symbolsTrackCharge(percentage: Int, symbol: String) {
        #expect(BatteryActivityPolicy.batterySymbol(for: percentage) == symbol)
    }
}
