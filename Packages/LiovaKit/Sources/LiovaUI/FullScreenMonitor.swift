import AppKit
import CoreGraphics
import LiovaCore

/// Knows which displays are covered by a full-screen window (a movie, a game, a slideshow).
///
/// Event-driven: it re-checks when the Space or the active app changes, when screens change,
/// and when the pointer reaches the top of a screen (rate-limited), which covers apps that
/// go full screen without switching Spaces (e.g. VLC's non-native mode). Never polls.
@MainActor
public final class FullScreenMonitor {
    public private(set) var coveredDisplays: Set<CGDirectDisplayID> = []
    public var onChange: ((Set<CGDirectDisplayID>) -> Void)?

    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var settleTasks: [Task<Void, Never>] = []
    private var lastPointerCheck: Date = .distantPast

    static let pointerCheckInterval: TimeInterval = 1

    public init() {}

    public func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append((
                workspace,
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkSoon() }
                }
            ))
        }
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSoon() }
        }))
        check()
    }

    public func stop() {
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        settleTasks.forEach { $0.cancel() }
        settleTasks.removeAll()
    }

    /// The pointer moved near the top of a screen: re-check, at most once a second.
    public func pointerNearTop() {
        guard Date().timeIntervalSince(lastPointerCheck) >= Self.pointerCheckInterval else { return }
        lastPointerCheck = Date()
        check()
    }

    /// Checks now and again after the full-screen transition (about 0.7 s) settles.
    private func checkSoon() {
        settleTasks.forEach { $0.cancel() }
        settleTasks = [0.1, 0.9].map { delay in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.check()
            }
        }
    }

    public func check() {
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        let displays = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect)? in
            guard let id = DisplayManager.displayID(of: screen) else { return nil }
            return (id, CGDisplayBounds(id))
        }
        let covered = Self.coveredDisplays(
            windows: windows,
            displays: displays,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        guard covered != coveredDisplays else { return }
        coveredDisplays = covered
        onChange?(covered)
    }

    /// Displays where another app's ordinary window exactly covers the whole screen, menu bar
    /// area included. Pure, so it's unit-tested.
    nonisolated static func coveredDisplays(
        windows: [[String: Any]],
        displays: [(id: CGDirectDisplayID, bounds: CGRect)],
        ownPID: pid_t
    ) -> Set<CGDirectDisplayID> {
        var covered: Set<CGDirectDisplayID> = []
        for window in windows {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  (0 ..< Int(CGWindowLevelForKey(.statusWindow))).contains(layer),
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else { continue }
            for display in displays where Self.matches(bounds, display.bounds) {
                covered.insert(display.id)
            }
        }
        return covered
    }

    nonisolated static func matches(_ window: CGRect, _ display: CGRect) -> Bool {
        abs(window.minX - display.minX) <= 1 && abs(window.minY - display.minY) <= 1
            && abs(window.width - display.width) <= 1 && abs(window.height - display.height) <= 1
    }
}
