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

    public var kind: Kind
    /// 0…1.
    public var level: Double
    public var isMuted: Bool
    public var symbol: String

    public init(kind: Kind, level: Double, isMuted: Bool = false, symbol: String) {
        self.kind = kind
        self.level = min(max(level, 0), 1)
        self.isMuted = isMuted
        self.symbol = symbol
    }
}

/// A vertical level bar at the right edge of the screen, for volume and brightness.
///
/// One borderless, click-through panel, created on first use and reused. It's on screen
/// only while visible: after the hide animation it's ordered out, so it costs nothing
/// between key presses.
@MainActor
public final class SideHUDController {
    /// How long the bar stays after the last change.
    static let displayDuration: Duration = .milliseconds(1500)
    static let panelSize = CGSize(width: 96, height: 300)

    private let model = SideHUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    public init() {}

    public func show(_ state: SideHUDState) {
        let panel = panel ?? makePanel()
        self.panel = panel
        if !model.isVisible {
            position(panel)
            panel.orderFrontRegardless()
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            model.state = state
            model.isVisible = true
        }
        scheduleHide()
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

    /// Right edge, vertically centered, on the display with the pointer.
    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = Self.panelSize
        panel.setFrame(
            CGRect(
                x: visible.maxX - size.width - 4,
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
    var state = SideHUDState(kind: .volume, level: 0, symbol: "speaker.wave.2.fill")
    var isVisible = false
}

/// The bar: a glass capsule with a filled level, the value on top and the symbol below.
struct SideHUDView: View {
    let model: SideHUDModel

    private static let barWidth: CGFloat = 46
    private static let barHeight: CGFloat = 220

    var body: some View {
        let state = model.state
        VStack(spacing: 10) {
            Text(state.isMuted ? "–" : "\(Int((state.level * 100).rounded()))")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(value: state.level))
            LevelTrack(state: state)
                .frame(width: 10)
                .frame(maxHeight: .infinity)
            Image(systemName: state.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 18)
        }
        .padding(.vertical, 14)
        .frame(width: Self.barWidth, height: Self.barHeight)
        .background {
            Capsule(style: .continuous)
                .fill(.black.opacity(0.55))
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
        .environment(\.colorScheme, .dark)
        .offset(x: model.isVisible ? 0 : 70)
        .opacity(model.isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 14)
    }
}

/// The vertical level. The fill reveals a fixed gradient, like a level meter: volume runs
/// green (quiet) through yellow to red (loud); brightness runs from dim amber to white.
private struct LevelTrack: View {
    let state: SideHUDState

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let level = state.isMuted ? 0 : state.level
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.14))
                gradient
                    .frame(height: height)
                    .mask(alignment: .bottom) {
                        Capsule().frame(height: max(level > 0 ? 10 : 0, height * level))
                    }
            }
        }
    }

    private var gradient: LinearGradient {
        switch state.kind {
        case .volume:
            LinearGradient(colors: [.green, .yellow, .orange, .red], startPoint: .bottom, endPoint: .top)
        case .brightness:
            LinearGradient(
                colors: [Color(red: 1, green: 0.62, blue: 0.1), .yellow, .white],
                startPoint: .bottom, endPoint: .top
            )
        }
    }
}
