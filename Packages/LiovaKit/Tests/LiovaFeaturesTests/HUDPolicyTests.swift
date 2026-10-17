import Foundation
import LiovaFeatures
import LiovaPluginKit
import LiovaProviders
import Testing

private let now = Date(timeIntervalSince1970: 1_000_000)

private func volume(_ level: Double, muted: Bool = false) -> VolumeState {
    VolumeState(deviceID: 42, volume: level, isMuted: muted, canSetVolume: true, canMute: true)
}

struct HUDPolicyStepTests {
    @Test func sixteenStepsByDefault() {
        #expect(HUDPolicy.step(0.5, .increase, fine: false) == 0.5625)
        #expect(HUDPolicy.step(0.5, .decrease, fine: false) == 0.4375)
    }

    @Test func sixtyFourStepsWithShiftOption() {
        #expect(HUDPolicy.step(0.5, .increase, fine: true) == 33.0 / 64)
        #expect(HUDPolicy.step(0.5, .decrease, fine: true) == 31.0 / 64)
    }

    @Test func clampsAtBothEnds() {
        #expect(HUDPolicy.step(1, .increase, fine: false) == 1)
        #expect(HUDPolicy.step(0, .decrease, fine: false) == 0)
        #expect(HUDPolicy.step(1, .increase, fine: true) == 1)
        #expect(HUDPolicy.step(0, .decrease, fine: true) == 0)
        #expect(HUDPolicy.step(15.0 / 16, .increase, fine: false) == 1)
        #expect(HUDPolicy.step(1.0 / 16, .decrease, fine: false) == 0)
    }

    @Test func outOfRangeInputIsClamped() {
        #expect(HUDPolicy.step(3, .decrease, fine: false) == 0.9375)
        #expect(HUDPolicy.step(-1, .increase, fine: false) == 0.0625)
        #expect(HUDPolicy.step(.nan, .increase, fine: false) == 0.0625)
    }

    @Test func betweenStepsSnapsInTheKeyDirection() {
        // 0.53 is between 8/16 and 9/16.
        #expect(HUDPolicy.step(0.53, .increase, fine: false) == 0.5625)
        #expect(HUDPolicy.step(0.53, .decrease, fine: false) == 0.5)
    }

    /// Devices quantize; a level read back slightly off the grid must still move a full step.
    @Test func quantizedReadBackStillMoves() {
        #expect(HUDPolicy.step(0.06, .increase, fine: false) == 0.125)
        #expect(HUDPolicy.step(0.4999, .increase, fine: false) == 0.5625)
        #expect(HUDPolicy.step(0.5001, .decrease, fine: false) == 0.4375)
    }

    @Test func sixteenPressesGoFromZeroToFull() {
        var level = 0.0
        for _ in 0 ..< 16 {
            level = HUDPolicy.step(level, .increase, fine: false)
        }
        #expect(level == 1)
    }
}

struct HUDPolicyVolumeTests {
    @Test func muteTogglesAndKeepsLevel() {
        #expect(HUDPolicy.volumeTarget(for: .mute, current: volume(0.5), fine: false)
            == .init(volume: 0.5, isMuted: true))
        #expect(HUDPolicy.volumeTarget(for: .mute, current: volume(0.5, muted: true), fine: false)
            == .init(volume: 0.5, isMuted: false))
    }

    @Test func volumeUpUnmutesAndSteps() {
        #expect(HUDPolicy.volumeTarget(for: .soundUp, current: volume(0.5, muted: true), fine: false)
            == .init(volume: 0.5625, isMuted: false))
    }

    @Test func volumeDownWhileMutedStaysMuted() {
        #expect(HUDPolicy.volumeTarget(for: .soundDown, current: volume(0.5, muted: true), fine: false)
            == .init(volume: 0.4375, isMuted: true))
    }

    @Test func volumeUpFromZero() {
        #expect(HUDPolicy.volumeTarget(for: .soundUp, current: volume(0), fine: false)
            == .init(volume: 0.0625, isMuted: false))
    }

    @Test func brightnessKeysAreNotVolumeKeys() {
        #expect(HUDPolicy.volumeTarget(for: .brightnessUp, current: volume(0.5), fine: false) == nil)
        #expect(HUDPolicy.brightnessTarget(for: .soundUp, current: 0.5, fine: false) == nil)
        #expect(HUDPolicy.brightnessTarget(for: .brightnessUp, current: 0.5, fine: false) == 0.5625)
        #expect(HUDPolicy.brightnessTarget(for: .brightnessDown, current: 0.5, fine: true) == 31.0 / 64)
    }
}

struct HUDPolicyActivityTests {
    @Test func volumeActivityShape() {
        let activity = HUDPolicy.volumeActivity(volume: 0.5, isMuted: false, now: now)
        #expect(activity.id == "system.hud")
        #expect(activity.source == "system.hud")
        #expect(activity.priority == .critical)
        #expect(activity.expiresAt == now + 1.5)
        #expect(activity.progress == 0.5)
        #expect(activity.tint == .gray)
        #expect(activity.subtitle == "50%")
    }

    @Test func mutedVolumeShowsSlashAndEmptyBar() {
        let activity = HUDPolicy.volumeActivity(volume: 0.5, isMuted: true, now: now)
        #expect(activity.symbol == "speaker.slash.fill")
        #expect(activity.progress == 0)
        #expect(activity.subtitle == "Muted")
    }

    @Test(arguments: [
        (0.0, false, "speaker.slash.fill"),
        (0.7, true, "speaker.slash.fill"),
        (0.0625, false, "speaker.wave.1.fill"),
        (0.3, false, "speaker.wave.1.fill"),
        (0.5, false, "speaker.wave.2.fill"),
        (0.7, false, "speaker.wave.3.fill"),
        (1.0, false, "speaker.wave.3.fill"),
    ])
    func volumeSymbols(level: Double, muted: Bool, symbol: String) {
        #expect(HUDPolicy.volumeSymbol(volume: level, isMuted: muted) == symbol)
    }

    @Test func brightnessActivityShape() {
        let activity = HUDPolicy.brightnessActivity(brightness: 0.75, now: now)
        #expect(activity.id == HUDPolicy.activityID)
        #expect(activity.priority == .critical)
        #expect(activity.tint == .yellow)
        #expect(activity.symbol == "sun.max.fill")
        #expect(activity.progress == 0.75)
        #expect(activity.expiresAt == now + HUDPolicy.displayDuration)
        #expect(HUDPolicy.brightnessActivity(brightness: 0.2, now: now).symbol == "sun.min.fill")
    }

    @Test func volumeAndBrightnessShareOneActivity() {
        #expect(HUDPolicy.volumeActivity(volume: 0.5, isMuted: false, now: now).id
            == HUDPolicy.brightnessActivity(brightness: 0.5, now: now).id)
    }
}
