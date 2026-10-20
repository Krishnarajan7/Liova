import LiovaPluginKit
import LiovaProviders
import LiovaUI
import SwiftUI

/// The rain heads-up in the closed notch: the sky in color on the left, when on the right.
@MainActor
public final class WeatherRenderer: ActivityRenderer {
    private let feature: WeatherFeature

    public init(feature: WeatherFeature) {
        self.feature = feature
    }

    public func compactLeading(for activity: Activity) -> AnyView? {
        AnyView(
            Image(systemName: activity.symbol ?? "cloud.rain.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 13, weight: .semibold))
        )
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
