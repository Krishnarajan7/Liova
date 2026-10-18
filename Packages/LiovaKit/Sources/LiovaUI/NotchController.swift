import AppKit
import LiovaCore
import SwiftUI

/// Owns the notch on one display: its panel, view state and pointer interaction.
@MainActor
public final class NotchController {
    public private(set) var display: Display

    private let model: NotchModel
    private let engine: ActivityEngine
    private let settings: LiovaSettings
    private let panel: NotchPanel
    private var interaction = NotchInteraction()
    private var enterTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var unmountTask: Task<Void, Never>?
    /// When the notch last closed, so a quick return reopens it without the hover delay.
    private var lastClosed: Date = .distantPast
    private var closeTask: Task<Void, Never>?
    private var lastPointer: CGPoint?

    /// How long the pointer must rest on the notch before it reacts. Filters out the
    /// pointer just passing by on its way to the menu bar or a tab bar.
    static let enterDelay: Duration = .milliseconds(70)

    /// A return within this window after closing reopens without the hover delay.
    static let quickReturnWindow: TimeInterval = 0.35
    /// How long the open content stays mounted after closing (the close animation's length),
    /// so a reversal mid-close continues smoothly.
    static let keepContentAfterClose: Duration = .milliseconds(550)

    private func scheduleUnmount() {
        unmountTask?.cancel()
        unmountTask = Task { [weak self] in
            try? await Task.sleep(for: Self.keepContentAfterClose)
            guard let self, !Task.isCancelled, model.presentation != .expanded else { return }
            model.keepsExpandedContent = false
        }
    }

    /// Grace period before an expanded notch closes after the pointer leaves.
    static let closeDelay: Duration = .milliseconds(180)

    public init(
        display: Display,
        engine: ActivityEngine,
        settings: LiovaSettings,
        renderers: ActivityRendererRegistry,
        chrome: NotchChrome
    ) {
        self.display = display
        self.engine = engine
        self.settings = settings
        model = NotchModel(geometry: display.geometry, showsIdleVirtualNotch: settings.showVirtualNotchWhenIdle)
        panel = NotchPanel(frame: Self.panelFrame(for: display.geometry))

        let root = NotchRootView(model: model, engine: engine, renderers: renderers, chrome: chrome) { [weak self] in
            self?.handle(.clicked)
        }
        panel.contentView = NotchHostingView(rootView: root)
    }

    public func show() {
        panel.orderFrontRegardless()
    }

    public func close() {
        enterTask?.cancel()
        openTask?.cancel()
        closeTask?.cancel()
        unmountTask?.cancel()
        panel.orderOut(nil)
        panel.close()
    }

    /// Applies new display metrics. Moves the panel only when its frame really changed.
    public func update(display: Display) {
        self.display = display
        guard model.geometry != display.geometry else { return }
        model.geometry = display.geometry
        panel.setFrame(Self.panelFrame(for: display.geometry), display: true)
    }

    public func settingsDidChange() {
        if model.showsIdleVirtualNotch != settings.showVirtualNotchWhenIdle {
            model.showsIdleVirtualNotch = settings.showVirtualNotchWhenIdle
        }
    }

    /// Files are being dragged and the pointer approached this notch (or the drag ended):
    /// open on the drop page, and close again afterwards unless the pointer stays.
    public func setFileDrag(_ active: Bool, dropPage: String?) {
        guard model.isFileDragActive != active else { return }
        model.isFileDragActive = active
        if active, let dropPage {
            model.selectedPage = dropPage
        }
        handle(active ? .attentionRequested : .attentionCleared)
        // The drop needs the panel to receive the drag even before the pointer is "inside".
        if active {
            panel.ignoresMouseEvents = false
        } else {
            updatePointerInside()
        }
    }

    /// The area a file drag must reach to open the notch: generously around it, so the
    /// notch opens as the files approach rather than only when they're on top of it.
    func dragApproachZone() -> CGRect {
        let notch = model.geometry.notchFrame
        return notch.insetBy(dx: -160, dy: -110)
    }

    /// Opens (or, with `false`, closes again) for something that needs the user.
    public func setAttention(_ needed: Bool) {
        if needed {
            model.selectedPage = NotchChrome.homePageID
        }
        handle(needed ? .attentionRequested : .attentionCleared)
    }

    public func setCoveredByFullScreen(_ covered: Bool) {
        guard model.isCoveredByFullScreen != covered else { return }
        model.isCoveredByFullScreen = covered
    }

    /// Whether the pointer is within the top strip of this display (where the notch lives).
    func isNearTop(_ point: CGPoint) -> Bool {
        let frame = display.metrics.frame
        return frame.contains(point) && point.y >= frame.maxY - 60
    }

