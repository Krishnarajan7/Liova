import CoreGraphics
import Foundation
@testable import LiovaProviders
import Testing

private func data1(key: Int, state: Int, repeating: Bool = false) -> Int {
    (key << 16) | (state << 8) | (repeating ? 1 : 0)
}

private let keyDown = 0x0A
private let keyUp = 0x0B

struct MediaKeyDecoderTests {
    @Test(arguments: MediaKey.allCases)
    func decodesKeyDown(key: MediaKey) {
        let event = MediaKeyDecoder.decode(subtype: 8, data1: data1(key: key.rawValue, state: keyDown), flags: [])
        #expect(event == MediaKeyEvent(key: key, isDown: true, isRepeat: false, isFineStep: false))
    }

    @Test(arguments: MediaKey.allCases)
    func decodesKeyUp(key: MediaKey) {
        let event = MediaKeyDecoder.decode(subtype: 8, data1: data1(key: key.rawValue, state: keyUp), flags: [])
        #expect(event == MediaKeyEvent(key: key, isDown: false))
    }

    @Test func keyCodesMatchEvKeymap() {
        #expect(MediaKey.soundUp.rawValue == 0)
        #expect(MediaKey.soundDown.rawValue == 1)
        #expect(MediaKey.brightnessUp.rawValue == 2)
        #expect(MediaKey.brightnessDown.rawValue == 3)
        #expect(MediaKey.mute.rawValue == 7)
    }

    @Test func decodesRepeat() {
        let event = MediaKeyDecoder.decode(subtype: 8, data1: data1(key: 0, state: keyDown, repeating: true), flags: [])
        #expect(event?.isRepeat == true)
        #expect(event?.isDown == true)
    }

    @Test func shiftOptionIsFineStep() {
        let event = MediaKeyDecoder.decode(
            subtype: 8, data1: data1(key: 1, state: keyDown), flags: [.maskShift, .maskAlternate]
        )
        #expect(event?.isFineStep == true)
    }

    @Test func shiftAloneAndFnAreNormalSteps() {
        for flags: CGEventFlags in [[.maskShift], [.maskSecondaryFn], [.maskNonCoalesced]] {
            let event = MediaKeyDecoder.decode(subtype: 8, data1: data1(key: 0, state: keyDown), flags: flags)
            #expect(event?.isFineStep == false)
        }
    }

    /// Option alone opens Sound or Displays settings; Command and Control belong to the system and other apps.
    @Test func systemModifierCombosPassThrough() {
        for flags: CGEventFlags in [[.maskAlternate], [.maskCommand], [.maskControl], [.maskShift, .maskCommand]] {
            #expect(MediaKeyDecoder.decode(subtype: 8, data1: data1(key: 0, state: keyDown), flags: flags) == nil)
        }
    }

    @Test func keyUpDecodesWhateverTheModifiers() {
        let event = MediaKeyDecoder.decode(subtype: 8, data1: data1(key: 7, state: keyUp), flags: [.maskCommand])
        #expect(event == MediaKeyEvent(key: .mute, isDown: false))
    }

    @Test(arguments: [0, 1, 7, 9, 13])
    func otherSubtypesPassThrough(subtype: Int) {
        #expect(MediaKeyDecoder.decode(subtype: subtype, data1: data1(key: 0, state: keyDown), flags: []) == nil)
    }

    /// Play/pause (16), next (17), previous (18), keyboard illumination (21–23), eject (14), caps lock (4).
    @Test(arguments: [4, 5, 6, 8, 14, 16, 17, 18, 19, 20, 21, 22, 23, 0xFFFF])
    func unhandledKeysPassThrough(keyCode: Int) {
        #expect(MediaKeyDecoder.decode(subtype: 8, data1: data1(key: keyCode, state: keyDown), flags: []) == nil)
    }

    @Test(arguments: [0x00, 0x01, 0x0C, 0xFF])
    func unknownKeyStatesPassThrough(state: Int) {
        #expect(MediaKeyDecoder.decode(subtype: 8, data1: data1(key: 0, state: state), flags: []) == nil)
    }
}

