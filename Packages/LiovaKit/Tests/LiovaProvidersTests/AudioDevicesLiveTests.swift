import Foundation
import LiovaProviders
import Testing

/// Lists this Mac's real sound devices: `LIOVA_LIVE_TESTS=1 swift test --filter AudioDevicesLiveTests`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIOVA_LIVE_TESTS"] == "1"))
struct AudioDevicesLiveTests {
    @Test func listsOutputsAndInputsWithOneOfEachInUse() throws {
        let provider = CoreAudioDevices()
        var seen: AudioDevices?
        provider.start { seen = $0 }
        defer { provider.stop() }
        let devices = try #require(seen)
        for device in devices.outputs {
            print("output: \(device.name) [\(device.kind)]\(device.id == devices.currentOutput ? " ← in use" : "")")
        }
        for device in devices.inputs {
            print("input: \(device.name) [\(device.kind)]\(device.id == devices.currentInput ? " ← in use" : "")")
        }
        #expect(devices.outputs.contains { $0.id == devices.currentOutput })
        #expect(devices.inputs.contains { $0.id == devices.currentInput })
    }
}
