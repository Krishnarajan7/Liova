import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaProviders
import Testing

private func app(_ name: String, cpu: Double, memory: UInt64 = 0) -> AppUsage {
    AppUsage(
        id: "/Applications/\(name).app",
        name: name,
        bundlePath: "/Applications/\(name).app",
        pids: [42],
        cpu: cpu,
        memory: memory
    )
}

private let gigabyte: UInt64 = 1_073_741_824

@MainActor
final class QuitRecorder {
    var quit: [String] = []
    var forced: [String] = []

    var quitter: AppQuitter {
        AppQuitter(quit: { [self] in quit.append($0.name) }, forceQuit: { [self] in forced.append($0.name) })
    }
}

@MainActor
struct ResourceAlertTests {
    let engine = ActivityEngine()
    let clock = HUDTestClock()
    let recorder = QuitRecorder()
    let settings: LiovaSettings
    let feature: ResourceAlertFeature
    private let scratch = ScratchDefaults()
    var stillRunning = true

    init() {
        settings = LiovaSettings(defaults: scratch.defaults)
        let clock = clock
        feature = ResourceAlertFeature(
            engine: engine, settings: settings, quitter: recorder.quitter,
            isRunning: { _ in true }, isHot: { false }, now: { clock.now }, totalMemory: 16 * gigabyte
        )
    }

    private func minute(_ apps: [AppUsage], memory: Double = 0.5, hot: Bool = false) {
        feature.receive(apps, memoryUsed: memory, hot: hot)
        clock.advance(60)
    }

    @Test func aSpikeIsNotWorthMentioning() {
        minute([app("Xcode", cpu: 3)])
        minute([app("Xcode", cpu: 3)])
        minute([app("Xcode", cpu: 0.1)])
        minute([app("Xcode", cpu: 3)])
        #expect(feature.alert == nil)
        #expect(engine.activity(ResourceAlertPolicy.alertID) == nil)
    }

    @Test func threeBusyMinutesNamesTheApp() throws {
        for _ in 0 ..< 3 {
            minute([app("Spotify", cpu: 1.45), app("Chrome", cpu: 0.2)])
        }
        let alert = try #require(feature.alert)
        #expect(alert.app.name == "Spotify")
        #expect(alert.title == "Spotify is heating up your Mac")
        #expect(alert.detail == "145% CPU for 3 min, draining battery")
        #expect(engine.activity(ResourceAlertPolicy.alertID)?.symbol == "flame.fill")
    }

    @Test func aHotMacSpeaksUpSooner() throws {
        minute([app("Spotify", cpu: 0.6)], hot: true)
        let alert = try #require(feature.alert)
        #expect(alert.detail == "60% CPU · your Mac is getting warm")
    }

    @Test func anAppHoveringAroundTheLineKeepsItsStreak() throws {
        minute([app("Simulator", cpu: 0.82)])
        minute([app("Simulator", cpu: 0.7)])
        minute([app("Simulator", cpu: 0.79)])
        #expect(try #require(feature.alert).app.name == "Simulator")
    }

    @Test func aCoreOfAppsTogetherIsEnough() throws {
        for _ in 0 ..< 3 {
            minute([app("Simulator", cpu: 0.6), app("Terminal", cpu: 0.25), app("Chrome", cpu: 0.2)])
        }
        let alert = try #require(feature.alert)
        #expect(alert.title == "Your Mac is working hard")
        #expect(alert.crowd.map(\.name) == ["Simulator", "Terminal", "Chrome"])
    }

    @Test func theAlertEndsWhenTheAppCalmsDown() {
        for _ in 0 ..< 3 {
            minute([app("Spotify", cpu: 1.45)])
        }
        #expect(feature.alert != nil)
        minute([app("Spotify", cpu: 0.05)])
        #expect(feature.alert == nil)
        #expect(engine.activity(ResourceAlertPolicy.alertID) == nil)
    }

    @Test func ignoredAppsStayQuiet() {
        for _ in 0 ..< 3 {
            minute([app("Spotify", cpu: 1.45)])
        }
        feature.ignore()
        for _ in 0 ..< 10 {
            minute([app("Spotify", cpu: 1.45)])
        }
        #expect(feature.alert == nil)
    }

