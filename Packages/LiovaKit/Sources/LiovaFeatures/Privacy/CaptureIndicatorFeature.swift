import Foundation
import LiovaCore
import LiovaPluginKit
import LiovaProviders
import Observation
import SwiftUI

/// A privacy indicator: when any app turns on the camera or microphone, the notch flashes
/// it, and while it stays on a colored dot sits by the battery in the open notch. Useful in
/// full-screen apps, where the menu bar's own indicator is hidden.
@MainActor
@Observable
public final class CaptureIndicatorFeature {
    public private(set) var state = CaptureState.off

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let monitor: any CaptureMonitoring
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var isRunning = false
    /// When the camera and microphone last turned off, to tell a restart from a new start.
    @ObservationIgnored private var cameraOffAt: Date?
    @ObservationIgnored private var microphoneOffAt: Date?

    public init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        monitor: any CaptureMonitoring = SystemCaptureMonitor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.engine = engine
        self.settings = settings
        self.monitor = monitor
        self.now = now
    }

    public func syncWithSettings() {
        if settings.captureIndicatorEnabled {
            guard !isRunning else { return }
            isRunning = true
            monitor.start { [weak self] new in self?.receive(new) }
        } else {
            stop()
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        monitor.stop()
        state = .off
        cameraOffAt = nil
        microphoneOffAt = nil
        engine.endAll(source: CapturePolicy.source)
    }

    func receive(_ new: CaptureState) {
        let old = state
        let date = now()
        state = new
        if let flash = CapturePolicy.flash(
            from: old, to: new, now: date, cameraOffAt: cameraOffAt, microphoneOffAt: microphoneOffAt
        ) {
            try? engine.start(flash)
        }
        if old.isCameraOn, !new.isCameraOn {
            cameraOffAt = date
        }
        if old.isMicrophoneOn, !new.isMicrophoneOn {
            microphoneOffAt = date
        }
    }
}

/// Pure mapping, so it's unit-tested.
public enum CapturePolicy {
    public static let source = "system.capture"
    public static let flashID: ActivityID = "system.capture.flash"
    public static let flashDuration: TimeInterval = 3
    /// Back on within this long of turning off is the same session restarting, not a new
    /// start: unplugging a headset makes a call app drop its mic and pick up the built-in one.
    public static let restartGrace: TimeInterval = 5

    /// A brief flash when something turns *on*; nothing when things turn off, or when they
    /// come straight back after a blip.
    public static func flash(
        from old: CaptureState,
        to new: CaptureState,
        now: Date,
        cameraOffAt: Date? = nil,
        microphoneOffAt: Date? = nil
    ) -> Activity? {
        func isRestart(_ offAt: Date?) -> Bool {
            offAt.map { now.timeIntervalSince($0) < restartGrace } ?? false
        }
        let cameraStarted = new.isCameraOn && !old.isCameraOn && !isRestart(cameraOffAt)
        let micStarted = new.isMicrophoneOn && !old.isMicrophoneOn && !isRestart(microphoneOffAt)
        guard cameraStarted || micStarted else { return nil }
        let title = switch (new.isCameraOn, new.isMicrophoneOn) {
        case (true, true): "Camera and microphone on"
        case (true, false): "Camera on"
        default: "Microphone on"
        }
        return Activity(
            id: flashID, source: source, priority: .high, title: title,
            symbol: new.isCameraOn ? "video.fill" : "mic.fill",
            tint: new.isCameraOn ? .green : .orange,
            expiresAt: now + flashDuration
        )
    }
}

/// Dots for the open notch header: green for camera, orange for microphone.
public struct CaptureStatusView: View {
    let feature: CaptureIndicatorFeature
    /// Dots instead of icons, like macOS's own indicators, for a crowded header.
    let isCompact: Bool

    public init(feature: CaptureIndicatorFeature, isCompact: Bool = false) {
        self.feature = feature
        self.isCompact = isCompact
    }

    public var body: some View {
        HStack(spacing: isCompact ? 3 : 4) {
            if feature.state.isCameraOn {
                indicator(symbol: "video.fill", color: .green)
                    .help("A camera is in use")
                    .transition(.scale.combined(with: .opacity))
            }
            if feature.state.isMicrophoneOn {
                indicator(symbol: "mic.fill", color: .orange)
                    .help("A microphone is in use")
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: feature.state)
    }

    @ViewBuilder private func indicator(symbol: String, color: Color) -> some View {
        if isCompact {
            Circle().fill(color).frame(width: 6, height: 6)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(color)
        }
    }
}
