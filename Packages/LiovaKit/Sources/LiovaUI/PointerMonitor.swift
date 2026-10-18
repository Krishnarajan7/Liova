import AppKit

/// Reports pointer movement, drags and clicks anywhere on screen.
///
/// Event-driven: when the mouse is still, nothing runs. Uses a global monitor for
/// events going to other apps and a local one for events going to Liova's own
/// panels. Neither needs the Accessibility permission (only key events would).
@MainActor
public final class PointerMonitor {
    public enum Event: Sendable, Equatable {
        case moved(CGPoint)
        /// The left button is held while moving: a drag, possibly of files.
        case dragged(CGPoint)
        case mouseDown(CGPoint)
        case leftMouseUp(CGPoint)
    }

    public var handler: ((Event) -> Void)?

    private var monitors: [Any] = []

    private static let mask: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp,
    ]

    public init() {}

    public func start() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: Self.mask, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.dispatch(type) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: Self.mask, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.dispatch(type) }
            return event
        }) {
            monitors.append(local)
        }
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func dispatch(_ type: NSEvent.EventType) {
        let location = NSEvent.mouseLocation
        let event: Event = switch type {
        case .leftMouseDragged: .dragged(location)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: .mouseDown(location)
        case .leftMouseUp: .leftMouseUp(location)
        default: .moved(location)
        }
        handler?(event)
    }
}

/// Recognizes when the user is dragging files (from Finder, a browser, anywhere), without
/// reading what's being dragged: it compares the drag pasteboard's change count at mouse-down
/// with the one during the drag, and checks only the advertised types. Pure, so it's tested.
public struct FileDragDetector: Sendable {
    public private(set) var isFileDragActive = false
    private var changeCountAtMouseDown: Int?
    private var decided = false

    public init() {}

    public mutating func mouseDown(dragPasteboardChangeCount: Int) {
        changeCountAtMouseDown = dragPasteboardChangeCount
        decided = false
        isFileDragActive = false
    }

    /// Returns true when this drag event started a file drag.
    public mutating func dragged(dragPasteboardChangeCount: Int, hasFileURLs: () -> Bool) -> Bool {
        guard !decided, let start = changeCountAtMouseDown else { return false }
        // A drag session writes the drag pasteboard when it begins; until then, keep waiting.
        guard dragPasteboardChangeCount != start else { return false }
        decided = true
        isFileDragActive = hasFileURLs()
        return isFileDragActive
    }

    /// Returns true when a file drag just ended.
    public mutating func mouseUp() -> Bool {
        let wasActive = isFileDragActive
        isFileDragActive = false
        changeCountAtMouseDown = nil
        decided = false
        return wasActive
    }
}