    @Test func theSameAppIsNotBroughtUpAgainSoon() {
        for _ in 0 ..< 3 {
            minute([app("Spotify", cpu: 1.45)])
        }
        minute([app("Spotify", cpu: 0)]) // calmed down
        for _ in 0 ..< 5 {
            minute([app("Spotify", cpu: 1.45)])
        }
        #expect(feature.alert == nil)
        clock.advance(ResourceAlertPolicy.cooldown)
        minute([app("Spotify", cpu: 1.45)])
        #expect(feature.alert?.app.name == "Spotify")
    }

    @Test func memoryOnlyMattersWhenItRunsShort() throws {
        minute([app("Chrome", cpu: 0.1, memory: 6 * gigabyte)], memory: 0.6)
        #expect(feature.alert == nil)
        minute([app("Chrome", cpu: 0.1, memory: 6 * gigabyte)], memory: 0.9)
        let alert = try #require(feature.alert)
        #expect(alert.title == "Chrome is filling your memory")
        #expect(alert.detail == "Using 6.0 GB of 16 GB")
    }

    @Test func quitAsksTheAppAndOffersForceQuitIfItHangsOn() async {
        for _ in 0 ..< 3 {
            minute([app("Spotify", cpu: 1.45)])
        }
        feature.quit()
        #expect(recorder.quit == ["Spotify"])
        #expect(feature.quitState == .quitting)
        #expect(await eventually(timeout: .seconds(6)) { feature.quitState == .notResponding })
        feature.forceQuit()
        #expect(recorder.forced == ["Spotify"])
        #expect(feature.alert == nil)
    }

    @Test func turningItOffEndsTheAlert() {
        for _ in 0 ..< 3 {
            minute([app("Spotify", cpu: 1.45)])
        }
        settings.resourceAlertsEnabled = false
        feature.syncWithSettings()
        #expect(feature.alert == nil)
        #expect(engine.activity(ResourceAlertPolicy.alertID) == nil)
    }

    @Test func severalAppsAddingUpAreNamedTogether() throws {
        let photos = AppUsage(
            id: "system:photos", name: "Photos", bundlePath: nil, pids: [7], cpu: 0.46, memory: 0,
            work: SystemWork.of(process: "mediaanalysisd")
        )
        for _ in 0 ..< 3 {
            minute([app("Simulator", cpu: 0.75), photos, app("Chrome", cpu: 0.4), app("Notes", cpu: 0.05)])
        }
        let alert = try #require(feature.alert)
        #expect(alert.title == "Your Mac is working hard")
        #expect(alert.detail == "Simulator 75% · Photos 46% · Chrome 40%")
        #expect(alert.reading == "161%")
        // macOS's own work can't be quit; the apps can.
        feature.quit(photos)
        feature.quit(alert.crowd[0])
        #expect(recorder.quit == ["Simulator"])
        // Calm again: it ends.
        minute([app("Simulator", cpu: 0.1)])
        #expect(feature.alert == nil)
    }

    @Test func oneHeavyAppIsNamedBeforeTheCrowd() throws {
        for _ in 0 ..< 3 {
            minute([app("Spotify", cpu: 1.2), app("Chrome", cpu: 0.5)])
        }
        #expect(try #require(feature.alert).title == "Spotify is heating up your Mac")
    }

    @Test func ignoringTheCrowdKeepsSingleAppsAlerting() {
        for _ in 0 ..< 3 {
            minute([app("Simulator", cpu: 0.75), app("Chrome", cpu: 0.75)])
        }
        feature.ignore()
        for _ in 0 ..< 3 {
            minute([app("Simulator", cpu: 0.75), app("Chrome", cpu: 0.75)])
        }
        #expect(feature.alert == nil)
        for _ in 0 ..< 3 {
            minute([app("Xcode", cpu: 2)])
        }
        #expect(feature.alert?.app.name == "Xcode")
    }

