import AppKit
import EventKit
import Foundation
import LiovaCore
import Observation

/// Calendar "Next Up": the next meeting appears in the notch ten minutes before it starts,
/// with a Join button for video calls, and the Calendar page lists the rest of today.
///
/// Opt-in (it needs calendar access). Event-driven: it reloads when the calendar database
/// changes and otherwise sleeps until the next moment something changes.
@MainActor
@Observable
public final class CalendarFeature {
    public enum Access: Equatable, Sendable {
        case off
        case needsPermission
        case denied
        case granted
    }

    public private(set) var access: Access = .off
    /// Today's remaining events and the next day's, soonest first.
    public private(set) var events: [UpcomingEvent] = []

    public static let pageID = "calendar"

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var changeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?

    public init(engine: ActivityEngine, settings: LiovaSettings, now: @escaping @Sendable () -> Date = Date.init) {
        self.engine = engine
        self.settings = settings
        self.now = now
    }

    public func syncWithSettings() {
        guard settings.calendarEnabled else {
            stop()
            return
        }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            access = .granted
            startObserving()
        case .notDetermined:
            access = .needsPermission
            requestAccess()
        default:
            access = .denied
        }
    }

    public func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.access = granted ? .granted : .denied
                if granted {
                    self.startObserving()
                }
            }
        }
    }

    public func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    public func stop() {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        changeObserver = nil
        wakeTask?.cancel()
        wakeTask = nil
        events = []
        if access == .granted || access == .needsPermission {
            access = .off
        }
        engine.endAll(source: CalendarPolicy.source)
    }

    public func join(_ event: UpcomingEvent) {
        guard let url = event.joinURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Internals

    private func startObserving() {
        if changeObserver == nil {
            changeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: store, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        reload()
    }

    private func reload() {
        let date = now()
        let until = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date))
            .map { $0 + 6 * 3600 } ?? date + 86400 // through tomorrow morning
        let predicate = store.predicateForEvents(withStart: date - 3600, end: until, calendars: nil)
        events = store.events(matching: predicate)
            .filter { $0.status != .canceled && $0.endDate > date }
            .sorted { $0.startDate < $1.startDate }
            .map(Self.makeEvent)
        update()
    }

    func update() {
        let date = now()
        if let featured = CalendarPolicy.featured(in: events, now: date) {
            try? engine.start(CalendarPolicy.activity(for: featured, now: date))
        } else {
            engine.end(CalendarPolicy.activityID)
        }
        scheduleWake(after: date)
    }

    private func scheduleWake(after date: Date) {
        wakeTask?.cancel()
        guard let wake = CalendarPolicy.nextWake(events: events, now: date) else { return }
        let delay = max(0.5, wake.timeIntervalSince(date))
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    private static func makeEvent(_ event: EKEvent) -> UpcomingEvent {
        let color = event.calendar.color?.usingColorSpace(.sRGB)
        return UpcomingEvent(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendarColor: CalendarColor(
                red: color.map { Double($0.redComponent) } ?? 0.3,
                green: color.map { Double($0.greenComponent) } ?? 0.6,
                blue: color.map { Double($0.blueComponent) } ?? 1
            ),
            joinURL: CalendarPolicy.joinURL(url: event.url, location: event.location, notes: event.notes)
        )
    }
}
