import AppKit
import Foundation
import LiovaCore
import LiovaPluginKit
import LiovaProviders
import Observation

/// Replaces the system volume and brightness overlays with notch HUDs.
///
/// A media-key event tap applies the change itself and shows a `system.hud` activity; any key
/// it can't handle passes through to macOS, which then shows its own HUD. See docs/HUD.md.
///
/// Its own `@Observable` store, so a HUD change re-renders only views that read it.
@MainActor
@Observable
public final class HUDFeature {
    public enum State: Equatable, Sendable {
        case off
        case needsPermission
        case running
        case unavailable(String)
    }

    public private(set) var state: State = .off

    /// Environment variable that starts Liova with HUD replacement disabled.
    public static let safeModeEnvironmentKey = "LIOVA_SAFE_MODE"

    /// True when `LIOVA_SAFE_MODE=1` is set or the Option key is held. Read it at launch.
    public static var isSafeModeRequested: Bool {
        isSafeMode(
            environment: ProcessInfo.processInfo.environment,
            optionKeyHeld: NSEvent.modifierFlags.contains(.option)
        )
    }

    /// Echoes of our own volume changes arriving this soon after a key press never flash the HUD,
    /// even mid-change (e.g. after unmute but before the new level has landed).
    static let echoWindow: TimeInterval = 0.75

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let volume: any SystemVolumeControlling
    @ObservationIgnored private let brightness: any DisplayBrightnessControlling
    @ObservationIgnored private let keyTap: any MediaKeyTapping
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let isSafeMode: Bool
    /// The last volume state we've seen or set, for dropping duplicate listener callbacks.
    @ObservationIgnored private var lastVolume: VolumeState?
    /// When we last changed the volume ourselves, for ignoring the listener's echo.
    @ObservationIgnored private var lastOwnVolumeChange: Date?
    /// Shows the side bar instead of the notch HUD when the user chose that style.
    /// Set by the app; when nil, the HUD always appears in the notch.
    @ObservationIgnored public var sideHUD: ((SideHUDState) -> Void)?

    /// Creates the feature with the real Core Audio, DisplayServices and event-tap providers.
    /// Safe mode is checked here, so create the feature at launch.
    public convenience init(engine: ActivityEngine, settings: LiovaSettings) {
        self.init(
            engine: engine,
            settings: settings,
            volume: CoreAudioSystemVolume(),
            brightness: DisplayServicesBrightness(),
            keyTap: CGEventMediaKeyTap()
        )
    }

    public convenience init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        volume: any SystemVolumeControlling,
        brightness: any DisplayBrightnessControlling,
        keyTap: any MediaKeyTapping
    ) {
        self.init(
            engine: engine,
            settings: settings,
            volume: volume,
            brightness: brightness,
            keyTap: keyTap,
            now: Date.init,
            isSafeMode: Self.isSafeModeRequested
        )
    }

    init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        volume: any SystemVolumeControlling,
        brightness: any DisplayBrightnessControlling,
        keyTap: any MediaKeyTapping,
        now: @escaping @Sendable () -> Date,
        isSafeMode: Bool
    ) {
        self.engine = engine
        self.settings = settings
        self.volume = volume
        self.brightness = brightness
        self.keyTap = keyTap
        self.now = now
        self.isSafeMode = isSafeMode
    }

    // MARK: - Lifecycle

    /// Starts or stops the feature to match settings. Safe to call repeatedly.
    public func syncWithSettings() {
        guard settings.hudReplacementEnabled else {
            stop()
            return
        }
        guard !isSafeMode else {
            if state != .unavailable(Self.safeModeReason) {
                stop()
                state = .unavailable(Self.safeModeReason)
                Log.feature.notice("HUD replacement not started: safe mode")
            }
            return
        }
        start()
    }

    /// Shows the system Accessibility prompt. Call from the settings UI only, never unprompted.
    public func requestPermission() {
        keyTap.requestPermission()
        recheckPermission()
    }

    /// Re-checks the Accessibility permission, e.g. when the app becomes active. Starts the tap
    /// if permission was just granted; stops it if permission was revoked.
    public func recheckPermission() {
        switch state {
        case .needsPermission:
            if keyTap.isPermissionGranted {
                syncWithSettings()
            }
        case .running:
            if !keyTap.isPermissionGranted {
                tearDown()
                state = .needsPermission
                Log.feature.notice("HUD replacement paused: Accessibility permission revoked")
            }
        case .off, .unavailable:
            break
        }
    }

    /// Removes the tap, stops listening and clears the HUD. The system HUD takes over again.
    public func stop() {
        tearDown()
        if state != .off {
            state = .off
            Log.feature.info("HUD feature stopped")
        }
    }

    private func start() {
        guard state != .running else { return }
        let status = keyTap.start(
            onKey: { [weak self] event in
                self?.handle(event) ?? false
            },
            onStatusChange: { [weak self] status in
                self?.tapStatusChanged(status)
            }
        )
        switch status {
        case .running:
            state = .running
            lastVolume = nil
            lastOwnVolumeChange = nil
            volume.start { [weak self] newState in
                self?.volumeChanged(newState)
            }
            Log.feature.info("HUD feature started")
        case .needsPermission:
            state = .needsPermission
        case let .failed(reason):
            tearDown()
            state = .unavailable(reason)
        case .stopped:
            tearDown()
            state = .unavailable("The key event tap didn't start.")
        }
    }

    private func tearDown() {
        keyTap.stop()
        volume.stop()
        engine.end(HUDPolicy.activityID)
        lastVolume = nil
        lastOwnVolumeChange = nil
    }

    private func tapStatusChanged(_ status: MediaKeyTapStatus) {
        guard state == .running else { return }
        switch status {
        case .running:
            break
        case .needsPermission:
            tearDown()
            state = .needsPermission
        case let .failed(reason):
            tearDown()
            state = .unavailable(reason)
        case .stopped:
            tearDown()
            state = .unavailable("The key event tap stopped.")
        }
    }

    static let safeModeReason = "Safe mode is on, so the system HUD is used. Relaunch normally to turn it off."

    static func isSafeMode(environment: [String: String], optionKeyHeld: Bool) -> Bool {
        if optionKeyHeld {
            return true
        }
        guard let value = environment[safeModeEnvironmentKey]?.lowercased() else { return false }
        return ["1", "true", "yes"].contains(value)
    }
}

