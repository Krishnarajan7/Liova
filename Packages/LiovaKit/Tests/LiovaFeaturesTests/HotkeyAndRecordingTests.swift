import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaPluginKit
import LiovaProviders
import Testing

@MainActor
final class FakeHotkeys: HotkeyRegistering {
    private(set) var combos: [String: HotkeyCombo] = [:]
    var refuse: Set<String> = []
    private var onPress: (@MainActor (String) -> Void)?

    func register(_ combos: [String: HotkeyCombo], onPress: @escaping @MainActor (String) -> Void) -> Set<String> {
        self.combos = combos
        self.onPress = onPress
        return refuse.intersection(combos.keys)
    }

    func unregisterAll() {
        combos = [:]
        onPress = nil
    }

    func press(_ action: HotkeyAction) {
        onPress?(action.rawValue)
    }
}

@MainActor
struct HotkeyFeatureTests {
    let hotkeys = FakeHotkeys()
    let settings: LiovaSettings
    let feature: HotkeyFeature
    private let scratch = ScratchDefaults()

    init() {
        settings = LiovaSettings(defaults: scratch.defaults)
        feature = HotkeyFeature(settings: settings, hotkeys: hotkeys, isAvailable: { true })
    }

    @Test func pressingAShortcutRunsItsAction() {
        var opened = 0
        feature.setAction(.clipboard) { opened += 1 }
        feature.syncWithSettings()
        #expect(hotkeys.combos["clipboard"] == HotkeyCombo(keyCode: 9, modifiers: 0x1800))
        hotkeys.press(.clipboard)
        #expect(opened == 1)
    }

    @Test func changedShortcutsAreRememberedAndReregistered() {
        feature.setAction(.toggleNotch) {}
        feature.syncWithSettings()
        let custom = Shortcut(keyCode: 49, modifiers: [.command, .shift], key: "Space")
        settings.setShortcut(custom, for: .toggleNotch)
        feature.syncWithSettings()
        #expect(hotkeys.combos["toggleNotch"]?.keyCode == 49)
        #expect(LiovaSettings(defaults: scratch.defaults).shortcut(for: .toggleNotch) == custom)
        settings.setShortcut(HotkeyAction.toggleNotch.defaultShortcut, for: .toggleNotch)
        #expect(settings.customShortcuts.isEmpty)
    }

    @Test func turningShortcutsOffReleasesThem() {
        feature.setAction(.toggleNotch) {}
        feature.syncWithSettings()
        settings.hotkeysEnabled = false
        feature.syncWithSettings()
        #expect(hotkeys.combos.isEmpty)
    }

    @Test func recordingANewShortcutSilencesTheOldOnes() {
        feature.setAction(.toggleNotch) {}
        feature.syncWithSettings()
        feature.setSuspended(true)
        #expect(hotkeys.combos.isEmpty)
        feature.setSuspended(false)
        #expect(!hotkeys.combos.isEmpty)
    }

    @Test func shortcutsTakenElsewhereAreReported() {
        hotkeys.refuse = ["clipboard"]
        feature.setAction(.clipboard) {}
        feature.syncWithSettings()
        #expect(feature.taken == [.clipboard])
    }

    @Test func sharedCombinationsGoToTheFirstAction() {
        let shared = Shortcut(keyCode: 1, modifiers: [.command, .option], key: "S")
        settings.setShortcut(shared, for: .toggleNotch)
        settings.setShortcut(shared, for: .clipboard)
        let chosen = HotkeyFeature.shortcuts(settings: settings, actions: [.toggleNotch, .clipboard])
        #expect(chosen[.toggleNotch] == shared)
        #expect(chosen[.clipboard] == nil)
    }

    @Test func shortcutsReadLikeMenus() {
        #expect(HotkeyAction.clipboard.defaultShortcut.displayName == "⌃⌥V")
        #expect(!Shortcut(keyCode: 9, modifiers: [.shift], key: "V").isUsable)
    }
}

