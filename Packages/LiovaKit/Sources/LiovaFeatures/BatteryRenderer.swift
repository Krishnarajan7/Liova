import LiovaPluginKit
import LiovaUI
import SwiftUI

/// The charging moment.
///
/// Plugging in: a battery fills up to the current charge with a spring, a bolt pops in,
/// and a streak of green light sweeps left to right along the notch. Unplugging: the bolt
/// flies off, the fill cools from green to white and a faint light sweeps back right to
/// left. Full: one soft green glow. Low: red. Every effect is one-shot, so the closed notch
/// still never loops an animation.
@MainActor
public final class BatteryRenderer: ActivityRenderer {
    public init() {}

    public func compactLeading(for activity: Activity) -> AnyView? {
        AnyView(BatteryGlyph(style: Style(activity), level: activity.progress ?? 0))
    }

    public func compactTrailing(for activity: Activity) -> AnyView? {
        AnyView(
            Text("\(Int(((activity.progress ?? 0) * 100).rounded()))%")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Style(activity).color)
                .contentTransition(.numericText())
        )
    }

    public func compactBackground(for activity: Activity) -> AnyView? {
        switch Style(activity) {
        case .charging: AnyView(EnergySweep(color: .green, reversed: false))
        case .full: AnyView(SoftGlow(color: .green))
        case .low: AnyView(SoftGlow(color: .red))
        case .onBattery: AnyView(EnergySweep(color: .white.opacity(0.7), reversed: true))
        }
    }

    enum Style {
        case charging, full, onBattery, low

        init(_ activity: Activity) {
            self = switch activity.title {
            case "Charging": .charging
            case "Fully Charged": .full
            case "Low Battery": .low
            default: .onBattery
            }
        }

        var color: Color {
            switch self {
            case .charging, .full: .green
            case .low: .red
            case .onBattery: .white.opacity(0.85)
            }
        }
    }
}

/// A drawn battery whose fill springs from empty to the current level when it appears.
private struct BatteryGlyph: View {
    let style: BatteryRenderer.Style
    let level: Double
    @State private var shownLevel = 0.0
    @State private var boltVisible = false
    /// Unplugging starts "still charging" (green, bolt) and cools down.
    @State private var unplugged = false

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 1.2)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(style == .onBattery && !unplugged ? Color.green : style.color)
                    .frame(width: max(2, 19 * shownLevel))
                    .padding(2)
                if style == .charging || style == .full || style == .onBattery {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .frame(maxWidth: .infinity)
                        .scaleEffect(boltVisible ? 1 : (style == .onBattery ? 1.4 : 0.2))
                        .offset(y: boltVisible || style != .onBattery ? 0 : -9)
                        .opacity(boltVisible ? 1 : 0)
                }
            }
            .frame(width: 23, height: 12)
            RoundedRectangle(cornerRadius: 1)
                .fill(.white.opacity(0.45))
                .frame(width: 1.5, height: 4.5)
        }
        .onAppear {
            if style == .onBattery {
                // The bolt starts in place, then flies up and away as the fill cools.
                shownLevel = level
                boltVisible = true
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7).delay(0.25)) {
                    boltVisible = false
                }
                withAnimation(.easeInOut(duration: 0.8).delay(0.3)) {
                    unplugged = true
                }
                return
            }
            // Plugging in fills from empty; other states start where they are.
            shownLevel = style == .charging ? 0 : level
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.15)) {
                shownLevel = level
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55).delay(0.45)) {
                boltVisible = true
            }
        }
        .onChange(of: level) { _, new in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { shownLevel = new }
        }
    }
}

/// One streak of light sweeping along the notch: left to right when power arrives,
/// right to left when it leaves.
private struct EnergySweep: View {
    let color: Color
    let reversed: Bool
    @State private var progress = -0.3

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [color.opacity(0), color.opacity(0.45), color.opacity(0)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: proxy.size.width * 0.35)
            .offset(x: proxy.size.width * (reversed ? 0.75 - progress : progress))
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).delay(0.2)) { progress = 1.05 }
        }
    }
}

/// A single soft pulse of color filling the notch, then fading away.
private struct SoftGlow: View {
    let color: Color
    @State private var opacity = 0.0

    var body: some View {
        RadialGradient(colors: [color.opacity(0.35), color.opacity(0)], center: .bottom, startRadius: 0, endRadius: 140)
            .opacity(opacity)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.35)) { opacity = 1 }
                withAnimation(.easeIn(duration: 0.9).delay(0.6)) { opacity = 0 }
            }
    }
}
