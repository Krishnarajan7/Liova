import IOKit.ps
@testable import LiovaProviders
import Testing

@MainActor
struct PowerSourceParsingTests {
    private func description(
        current: Int = 76,
        max: Int = 100,
        state: String = kIOPSBatteryPowerValue,
        charging: Bool = false,
        charged: Bool = false,
        toEmpty: Int? = 240,
        toFull: Int? = nil
    ) -> [String: Any] {
        var info: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: current,
            kIOPSMaxCapacityKey: max,
            kIOPSPowerSourceStateKey: state,
            kIOPSIsChargingKey: charging,
            kIOPSIsChargedKey: charged,
        ]
        info[kIOPSTimeToEmptyKey] = toEmpty
        info[kIOPSTimeToFullChargeKey] = toFull
        return info
    }

    @Test func onBattery() {
        let snapshot = IOKitPowerSource.parse(description(), lowPower: false)
        #expect(snapshot.hasBattery)
        #expect(snapshot.percentage == 76)
        #expect(!snapshot.isPluggedIn)
        #expect(snapshot.minutesRemaining == 240)
    }

    @Test func chargingUsesTimeToFull() {
        let snapshot = IOKitPowerSource.parse(
            description(state: kIOPSACPowerValue, charging: true, toEmpty: nil, toFull: 45),
            lowPower: false
        )
        #expect(snapshot.isPluggedIn)
        #expect(snapshot.isCharging)
        #expect(snapshot.minutesRemaining == 45)
    }

    @Test func unknownEstimateIsNil() {
        // IOKit reports -1 while it is still calculating.
        let snapshot = IOKitPowerSource.parse(description(toEmpty: -1), lowPower: false)
        #expect(snapshot.minutesRemaining == nil)
    }

    @Test func nonPercentCapacityIsNormalized() {
        let snapshot = IOKitPowerSource.parse(description(current: 4000, max: 5000), lowPower: false)
        #expect(snapshot.percentage == 80)
    }

    @Test func pluggedInAtHundredIsFullyCharged() {
        let snapshot = IOKitPowerSource.parse(
            description(current: 100, state: kIOPSACPowerValue, toEmpty: nil),
            lowPower: false
        )
        #expect(snapshot.isFullyCharged)
    }

    @Test func zeroMaxCapacityDoesNotCrash() {
        let snapshot = IOKitPowerSource.parse(description(current: 0, max: 0), lowPower: true)
        #expect(snapshot.percentage == 0)
        #expect(snapshot.isLowPowerMode)
    }

    @Test func readsThisMacWithoutCrashing() {
        let snapshot = IOKitPowerSource.read()
        #expect((0 ... 100).contains(snapshot.percentage))
    }
}
