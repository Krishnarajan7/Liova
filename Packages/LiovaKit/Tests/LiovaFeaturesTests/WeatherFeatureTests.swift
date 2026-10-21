import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaPluginKit
import LiovaProviders
import Testing

actor FakeWeather: WeatherFetching {
    private(set) var requests: [(Double, Double)] = []
    var answer: WeatherReport?

    init(answer: WeatherReport?) {
        self.answer = answer
    }

    func report(latitude: Double, longitude: Double) async throws -> WeatherReport {
        requests.append((latitude, longitude))
        guard let answer else { throw URLError(.notConnectedToInternet) }
        return answer
    }

    func places(named name: String) async throws -> [GeoPlace] {
        [GeoPlace(name: "\(name), Somewhere", latitude: 1, longitude: 2)]
    }

    func set(_ report: WeatherReport?) {
        answer = report
    }
}

@MainActor
final class FakeLocation: ApproximateLocating {
    var authorization: LocationAuthorization
    private(set) var asked = 0
    private var onChange: (@MainActor (LocationAuthorization) -> Void)?

    init(_ authorization: LocationAuthorization) {
        self.authorization = authorization
    }

    func requestAuthorization(onChange: @escaping @MainActor (LocationAuthorization) -> Void) {
        asked += 1
        self.onChange = onChange
    }

    func currentLocation() async throws -> ApproximatePlace {
        ApproximatePlace(latitude: 13.08, longitude: 80.27, name: "Chennai")
    }

    func answer(_ value: LocationAuthorization) {
        authorization = value
        onChange?(value)
    }
}

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func report(
    now condition: WeatherCondition = .cloudy,
    later: WeatherCondition = .rain,
    chance: Int = 70,
    fetchedAt: Date = start
) -> WeatherReport {
    WeatherReport(
        current: .init(temperature: 21.4, feelsLike: 24, condition: condition),
        hours: [
            .init(time: start - 600, temperature: 21, condition: condition, precipitationChance: 10),
            .init(time: start + 3000, temperature: 20, condition: later, precipitationChance: chance),
            .init(time: start + 6600, temperature: 19, condition: later, precipitationChance: chance),
        ],
        days: [.init(date: start, high: 24, low: 15, condition: later)],
        timeZone: TimeZone(identifier: "UTC")!,
        fetchedAt: fetchedAt
    )
}

struct WeatherPolicyTests {
    @Test func rainSoonWhileDry() throws {
        let hour = try #require(WeatherPolicy.rainSoon(in: report(), now: start, lastAnnounced: nil))
        #expect(hour.time == start + 3000)
        let activity = try WeatherPolicy.rainActivity(
            for: hour,
            timeZone: #require(TimeZone(identifier: "UTC")),
            now: start
        )
        #expect(activity.title.hasPrefix("Rain around"))
        #expect(activity.subtitle == "70%")
        #expect(activity.expiresAt == start + 8)
    }

    @Test func noHeadsUpWhenAlreadyRainingUnlikelyOrFar() {
        #expect(WeatherPolicy.rainSoon(in: report(now: .rain), now: start, lastAnnounced: nil) == nil)
        #expect(WeatherPolicy.rainSoon(in: report(chance: 30), now: start, lastAnnounced: nil) == nil)
        #expect(WeatherPolicy.rainSoon(in: report(later: .partlyCloudy), now: start, lastAnnounced: nil) == nil)
        #expect(WeatherPolicy.rainSoon(in: report(), now: start - 3 * 3600, lastAnnounced: nil) == nil)
    }

    @Test func oneHeadsUpPerSpell() {
        #expect(WeatherPolicy.rainSoon(in: report(), now: start, lastAnnounced: start + 3000) == nil)
        #expect(WeatherPolicy.rainSoon(in: report(), now: start, lastAnnounced: start - 4 * 3600) != nil)
    }

    @Test func snowAndStormsSayWhatTheyAre() throws {
        let hour = try #require(WeatherPolicy.rainSoon(in: report(later: .snow), now: start, lastAnnounced: nil))
        #expect(WeatherPolicy.rainActivity(for: hour, timeZone: .gmt, now: start).title.hasPrefix("Snow"))
        let running = WeatherReport.Hour(time: start - 60, temperature: 1, condition: .thunderstorm)
        #expect(WeatherPolicy.rainActivity(for: running, timeZone: .gmt, now: start).title == "Storms starting soon")
    }

    @Test func temperatures() {
        #expect(WeatherPolicy.temperature(21.4, fahrenheit: false) == "21°")
        #expect(WeatherPolicy.temperature(21.4, fahrenheit: true) == "71°")
        #expect(WeatherPolicy.temperature(-0.3, fahrenheit: false) == "0°")
        #expect(TemperatureUnit.automatic.usesFahrenheit(locale: Locale(identifier: "en_US")))
        #expect(!TemperatureUnit.automatic.usesFahrenheit(locale: Locale(identifier: "en_IN")))
    }

    @Test func hoursFollowThePlacesTimeZone() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000) // 08:00 UTC
        let locale = Locale(identifier: "en_GB")
        #expect(WeatherPolicy.time(date, in: .gmt, locale: locale) == "08")
        #expect(try WeatherPolicy
            .time(date, in: #require(TimeZone(identifier: "Asia/Kolkata")), locale: locale) == "13")
    }
}

