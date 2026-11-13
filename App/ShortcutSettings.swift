import AppKit
import LiovaCore
import LiovaFeatures
import LiovaProviders
import SwiftUI

/// Settings → General: the global shortcuts, each one changeable.
struct ShortcutSection: View {
    @Bindable var settings: LiovaSettings
    let hotkeys: HotkeyFeature

    var body: some View {
        Section {
            Toggle("Keyboard shortcuts", isOn: $settings.hotkeysEnabled)
            ForEach(hotkeys.actionsInUse, id: \.self) { action in
                LabeledContent(action.title) {
                    HStack(spacing: 6) {
                        if hotkeys.taken.contains(action) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("Another app already uses this shortcut. Pick a different one.")
                        }
                        ShortcutRecorder(shortcut: settings.shortcut(for: action), hotkeys: hotkeys) {
                            settings.setShortcut($0, for: action)
                        }
                    }
                }
                .disabled(!settings.hotkeysEnabled)
            }
        } footer: {
            Text(
                "Work in every app. Click one to change it, then press the new keys (with ⌘, ⌃ or ⌥); "
                    + "Esc cancels, Delete puts the default back. Liova only hears its own shortcuts."
            )
        }
    }
}

/// A shortcut field: shows the keys, and records new ones when clicked.
private struct ShortcutRecorder: View {
    let shortcut: Shortcut
    let hotkeys: HotkeyFeature
    let onChange: (Shortcut?) -> Void
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? finish() : begin()
        } label: {
            Text(isRecording ? "Press keys…" : shortcut.displayName)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 84)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .onDisappear { finish() }
    }

    private func begin() {
        isRecording = true
        hotkeys.setSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: // Esc
                finish()
            case 51, 117: // Delete, Forward Delete
                onChange(nil)
                finish()
            default:
                let new = Self.shortcut(from: event)
                guard new.isUsable else { NSSound.beep(); return nil }
                onChange(new)
                finish()
            }
            return nil
        }
    }

    private func finish() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if isRecording {
            isRecording = false
            hotkeys.setSuspended(false)
        }
    }

    static func shortcut(from event: NSEvent) -> Shortcut {
        let flags = event.modifierFlags
        var modifiers: Shortcut.Modifiers = []
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        if flags.contains(.control) {
            modifiers.insert(.control)
        }
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: keyName(event))
    }

    /// The key as printed on the keyboard, whatever the layout.
    private static func keyName(_ event: NSEvent) -> String {
        let named: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        ]
        if let name = named[event.keyCode] {
            return name
        }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// Settings → Activities: recording controls and the OBS password.
struct RecordingSection: View {
    @Bindable var settings: LiovaSettings
    let recording: RecordingFeature
    @State private var password = OBSPassword.load() ?? ""

    var body: some View {
        Section {
            Toggle("Screen recording controls", isOn: $settings.recordingControlsEnabled)
            LabeledContent("OBS WebSocket password") {
                HStack {
                    SecureField("None", text: $password)
                        .frame(width: 140)
                    Button("Save") {
                        OBSPassword.save(password)
                        recording.reconnect()
                    }
                }
            }
            .disabled(!settings.recordingControlsEnabled)
        } footer: {
            Text(
                "While macOS (⌘⇧5) or OBS records, the notch shows how long, with Stop, and Pause in OBS. "
                    + "For OBS, turn on Tools → WebSocket Server Settings and copy its password here; "
                    + "it stays in your Keychain and Liova only talks to OBS on this Mac."
            )
        }
    }
}
