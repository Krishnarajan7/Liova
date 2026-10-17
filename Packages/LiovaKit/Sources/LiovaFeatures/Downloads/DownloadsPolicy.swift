import Foundation
import LiovaPluginKit
import LiovaProviders

/// Turns the list of downloads into activities. Pure, so every rule is unit-tested.
///
/// - One `low`-priority activity per active download, updated in place. Low is the
///   ambient level (the same as music): anything the user is waiting on (timers, agent
///   prompts, HUDs) covers it, and it comes back when they end.
/// - More than `maxIndividual` at once collapse into one "N downloads" activity.
/// - A finished download flashes a brief `high` "Downloaded" activity; a failed, cancelled
///   or stalled one just ends.
/// - Values are rounded (progress to 1%) so the engine sees an identical activity, and
///   drops it, unless something visible changed.
public enum DownloadsPolicy {
    public enum Action: Equatable, Sendable {
        case start(Activity)
        case end(ActivityID)
    }

    public static let source = "system.downloads"
    public static let combinedID: ActivityID = "system.downloads.combined"
    public static let finishedID: ActivityID = "system.downloads.finished"
    public static let maxIndividual = 3
    public static let finishedDuration: TimeInterval = 4
    static let idPrefix = "system.downloads."
    static let maxIDLength = 64

    public static let activeSymbol = "arrow.down.circle"
    public static let finishedSymbol = "checkmark.circle.fill"

    /// Actions that move the engine from `shown` (the persistent activities published last
    /// time) to what `items` calls for.
    public static func actions(items: [DownloadItem], shown: Set<ActivityID>, now: Date) -> [Action] {
        let active = items.filter(\.isActive)
        var wanted: [Activity] = []
        if active.count > maxIndividual {
            wanted.append(combinedActivity(for: active))
        } else {
            wanted = active.map(activity(for:))
        }
        let wantedIDs = Set(wanted.map(\.id))
        var actions: [Action] = shown.subtracting(wantedIDs).sorted { $0.rawValue < $1.rawValue }.map(Action.end)
        actions += wanted.map(Action.start)

        let finished = items.filter { $0.state == .finished }
        if let flash = finishedActivity(for: finished, now: now) {
            actions.append(.start(flash))
        }
        return actions
    }

    /// The ID of a download's activity: `system.downloads.<sanitized id>`.
    public static func activityID(for itemID: String) -> ActivityID {
        ActivityID(idPrefix + sanitize(itemID))
    }

    /// Keeps letters, digits, `-` and `_`; everything else becomes `-`. Capped in length.
    static func sanitize(_ id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(id.map { allowed.contains($0) ? $0 : "-" })
        let capped = String(cleaned.prefix(maxIDLength))
        return capped.isEmpty ? "unknown" : capped
    }

    static func activity(for item: DownloadItem) -> Activity {
        Activity(
            id: activityID(for: item.id),
            source: source,
            priority: .low,
            title: item.displayName,
            subtitle: subtitle(
                completed: item.bytesCompleted,
                total: item.totalBytes,
                throughput: item.throughput,
                remaining: item.estimatedTimeRemaining
            ),
            symbol: activeSymbol,
            progress: roundedProgress(item.fractionCompleted),
            tint: .blue
        )
    }

    static func combinedActivity(for items: [DownloadItem]) -> Activity {
        let completed = items.reduce(Int64(0)) { $0 + $1.bytesCompleted }
        let totals = items.compactMap(\.totalBytes)
        let total: Int64? = totals.count == items.count ? totals.reduce(0, +) : nil
        let rates = items.compactMap(\.throughput)
        let rate: Double? = rates.isEmpty ? nil : rates.reduce(0, +)
        let remaining: TimeInterval? = if let total, let rate, rate > 0 {
            Double(max(0, total - completed)) / rate
        } else {
            nil
        }
        let fraction = total.flatMap { $0 > 0 ? Double(completed) / Double($0) : nil }
        return Activity(
            id: combinedID,
            source: source,
            priority: .low,
            title: "\(items.count) downloads",
            subtitle: subtitle(completed: completed, total: total, throughput: rate, remaining: remaining),
            symbol: activeSymbol,
            progress: roundedProgress(fraction),
            tint: .blue
        )
    }

    static func finishedActivity(for finished: [DownloadItem], now: Date) -> Activity? {
        guard let first = finished.first else { return nil }
        let single = finished.count == 1
        return Activity(
            id: finishedID,
            source: source,
            priority: .high,
            title: single ? first.displayName : "\(finished.count) downloads",
            subtitle: single ? "Downloaded · " + DownloadsFormat.bytes(first.totalBytes ?? first.bytesCompleted)
                : "Downloaded",
            symbol: finishedSymbol,
            progress: nil,
            tint: .green,
            expiresAt: now + finishedDuration
        )
    }

    /// `412 MB of 1.4 GB · 8.3 MB/s · 2 min left`, or `412 MB · 8.3 MB/s` with no total.
    public static func subtitle(
        completed: Int64,
        total: Int64?,
        throughput: Double?,
        remaining: TimeInterval?
    ) -> String {
        var parts: [String] = []
        if let total {
            parts.append("\(DownloadsFormat.bytes(completed)) of \(DownloadsFormat.bytes(total))")
        } else {
            parts.append(DownloadsFormat.bytes(completed))
        }
        if let throughput {
            parts.append(DownloadsFormat.speed(throughput))
        }
        if total != nil, let remaining, let text = DownloadsFormat.timeRemaining(remaining) {
            parts.append(text)
        }
        return parts.joined(separator: " · ")
    }

    /// Rounded to 1%, so sub-percent ticks don't republish.
    static func roundedProgress(_ fraction: Double?) -> Double? {
        fraction.map { ($0 * 100).rounded() / 100 }
    }
}

/// Text for sizes, speeds and durations.
public enum DownloadsFormat {
    /// `412 MB`, `1.4 GB` (decimal units, like Finder).
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file)
    }

    /// `8.3 MB/s`.
    public static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return bytes(0) + "/s" }
        return bytes(Int64(bytesPerSecond.rounded())) + "/s"
    }

    /// `8.3M/s`, `412K/s`, `12M/s`: for the closed notch's narrow ear.
    public static func compactSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1 else { return "0K/s" }
        return compact(bytesPerSecond) + "/s"
    }

    /// `412M`, `1.4G`: a size for the closed notch's narrow ear.
    public static func compactBytes(_ count: Int64) -> String {
        compact(Double(max(0, count)))
    }

    /// One decimal below 10, none above; decimal units like Finder. Always `.` as the separator.
    private static func compact(_ value: Double) -> String {
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "G"), (1e6, "M"), (1e3, "K")]
        for (scale, unit) in units where value >= scale * 0.9995 {
            let scaled = value / scale
            let text = scaled < 9.95 ? String(format: "%.1f", scaled) : String(format: "%.0f", scaled)
            return text + unit
        }
        return value < 1 ? "0K" : "<1K"
    }

    /// `45 s left`, `2 min left`, `1 hr 5 min left`. Seconds are rounded to 5 so the text
    /// doesn't change every tick; `nil` for nonsense values.
    public static func timeRemaining(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds >= 0, seconds < 7 * 24 * 3600 else { return nil }
        if seconds < 60 {
            return "\(min(55, max(5, Int((seconds / 5).rounded(.up)) * 5))) s left"
        }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 {
            return "\(minutes) min left"
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) hr left" : "\(hours) hr \(rest) min left"
    }
}