    @Test func backgroundWorkSaysItStopsOnItsOwn() throws {
        let spotlight = AppUsage(
            id: "system:spotlight", name: "Spotlight", bundlePath: nil, pids: [8], cpu: 1.1, memory: 0,
            work: SystemWork.of(process: "mdworker_shared")
        )
        for _ in 0 ..< 3 {
            minute([spotlight])
        }
        let alert = try #require(feature.alert)
        #expect(alert.title == "Spotlight is indexing your files")
        #expect(alert.detail == "110% CPU for 3 min · it stops when it's done")
        feature.quit()
        #expect(recorder.quit.isEmpty)
    }

    @Test func pluggedInItWarmsInsteadOfDraining() throws {
        for _ in 0 ..< 3 {
            feature.receive([app("Spotify", cpu: 1.45)], memoryUsed: 0.5, hot: false, onBattery: false)
            clock.advance(60)
        }
        #expect(try #require(feature.alert).detail == "145% CPU for 3 min, warming your Mac")
    }
}

@MainActor
struct SystemPageAppsTests {
    @Test func listsTheTopAppsByTheChosenMeasure() {
        let feature = SystemMonitorFeature(quitter: QuitRecorder().quitter)
        feature.update([
            app("Spotify", cpu: 1.4, memory: 800),
            app("Chrome", cpu: 0.3, memory: 5000),
            app("Mail", cpu: 0.1, memory: 300),
            app("Notes", cpu: 0.05, memory: 900),
        ])
        #expect(feature.topApps.map(\.name) == ["Spotify", "Chrome", "Mail"])
        feature.ranking = .memory
        #expect(feature.topApps.map(\.name) == ["Chrome", "Notes", "Spotify"])
    }

    @Test func quitTurnsIntoForceQuitIfTheAppHangsOn() {
        let clock = HUDTestClock()
        let recorder = QuitRecorder()
        let feature = SystemMonitorFeature(quitter: recorder.quitter, now: { clock.now })
        let spotify = app("Spotify", cpu: 1.4)
        feature.update([spotify])
        #expect(feature.quitState(for: spotify) == .running)
        feature.quit(spotify)
        #expect(recorder.quit == ["Spotify"])
        #expect(feature.quitState(for: spotify) == .quitting)
        clock.advance(AppQuitter.patience)
        #expect(feature.quitState(for: spotify) == .notResponding)
        feature.update([]) // it quit
        feature.update([spotify]) // and was opened again
        #expect(feature.quitState(for: spotify) == .running)
    }

    @Test func numbersReadLikeActivityMonitor() {
        #expect(AppUsageText.cpu(1.449) == "145%")
        #expect(AppUsageText.memory(806 * 1_048_576) == "806 MB")
        #expect(AppUsageText.memory(2_469_606_195) == "2.3 GB")
        #expect(AppUsageText.hint(for: app("Spotify", cpu: 1.4), totalMemory: 16 * gigabyte) == "Heating up your Mac")
        #expect(AppUsageText.hint(for: app("Chrome", cpu: 0.1, memory: 4 * gigabyte), totalMemory: 16 * gigabyte)
            == "Filling memory")
        #expect(AppUsageText.hint(for: app("Mail", cpu: 0.1, memory: gigabyte), totalMemory: 16 * gigabyte) == nil)
    }
}

struct FallingWeatherTests {
    let size = CGSize(width: 16, height: 11)

    @Test func dropsFallAndFade() {
        let start = FallingWeather.drops(.rain, at: 100, in: size)
        let later = FallingWeather.drops(.rain, at: 100.1, in: size)
        #expect(start.count == later.count)
        // Most lanes moved down (one may have wrapped back to the top).
        let fell = zip(start, later).filter { $1.rect.minY > $0.rect.minY }.count
        #expect(fell >= start.count - 1)
        #expect(start.allSatisfy { (0 ... 1).contains($0.opacity) })
    }

    @Test func dropsStayInsideTheirSpace() {
        for step in 0 ..< 50 {
            for drop in FallingWeather.drops(.snow, at: Double(step) * 0.07, in: size) {
                #expect(drop.rect.midY >= -2 && drop.rect.midY <= size.height + 2)
            }
        }
    }

    @Test func eachSkyFallsItsOwnWay() {
        #expect(FallingWeather.Kind(.heavySnow) == .snow)
        #expect(FallingWeather.Kind(.thunderstorm) == .storm)
        #expect(FallingWeather.Kind(.drizzle) == .rain)
    }
}
