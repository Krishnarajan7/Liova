import LiovaPluginKit
import LiovaProviders
import LiovaUI
import SwiftUI

/// The rain heads-up in the closed notch: rain falling from a cloud on the left, when on the
/// right.
@MainActor
public final class WeatherRenderer: ActivityRenderer {
    private let feature: WeatherFeature

    public init(feature: WeatherFeature) {
        self.feature = feature
    }

    public func compactLeading(for activity: Activity) -> AnyView? {
        guard activity.id == WeatherPolicy.rainID, let hour = feature.announcedRain else {
            return AnyView(
                Image(systemName: activity.symbol ?? "cloud.rain.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 13, weight: .semibold))
            )
        }
        return AnyView(FallingWeather(kind: .init(hour.condition)))
    }

    public func compactTrailing(for activity: Activity) -> AnyView? {
        guard activity.id == WeatherPolicy.rainID, let hour = feature.announcedRain else { return nil }
        let timeZone = feature.report?.timeZone ?? .current
        return AnyView(
            Text(WeatherPolicy.rainWhen(hour, timeZone: timeZone, now: Date()))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1))
                .lineLimit(1)
                .fixedSize()
        )
    }
}

/// The Weather page: the temperature and sky now with today's range on the left, the next
/// hours on the right. The notch fits around it.
public struct WeatherPage: View {
    let feature: WeatherFeature

    public init(feature: WeatherFeature) {
        self.feature = feature
    }

    public var body: some View {
        VStack(spacing: 6) {
            if let report = feature.report {
                WeatherNow(report: report, place: feature.placeName, fahrenheit: feature.usesFahrenheit)
                    .overlay(alignment: .bottomTrailing) {
                        if feature.status == .failed {
                            Text("Offline · \(WeatherPolicy.clock(report.fetchedAt, in: .current))")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
            } else {
                switch feature.status {
                case .needsPermission:
                    WeatherMessage(symbol: "location", text: "Allow location access to see the weather here,")
                    SettingsHint()
                case .denied:
                    VStack(spacing: 6) {
                        WeatherMessage(symbol: "location.slash", text: "Location is off for Liova.")
                        HStack(spacing: 14) {
                            Button("Open Privacy Settings") { feature.openLocationSettings() }
                            Text("or pick a city in Liova's Settings.")
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.blue)
                    }
                case .failed:
                    VStack(spacing: 6) {
                        WeatherMessage(symbol: "icloud.slash", text: "Couldn't load the weather.")
                        Button("Try Again") { feature.refresh() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                case .off:
                    WeatherMessage(symbol: "cloud.sun", text: "Turn on Weather in Liova's Settings.")
                case .loading, .ready:
                    WeatherMessage(symbol: "cloud.sun", text: "Getting the weather…")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.top, 2)
        .onAppear { feature.refreshIfStale() }
    }
}

private struct SettingsHint: View {
    var body: some View {
        Text("or pick a city in Liova's Settings.")
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
    }
}

private struct WeatherNow: View {
    let report: WeatherReport
    let place: String?
    let fahrenheit: Bool

    private static let hourCount = 5

    var body: some View {
        let current = report.current
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: current.condition.symbol(isDay: current.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 26))
                    Text(WeatherPolicy.temperature(current.temperature, fahrenheit: fahrenheit))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                }
                Text(current.condition.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(details)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                if let place {
                    Label(place, systemImage: "location.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(report.hours.prefix(Self.hourCount)) { hour in
                    HourColumn(
                        hour: hour,
                        isNow: hour.id == report.hours.first?.id,
                        timeZone: report.timeZone,
                        fahrenheit: fahrenheit
                    )
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "H 31°  L 25° · Feels 34°".
    private var details: String {
        var parts: [String] = []
        if let today = report.days.first {
            parts.append(
                "H \(WeatherPolicy.temperature(today.high, fahrenheit: fahrenheit))  "
                    + "L \(WeatherPolicy.temperature(today.low, fahrenheit: fahrenheit))"
            )
        }
        if let feelsLike = report.current.feelsLike,
           abs(feelsLike - report.current.temperature) >= 2
        {
            parts.append("Feels \(WeatherPolicy.temperature(feelsLike, fahrenheit: fahrenheit))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct HourColumn: View {
    let hour: WeatherReport.Hour
    let isNow: Bool
    let timeZone: TimeZone
    let fahrenheit: Bool

    var body: some View {
        VStack(spacing: 5) {
            Text(isNow ? "Now" : WeatherPolicy.time(hour.time, in: timeZone))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(isNow ? 0.9 : 0.5))
                .lineLimit(1)
            Image(systemName: hour.condition.symbol(isDay: hour.isDay))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 15))
                .frame(height: 18)
            Text(WeatherPolicy.temperature(hour.temperature, fahrenheit: fahrenheit))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            // Only worth a glance when it's likely.
            Text(chanceText)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1))
        }
        .frame(width: 44)
        .padding(.vertical, 6)
        .background {
            if isNow {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07))
            }
        }
    }

    private var chanceText: String {
        guard let chance = hour.precipitationChance, chance >= 20 else { return " " }
        return "\(chance)%"
    }
}

private struct WeatherMessage: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.white.opacity(0.5))
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }
}

/// A cloud with rain, snow or a storm falling from it, for the rain heads-up.
///
/// The closed notch normally holds still; this runs only while the heads-up shows (a few
/// seconds), at 30 fps, and not at all with Reduce Motion, where it's the plain symbol.
struct FallingWeather: View {
    enum Kind: Equatable {
        case rain, snow, storm

