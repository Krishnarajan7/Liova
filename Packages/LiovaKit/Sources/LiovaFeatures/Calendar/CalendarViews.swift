import LiovaPluginKit
import LiovaUI
import SwiftUI

extension CalendarColor {
    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}

/// The featured event when the notch is open: title, time and a Join button.
@MainActor
public final class CalendarRenderer: ActivityRenderer {
    private let feature: CalendarFeature

    public init(feature: CalendarFeature) {
        self.feature = feature
    }

    public func expanded(for _: Activity) -> AnyView? {
        guard let event = CalendarPolicy.featured(in: feature.events, now: .now) else { return nil }
        return AnyView(EventCard(event: event, feature: feature))
    }
}

private struct EventCard: View {
    let event: UpcomingEvent
    let feature: CalendarFeature

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.calendarColor.color)
                .frame(width: 4, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title.isEmpty ? "Untitled event" : event.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(timeText)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            if event.joinURL != nil {
                Button { feature.join(event) } label: {
                    Label("Join", systemImage: "video.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(.green, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var timeText: String {
        let formatter = CalendarPolicy.timeFormatter
        let range = "\(formatter.string(from: event.start)) – \(formatter.string(from: event.end))"
        let minutes = Int((event.start.timeIntervalSinceNow / 60).rounded(.up))
        return minutes > 0 ? "In \(minutes) min · \(range)" : "Now · \(range)"
    }
}

/// The Calendar page: today's remaining events.
public struct CalendarPage: View {
    let feature: CalendarFeature

    public init(feature: CalendarFeature) {
        self.feature = feature
    }

    public var body: some View {
        Group {
            switch feature.access {
            case .granted:
                let today = feature.events.filter { Calendar.current.isDateInToday($0.start) || $0.start < .now }
                if today.isEmpty {
                    Message(symbol: "calendar", text: "Nothing else on your calendar today.")
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 6) {
                            ForEach(today.prefix(8)) { EventRow(event: $0, feature: feature) }
                        }
                    }
                }
            case .denied:
                VStack(spacing: 6) {
                    Message(symbol: "calendar.badge.exclamationmark", text: "Liova can't see your calendars.")
                    Button("Open Privacy Settings") { feature.openPrivacySettings() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            case .needsPermission:
                VStack(spacing: 6) {
                    Message(symbol: "calendar", text: "Liova needs access to your calendars.")
                    Button("Allow Access…") { feature.requestAccess() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            case .off:
                Message(symbol: "calendar", text: "Turn on Calendar in Liova's Settings to see what's next.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
        .onAppear { feature.recheckAccess() }
    }
}

private struct EventRow: View {
    let event: UpcomingEvent
    let feature: CalendarFeature

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(event.calendarColor.color).frame(width: 7, height: 7)
            Text(event.isAllDay ? "All day" : CalendarPolicy.timeFormatter.string(from: event.start))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 58, alignment: .leading)
            Text(event.title.isEmpty ? "Untitled event" : event.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
            if event.joinURL != nil {
                Button("Join") { feature.join(event) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
            }
        }
    }
}

private struct Message: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.white.opacity(0.5))
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }
}
