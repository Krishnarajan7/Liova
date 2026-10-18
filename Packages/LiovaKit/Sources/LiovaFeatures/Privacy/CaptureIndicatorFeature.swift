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
        engine.endAll(source: CapturePolicy.source)
    }

    func receive(_ new: CaptureState) {
        let old = state
        state = new
        if let flash = CapturePolicy.flash(from: old, to: new, now: now()) {
            try? engine.start(flash)
        }
    }
}

/// Pure mapping, so it's unit-tested.
public enum CapturePolicy {
    public static let source = "system.capture"
    public static let flashID: ActivityID = "system.capture.flash"
    public static let flashDuration: TimeInterval = 3

    /// A brief flash when something turns *on*; nothing when things turn off.
    public static func flash(from old: CaptureState, to new: CaptureState, now: Date) -> Activity? {
        let cameraStarted = new.isCameraOn && !old.isCameraOn
        let micStarted = new.isMicrophoneOn && !old.isMicrophoneOn
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

    public init(feature: CaptureIndicatorFeature) {
        self.feature = feature
    }

    public var body: some View {
        HStack(spacing: 4) {
            if feature.state.isCameraOn {
                Image(systemName: "video.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.green)
                    .help("A camera is in use")
                    .transition(.scale.combined(with: .opacity))
            }
            if feature.state.isMicrophoneOn {
                Image(systemName: "mic.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.orange)
                    .help("A microphone is in use")
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: feature.state)
    }
}
