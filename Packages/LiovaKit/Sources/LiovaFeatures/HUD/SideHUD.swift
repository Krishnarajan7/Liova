import AppKit
import LiovaCore
import Observation
import SwiftUI

/// What the side HUD shows.
public struct SideHUDState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case volume
        case brightness
    }

    /// How the level is drawn at the screen's edge.
    public enum Look: Equatable, Sendable {
        /// A pill that fills with the level.
        case pill
        /// A line of light along the edge, as long as the level.
        case light
    }

    public var kind: Kind
    /// 0…1.
    public var level: Double
    public var isMuted: Bool
    public var symbol: String
    public var look: Look

    public init(kind: Kind, level: Double, isMuted: Bool = false, symbol: String, look: Look = .pill) {
        self.kind = kind
        self.level = min(max(level, 0), 1)
        self.isMuted = isMuted
        self.symbol = symbol
        self.look = look
    }

    /// The colour at a height on the scale (0 at the bottom, 1 at the top). Volume is an old
    /// hi-fi's level meter: green while it's comfortable, amber as it gets loud, red at the
    /// top. Brightness warms from amber to daylight.
    func color(at fraction: Double) -> Color {
        switch kind {
        case .volume:
            if fraction < 0.6 {
                Color(red: 0.36, green: 0.9, blue: 0.47)
            } else if fraction < 0.85 {
                Color(red: 1, green: 0.76, blue: 0.22)
            } else {
                Color(red: 1, green: 0.36, blue: 0.3)
            }
        case .brightness:
            Color(red: 1, green: 0.72 + 0.25 * fraction, blue: 0.3 + 0.6 * fraction)
        }
    }

    /// The same scale as a gradient, bottom to top, for a continuous line.
    var scale: LinearGradient {
        let stops: [Gradient.Stop] = switch kind {
        case .volume: [
                .init(color: color(at: 0), location: 0), .init(color: color(at: 0), location: 0.5),
                .init(color: color(at: 0.7), location: 0.74), .init(color: color(at: 1), location: 0.96),
            ]
        case .brightness: [.init(color: color(at: 0), location: 0), .init(color: color(at: 1), location: 1)]
        }
        return LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top)
    }

    /// The level that's shown: nothing while muted.
    var shownLevel: Double {
        isMuted ? 0 : level
    }
}

/// A vertical level pill at the edge of the screen: volume on the right, brightness on the
/// left (create one controller per edge).
///
/// One borderless, click-through panel, created on first use and reused. It's on screen
/// only while visible: after the hide animation it's ordered out, so it costs nothing
/// between key presses.
@MainActor
public final class SideHUDController {
    public enum Edge: Sendable {
        case leading
        case trailing
    }

    /// How long the bar stays after the last change.
    static let displayDuration: Duration = .milliseconds(1500)
    static let panelSize = CGSize(width: 96, height: 300)

    private let model: SideHUDModel
    private let edge: Edge
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    public init(edge: Edge) {
        self.edge = edge
        model = SideHUDModel(edge: edge)
    }

