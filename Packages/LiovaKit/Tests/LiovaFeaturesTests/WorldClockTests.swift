import AppKit
import Foundation
import LiovaCore
@testable import LiovaFeatures
import SwiftUI
import Testing

struct WorldClockTests {
    /// 15 November 2026, 12:00 in Chennai (06:30 UTC).
    private let noon = Date(timeIntervalSince1970: 1_794_724_200)
    private let chennai = TimeZone(identifier: "Asia/Kolkata")!
    private let english = Locale(identifier: "en_US")

    private func entry(_ zoneID: String, at date: Date? = nil) -> WorldClockEntry? {
        WorldClockPolicy.entry(zoneID: zoneID, now: date ?? noon, local: chennai, locale: english)
    }

    @Test func citiesAreNamedAfterTheirTimeZone() {
        #expect(WorldClockPolicy.city(for: "Asia/Tokyo") == "Tokyo")
        #expect(WorldClockPolicy.city(for: "America/New_York") == "New York")
        #expect(WorldClockPolicy.city(for: "America/Argentina/Buenos_Aires") == "Buenos Aires")
        #expect(WorldClockPolicy.city(for: "UTC") == "UTC")
    }

    @Test func aCityAheadShowsItsTimeAndHowFarAhead() throws {
        let tokyo = try #require(entry("Asia/Tokyo"))
        #expect(tokyo.time.replacingOccurrences(of: "\u{202F}", with: " ") == "3:30 PM")
        #expect(tokyo.detail == "Today · +3:30")
        #expect(!tokyo.isNight)
    }

    @Test func aCityBehindCanStillBeOnYesterday() throws {
        // 12:00 in Chennai is 22:30 the evening before in Los Angeles.
        let losAngeles = try #require(entry("America/Los_Angeles"))
        #expect(losAngeles.detail == "Yesterday · -13:30")
        #expect(losAngeles.isNight)
    }

    @Test func aCityAheadCanAlreadyBeOnTomorrow() throws {
        // 23:00 in Chennai is 02:30 the next morning in Tokyo.
        let tokyo = try #require(entry("Asia/Tokyo", at: noon + 11 * 3600))
        #expect(tokyo.detail == "Tomorrow · +3:30")
        #expect(tokyo.isNight)
    }

    @Test func theSameTimeZoneHasNoOffset() throws {
        #expect(try #require(entry("Asia/Kolkata")).detail == "Today")
        #expect(WorldClockPolicy.offsetText(seconds: 0).isEmpty)
        #expect(WorldClockPolicy.offsetText(seconds: 9 * 3600) == "+9h")
        #expect(WorldClockPolicy.offsetText(seconds: -(5 * 3600 + 45 * 60)) == "-5:45")
    }

    @Test func unknownAndRepeatedCitiesAreLeftOutAndFourIsTheMost() {
        let zones = [
            "Asia/Tokyo", "Nowhere/Atlantis", "Asia/Tokyo", "Europe/London", "America/New_York",
            "Australia/Sydney", "Africa/Cairo",
        ]
        let entries = WorldClockPolicy.entries(zoneIDs: zones, now: noon, local: chennai, locale: english)
        #expect(entries.map(\.city) == ["Tokyo", "London", "New York", "Sydney"])
    }

    @Test func everyRegionOffersItsCitiesInOrder() throws {
        let regions = WorldClockPolicy.regions()
        let asia = try #require(regions.first { $0.name == "Asia" })
        #expect(asia.zoneIDs.contains("Asia/Tokyo"))
        #expect(asia.zoneIDs.map(WorldClockPolicy.city(for:)) == asia.zoneIDs.map(WorldClockPolicy.city(for:)).sorted())
    }

    /// Renders the Timers page with the world clock when `LIOVA_SNAPSHOT_DIR` is set.
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIOVA_SNAPSHOT_DIR"] != nil))
    func snapshot() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIOVA_SNAPSHOT_DIR"] ?? "/tmp")
        let defaults = try #require(UserDefaults(suiteName: "liova-worldclock-\(UUID().uuidString)"))
        let settings = LiovaSettings(defaults: defaults)
        settings.worldClockCities = ["America/New_York", "Europe/London", "Asia/Tokyo", "Australia/Sydney"]
        let feature = TimerFeature(engine: ActivityEngine(), playSound: {})
        feature.start(duration: 25 * 60)
        let view = TimersPage(feature: feature, settings: settings)
            .padding(14)
            .frame(width: 480)
            .background(.black)
            .environment(\.colorScheme, .dark)
        _ = ImageRenderer(content: view).nsImage
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let tiff = try #require(renderer.nsImage?.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("timers-world-clock.png"))
    }
}