        init(_ condition: WeatherCondition) {
            self = switch condition {
            case .snow, .heavySnow, .snowShowers: .snow
            case .thunderstorm, .hail: .storm
            default: .rain
            }
        }

        var cloud: String {
            self == .storm ? "cloud.bolt.fill" : "cloud.fill"
        }

        var stillSymbol: String {
            switch self {
            case .rain: "cloud.rain.fill"
            case .snow: "cloud.snow.fill"
            case .storm: "cloud.bolt.rain.fill"
            }
        }
    }

    let kind: Kind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let rainColor = Color(red: 0.45, green: 0.75, blue: 1)

    var body: some View {
        if reduceMotion {
            Image(systemName: kind.stillSymbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 13, weight: .semibold))
        } else {
            ZStack(alignment: .top) {
                TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                    Canvas { context, size in
                        let time = timeline.date.timeIntervalSinceReferenceDate
                        for drop in Self.drops(kind, at: time, in: size) {
                            let shape = kind == .snow
                                ? Path(ellipseIn: drop.rect)
                                : Path(roundedRect: drop.rect, cornerRadius: drop.rect.width / 2)
                            context.fill(
                                shape,
                                with: .color((kind == .snow ? Color.white : Self.rainColor).opacity(drop.opacity))
                            )
                        }
                    }
                }
                .frame(width: 16, height: 11)
                .padding(.top, 8)
                Image(systemName: kind.cloud)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(width: 18, height: 19)
            .accessibilityLabel(Text(kind == .snow ? "Snow" : "Rain"))
        }
    }

    struct Drop: Equatable {
        var rect: CGRect
        var opacity: Double
    }

    /// Where each drop is at `time`: drops fall in lanes on their own clocks, so the shower
    /// never pulses in step, and fade as they fall. Snow falls slower and drifts. Pure, so
    /// it's unit-tested.
    nonisolated static func drops(_ kind: Kind, at time: TimeInterval, in size: CGSize) -> [Drop] {
        let lanes: [(x: Double, offset: Double)] = [(0.15, 0), (0.4, 0.55), (0.65, 0.25), (0.88, 0.8), (0.28, 0.4)]
        let period = kind == .snow ? 1.8 : 0.6
        return lanes.enumerated().map { index, lane in
            let phase = (time / period + lane.offset).truncatingRemainder(dividingBy: 1)
            let progress = phase < 0 ? phase + 1 : phase
            let y = progress * size.height
            switch kind {
            case .snow:
                let drift = sin(time * 2.5 + Double(index)) * 1.2
                let x = lane.x * size.width + drift
                return Drop(rect: CGRect(x: x - 1.1, y: y - 1.1, width: 2.2, height: 2.2), opacity: 1 - progress * 0.6)
            case .rain, .storm:
                let x = lane.x * size.width - progress * 1.5 // a little slant
                return Drop(
                    rect: CGRect(x: x - 0.65, y: y - 3.5, width: 1.3, height: 3.5),
                    opacity: 1 - progress * progress
                )
            }
        }
    }
}
