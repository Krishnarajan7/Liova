import AppKit
import LiovaCore

/// Thin lifecycle layer. Everything else lives in `AppCoordinator`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    /// Another copy of Liova that was already running when this one launched.
    /// Two copies would draw two notches, so this copy hands off and quits.
    private lazy var originalInstance: NSRunningApplication? = {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != .current }
            .min { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
    }()

    private var pendingForwards = 0
    private var shouldQuitAfterForwarding = false

    func applicationDidFinishLaunching(_: Notification) {
        // Agent app: no Dock icon, no main window. Matches LSUIElement in Info.plist.
        NSApp.setActivationPolicy(.accessory)
        if originalInstance != nil {
            Log.app.notice("Another Liova is running; handing off and quitting this copy")
            shouldQuitAfterForwarding = true
            quitIfDoneForwarding()
            return
        }
        coordinator.start()
    }

    /// Handles `liova://` links. A link can launch a second copy of Liova (e.g. when
    /// two builds are installed); that copy passes the link on to the running one.
    func application(_: NSApplication, open urls: [URL]) {
        if let original = originalInstance, let appURL = original.bundleURL {
            forward(urls, to: appURL)
        } else {
            urls.forEach(coordinator.open)
        }
    }

    func applicationDidBecomeActive(_: Notification) {
        coordinator.hud.recheckPermission()
    }

    func applicationWillTerminate(_: Notification) {
        coordinator.stop()
    }

    private func forward(_ urls: [URL], to appURL: URL) {
        pendingForwards += 1
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration) { _, error in
            Task { @MainActor [weak self] in
                if let error {
                    Log.app.error("Couldn't forward link: \(error.localizedDescription, privacy: .public)")
                }
                self?.pendingForwards -= 1
                self?.quitIfDoneForwarding()
            }
        }
    }

    private func quitIfDoneForwarding() {
        guard shouldQuitAfterForwarding, pendingForwards == 0 else { return }
        NSApp.terminate(nil)
    }
}