    public func show(_ state: SideHUDState) {
        let panel = panel ?? makePanel()
        self.panel = panel
        if !model.isVisible {
            position(panel, flush: state.look == .light)
            panel.orderFrontRegardless()
        }
        // Already on screen and still at an end: the key was pressed with nowhere left to go.
        if model.isVisible, state == model.state, Self.isAtLimit(state) {
            model.limitHits += 1
        }
        // A little overshoot, so the fill lands rather than stops.
        withAnimation(.spring(response: 0.26, dampingFraction: 0.78)) {
            model.state = state
            model.isVisible = true
        }
        scheduleHide()
        logPlacement(panel, moment: "shown")
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, let panel = self.panel else { return }
            logPlacement(panel, moment: "settled")
        }
    }

    /// Where the bar is and whether macOS considers it visible, for diagnosing a bar that
    /// doesn't appear (e.g. over a full-screen app).
    private func logPlacement(_ panel: NSPanel, moment: String) {
        let frame = NSStringFromRect(panel.frame)
        let screen = NSStringFromRect(panel.screen?.frame ?? .zero)
        let visible = panel.occlusionState.contains(.visible)
        Log.display.notice(
            """
            Side HUD \(moment, privacy: .public): frame \(frame, privacy: .public), \
            screen \(screen, privacy: .public), onActiveSpace \(panel.isOnActiveSpace), \
            visible \(visible), window \(panel.windowNumber), alpha \(panel.alphaValue)
            """
        )
    }

    /// Nothing left to turn down, or up.
    static func isAtLimit(_ state: SideHUDState) -> Bool {
        state.isMuted || state.level <= 0 || state.level >= 1
    }

    public func hide() {
        hideTask?.cancel()
        guard model.isVisible else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 1)) {
            model.isVisible = false
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, !model.isVisible else { return }
            panel?.orderOut(nil)
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.displayDuration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Its edge, vertically centered, on the display with the pointer.
    private func position(_ panel: NSPanel, flush: Bool) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = Self.panelSize
        panel.setFrame(
            CGRect(
                x: edge == .trailing ? visible.maxX - size.width - (flush ? 0 : 4) : visible.minX + (flush ? 0 : 4),
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: false
        )
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: SideHUDView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

@MainActor
@Observable
final class SideHUDModel {
    let edge: SideHUDController.Edge
    var state = SideHUDState(kind: .volume, level: 0, symbol: "speaker.wave.2.fill")
    var isVisible = false
    /// Counts presses that arrive with the level already at an end (or muted).
    var limitHits = 0

    init(edge: SideHUDController.Edge) {
        self.edge = edge
    }
}

/// The side bar in either look, sliding in from its edge.
struct SideHUDView: View {
    let model: SideHUDModel

    var body: some View {
        switch model.state.look {
        case .pill: pill
        case .light: EdgeLight(model: model)
        }
    }

    private var pill: some View {
        LevelPill(state: model.state)
            // A press at either end still answers: the pill gives, like a button at its stop.
            .keyframeAnimator(initialValue: 0.0, trigger: model.limitHits) { pill, squash in
                pill.scaleEffect(x: 1 + squash * 0.05, y: 1 - squash * 0.04)
            } keyframes: { _ in
                CubicKeyframe(1, duration: 0.09)
                SpringKeyframe(0, duration: 0.3, spring: .bouncy)
            }
            .environment(\.colorScheme, .dark)
            .offset(x: model.isVisible ? 0 : (model.edge == .trailing ? 80 : -80))
            .opacity(model.isVisible ? 1 : 0)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: model.edge == .trailing ? .trailing : .leading
            )
            .padding(model.edge == .trailing ? .trailing : .leading, 14)
    }
}

/// One pill that *is* the level: it fills from the bottom, smoothly, in an old hi-fi meter's
/// colours (green, then amber, then red towards the top; amber to daylight for brightness).
/// Each height keeps its colour, so turning it up reveals more of the scale. The symbol
/// inside turns dark where the fill covers it. The case is dark grey with a light rim, so
/// it stands out on a black window as well as a bright one.
private struct LevelPill: View {
    let state: SideHUDState

    static let size = CGSize(width: 44, height: 152)

    var body: some View {
        GeometryReader { proxy in
            let filled = proxy.size.height * state.shownLevel
            ZStack(alignment: .bottom) {
                Color(white: 0.11).opacity(0.94)
                state.scale
                    .mask(alignment: .bottom) { Rectangle().frame(height: filled) }
                symbol(.white.opacity(0.92))
                symbol(.black.opacity(0.8))
                    .mask(alignment: .bottom) { Rectangle().frame(height: filled) }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }

    /// Pinned near the bottom, so it's covered (and turns dark) from about a sixth up.
    private func symbol(_ color: Color) -> some View {
        Image(systemName: state.symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .contentTransition(.symbolEffect(.replace))
            .frame(height: 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 15)
    }
}

/// A line of light on the very edge of the screen, in the meter's colours, as long as the
/// level. It grows up the edge from the bottom, with only a faint halo, ends in a small
/// bright bead, and carries its symbol and number along beside that bead, where the eye is.
private struct EdgeLight: View {
    let model: SideHUDModel

    private static let length: CGFloat = 280
    private static let core: CGFloat = 3
    private static let bloom: CGFloat = 12
    private static let labelHeight: CGFloat = 22

    var body: some View {
        let state = model.state
        let trailing = model.edge == .trailing
        // Hidden means unlit, so appearing is the light running up the edge.
        let lit = Self.length * (model.isVisible ? state.shownLevel : 0)
        ZStack(alignment: trailing ? .bottomTrailing : .bottomLeading) {
            Rectangle()
                .fill(.white.opacity(0.14))
                .frame(width: 1.5, height: Self.length)
            state.scale
                .frame(width: Self.bloom, height: Self.length)
                .mask {
                    LinearGradient(
                        colors: [.white, .clear],
                        startPoint: trailing ? .trailing : .leading,
                        endPoint: trailing ? .leading : .trailing
                    )
                }
                .mask(alignment: .bottom) { Rectangle().frame(height: lit) }
                .opacity(0.28)
                .blur(radius: 2)
            state.scale
                .frame(width: Self.core, height: Self.length)
                .mask(alignment: .bottom) { Rectangle().frame(height: lit) }
            bead(state)
                .offset(x: trailing ? 1.5 : -1.5, y: 3.5 - lit)
                .opacity(lit > 0 ? 1 : 0)
            label(state)
                .offset(
                    x: trailing ? -14 : 14,
                    y: -min(max(lit - Self.labelHeight / 2, 0), Self.length - Self.labelHeight)
                )
        }
        .frame(height: Self.length)
        .environment(\.colorScheme, .dark)
        .opacity(model.isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: trailing ? .trailing : .leading)
    }

    /// The bright end of the light. It swells when a key is pressed with nowhere left to go.
    private func bead(_ state: SideHUDState) -> some View {
        let color = state.color(at: state.shownLevel)
        return Circle()
            .fill(.white)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.8), radius: 3)
            .keyframeAnimator(initialValue: 0.0, trigger: model.limitHits) { bead, swell in
                bead.scaleEffect(1 + swell * 0.9)
            } keyframes: { _ in
                CubicKeyframe(1, duration: 0.09)
                SpringKeyframe(0, duration: 0.3, spring: .bouncy)
            }
    }

    private func label(_ state: SideHUDState) -> some View {
        HStack(spacing: 4) {
            Image(systemName: state.symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            if !state.isMuted {
                Text("\(Int((state.level * 100).rounded()))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: state.level))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: Self.labelHeight)
        .background(Color(white: 0.11).opacity(0.9), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
    }
}
