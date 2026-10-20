import Foundation
@testable import LiovaProviders
import Testing

struct OpenMeteoParsingTests {
    /// Trimmed from a real response (Chennai, timezone=auto, timeformat=unixtime).
    static let response = """
    {"latitude":13.11,"longitude":80.25,"utc_offset_seconds":19800,"timezone":"Asia/Kolkata",
     "current":{"time":1792476900,"interval":900,"temperature_2m":28.6,"apparent_temperature":32.9,
                "relative_humidity_2m":78,"weather_code":95,"is_day":1,"wind_speed_10m":14.8},
     "hourly":{"time":[1792470600,1792474200,1792477800,1792481400,1792485000],
               "temperature_2m":[29.2,28.6,28.9,null,29.0],
               "weather_code":[3,95,61,2,0],
               "precipitation_probability":[10,80,65,null,5],
               "is_day":[1,1,1,1,0]},
     "daily":{"time":[1792434600,1792521000],"weather_code":[95,2],
              "temperature_2m_max":[29.2,27.4],"temperature_2m_min":[24.3,23.9],
              "sunrise":[1792456920,1792543320],"sunset":[1792499100,1792585440]}}
    """

    @Test func parsesNowHoursAndDays() throws {
        let now = Date(timeIntervalSince1970: 1_792_476_900) // 15 minutes into the 1792476... hour
        let report = try OpenMeteoClient.parse(Data(Self.response.utf8), now: now)
        #expect(report.current.temperature == 28.6)
        #expect(report.current.feelsLike == 32.9)
        #expect(report.current.condition == .thunderstorm)
        #expect(report.current.humidity == 78)
        #expect(report.timeZone.identifier == "Asia/Kolkata")
        // The hour that's running is kept; the one before it isn't; the hour with no
        // temperature is skipped.
        #expect(report.hours.map(\.time.timeIntervalSince1970) == [1_792_474_200, 1_792_477_800, 1_792_485_000])
        #expect(report.hours.map(\.precipitationChance) == [80, 65, 5])
        #expect(report.hours.last?.isDay == false)
        #expect(report.days.count == 2)
        #expect(report.days.first?.high == 29.2)
        #expect(report.days.first?.sunrise == Date(timeIntervalSince1970: 1_792_456_920))
        #expect(report.fetchedAt == now)
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try OpenMeteoClient.parse(Data("{}".utf8), now: Date()) }
    }

    @Test func places() throws {
        let json = """
        {"results":[{"name":"Chennai","latitude":13.08784,"longitude":80.27847,"country":"India","admin1":"Tamil Nadu"},
                    {"name":"Singapore","latitude":1.29,"longitude":103.85,"country":"Singapore"}]}
        """
        let places = try OpenMeteoClient.parsePlaces(Data(json.utf8))
        #expect(places.map(\.name) == ["Chennai, Tamil Nadu, India", "Singapore"])
        #expect(try OpenMeteoClient.parsePlaces(Data(#"{"generationtime_ms":0.1}"#.utf8)).isEmpty)
    }

    @Test func coordinatesAreCoarse() {
        #expect(OpenMeteoClient.coarse(13.087_843) == 13.09)
        #expect(OpenMeteoClient.coarse(-0.004) == -0.0)
    }

    @Test func conditions() {
        #expect(WeatherCondition(wmoCode: 0) == .clear)
        #expect(WeatherCondition(wmoCode: 2) == .partlyCloudy)
        #expect(WeatherCondition(wmoCode: 65) == .heavyRain)
        #expect(WeatherCondition(wmoCode: 81) == .showers)
        #expect(WeatherCondition(wmoCode: 99) == .hail)
        #expect(WeatherCondition(wmoCode: 1234) == .cloudy)
        #expect(WeatherCondition.clear.symbol(isDay: false) == "moon.stars.fill")
        #expect(!WeatherCondition.fog.isWet)
        #expect(WeatherCondition.snowShowers.isWet)
    }
}

/// Talks to the real Open-Meteo. Off unless `LIOVA_LIVE_TESTS=1`:
///
///     LIOVA_LIVE_TESTS=1 swift test --filter WeatherLiveTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIOVA_LIVE_TESTS"] == "1"))
struct WeatherLiveTests {
    let client = OpenMeteoClient()

    @Test func forecastForACity() async throws {
        let report = try await client.report(latitude: 13.08, longitude: 80.27)
        #expect(report.hours.count >= 20)
        #expect(report.days.count >= 2)
        #expect((-60 ... 60).contains(report.current.temperature))
    }

    @Test func findsACity() async throws {
        let places = try await client.places(named: "Chennai")
        #expect(places.first?.name.hasPrefix("Chennai") == true)
    }
}
