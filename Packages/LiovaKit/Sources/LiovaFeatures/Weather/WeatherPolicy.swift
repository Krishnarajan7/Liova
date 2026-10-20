import Foundation
import LiovaPluginKit
import LiovaProviders

/// When weather gets a moment in the notch, and how temperatures and times read. Pure, so
/// it's unit-tested.
///
/// The one moment is a heads-up that rain (or snow, or a storm) is about to start: while
/// it's dry now, the first hour in the next two that's wet with at least a 50% chance.
/// Each spell is announced once; a later one, three hours or more after, is new.
public enum WeatherPolicy {
    public static let source = "system.weather"
    public static let rainID: ActivityID = "system.weather.rain"
    public static let pageID = "weather"

    static let rainDuration: TimeInterval = 8
    static let lookahead: TimeInterval = 2 * 3600
    static let minimumChance = 50
    /// A wet hour this long after the last one announced is a new spell.
    static let newSpellGap: TimeInterval = 3 * 3600

    /// Weather is fetched this often while on, and on wake or opening the page once older
    /// than `staleAfter`.
    public static let refreshInterval: Duration = .seconds(30 * 60)
    public static let staleAfter: TimeInterval = 10 * 60

    /// The hour rain starts, if it starts soon and hasn't been announced.
    static func rainSoon(in report: WeatherReport, now: Date, lastAnnounced: Date?) -> WeatherReport.Hour? {
        guard !report.current.condition.isWet else { return nil }
        let hour = report.hours.first { hour in
            // An hour still running counts: it started before now but isn't over.
            hour.time + 3600 > now && hour.time <= now + lookahead
                && hour.condition.isWet && (hour.precipitationChance ?? 0) >= minimumChance
        }
        guard let hour else { return nil }
        if let lastAnnounced, hour.time.timeIntervalSince(lastAnnounced) < newSpellGap {
            return nil
        }
        return hour
    }

    static func rainActivity(for hour: WeatherReport.Hour, timeZone: TimeZone, now: Date) -> Activity {
        let what = switch hour.condition {
        case .snow, .heavySnow, .snowShowers: "Snow"
        case .thunderstorm, .hail: "Storms"
        default: "Rain"
        }
        let when = hour.time <= now ? "\(what) starting soon" : "\(what) around \(time(hour.time, in: timeZone))"
        return Activity(
            id: rainID,
            source: source,
            priority: .normal,
            title: when,
            subtitle: hour.precipitationChance.map { "\($0)%" },
            symbol: hour.condition.symbol(isDay: hour.isDay),
            tint: .blue,
            expiresAt: now + rainDuration
        )
    }

    /// What the closed notch shows beside the rain symbol: "2 PM", or "Soon" once it's due.
    static func rainWhen(_ hour: WeatherReport.Hour, timeZone: TimeZone, now: Date) -> String {
        hour.time <= now ? "Soon" : time(hour.time, in: timeZone)
    }

    /// "21°", rounded, in the chosen unit.
    public static func temperature(_ celsius: Double, fahrenheit: Bool) -> String {
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        let rounded = Int(value.rounded())
        return "\(rounded == 0 ? 0 : rounded)°"
    }

    /// "3 PM" or "15:00", following the Mac's 12/24-hour setting, in the place's time zone.
    public static func time(_ date: Date, in timeZone: TimeZone, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: timeZone)
        style = style.hour(.defaultDigits(amPM: .abbreviated))
        return date.formatted(style)
    }

    /// "6:12 AM", for sunrise and sunset.
    public static func clock(_ date: Date, in timeZone: TimeZone, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
    }
}
