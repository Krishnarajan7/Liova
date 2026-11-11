import AppKit
import LiovaPluginKit
import LiovaProviders
import LiovaUI
import SwiftUI

/// A recording in the closed notch: a breathing red dot (a pause sign while paused) and
/// the time. Open, Pause or Resume and Stop.
@MainActor
public final class RecordingRenderer: ActivityRenderer {
    private let feature: RecordingFeature

    public init(feature: RecordingFeature) {
        self.feature = feature
    }

    public func compactLeading(for _: Activity) -> AnyView? {
        AnyView(RecordingDot(isPaused: feature.recording?.isPaused ?? false))
    }

    public func compactTrailing(for _: Activity) -> AnyView? {
        guard let recording = feature.recording else { return nil }
        return AnyView(
            RecordingClock(recording: recording)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(recording.isPaused ? Color.orange : .white.opacity(0.9))
        )
    }

    public func expanded(for _: Activity) -> AnyView? {
        guard feature.recording != nil else { return nil }
        return AnyView(RecordingControls(feature: feature))
    }
}

enum RecordingColors {
    static let live = Color(red: 1, green: 0.23, blue: 0.19)
    static let paused = Color.orange
}

/// Breathes slowly while recording, so it reads as live without flashing. Still with Reduce Motion.
struct RecordingDot: View {
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        ZStack {
            if isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(RecordingColors.paused)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else {
                Circle()
                    .fill(RecordingColors.live)
                    .frame(width: 9, height: 9)
                    .shadow(color: RecordingColors.live.opacity(breathing ? 0.8 : 0.2), radius: breathing ? 4 : 1)
                    .scaleEffect(breathing ? 1 : 0.82)
                    .opacity(breathing ? 1 : 0.7)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .frame(width: 14, height: 14)
        .animation(Motion.swap, value: isPaused)
        .onAppear { breathe() }
        .onChange(of: isPaused) { breathe() }
    }

    private func breathe() {
        guard !reduceMotion, !isPaused else {
            breathing = true
            return
        }
        breathing = false
        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }
}

/// The recorded time, ticking while recording and held while paused.
struct RecordingClock: View {
    let recording: Recording

    var body: some View {
        Text(
            timerInterval: recording.clockStart ... Date.distantFuture,
            pauseTime: recording.isPaused ? recording.measuredAt : nil,
            countsDown: false
        )
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .contentTransition(.numericText())
    }
}

/// The open notch while recording: where it's recording, how long, and the buttons.
struct RecordingControls: View {
    let feature: RecordingFeature

    var body: some View {
        if let recording = feature.recording {
            HStack(spacing: 12) {
                RecordingSourceIcon(source: recording.source)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        RecordingDot(isPaused: recording.isPaused)
                        Text(recording.isPaused ? "Paused" : "Recording")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(recording.isPaused ? RecordingColors.paused : .white)
                            .contentTransition(.opacity)
                    }
                    RecordingClock(recording: recording)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(recording.source == .obs ? "In OBS" : "macOS screen recording")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
                if recording.canPause {
                    RoundButton(
                        symbol: recording.isPaused ? "play.fill" : "pause.fill",
                        label: recording.isPaused ? "Resume" : "Pause",
                        fill: .white.opacity(0.16)
                    ) { feature.togglePause() }
                }
                RoundButton(symbol: "stop.fill", label: "Stop", fill: RecordingColors.live) {
                    feature.stopRecording()
                }
            }
            .animation(Motion.swap, value: recording.isPaused)
        }
    }
}

struct RecordingSourceIcon: View {
    let source: Recording.Source

    var body: some View {
        Image(nsImage: Self.icon(for: source))
            .resizable()
            .frame(width: 38, height: 38)
    }

    static func icon(for source: Recording.Source) -> NSImage {
        let bundleID = source == .obs ? RecordingFeature.obsBundleID : "com.apple.screenshot.launcher"
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// A round button with its label under it.
struct RoundButton: View {
    let symbol: String
    let label: String
    let fill: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 38, height: 38)
                    .background(fill.opacity(isHovered ? 1 : 0.85), in: Circle())
                    .scaleEffect(isHovered ? 1.06 : 1)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .contentTransition(.opacity)
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityLabel(label)
    }
}

/// The Record page: start a recording in OBS or with macOS, or control the one going.
public struct RecordingPage: View {
    let feature: RecordingFeature

    public init(feature: RecordingFeature) {
        self.feature = feature
    }

    public var body: some View {
        Group {
            if feature.recording != nil {
                RecordingControls(feature: feature)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                HStack(spacing: 10) {
                    StartTile(
                        title: "Record screen", detail: "macOS · pick an area or window",
                        icon: RecordingSourceIcon.icon(for: .screen)
                    ) { feature.openScreenToolbar() }
                    obsTile
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.list, value: feature.recording == nil)
    }

    @ViewBuilder private var obsTile: some View {
        let icon = RecordingSourceIcon.icon(for: .obs)
        switch feature.obs {
        case .connected:
            StartTile(title: "Record in OBS", detail: "With your scenes and audio", icon: icon) {
                feature.startOBSRecording()
            }
        case .connecting:
            StartTile(title: "OBS", detail: "Connecting…", icon: icon, action: nil)
        case .needsPassword:
            StartTile(title: "OBS", detail: "Add its WebSocket password in Liova's Settings", icon: icon, action: nil)
        case .serverOff:
            StartTile(title: "OBS", detail: "Turn on Tools → WebSocket Server Settings", icon: icon, action: nil)
        case .disconnected:
            StartTile(title: "OBS", detail: feature.isOBSOpen ? "Can't reach OBS" : "Open OBS", icon: icon) {
                feature.openOBS()
            }
        }
    }
}

private struct StartTile: View {
    let title: String
    let detail: String
    let icon: NSImage
    let action: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 10) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if action != nil, title.hasPrefix("Record") {
                            Circle().fill(RecordingColors.live).frame(width: 7, height: 7)
                        }
                        Text(title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(
                .white.opacity(isHovered && action != nil ? 0.13 : 0.07),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}
