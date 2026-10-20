import CoreAudio
import Foundation
import os

/// What Core Audio says about one output device. Plain values, so deciding whether it's
/// headphones is tested without hardware.
public struct AudioOutputDescription: Equatable, Sendable {
    public var uid: String
    public var name: String
    /// `kAudioDevicePropertyTransportType`: built-in, USB, Bluetooth, AirPlay…
    public var transport: UInt32
    /// `kAudioStreamPropertyTerminalType` of each output stream.
    public var terminalTypes: [UInt32]
    /// `kAudioDevicePropertyDataSource` on the output side, for devices that switch between
    /// speakers and a jack.
    public var dataSource: UInt32?

    public init(uid: String, name: String, transport: UInt32, terminalTypes: [UInt32], dataSource: UInt32? = nil) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.terminalTypes = terminalTypes
        self.dataSource = dataSource
    }
}

/// Which output devices are wired headphones. Pure, so it's unit-tested.
public enum WiredHeadphonesReading {
    /// `'hdpn'`: the built-in output's data source when something is in the headphone jack.
    static let headphonesDataSource: UInt32 = 0x6864_706E
    /// USB Audio Class terminal types: headphones (0x302) and headset (0x402). Core Audio's
    /// own `'hdph'` is what USB-C EarPods report.
    static let headphoneTerminals: Set<UInt32> = [kAudioStreamTerminalTypeHeadphones, 0x302, 0x402]
    static let headphoneNames = ["earpods", "headphone", "headset", "earphone"]

    /// Built-in and USB only: Bluetooth comes from IOBluetooth with its battery, and AirPlay,
    /// displays, docks and virtual devices aren't headphones.
    public static func headphones(from device: AudioOutputDescription) -> HeadphonesState? {
        let isHeadphones: Bool
        switch device.transport {
        case kAudioDeviceTransportTypeBuiltIn:
            // Apple silicon Macs add an "External Headphones" device when the jack is in use;
            // older ones switch the speakers' data source instead.
            isHeadphones = device.dataSource == headphonesDataSource
                || device.terminalTypes.contains { headphoneTerminals.contains($0) }
                || device.uid.localizedCaseInsensitiveContains("headphone")
        case kAudioDeviceTransportTypeUSB:
            // Only what calls itself headphones: a USB DAC or audio interface stays quiet.
            let name = device.name.lowercased()
            isHeadphones = device.terminalTypes.contains { headphoneTerminals.contains($0) }
                || headphoneNames.contains { name.contains($0) }
        default:
            isHeadphones = false
        }
        guard isHeadphones else { return nil }
        let isJack = device.transport == kAudioDeviceTransportTypeBuiltIn
        // The jack's device name is "External Headphones", or the speakers' on older Macs.
        let name = isJack ? "Headphones" : device.name
        return HeadphonesState(
            id: isJack ? "wired.jack" : "wired.\(device.uid)",
            name: name,
            kind: device.name.lowercased().contains("earpods") ? .earPods : .other,
            isWired: true
        )
    }

    /// One entry per pair: a USB headset can expose more than one output device.
    public static func headphones(from devices: [AudioOutputDescription]) -> [HeadphonesState] {
        var seen: Set<String> = []
        return devices.compactMap(headphones(from:)).filter { seen.insert($0.id).inserted }
    }
}

/// Wired headphones through Core Audio: USB-C EarPods, USB headsets and the headphone jack.
///
/// Event-driven: Core Audio calls back when devices come and go and when the built-in
/// output's data source switches. Nothing is polled, and no permission is needed.
@MainActor
public final class CoreAudioWiredHeadphonesMonitor: HeadphonesMonitoring {
    private var onChange: (@MainActor ([HeadphonesState]) -> Void)?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    /// Data-source listeners on built-in outputs, by device.
    private var sourceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var lastDelivered: [HeadphonesState]?
    private static let log = Logger(subsystem: "app.liova.Liova", category: "headphones")

    private static let devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let dataSourceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    public init() {}

