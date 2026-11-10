import AppKit
import CoreGraphics
import Foundation

@MainActor
public protocol ClipboardWatching: AnyObject {
    /// `onCopy` runs for each new copy, private ones (passwords) already left out.
    func start(onCopy: @escaping @MainActor (ClipboardCapture) -> Void)
    func stop()
    /// Puts `content` back on the clipboard without it counting as a new copy.
    func write(_ content: ClipboardContent)
}

/// Notices copies. macOS says nothing when the clipboard changes, so this compares its
/// change count, which costs next to nothing, and only as often as it's worth it:
/// often while you're using the Mac, rarely once you're away, never while the screen is
/// off or locked, and right away when you switch apps (copy, then switch to paste).
@MainActor
public final class SystemClipboardWatcher: ClipboardWatching {
    private let pasteboard: any PasteboardAccess
    private let secondsSinceInput: () -> TimeInterval
    private var onCopy: (@MainActor (ClipboardCapture) -> Void)?
    private var timer: Timer?
    private var lastChangeCount = 0
    private var isAsleep = false
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    static let activeInterval: TimeInterval = 0.75
    static let idleInterval: TimeInterval = 5
    /// No keyboard, mouse or trackpad for this long counts as away.
    static let idleAfter: TimeInterval = 30

    public init(
        pasteboard: any PasteboardAccess = SystemPasteboard(),
        secondsSinceInput: @escaping () -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        }
    ) {
        self.pasteboard = pasteboard
        self.secondsSinceInput = secondsSinceInput
    }

    public func start(onCopy: @escaping @MainActor (ClipboardCapture) -> Void) {
        stop()
        self.onCopy = onCopy
        // What's already on the clipboard was copied before; only new copies count.
        lastChangeCount = pasteboard.changeCount
        observe()
        schedule(Self.activeInterval)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for (center, observer) in observers {
            center.removeObserver(observer)
        }
        observers = []
        onCopy = nil
        isAsleep = false
    }

    public func write(_ content: ClipboardContent) {
        pasteboard.write(content)
        lastChangeCount = pasteboard.changeCount
    }

    /// How often it looks now; nil while paused.
    var interval: TimeInterval? {
        timer?.timeInterval
    }

    /// Reads the clipboard if it changed, then picks how soon to look again.
    func check() {
        guard onCopy != nil, !isAsleep else { return }
        let count = pasteboard.changeCount
        if count != lastChangeCount {
            lastChangeCount = count
            capture()
        }
        let interval = secondsSinceInput() > Self.idleAfter ? Self.idleInterval : Self.activeInterval
        if timer?.timeInterval != interval {
            schedule(interval)
        }
    }

    private func capture() {
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard !ClipboardRules.isPrivate(types: pasteboard.types, sourceBundleID: source),
              let content = pasteboard.read()
        else { return }
        onCopy?(ClipboardCapture(content: content, sourceBundleID: source))
    }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // Lets macOS line the check up with other work instead of waking just for it.
        timer.tolerance = interval * 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        let sleep: [Notification.Name] = [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        let wake: [Notification.Name] = [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in sleep {
            add(workspace, name) { $0.pause() }
        }
        for name in wake {
            add(workspace, name) { $0.resume() }
        }
        add(workspace, NSWorkspace.didActivateApplicationNotification) { $0.check() }
    }

    private func add(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ action: @escaping @MainActor (SystemClipboardWatcher) -> Void
    ) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, observer))
    }

    private func pause() {
        isAsleep = true
        timer?.invalidate()
        timer = nil
    }

    private func resume() {
        guard isAsleep, onCopy != nil else { return }
        isAsleep = false
        check()
        schedule(Self.activeInterval)
    }
}
