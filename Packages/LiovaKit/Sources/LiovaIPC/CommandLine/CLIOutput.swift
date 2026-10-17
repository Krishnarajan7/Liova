import Foundation
import LiovaPluginKit

/// Pure formatting for the `liova` CLI's output.
public enum CLIOutput {
    /// Exit codes. Scripts can rely on these.
    public enum ExitCode: Int32, Sendable {
        case success = 0
        /// Liova answered with an error, or the exchange failed.
        case serverError = 1
        /// The command line was invalid.
        case usage = 2
        /// Liova isn't running.
        case serverNotRunning = 3
    }

    /// The response as pretty-printed JSON with sorted keys.
    public static func json(_ response: IPCResponse) -> String {
        let encoder = LiovaWire.makeEncoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        guard let data = try? encoder.encode(response), let text = String(data: data, encoding: .utf8) else {
            return #"{"ok":false}"#
        }
        return text
    }

    /// Human-readable success output for a command, or `nil` to print nothing.
    public static func text(for command: IPCCommand, response: IPCResponse, now: Date = Date()) -> String? {
        switch command {
        case .ping:
            "Liova is running (plugin API v\(response.serverVersion))."
        case .list:
            table(response.activities ?? [], now: now)
        case .start, .update, .end, .endAll, .agentEvent, .agentPermission:
            nil // Silence is success, so scripts can call these in tight loops.
        }
    }

    /// A fixed-width table of activities, in the order given.
    ///
    /// The server returns activities in **display order**: the first one is what the notch is
    /// showing (among equal priorities, the most recently started wins). The order is kept and
    /// the first row is marked with `*` in the leading column.
    public static func table(_ activities: [Activity], now: Date = Date()) -> String {
        guard !activities.isEmpty else { return "No live activities." }
        let header = [" ", "ID", "SOURCE", "PRIORITY", "PROGRESS", "EXPIRES", "TITLE"]
        let rows = activities.enumerated().map { index, activity in
            [
                index == 0 ? "*" : " ",
                activity.id.rawValue,
                activity.source,
                priorityName(activity.priority),
                activity.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "-",
                activity.expiresAt.map { remaining(until: $0, now: now) } ?? "-",
                activity.subtitle.map { "\(activity.title) - \($0)" } ?? activity.title,
            ]
        }
        let widths = header.indices.dropLast().map { column in
            ([header] + rows).map { $0[column].count }.max() ?? 0
        }
        return ([header] + rows).map { row in
            row.enumerated().map { column, cell in
                column < widths.count ? cell.padding(toLength: widths[column], withPad: " ", startingAt: 0) : cell
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    static func priorityName(_ priority: ActivityPriority) -> String {
        switch priority {
        case .low: "low"
        case .normal: "normal"
        case .high: "high"
        case .critical: "critical"
        default: String(priority.rawValue)
        }
    }

    static func remaining(until date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded(.up))
        switch seconds {
        case ..<1: return "now"
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m\(seconds % 60 == 0 ? "" : " \(seconds % 60)s")"
        default: return "\(seconds / 3600)h\(seconds % 3600 / 60 == 0 ? "" : " \(seconds % 3600 / 60)m")"
        }
    }
}
