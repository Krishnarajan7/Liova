import Foundation

/// A key combination, like ⌃⌥V.
public struct Shortcut: Equatable, Hashable, Codable, Sendable {
    /// The key's virtual key code (kVK_ANSI_V is 9), the same on every keyboard layout.
    public var keyCode: UInt32
    public var modifiers: Modifiers
    /// What the key prints on the user's keyboard, for display: "V", "Space".
    public var key: String

    public init(keyCode: UInt32, modifiers: Modifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    public struct Modifiers: OptionSet, Hashable, Codable, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        // Carbon's values (cmdKey, shiftKey, optionKey, controlKey), which hotkeys use.
        public static let command = Modifiers(rawValue: 1 << 8)
        public static let shift = Modifiers(rawValue: 1 << 9)
        public static let option = Modifiers(rawValue: 1 << 11)
        public static let control = Modifiers(rawValue: 1 << 12)
    }

    /// "⌃⌥⇧⌘V", in the order macOS menus use.
    public var displayName: String {
        var text = ""
        if modifiers.contains(.control) {
            text += "⌃"
        }
        if modifiers.contains(.option) {
            text += "⌥"
        }
        if modifiers.contains(.shift) {
            text += "⇧"
        }
        if modifiers.contains(.command) {
            text += "⌘"
        }
        return text + key
    }

    /// A global shortcut needs ⌘, ⌃ or ⌥: a plain key, or ⇧ and a key, is typing.
    public var isUsable: Bool {
        !modifiers.isDisjoint(with: [.command, .control, .option])
    }
}

/// What a global shortcut can do.
public enum HotkeyAction: String, CaseIterable, Codable, Sendable {
    case toggleNotch
    case clipboard
    case toggleRecording
    case pauseRecording

    public var title: String {
        switch self {
        case .toggleNotch: "Open or close the notch"
        case .clipboard: "Clipboard history"
        case .toggleRecording: "Start or stop recording"
        case .pauseRecording: "Pause or resume recording"
        }
    }

    /// ⌃⌥ and a letter: free in macOS and almost every app.
    public var defaultShortcut: Shortcut {
        switch self {
        case .toggleNotch: Shortcut(keyCode: 45, modifiers: [.control, .option], key: "N")
        case .clipboard: Shortcut(keyCode: 9, modifiers: [.control, .option], key: "V")
        case .toggleRecording: Shortcut(keyCode: 15, modifiers: [.control, .option], key: "R")
        case .pauseRecording: Shortcut(keyCode: 35, modifiers: [.control, .option], key: "P")
        }
    }
}
