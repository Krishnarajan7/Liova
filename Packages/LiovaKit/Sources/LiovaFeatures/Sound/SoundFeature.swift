import LiovaCore
import LiovaProviders
import Observation

/// The Sound page: where the Mac's sound goes, where it's taken from, and a click to change
/// either.
///
/// It watches the device list only while a Sound page is on screen (each display's notch
/// has its own), so it does nothing at all the rest of the time.
@MainActor
@Observable
public final class SoundFeature {
    public static let pageID = "sound"

    public private(set) var devices = AudioDevices()

    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let provider: any AudioDevicesProviding
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var isWatching = false

    public init(settings: LiovaSettings, provider: any AudioDevicesProviding = CoreAudioDevices()) {
        self.settings = settings
        self.provider = provider
    }

    public var isEnabled: Bool {
        settings.soundPageEnabled
    }

    public func syncWithSettings() {
        watch(isEnabled && viewers > 0)
    }

    public func stop() {
        viewers = 0
        watch(false)
    }

    public func pageAppeared() {
        viewers += 1
        watch(isEnabled)
    }

    public func pageDisappeared() {
        viewers = max(0, viewers - 1)
        watch(isEnabled && viewers > 0)
    }

    public func useOutput(_ device: AudioDevice) {
        guard device.id != devices.currentOutput else { return }
        if !provider.useOutput(device.id) {
            Log.feature.notice("Couldn't switch the sound output")
        }
    }

    public func useInput(_ device: AudioDevice) {
        guard device.id != devices.currentInput else { return }
        if !provider.useInput(device.id) {
            Log.feature.notice("Couldn't switch the sound input")
        }
    }

    private func watch(_ wanted: Bool) {
        guard wanted != isWatching else { return }
        isWatching = wanted
        if wanted {
            provider.start { [weak self] in self?.devices = $0 }
        } else {
            provider.stop()
        }
    }
}

/// How a device is drawn. Pure, so it's unit-tested.
public enum SoundPolicy {
    public static func symbol(for kind: AudioDevice.Kind, isInput: Bool) -> String {
        switch kind {
        case .builtIn: isInput ? "mic.fill" : "laptopcomputer"
        case .headphones: "headphones"
        case .airPods: "airpods"
        case .bluetooth: isInput ? "mic.fill" : "hifispeaker.fill"
        case .display: "display"
        case .usb: isInput ? "mic.fill" : "hifispeaker.fill"
        case .airPlay: "airplayaudio"
        case .other: isInput ? "mic.fill" : "speaker.wave.2.fill"
        }
    }
}