@MainActor
struct WeatherFeatureTests {
    final class Clock: @unchecked Sendable {
        var now = start
    }

    let engine = ActivityEngine()
    let settings: LiovaSettings
    let clock = Clock()

    private let scratch = ScratchDefaults()

    init() throws {
        settings = LiovaSettings(defaults: scratch.defaults)
    }

    private func feature(_ fetcher: FakeWeather, _ location: FakeLocation) -> WeatherFeature {
        let clock = clock
        return WeatherFeature(engine: engine, settings: settings, fetcher: fetcher, location: { location }, now: {
            clock.now
        })
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    @Test func offByDefaultAndTouchesNothing() async throws {
        let fetcher = FakeWeather(answer: report())
        let location = FakeLocation(.notDetermined)
        let weather = feature(fetcher, location)
        weather.syncWithSettings()
        try await settle()
        #expect(!settings.weatherEnabled)
        #expect(weather.status == .off)
        #expect(location.asked == 0)
        #expect(await fetcher.requests.isEmpty)
    }

    @Test func aPickedCityNeedsNoLocation() async throws {
        let fetcher = FakeWeather(answer: report())
        let location = FakeLocation(.notDetermined)
        settings.weatherPlace = WeatherPlace(name: "Chennai, Tamil Nadu, India", latitude: 13.08, longitude: 80.27)
        settings.weatherEnabled = true
        let weather = feature(fetcher, location)
        weather.syncWithSettings()
        try await settle()
        #expect(weather.status == .ready)
        #expect(weather.placeName == "Chennai")
        #expect(location.asked == 0)
        #expect(await fetcher.requests.count == 1)
    }

    @Test func currentLocationAsksThenLoads() async throws {
        let fetcher = FakeWeather(answer: report())
        let location = FakeLocation(.notDetermined)
        settings.weatherEnabled = true
        let weather = feature(fetcher, location)
        weather.syncWithSettings()
        try await settle()
        #expect(weather.status == .needsPermission)
        #expect(location.asked == 1)
        location.answer(.authorized)
        try await settle()
        #expect(weather.status == .ready)
        #expect(weather.placeName == "Chennai")
    }

    @Test func deniedSaysSo() async throws {
        let weather = feature(FakeWeather(answer: report()), FakeLocation(.denied))
        settings.weatherEnabled = true
        weather.syncWithSettings()
        try await settle()
        #expect(weather.status == .denied)
    }

    @Test func offlineKeepsTheLastReport() async throws {
        let fetcher = FakeWeather(answer: report())
        settings.weatherEnabled = true
        let weather = feature(fetcher, FakeLocation(.authorized))
        weather.syncWithSettings()
        try await settle()
        await fetcher.set(nil)
        weather.refresh()
        try await settle()
        #expect(weather.status == .failed)
        #expect(weather.report != nil)
    }

    @Test func rainHeadsUpOnceAndOnlyWhenWanted() async throws {
        let fetcher = FakeWeather(answer: report())
        settings.weatherEnabled = true
        let weather = feature(fetcher, FakeLocation(.authorized))
        weather.syncWithSettings()
        try await settle()
        #expect(engine.activity(WeatherPolicy.rainID) != nil)
        engine.end(WeatherPolicy.rainID)
        weather.refresh()
        try await settle()
        #expect(engine.activity(WeatherPolicy.rainID) == nil)

        settings.rainAlertsEnabled = false
        weather.syncWithSettings()
        let quiet = feature(FakeWeather(answer: report()), FakeLocation(.authorized))
        quiet.syncWithSettings()
        try await settle()
        #expect(engine.activity(WeatherPolicy.rainID) == nil)
    }

    @Test func staleOnlyRefetchesWhenOld() async throws {
        let fetcher = FakeWeather(answer: report())
        settings.weatherEnabled = true
        let weather = feature(fetcher, FakeLocation(.authorized))
        weather.syncWithSettings()
        try await settle()
        weather.refreshIfStale()
        try await settle()
        #expect(await fetcher.requests.count == 1)
        clock.now += WeatherPolicy.staleAfter + 1
        weather.refreshIfStale()
        try await settle()
        #expect(await fetcher.requests.count == 2)
    }

    @Test func changingCityStartsOver() async throws {
        let fetcher = FakeWeather(answer: report())
        settings.weatherEnabled = true
        let weather = feature(fetcher, FakeLocation(.authorized))
        weather.syncWithSettings()
        try await settle()
        settings.weatherPlace = WeatherPlace(name: "Oslo, Norway", latitude: 59.91, longitude: 10.75)
        weather.syncWithSettings()
        try await settle()
        #expect(await fetcher.requests.last?.0 == 59.91)
        #expect(weather.placeName == "Oslo")
    }

    @Test func turningOffClearsEverything() async throws {
        settings.weatherEnabled = true
        let weather = feature(FakeWeather(answer: report()), FakeLocation(.authorized))
        weather.syncWithSettings()
        try await settle()
        settings.weatherEnabled = false
        weather.syncWithSettings()
        #expect(weather.status == .off)
        #expect(weather.report == nil)
        #expect(engine.activities.allSatisfy { $0.source != WeatherPolicy.source })
    }

    @Test func citySearchMapsToPlaces() async {
        let weather = feature(FakeWeather(answer: nil), FakeLocation(.denied))
        #expect(await weather.places(named: "Oslo").first?.name == "Oslo, Somewhere")
    }
}
