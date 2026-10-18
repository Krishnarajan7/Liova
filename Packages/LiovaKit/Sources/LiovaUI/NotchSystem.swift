import AppKit
import LiovaCore

/// Keeps one `NotchController` per selected display, reconciled by display UUID.
///
/// When displays change, existing controllers are updated in place, new displays
/// get a controller, and removed ones are torn down. Nothing is rebuilt needlessly.
@MainActor
public final class NotchSystem {
    private let engine: ActivityEngine
    private let settings: LiovaSettings
    private let displayManager: DisplayManager
    private let renderers: ActivityRendererRegistry
    private let chrome: NotchChrome
    private let pointer = PointerMonitor()
    private let fullScreen = FullScreenMonitor()
    private var fileDrag = FileDragDetector()
    private var dragTarget: String?
    private var controllers: [String: NotchController] = [:]

    public init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        displayManager: DisplayManager,
        renderers: ActivityRendererRegistry,
        chrome: NotchChrome
    ) {
        self.engine = engine
        self.renderers = renderers
        self.chrome = chrome
        self.settings = settings
        self.displayManager = displayManager
    }

    public func start() {
        displayManager.onChange = { [weak self] _ in self?.reconcile() }
        displayManager.start()
        pointer.handler = { [weak self] event in self?.route(event) }
        pointer.start()
        fullScreen.onChange = { [weak self] _ in self?.applyFullScreen() }
        fullScreen.start()
        reconcile()
    }

    public func stop() {
        pointer.stop()
        fullScreen.stop()
        displayManager.stop()
        controllers.values.forEach { $0.close() }
        controllers.removeAll()
    }

    /// Opens the notch on the display the user is looking at (the one with the pointer)
    /// for something that needs them, or closes it again with `false`.
    public func setAttention(_ needed: Bool) {
        guard needed else {
            controllers.values.forEach { $0.setAttention(false) }
            return
        }
        let pointer = NSEvent.mouseLocation
        let target = controllers.values.first { $0.containsPointer(pointer) }
            ?? controllers.values.first { $0.display.isMain }
            ?? controllers.values.first
        target?.setAttention(true)
    }

    private func draggedFile(at point: CGPoint) {
        let pasteboard = NSPasteboard(name: .drag)
        _ = fileDrag.dragged(dragPasteboardChangeCount: pasteboard.changeCount) {
            pasteboard.types?.contains(.fileURL) ?? false
        }
        guard fileDrag.isFileDragActive, chrome.dropPageID != nil else { return }
        // Open the notch the files are heading for; close any other.
        let target = controllers.first { $0.value.dragApproachZone().contains(point) }?.key
        guard target != dragTarget else { return }
        if let previous = dragTarget {
            controllers[previous]?.setFileDrag(false, dropPage: nil)
        }
        dragTarget = target
        if let target {
            controllers[target]?.setFileDrag(true, dropPage: chrome.dropPageID)
        }
    }

    /// The drop (if any) has been delivered by now; give it a beat, then let go.
    private func endFileDrag() {
        guard let target = dragTarget else { return }
        dragTarget = nil
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.controllers[target]?.setFileDrag(false, dropPage: nil)
        }
    }

    private func applyFullScreen() {
        let covered = settings.hideInFullScreen ? fullScreen.coveredDisplays : []
        Log.display.info("Full-screen displays: \(covered.count)")
        for controller in controllers.values {
            controller.setCoveredByFullScreen(covered.contains(controller.display.displayID))
        }
    }

    /// Call after settings change.
    public func settingsDidChange() {
        reconcile()
        controllers.values.forEach { $0.settingsDidChange() }
        applyFullScreen()
    }

    private func reconcile() {
        let wanted = settings.displayPlacement.select(from: displayManager.displays)
        let wantedIDs = Set(wanted.map(\.id))

        for (id, controller) in controllers where !wantedIDs.contains(id) {
            controller.close()
            controllers[id] = nil
        }
        for display in wanted {
            if let controller = controllers[display.id] {
                controller.update(display: display)
            } else {
                let controller = NotchController(
                    display: display,
                    engine: engine,
                    settings: settings,
                    renderers: renderers,
                    chrome: chrome
                )
                controllers[display.id] = controller
                controller.show()
            }
        }
        let count = controllers.count
        Log.display.info("Notch on \(count) display(s)")
    }

    private func route(_ event: PointerMonitor.Event) {
        switch event {
        case let .moved(point):
            if controllers.values.contains(where: { $0.isNearTop(point) }) {
                fullScreen.pointerNearTop()
            }
            controllers.values.forEach { $0.pointerMoved(to: point) }
        case let .mouseDown(point):
            fileDrag.mouseDown(dragPasteboardChangeCount: NSPasteboard(name: .drag).changeCount)
            controllers.values.forEach { $0.mouseDown(at: point) }
        case let .dragged(point):
            draggedFile(at: point)
            controllers.values.forEach { $0.pointerMoved(to: point) }
        case .leftMouseUp:
            if fileDrag.mouseUp() {
                endFileDrag()
            }
        }
    }
}
