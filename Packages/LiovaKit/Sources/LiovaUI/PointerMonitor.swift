import AppKit

/// Reports pointer movement and clicks anywhere on screen.
///
/// Event-driven: when the mouse is still, nothing runs. Uses a global monitor for
/// events going to other apps and a local one for events going to Liova's own
/// panels. Neither needs the Accessibility permission (only key events would).
@MainActor
public final class PointerMonitor {
    public enum Event: Sendable {
        case moved(CGPoint)
        case mouseDown(CGPoint)
    }

    public var handler: ((Event) -> Void)?

    private var monitors: [Any] = []

    private static let moveMask: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]
    private static let downMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    public init() {}

    public func start() {
        guard monitors.isEmpty else { return }
        let mask = Self.moveMask.union(Self.downMask)
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let isDown = Self.downMask.contains(NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue))
            MainActor.assumeIsolated { self?.dispatch(isDown: isDown) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let isDown = Self.downMask.contains(NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue))
            MainActor.assumeIsolated { self?.dispatch(isDown: isDown) }
            return event
        }) {
            monitors.append(local)
        }
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func dispatch(isDown: Bool) {
        let location = NSEvent.mouseLocation
        handler?(isDown ? .mouseDown(location) : .moved(location))
    }
}
