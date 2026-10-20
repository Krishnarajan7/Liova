import AppKit
import Foundation
import LiovaCore
import LiovaProviders
import Observation

/// Weather in the open notch: now, the next hours, today's high and low, and a heads-up in
/// the closed notch when rain is about to start.
///
/// Opt-in: it asks Open-Meteo about a place. The place is a city the user picked, or the
/// Mac's approximate location, rounded to about a kilometre before it leaves the Mac.
/// Refreshes every half hour while on, and on wake or when the page opens if it's older
/// than ten minutes. Off, nothing runs and Location Services is never touched.
@MainActor
@Observable
public final class WeatherFeature {
    public enum Status: Equatable {
        case off
        case loading
        /// Waiting for the user to answer macOS's location prompt.
        case needsPermission
        /// Location access is off for Liova and no city is picked.
        case denied
        case ready
        /// Offline or the service didn't answer; any older report is still shown.
        case failed
    }

    public private(set) var status: Status = .off
    public private(set) var report: WeatherReport?
    /// The city picked, or the name of the place the Mac is in.
    public private(set) var placeName: String?
    /// The wet hour the last heads-up was about.
    public private(set) var announcedRain: WeatherReport.Hour?

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let fetcher: any WeatherFetching
    @ObservationIgnored private let makeLocation: @MainActor () -> any ApproximateLocating
    @ObservationIgnored private lazy var location: any ApproximateLocating = makeLocation()
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var lastPlace: WeatherPlace?
    @ObservationIgnored private var lastRainAnnounced: Date?

    public init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        fetcher: any WeatherFetching = OpenMeteoClient(),
        location: @escaping @MainActor () -> any ApproximateLocating = { CoreLocationApproximateLocation() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.engine = engine
        self.settings = settings
        self.fetcher = fetcher
        makeLocation = location
        self.now = now
    }

    public var usesFahrenheit: Bool {
        settings.temperatureUnit.usesFahrenheit()
    }

    public func syncWithSettings() {
        guard settings.weatherEnabled else {
            stop()
            return
        }
        if !settings.rainAlertsEnabled {
            engine.end(WeatherPolicy.rainID)
        }
        if !isRunning {
            isRunning = true
            lastPlace = settings.weatherPlace
            start()
        } else if settings.weatherPlace != lastPlace {
            // A different city (or back to the current location): start over there.
            lastPlace = settings.weatherPlace
            report = nil
            lastRainAnnounced = nil
            refresh()
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        fetchTask?.cancel()
        fetchTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        status = .off
        report = nil
        placeName = nil
        lastRainAnnounced = nil
        announcedRain = nil
        engine.endAll(source: WeatherPolicy.source)
    }

    /// Fetches again if what's shown is older than a few minutes; call when the page opens.
    public func refreshIfStale() {
        guard isRunning else { return }
        if let report, now().timeIntervalSince(report.fetchedAt) < WeatherPolicy.staleAfter {
            return
        }
        refresh()
    }

    /// Fetches now.
    public func refresh() {
        guard isRunning else { return }
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in await self?.load() }
    }

    /// Asks macOS for location access (when no city is picked).
    public func requestLocationAccess() {
        location.requestAuthorization { [weak self] answer in
            // Only a real answer; "not asked yet" would just ask again.
            if answer != .notDetermined {
                self?.refresh()
            }
        }
    }

    public func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Cities matching what the user typed, for Settings.
    public func places(named name: String) async -> [WeatherPlace] {
        let found = await (try? fetcher.places(named: name)) ?? []
        return found.map { WeatherPlace(name: $0.name, latitude: $0.latitude, longitude: $0.longitude) }
    }

    // MARK: - Internals

    private func start() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfStale() }
        }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: WeatherPolicy.refreshInterval, tolerance: .seconds(120))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
        refresh()
    }

    private func load() async {
        if report == nil {
            status = .loading
        }
        guard let coordinates = await coordinates() else { return }
        do {
            let fresh = try await fetcher.report(latitude: coordinates.latitude, longitude: coordinates.longitude)
            guard !Task.isCancelled, isRunning else { return }
            report = fresh
            status = .ready
            Log.feature.info("Weather: updated")
            announceRain(in: fresh)
        } catch {
            guard !Task.isCancelled, isRunning else { return }
            status = .failed
            Log.feature.notice("Weather: unavailable")
        }
    }

    /// The picked city, or the Mac's approximate location. Nil (with the status saying why)
    /// when there's neither.
    private func coordinates() async -> (latitude: Double, longitude: Double)? {
        if let place = settings.weatherPlace {
            placeName = place.name.components(separatedBy: ", ").first ?? place.name
            return (place.latitude, place.longitude)
        }
        switch location.authorization {
        case .notDetermined:
            status = .needsPermission
            requestLocationAccess()
            return nil
        case .denied:
            status = .denied
            return nil
        case .authorized:
            do {
                let here = try await location.currentLocation()
                if let name = here.name {
                    placeName = name
                }
                return (here.latitude, here.longitude)
            } catch {
                if !Task.isCancelled {
                    status = report == nil ? .failed : status
                }
                return nil
            }
        }
    }

    private func announceRain(in report: WeatherReport) {
        guard settings.rainAlertsEnabled,
              let hour = WeatherPolicy.rainSoon(in: report, now: now(), lastAnnounced: lastRainAnnounced)
        else { return }
        lastRainAnnounced = hour.time
        announcedRain = hour
        try? engine.start(WeatherPolicy.rainActivity(for: hour, timeZone: report.timeZone, now: now()))
    }
}