struct MediaKeyFilterTests {
    @Test func swallowsHandledDownAndItsUp() {
        var filter = MediaKeyFilter()
        #expect(filter.shouldSwallow(MediaKeyEvent(key: .soundUp, isDown: true)) { _ in true })
        #expect(filter.shouldSwallow(MediaKeyEvent(key: .soundUp, isDown: false)) { _ in
            Issue.record("Key-ups never reach the handler")
            return true
        })
    }

    @Test func unhandledDownAndItsUpPassThrough() {
        var filter = MediaKeyFilter()
        #expect(!filter.shouldSwallow(MediaKeyEvent(key: .brightnessUp, isDown: true)) { _ in false })
        #expect(!filter.shouldSwallow(MediaKeyEvent(key: .brightnessUp, isDown: false)) { _ in true })
    }

    @Test func strayUpPassesThrough() {
        var filter = MediaKeyFilter()
        #expect(!filter.shouldSwallow(MediaKeyEvent(key: .mute, isDown: false)) { _ in true })
    }

    @Test func failedRepeatReleasesTheKey() {
        var filter = MediaKeyFilter()
        #expect(filter.shouldSwallow(MediaKeyEvent(key: .soundUp, isDown: true)) { _ in true })
        #expect(!filter.shouldSwallow(MediaKeyEvent(key: .soundUp, isDown: true, isRepeat: true)) { _ in false })
        #expect(!filter.shouldSwallow(MediaKeyEvent(key: .soundUp, isDown: false)) { _ in true })
    }

    @Test func resetForgetsSwallowedDowns() {
        var filter = MediaKeyFilter()
        _ = filter.shouldSwallow(MediaKeyEvent(key: .soundDown, isDown: true)) { _ in true }
        filter.reset()
        #expect(!filter.shouldSwallow(MediaKeyEvent(key: .soundDown, isDown: false)) { _ in true })
    }
}

struct TapWatchdogTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func occasionalDisablesAreReenabled() {
        var watchdog = TapWatchdog(maxDisables: 3, window: 60)
        for minute in 0 ..< 10 {
            #expect(watchdog.recordDisable(at: start + Double(minute) * 61) == .reenable)
        }
    }

    @Test func burstGivesUp() {
        var watchdog = TapWatchdog(maxDisables: 3, window: 60)
        #expect(watchdog.recordDisable(at: start) == .reenable)
        #expect(watchdog.recordDisable(at: start + 1) == .reenable)
        #expect(watchdog.recordDisable(at: start + 2) == .reenable)
        #expect(watchdog.recordDisable(at: start + 3) == .giveUp)
    }

    @Test func resetClearsHistory() {
        var watchdog = TapWatchdog(maxDisables: 1, window: 60)
        #expect(watchdog.recordDisable(at: start) == .reenable)
        watchdog.reset()
        #expect(watchdog.recordDisable(at: start + 1) == .reenable)
        #expect(watchdog.recordDisable(at: start + 2) == .giveUp)
    }
}

/// These never create a real tap or touch real hardware: trust and the display are injected.
@MainActor
struct HUDProviderSafetyTests {
    @Test func tapWithoutPermissionReportsNeedsPermission() {
        let tap = CGEventMediaKeyTap(isTrusted: { false })
        let status = tap.start(onKey: { _ in true }, onStatusChange: { _ in })
        #expect(status == .needsPermission)
        #expect(tap.status == .needsPermission)
        #expect(!tap.isPermissionGranted)
        tap.stop()
        #expect(tap.status == .stopped)
    }

    @Test func stopWithoutStartIsSafe() {
        let tap = CGEventMediaKeyTap(isTrusted: { false })
        tap.stop()
        tap.stop()
        #expect(tap.status == .stopped)
    }

    @Test func missingDisplayServicesIsUnavailable() {
        let provider = DisplayServicesBrightness(frameworkPath: "/nonexistent/DisplayServices", builtInDisplay: { 1 })
        #expect(!provider.isAvailable)
        #expect(provider.brightness() == nil)
        #expect(!provider.setBrightness(0.5))
    }

    @Test func noBuiltInDisplayIsUnavailable() {
        // The real framework, but no built-in display (e.g. clamshell): nothing is read or set.
        let provider = DisplayServicesBrightness(builtInDisplay: { nil })
        #expect(!provider.isAvailable)
        #expect(!provider.setBrightness(0.5))
    }

    @Test func channelVolumesAreAveraged() {
        #expect(CoreAudioSystemVolume.average([]) == 0)
        #expect(CoreAudioSystemVolume.average([0.5]) == 0.5)
        #expect(CoreAudioSystemVolume.average([0.25, 0.75]) == 0.5)
    }

    @Test func volumeStateClamps() {
        #expect(VolumeState(deviceID: 1, volume: 1.4, isMuted: false, canSetVolume: true, canMute: true).volume == 1)
        #expect(VolumeState(deviceID: 1, volume: -1, isMuted: false, canSetVolume: true, canMute: true).volume == 0)
        #expect(VolumeState(deviceID: 1, volume: .nan, isMuted: false, canSetVolume: true, canMute: true).volume == 0)
    }
}
