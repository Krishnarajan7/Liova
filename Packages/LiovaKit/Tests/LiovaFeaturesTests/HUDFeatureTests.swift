import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaPluginKit
import LiovaProviders
import Testing

/// Starting, stopping, permission, safe mode and fallback.
@MainActor
struct HUDFeatureLifecycleTests {
    private let fixture: HUDFeatureFixture
    private var clock: HUDTestClock {
        fixture.clock
    }

    private var engine: ActivityEngine {
        fixture.engine
    }

    private var settings: LiovaSettings {
        fixture.settings
    }

    private var volume: HUDFakeVolume {
        fixture.volume
    }

    private var brightness: HUDFakeBrightness {
        fixture.brightness
    }

    private var tap: HUDFakeKeyTap {
        fixture.tap
    }

    init() throws {
        fixture = try HUDFeatureFixture()
    }

    private func makeFeature(safeMode: Bool = false) -> HUDFeature {
        fixture.makeFeature(safeMode: safeMode)
    }

    private func enabledFeature() -> HUDFeature {
        fixture.enabledFeature()
    }

    @Test func offByDefault() {
        let feature = makeFeature()
        feature.syncWithSettings()
        #expect(feature.state == .off)
        #expect(!tap.isTapInstalled)
        #expect(!volume.isStarted)
    }

    @Test func enablingStartsTapAndListener() {
        let feature = enabledFeature()
        #expect(feature.state == .running)
        #expect(tap.isTapInstalled)
        #expect(volume.isStarted)
        #expect(engine.current == nil) // the initial state never flashes the HUD
    }

    @Test func missingPermissionReportsNeedsPermission() {
        tap.isPermissionGranted = false
        let feature = enabledFeature()
        #expect(feature.state == .needsPermission)
        #expect(!tap.isTapInstalled)
        #expect(!volume.isStarted)
    }

    @Test func grantingPermissionLaterStartsOnRecheck() {
        tap.isPermissionGranted = false
        let feature = enabledFeature()
        feature.recheckPermission()
        #expect(feature.state == .needsPermission)
        tap.isPermissionGranted = true
        feature.recheckPermission()
        #expect(feature.state == .running)
    }

    @Test func revokingPermissionStopsTheTap() {
        let feature = enabledFeature()
        tap.isPermissionGranted = false
        feature.recheckPermission()
        #expect(feature.state == .needsPermission)
        #expect(!tap.isTapInstalled)
        #expect(!volume.isStarted)
    }

    @Test func requestPermissionGoesThroughTheTap() {
        tap.isPermissionGranted = false
        let feature = enabledFeature()
        feature.requestPermission()
        #expect(tap.permissionRequests == 1)
    }

    @Test func tapFailureIsUnavailable() {
        tap.failure = "nope"
        let feature = enabledFeature()
        #expect(feature.state == .unavailable("nope"))
        #expect(!volume.isStarted)
    }

    @Test func safeModeRefusesToStart() {
        settings.hudReplacementEnabled = true
        let feature = makeFeature(safeMode: true)
        feature.syncWithSettings()
        guard case .unavailable = feature.state else {
            Issue.record("Expected unavailable, got \(feature.state)")
            return
        }
        #expect(!tap.isTapInstalled)
        settings.hudReplacementEnabled = false
        feature.syncWithSettings()
        #expect(feature.state == .off)
    }

    @Test func safeModeDetection() {
        #expect(HUDFeature.isSafeMode(environment: ["LIOVA_SAFE_MODE": "1"], optionKeyHeld: false))
        #expect(HUDFeature.isSafeMode(environment: ["LIOVA_SAFE_MODE": "TRUE"], optionKeyHeld: false))
        #expect(HUDFeature.isSafeMode(environment: [:], optionKeyHeld: true))
        #expect(!HUDFeature.isSafeMode(environment: [:], optionKeyHeld: false))
        #expect(!HUDFeature.isSafeMode(environment: ["LIOVA_SAFE_MODE": "0"], optionKeyHeld: false))
    }

