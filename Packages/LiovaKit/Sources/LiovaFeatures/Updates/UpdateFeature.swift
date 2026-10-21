import AppKit
import Foundation
import LiovaCore
import LiovaProviders
import Observation

/// Keeps Liova up to date: looks for a new version once a day (and when asked), says so in
/// the closed notch once per version, and installs it in place on request.
///
/// In place means: download, check the checksum, check the new app is signed by the same
/// certificate as this one, then swap it in after Liova quits and reopen it. A copy that
/// can't do that (signed ad-hoc, or not in a writable folder) gets the checked installer
/// opened in Finder instead. See `UpdateInstaller` for the trust rules.
@MainActor
@Observable
public final class UpdateFeature {
    public enum Status: Equatable {
        /// Not looked yet since launch.
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        /// 0…1.
        case downloading(ReleaseInfo, progress: Double)
        /// Checking the download and getting it ready to swap in.
        case preparing(ReleaseInfo)
        /// About to quit so the helper can swap it in.
        case installing(ReleaseInfo)
        /// The installer is open in Finder for the user to drag into Applications.
        case openedInstaller(ReleaseInfo)
        case failed(ReleaseInfo?, message: String)

        public var release: ReleaseInfo? {
            switch self {
            case .idle, .checking, .upToDate: nil
            case let .available(release), let .downloading(release, _), let .preparing(release),
                 let .installing(release), let .openedInstaller(release): release
            case let .failed(release, _): release
            }
        }

        public var isBusy: Bool {
            switch self {
            case .checking, .downloading, .preparing, .installing: true
            default: false
            }
        }
    }

    public private(set) var status: Status = .idle
    /// How this copy will install updates; Settings explains anything but `.supported`.
    /// Worked out on first use: it reads the app's code signature.
    @ObservationIgnored public private(set) lazy var inPlaceSupport = installer.inPlaceSupport(for: appURL)
    public let currentVersion: AppVersion?

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let fetcher: any ReleaseFetching
    @ObservationIgnored private let installer: any UpdateInstalling
    @ObservationIgnored private let appURL: URL
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let quit: @MainActor () -> Void
    @ObservationIgnored private let openFile: @MainActor (URL) -> Void
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var workTask: Task<Void, Never>?
    @ObservationIgnored private var announced: AppVersion?

    public init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        fetcher: any ReleaseFetching = GitHubReleaseClient(),
        installer: any UpdateInstalling = UpdateInstaller(),
        appURL: URL = Bundle.main.bundleURL,
        currentVersion: AppVersion? = (Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(AppVersion.init),
        now: @escaping @Sendable () -> Date = Date.init,
        quit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
        openFile: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.engine = engine
        self.settings = settings
        self.fetcher = fetcher
        self.installer = installer
        self.appURL = appURL
        self.currentVersion = currentVersion
        self.now = now
        self.quit = quit
        self.openFile = openFile
    }

    /// The release on offer, if any.
    public var availableRelease: ReleaseInfo? {
        if case .upToDate = status {
            return nil
        }
        return status.release
    }

    public func syncWithSettings() {
        if settings.automaticUpdateChecks {
            guard loopTask == nil else { return }
            loopTask = Task { [weak self] in
                try? await Task.sleep(for: UpdatePolicy.firstCheckDelay, tolerance: .seconds(15))
                // Every launch looks once; after that, once a day.
                self?.check(isManual: false)
                while !Task.isCancelled {
                    try? await Task.sleep(for: UpdatePolicy.loopInterval, tolerance: .seconds(600))
                    guard let self, !Task.isCancelled else { return }
                    if UpdatePolicy.isDue(lastCheck: settings.lastUpdateCheck, now: now()) {
                        check(isManual: false)
                    }
                }
            }
        } else {
            loopTask?.cancel()
            loopTask = nil
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        workTask?.cancel()
        workTask = nil
        engine.endAll(source: UpdatePolicy.source)
    }

    /// Looks for a new version now ("Check for Updates…").
    public func checkNow() {
        check(isManual: true)
    }

    /// Don't offer this version again; a newer one still will be.
    public func skip() {
        guard let release = availableRelease else { return }
        settings.skippedUpdateVersion = release.version.description
        engine.end(UpdatePolicy.activityID)
        status = .upToDate
    }

    /// Downloads and installs the offered version (see the type's documentation).
    public func install() {
        guard let release = availableRelease, !status.isBusy else { return }
        status = .downloading(release, progress: 0)
        try? engine.start(UpdatePolicy.progressActivity(for: release, progress: 0))
        workTask = Task { [weak self] in await self?.runInstall(release) }
    }

    // MARK: - Internals

    func check(isManual: Bool) {
        guard !status.isBusy, let currentVersion else { return }
        // An offer already on screen stays put while looking again.
        let offered = availableRelease
        if offered == nil {
            status = .checking
        }
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let releases = try await fetcher.releases()
                guard !Task.isCancelled else { return }
                settings.lastUpdateCheck = now()
                let newest = UpdatePolicy.newest(
                    in: releases, above: currentVersion, includingBetas: settings.betaUpdates
                )
                // A manual check offers even a skipped version: the user asked.
                if let newest, isManual || newest.version.description != settings.skippedUpdateVersion {
                    status = .available(newest)
                    announce(newest)
                } else {
                    status = .upToDate
                }
            } catch {
                guard !Task.isCancelled else { return }
                if let offered {
                    status = .available(offered)
                } else {
                    // Automatic checks fail quietly (offline is normal); a manual one says so.
                    status = isManual ? .failed(nil, message: "Couldn't reach GitHub to check for updates.") : .idle
                }
                Log.feature.notice("Update check failed")
            }
        }
    }

    private func announce(_ release: ReleaseInfo) {
        guard UpdatePolicy.shouldAnnounce(release, skipped: settings.skippedUpdateVersion, alreadyAnnounced: announced)
        else { return }
        announced = release.version
        try? engine.start(UpdatePolicy.announcement(for: release, now: now()))
    }

    private func runInstall(_ release: ReleaseInfo) async {
        do {
            let downloaded = try await installer.download(release) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.status else { return }
                    self.status = .downloading(release, progress: fraction)
                    try? self.engine.update(UpdatePolicy.activityID) { $0.progress = fraction }
                }
            }
            guard !Task.isCancelled else { return }
            guard inPlaceSupport == .supported else {
                engine.end(UpdatePolicy.activityID)
                openFile(downloaded)
                status = .openedInstaller(release)
                return
            }
            status = .preparing(release)
            try? engine.start(UpdatePolicy.progressActivity(for: release, progress: nil))
            let staged = try await installer.prepare(installer: downloaded, release: release, replacing: appURL)
            guard !Task.isCancelled else { return }
            try installer.installAfterQuit(staged: staged, replacing: appURL)
            status = .installing(release)
            Log.feature.notice("Update \(release.version.description, privacy: .public) ready; quitting to install")
            quit()
        } catch {
            guard !Task.isCancelled else { return }
            engine.end(UpdatePolicy.activityID)
            status = .failed(release, message: error.message)
            Log.feature.error("Update failed: \(error.message, privacy: .public)")
        }
    }
}
