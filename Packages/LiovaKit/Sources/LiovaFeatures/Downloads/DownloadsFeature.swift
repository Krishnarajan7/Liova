import Foundation
import LiovaCore
import LiovaPluginKit
import LiovaProviders
import Observation

/// Shows active downloads (browsers, AirDrop, Telegram) in the notch.
///
/// Its own `@Observable` store: a download tick re-renders only the download views.
@MainActor
@Observable
public final class DownloadsFeature {
    /// Active downloads, oldest first.
    public private(set) var items: [DownloadItem] = []
    public private(set) var isRunning = false

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let settings: LiovaSettings
    /// Builds the source for a "Telegram included?" choice; the feature rebuilds it when
    /// that setting changes.
    @ObservationIgnored private let makeSource: @MainActor (Bool) -> any DownloadSourcing
    @ObservationIgnored private var source: (any DownloadSourcing)?
    @ObservationIgnored private var sourceIncludesTelegram: Bool?
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Persistent activities published last time, so ones no longer wanted can be ended.
    @ObservationIgnored private var shown: Set<ActivityID> = []

    public init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        source: any DownloadSourcing,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.engine = engine
        self.settings = settings
        makeSource = { _ in source }
        self.now = now
    }

    init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        makeSource: @escaping @MainActor (Bool) -> any DownloadSourcing,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.engine = engine
        self.settings = settings
        self.makeSource = makeSource
        self.now = now
    }

    /// Uses the real sources: published file progress in `~/Downloads`, and growing partial
    /// files in `~/Downloads` and Telegram's media folders.
    public convenience init(engine: ActivityEngine, settings: LiovaSettings) {
        self.init(engine: engine, settings: settings, makeSource: { includeTelegram in
            CompositeDownloadSource(includeTelegram: includeTelegram)
        })
    }

    /// Starts or stops the feature to match settings. Safe to call repeatedly; restarts when
    /// the Telegram choice changes.
    public func syncWithSettings() {
        guard settings.downloadsEnabled else {
            stop()
            return
        }
        if isRunning, sourceIncludesTelegram != settings.telegramDownloadsEnabled {
            stop()
        }
        start()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let includeTelegram = settings.telegramDownloadsEnabled
        let source = makeSource(includeTelegram)
        self.source = source
        sourceIncludesTelegram = includeTelegram
        source.start { [weak self] items in
            self?.receive(items)
        }
        Log.feature.info("Downloads started")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        source?.stop()
        source = nil
        sourceIncludesTelegram = nil
        if !items.isEmpty {
            items = []
        }
        shown = []
        engine.endAll(source: DownloadsPolicy.source)
        Log.feature.info("Downloads stopped")
    }

    /// The download an activity shows, for the renderer. `nil` for the combined and
    /// finished activities.
    public func item(for activityID: ActivityID) -> DownloadItem? {
        items.first { DownloadsPolicy.activityID(for: $0.id) == activityID }
    }

    func receive(_ new: [DownloadItem]) {
        guard isRunning else { return }
        let active = new.filter(\.isActive)
        if active != items {
            items = active
        }
        for action in DownloadsPolicy.actions(items: new, shown: shown, now: now()) {
            switch action {
            case let .start(activity):
                do {
                    try engine.start(activity)
                } catch {
                    Log.feature.error("Download activity rejected: \(String(describing: error), privacy: .public)")
                }
                if activity.id != DownloadsPolicy.finishedID {
                    shown.insert(activity.id)
                }
            case let .end(id):
                engine.end(id)
                shown.remove(id)
            }
        }
    }
}
