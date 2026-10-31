import CoreAudio
import CoreMediaIO
import Foundation

/// Whether any app is using a camera or microphone right now.
public struct CaptureState: Equatable, Sendable {
    public var isCameraOn: Bool
    public var isMicrophoneOn: Bool

    public init(isCameraOn: Bool, isMicrophoneOn: Bool) {
        self.isCameraOn = isCameraOn
        self.isMicrophoneOn = isMicrophoneOn
    }

    public static let off = CaptureState(isCameraOn: false, isMicrophoneOn: false)
}

@MainActor
public protocol CaptureMonitoring: AnyObject {
    func start(onChange: @escaping @MainActor (CaptureState) -> Void)
    func stop()
}

/// Watches every camera (CoreMediaIO) and every audio input (Core Audio) for "running
/// somewhere", i.e. in use by any process. Property listeners only: nothing polls, and no
/// permission is needed because no audio or video is ever read.
///
/// The device-list listeners stay put for as long as the monitor runs; only per-device
/// listeners come and go, and only for devices that actually appeared or disappeared. Device
/// lists churn in bursts (waking from sleep, a call app adding virtual devices), so changes
/// are coalesced into one sync. Tearing everything down on every notification used to feed
/// itself and pin the main thread.
@MainActor
public final class SystemCaptureMonitor: CaptureMonitoring {
    private var onChange: (@MainActor (CaptureState) -> Void)?
    private var state = CaptureState.off

    private var audioDevicesListener: AudioObjectPropertyListenerBlock?
    private var cameraDevicesListener: CMIOObjectPropertyListenerBlock?
    private var audioListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var videoListeners: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private var pendingSync: Task<Void, Never>?
    private let queue = DispatchQueue.main

    /// How long to wait for a burst of device-list changes to settle.
    static let syncDelay: Duration = .milliseconds(250)

    public init() {}

    public func start(onChange: @escaping @MainActor (CaptureState) -> Void) {
        stop()
        self.onChange = onChange
        addDeviceListListeners()
        syncDeviceListeners()
        refresh()
    }

    public func stop() {
        pendingSync?.cancel()
        pendingSync = nil
        removeDeviceListListeners()
        for device in Array(audioListeners.keys) {
            removeAudioListener(device)
        }
        for camera in Array(videoListeners.keys) {
            removeVideoListener(camera)
        }
        onChange = nil
        state = .off
    }

    // MARK: - Listeners

    private func addDeviceListListeners() {
        // Devices come and go (AirPods, USB mics, virtual devices): resync when a list changes.
        let audioBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleSync() }
        }
        var audioAddress = Self.address(kAudioHardwarePropertyDevices)
        let audioSystem = AudioObjectID(kAudioObjectSystemObject)
        if AudioObjectAddPropertyListenerBlock(audioSystem, &audioAddress, queue, audioBlock) == noErr {
            audioDevicesListener = audioBlock
        }

        let videoBlock: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleSync() }
        }
        var videoAddress = Self.cmioAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let videoSystem = CMIOObjectID(kCMIOObjectSystemObject)
        if CMIOObjectAddPropertyListenerBlock(videoSystem, &videoAddress, queue, videoBlock) == noErr {
            cameraDevicesListener = videoBlock
        }
    }

    private func removeDeviceListListeners() {
        if let audioDevicesListener {
            var address = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, audioDevicesListener
            )
        }
        if let cameraDevicesListener {
            var address = Self.cmioAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
            CMIOObjectRemovePropertyListenerBlock(
                CMIOObjectID(kCMIOObjectSystemObject), &address, queue, cameraDevicesListener
            )
        }
        audioDevicesListener = nil
        cameraDevicesListener = nil
    }

    /// One sync per burst: later notifications while one is pending are dropped.
    private func scheduleSync() {
        guard onChange != nil, pendingSync == nil else { return }
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: Self.syncDelay)
            guard !Task.isCancelled, let self else { return }
            pendingSync = nil
            syncDeviceListeners()
            refresh()
        }
    }

    /// Listens to devices that appeared and forgets those that left. Devices already watched
    /// are left alone, so an unchanged list costs two lookups and nothing else.
    private func syncDeviceListeners() {
        let inputs = Set(Self.audioInputDevices())
        for device in audioListeners.keys where !inputs.contains(device) {
            removeAudioListener(device)
        }
        for device in inputs where audioListeners[device] == nil {
            addAudioListener(device)
        }

        let cameras = Set(Self.cameras())
        for camera in videoListeners.keys where !cameras.contains(camera) {
            removeVideoListener(camera)
        }
        for camera in cameras where videoListeners[camera] == nil {
            addVideoListener(camera)
        }
    }

    private func addAudioListener(_ device: AudioObjectID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr {
            audioListeners[device] = block
        }
    }

    private func removeAudioListener(_ device: AudioObjectID) {
        guard let block = audioListeners.removeValue(forKey: device) else { return }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
    }

    private func addVideoListener(_ camera: CMIOObjectID) {
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        var address = Self.cmioAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        if CMIOObjectAddPropertyListenerBlock(camera, &address, queue, block) == noErr {
            videoListeners[camera] = block
        }
    }

    private func removeVideoListener(_ camera: CMIOObjectID) {
        guard let block = videoListeners.removeValue(forKey: camera) else { return }
        var address = Self.cmioAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        CMIOObjectRemovePropertyListenerBlock(camera, &address, queue, block)
    }

    private func refresh() {
        let latest = CaptureState(
            isCameraOn: Self.cameras().contains(where: Self.isCameraRunning),
            isMicrophoneOn: Self.audioInputDevices().contains(where: Self.isAudioDeviceRunning)
        )
        guard latest != state else { return }
        state = latest
        onChange?(latest)
    }

    // MARK: - Core Audio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func audioInputDevices() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
            == noErr
        else { return [] }
        return devices.filter(hasInput)
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    static func isAudioDeviceRunning(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    // MARK: - CoreMediaIO

    private static func cmioAddress(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    static func cameras() -> [CMIOObjectID] {
        var address = cmioAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.stride)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices
        ) == noErr
        else { return [] }
        return devices
    }

    static func isCameraRunning(_ device: CMIOObjectID) -> Bool {
        var address = cmioAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        var running: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running)
            == noErr && running != 0
    }
}
