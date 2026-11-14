import AppKit
import ApplicationServices
import Foundation

public enum HangUpResult: Equatable, Sendable {
    case done
    /// Liova needs Accessibility access to press the app's button.
    case needsPermission
    /// No leave or end button was found.
    case notFound
    /// A browser has the microphone but shows no Leave button: a call's page before joining
    /// ("Ready to join?") or after leaving keeps the mic on. The browser is brought forward
    /// so its tab can be closed.
    case tabStillOpen
}

@MainActor
public protocol CallHangingUp: AnyObject {
    func hangUp(_ user: MicrophoneUser) async -> HangUpResult
}

/// Hangs up by pressing the app's own Leave or End button, found through Accessibility, as
/// the user would: the app says goodbye properly, and nothing private is touched. Apps
/// that ask "Leave meeting?" get the confirmation pressed too; "End meeting for all" never
/// is. A few apps without a findable button get their hang-up shortcut instead.
@MainActor
public final class AccessibilityHangUp: CallHangingUp {
    private let isTrusted: () -> Bool

    public init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.isTrusted = isTrusted
    }

    public func hangUp(_ user: MicrophoneUser) async -> HangUpResult {
        guard isTrusted() else {
            Self.askForPermission()
            return .needsPermission
        }
        let app = AXUIElementCreateApplication(user.pid)
        // Chromium browsers and Electron apps only build their web content's tree on request.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        if let button = await Self.findHangUp(in: app) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            // "Leave meeting?" comes up a moment later in some apps.
            try? await Task.sleep(for: .milliseconds(450))
            if let confirm = Self.findButton(in: app, matching: CallButtonLabels.isConfirmation) {
                AXUIElementPerformAction(confirm, kAXPressAction as CFString)
            }
            return .done
        }
        if let shortcut = CallButtonLabels.shortcut(for: user.bundleID) {
            Self.send(shortcut, to: user.pid)
            return .done
        }
        if CallButtonLabels.browsers.contains(user.bundleID) {
            NSRunningApplication(processIdentifier: user.pid)?.activate()
            return .tabStillOpen
        }
        return .notFound
    }

    /// The tree a browser builds on request isn't there at once (Meet's Leave call button
    /// shows up a moment later), so it's looked for a few times. Then the menu bar: WhatsApp's
    /// Call menu has End Call.
    private static func findHangUp(in app: AXUIElement) async -> AXUIElement? {
        for attempt in 0 ..< 4 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(400))
            }
            if let button = findButton(in: app, matching: CallButtonLabels.isHangUp) {
                return button
            }
        }
        return findButton(in: app, from: kAXMenuBarAttribute, matching: CallButtonLabels.isHangUp)
    }

    public static func askForPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Finding the button

    /// Breadth-first through the app's windows, so the toolbar's button is found before
    /// anything buried in a chat. Bounded, so a huge web page can't stall the main thread.
    private static func findButton(
        in app: AXUIElement,
        from root: String = kAXWindowsAttribute,
        matching matches: (String) -> Bool
    ) -> AXUIElement? {
        var value: CFTypeRef?
        var queue = children(of: app, attribute: root)
        if queue.isEmpty, AXUIElementCopyAttributeValue(app, root as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        {
            // The menu bar is one element, not a list.
            queue = [unsafeDowncast(value, to: AXUIElement.self)]
        }
        // The front window first: a browser's other windows can hold thousands of elements.
        var front: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &front) == .success,
           let front, let index = queue.firstIndex(where: { CFEqual($0, front) })
        {
            queue.insert(queue.remove(at: index), at: 0)
        }
        var index = 0
        let limit = 15000
        while index < queue.count, index < limit {
            let element = queue[index]
            index += 1
            if isPressable(element), labels(of: element).contains(where: matches) {
                return element
            }
            queue += children(of: element, attribute: kAXChildrenAttribute)
        }
        return nil
    }

    private static func isPressable(_ element: AXUIElement) -> Bool {
        guard let role = string(element, kAXRoleAttribute) else { return false }
        if role == kAXMenuItemRole {
            var enabled: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
            return (enabled as? Bool) ?? false
        }
        return role == kAXButtonRole || role == "AXLink" || role == kAXMenuButtonRole
    }

    private static func labels(of element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap { string(element, $0) }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement]
        else { return [] }
        return elements
    }

    // MARK: - Shortcut fallback

    private static func send(_ shortcut: CallButtonLabels.Shortcut, to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.key, keyDown: isDown)
            event?.flags = shortcut.flags
            event?.postToPid(pid)
        }
    }
}

/// Which buttons hang up. Pure, so it's unit-tested.
public enum CallButtonLabels {
    /// The words call apps put on their hang-up button (English).
    static let hangUp: Set = [
        "leave", "leave call", "leave meeting", "leave huddle", "leave room", "leave channel",
        "end", "end call", "hang up", "disconnect", "end video call", "end audio call",
    ]

    /// WhatsApp starts every label with an invisible left-to-right mark ("\u{200E}End call"),
    /// so text-direction marks are dropped before comparing.
    static func normalized(_ label: String) -> String {
        String(label.unicodeScalars.filter { $0.properties.generalCategory != .format })
            .lowercased()
            .replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// Never ends the meeting for everyone, even when the user hosts it.
    static func isHangUp(_ label: String) -> Bool {
        let text = normalized(label)
        guard !text.contains("for all"), !text.contains("for everyone") else { return false }
        return hangUp.contains(text) || text.hasPrefix("leave call") || text.hasPrefix("hang up")
    }

    /// The second button some apps ask for ("Leave Meeting" in Zoom's confirmation).
    static func isConfirmation(_ label: String) -> Bool {
        let text = normalized(label)
        guard !text.contains("for all"), !text.contains("for everyone") else { return false }
        return ["leave meeting", "leave", "end call", "leave call"].contains(text)
    }

    /// Browsers, where a "call" is a web page that may keep the mic without being in one.
    public static let browsers: Set = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser",
    ]

    struct Shortcut {
        var key: CGKeyCode
        var flags: CGEventFlags
    }

    /// Apps whose hang-up button isn't exposed but has a shortcut: ⌘⇧H in Teams and Slack.
    static func shortcut(for bundleID: String) -> Shortcut? {
        switch bundleID {
        case "com.microsoft.teams2", "com.microsoft.teams", "com.tinyspeck.slackmacgap":
            Shortcut(key: 4, flags: [.maskCommand, .maskShift]) // H
        default:
            nil
        }
    }
}
