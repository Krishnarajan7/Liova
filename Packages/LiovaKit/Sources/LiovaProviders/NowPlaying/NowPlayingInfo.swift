import Foundation

/// What is playing right now, in any app.
public struct NowPlayingInfo: Equatable, Sendable {
    /// The app playing the media, e.g. `com.spotify.client`.
    public var bundleIdentifier: String
    /// For web players: the browser hosting the page.
    public var parentBundleIdentifier: String?
    public var title: String
    public var artist: String?
    public var album: String?
    /// Track length in seconds, when known.
    public var duration: TimeInterval?
    /// Elapsed time in seconds, as of `timestamp`.
    public var elapsedTime: TimeInterval?
    /// When `elapsedTime` was sampled.
    public var timestamp: Date?
    /// 1 at normal speed, 0 when paused.
    public var playbackRate: Double
    public var isPlaying: Bool
    /// Encoded artwork image (JPEG or PNG), when the player provides one.
    public var artworkData: Data?

    public init(
        bundleIdentifier: String,
        parentBundleIdentifier: String? = nil,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil,
        elapsedTime: TimeInterval? = nil,
        timestamp: Date? = nil,
        playbackRate: Double = 1,
        isPlaying: Bool,
        artworkData: Data? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.parentBundleIdentifier = parentBundleIdentifier
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsedTime = elapsedTime
        self.timestamp = timestamp
        self.playbackRate = playbackRate
        self.isPlaying = isPlaying
        self.artworkData = artworkData
    }

    /// The elapsed time at `date`, extrapolated from the last sample while playing.
    /// Lets the UI show a moving scrubber without asking the player every second.
    public func elapsed(at date: Date) -> TimeInterval? {
        guard let elapsedTime else { return nil }
        var value = elapsedTime
        if isPlaying, let timestamp {
            value += max(0, date.timeIntervalSince(timestamp)) * (playbackRate > 0 ? playbackRate : 1)
        }
        if let duration, duration > 0 {
            value = min(value, duration)
        }
        return max(0, value)
    }

    /// The same track, ignoring position and artwork. Used to avoid needless updates.
    public func isSameTrack(as other: NowPlayingInfo) -> Bool {
        bundleIdentifier == other.bundleIdentifier && title == other.title
            && artist == other.artist && album == other.album
    }
}

/// Playback commands. Raw values are MediaRemote command IDs.
public enum NowPlayingCommand: Int, Sendable, CaseIterable {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
}

/// A source of Now Playing data. Behind a protocol so the implementation can change
/// (Apple may close today's route) without touching the feature or UI.
@MainActor
public protocol NowPlayingProviding: AnyObject {
    /// Starts delivering updates on the main actor. `nil` means nothing is playing.
    func start(onChange: @escaping @MainActor (NowPlayingInfo?) -> Void)
    func stop()
    func send(_ command: NowPlayingCommand)
    /// Seeks the current track to `seconds`.
    func seek(to seconds: TimeInterval)
}
