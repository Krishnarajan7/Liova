import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaPluginKit
import LiovaProviders
import Testing

@MainActor
final class FakeMicUsers: MicrophoneUserMonitoring {
    private var onChange: (@MainActor ([MicrophoneUser]) -> Void)?
    private(set) var isStarted = false

    func start(onChange: @escaping @MainActor ([MicrophoneUser]) -> Void) {
        isStarted = true
        self.onChange = onChange
    }

    func stop() {
        isStarted = false
        onChange = nil
    }

    func send(_ users: [MicrophoneUser]) {
        onChange?(users)
    }
}

@MainActor
final class FakeMute: InputMuting {
    private(set) var isMuted = false
    var canMute = true
    private var onChange: (@MainActor (Bool) -> Void)?

    func setMuted(_ muted: Bool) {
        isMuted = muted
        onChange?(muted)
    }

    func start(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
    }

    func stop() {
        onChange = nil
    }

    /// Muted from elsewhere: a headset button, another app.
    func externallySet(_ muted: Bool) {
        isMuted = muted
        onChange?(muted)
    }
}

@MainActor
final class FakeHangUp: CallHangingUp {
    var result = HangUpResult.done
    private(set) var hungUp: [String] = []

    func hangUp(_ user: MicrophoneUser) async -> HangUpResult {
        hungUp.append(user.bundleID)
        return result
    }
}

private let zoom = MicrophoneUser(pid: 10, bundleID: "us.zoom.xos", name: "zoom.us")
private let dictation = MicrophoneUser(pid: 11, bundleID: "com.example.Whisper", name: "Whisper")

@MainActor
struct CallTests {
    let engine = ActivityEngine()
    let users = FakeMicUsers()
    let mute = FakeMute()
    let hangUpper = FakeHangUp()
    let settings: LiovaSettings
    let feature: CallFeature
    private let scratch = ScratchDefaults()

    init() {
        settings = LiovaSettings(defaults: scratch.defaults)
        feature = CallFeature(
            engine: engine, settings: settings, users: users, mute: mute, hangUpper: hangUpper,
            isAvailable: { true }
        )
        feature.syncWithSettings()
    }

    private var activity: Activity? {
        engine.activity(CallPolicy.callID)
    }

    @Test func anAppRecordingIsACall() throws {
        users.send([zoom])
        #expect(feature.call?.app == zoom)
        let shown = try #require(activity)
        #expect(shown.title == "zoom.us")
        #expect(shown.symbol == "mic.fill")
        users.send([])
        #expect(feature.call == nil)
        #expect(activity == nil)
    }

    @Test func callAppsWinOverOtherRecorders() {
        users.send([dictation, zoom])
        #expect(feature.call?.app == zoom)
    }

    @Test func muteShowsInTheClosedNotch() {
        users.send([zoom])
        feature.toggleMute()
        #expect(mute.isMuted)
        #expect(activity?.symbol == "mic.slash.fill")
        #expect(activity?.tint == .red)
        feature.toggleMute()
        #expect(!mute.isMuted)
        #expect(activity?.symbol == "mic.fill")
    }

    @Test func theMicIsNeverLeftMutedAfterTheCall() {
        users.send([zoom])
        feature.toggleMute()
        users.send([])
        #expect(!mute.isMuted)
    }

    @Test func aMuteFromElsewhereIsShownButLeftAlone() {
        users.send([zoom])
        mute.externallySet(true)
        #expect(feature.isMuted)
        #expect(activity?.symbol == "mic.slash.fill")
        users.send([])
        // Liova didn't mute it, so it doesn't unmute it either.
        #expect(mute.isMuted)
    }

    @Test func hangUpAsksTheCallApp() async {
        users.send([zoom])
        feature.hangUp()
        #expect(await eventually { hangUpper.hungUp == ["us.zoom.xos"] })
    }

    @Test func aFailedHangUpSaysWhy() async {
        hangUpper.result = .needsPermission
        users.send([zoom])
        feature.hangUp()
        #expect(await eventually { feature.hangUpProblem == .needsPermission })
    }

    @Test func turningItOffEndsTheCallAndStopsListening() {
        users.send([zoom])
        settings.callControlsEnabled = false
        feature.syncWithSettings()
        #expect(feature.call == nil)
        #expect(activity == nil)
        #expect(!users.isStarted)
    }

    @Test func hiddenUntilReleased() {
        let hidden = CallFeature(
            engine: engine, settings: settings, users: FakeMicUsers(), mute: FakeMute(), hangUpper: FakeHangUp(),
            isAvailable: { false }
        )
        hidden.syncWithSettings()
        #expect(hidden.call == nil)
    }
}
