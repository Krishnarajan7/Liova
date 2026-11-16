import Foundation
import LiovaCore
import Testing

@MainActor
struct LiovaSettingsTests {
    private let scratch = ScratchDefaults()

    var defaults: UserDefaults {
        scratch.defaults
    }

    @Test func defaultsAreSensible() {
        let settings = LiovaSettings(defaults: defaults)
        #expect(settings.openOnHover)
        #expect(settings.hoverDelay == 0.12)
        #expect(settings.displayPlacement == .allDisplays)
        #expect(settings.lowBatteryThreshold == 20)
        #expect(!settings.hudReplacementEnabled)
        #expect(settings.nowPlayingEnabled)
        #expect(settings.musicBars == .always)
        #expect(!settings.lyricsEnabled)
        #expect(settings.lyricsInClosedNotch)
        #expect(settings.agentsOverMusic)
        #expect(settings.notchStyle == .black)
        #expect(settings.resourceAlertsEnabled)
    }

    @Test func everyPreferenceChangeRaisesTheRevision() {
        let settings = LiovaSettings(defaults: defaults)
        var last = settings.revision
        func changed() -> Bool {
            defer { last = settings.revision }
            return settings.revision > last
        }
        settings.hudStyle = .notch
        #expect(changed())
        settings.musicBars = .off
        #expect(changed())
        settings.hoverDelay = 0.5
        #expect(changed())
        settings.weatherPlace = WeatherPlace(name: "Chennai", latitude: 13.08, longitude: 80.27)
        #expect(changed())
        settings.weatherPlace = nil
        #expect(changed())
        settings.customShortcuts = [:]
        #expect(changed())
    }

    @Test func bookkeepingDoesNotRaiseTheRevision() {
        let settings = LiovaSettings(defaults: defaults)
        let before = settings.revision
        settings.hasSeenWelcome = true
        settings.lastUpdateCheck = Date()
        settings.skippedUpdateVersion = "9.9.9"
        settings.skippedUpdateVersion = nil
        #expect(settings.revision == before)
    }

    @Test func worldClockCitiesStartWithThreeAndCanBeEmptied() {
        #expect(LiovaSettings(defaults: defaults).worldClockCities == LiovaSettings.defaultWorldClockCities)
        LiovaSettings(defaults: defaults).worldClockCities = ["Asia/Kolkata"]
        #expect(LiovaSettings(defaults: defaults).worldClockCities == ["Asia/Kolkata"])
        // Removing every city hides the world clock, and it stays hidden.
        LiovaSettings(defaults: defaults).worldClockCities = []
        #expect(LiovaSettings(defaults: defaults).worldClockCities.isEmpty)
    }

    @Test func notchStyleIsRemembered() {
        LiovaSettings(defaults: defaults).notchStyle = .glass
        #expect(LiovaSettings(defaults: defaults).notchStyle == .glass)
        defaults.set("chrome", forKey: "notchStyle") // unknown: back to black
        #expect(LiovaSettings(defaults: defaults).notchStyle == .black)
    }

    @Test func oldMusicBarsSwitchCarriesOver() {
        defaults.set(false, forKey: "animatedMusicBars")
        #expect(LiovaSettings(defaults: defaults).musicBars == .off)
        defaults.set(true, forKey: "animatedMusicBars")
        #expect(LiovaSettings(defaults: defaults).musicBars == .always)
        defaults.set("off", forKey: "musicBars")
        #expect(LiovaSettings(defaults: defaults).musicBars == .off)
    }

    @Test func musicBarsRestOnBatteryByDefault() {
        #expect(MusicBarsMode.pluggedIn.animates(onBattery: false))
        #expect(!MusicBarsMode.pluggedIn.animates(onBattery: true))
        #expect(MusicBarsMode.always.animates(onBattery: true))
        #expect(!MusicBarsMode.off.animates(onBattery: false))
    }

    @Test func valuesPersistAcrossInstances() {
        let first = LiovaSettings(defaults: defaults)
        first.openOnHover = false
        first.displayPlacement = .builtInOnly
        first.hoverDelay = 0.3
        first.lyricsInClosedNotch = false
        let second = LiovaSettings(defaults: defaults)
        #expect(!second.openOnHover)
        #expect(second.displayPlacement == .builtInOnly)
        #expect(second.hoverDelay == 0.3)
        #expect(!second.lyricsInClosedNotch)
    }

    @Test func outOfRangeValuesAreClamped() {
        let settings = LiovaSettings(defaults: defaults)
        settings.hoverDelay = 99
        settings.lowBatteryThreshold = 1
        #expect(settings.hoverDelay == 1)
        #expect(settings.lowBatteryThreshold == 5)
        #expect(LiovaSettings(defaults: defaults).lowBatteryThreshold == 5)
    }

    @Test func corruptStoredPlacementFallsBack() {
        defaults.set("sideways", forKey: "displayPlacement")
        #expect(LiovaSettings(defaults: defaults).displayPlacement == .allDisplays)
    }
}

struct DisplayPlacementTests {
    let laptop = Display(
        id: "laptop", displayID: 1, name: "Built-in", isBuiltIn: true, isMain: false,
        metrics: Fixtures.macBookAirM4
    )
    let monitor = Display(
        id: "monitor", displayID: 2, name: "Studio", isBuiltIn: false, isMain: true,
        metrics: Fixtures.externalRight
    )

    @Test func allDisplays() {
        #expect(DisplayPlacement.allDisplays.select(from: [laptop, monitor]).map(\.id) == ["laptop", "monitor"])
    }

    @Test func builtInOnly() {
        #expect(DisplayPlacement.builtInOnly.select(from: [laptop, monitor]).map(\.id) == ["laptop"])
    }

    @Test func builtInOnlyFallsBackToMainWhenLidClosed() {
        #expect(DisplayPlacement.builtInOnly.select(from: [monitor]).map(\.id) == ["monitor"])
    }

    @Test func mainOnly() {
        #expect(DisplayPlacement.mainOnly.select(from: [laptop, monitor]).map(\.id) == ["monitor"])
    }
}
