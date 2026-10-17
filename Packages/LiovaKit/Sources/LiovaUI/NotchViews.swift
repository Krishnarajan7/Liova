import LiovaCore
import LiovaPluginKit
import SwiftUI

/// Root of the notch panel: the animated shape and whatever it contains.
struct NotchRootView: View {
    let model: NotchModel
    let engine: ActivityEngine
    let renderers: ActivityRendererRegistry
    let chrome: NotchChrome
    let onTap: () -> Void

    var body: some View {
        let hasActivity = engine.current != nil
        let spec = NotchLayout.spec(for: model.presentation, geometry: model.geometry, hasActivity: hasActivity)
        let hidden = !model.geometry.hasHardwareNotch && !model.showsIdleVirtualNotch
            && model.presentation == .closed && !hasActivity

        ZStack(alignment: .top) {
            NotchShape(topRadius: spec.topRadius, bottomRadius: spec.bottomRadius)
                .fill(.black)

            content(spec: spec)
                .padding(.horizontal, spec.topRadius)
                .clipShape(NotchShape(topRadius: spec.topRadius, bottomRadius: spec.bottomRadius))
        }
        .frame(width: spec.shapeWidth, height: spec.height)
        .contentShape(NotchShape(topRadius: spec.topRadius, bottomRadius: spec.bottomRadius))
        .onTapGesture(perform: onTap)
        .opacity(hidden ? 0 : 1)
        .animation(Motion.open, value: hasActivity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func content(spec: NotchSpec) -> some View {
        switch model.presentation {
        case .expanded:
            ExpandedView(model: model, engine: engine, renderers: renderers, chrome: chrome)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                        .animation(Motion.expandedContentIn),
                    removal: .opacity.animation(Motion.contentOut)
                ))
        case .closed, .peek:
            if let activity = engine.current {
                CompactView(
                    activity: activity,
                    renderer: renderers.renderer(for: activity),
                    notchWidth: model.geometry.notchSize.width,
                    earWidth: NotchLayout.earWidth(for: model.geometry)
                )
                .frame(height: model.geometry.notchSize.height)
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.8))
                        .animation(Motion.compactContentIn),
                    removal: .opacity.animation(Motion.contentOut)
                ))
            }
        }
    }
}

/// The closed notch with a live activity: an icon in the left ear, status in the right.
/// The middle stays empty so nothing is drawn under the camera.
struct CompactView: View {
    let activity: Activity
    let renderer: (any ActivityRenderer)?
    let notchWidth: CGFloat
    let earWidth: CGFloat

    var body: some View {
        ZStack {
            renderer?.compactBackground(for: activity)
            ears
        }
    }

    private var ears: some View {
        HStack(spacing: 0) {
            Group {
                if let custom = renderer?.compactLeading(for: activity) {
                    custom
                } else {
                    ActivitySymbol(activity: activity, size: 15)
                }
            }
            .frame(width: earWidth)
            Color.clear.frame(width: notchWidth)
            Group {
                if let custom = renderer?.compactTrailing(for: activity) {
                    custom
                } else {
                    CompactTrailing(activity: activity)
                }
            }
            .frame(width: earWidth)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CompactTrailing: View {
    let activity: Activity

    var body: some View {
        if let progress = activity.progress {
            ProgressRing(progress: progress, tint: activity.tint.color)
                .frame(width: 16, height: 16)
        } else if let subtitle = activity.subtitle, subtitle.count <= 5 {
            Text(subtitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(activity.tint.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            Circle()
                .fill(activity.tint.color)
                .frame(width: 6, height: 6)
        }
    }
}

struct ActivitySymbol: View {
    let activity: Activity
    let size: CGFloat

    var body: some View {
        Image(systemName: activity.symbol ?? "sparkle")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(activity.tint.color)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size + 6, height: size + 6)
    }
}

/// A determinate ring. Values stream in without animation (performance rule 6).
struct ProgressRing: View {
    let progress: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .transaction { $0.animation = nil }
    }
}

/// A determinate bar. Values stream in without animation.
struct ProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(tint).frame(width: max(4, proxy.size.width * progress))
            }
        }
        .frame(height: 5)
        .transaction { $0.animation = nil }
    }
}
