import Foundation
import LiovaPluginKit
import LiovaProviders

/// Maps Now Playing state to the media activity. Pure, so it's unit-tested.
///
/// Media sits at low priority: anything else (a timer, a build, an agent asking for
/// approval) takes the notch, and music comes back when it's done. Paused media stays
/// for a while, then leaves on its own.
public enum NowPlayingPolicy {
    public static let source = "system.media"
    public static let activityID: ActivityID = "system.media"
    /// How long paused media stays in the notch.
    public static let pausedGrace: TimeInterval = 10 * 60

    public static func activity(for info: NowPlayingInfo?, previous: Activity?, now: Date) -> Activity? {
        guard let info else { return nil }
        let expiresAt: Date? = if info.isPlaying {
            nil
        } else if let previous, let kept = previous.expiresAt, previous.title == info.title {
            // Already paused: keep the original deadline so updates don't extend it forever.
            kept
        } else {
            now + pausedGrace
        }
        return Activity(
            id: activityID,
            source: source,
            priority: .low,
            title: info.title,
            subtitle: info.artist,
            symbol: info.isPlaying ? "music.note" : "pause.fill",
            tint: .pink,
            expiresAt: expiresAt
        )
    }

    /// "3:07", or "1:02:03" for long media.
    public static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
