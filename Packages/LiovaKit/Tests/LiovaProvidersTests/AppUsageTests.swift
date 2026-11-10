@testable import LiovaProviders
import Testing

struct AppUsageTests {
    @Test func helpersCountTowardTheirApp() {
        let renderer = "/Applications/Spotify.app/Contents/Frameworks/Spotify Helper (Renderer).app/Contents/MacOS/x"
        #expect(AppUsageReader.appBundle(for: renderer) == "/Applications/Spotify.app")
        #expect(AppUsageReader.appBundle(for: "/Applications/Notes.app") == "/Applications/Notes.app")
        #expect(AppUsageReader.appBundle(for: "/Users/me/.local/bin/claude") == nil)
    }

    @Test func partsOfMacOSAreLeftOut() {
        #expect(AppUsageReader.owner(of: "/usr/libexec/coreaudiod", responsiblePath: nil) == nil)
        #expect(AppUsageReader.owner(
            of: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
            responsiblePath: nil
        ) == nil)
        // Homebrew and the user's own tools are theirs to quit.
        #expect(AppUsageReader.owner(of: "/usr/local/bin/node", responsiblePath: nil) == "/usr/local/bin/node")
        #expect(AppUsageReader.owner(of: "/opt/homebrew/bin/node", responsiblePath: nil) == "/opt/homebrew/bin/node")
    }

    @Test func webPagesCountTowardTheBrowserThatOpenedThem() {
        let webContent = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/"
            + "com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
        let safari = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"
        #expect(AppUsageReader.owner(of: webContent, responsiblePath: safari)
            == "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app")
        // Started by the Dock: still part of macOS.
        let dock = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
        #expect(AppUsageReader.owner(of: webContent, responsiblePath: dock) == nil)
    }

    @Test func groupsAddUpAndBusiestComesFirst() {
        let apps = AppUsageReader.group([
            ProcessReading(pid: 1, path: "/Applications/Chrome.app", cpu: 0.2, memory: 100),
            ProcessReading(pid: 2, path: "/Applications/Chrome.app", cpu: 0.3, memory: 200),
            ProcessReading(pid: 3, path: "/Applications/Spotify.app", cpu: 1.4, memory: 50),
            ProcessReading(pid: 4, path: "/Users/me/bin/2.1.314", name: "claude", cpu: 0.1, memory: 10),
        ])
        #expect(apps.map(\.name) == ["Spotify", "Chrome", "claude"])
        #expect(apps[1].pids == [1, 2])
        #expect(abs(apps[1].cpu - 0.5) < 0.0001)
        #expect(apps[1].memory == 300)
        #expect(apps[2].bundlePath == nil)
        #expect(apps[2].id == "pid:4")
    }

    @Test func readsThisMac() {
        // Smoke test: the real reader finds something and never reports a negative.
        let reader = AppUsageReader()
        _ = reader.sample()
        let apps = reader.sample()
        #expect(apps.allSatisfy { $0.cpu >= 0 })
    }
}
