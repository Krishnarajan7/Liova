import Foundation
import LiovaCore
import LiovaProviders
import Observation

/// Shows charging, unplugging, full-charge and low-battery activities.
///
/// Its own `@Observable` store, so a battery change re-renders only views that read it.
@MainActor
@Observable
public final class BatteryFeature {
    public private(set) var snapshot: PowerSnapshot?
    public private(set) var isRunning = false

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let provider: any PowerSourceProviding
    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        provider: any PowerSourceProviding,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.engine = engine
        self.settings = settings
        self.provider = provider
        self.now = now
    }

    /// Starts or stops the feature to match settings. Safe to call repeatedly.
    public func syncWithSettings() {
        if settings.batteryActivitiesEnabled {
            start()
        } else {
            stop()
        }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        snapshot = nil
        provider.start { [weak self] snapshot in
            self?.receive(snapshot)
        }
        Log.feature.info("Battery feature started")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        provider.stop()
        engine.endAll(source: BatteryActivityPolicy.source)
        Log.feature.info("Battery feature stopped")
    }

    func receive(_ new: PowerSnapshot) {
        let actions = BatteryActivityPolicy.actions(
            from: snapshot,
            to: new,
            lowThreshold: settings.lowBatteryThreshold,
            now: now()
        )
        snapshot = new
        for action in actions {
            switch action {
            case let .start(activity):
                do {
                    try engine.start(activity)
                } catch {
                    Log.feature.error("Battery activity rejected: \(String(describing: error), privacy: .public)")
                }
            case let .end(id):
                engine.end(id)
            }
        }
    }
}
