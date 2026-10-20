import Foundation
import LiovaCore
import LiovaProviders
import Observation

/// Synced lyrics for what's playing, line by line, in the open notch.
///
/// Off until the user turns it on: it's the one feature that asks the internet (lrclib.net)
/// about the song. Lookups wait a moment after a track change, so skipping through a playlist
/// doesn't fire a request per song, and every answer is cached.
///
/// Line changes are scheduled for the moment the next line starts, not polled, and only
/// while lyrics are on screen; seeking, pausing or changing speed reschedules.
@MainActor
@Observable
public final class LyricsFeature {
    public enum Status: Equatable {
        case off
        /// No lookup for this track (nothing playing, no artist, or not song-length).
        case idle
        case loading
        case synced(SyncedLyrics)
        /// Looked up; there are no synced lyrics for this song.
        case unavailable
    }

    public private(set) var status: Status = .off
    /// The line being sung, as of the last update.
    public private(set) var lineIndex: Int?

    public var isEnabled: Bool {
        settings.lyricsEnabled
    }

    public var lyrics: SyncedLyrics? {
        if case let .synced(lyrics) = status {
            lyrics
        } else {
            nil
        }
    }

    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let fetcher: any LyricsFetching
    @ObservationIgnored private let cache: LyricsCache
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var info: NowPlayingInfo?
    @ObservationIgnored private var query: LyricsQuery?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var lineTask: Task<Void, Never>?
    @ObservationIgnored private var viewers = 0

    /// Wait this long after a track change before asking.
    static let lookupDelay: Duration = .milliseconds(700)
    /// Show a line this much before it's sung, so it's readable as the singer starts.
    static let lead: TimeInterval = 0.2
    static let songLength: ClosedRange<TimeInterval> = 30 ... 20 * 60

    public init(
        settings: LiovaSettings,
        fetcher: any LyricsFetching = LRCLibClient(),
        cache: LyricsCache = LyricsCache(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.settings = settings
        self.fetcher = fetcher
        self.cache = cache
        self.now = now
    }

    /// Call with every Now Playing change.
    public func update(_ info: NowPlayingInfo?) {
        self.info = info
        guard settings.lyricsEnabled else {
            clear(to: .off)
            return
        }
        let newQuery = info.flatMap(Self.query(for:))
        // Coming from off, settle the status even when there's nothing to look up.
        if newQuery != query || status == .off {
            query = newQuery
            lineIndex = nil
            if let newQuery {
                lookUp(newQuery)
            } else {
                fetchTask?.cancel()
                status = .idle
            }
        }
        reschedule()
    }

    public func setEnabled(_ enabled: Bool) {
        settings.lyricsEnabled = enabled
        syncWithSettings()
    }

    public func syncWithSettings() {
        if settings.lyricsEnabled {
            if status == .off {
                query = nil
                update(info)
            }
        } else {
            clear(to: .off)
        }
    }

    /// Call when a view showing lyrics appears; balance with `viewerLeft()`.
    public func viewerAppeared() {
        viewers += 1
        reschedule()
    }

    public func viewerLeft() {
        viewers = max(0, viewers - 1)
        if viewers == 0 {
            lineTask?.cancel()
            lineTask = nil
        }
    }

    /// What to look up, or nil when this isn't something with lyrics.
    static func query(for info: NowPlayingInfo) -> LyricsQuery? {
        guard let artist = info.artist, !artist.isEmpty, !info.title.isEmpty,
              let duration = info.duration, songLength.contains(duration),
              !podcastApps.contains(info.bundleIdentifier)
        else { return nil }
        return LyricsQuery(title: info.title, artist: artist, album: info.album, duration: duration)
    }

    static let podcastApps: Set<String> = ["com.apple.podcasts", "fm.overcast.overcast", "com.pocketcasts.mac"]

    // MARK: - Lookup

    private func lookUp(_ query: LyricsQuery) {
        fetchTask?.cancel()
        status = .loading
        let fetcher = fetcher
        let cache = cache
        fetchTask = Task { [weak self] in
            if let cached = await cache.result(for: query) {
                self?.finish(cached, for: query)
                return
            }
            try? await Task.sleep(for: Self.lookupDelay)
            guard !Task.isCancelled else { return }
            do {
                let result = try await fetcher.lyrics(for: query)
                await cache.store(result, for: query)
                self?.finish(result, for: query)
            } catch {
                // Offline or lrclib unreachable: say so for this track, remember nothing.
                guard !Task.isCancelled else { return }
                self?.finish(.notFound, for: query)
            }
        }
    }

    private func finish(_ result: LyricsResult, for query: LyricsQuery) {
        guard query == self.query, settings.lyricsEnabled else { return }
        if case let .synced(lyrics) = result {
            status = .synced(lyrics)
            Log.feature.info("Lyrics: synced, \(lyrics.lines.count) lines")
        } else {
            status = .unavailable
            Log.feature.info("Lyrics: none for this song")
        }
        reschedule()
    }

    private func clear(to newStatus: Status) {
        fetchTask?.cancel()
        lineTask?.cancel()
        lineTask = nil
        query = nil
        lineIndex = nil
        if status != newStatus {
            status = newStatus
        }
    }

    // MARK: - Lines

    private func reschedule() {
        lineTask?.cancel()
        lineTask = nil
        guard let lyrics, let info, let elapsed = info.elapsed(at: now()) else {
            if lineIndex != nil {
                lineIndex = nil
            }
            return
        }
        let position = elapsed + Self.lead
        let index = lyrics.lineIndex(at: position)
        if index != lineIndex {
            lineIndex = index
        }
        guard viewers > 0, info.isPlaying, let next = lyrics.nextLineTime(after: position) else { return }
        let rate = info.playbackRate > 0 ? info.playbackRate : 1
        let wait = max(0.05, (next - position) / rate)
        lineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait), tolerance: .milliseconds(30))
            guard !Task.isCancelled else { return }
            self?.reschedule()
        }
    }
}