    /// Whether the pointer is on this controller's display.
    func containsPointer(_ point: CGPoint) -> Bool {
        display.metrics.frame.contains(point)
    }

    // MARK: - Pointer

    public func pointerMoved(to point: CGPoint) {
        lastPointer = point
        // Fast path for the common case: the pointer is nowhere near this notch and
        // wasn't on it before, so nothing can change. Skips all layout math.
        if !interaction.isPointerInside, !panel.frame.insetBy(dx: -16, dy: -16).contains(point) {
            return
        }
        updatePointerInside()
    }

    public func mouseDown(at point: CGPoint) {
        lastPointer = point
        if !hotZone.contains(point) {
            handle(.clickedOutside)
        }
    }

    /// The area that counts as "on the notch" right now, in screen coordinates.
    var hotZone: CGRect {
        // Just after closing, the shape is still visibly shrinking; let the pointer catch it
        // anywhere it can see it, not only over the small closed notch.
        let closing = interaction.presentation != .expanded
            && Date().timeIntervalSince(lastClosed) < Self.quickReturnWindow
        let spec = NotchLayout.spec(
            for: closing ? .expanded : interaction.presentation,
            geometry: model.geometry,
            hasActivity: engine.current != nil
        )
        let slop: CGFloat = interaction.presentation == .expanded ? 10 : 4
        return NotchLayout.hotZone(spec, inPanel: panel.frame, slop: slop)
    }

    private func updatePointerInside() {
        guard let point = lastPointer else { return }
        let inside = hotZone.contains(point)
        // Clicks pass through the transparent parts of the panel.
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
        guard inside != interaction.isPointerInside else {
            if !inside {
                cancelEnter()
            }
            return
        }
        if inside {
            scheduleEnter()
        } else {
            cancelEnter()
            handle(.pointerExited)
        }
    }

    /// Reacts to the pointer only if it is still on the notch after `enterDelay`.
    /// An open notch reacts immediately, so moving back in never feels laggy.
    private func scheduleEnter() {
        // With open-on-hover, the open delay already filters out a passing pointer.
        if interaction.presentation == .expanded || settings.openOnHover {
            handle(.pointerEntered)
            return
        }
        guard enterTask == nil else { return }
        enterTask = Task { [weak self] in
            try? await Task.sleep(for: Self.enterDelay)
            guard let self, !Task.isCancelled else { return }
            enterTask = nil
            if let point = lastPointer, hotZone.contains(point), !interaction.isPointerInside {
                handle(.pointerEntered)
            }
        }
    }

    private func cancelEnter() {
        enterTask?.cancel()
        enterTask = nil
    }

    // MARK: - State machine

    private func handle(_ event: NotchInteraction.Event) {
        let before = interaction.presentation
        let effects = interaction.handle(event, openOnHover: settings.openOnHover)
        effects.forEach(run)
        let after = interaction.presentation
        guard after != before else { return }

        Log.interaction.debug("Notch \(String(describing: before)) → \(String(describing: after))")
        Log.signposter.emitEvent("notch.presentation", "\(String(describing: after))")
        if after == .expanded {
            unmountTask?.cancel()
            model.keepsExpandedContent = true
        } else if before == .expanded {
            lastClosed = Date()
            scheduleUnmount()
        }
        withAnimation(Self.animation(from: before, to: after)) {
            model.presentation = after
        }
        // The hot zone changed size; re-check where the pointer is.
        updatePointerInside()
    }

    private func run(_ effect: NotchInteraction.Effect) {
        switch effect {
        case .scheduleOpen:
            openTask?.cancel()
            // Coming straight back after leaving reads as "I didn't mean to close it": reopen
            // at once, continuing the same motion, instead of waiting out the hover delay.
            let returning = Date().timeIntervalSince(lastClosed) < Self.quickReturnWindow
            let delay = returning ? .zero : Duration.milliseconds(Int(settings.hoverDelay * 1000))
            openTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.handle(.openIntentElapsed)
            }
        case .cancelOpen:
            openTask?.cancel()
            openTask = nil
        case .scheduleClose:
            closeTask?.cancel()
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: Self.closeDelay)
                guard !Task.isCancelled else { return }
                self?.handle(.closeIntentElapsed)
            }
        case .cancelClose:
            closeTask?.cancel()
            closeTask = nil
        case .haptic:
            if settings.hapticsEnabled {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    private static func animation(from before: NotchPresentation, to after: NotchPresentation) -> Animation {
        switch (before, after) {
        case (_, .expanded): Motion.open
        case (.expanded, _): Motion.close
        default: Motion.hover
        }
    }

    private static func panelFrame(for geometry: NotchGeometry) -> CGRect {
        geometry.panelFrame(contentSize: NotchLayout.panelSize(for: geometry))
    }
}
