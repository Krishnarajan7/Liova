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
        let showsDetail = renderers.showsCompactDetail(for: engine.current)
        let isExpanded = model.presentation == .expanded
        let spec = NotchLayout.spec(
            for: model.presentation,
            geometry: model.geometry,
            hasActivity: hasActivity,
            compactDetail: showsDetail,
            contentHeight: model.fittedContentHeight
        )
        let idleVirtual = !model.geometry.hasHardwareNotch && !model.showsIdleVirtualNotch && !hasActivity
        let hidden = model.presentation == .closed && (idleVirtual || model.isCoveredByFullScreen)

        ZStack(alignment: .top) {
            NotchShape(topRadius: spec.topRadius, bottomRadius: spec.bottomRadius)
                .fill(.black)

            content(
                isExpanded: isExpanded,
                compactVisible: !isExpanded && !hidden,
                hasActivity: hasActivity,
                showsDetail: showsDetail
            )
            .frame(width: spec.shapeWidth, height: spec.height, alignment: .top)
            .clipShape(NotchShape(topRadius: spec.topRadius, bottomRadius: spec.bottomRadius))
        }
        .frame(width: spec.shapeWidth, height: spec.height)
        .contentShape(NotchShape(topRadius: spec.topRadius, bottomRadius: spec.bottomRadius))
        .onTapGesture(perform: onTap)
        .opacity(hidden ? 0 : 1)
        .animation(Motion.open, value: hasActivity)
        .animation(Motion.resize, value: showsDetail)
        .animation(Motion.resize, value: model.fittedContentHeight)
        .animation(.easeInOut(duration: 0.25), value: hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    /// Both layers can be mounted at once during a transition. Each one's visibility follows
    /// `isExpanded` through an animation, so reversing direction mid-flight (hover in, out, in)
    /// continues smoothly from wherever it is instead of restarting an insertion.
    ///
    /// Each layer has a **fixed size** (its own state's size, the open one at its tallest)
    /// and is centered at the top; the animating shape only clips it. Content never reflows while the notch grows or
    /// shrinks,
    /// which is what keeps the motion clean.
    private func content(isExpanded: Bool, compactVisible: Bool, hasActivity: Bool, showsDetail: Bool) -> some View {
        let expanded = NotchLayout.spec(for: .expanded, geometry: model.geometry, hasActivity: hasActivity)
        let compact = NotchLayout.spec(
            for: .closed,
            geometry: model.geometry,
            hasActivity: hasActivity,
            compactDetail: showsDetail
        )
        return ZStack(alignment: .top) {
            if let activity = engine.current {
                CompactView(
                    activity: activity,
                    renderer: renderers.renderer(for: activity),
                    notchSize: model.geometry.notchSize,
                    earWidth: NotchLayout.earWidth(for: model.geometry),
                    showsDetail: showsDetail,
                    detailInset: compact.bottomRadius
                )
                .frame(width: compact.bodyWidth, height: compact.height, alignment: .top)
                .opacity(isExpanded ? 0 : 1)
                .scaleEffect(isExpanded ? 0.85 : 1)
                .animation(isExpanded ? Motion.contentOut : Motion.compactContentIn, value: isExpanded)
                .environment(\.notchCompactVisible, compactVisible)
                .transition(.opacity.combined(with: .scale(scale: 0.8)).animation(Motion.compactContentIn))
            }
            if model.keepsExpandedContent || isExpanded {
                ExpandedView(model: model, engine: engine, renderers: renderers, chrome: chrome)
                    .frame(width: expanded.bodyWidth, height: expanded.height)
                    .environment(\.notchFileDragActive, model.isFileDragActive)
                    .opacity(isExpanded ? 1 : 0)
                    .scaleEffect(isExpanded ? 1 : 0.96, anchor: .top)
                    .animation(isExpanded ? Motion.expandedContentIn : Motion.contentOut, value: isExpanded)
                    .allowsHitTesting(isExpanded)
            }
        }
        .frame(width: max(expanded.shapeWidth, compact.shapeWidth), alignment: .top)
    }
}

/// Whether the closed notch's compact content is actually visible. Views with motion (the
/// music bars) pause when it isn't: the notch is open, hidden, or covered by a full-screen app.
public extension EnvironmentValues {
    @Entry var notchCompactVisible = true
    /// Files are being dragged onto the open notch: pages show drop targets.
    @Entry var notchFileDragActive = false
}

/// The closed notch with a live activity: an icon in the left ear, status in the right.
/// The middle stays empty so nothing is drawn under the camera. Some activities add a line
/// of text in a strip below the camera row.
struct CompactView: View {
    let activity: Activity
    let renderer: (any ActivityRenderer)?
    let notchSize: CGSize
    let earWidth: CGFloat
    let showsDetail: Bool
    /// Keeps the line clear of the strip's rounded bottom corners.
    let detailInset: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            renderer?.compactBackground(for: activity)
            VStack(spacing: 0) {
                ears
                    .frame(height: notchSize.height)
                if showsDetail, let detail = renderer?.compactDetail(for: activity) {
                    detail
                        .frame(maxWidth: .infinity)
                        .frame(height: NotchLayout.compactDetailHeight, alignment: .top)
                        .padding(.horizontal, detailInset)
                        // Arrives once the strip has mostly grown, leaves before it shrinks.
                        .transition(.asymmetric(
                            insertion: .opacity.animation(Motion.expandedContentIn),
                            removal: .opacity.animation(Motion.contentOut)
                        ))
                }
            }
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
            Color.clear.frame(width: notchSize.width)
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
