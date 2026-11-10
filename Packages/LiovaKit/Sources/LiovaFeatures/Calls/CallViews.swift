import AppKit
import LiovaPluginKit
import LiovaProviders
import LiovaUI
import SwiftUI

/// A call in the closed notch: the mic on the left, green when live and red when muted, so
/// the mute is visible at a glance; how long the call has run on the right. Open, the app,
/// and round Mute and Hang Up buttons.
@MainActor
public final class CallRenderer: ActivityRenderer {
    private let feature: CallFeature

    public init(feature: CallFeature) {
        self.feature = feature
    }

    public func compactLeading(for _: Activity) -> AnyView? {
        AnyView(CallMicGlyph(isMuted: feature.isMuted))
    }

    public func compactTrailing(for _: Activity) -> AnyView? {
        guard let call = feature.call else { return nil }
        return AnyView(
            Text(call.startedAt, style: .timer)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .fixedSize()
        )
    }

    public func expanded(for _: Activity) -> AnyView? {
        guard feature.call != nil else { return nil }
        return AnyView(CallCard(feature: feature))
    }
}

private struct CallMicGlyph: View {
    let isMuted: Bool

    var body: some View {
        Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isMuted ? CallColors.muted : CallColors.live)
            .contentTransition(.symbolEffect(.replace))
            .animation(Motion.swap, value: isMuted)
    }
}

enum CallColors {
    static let live = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let muted = Color(red: 1, green: 0.27, blue: 0.23)
}

private struct CallCard: View {
    let feature: CallFeature

    var body: some View {
        if let call = feature.call {
            HStack(spacing: 12) {
                Image(nsImage: Self.icon(for: call.app))
                    .resizable()
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(call.app.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(call.startedAt, style: .timer)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    status
                }
                Spacer(minLength: 0)
                CallButton(
                    symbol: feature.isMuted ? "mic.slash.fill" : "mic.fill",
                    label: feature.isMuted ? "Unmute" : "Mute",
                    style: feature.isMuted ? .active : .idle
                ) {
                    feature.toggleMute()
                }
                .disabled(!feature.canMute)
                .help(feature.canMute ? "Mutes the microphone for every app" : "This microphone can't be muted")
                CallButton(symbol: "phone.down.fill", label: "Hang Up", style: .destructive) {
                    feature.hangUp()
                }
                .help("Presses the app's own Leave or End button")
            }
            .animation(Motion.swap, value: feature.isMuted)
            .animation(Motion.swap, value: feature.hangUpProblem)
        }
    }

    @ViewBuilder private var status: some View {
        switch feature.hangUpProblem {
        case .needsPermission:
            Text("Allow Liova in Accessibility to hang up from here")
                .foregroundStyle(LoadLevel.busy.color)
        case .notFound:
            Text("Couldn't find its Leave button. Bring the call's window or tab forward.")
                .foregroundStyle(LoadLevel.busy.color)
        case .done, nil:
            Text(feature.isMuted ? "Your microphone is off" : "Your microphone is on")
                .foregroundStyle(feature.isMuted ? CallColors.muted : .white.opacity(0.55))
        }
    }

    private static func icon(for app: MicrophoneUser) -> NSImage {
        NSRunningApplication(processIdentifier: app.pid)?.icon
            ?? NSWorkspace.shared.icon(for: .application)
    }
}

/// A round button with its label under it, like the iPhone's call screen.
private struct CallButton: View {
    enum Style {
        case idle, active, destructive
    }

    let symbol: String
    let label: String
    let style: Style
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(style == .active ? .black : .white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 38, height: 38)
                    .background(background, in: Circle())
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize()
            }
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var background: Color {
        switch style {
        case .idle: .white.opacity(0.16)
        case .active: .white
        case .destructive: CallColors.muted
        }
    }
}
