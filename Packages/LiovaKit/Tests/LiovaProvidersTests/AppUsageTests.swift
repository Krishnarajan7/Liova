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

    @Test func theSimulatorCountsAsOneApp() {
        let simulator = "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"
        let parts = [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/"
                + "SimRenderingServices.simdeviceio/Contents/XPCServices/SimMetalHost.xpc/Contents/MacOS/SimMetalHost",
            "/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/Runtimes/"
                + "iOS 26.5.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/backboardd",
            "/Users/me/Library/Developer/CoreSimulator/Devices/178F/data/Containers/Bundle/Application/109E/"
                + "Runner.app/Runner",
        ]
        for path in parts {
            #expect(AppUsageReader.owner(of: path, responsiblePath: nil, simulator: simulator) == simulator)
        }
        // Simulator.app itself, inside Xcode, is its own app, not Xcode.
        #expect(AppUsageReader.appBundle(for: simulator + "/Contents/MacOS/Simulator") == simulator)
        #expect(AppUsageReader.appBundle(for: "/Applications/Xcode.app/Contents/MacOS/Xcode")
            == "/Applications/Xcode.app")
    }

    @Test func macOSBackgroundWorkIsNamed() {
        let analysis = "/System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd"
        #expect(AppUsageReader.work(at: analysis)?.name == "Photos")
        #expect(AppUsageReader.work(at: "/usr/libexec/coreaudiod") == nil)
        // Only macOS's own: a tool of the user's with the same name stays itself.
        #expect(AppUsageReader.work(at: "/Users/me/bin/cloudd") == nil)

        let apps = AppUsageReader.group([
            ProcessReading(
                pid: 1,
                path: "system:photos",
                cpu: 0.3,
                memory: 10,
                work: SystemWork.of(process: "mediaanalysisd")
            ),
            ProcessReading(
                pid: 2,
                path: "system:photos",
                cpu: 0.2,
                memory: 10,
                work: SystemWork.of(process: "photoanalysisd")
            ),
        ])
        #expect(apps.count == 1)
        #expect(apps[0].name == "Photos")
        #expect(apps[0].id == "system:photos")
        #expect(!apps[0].canQuit)
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
