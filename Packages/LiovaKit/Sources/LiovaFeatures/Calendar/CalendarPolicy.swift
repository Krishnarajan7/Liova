import Foundation
import LiovaPluginKit

/// A calendar event, reduced to what the notch needs.
public struct UpcomingEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendarColor: CalendarColor
    /// A video-call link found in the event's URL, location or notes.
    public var joinURL: URL?

    public init(
        id: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
        calendarColor: CalendarColor = CalendarColor(red: 0.3, green: 0.6, blue: 1), joinURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarColor = calendarColor
        self.joinURL = joinURL
    }
}

public struct CalendarColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Decides when an event belongs in the notch and how it reads. Pure, so it's unit-tested.
public enum CalendarPolicy {
    public static let source = "system.calendar"
    public static let activityID: ActivityID = "system.calendar.next"
    /// How early an upcoming event appears.
    public static let leadTime: TimeInterval = 10 * 60
    /// How long a started event stays.
    public static let stayAfterStart: TimeInterval = 5 * 60

    /// The event to show now: the soonest timed event starting within the lead time, or one
    /// that started in the last few minutes.
    public static func featured(in events: [UpcomingEvent], now: Date) -> UpcomingEvent? {
        events
            .filter { !$0.isAllDay && $0.start - leadTime <= now && now < min($0.end, $0.start + stayAfterStart) }
            .min { $0.start < $1.start }
    }

    public static func activity(for event: UpcomingEvent, now: Date) -> Activity {
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
        let when = minutes > 0 ? "in \(minutes) min" : "Now · until \(timeFormatter.string(from: event.end))"
        return Activity(
            id: activityID, source: source, priority: minutes > 0 ? .normal : .high,
            title: event.title.isEmpty ? "Untitled event" : event.title,
            subtitle: event.joinURL == nil ? when : "\(when) · Join available",
            symbol: event.joinURL == nil ? "calendar" : "video.fill",
            tint: .red,
            expiresAt: min(event.end, event.start + stayAfterStart)
        )
    }

    /// The next moments the featured event or its text changes: lead-time starts, minute
    /// ticks inside the lead window, starts and ends. The feature sleeps until the earliest.
    public static func nextWake(events: [UpcomingEvent], now: Date) -> Date? {
        var candidates: [Date] = []
        for event in events where !event.isAllDay {
            candidates += [event.start - leadTime, event.start, min(event.end, event.start + stayAfterStart)]
        }
        if let featured = featured(in: events, now: now), featured.start > now {
            // Inside the lead window the "in N min" text changes each minute.
            let untilStart = featured.start.timeIntervalSince(now)
            candidates.append(now + (untilStart.truncatingRemainder(dividingBy: 60) + 0.5))
        }
        return candidates.filter { $0 > now }.min()
    }

    /// Finds a Zoom, Google Meet, Teams, Webex or FaceTime link.
    public static func joinURL(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isMeetingLink(url.absoluteString) {
            return url
        }
        for text in [location, notes].compactMap(\.self) {
            if let match = text.firstMatch(of: meetingPattern) {
                return URL(string: String(text[match.range]))
            }
        }
        return nil
    }

    private static func isMeetingLink(_ string: String) -> Bool {
        string.firstMatch(of: meetingPattern) != nil
    }

    static let meetingHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com",
    ]
    nonisolated(unsafe) static let meetingPattern: Regex<AnyRegexOutput> = {
        let hosts = meetingHosts.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // The pattern is built from constants above, so it always compiles.
        // swiftlint:disable:next force_try
        return try! Regex(#"https://(?:[\w-]+\.)?(?:"# + hosts + #")/[^\s<>"]+"#)
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
