import Foundation
import os

/// A source of weather and place names. Behind a protocol so features are tested offline.
public protocol WeatherFetching: Sendable {
    func report(latitude: Double, longitude: Double) async throws -> WeatherReport
    func places(named name: String) async throws -> [GeoPlace]
}

/// Open-Meteo (open-meteo.com): free weather for non-commercial use, no account or key.
/// Data is CC BY 4.0; Liova credits it in Settings and under About > Licenses.
///
/// Sends only coordinates, rounded to two decimals (about a kilometre) so the exact
/// position never leaves the Mac, or the name typed into the city search.
public struct OpenMeteoClient: WeatherFetching {
    private let session: URLSession
    private let forecastURL = URL(string: "https://api.open-meteo.com/v1/forecast")!
    private let geocodingURL = URL(string: "https://geocoding-api.open-meteo.com/v1/search")!
    private static let log = Logger(subsystem: "app.liova.Liova", category: "weather")

    /// Hours of forecast kept after the current one.
    static let hoursAhead = 24

    public init(session: URLSession? = nil) {
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.waitsForConnectivity = false
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            configuration
                .httpAdditionalHeaders = ["User-Agent": "Liova/\(version) (https://github.com/Krishnarajan7/Liova)"]
            return URLSession(configuration: configuration)
        }()
    }

    /// Two decimals: about a kilometre, plenty for weather and not a street address.
    public static func coarse(_ coordinate: Double) -> Double {
        (coordinate * 100).rounded() / 100
    }

    public func report(latitude: Double, longitude: Double) async throws -> WeatherReport {
        var components = URLComponents(url: forecastURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(Self.coarse(latitude))),
            URLQueryItem(name: "longitude", value: String(Self.coarse(longitude))),
            URLQueryItem(
                name: "current",
                value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,wind_speed_10m"
            ),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: "3"),
        ]
        let (data, response) = try await session.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            Self.log.notice("Weather request failed")
            throw URLError(.badServerResponse)
        }
        return try Self.parse(data, now: Date())
    }

    public func places(named name: String) async throws -> [GeoPlace] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        var components = URLComponents(url: geocodingURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: "6"),
            URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        let (data, response) = try await session.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try Self.parsePlaces(data)
    }

    // MARK: - Parsing

    /// Turns Open-Meteo's column-per-field JSON into a report, keeping hours from the current
    /// one on. Pure, so it's tested with a recorded response.
    static func parse(_ data: Data, now: Date) throws -> WeatherReport {
        let response = try JSONDecoder().decode(OpenMeteoForecast.self, from: data)
        let timeZone = response.timezone.flatMap(TimeZone.init(identifier:))
            ?? response.utcOffsetSeconds.flatMap(TimeZone.init(secondsFromGMT:))
            ?? .current

        let current = WeatherReport.Current(
            temperature: response.current.temperature2m,
            feelsLike: response.current.apparentTemperature,
            condition: WeatherCondition(wmoCode: response.current.weatherCode),
            isDay: (response.current.isDay ?? 1) != 0,
            humidity: response.current.relativeHumidity2m.map { Int($0.rounded()) },
            windSpeed: response.current.windSpeed10m
        )

        let hourly = response.hourly
        let thisHour = now.timeIntervalSince1970 - 3600
        var hours: [WeatherReport.Hour] = []
        for (index, time) in hourly.time.enumerated() where time > thisHour {
            guard let temperature = hourly.temperature2m[safe: index] ?? nil,
                  let code = hourly.weatherCode[safe: index] ?? nil
            else { continue }
            hours.append(WeatherReport.Hour(
                time: Date(timeIntervalSince1970: time),
                temperature: temperature,
                condition: WeatherCondition(wmoCode: code),
                precipitationChance: (hourly.precipitationProbability?[safe: index] ?? nil).map { Int($0.rounded()) },
                isDay: (hourly.isDay?[safe: index] ?? nil).map { $0 != 0 } ?? true
            ))
            if hours.count > hoursAhead {
                break
            }
        }

        let daily = response.daily
        let days: [WeatherReport.Day] = daily.time.enumerated().compactMap { index, time in
            guard let high = daily.temperature2mMax[safe: index] ?? nil,
                  let low = daily.temperature2mMin[safe: index] ?? nil,
                  let code = daily.weatherCode[safe: index] ?? nil
            else { return nil }
            return WeatherReport.Day(
                date: Date(timeIntervalSince1970: time),
                high: high,
                low: low,
                condition: WeatherCondition(wmoCode: code),
                sunrise: (daily.sunrise?[safe: index] ?? nil).map(Date.init(timeIntervalSince1970:)),
                sunset: (daily.sunset?[safe: index] ?? nil).map(Date.init(timeIntervalSince1970:))
            )
        }
        return WeatherReport(current: current, hours: hours, days: days, timeZone: timeZone, fetchedAt: now)
    }

    static func parsePlaces(_ data: Data) throws -> [GeoPlace] {
        let response = try JSONDecoder().decode(OpenMeteoPlaces.self, from: data)
        return (response.results ?? []).map { result in
            // "Chennai, Tamil Nadu, India", skipping parts that repeat the name or are missing.
            var parts = [result.name]
            for part in [result.admin1, result.country].compactMap(\.self) where !parts.contains(part) {
                parts.append(part)
            }
            return GeoPlace(name: parts.joined(separator: ", "), latitude: result.latitude, longitude: result.longitude)
        }
    }
}

