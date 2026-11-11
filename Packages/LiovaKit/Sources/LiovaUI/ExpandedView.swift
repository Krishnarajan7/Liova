import LiovaCore
import LiovaPluginKit
import SwiftUI

/// The open notch. Shows the visible activity in detail and the rest of the stack below it.
struct ExpandedView: View {
    let model: NotchModel
    let engine: ActivityEngine
    let renderers: ActivityRendererRegistry
    let chrome: NotchChrome
    /// One selection highlight for both halves of the page bar, so it slides across.
    @Namespace private var pageHighlight

    private static let maxQueued = 2
    private static let horizontalPadding: CGFloat = 18
    private static let headerSpacing: CGFloat = 10
    private static let bottomPadding: CGFloat = 14
    /// Activities ending within this window are "brief" (a charging flash, a HUD, a finished
    /// agent turn). In the open notch they appear as a chip beside the camera instead of
    /// taking over the main card, so what you opened the notch for stays put.
    static let briefWindow: TimeInterval = 15

    static func isBrief(_ activity: Activity, now: Date) -> Bool {
        guard let expiresAt = activity.expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= briefWindow
    }

    var body: some View {
        let brief = engine.activities.first { Self.isBrief($0, now: Date()) }
        VStack(alignment: .leading, spacing: Self.headerSpacing) {
            header(brief: brief)
            page
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.bottom, Self.bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.openNotchPage, OpenNotchPageAction { [model] id in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                model.selectedPage = id
            }
        })
    }

    /// The row beside the camera: pages on the left, status on the right. The middle stays
    /// empty so nothing is ever drawn under the camera; pages that don't fit left of it go
    /// on the right, before the status.
    private func header(brief: Activity?) -> some View {
        let notch = model.geometry.notchSize
        let ids = chrome.barPageIDs
        let leftIDs = Array(ids.prefix(PageBar.leftLimit))
        let rightIDs = Array(ids.dropFirst(PageBar.leftLimit))
        return HStack(spacing: 0) {
            HStack {
                if ids.count > 1 {
                    PageBar(model: model, chrome: chrome, ids: leftIDs, highlight: pageHighlight)
                }
                Spacer(minLength: 0)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            Color.clear.frame(width: notch.width + 8)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if !rightIDs.isEmpty {
                    PageBar(model: model, chrome: chrome, ids: rightIDs, highlight: pageHighlight)
                }
                if let brief {
                    BriefChip(activity: brief)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
                } else if let status = chrome.trailingStatus {
                    // First claim on the space: otherwise the spacer shares it and a status
                    // that adapts to its width (ViewThatFits) is offered too little.
                    status()
                        .layoutPriority(1)
                        .transition(.opacity)
                }
                if let openSettings = chrome.openSettings {
                    HeaderButton(symbol: "gearshape.fill", action: openSettings)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .frame(height: max(notch.height - 6, 0))
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: brief?.id)
    }

    /// The selected page at its natural height, which the notch fits around: the camera
    /// row, the page and the bottom margin, and nothing more.
    private var page: some View {
        let selected = chrome.allPageIDs.contains(model.selectedPage) ? model.selectedPage : NotchChrome.homePageID
        return NaturalHeightLayout {
            ZStack(alignment: .topLeading) {
                if selected == NotchChrome.homePageID {
                    HomePage(engine: engine, renderers: renderers)
                        .transition(Self.pageTransition)
                } else if let page = chrome.visiblePages.first(where: { $0.id == selected }) {
                    page.content()
                        .transition(Self.pageTransition)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded(.up) }, action: { [model] height in
            // Below the camera row: what the header doesn't already cover, plus the margins.
            let needed = height + Self.headerSpacing + Self.bottomPadding - 6
            if model.expandedContentHeight != needed {
                model.expandedContentHeight = needed
            }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: selected)
    }

    private static let pageTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .offset(y: 6)),
        removal: .opacity
    )
}

/// Live activities: the main card and what's queued beneath it.
private struct HomePage: View {
    let engine: ActivityEngine
    let renderers: ActivityRendererRegistry

    var body: some View {
        let now = Date()
        let lasting = engine.activities.filter { !ExpandedView.isBrief($0, now: now) }
        let brief = engine.activities.first { ExpandedView.isBrief($0, now: now) }
        VStack(alignment: .leading, spacing: 10) {
            if let current = lasting.first ?? brief {
                let renderer = renderers.renderer(for: current)
                Group {
                    if let custom = renderer?.expanded(for: current) {
                        custom
                    } else {
                        ActivityCard(activity: current)
                    }
                }
                .id(current.id)
                .transition(Self.cardTransition)
                let room = renderer?.expandedNeedsFullHeight(for: current) == true
                    ? 0 : renderer?.expandedQueueRoom(for: current) ?? 2
                let queued = lasting.dropFirst().prefix(room)
                if !queued.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(queued) { activity in
                            ActivityRow(activity: activity) {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                                    engine.bringToFront(activity.id)
                                }
                            }
                            .transition(Motion.listItem)
                        }
                    }
                }
                Spacer(minLength: 0)
            } else {
                EmptyState()
                    .frame(maxHeight: .infinity)
            }
        }
        // Activities arriving and leaving while open (a download starting, finishing) move
        // into place instead of snapping.
        .animation(Motion.list, value: lasting.map(\.id))
    }

    /// The main card changing hands: the new one rises in as the old one fades.
    private static let cardTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .offset(y: 6)).animation(Motion.swap.delay(0.05)),
        removal: .opacity.animation(Motion.contentOut)
    )
}

