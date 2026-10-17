import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaProviders
import Testing

@MainActor
final class FakePowerSource: PowerSourceProviding {
    var snapshot: PowerSnapshot
    private var onChange: (@MainActor (PowerSnapshot) -> Void)?
    private(set) var isStarted = false

    init(_ snapshot: PowerSnapshot) {
        self.snapshot = snapshot
    }

    func start(onChange: @escaping @MainActor (PowerSnapshot) -> Void) {
        isStarted = true
        self.onChange = onChange
        onChange(snapshot)
    }

    func stop() {
        isStarted = false
        onChange = nil
    }

    func send(_ snapshot: PowerSnapshot) {
        self.snapshot = snapshot
        onChange?(snapshot)
    }
}

@MainActor
struct BatteryFeatureTests {
    let engine = ActivityEngine()
    let settings: LiovaSettings
    let source = FakePowerSource(PowerSnapshot(hasBattery: true, percentage: 50, isPluggedIn: false, isCharging: false))

    init() throws {
        settings = try LiovaSettings(defaults: #require(UserDefaults(suiteName: "app.liova.tests.\(UUID())")))
    }

    @Test func pluggingInReachesTheEngine() {
        let feature = BatteryFeature(engine: engine, settings: settings, provider: source)
        feature.start()
        #expect(engine.current == nil)
        source.send(PowerSnapshot(hasBattery: true, percentage: 50, isPluggedIn: true, isCharging: true))
        #expect(engine.current?.title == "Charging")
    }

    @Test func disablingInSettingsStopsAndClears() {
        let feature = BatteryFeature(engine: engine, settings: settings, provider: source)
        feature.start()
        source.send(PowerSnapshot(hasBattery: true, percentage: 10, isPluggedIn: false, isCharging: false))
        #expect(engine.current?.title == "Low Battery")
        settings.batteryActivitiesEnabled = false
        feature.syncWithSettings()
        #expect(engine.current == nil)
        #expect(!source.isStarted)
    }
}