/// Open-Meteo's forecast JSON. Field names as sent; `convertFromSnakeCase` would turn
/// `temperature_2m` into `temperature2M`.
struct OpenMeteoForecast: Decodable {
    var utcOffsetSeconds: Int?
    var timezone: String?
    var current: OpenMeteoCurrent
    var hourly: OpenMeteoHourly
    var daily: OpenMeteoDaily

    enum CodingKeys: String, CodingKey {
        case utcOffsetSeconds = "utc_offset_seconds", timezone, current, hourly, daily
    }
}

struct OpenMeteoCurrent: Decodable {
    var temperature2m: Double
    var apparentTemperature: Double?
    var relativeHumidity2m: Double?
    var weatherCode: Int
    var isDay: Int?
    var windSpeed10m: Double?

    enum CodingKeys: String, CodingKey {
        case temperature2m = "temperature_2m", apparentTemperature = "apparent_temperature"
        case relativeHumidity2m = "relative_humidity_2m", weatherCode = "weather_code"
        case isDay = "is_day", windSpeed10m = "wind_speed_10m"
    }
}

/// One array per field, index-aligned with `time`.
struct OpenMeteoHourly: Decodable {
    var time: [TimeInterval]
    var temperature2m: [Double?]
    var weatherCode: [Int?]
    var precipitationProbability: [Double?]?
    var isDay: [Int?]?

    enum CodingKeys: String, CodingKey {
        case time, temperature2m = "temperature_2m", weatherCode = "weather_code"
        case precipitationProbability = "precipitation_probability", isDay = "is_day"
    }
}

struct OpenMeteoDaily: Decodable {
    var time: [TimeInterval]
    var weatherCode: [Int?]
    var temperature2mMax: [Double?]
    var temperature2mMin: [Double?]
    var sunrise: [TimeInterval?]?
    var sunset: [TimeInterval?]?

    enum CodingKeys: String, CodingKey {
        case time, weatherCode = "weather_code", temperature2mMax = "temperature_2m_max"
        case temperature2mMin = "temperature_2m_min", sunrise, sunset
    }
}

/// Open-Meteo's geocoding JSON; `results` is missing when nothing matches.
struct OpenMeteoPlaces: Decodable {
    var results: [OpenMeteoPlace]?
}

struct OpenMeteoPlace: Decodable {
    var name: String
    var latitude: Double
    var longitude: Double
    var admin1: String?
    var country: String?
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
