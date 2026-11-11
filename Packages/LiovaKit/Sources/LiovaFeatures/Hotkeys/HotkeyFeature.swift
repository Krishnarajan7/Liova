import Foundation
import LiovaCore
import LiovaProviders
import Observation

/// Global keyboard shortcuts: open the notch, the clipboard, control a recording, from any app.
@MainActor
@Observable
public final class HotkeyFeature {
    /// Shortcuts macOS refused because another app already uses them.
    public private(set) var taken: Set<HotkeyAction> = []

    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let hotkeys: any HotkeyRegistering
    @ObservationIgnored private let isAvailable: @MainActor () -> Bool
    @ObservationIgnored private var actions: [HotkeyAction: @MainActor () -> Void] = [:]
    @ObservationIgnored private var registered: [HotkeyAction: Shortcut] = [:]
    /// While Settings records a new shortcut, the current ones stay quiet.
    @ObservationIgnored private var isSuspended = false

    public init(
        settings: LiovaSettings,
        hotkeys: any HotkeyRegistering = GlobalHotkeys(),
        isAvailable: @escaping @MainActor () -> Bool = { PreviewFeature.hotkeys.isEnabled() }
    ) {
        self.settings = settings
        self.hotkeys = hotkeys
        self.isAvailable = isAvailable
    }

    public var isEnabled: Bool {
        settings.hotkeysEnabled && isAvailable()
    }

    /// What each shortcut does. Actions without a handler aren't registered.
    public func setAction(_ action: HotkeyAction, _ handler: @escaping @MainActor () -> Void) {
        actions[action] = handler
    }

    public func syncWithSettings() {
        let wanted = isEnabled && !isSuspended ? Self.shortcuts(settings: settings, actions: Array(actions.keys)) : [:]
        guard wanted != registered else { return }
        registered = wanted
        guard !wanted.isEmpty else {
            hotkeys.unregisterAll()
            taken = []
            return
        }
        let combos = wanted.reduce(into: [String: HotkeyCombo]()) { combos, entry in
            combos[entry.key.rawValue] = HotkeyCombo(
                keyCode: entry.value.keyCode,
                modifiers: entry.value.modifiers.rawValue
            )
        }
        let refused = hotkeys.register(combos) { [weak self] id in
            guard let action = HotkeyAction(rawValue: id) else { return }
            self?.actions[action]?()
        }
        taken = Set(refused.compactMap(HotkeyAction.init(rawValue:)))
    }

    public func stop() {
        registered = [:]
        hotkeys.unregisterAll()
        taken = []
    }

    /// Settings is recording a shortcut: pressing a current one shouldn't run it.
    public func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        syncWithSettings()
    }

    /// One shortcut per combination: if two actions share one, the first keeps it.
    static func shortcuts(settings: LiovaSettings, actions: [HotkeyAction]) -> [HotkeyAction: Shortcut] {
        var result: [HotkeyAction: Shortcut] = [:]
        var used = Set<Shortcut>()
        for action in HotkeyAction.allCases where actions.contains(action) {
            let shortcut = settings.shortcut(for: action)
            guard shortcut.isUsable, used.insert(shortcut).inserted else { continue }
            result[action] = shortcut
        }
        return result
    }
}
