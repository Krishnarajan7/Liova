import SwiftUI

@main
struct LiovaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(coordinator: appDelegate.coordinator)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }

        Settings {
            SettingsView(coordinator: appDelegate.coordinator)
        }
    }
}

private struct MenuContent: View {
    let coordinator: AppCoordinator

    var body: some View {
        Text("Liova \(Bundle.main.shortVersion)")
        Divider()
        Button("Show Demo Activity") { coordinator.runDemo() }
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Liova") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
