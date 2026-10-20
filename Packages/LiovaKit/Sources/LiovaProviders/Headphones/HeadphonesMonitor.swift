import Foundation
import IOBluetooth
import os

/// A source of connected-headphones state. Behind a protocol so features are tested without
/// Bluetooth hardware.
@MainActor
public protocol HeadphonesMonitoring: AnyObject {
    /// Starts delivering the connected headphones on the main actor, current state first.
    func start(onChange: @escaping @MainActor ([HeadphonesState]) -> Void)
    func stop()
    /// Re-reads battery and mode now (e.g. when the user opens the notch to look).
    func refresh()
    func setListeningMode(_ mode: HeadphonesState.ListeningMode, for id: String)
}

/// Connected Bluetooth headphones through IOBluetooth.
///
/// Event-driven: connect and disconnect notifications from IOBluetooth. Headphones report
/// their battery a few seconds after connecting, so each connection gets a few follow-up
/// reads; after that, battery is re-read every few minutes only while headphones are
/// connected, and on demand when the notch opens. With nothing connected, nothing runs.
///
/// Battery levels and noise control come from IOBluetooth properties that aren't in the
/// public headers. Each is checked with `responds(to:)` before use, so a macOS release that
/// drops one hides that detail instead of crashing (see SECURITY.md, "Private APIs are
/// isolated").
@MainActor
public final class IOBluetoothHeadphonesMonitor: NSObject, HeadphonesMonitoring {
    private struct Tracked {
        let device: IOBluetoothDevice
        let disconnect: IOBluetoothUserNotification?
    }

    private var onChange: (@MainActor ([HeadphonesState]) -> Void)?
    private var connectNotification: IOBluetoothUserNotification?
    private var tracked: [String: Tracked] = [:]
    private var followUps: [String: Task<Void, Never>] = [:]
    private var periodicRefresh: Task<Void, Never>?
    private var lastDelivered: [HeadphonesState]?

    /// Seconds after connecting at which to re-read: battery usually arrives within these.
    static let followUpDelays: [Double] = [1, 3, 8, 20]
    static let refreshInterval: Duration = .seconds(300)
    private static let log = Logger(subsystem: "app.liova.Liova", category: "headphones")

    override public init() {
        super.init()
    }

    public func start(onChange: @escaping @MainActor ([HeadphonesState]) -> Void) {
        stop()
        self.onChange = onChange
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        // Registration reports devices that are already connected too; this covers macOS
        // releases where it doesn't.
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] where device.isConnected() {
            track(device)
        }
        deliver()
    }

    public func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        for (_, entry) in tracked {
            entry.disconnect?.unregister()
        }
        tracked.removeAll()
        followUps.values.forEach { $0.cancel() }
        followUps.removeAll()
        periodicRefresh?.cancel()
        periodicRefresh = nil
        lastDelivered = nil
        onChange = nil
    }

    public func refresh() {
        deliver()
    }

    public func setListeningMode(_ mode: HeadphonesState.ListeningMode, for id: String) {
        guard let device = tracked[id]?.device,
              device.responds(to: NSSelectorFromString("setListeningMode:"))
        else { return }
        Self.log.info("Setting listening mode to \(mode.title, privacy: .public)")
        device.setValue(NSNumber(value: mode.rawValue), forKey: "listeningMode")
        // The headphones confirm a moment later; read back what they actually did.
        scheduleFollowUps(for: id, delays: [0.4, 1.5])
    }

    // MARK: - Connections

    @objc nonisolated func deviceConnected(_: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        nonisolated(unsafe) let device = device
        onMain {
            $0.track(device)
            $0.deliver()
        }
    }

    @objc nonisolated func deviceDisconnected(_: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let id = device.addressString ?? ""
        onMain { $0.untrack(id) }
    }

    /// IOBluetooth calls back on the run loop it was registered on, which is the main one.
    /// Hops anyway if a future release doesn't.
    nonisolated func onMain(_ work: @escaping @MainActor (IOBluetoothHeadphonesMonitor) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work(self) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work(self) } }
        }
    }

    private func track(_ device: IOBluetoothDevice) {
        guard Self.isHeadphones(device), let id = device.addressString, tracked[id] == nil else { return }
        let disconnect = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDisconnected(_:device:))
        )
        tracked[id] = Tracked(device: device, disconnect: disconnect)
        Self.log.info("Headphones connected")
        scheduleFollowUps(for: id, delays: Self.followUpDelays)
        updatePeriodicRefresh()
    }

    private func untrack(_ id: String) {
        guard let entry = tracked.removeValue(forKey: id) else { return }
        entry.disconnect?.unregister()
        followUps.removeValue(forKey: id)?.cancel()
        Self.log.info("Headphones disconnected")
        updatePeriodicRefresh()
        deliver()
    }

    private func scheduleFollowUps(for id: String, delays: [Double]) {
        followUps[id]?.cancel()
        followUps[id] = Task { [weak self] in
            var elapsed = 0.0
            for delay in delays {
                try? await Task.sleep(for: .seconds(delay - elapsed), tolerance: .milliseconds(200))
                guard !Task.isCancelled else { return }
                elapsed = delay
                self?.deliver()
            }
        }
    }

    private func updatePeriodicRefresh() {
        if tracked.isEmpty {
            periodicRefresh?.cancel()
            periodicRefresh = nil
        } else if periodicRefresh == nil {
            periodicRefresh = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.refreshInterval, tolerance: .seconds(60))
                    guard !Task.isCancelled else { return }
                    self?.deliver()
                }
            }
        }
    }

    // MARK: - Reading

    private func deliver() {
        let states = tracked.values.map { Self.read($0.device) }.sorted { $0.name < $1.name }
        guard states != lastDelivered else { return }
        lastDelivered = states
        onChange?(states)
    }

    /// Audio-class devices only: headphones, earbuds, headsets and speakers that report it.
    static func isHeadphones(_ device: IOBluetoothDevice) -> Bool {
        device.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio)
    }

    static func read(_ device: IOBluetoothDevice) -> HeadphonesState {
        let name = device.nameOrAddress ?? "Headphones"
        let modes = HeadphonesReading.modes(
            current: integer(device, "listeningMode"),
            noiseCancellation: integer(device, "isANCSupported").map { $0 != 0 } ?? false,
            transparency: integer(device, "isTransparencySupported").map { $0 != 0 } ?? false
        )
        return HeadphonesState(
            id: device.addressString ?? name,
            name: name,
            kind: HeadphonesReading.kind(
                productID: integer(device, "productID"),
                isApple: integer(device, "isAppleDevice").map { $0 != 0 } ?? false,
                name: name
            ),
            battery: HeadphonesReading.battery(
                left: integer(device, "batteryPercentLeft"),
                right: integer(device, "batteryPercentRight"),
                caseLevel: integer(device, "batteryPercentCase"),
                single: integer(device, "batteryPercentSingle"),
                combined: integer(device, "batteryPercentCombined")
            ),
            listeningMode: modes.current,
            availableModes: modes.available
        )
    }

    /// A numeric property, only if this macOS has it.
    private static func integer(_ device: IOBluetoothDevice, _ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)) else { return nil }
        return (device.value(forKey: key) as? NSNumber)?.intValue
    }
}
