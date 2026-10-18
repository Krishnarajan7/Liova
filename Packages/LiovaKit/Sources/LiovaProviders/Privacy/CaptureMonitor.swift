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
@MainActor
public final class SystemCaptureMonitor: CaptureMonitoring {
    private var onChange: (@MainActor (CaptureState) -> Void)?
    private var state = CaptureState.off
    private struct AudioListener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private struct VideoListener {
        let object: CMIOObjectID
        let address: CMIOObjectPropertyAddress
        let block: CMIOObjectPropertyListenerBlock
    }

    private var audioListeners: [AudioListener] = []
    private var videoListeners: [VideoListener] = []
    private let queue = DispatchQueue.main

    public init() {}

    public func start(onChange: @escaping @MainActor (CaptureState) -> Void) {
        stop()
        self.onChange = onChange
        rebuildListeners()
        refresh()
    }

    public func stop() {
        removeAllListeners()
        audioListeners.removeAll()
        videoListeners.removeAll()
        onChange = nil
    }

    // MARK: - Listeners

    private func removeAllListeners() {
        for listener in audioListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, queue, listener.block)
        }
        for listener in videoListeners {
            var address = listener.address
            CMIOObjectRemovePropertyListenerBlock(listener.object, &address, queue, listener.block)
        }
        audioListeners.removeAll()
        videoListeners.removeAll()
    }

    private func rebuildListeners() {
        removeAllListeners()
        audioListeners.removeAll()
        videoListeners.removeAll()

        let changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let devicesChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.rebuildListeners()
                self?.refresh()
            }
        }
        // Devices come and go (AirPods, USB mics): rebuild when the list changes.
        addAudioListener(
            AudioObjectID(kAudioObjectSystemObject),
            Self.address(kAudioHardwarePropertyDevices),
            devicesChanged
        )
        for device in Self.audioInputDevices() {
            addAudioListener(device, Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere), changed)
        }

        let videoChanged: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let camerasChanged: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.rebuildListeners()
                self?.refresh()
            }
        }
        addVideoListener(
            CMIOObjectID(kCMIOObjectSystemObject),
            Self.cmioAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)),
            camerasChanged
        )
        for camera in Self.cameras() {
            addVideoListener(
                camera,
                Self.cmioAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)),
                videoChanged
            )
        }
    }

    private func addAudioListener(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = address
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            audioListeners.append(AudioListener(object: object, address: address, block: block))
        }
    }

    private func addVideoListener(
        _ object: CMIOObjectID,
        _ address: CMIOObjectPropertyAddress,
        _ block: @escaping CMIOObjectPropertyListenerBlock
    ) {
        var address = address
        if CMIOObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            videoListeners.append(VideoListener(object: object, address: address, block: block))
        }
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
