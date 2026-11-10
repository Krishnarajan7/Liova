import AppKit
import CoreAudio
import Foundation

/// An app using a microphone right now.
public struct MicrophoneUser: Equatable, Sendable {
    public var pid: pid_t
    public var bundleID: String
    public var name: String

    public init(pid: pid_t, bundleID: String, name: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
    }
}

/// Which apps are recording from a microphone, from Core Audio's process objects (public
/// since macOS 14.2; earlier it reports nobody). No permission needed: nothing is recorded.
public enum MicrophoneUsers {
    /// Apps first, as the user knows them: a browser's audio service counts as the browser.
    /// Parts of macOS listening for "Hey Siri" or dictation are left out.
    @MainActor
    public static func current() -> [MicrophoneUser] {
        var seen = Set<pid_t>()
        return processObjects().compactMap { object -> MicrophoneUser? in
            guard isRunningInput(object), let pid = pid(of: object) else { return nil }
            let owner = ResponsibleProcess.pid(for: pid) ?? pid
            guard let app = NSRunningApplication(processIdentifier: owner) ??
                NSRunningApplication(processIdentifier: pid),
                let bundleID = app.bundleIdentifier, !isSystem(bundleID), app.processIdentifier != getpid(),
                seen.insert(app.processIdentifier).inserted
            else { return nil }
            return MicrophoneUser(
                pid: app.processIdentifier,
                bundleID: bundleID,
                name: app.localizedName ?? bundleID
            )
        }
    }

    /// Listening, not calling: Siri, dictation, and the like.
    static func isSystem(_ bundleID: String) -> Bool {
        [
            "com.apple.CoreSpeech",
            "com.apple.corespeechd",
            "com.apple.SpeechRecognitionCore",
            "com.apple.assistantd",
            "com.apple.Siri",
            "com.apple.siri",
            "com.apple.DictationIM",
            "com.apple.accessibility",
        ]
        .contains { bundleID.hasPrefix($0) }
    }

    static func processObjects() -> [AudioObjectID] {
        var address = CoreAudioAddress.global(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func isRunningInput(_ object: AudioObjectID) -> Bool {
        var address = CoreAudioAddress.global(kAudioProcessPropertyIsRunningInput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func pid(of object: AudioObjectID) -> pid_t? {
        var address = CoreAudioAddress.global(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr, pid > 0 else { return nil }
        return pid
    }
}

@MainActor
public protocol MicrophoneUserMonitoring: AnyObject {
    /// `onChange` gets the apps using a microphone now, and again whenever that changes.
    func start(onChange: @escaping @MainActor ([MicrophoneUser]) -> Void)
    func stop()
}

/// Tells when apps start or stop recording, from Core Audio's process objects: the list
/// of processes doing audio, and whether each is recording. Listeners only, never a timer;
/// bursts (a call app opening several streams) settle into one update.
@MainActor
public final class SystemMicrophoneUserMonitor: MicrophoneUserMonitoring {
    private var onChange: (@MainActor ([MicrophoneUser]) -> Void)?
    private var listListener: AudioObjectPropertyListenerBlock?
    private var inputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var pending: Task<Void, Never>?
    private var last: [MicrophoneUser]?

    static let settle: Duration = .milliseconds(200)

    public init() {}

    public func start(onChange: @escaping @MainActor ([MicrophoneUser]) -> Void) {
        stop()
        self.onChange = onChange
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        var address = CoreAudioAddress.global(kAudioHardwarePropertyProcessObjectList)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) ==
            noErr
        {
            listListener = block
        }
        syncProcesses()
        report()
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        if let listListener {
            var address = CoreAudioAddress.global(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                .main,
                listListener
            )
        }
        listListener = nil
        for object in Array(inputListeners.keys) {
            removeInputListener(object)
        }
        onChange = nil
        last = nil
    }

    private func schedule() {
        guard onChange != nil, pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled, let self else { return }
            pending = nil
            syncProcesses()
            report()
        }
    }

    private func report() {
        let users = MicrophoneUsers.current()
        guard users != last else { return }
        last = users
        onChange?(users)
    }

    private func syncProcesses() {
        let objects = Set(MicrophoneUsers.processObjects())
        for object in inputListeners.keys where !objects.contains(object) {
            removeInputListener(object)
        }
        for object in objects where inputListeners[object] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
            var address = CoreAudioAddress.global(kAudioProcessPropertyIsRunningInput)
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
                inputListeners[object] = block
            }
        }
    }

    private func removeInputListener(_ object: AudioObjectID) {
        guard let block = inputListeners.removeValue(forKey: object) else { return }
        var address = CoreAudioAddress.global(kAudioProcessPropertyIsRunningInput)
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
}

/// Mutes the microphone for every app at once, at the input device, the way a hardware
/// mute switch would. Follows the default input: plug in a headset while muted, and the
/// headset is muted too.
@MainActor
public protocol InputMuting: AnyObject {
    var isMuted: Bool { get }
    /// Whether the current input can be muted at all.
    var canMute: Bool { get }
    func setMuted(_ muted: Bool)
    /// `onChange` runs when the mute changes, from here or elsewhere (another app, a headset).
    func start(onChange: @escaping @MainActor (Bool) -> Void)
    func stop()
}

@MainActor
public final class SystemInputMute: InputMuting {
    public private(set) var isMuted = false
    private var onChange: (@MainActor (Bool) -> Void)?
    private var device: AudioObjectID = 0
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    /// Set by `setMuted`, so a new default input inherits it.
    private var wanted: Bool?

    public init() {}

    public var canMute: Bool {
        var address = Self.muteAddress
        var settable: DarwinBoolean = false
        return device != 0 && AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    public func start(onChange: @escaping @MainActor (Bool) -> Void) {
        stop()
        self.onChange = onChange
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.inputChanged() }
        }
        var address = CoreAudioAddress.global(kAudioHardwarePropertyDefaultInputDevice)
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block
        ) == noErr {
            deviceListener = block
        }
        follow(Self.defaultInput())
    }

    public func stop() {
        if let deviceListener {
            var address = CoreAudioAddress.global(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                .main,
                deviceListener
            )
        }
        deviceListener = nil
        unfollow()
        onChange = nil
        wanted = nil
    }

    public func setMuted(_ muted: Bool) {
        wanted = muted
        write(muted, to: device)
        read()
    }

    private func inputChanged() {
        follow(Self.defaultInput())
        if let wanted, wanted != isMuted {
            write(wanted, to: device)
            read()
        }
    }

    private func follow(_ new: AudioObjectID) {
        guard new != device else { return }
        unfollow()
        device = new
        guard new != 0 else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.read() }
        }
        var address = Self.muteAddress
        if AudioObjectAddPropertyListenerBlock(new, &address, .main, block) == noErr {
            muteListener = block
        }
        read()
    }

    private func unfollow() {
        if let muteListener, device != 0 {
            var address = Self.muteAddress
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, muteListener)
        }
        muteListener = nil
        device = 0
    }

    private func read() {
        var address = Self.muteAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let muted = device != 0
            && AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
        guard muted != isMuted else { return }
        isMuted = muted
        onChange?(muted)
    }

    private func write(_ muted: Bool, to device: AudioObjectID) {
        guard device != 0 else { return }
        var address = Self.muteAddress
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func defaultInput() -> AudioObjectID {
        var address = CoreAudioAddress.global(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr else { return 0 }
        return device
    }
}

enum CoreAudioAddress {
    static func global(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