    @Test func disablingClearsHUDAndRemovesTap() {
        let feature = enabledFeature()
        tap.press(.soundUp)
        #expect(engine.current != nil)
        settings.hudReplacementEnabled = false
        feature.syncWithSettings()
        #expect(feature.state == .off)
        #expect(engine.current == nil)
        #expect(!tap.isTapInstalled)
        #expect(!volume.isStarted)
    }

    @Test func watchdogGivingUpFallsBackToSystem() {
        let feature = enabledFeature()
        tap.press(.soundUp)
        tap.watchdogGivesUp()
        #expect(feature.state == .unavailable("gave up"))
        #expect(engine.current == nil)
        #expect(!volume.isStarted)
    }

    @Test func syncIsIdempotent() {
        let feature = enabledFeature()
        feature.syncWithSettings()
        feature.syncWithSettings()
        #expect(feature.state == .running)
        #expect(tap.stopCount == 0)
    }

    /// The tap holds the feature weakly: a released feature lets every key through to the system.
    @Test func releasedFeatureNeverSwallowsKeys() {
        settings.hudReplacementEnabled = true
        do {
            let feature = makeFeature()
            feature.syncWithSettings()
            #expect(feature.state == .running)
        }
        #expect(!tap.press(.soundUp))
        #expect(volume.setVolumeCalls.isEmpty)
    }

    @Test func stopIsAlwaysSafe() {
        let feature = makeFeature()
        feature.stop()
        feature.stop()
        #expect(feature.state == .off)
    }
}

/// Key presses, levels, the HUD activity and external volume changes.
@MainActor
struct HUDFeatureKeyTests {
    private let fixture: HUDFeatureFixture
    private var clock: HUDTestClock {
        fixture.clock
    }

    private var engine: ActivityEngine {
        fixture.engine
    }

    private var settings: LiovaSettings {
        fixture.settings
    }

    private var volume: HUDFakeVolume {
        fixture.volume
    }

    private var brightness: HUDFakeBrightness {
        fixture.brightness
    }

    private var tap: HUDFakeKeyTap {
        fixture.tap
    }

    init() throws {
        fixture = try HUDFeatureFixture()
    }

    private func makeFeature(safeMode: Bool = false) -> HUDFeature {
        fixture.makeFeature(safeMode: safeMode)
    }

    private func enabledFeature() -> HUDFeature {
        fixture.enabledFeature()
    }

    @Test func volumeKeyAppliesAndShowsHUD() throws {
        let feature = enabledFeature()
        defer { withExtendedLifetime(feature) {} }
        #expect(tap.press(.soundUp))
        #expect(volume.setVolumeCalls == [0.5625])
        let hud = try #require(engine.current)
        #expect(hud.id == HUDPolicy.activityID)
        #expect(hud.progress == 0.5625)
        #expect(hud.priority == .critical)
        #expect(hud.expiresAt == clock.now + 1.5)
    }

    @Test func fineStepUsesSixtyFourSteps() {
        let feature = enabledFeature()
        defer { withExtendedLifetime(feature) {} }
        tap.press(.soundDown, fine: true)
        #expect(volume.setVolumeCalls == [31.0 / 64])
    }

    @Test func muteKeyTogglesMute() {
        let feature = enabledFeature()
        defer { withExtendedLifetime(feature) {} }
        #expect(tap.press(.mute))
        #expect(volume.setMutedCalls == [true])
        #expect(engine.current?.symbol == "speaker.slash.fill")
        #expect(tap.press(.mute))
        #expect(volume.setMutedCalls == [true, false])
    }

    @Test func volumeUpWhileMutedUnmutes() {
        volume.state?.isMuted = true
        let feature = enabledFeature()
        defer { withExtendedLifetime(feature) {} }
        tap.press(.soundUp)
        #expect(volume.setMutedCalls == [false])
        #expect(volume.state?.isMuted == false)
    }

