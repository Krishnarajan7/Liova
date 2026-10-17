import AudioToolbox
import CoreAudio
import Foundation

/// The default output device's volume at one moment.
public struct VolumeState: Equatable, Sendable {
    /// Core Audio object ID of the default output device. Changes when the output switches.
    public var deviceID: UInt32
    /// Volume in `0...1`.
    public var volume: Double
    public var isMuted: Bool
    /// False for outputs whose volume is fixed or controlled elsewhere (some HDMI and AirPlay outputs).
    public var canSetVolume: Bool
    public var canMute: Bool

    public init(deviceID: UInt32, volume: Double, isMuted: Bool, canSetVolume: Bool, canMute: Bool) {
        self.deviceID = deviceID
        self.volume = volume.isFinite ? min(max(volume, 0), 1) : 0
        self.isMuted = isMuted
        self.canSetVolume = canSetVolume
        self.canMute = canMute
    }
}

/// Reads and changes the system output volume. Behind a protocol so features are testable
/// without touching the user's speakers.
@MainActor
public protocol SystemVolumeControlling: AnyObject {
    /// Latest known state, or `nil` when there is no output device.
    var state: VolumeState? { get }
    /// Sets the volume of the default output device. Returns false if it can't be set.
    @discardableResult func setVolume(_ volume: Double) -> Bool
    /// Mutes or unmutes the default output device. Returns false if it can't be muted.
    @discardableResult func setMuted(_ muted: Bool) -> Bool
    /// Starts delivering changes on the main actor, including ones made elsewhere
    /// (Control Center, AirPods, other apps) and output-device switches. Delivers the current state first.
    func start(onChange: @escaping @MainActor (VolumeState?) -> Void)
    func stop()
}

/// Core Audio implementation. Event-driven: property listeners on the system object (default
/// output device) and on the device (volume, mute). Nothing polls.
///
/// Volume is read and written through the first control the device offers:
/// 1. `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, which keeps the channel balance;
/// 2. the main element's `kAudioDevicePropertyVolumeScalar`;
/// 3. each preferred stereo channel's `kAudioDevicePropertyVolumeScalar`, averaged.
@MainActor
public final class CoreAudioSystemVolume: SystemVolumeControlling {
    public private(set) var state: VolumeState?

    private var device: AudioObjectID = kAudioObjectUnknown
    private var control: VolumeControl = .unavailable
    private var systemListener: Listener?
    private var deviceListeners: [Listener] = []
    private var onChange: (@MainActor (VolumeState?) -> Void)?

    public init() {
        refreshDevice()
    }

    public func start(onChange: @escaping @MainActor (VolumeState?) -> Void) {
        stop()
        self.onChange = onChange
        systemListener = Listener.add(
            object: AudioObjectID(kAudioObjectSystemObject),
            address: Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        ) { [weak self] in
            self?.defaultDeviceChanged()
        }
        refreshDevice()
        addDeviceListeners()
        onChange(state)
    }

    public func stop() {
        systemListener?.remove()
        systemListener = nil
        removeDeviceListeners()
        onChange = nil
    }

    @discardableResult
    public func setVolume(_ volume: Double) -> Bool {
        guard device != kAudioObjectUnknown, volume.isFinite else { return false }
        let value = Float32(min(max(volume, 0), 1))
        let succeeded: Bool = switch control {
        case .unavailable:
            false
        case let .virtualMain(address), let .mainElement(address):
            Self.setFloat(value, object: device, address: address)
        case let .channels(addresses):
            // Succeed only if every channel took the value, so a partial change is never reported as done.
            addresses.map { Self.setFloat(value, object: device, address: $0) }.allSatisfy(\.self)
        }
        if succeeded {
            refreshState()
        }
        return succeeded
    }

