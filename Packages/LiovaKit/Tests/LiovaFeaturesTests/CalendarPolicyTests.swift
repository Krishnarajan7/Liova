import EventKit
import Foundation
@testable import LiovaFeatures
import Testing

private let now = Date(timeIntervalSince1970: 4_000_000)

private func event(
    _ id: String,
    startsIn minutes: Double,
    length: Double = 30,
    allDay: Bool = false,
    join: Bool = false
) -> UpcomingEvent {
    UpcomingEvent(
        id: id, title: id, start: now + minutes * 60, end: now + (minutes + length) * 60, isAllDay: allDay,
        joinURL: join ? URL(string: "https://meet.google.com/abc-defg-hij") : nil
    )
}

struct CalendarPolicyTests {
    @Test func featuresOnlyWithinTheLeadTime() {
        #expect(CalendarPolicy.featured(in: [event("later", startsIn: 30)], now: now) == nil)
        #expect(CalendarPolicy.featured(in: [event("soon", startsIn: 8)], now: now)?.id == "soon")
    }

    @Test func staysBrieflyAfterStartingThenLeaves() {
        #expect(CalendarPolicy.featured(in: [event("started", startsIn: -3)], now: now)?.id == "started")
        #expect(CalendarPolicy.featured(in: [event("old", startsIn: -10)], now: now) == nil)
    }

    @Test func allDayEventsNeverFeature() {
        #expect(CalendarPolicy.featured(in: [event("holiday", startsIn: 5, allDay: true)], now: now) == nil)
    }

    @Test func soonestWins() {
        let featured = CalendarPolicy.featured(in: [event("b", startsIn: 9), event("a", startsIn: 4)], now: now)
        #expect(featured?.id == "a")
    }

    @Test func activityTextCountsDownThenShowsNow() {
        let upcoming = CalendarPolicy.activity(for: event("Standup", startsIn: 7.5, join: true), now: now)
        #expect(upcoming.subtitle == "in 8 min · Join available")
        #expect(upcoming.priority == .normal)
        let started = CalendarPolicy.activity(for: event("Standup", startsIn: -1), now: now)
        #expect(started.subtitle?.hasPrefix("Now · until") == true)
        #expect(started.priority == .high)
    }

    @Test func wakesAtTheNextMeaningfulMoment() throws {
        // 30 min away: next wake is when it enters the lead time.
        let wake = try #require(CalendarPolicy.nextWake(events: [event("x", startsIn: 30)], now: now))
        #expect(wake == now + 20 * 60)
        // Inside the lead window: wakes within a minute to update "in N min".
        let inside = try #require(CalendarPolicy.nextWake(events: [event("y", startsIn: 5.25)], now: now))
        #expect(inside.timeIntervalSince(now) <= 61)
    }

    @Test(arguments: [
        ("https://us02web.zoom.us/j/123456?pwd=abc", true),
        ("Join: https://meet.google.com/abc-defg-hij", true),
        ("https://teams.microsoft.com/l/meetup-join/xyz", true),
        ("Room 4B, 2nd floor", false),
        ("https://example.com/agenda", false),
    ])
    func findsMeetingLinks(text: String, found: Bool) {
        #expect((CalendarPolicy.joinURL(url: nil, location: text, notes: nil) != nil) == found)
    }
}

struct CalendarAccessTests {
    @Test func onlyFullAccessReadsEvents() {
        #expect(CalendarFeature.access(for: .fullAccess) == .granted)
        // Not asked yet (or macOS couldn't ask): Liova can still ask, so it offers to.
        #expect(CalendarFeature.access(for: .notDetermined) == .needsPermission)
        #expect(CalendarFeature.access(for: .writeOnly) == .denied)
        #expect(CalendarFeature.access(for: .denied) == .denied)
        #expect(CalendarFeature.access(for: .restricted) == .denied)
    }

    @Test func theAppIsEntitledToAskForCalendars() throws {
        // Under the hardened runtime, a missing entitlement makes macOS refuse without asking.
        // This file is generated from project.yml (`entitlements.properties`); CI checks the signed app too.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../../App/Liova.entitlements")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let entitlements = try #require(plist as? [String: Any])
        #expect(entitlements["com.apple.security.personal-information.calendars"] as? Bool == true)
        #expect(entitlements["com.apple.security.personal-information.location"] as? Bool == true)
    }
}
