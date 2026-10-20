import Foundation
import LiovaCore
import LiovaPluginKit
import LiovaProviders
import Observation

/// AirPods, other Bluetooth headphones and wired ones: a moment in the notch when they
/// connect, a low-battery alert, and a page with each bud's battery and noise control.
@MainActor
@Observable
public final class HeadphonesFeature {
    /// Connected headphones, sorted by name.
    public private(set) var devices: [HeadphonesState] = []
    /// Which headphones each of this feature's activities is about.
    public private(set) var deviceIDByActivity: [ActivityID: String] = [:]
    /// The headphones that last went away, as they were, for the disconnect moment.
    public private(set) var lastDisconnected: HeadphonesState?

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let monitor: any HeadphonesMonitoring
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var alerted: Set<String> = []
    /// The headphones the connect activity is about, and when it ends.
    @ObservationIgnored private var announced: (id: String, expiresAt: Date)?

    public init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        monitor: any HeadphonesMonitoring = CombinedHeadphonesMonitor.standard(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.engine = engine
        self.settings = settings
        self.monitor = monitor
        self.now = now
    }

    public var isConnected: Bool {
        !devices.isEmpty
    }

    public func syncWithSettings() {
        if settings.headphonesEnabled {
            guard !isRunning else { return }
            isRunning = true
            monitor.start { [weak self] states in self?.receive(states) }
        } else {
            stop()
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        monitor.stop()
        devices = []
        alerted = []
        announced = nil
        lastDisconnected = nil
        deviceIDByActivity = [:]
        engine.endAll(source: HeadphonesPolicy.source)
    }

    /// Re-reads battery and mode; call when the user opens something that shows them.
    public func refresh() {
        guard isRunning else { return }
        monitor.refresh()
    }

    public func setListeningMode(_ mode: HeadphonesState.ListeningMode, for id: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }),
              devices[index].availableModes.contains(mode)
        else { return }
        // Optimistic: show it now; the monitor reads back what the headphones really did.
        devices[index].listeningMode = mode
        monitor.setListeningMode(mode, for: id)
    }

    func receive(_ new: [HeadphonesState]) {
        let outcome = HeadphonesPolicy.changes(from: devices, to: new, alerted: alerted)
        alerted = outcome.alerted
        if devices != new {
            devices = new
        }
        let date = now()

        // Leaving first, so when headphones are swapped the new pair's arrival is what shows.
        if let announced, !new.contains(where: { $0.id == announced.id }) {
            self.announced = nil
            engine.end(HeadphonesPolicy.connectedID)
        }
        if let device = outcome.disconnected.last {
            lastDisconnected = device
            deviceIDByActivity[HeadphonesPolicy.disconnectedID] = device.id
            try? engine.start(HeadphonesPolicy.disconnectedActivity(for: device, now: date))
        }
        if let device = outcome.connected.last {
            // Plugged back in or swapped: the hello replaces any goodbye.
            engine.end(HeadphonesPolicy.disconnectedID)
            let expiresAt = date + HeadphonesPolicy.connectedDuration
            announced = (device.id, expiresAt)
            deviceIDByActivity[HeadphonesPolicy.connectedID] = device.id
            try? engine.start(HeadphonesPolicy.connectedActivity(for: device, expiresAt: expiresAt))
        } else if let announced, announced.expiresAt > date,
                  let device = new.first(where: { $0.id == announced.id })
        {
            // Battery arrived after the connection: fill it in, same deadline.
            try? engine.start(HeadphonesPolicy.connectedActivity(for: device, expiresAt: announced.expiresAt))
        }
        if let device = outcome.lowBattery.last {
            deviceIDByActivity[HeadphonesPolicy.lowBatteryID] = device.id
            try? engine.start(HeadphonesPolicy.lowBatteryActivity(for: device, now: date))
        }
    }
}
