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
    public private(set) var isRunning = false

    /// False when the adapter isn't bundled or keeps failing; the settings UI says so.
    /// Whether the closed-notch music bars should move (a user preference).
    public var animatesIndicator: Bool {
        settings.animatedMusicBars
    }

    public var isAvailable: Bool {
        guard let provider else { return false }
        return (provider as? MediaRemoteAdapterProvider)?.isAvailable ?? true
    }

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let provider: (any NowPlayingProviding)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var artworkSource: Data?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?

    /// Pixel size artwork is decoded at: enough for the 64 pt card on a Retina display.
    nonisolated static let artworkPixelSize = 160

    public init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        provider: (any NowPlayingProviding)?,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.engine = engine
        self.settings = settings
        self.provider = provider
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
        artworkSource = nil
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
            return
        }
        artworkTask = Task { [weak self] in
            let image = await Self.decodeArtwork(data)
            guard let self, !Task.isCancelled, artworkSource == data else { return }
            artwork = image
        }
    }

    /// Decodes and downsamples artwork in one ImageIO pass, off the main actor.
    @concurrent nonisolated static func decodeArtwork(_ data: Data) async -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: artworkPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
