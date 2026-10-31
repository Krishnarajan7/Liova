import AppKit
import SwiftUI

/// The Settings window, built in AppKit so any part of Liova can open it: the notch's gear,
/// an update card, the menu.
///
/// SwiftUI's `Settings` scene can't be opened from outside a SwiftUI view on macOS 14 and
/// later: `showSettingsWindow:` is ignored there, and `openSettings` needs a view to call it
/// from. A toolbar-style tab view controller gives the same window, opened from anywhere.
@MainActor
final class SettingsWindow {
    private unowned let coordinator: AppCoordinator
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    private var keyMonitor: Any?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    /// Liova lives in the menu bar, so ⌘Q in Settings means "done with Settings", not "quit
    /// the notch". ⌘Q and ⌘W close the window; Quit stays in the menu bar menu.
    private func watchCloseKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let window = self?.window, window.isKeyWindow,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  ["q", "w"].contains(event.charactersIgnoringModifiers?.lowercased())
            else { return event }
            window.performClose(nil)
            return nil
        }
    }

    /// Brings Settings to the front, on `tab` when given (otherwise where it was left).
    func show(tab: SettingsTab?) {
        let window = window ?? makeWindow()
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) {
            tabs?.selectedTabViewItemIndex = index
        }
        if !window.isVisible {
            window.center()
        }
        // An agent app has to step forward itself, or the window opens behind the frontmost app.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: SettingsPane(tab: tab, coordinator: coordinator))
            // The window takes each tab's own height, as the Settings scene did.
            host.sizingOptions = .preferredContentSize
            // The tab view controller titles the window after the selected tab's controller;
            // without one the window reads "Untitled".
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("LiovaSettings")
        self.tabs = tabs
        self.window = window
        watchCloseKeys()
        return window
    }
}
