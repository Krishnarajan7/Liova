import AppKit

/// One connected screen, identified by a UUID that survives reconnects and reboots.
public struct Display: Identifiable, Equatable, Sendable {
    /// Stable display UUID (`CGDisplayCreateUUIDFromDisplayID`).
    public let id: String
    public let displayID: CGDirectDisplayID
    public let name: String
    public let isBuiltIn: Bool
    public let isMain: Bool
    public let metrics: ScreenMetrics
    public let geometry: NotchGeometry

    public init(
        id: String,
        displayID: CGDirectDisplayID,
        name: String,
        isBuiltIn: Bool,
        isMain: Bool,
        metrics: ScreenMetrics
    ) {
        self.id = id
        self.displayID = displayID
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
        self.metrics = metrics
        geometry = NotchGeometry(metrics: metrics)
    }
}

/// Which displays get a notch.
public enum DisplayPlacement: String, CaseIterable, Codable, Sendable {
    case allDisplays
    case builtInOnly
    case mainOnly

    /// Picks displays for this placement. Falls back to the main display, so a
    /// lid-closed laptop on `builtInOnly` still has a notch somewhere.
    public func select(from displays: [Display]) -> [Display] {
        let chosen: [Display] = switch self {
        case .allDisplays: displays
        case .builtInOnly: displays.filter(\.isBuiltIn)
        case .mainOnly: displays.filter(\.isMain)
        }
        if chosen.isEmpty, let fallback = displays.first(where: \.isMain) ?? displays.first {
            return [fallback]
        }
        return chosen
    }
}

/// Tracks connected displays and reports changes, coalescing bursts.
///
/// macOS posts several screen-parameter notifications per change (resolution,
/// arrangement, sleep/wake). We wait for them to settle, then publish one snapshot,
/// and only when something actually changed.
@MainActor
public final class DisplayManager {
    public private(set) var displays: [Display] = []

    /// Called on the main actor with the new snapshot whenever displays change.
    public var onChange: (([Display]) -> Void)?

    private let settleDelay: Duration
    private var observer: (any NSObjectProtocol)?
    private var pending: Task<Void, Never>?

    public init(settleDelay: Duration = .milliseconds(120)) {
        self.settleDelay = settleDelay
        displays = Self.snapshot()
    }

    public func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    public func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        pending?.cancel()
    }

    /// Re-reads displays now. Publishes only if something changed.
    public func refresh() {
        let latest = Self.snapshot()
        guard latest != displays else { return }
        displays = latest
        Log.display.info("Displays changed: \(latest.map(\.name), privacy: .public)")
        onChange?(latest)
    }

    private func scheduleRefresh() {
        pending?.cancel()
        let delay = settleDelay
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Reads every connected screen.
    public static func snapshot() -> [Display] {
        let mainID = NSScreen.main.flatMap(displayID(of:))
        return NSScreen.screens.compactMap { screen in
            guard let displayID = displayID(of: screen) else { return nil }
            let metrics = ScreenMetrics(
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                safeAreaTop: screen.safeAreaInsets.top,
                auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
                auxiliaryTopRight: screen.auxiliaryTopRightArea,
                backingScale: screen.backingScaleFactor
            )
            return Display(
                id: uuid(of: displayID),
                displayID: displayID,
                name: screen.localizedName,
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                isMain: displayID == mainID,
                metrics: metrics
            )
        }
    }

    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Finds the `NSScreen` for a display, if it is still connected.
    public static func screen(for display: Display) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == display.displayID }
    }

    private static func uuid(of displayID: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String?
        else { return "display-\(displayID)" }
        return string
    }
}
