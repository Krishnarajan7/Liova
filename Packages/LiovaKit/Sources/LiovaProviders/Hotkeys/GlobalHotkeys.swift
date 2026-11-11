import Carbon.HIToolbox
import Foundation

/// A key combination for `GlobalHotkeys`, in Carbon's terms.
public struct HotkeyCombo: Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

@MainActor
public protocol HotkeyRegistering: AnyObject {
    /// Replaces every registered shortcut. Returns the IDs macOS refused (taken by another app).
    @discardableResult
    func register(_ combos: [String: HotkeyCombo], onPress: @escaping @MainActor (String) -> Void) -> Set<String>
    func unregisterAll()
}

/// System-wide shortcuts through Carbon's hotkeys: macOS tells Liova only when one of its
/// own combinations is pressed. Nothing else typed is seen, so no permission is needed,
/// and nothing runs between presses.
@MainActor
public final class GlobalHotkeys: HotkeyRegistering {
    private var refs: [EventHotKeyRef] = []
    private var ids: [UInt32: String] = [:]
    private var onPress: (@MainActor (String) -> Void)?
    private var handler: EventHandlerRef?

    /// "LIOV": tells Liova's hotkeys apart from any other code's in the process.
    private static let signature: OSType = 0x4C49_4F56

    public init() {}

    @discardableResult
    public func register(
        _ combos: [String: HotkeyCombo],
        onPress: @escaping @MainActor (String) -> Void
    ) -> Set<String> {
        unregisterAll()
        self.onPress = onPress
        installHandler()
        var refused = Set<String>()
        for (index, (id, combo)) in combos.sorted(by: { $0.key < $1.key }).enumerated() {
            let number = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: number),
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
                ids[number] = id
            } else {
                refused.insert(id)
            }
        }
        return refused
    }

    public func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        ids = [:]
        if let handler {
            RemoveEventHandler(handler)
        }
        handler = nil
        onPress = nil
    }

    fileprivate func pressed(_ number: UInt32) {
        guard let id = ids[number] else { return }
        onPress?(id)
    }

    private func installHandler() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var hotkey = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkey
                )
                guard status == noErr, hotkey.signature == GlobalHotkeys.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let hotkeys = Unmanaged<GlobalHotkeys>.fromOpaque(context).takeUnretainedValue()
                // Carbon calls on the main thread.
                MainActor.assumeIsolated { hotkeys.pressed(hotkey.id) }
                return noErr
            },
            1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
    }
}