    @discardableResult
    public func setMuted(_ muted: Bool) -> Bool {
        guard device != kAudioObjectUnknown, state?.canMute == true else { return false }
        var value: UInt32 = muted ? 1 : 0
        var address = Self.address(kAudioDevicePropertyMute)
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        )
        guard status == noErr else {
            HUDLog.logger.error("Setting mute failed: \(status)")
            return false
        }
        refreshState()
        return true
    }

    // MARK: - Device tracking

    private func defaultDeviceChanged() {
        let previous = state
        removeDeviceListeners()
        refreshDevice()
        addDeviceListeners()
        if state != previous {
            onChange?(state)
        }
    }

    private func refreshDevice() {
        device = Self.defaultOutputDevice() ?? kAudioObjectUnknown
        control = device == kAudioObjectUnknown ? .unavailable : Self.volumeControl(for: device)
        state = readState()
    }

    /// Re-reads the current device. Notifies only on a real change.
    private func refreshState() {
        let latest = readState()
        guard latest != state else { return }
        state = latest
        onChange?(latest)
    }

    private func readState() -> VolumeState? {
        guard device != kAudioObjectUnknown else { return nil }
        let volume: Double = switch control {
        case .unavailable:
            // Read-only outputs may still report a level; show full otherwise.
            Self.getFloat(object: device, address: Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume))
                .map(Double.init) ?? 1
        case let .virtualMain(address), let .mainElement(address):
            Self.getFloat(object: device, address: address).map(Double.init) ?? 0
        case let .channels(addresses):
            Self.average(addresses.compactMap { Self.getFloat(object: device, address: $0) })
        }
        let muteAddress = Self.address(kAudioDevicePropertyMute)
        let mutedValue = Self.getUInt32(object: device, address: muteAddress)
        return VolumeState(
            deviceID: device,
            volume: volume,
            isMuted: (mutedValue ?? 0) != 0,
            canSetVolume: control.isSettable,
            canMute: mutedValue != nil && Self.isSettable(object: device, address: muteAddress)
        )
    }

    private func addDeviceListeners() {
        guard device != kAudioObjectUnknown else { return }
        // Listen to every volume property the device might report changes on; refreshState()
        // reads the effective value and drops duplicates, so overlapping callbacks are harmless.
        var addresses = [
            Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
            Self.address(kAudioDevicePropertyVolumeScalar),
            Self.address(kAudioDevicePropertyMute),
        ]
        if case let .channels(channelAddresses) = control {
            addresses += channelAddresses
        }
        deviceListeners = addresses.compactMap { address in
            Listener.add(object: device, address: address) { [weak self] in
                self?.refreshState()
            }
        }
    }

    private func removeDeviceListeners() {
        for listener in deviceListeners {
            listener.remove()
        }
        deviceListeners = []
    }
}

// MARK: - Core Audio helpers

extension CoreAudioSystemVolume {
    /// How the current device's volume is read and written.
    enum VolumeControl {
        case unavailable
        case virtualMain(AudioObjectPropertyAddress)
        case mainElement(AudioObjectPropertyAddress)
        case channels([AudioObjectPropertyAddress])

        var isSettable: Bool {
            if case .unavailable = self {
                return false
            }
            return true
        }
    }

    /// The mean of the channel volumes, or 0 when none could be read.
    static func average(_ values: [Float32]) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func volumeControl(for device: AudioObjectID) -> VolumeControl {
        let virtualMain = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        if isSettable(object: device, address: virtualMain) {
            return .virtualMain(virtualMain)
        }
        let mainElement = address(kAudioDevicePropertyVolumeScalar)
        if isSettable(object: device, address: mainElement) {
            return .mainElement(mainElement)
        }
        let channels = preferredStereoChannels(for: device)
            .map { address(kAudioDevicePropertyVolumeScalar, element: $0) }
            .filter { isSettable(object: device, address: $0) }
        return channels.isEmpty ? .unavailable : .channels(channels)
    }

    static func preferredStereoChannels(for device: AudioObjectID) -> [UInt32] {
        var address = address(kAudioDevicePropertyPreferredChannelsForStereo)
        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &channels)
        guard status == noErr, size == UInt32(MemoryLayout<UInt32>.size * 2) else { return [1, 2] }
        return Array(Set(channels)).sorted()
    }

    static func isSettable(object: AudioObjectID, address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    static func getFloat(object: AudioObjectID, address: AudioObjectPropertyAddress) -> Float32? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && value.isFinite ? value : nil
    }

    static func getUInt32(object: AudioObjectID, address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func setFloat(_ value: Float32, object: AudioObjectID, address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var value = value
        let status = AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if status != noErr {
            HUDLog.logger.error("Setting volume failed: \(status)")
        }
        return status == noErr
    }

    /// One block-based property listener, delivered on the main queue.
    final class Listener {
        private let object: AudioObjectID
        private let address: AudioObjectPropertyAddress
        private let block: AudioObjectPropertyListenerBlock
        private var isRegistered = true

        private init(
            object: AudioObjectID,
            address: AudioObjectPropertyAddress,
            block: @escaping AudioObjectPropertyListenerBlock
        ) {
            self.object = object
            self.address = address
            self.block = block
        }

        /// Registers a listener, or returns `nil` if the object doesn't have the property.
        @MainActor
        static func add(
            object: AudioObjectID,
            address: AudioObjectPropertyAddress,
            onChange: @escaping @MainActor () -> Void
        ) -> Listener? {
            var address = address
            guard AudioObjectHasProperty(object, &address) else { return nil }
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                // Registered on the main queue below.
                MainActor.assumeIsolated { onChange() }
            }
            let status = AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
            guard status == noErr else {
                HUDLog.logger.error("Adding Core Audio listener failed: \(status)")
                return nil
            }
            return Listener(object: object, address: address, block: block)
        }

        func remove() {
            guard isRegistered else { return }
            isRegistered = false
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
    }
}
