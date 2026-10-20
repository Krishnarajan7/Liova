import Foundation

/// The weather at a place: now, the coming hours, and today and tomorrow. Temperatures are
/// always Celsius; views convert, so switching units never asks the network again.
public struct WeatherReport: Equatable, Sendable {
    public var current: Current
    /// From the current hour on.
    public var hours: [Hour]
    /// Today first.
    public var days: [Day]
    /// The place's time zone, for showing its hours and sunrise.
    public var timeZone: TimeZone
    public var fetchedAt: Date

    public init(current: Current, hours: [Hour], days: [Day], timeZone: TimeZone, fetchedAt: Date) {
        self.current = current
        self.hours = hours
        self.days = days
        self.timeZone = timeZone
        self.fetchedAt = fetchedAt
    }

    public struct Current: Equatable, Sendable {
        public var temperature: Double
        public var feelsLike: Double?
        public var condition: WeatherCondition
        public var isDay: Bool
        public var humidity: Int?
        /// km/h.
        public var windSpeed: Double?

        public init(
            temperature: Double,
            feelsLike: Double? = nil,
            condition: WeatherCondition,
            isDay: Bool = true,
            humidity: Int? = nil,
            windSpeed: Double? = nil
        ) {
            self.temperature = temperature
            self.feelsLike = feelsLike
            self.condition = condition
            self.isDay = isDay
            self.humidity = humidity
            self.windSpeed = windSpeed
        }
    }

    public struct Hour: Equatable, Sendable, Identifiable {
        public var time: Date
        public var temperature: Double
        public var condition: WeatherCondition
        /// 0…100, when known.
        public var precipitationChance: Int?
        public var isDay: Bool

        public var id: Date {
            time
        }

        public init(
            time: Date,
            temperature: Double,
            condition: WeatherCondition,
            precipitationChance: Int? = nil,
            isDay: Bool = true
        ) {
            self.time = time
            self.temperature = temperature
            self.condition = condition
            self.precipitationChance = precipitationChance
            self.isDay = isDay
        }
    }

    public struct Day: Equatable, Sendable {
        public var date: Date
        public var high: Double
        public var low: Double
        public var condition: WeatherCondition
        public var sunrise: Date?
        public var sunset: Date?

        public init(
            date: Date,
            high: Double,
            low: Double,
            condition: WeatherCondition,
            sunrise: Date? = nil,
            sunset: Date? = nil
        ) {
            self.date = date
            self.high = high
            self.low = low
            self.condition = condition
            self.sunrise = sunrise
            self.sunset = sunset
        }
    }
}

/// What the sky is doing, from the WMO weather codes Open-Meteo reports.
public enum WeatherCondition: String, Sendable, CaseIterable {
    case clear
    case mostlyClear
    case partlyCloudy
    case cloudy
    case fog
    case drizzle
    case freezingDrizzle
    case rain
    case heavyRain
    case freezingRain
    case snow
    case heavySnow
    case showers
    case snowShowers
    case thunderstorm
    case hail

    /// WMO 4677 codes as Open-Meteo documents them. Unknown codes read as cloudy rather
    /// than failing the whole report.
    public init(wmoCode: Int) {
        self = Self.byWMOCode[wmoCode] ?? .cloudy
    }

    private static let byWMOCode: [Int: WeatherCondition] = [
        0: .clear, 1: .mostlyClear, 2: .partlyCloudy, 3: .cloudy, 45: .fog, 48: .fog,
        51: .drizzle, 53: .drizzle, 55: .drizzle, 56: .freezingDrizzle, 57: .freezingDrizzle,
        61: .rain, 63: .rain, 65: .heavyRain, 66: .freezingRain, 67: .freezingRain,
        71: .snow, 73: .snow, 77: .snow, 75: .heavySnow, 80: .showers, 81: .showers, 82: .showers,
        85: .snowShowers, 86: .snowShowers, 95: .thunderstorm, 96: .hail, 99: .hail,
    ]

    /// How each condition reads and looks: a title, and SF Symbols for day and night.
    private struct Look {
        let title: String
        let day: String
        var night: String?
    }

    private static let looks: [WeatherCondition: Look] = [
        .clear: Look(title: "Clear", day: "sun.max.fill", night: "moon.stars.fill"),
        .mostlyClear: Look(title: "Mostly Clear", day: "cloud.sun.fill", night: "cloud.moon.fill"),
        .partlyCloudy: Look(title: "Partly Cloudy", day: "cloud.sun.fill", night: "cloud.moon.fill"),
        .cloudy: Look(title: "Cloudy", day: "cloud.fill"),
        .fog: Look(title: "Fog", day: "cloud.fog.fill"),
        .drizzle: Look(title: "Drizzle", day: "cloud.drizzle.fill"),
        .freezingDrizzle: Look(title: "Freezing Drizzle", day: "cloud.drizzle.fill"),
        .rain: Look(title: "Rain", day: "cloud.rain.fill"),
        .heavyRain: Look(title: "Heavy Rain", day: "cloud.heavyrain.fill"),
        .freezingRain: Look(title: "Freezing Rain", day: "cloud.rain.fill"),
        .snow: Look(title: "Snow", day: "cloud.snow.fill"),
        .heavySnow: Look(title: "Heavy Snow", day: "cloud.snow.fill"),
        .showers: Look(title: "Showers", day: "cloud.sun.rain.fill", night: "cloud.moon.rain.fill"),
        .snowShowers: Look(title: "Snow Showers", day: "cloud.snow.fill"),
        .thunderstorm: Look(title: "Thunderstorms", day: "cloud.bolt.rain.fill"),
        .hail: Look(title: "Thunderstorms and Hail", day: "cloud.hail.fill"),
    ]

    public var title: String {
        Self.looks[self]?.title ?? rawValue
    }

    /// An SF Symbol, with the sun or moon depending on the time of day.
    public func symbol(isDay: Bool) -> String {
        guard let look = Self.looks[self] else { return "cloud.fill" }
        return isDay ? look.day : look.night ?? look.day
    }

    /// Rain, snow or storms: what a "starting soon" heads-up is about.
    public var isWet: Bool {
        switch self {
        case .clear, .mostlyClear, .partlyCloudy, .cloudy, .fog: false
        default: true
        }
    }
}

/// A place found by name.
public struct GeoPlace: Equatable, Sendable {
    /// "Chennai, Tamil Nadu, India".
    public var name: String
    public var latitude: Double
    public var longitude: Double

    public init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }
}