// MARK: - Keys and volume changes

extension HUDFeature {
    /// Applies a key press. Returns true only if the change was applied, so the tap swallows the
    /// key only then; otherwise macOS handles it and shows its own HUD.
    func handle(_ event: MediaKeyEvent) -> Bool {
        guard state == .running, event.isDown else { return false }
        return event.key.isVolumeKey ? handleVolumeKey(event) : handleBrightnessKey(event)
    }

    private func handleVolumeKey(_ event: MediaKeyEvent) -> Bool {
        guard let current = volume.state,
              let target = HUDPolicy.volumeTarget(for: event.key, current: current, fine: event.isFineStep)
        else { return false }
        let isMuteKey = event.key == .mute
        guard isMuteKey ? current.canMute : current.canSetVolume else { return false }

        // Set before applying: providers may report our own change synchronously.
        lastOwnVolumeChange = now()
        var applied = current
        if target.isMuted != current.isMuted {
            if volume.setMuted(target.isMuted) {
                applied.isMuted = target.isMuted
            } else if isMuteKey {
                return false
            }
        }
        if !HUDPolicy.isSameLevel(target.volume, current.volume) {
            guard volume.setVolume(target.volume) else {
                // Nothing changed: let macOS handle the key. If mute did change, we did act.
                return applied != current ? finishVolume(applied) : false
            }
            applied.volume = target.volume
        }
        return finishVolume(applied)
    }

    private func finishVolume(_ applied: VolumeState) -> Bool {
        lastVolume = applied
        show(HUDPolicy.volumeActivity(volume: applied.volume, isMuted: applied.isMuted, now: now()))
        return true
    }

    private func handleBrightnessKey(_ event: MediaKeyEvent) -> Bool {
        guard let current = brightness.brightness(),
              let target = HUDPolicy.brightnessTarget(for: event.key, current: current, fine: event.isFineStep)
        else { return false }
        if !HUDPolicy.isSameLevel(target, current) {
            guard brightness.setBrightness(target) else { return false }
        }
        show(HUDPolicy.brightnessActivity(brightness: target, now: now()))
        return true
    }

    /// Volume changed outside a key press we handled (Control Center, AirPods, another app),
    /// or this is the echo of our own change.
    func volumeChanged(_ new: VolumeState?) {
        let previous = lastVolume
        lastVolume = new
        guard state == .running, let new, let previous else { return }
        // A different output device isn't a volume change; macOS shows nothing either.
        guard new.deviceID == previous.deviceID, !HUDPolicy.isSameVolume(new, previous) else { return }
        if let lastOwnVolumeChange, now().timeIntervalSince(lastOwnVolumeChange) < Self.echoWindow {
            return
        }
        show(HUDPolicy.volumeActivity(volume: new.volume, isMuted: new.isMuted, now: now()))
    }

    private func show(_ activity: Activity) {
        if settings.hudStyle == .sideBar, let sideHUD {
            sideHUD(SideHUDState(
                kind: activity.title == "Brightness" ? .brightness : .volume,
                level: activity.progress ?? 0,
                isMuted: activity.subtitle == "Muted",
                symbol: activity.symbol ?? "speaker.wave.2.fill"
            ))
            return
        }
        do {
            // Same ID, so a press within the window updates the HUD in place and extends its expiry.
            try engine.start(activity)
        } catch {
            Log.feature.error("HUD activity rejected: \(String(describing: error), privacy: .public)")
        }
    }
}