    @Test func atFullVolumeStillShowsHUD() {
        volume.state?.volume = 1
        let feature = enabledFeature()
        defer { withExtendedLifetime(feature) {} }
        #expect(tap.press(.soundUp))
        #expect(volume.setVolumeCalls.isEmpty)
        #expect(engine.current?.progress == 1)
    }

    @Test func fixedVolumeDevicePassesKeysToTheSystem() {
        volume.state?.canSetVolume = false
        volume.canSet = false
        let feature = enabledFeature()
        defer { withExtendedLifetime(feature) {} }
        #expect(!tap.press(.soundUp))
        #expect(engine.current == nil)
    }

    @Test func noOutputDevicePassesKeysToTheSystem() {
        volume.state = nil
        let feature = enabledFeature()
        defer { withExtendedLifetime(feature) {} }
        #expect(!tap.press(.soundDown))
        #expect(!tap.press(.mute))
    }

    @Test func brightnessKeyAppliesAndShowsYellowHUD() {
        let feature = enabledFeature()
        defer { withExtendedLifetime(feature) {} }
        #expect(tap.press(.brightnessUp))
        #expect(brightness.setCalls == [0.5625])
        #expect(engine.current?.tint == .yellow)
        #expect(engine.current?.symbol == "sun.max.fill")
    }

    @Test func unavailableBrightnessPassesKeysToTheSystem() {
        brightness.level = nil
        let feature = enabledFeature()
        defer { withExtendedLifetime(feature) {} }
        #expect(!tap.press(.brightnessDown))
        #expect(engine.current == nil)
    }

    @Test func repressUpdatesInPlaceAndExtendsExpiry() throws {
        let feature = enabledFeature()
        defer { withExtendedLifetime(feature) {} }
        tap.press(.soundUp)
        let first = try #require(engine.current?.expiresAt)
        clock.advance(1)
        tap.press(.brightnessDown)
        #expect(engine.activities.count == 1)
        #expect(engine.current?.title == "Brightness")
        #expect(engine.current?.expiresAt == first + 1)
    }

    @Test func externalVolumeChangeFlashesHUD() {
        let feature = enabledFeature()
        defer { withExtendedLifetime(feature) {} }
        volume.send(VolumeState(deviceID: 7, volume: 0.25, isMuted: false, canSetVolume: true, canMute: true))
        #expect(engine.current?.progress == 0.25)
    }

    @Test func echoOfOwnChangeIsIgnored() {
        let feature = enabledFeature()
        defer { withExtendedLifetime(feature) {} }
        tap.press(.soundUp)
        engine.end(HUDPolicy.activityID)
        // Core Audio reports our own change back, slightly off because of Float32 rounding.
        volume.send(VolumeState(deviceID: 7, volume: 0.5624, isMuted: false, canSetVolume: true, canMute: true))
        #expect(engine.current == nil)
        // An intermediate state right after our change is an echo too.
        volume.send(VolumeState(deviceID: 7, volume: 0.5, isMuted: true, canSetVolume: true, canMute: true))
        #expect(engine.current == nil)
        // Later, a genuine outside change flashes again.
        clock.advance(2)
        volume.send(VolumeState(deviceID: 7, volume: 0.1, isMuted: false, canSetVolume: true, canMute: true))
        #expect(engine.current?.progress == 0.1)
    }

    @Test func deviceSwitchDoesNotFlash() {
        let feature = enabledFeature()
        defer { withExtendedLifetime(feature) {} }
        volume.send(VolumeState(deviceID: 8, volume: 0.9, isMuted: false, canSetVolume: true, canMute: true))
        #expect(engine.current == nil)
    }

    @Test func externalChangesIgnoredWhileWaitingForPermission() {
        tap.isPermissionGranted = false
        let feature = enabledFeature()
        defer { withExtendedLifetime(feature) {} }
        volume.send(VolumeState(deviceID: 7, volume: 0.1, isMuted: false, canSetVolume: true, canMute: true))
        #expect(engine.current == nil)
    }
}
