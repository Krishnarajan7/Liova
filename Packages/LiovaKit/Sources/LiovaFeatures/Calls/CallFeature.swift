import Foundation
import LiovaCore
import LiovaPluginKit
import LiovaProviders
import Observation

/// A call in progress: an app recording from the microphone.
public struct Call: Equatable, Sendable {
    public var app: MicrophoneUser
    public var startedAt: Date
}

/// Calls in the notch: which app you're on a call in, for how long, whether you're muted,
/// and Mute and Hang Up right there.
///
/// Mute is the microphone's own, so it holds in every app (and on a headset plugged in
/// mid-call). Muting is undone when the call ends, so the mic is never left muted by
/// accident. Everything is event-driven: nothing runs while no app records.
@MainActor
@Observable
public final class CallFeature {
    public private(set) var call: Call?
    public private(set) var isMuted = false
    /// Why the last Hang Up didn't work, shown for a moment.
    public private(set) var hangUpProblem: HangUpResult?

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let users: any MicrophoneUserMonitoring
    @ObservationIgnored private let mute: any InputMuting
    @ObservationIgnored private let hangUpper: any CallHangingUp
    @ObservationIgnored private let isAvailable: @MainActor () -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var isRunning = false
    /// Liova muted the mic for this call, so it unmutes when the call ends.
    @ObservationIgnored private var mutedForCall = false
    @ObservationIgnored private var problemTask: Task<Void, Never>?

    public init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        users: any MicrophoneUserMonitoring = SystemMicrophoneUserMonitor(),
        mute: any InputMuting = SystemInputMute(),
        hangUpper: any CallHangingUp = AccessibilityHangUp(),
        isAvailable: @escaping @MainActor () -> Bool = { PreviewFeature.calls.isEnabled() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.engine = engine
        self.settings = settings
        self.users = users
        self.mute = mute
        self.hangUpper = hangUpper
        self.isAvailable = isAvailable
        self.now = now
    }

    public func syncWithSettings() {
        guard settings.callControlsEnabled, isAvailable() else {
            stop()
            return
        }
        guard !isRunning else { return }
        isRunning = true
        mute.start { [weak self] muted in self?.muteChanged(muted) }
        isMuted = mute.isMuted
        users.start { [weak self] users in self?.receive(users) }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        endCall()
        users.stop()
        mute.stop()
    }

    // MARK: - Actions

    public var canMute: Bool {
        mute.canMute
    }

    public func toggleMute() {
        guard call != nil else { return }
        mute.setMuted(!isMuted)
        mutedForCall = mute.isMuted
        muteChanged(mute.isMuted)
    }

    public func hangUp() {
        guard let app = call?.app else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await hangUpper.hangUp(app)
            guard result != .done else { return }
            hangUpProblem = result
            problemTask?.cancel()
            problemTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.hangUpProblem = nil
            }
        }
    }

    // MARK: - Events

    func receive(_ users: [MicrophoneUser]) {
        guard let app = CallPolicy.callApp(among: users) else {
            endCall()
            return
        }
        if call?.app.pid != app.pid {
            call = Call(app: app, startedAt: now())
        }
        publish()
    }

    private func muteChanged(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        if call != nil {
            publish()
        }
    }

    private func endCall() {
        guard call != nil else { return }
        if mutedForCall, mute.isMuted {
            mute.setMuted(false)
        }
        mutedForCall = false
        call = nil
        hangUpProblem = nil
        engine.end(CallPolicy.callID)
    }

    private func publish() {
        guard let call else { return }
        try? engine.start(CallPolicy.activity(for: call, muted: isMuted))
    }
}

/// Which app is the call, and what the notch says. Pure, so it's unit-tested.
public enum CallPolicy {
    public static let source = "system.calls"
    public static let callID: ActivityID = "system.calls.call"

    /// Apps made for calls come first: with Zoom and a dictation app both recording, it's
    /// the Zoom call.
    static let callApps: Set = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp", "com.skype.skype", "ru.keepcoder.Telegram",
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser",
    ]

    static func callApp(among users: [MicrophoneUser]) -> MicrophoneUser? {
        users.first { callApps.contains($0.bundleID) } ?? users.first
    }

    static func activity(for call: Call, muted: Bool) -> Activity {
        Activity(
            id: callID,
            source: source,
            // Above music: on a call, the call is what matters.
            priority: .normal,
            title: muted ? "Muted · \(call.app.name)" : call.app.name,
            subtitle: muted ? "Microphone off" : "On a call",
            symbol: muted ? "mic.slash.fill" : "mic.fill",
            tint: muted ? .red : .green
        )
    }
}
