import CoreAudio
import Foundation

/// A speaker, pair of headphones, display or microphone that sound can be sent to or taken from.
public struct AudioDevice: Identifiable, Equatable, Sendable {
    /// What it is, for its symbol.
    public enum Kind: Equatable, Sendable {
        case builtIn
        case headphones
        case airPods
        case bluetooth
        case display
        case usb
        case airPlay
        case other
    }

    /// Stable across restarts and reconnects, unlike Core Audio's object number.
    public var id: String
    public var name: String
    public var kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// From what Core Audio says about how the device is connected, and its name.
    public static func kind(transport: UInt32, name: String) -> Kind {
        let lowered = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return lowered.contains("headphone") ? .headphones : .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if lowered.contains("airpods") {
                return .airPods
            }
            return lowered.contains("speaker") ? .bluetooth : .headphones
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt:
            return .display
        case kAudioDeviceTransportTypeUSB:
            return lowered.contains("headphone") || lowered.contains("headset") || lowered.contains("earpods")
                ? .headphones : .usb
        case kAudioDeviceTransportTypeAirPlay:
            return .airPlay
        default:
            return .other
        }
    }
}

/// The Mac's sound outputs and inputs, and which of each is in use.
public struct AudioDevices: Equatable, Sendable {
    public var outputs: [AudioDevice]
    public var inputs: [AudioDevice]
    public var currentOutput: String?
    public var currentInput: String?

    public init(
        outputs: [AudioDevice] = [], inputs: [AudioDevice] = [], currentOutput: String? = nil,
        currentInput: String? = nil
    ) {
        self.outputs = outputs
        self.inputs = inputs
        self.currentOutput = currentOutput
        self.currentInput = currentInput
    }
}

/// Lists the sound devices and switches between them.
@MainActor
public protocol AudioDevicesProviding: AnyObject {
    /// Reports the devices now and whenever one comes, goes or is switched to.
    func start(onChange: @escaping @MainActor (AudioDevices) -> Void)
    func stop()
    /// Sends the Mac's sound to this output. False when it didn't take.
    @discardableResult func useOutput(_ id: String) -> Bool
    /// Takes the Mac's sound from this input. False when it didn't take.
    @discardableResult func useInput(_ id: String) -> Bool
}

/// Core Audio's device list. Event-driven: three property listeners on the main queue
/// (devices, default output, default input) and nothing between changes. Only names and
/// connection types are read; no audio.
@MainActor
public final class CoreAudioDevices: AudioDevicesProviding {
    private var onChange: (@MainActor (AudioDevices) -> Void)?
    private var listener: AudioObjectPropertyListenerBlock?
    private var lastDelivered: AudioDevices?

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let watched: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultInputDevice,
    ]

    public init() {}

    public func start(onChange: @escaping @MainActor (AudioDevices) -> Void) {
        stop()
        self.onChange = onChange
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        for selector in Self.watched {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(Self.system, &address, .main, block)
        }
        listener = block
        refresh()
    }

    public func stop() {
        if let listener {
            for selector in Self.watched {
                var address = Self.address(selector)
                AudioObjectRemovePropertyListenerBlock(Self.system, &address, .main, listener)
            }
        }
        listener = nil
        onChange = nil
        lastDelivered = nil
    }

    public func useOutput(_ id: String) -> Bool {
        setDefault(kAudioHardwarePropertyDefaultOutputDevice, to: id, scope: kAudioObjectPropertyScopeOutput)
    }

    public func useInput(_ id: String) -> Bool {
        setDefault(kAudioHardwarePropertyDefaultInputDevice, to: id, scope: kAudioObjectPropertyScopeInput)
    }

    private func refresh() {
        let devices = Self.read()
        guard devices != lastDelivered else { return }
        lastDelivered = devices
        onChange?(devices)
    }

    private func setDefault(
        _ selector: AudioObjectPropertySelector, to id: String, scope: AudioObjectPropertyScope
    ) -> Bool {
        guard var device = Self.deviceIDs().first(where: { Self.uid($0) == id && Self.canBeDefault($0, scope: scope) })
        else { return false }
        var address = Self.address(selector)
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectSetPropertyData(Self.system, &address, 0, nil, size, &device) == noErr
    }

    // MARK: - Core Audio

    private static func read() -> AudioDevices {
        var devices = AudioDevices()
        let ids = deviceIDs()
        for id in ids {
            guard let uid = uid(id) else { continue }
            let name = string(id, kAudioObjectPropertyName) ?? "Unnamed device"
            let device = AudioDevice(
                id: uid, name: name,
                kind: AudioDevice.kind(transport: number(id, kAudioDevicePropertyTransportType) ?? 0, name: name)
            )
            if canBeDefault(id, scope: kAudioObjectPropertyScopeOutput) {
                devices.outputs.append(device)
            }
            if canBeDefault(id, scope: kAudioObjectPropertyScopeInput) {
                devices.inputs.append(device)
            }
        }
        devices.currentOutput = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice).flatMap(uid)
        devices.currentInput = defaultDevice(kAudioHardwarePropertyDefaultInputDevice).flatMap(uid)
        return devices
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        guard let id = number(system, selector), id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func uid(_ device: AudioObjectID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    /// Has streams in that direction and macOS lets it be chosen (not a hidden or helper device).
    private static func canBeDefault(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var streams = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &size) == noErr, size > 0 else { return false }
        return number(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: scope) != 0
    }

    private static func number(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