    public func start(onChange: @escaping @MainActor ([HeadphonesState]) -> Void) {
        stop()
        self.onChange = onChange
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }
        var address = Self.devicesAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) ==
            noErr
        {
            devicesListener = listener
        }
        devicesChanged()
    }

    public func stop() {
        if let devicesListener {
            var address = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                .main,
                devicesListener
            )
        }
        devicesListener = nil
        for (device, listener) in sourceListeners {
            var address = Self.dataSourceAddress
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener)
        }
        sourceListeners.removeAll()
        lastDelivered = nil
        onChange = nil
    }

    public func refresh() {
        deliver(Self.outputs())
    }

    /// Wired headphones have no noise control.
    public func setListeningMode(_: HeadphonesState.ListeningMode, for _: String) {}

    private func devicesChanged() {
        let ids = Self.deviceIDs()
        let outputs = ids.compactMap(Self.describe)
        watchDataSources(of: Set(ids.filter { Self.isBuiltInOutputWithDataSource($0) }))
        deliver(outputs)
    }

    /// Keeps one data-source listener per built-in output with a switchable source.
    private func watchDataSources(of devices: Set<AudioObjectID>) {
        for (device, listener) in sourceListeners where !devices.contains(device) {
            var address = Self.dataSourceAddress
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener)
            sourceListeners[device] = nil
        }
        for device in devices where sourceListeners[device] == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            var address = Self.dataSourceAddress
            if AudioObjectAddPropertyListenerBlock(device, &address, .main, listener) == noErr {
                sourceListeners[device] = listener
            }
        }
    }

    private func deliver(_ outputs: [AudioOutputDescription]) {
        let states = WiredHeadphonesReading.headphones(from: outputs)
        guard states != lastDelivered else { return }
        if let lastDelivered, states.count != lastDelivered.count {
            Self.log.info("Wired headphones: \(states.count) connected")
        }
        lastDelivered = states
        onChange?(states)
    }

    // MARK: - Core Audio

    private static func outputs() -> [AudioOutputDescription] {
        deviceIDs().compactMap(describe)
    }

    private static func deviceIDs() -> [AudioObjectID] {
        var address = devicesAddress
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Nil for devices with no output streams (microphones).
    private static func describe(_ device: AudioObjectID) -> AudioOutputDescription? {
        let streams = objectIDs(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard !streams.isEmpty else { return nil }
        return AudioOutputDescription(
            uid: string(device, kAudioDevicePropertyDeviceUID) ?? "\(device)",
            name: string(device, kAudioObjectPropertyName) ?? "Headphones",
            transport: number(device, kAudioDevicePropertyTransportType) ?? 0,
            terminalTypes: streams.compactMap { number($0, kAudioStreamPropertyTerminalType) },
            dataSource: number(device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        )
    }

    private static func isBuiltInOutputWithDataSource(_ device: AudioObjectID) -> Bool {
        guard number(device, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn
        else { return false }
        var address = dataSourceAddress
        return AudioObjectHasProperty(device, &address)
    }

    private static func number(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func objectIDs(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}

/// Several monitors as one: Bluetooth and wired headphones together, in that order.
@MainActor
public final class CombinedHeadphonesMonitor: HeadphonesMonitoring {
    private let monitors: [any HeadphonesMonitoring]
    private var latest: [[HeadphonesState]]

    public init(_ monitors: [any HeadphonesMonitoring]) {
        self.monitors = monitors
        latest = Array(repeating: [], count: monitors.count)
    }

    /// What Liova uses: IOBluetooth for wireless pairs, Core Audio for wired ones.
    public static func standard() -> CombinedHeadphonesMonitor {
        CombinedHeadphonesMonitor([IOBluetoothHeadphonesMonitor(), CoreAudioWiredHeadphonesMonitor()])
    }

    public func start(onChange: @escaping @MainActor ([HeadphonesState]) -> Void) {
        latest = Array(repeating: [], count: monitors.count)
        for (index, monitor) in monitors.enumerated() {
            monitor.start { [weak self] states in
                guard let self else { return }
                latest[index] = states
                onChange(latest.flatMap(\.self))
            }
        }
    }

    public func stop() {
        monitors.forEach { $0.stop() }
    }

    public func refresh() {
        monitors.forEach { $0.refresh() }
    }

    public func setListeningMode(_ mode: HeadphonesState.ListeningMode, for id: String) {
        monitors.forEach { $0.setListeningMode(mode, for: id) }
    }
}
