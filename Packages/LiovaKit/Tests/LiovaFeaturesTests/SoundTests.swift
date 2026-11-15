import AppKit
import CoreAudio
import LiovaCore
@testable import LiovaFeatures
import LiovaProviders
import SwiftUI
import Testing

@MainActor
private final class FakeAudioDevices: AudioDevicesProviding {
    var devices = AudioDevices(
        outputs: [
            AudioDevice(id: "speakers", name: "MacBook Air Speakers", kind: .builtIn),
            AudioDevice(id: "airpods", name: "Krish's AirPods Pro", kind: .airPods),
            AudioDevice(id: "display", name: "Studio Display", kind: .display),
        ],
        inputs: [
            AudioDevice(id: "mic", name: "MacBook Air Microphone", kind: .builtIn),
            AudioDevice(id: "airpods", name: "Krish's AirPods Pro", kind: .airPods),
        ],
        currentOutput: "speakers",
        currentInput: "mic"
    )
    private(set) var starts = 0
    private(set) var isRunning = false
    private var onChange: (@MainActor (AudioDevices) -> Void)?

    func start(onChange: @escaping @MainActor (AudioDevices) -> Void) {
        starts += 1
        isRunning = true
        self.onChange = onChange
        onChange(devices)
    }

    func stop() {
        isRunning = false
        onChange = nil
    }

    func useOutput(_ id: String) -> Bool {
        guard devices.outputs.contains(where: { $0.id == id }) else { return false }
        devices.currentOutput = id
        onChange?(devices)
        return true
    }

    func useInput(_ id: String) -> Bool {
        guard devices.inputs.contains(where: { $0.id == id }) else { return false }
        devices.currentInput = id
        onChange?(devices)
        return true
    }
}

@MainActor
struct SoundTests {
    private let provider = FakeAudioDevices()
    private let settings: LiovaSettings
    private let feature: SoundFeature
    private let scratch = ScratchDefaults()

    init() {
        settings = LiovaSettings(defaults: scratch.defaults)
        feature = SoundFeature(settings: settings, provider: provider)
    }

    @Test func watchesOnlyWhileAPageIsOnScreen() {
        #expect(!provider.isRunning)
        feature.pageAppeared()
        #expect(provider.isRunning)
        #expect(feature.devices.outputs.count == 3)
        feature.pageAppeared() // a second display's notch
        feature.pageDisappeared()
        #expect(provider.isRunning)
        #expect(provider.starts == 1)
        feature.pageDisappeared()
        #expect(!provider.isRunning)
    }

    @Test func choosingADeviceSwitchesToIt() {
        feature.pageAppeared()
        feature.useOutput(feature.devices.outputs[1])
        #expect(feature.devices.currentOutput == "airpods")
        #expect(feature.devices.currentInput == "mic") // the microphone stays where it was
        feature.useInput(feature.devices.inputs[1])
        #expect(feature.devices.currentInput == "airpods")
    }

    @Test func turningItOffStopsWatching() {
        feature.pageAppeared()
        settings.soundPageEnabled = false
        feature.syncWithSettings()
        #expect(!feature.isEnabled)
        #expect(!provider.isRunning)
        settings.soundPageEnabled = true
        feature.syncWithSettings()
        #expect(provider.isRunning) // the page is still open
    }

    @Test func devicesAreRecognisedByHowTheyConnect() {
        #expect(AudioDevice.kind(transport: kAudioDeviceTransportTypeBuiltIn, name: "MacBook Air Speakers") == .builtIn)
        #expect(AudioDevice
            .kind(transport: kAudioDeviceTransportTypeBuiltIn, name: "External Headphones") == .headphones)
        #expect(AudioDevice
            .kind(transport: kAudioDeviceTransportTypeBluetooth, name: "Krish's AirPods Pro") == .airPods)
        #expect(AudioDevice.kind(transport: kAudioDeviceTransportTypeBluetooth, name: "Nord Buds 3") == .headphones)
        #expect(AudioDevice.kind(transport: kAudioDeviceTransportTypeBluetooth, name: "JBL Speaker") == .bluetooth)
        #expect(AudioDevice.kind(transport: kAudioDeviceTransportTypeHDMI, name: "LG TV") == .display)
        #expect(AudioDevice.kind(transport: kAudioDeviceTransportTypeUSB, name: "EarPods") == .headphones)
        #expect(AudioDevice.kind(transport: kAudioDeviceTransportTypeUSB, name: "Scarlett 2i2") == .usb)
        #expect(AudioDevice.kind(transport: kAudioDeviceTransportTypeVirtual, name: "BlackHole") == .other)
    }

    @Test func aMicrophoneNeverGetsASpeakersSymbol() {
        for kind in [AudioDevice.Kind.builtIn, .bluetooth, .usb, .other] {
            #expect(SoundPolicy.symbol(for: kind, isInput: true) == "mic.fill")
        }
        #expect(SoundPolicy.symbol(for: .airPods, isInput: true) == "airpods")
        #expect(SoundPolicy.symbol(for: .builtIn, isInput: false) == "laptopcomputer")
    }

    /// Renders the page for visual review when `LIOVA_SNAPSHOT_DIR` is set.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIOVA_SNAPSHOT_DIR"] != nil))
    func snapshot() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIOVA_SNAPSHOT_DIR"] ?? "/tmp")
        feature.pageAppeared()
        feature.useOutput(feature.devices.outputs[1])
        let view = SoundPage(feature: feature)
            .padding(14)
            .frame(width: 520)
            .background(.black)
            .environment(\.colorScheme, .dark)
        _ = ImageRenderer(content: view).nsImage
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let tiff = try #require(renderer.nsImage?.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("sound-page.png"))
    }
}