@MainActor
final class FakeOBS: OBSControlling {
    private(set) var connection = OBSConnection.disconnected
    private(set) var sent: [OBSCommand] = []
    private var onChange: (@MainActor (OBSConnection) -> Void)?

    func connect(password _: String?, onChange: @escaping @MainActor (OBSConnection) -> Void) {
        self.onChange = onChange
    }

    func disconnect() {
        onChange = nil
    }

    func send(_ command: OBSCommand) {
        sent.append(command)
    }

    func report(_ new: OBSConnection) {
        connection = new
        onChange?(new)
    }
}

@MainActor
final class FakeScreenRecording: ScreenRecordingWatching {
    private var onChange: (@MainActor (Bool) -> Void)?
    private(set) var stops = 0
    private(set) var toolbarOpened = 0

    func start(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
    }

    func stop() {
        onChange = nil
    }

    func stopRecording() {
        stops += 1
    }

    func openToolbar() {
        toolbarOpened += 1
    }

    func report(_ recording: Bool) {
        onChange?(recording)
    }
}

@MainActor
struct RecordingFeatureTests {
    let engine = ActivityEngine()
    let screen = FakeScreenRecording()
    let obs = FakeOBS()
    let settings: LiovaSettings
    let feature: RecordingFeature
    private let scratch = ScratchDefaults()

    init() {
        settings = LiovaSettings(defaults: scratch.defaults)
        feature = RecordingFeature(
            engine: engine, settings: settings, obsClient: obs, screen: screen,
            password: { nil }, isAvailable: { true }
        )
        feature.syncWithSettings()
    }

    private var activity: Activity? {
        engine.activity(RecordingPolicy.activityID)
    }

    @Test func macOSRecordingShowsAndStopsFromTheNotch() {
        screen.report(true)
        #expect(feature.recording?.source == .screen)
        #expect(activity?.tint == .red)
        #expect(feature.recording?.canPause == false)
        feature.stopRecording()
        #expect(screen.stops == 1)
        screen.report(false)
        #expect(feature.recording == nil)
        #expect(activity == nil)
    }

    @Test func recordWithoutOBSOpensTheScreenshotToolbar() {
        feature.toggleRecording()
        #expect(screen.toolbarOpened == 1)
        #expect(obs.sent.isEmpty)
    }

    @Test func pauseShowsAtOnceAndAsksOBS() {
        feature.obsChanged(.connected(recording: OBSRecording(isPaused: false, elapsed: 12, measuredAt: Date())))
        #expect(feature.recording?.source == .obs)
        feature.togglePause()
        #expect(obs.sent.last == .pause)
        #expect(feature.recording?.isPaused == true)
        #expect(activity?.tint == .orange)
        feature.togglePause()
        #expect(obs.sent.last == .resume)
        #expect(feature.recording?.isPaused == false)
    }

    @Test func recordStartsInOBSWhenConnected() {
        feature.obsChanged(.connected(recording: nil))
        feature.toggleRecording()
        #expect(obs.sent == [.start])
        #expect(screen.toolbarOpened == 0)
    }

    @Test func obsStoppingEndsTheRecording() {
        feature.obsChanged(.connected(recording: OBSRecording(isPaused: false, elapsed: 3, measuredAt: Date())))
        feature.obsChanged(.connected(recording: nil))
        #expect(feature.recording == nil)
        #expect(activity == nil)
    }

    @Test func turningItOffEndsTheActivity() {
        screen.report(true)
        settings.recordingControlsEnabled = false
        feature.syncWithSettings()
        #expect(activity == nil)
    }

    @Test func theClockLeavesPausesOut() {
        let date = Date(timeIntervalSince1970: 1000)
        let recording = Recording(source: .obs, isPaused: false, elapsed: 30, measuredAt: date)
        #expect(recording.clockStart == Date(timeIntervalSince1970: 970))
    }
}
