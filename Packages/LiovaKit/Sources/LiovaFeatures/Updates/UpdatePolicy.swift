import Foundation
import LiovaPluginKit
import LiovaProviders

/// When Liova looks for a new version and which release it offers. Pure, so it's tested.
public enum UpdatePolicy {
    public static let source = "system.update"
    public static let activityID: ActivityID = "system.update.available"

    /// The first check waits until launch has settled and the network is likely up.
    static let firstCheckDelay: Duration = .seconds(60)
    /// After that, at most once a day. The loop wakes hourly to see if a day has passed,
    /// which also covers a Mac that slept through the due time.
    static let checkInterval: TimeInterval = 24 * 3600
    static let loopInterval: Duration = .seconds(3600)
    static let announcementDuration: TimeInterval = 6

    static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        // A clock set backwards makes the last check look like the future; check then too.
        return now.timeIntervalSince(lastCheck) >= checkInterval || lastCheck > now
    }

    /// The newest release above `current` that has an installer, pre-releases included
    /// only when asked for.
    static func newest(in releases: [ReleaseInfo], above current: AppVersion, includingBetas: Bool) -> ReleaseInfo? {
        releases
            .filter { $0.version > current && (includingBetas || !$0.isPrerelease) && $0.installer != nil }
            .max { $0.version < $1.version }
    }

    /// The closed notch says so once per version, unless the user skipped it.
    static func shouldAnnounce(_ release: ReleaseInfo, skipped: String?, alreadyAnnounced: AppVersion?) -> Bool {
        release.version.description != skipped && release.version != alreadyAnnounced
    }

    /// While an update downloads and gets checked: it stays until Liova quits or it fails.
    static func progressActivity(for release: ReleaseInfo, progress: Double?) -> Activity {
        Activity(
            id: activityID,
            source: source,
            priority: .normal,
            title: progress == nil ? "Checking Liova \(release.version)" : "Downloading Liova \(release.version)",
            subtitle: "Update",
            symbol: "arrow.down.circle.fill",
            progress: progress,
            tint: .blue
        )
    }

    static func announcement(for release: ReleaseInfo, now: Date) -> Activity {
        Activity(
            id: activityID,
            source: source,
            priority: .low,
            title: "Liova \(release.version) is available",
            subtitle: "Update",
            symbol: "arrow.down.circle.fill",
            tint: .blue,
            expiresAt: now + announcementDuration
        )
    }
}
