import AppKit
import Foundation
import ImageIO
import LiovaCore
import LiovaPluginKit
import LiovaProviders
import Observation

/// Shows what's playing in any app, with artwork and controls.
///
/// Its own `@Observable` store: a track change re-renders only the media views.
@MainActor
@Observable
public final class NowPlayingFeature {
    public private(set) var info: NowPlayingInfo?
    /// Downsampled artwork, decoded off the main thread.
    public private(set) var artwork: NSImage?
    /// The art's most vivid colour, for the closed notch's music wave; `nil` without colour.
    public private(set) var artworkTint: NSColor?
    public private(set) var isRunning = false

    /// False when the adapter isn't bundled or keeps failing; the settings UI says so.
    /// When the closed-notch music bars should move (a user preference).
    public var musicBars: MusicBarsMode {
        settings.musicBars
    }

    /// Repeat for the player, wherever it comes from: what the player reports to macOS, or,
    /// for players that don't (Spotify), what its AppleScript says. Nil means no repeat button.
    public var repeatMode: RepeatMode? {
        guard let info else { return nil }
        if let reported = info.repeatMode {
            return reported
        }
        guard scripting?.supports(info.bundleIdentifier) == true else { return nil }
        return scriptedRepeat ?? .off
    }

    /// Repeat read from the player's AppleScript (on or off only).
    private(set) var scriptedRepeat: RepeatMode?

    /// Whether gestures in the player give a trackpad tick (a user preference).
    public var hapticsEnabled: Bool {
        settings.hapticsEnabled
    }

    public var isAvailable: Bool {
        guard let provider else { return false }
        return (provider as? MediaRemoteAdapterProvider)?.isAvailable ?? true
    }

    /// Told about every change (lyrics follow the track and its position this way).
    @ObservationIgnored public var onInfoChange: (@MainActor (NowPlayingInfo?) -> Void)?
    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let provider: (any NowPlayingProviding)?
    @ObservationIgnored private let scripting: (any AppRepeatScripting)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var artworkSource: Data?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?

    /// Pixel size artwork is decoded at: enough for the 64 pt card on a Retina display.
    nonisolated static let artworkPixelSize = 160

    public init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        provider: (any NowPlayingProviding)?,
        scripting: (any AppRepeatScripting)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.engine = engine
        self.settings = settings
        self.provider = provider
        self.scripting = scripting
        self.now = now
    }

    public func syncWithSettings() {
        if settings.nowPlayingEnabled {
            start()
        } else {
            stop()
        }
    }

    public func start() {
        guard !isRunning, let provider else { return }
        isRunning = true
        provider.start { [weak self] info in
            self?.receive(info)
        }
        Log.feature.info("Now Playing started")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        provider?.stop()
        artworkTask?.cancel()
        info = nil
        artwork = nil
        artworkTint = nil
        artworkSource = nil
        onInfoChange?(nil)
        engine.endAll(source: NowPlayingPolicy.source)
        Log.feature.info("Now Playing stopped")
    }

    // MARK: - Commands

    public func togglePlayPause() {
        guard var current = info else { return }
        // Optimistic: flip now, the stream confirms a moment later.
        current.elapsedTime = current.elapsed(at: now())
        current.timestamp = now()
        current.isPlaying.toggle()
        current.playbackRate = current.isPlaying ? 1 : 0
        apply(current)
        provider?.send(.togglePlayPause)
    }

    public func nextTrack() {
        provider?.send(.nextTrack)
    }

    public func previousTrack() {
        provider?.send(.previousTrack)
    }

    /// Steps repeat on, as in Music: off, all, one, off. Players scripted instead (Spotify)
    /// only go on and off.
    public func cycleRepeat() {
        guard var current = info else { return }
        if let mode = current.repeatMode {
            // Optimistic, like play/pause: the stream confirms a moment later.
            current.repeatMode = mode.next
            apply(current)
            provider?.setRepeat(mode.next)
            return
        }
        guard let scripting, scripting.supports(current.bundleIdentifier) else { return }
        let target: RepeatMode = repeatMode == .off ? .all : .off
        let bundle = current.bundleIdentifier
        scriptedRepeat = target
        Task { [weak self] in
            // The first time, macOS asks the user to let Liova control the player.
            let took = await scripting.setRepeating(target != .off, in: bundle)
            guard let self, info?.bundleIdentifier == bundle else { return }
            if !took {
                Log.feature.notice("Repeat: \(bundle, privacy: .public) can't be scripted (not allowed?)")
                await refreshScriptedRepeat()
            }
        }
    }

    /// Reads a scripted player's repeat, never asking for permission. Call when the player
    /// card appears or the track changes, so a change made in the player itself shows.
    public func refreshScriptedRepeat() async {
        guard let info, let scripting, scripting.supports(info.bundleIdentifier) else {
            scriptedRepeat = nil
            return
        }
        let bundle = info.bundleIdentifier
        let isOn = await scripting.repeating(in: bundle)
        guard self.info?.bundleIdentifier == bundle else { return }
        scriptedRepeat = isOn.map { $0 ? .all : .off }
    }

    /// Seeks to a fraction (0…1) of the current track.
    public func seek(toFraction fraction: Double) {
        guard var current = info, let duration = current.duration, fraction.isFinite else { return }
        let seconds = min(max(fraction, 0), 1) * duration
        current.elapsedTime = seconds
        current.timestamp = now()
        apply(current)
        provider?.seek(to: seconds)
    }

    // MARK: - Updates

    func receive(_ new: NowPlayingInfo?) {
        apply(new)
    }

    private func apply(_ new: NowPlayingInfo?) {
        if info != new {
            info = new
        }
        updateArtwork(for: new)
        onInfoChange?(new)

        let previous = engine.activity(NowPlayingPolicy.activityID)
        guard let activity = NowPlayingPolicy.activity(for: new, previous: previous, now: now()) else {
            engine.end(NowPlayingPolicy.activityID)
            return
        }
        do {
            try engine.start(activity)
        } catch {
            Log.feature.error("Media activity rejected: \(String(describing: error), privacy: .public)")
        }
    }

    private func updateArtwork(for info: NowPlayingInfo?) {
        let data = info?.artworkData
        guard data != artworkSource else { return }
        artworkSource = data
        artworkTask?.cancel()
        guard let data else {
            artwork = nil
            artworkTint = nil
            return
        }
        artworkTask = Task { [weak self] in
            let decoded = await Self.decodeArtwork(data)
            guard let self, !Task.isCancelled, artworkSource == data else { return }
            artwork = decoded?.image
            artworkTint = decoded?.tint
        }
    }

    /// Decodes and downsamples artwork in one ImageIO pass, and picks its tint, off the main actor.
    @concurrent nonisolated static func decodeArtwork(_ data: Data) async -> (image: NSImage, tint: NSColor?)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: artworkPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let artwork = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        return (artwork, ArtworkTint.color(of: image))
    }
}