/// Page icons with a highlight that slides to the selected one.
private struct PageBar: View {
    let model: NotchModel
    let chrome: NotchChrome
    let ids: [String]
    let highlight: Namespace.ID

    /// Left of the camera is about 125 pt on a 14" MacBook: six slim icons. The right side
    /// shares its room with the status and the gear, so it takes the rest.
    static let leftLimit = 6

    var body: some View {
        let width: CGFloat = ids.count > 5 ? 19 : ids.count > 4 ? 22 : 26
        HStack(spacing: ids.count > 4 ? 1 : 2) {
            ForEach(ids, id: \.self) { id in
                let isSelected = model.selectedPage == id
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        model.selectedPage = id
                    }
                } label: {
                    Image(systemName: symbol(for: id))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(isSelected ? 1 : 0.45))
                        .frame(width: width, height: 22)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(.white.opacity(0.15))
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(title(for: id))
            }
        }
    }

    private func symbol(for id: String) -> String {
        id == NotchChrome.homePageID ? "house.fill" : chrome.pages.first { $0.id == id }?.symbol ?? "circle"
    }

    private func title(for id: String) -> String {
        id == NotchChrome.homePageID ? "Home" : chrome.pages.first { $0.id == id }?.title ?? ""
    }
}

private struct HeaderButton: View {
    let symbol: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 0.9 : 0.45))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// A brief event, shown small beside the camera while the notch is open.
private struct BriefChip: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 5) {
            ActivitySymbol(activity: activity, size: 11)
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(activity.tint.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(activity.tint.color.opacity(0.14), in: Capsule())
        .frame(maxWidth: 120, alignment: .trailing)
    }

    private var label: String {
        if let progress = activity.progress {
            return "\(Int((progress * 100).rounded()))%"
        }
        return activity.subtitle ?? activity.title
    }
}

private struct ActivityCard: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 12) {
            ActivitySymbol(activity: activity, size: 22)
                .frame(width: 40, height: 40)
                .background(activity.tint.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle = activity.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                if let progress = activity.progress {
                    ProgressBar(progress: progress, tint: activity.tint.color)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
            if let progress = activity.progress {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
                    .contentTransition(.numericText())
            }
        }
    }
}

/// Something else that's live. Tapping it brings it to the front, open and closed.
private struct ActivityRow: View {
    let activity: Activity
    let bringToFront: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: bringToFront) {
            HStack(spacing: 8) {
                ActivitySymbol(activity: activity, size: 11)
                Text(activity.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(isHovered ? 0.95 : 0.75))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let progress = activity.progress {
                    ProgressBar(progress: progress, tint: activity.tint.color)
                        .frame(width: 60)
                }
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(isHovered ? 0.1 : 0)))
            .padding(.horizontal, -6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help("Show \(activity.title) first")
        .accessibilityHint(Text("Shows this activity first"))
    }
}

private struct EmptyState: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing live right now")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Activities from your Mac, apps and agents appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Sizes its content at the height it would like (Spacers collapsed, stacks at their
/// natural size), up to what's offered. Measures and places in one pass, so nothing is
/// built twice.
struct NaturalHeightLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let natural = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, proposal.height ?? .infinity))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
