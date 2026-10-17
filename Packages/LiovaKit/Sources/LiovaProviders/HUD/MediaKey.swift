import CoreGraphics
import Foundation
import os

/// The media keys the HUD handles. Raw values are the `NX_KEYTYPE_*` codes from `<IOKit/hidsystem/ev_keymap.h>`.
public enum MediaKey: Int, Sendable, CaseIterable {
    case soundUp = 0 // NX_KEYTYPE_SOUND_UP
    case soundDown = 1 // NX_KEYTYPE_SOUND_DOWN
    case brightnessUp = 2 // NX_KEYTYPE_BRIGHTNESS_UP
    case brightnessDown = 3 // NX_KEYTYPE_BRIGHTNESS_DOWN
    case mute = 7 // NX_KEYTYPE_MUTE

    public var isVolumeKey: Bool {
        switch self {
        case .soundUp, .soundDown, .mute: true
        case .brightnessUp, .brightnessDown: false
        }
    }
}

/// One decoded media-key event.
public struct MediaKeyEvent: Equatable, Sendable {
    public var key: MediaKey
    /// True for key-down (including auto-repeat), false for key-up.
    public var isDown: Bool
    /// True when the key is held and macOS is auto-repeating it.
    public var isRepeat: Bool
    /// Shift+Option held: change by a quarter step, like macOS.
    public var isFineStep: Bool

    public init(key: MediaKey, isDown: Bool, isRepeat: Bool = false, isFineStep: Bool = false) {
        self.key = key
        self.isDown = isDown
        self.isRepeat = isRepeat
        self.isFineStep = isFineStep
    }
}

/// Decodes `NSEvent.EventType.systemDefined` events. Pure, so every bit is unit-tested.
public enum MediaKeyDecoder {
    /// `NX_SYSDEFINED`, the raw value of `NSEvent.EventType.systemDefined` and of the matching `CGEventType`.
    public static let systemDefinedEventType: UInt32 = 14
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`: media and special function keys.
    public static let auxControlButtonsSubtype: Int = 8

    private static let keyDownState = 0x0A
    private static let keyUpState = 0x0B

    /// Decodes a media-key event, or returns `nil` when the event must pass through untouched:
    /// another subtype, a key the HUD doesn't handle, an unknown key state, or a key-down with
    /// modifiers that macOS gives a different meaning (Option alone opens Sound or Displays
    /// settings; Command and Control combinations are left to the system and other apps).
    ///
    /// Key-ups are decoded whatever the modifiers, so a swallowed key-down is always paired
    /// with its swallowed key-up even if a modifier changed in between.
    public static func decode(subtype: Int, data1: Int, flags: CGEventFlags) -> MediaKeyEvent? {
        guard subtype == auxControlButtonsSubtype else { return nil }
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyState = (data1 & 0x0000_FF00) >> 8
        let isRepeat = data1 & 0x1 == 0x1
        guard let key = MediaKey(rawValue: keyCode) else { return nil }

        switch keyState {
        case keyUpState:
            return MediaKeyEvent(key: key, isDown: false, isRepeat: false, isFineStep: false)
        case keyDownState:
            let shift = flags.contains(.maskShift)
            let option = flags.contains(.maskAlternate)
            if flags.contains(.maskCommand) || flags.contains(.maskControl) || (option && !shift) {
                return nil
            }
            return MediaKeyEvent(key: key, isDown: true, isRepeat: isRepeat, isFineStep: shift && option)
        default:
            return nil
        }
    }
}

/// Decides which decoded events to swallow. A key-down is swallowed only when the handler
/// reports success; its key-up is swallowed only if that key-down was. Everything else passes.
public struct MediaKeyFilter: Sendable {
    private var swallowedDowns: Set<MediaKey> = []

    public init() {}

    public mutating func shouldSwallow(_ event: MediaKeyEvent, handle: (MediaKeyEvent) -> Bool) -> Bool {
        guard event.isDown else {
            return swallowedDowns.remove(event.key) != nil
        }
        if handle(event) {
            swallowedDowns.insert(event.key)
            return true
        }
        swallowedDowns.remove(event.key)
        return false
    }

    public mutating func reset() {
        swallowedDowns.removeAll()
    }
}

/// Watches how often macOS disables the event tap. A few disables are normal (the main thread
/// was busy once); a burst means something is wrong, and the safest response is to remove the tap
/// so the system handles the keys and shows its own HUD again.
public struct TapWatchdog: Sendable {
    public enum Decision: Equatable, Sendable {
        case reenable
        case giveUp
    }

    public let maxDisables: Int
    public let window: TimeInterval
    private var recent: [Date] = []

    public init(maxDisables: Int = 3, window: TimeInterval = 60) {
        self.maxDisables = max(maxDisables, 1)
        self.window = window
    }

    public mutating func recordDisable(at date: Date) -> Decision {
        recent = recent.filter { date.timeIntervalSince($0) < window }
        recent.append(date)
        return recent.count > maxDisables ? .giveUp : .reenable
    }

    public mutating func reset() {
        recent.removeAll()
    }
}

enum HUDLog {
    static let logger = Logger(subsystem: "app.liova.Liova", category: "hud")
}
