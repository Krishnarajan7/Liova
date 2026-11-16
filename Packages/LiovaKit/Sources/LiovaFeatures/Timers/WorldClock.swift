import Foundation
import LiovaCore
import SwiftUI

/// One city on the world clock, ready to draw.
public struct WorldClockEntry: Identifiable, Equatable, Sendable {
    /// The time zone identifier ("Asia/Tokyo").
    public let id: String
    public let city: String
    /// The time there, in the user's own format ("9:41 PM" or "21:41").
    public let time: String
    /// Which day it is there and how far from here: "Tomorrow · +9h".
    public let detail: String
    public let isNight: Bool
}

/// What the world clock says about a city. Pure, so it's unit-tested.
public enum WorldClockPolicy {
    /// As many cities as fit in one row of the Timers page.
    public static let maxCities = 4

    public static func city(for zoneID: String) -> String {
        (zoneID.split(separator: "/").last.map(String.init) ?? zoneID).replacingOccurrences(of: "_", with: " ")
    }

    public static func entry(
        zoneID: String, now: Date, local: TimeZone = .current, locale: Locale = .current
    ) -> WorldClockEntry? {
        guard let zone = TimeZone(identifier: zoneID) else { return nil }
        let time = now.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: zone))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let hour = calendar.component(.hour, from: now)
        let day = dayName(dayOffset(of: zone, from: local, at: now))
        let offset = offsetText(seconds: zone.secondsFromGMT(for: now) - local.secondsFromGMT(for: now))
        return WorldClockEntry(
            id: zoneID,
            city: city(for: zoneID),
            time: time,
            detail: offset.isEmpty ? day : "\(day) · \(offset)",
            isNight: hour < 6 || hour >= 18
        )
    }

    /// The first `maxCities` cities that exist, in the user's order, without repeats.
    public static func entries(
        zoneIDs: [String], now: Date, local: TimeZone = .current, locale: Locale = .current
    ) -> [WorldClockEntry] {
        var seen: Set<String> = []
        return zoneIDs
            .filter { seen.insert($0).inserted }
            .compactMap { entry(zoneID: $0, now: now, local: local, locale: locale) }
            .prefix(maxCities)
            .map(\.self)
    }

    /// "+9h", "-5:30", or nothing when the city keeps the same time as here. Short, so it
    /// fits a tile beside "Tomorrow".
    static func offsetText(seconds: Int) -> String {
        guard seconds != 0 else { return "" }
        let minutes = abs(seconds) / 60
        let sign = seconds > 0 ? "+" : "-"
        return minutes % 60 == 0
            ? "\(sign)\(minutes / 60)h"
            : "\(sign)\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }

    /// How many calendar days the city is ahead of here (-1, 0 or 1).
    static func dayOffset(of zone: TimeZone, from local: TimeZone, at now: Date) -> Int {
        // The calendar date in each place, compared as dates in one shared time zone.
        var shared = Calendar(identifier: .gregorian)
        shared.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        func day(in zone: TimeZone) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return shared.date(from: calendar.dateComponents([.year, .month, .day], from: now)) ?? now
        }
        return shared.dateComponents([.day], from: day(in: local), to: day(in: zone)).day ?? 0
    }

    static func dayName(_ offset: Int) -> String {
        offset > 0 ? "Tomorrow" : offset < 0 ? "Yesterday" : "Today"
    }

    /// Every city macOS knows, grouped by region, for the picker in Settings.
    public static func regions() -> [(name: String, zoneIDs: [String])] {
        let grouped = Dictionary(grouping: TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") }) {
            String($0.split(separator: "/")[0])
        }
        return grouped.keys.sorted().map { region in
            (region, (grouped[region] ?? []).sorted { city(for: $0) < city(for: $1) })
        }
    }
}

/// The world clock on the Timers page: one tile per city. It redraws once a minute, and
/// only while the page is on screen.
struct WorldClockStrip: View {
    let zoneIDs: [String]

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 6) {
                ForEach(WorldClockPolicy.entries(zoneIDs: zoneIDs, now: context.date)) { entry in
                    WorldClockTile(entry: entry)
                }
            }
        }
    }
}

private struct WorldClockTile: View {
    let entry: WorldClockEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: entry.isNight ? "moon.fill" : "sun.max.fill")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(entry.isNight ? Color.indigo.opacity(0.9) : Color.orange)
                Text(entry.city)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Text(entry.time)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(entry.detail)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(entry.city), \(entry.time), \(entry.detail)"))
    }
}
