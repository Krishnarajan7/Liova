import Foundation

/// A crash, hang or other problem report about Liova that is on this Mac.
public struct ProblemReport: Equatable, Sendable {
    public let url: URL
    public let date: Date

    public init(url: URL, date: Date) {
        self.url = url
        self.date = date
    }
}

/// Finds the problem reports about Liova on this Mac, and keeps the ones MetricKit hands over.
///
/// Nothing here leaves the Mac. macOS writes a report to `~/Library/Logs/DiagnosticReports`
/// when any app crashes; MetricKit adds hangs and runaway CPU or disk use, which Liova saves
/// to `~/Library/Logs/Liova`. Settings → About shows them in Finder, to attach to an issue.
public struct ProblemReportStore: Sendable {
    /// Where macOS writes crash reports.
    let systemDirectory: URL
    /// Where Liova saves what MetricKit delivers.
    let ownDirectory: URL

    /// Reports older than this aren't listed: they are rarely about the installed version.
    static let recentWindow: TimeInterval = 30 * 24 * 3600
    /// The most saved reports kept; the oldest go first.
    static let maxSavedReports = 20
    static let reportExtensions: Set<String> = ["ips", "crash", "hang", "diag", "spin", "json"]

    public init(systemDirectory: URL? = nil, ownDirectory: URL? = nil) {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs", directoryHint: .isDirectory)
        self.systemDirectory = systemDirectory ?? logs.appending(path: "DiagnosticReports", directoryHint: .isDirectory)
        self.ownDirectory = ownDirectory ?? logs.appending(path: "Liova", directoryHint: .isDirectory)
    }

    /// Reports about Liova from the last 30 days, newest first.
    public func recent(now: Date = Date()) -> [ProblemReport] {
        (reports(in: systemDirectory) + reports(in: ownDirectory))
            .filter { now.timeIntervalSince($0.date) < Self.recentWindow }
            .sorted { $0.date > $1.date }
    }

    /// Saves a report MetricKit delivered, then drops the oldest saved ones past the limit.
    @discardableResult
    public func save(_ data: Data, kind: String, at date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: ownDirectory, withIntermediateDirectories: true)
        let stamp = date.formatted(.iso8601.dateSeparator(.dash).timeSeparator(.omitted))
        var url = ownDirectory.appending(path: "Liova-\(kind)-\(stamp).json")
        var copy = 1
        while FileManager.default.fileExists(atPath: url.path) {
            copy += 1
            url = ownDirectory.appending(path: "Liova-\(kind)-\(stamp)-\(copy).json")
        }
        try data.write(to: url, options: .atomic)
        // Dated when the problem happened, not when macOS got round to delivering it.
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        for old in reports(in: ownDirectory).sorted(by: { $0.date > $1.date }).dropFirst(Self.maxSavedReports) {
            try? FileManager.default.removeItem(at: old.url)
        }
        return url
    }

    /// Whether a file in a reports folder is about Liova (the app or the `liova` tool):
    /// macOS names them `Liova-2026-11-15-101502.ips`, `Liova_2026-11-15-101502_Mac.hang`.
    static func isLiovaReport(_ name: String) -> Bool {
        let lowered = name.lowercased()
        guard lowered.hasPrefix("liova-") || lowered.hasPrefix("liova_") else { return false }
        return reportExtensions.contains((lowered as NSString).pathExtension)
    }

    private func reports(in directory: URL) -> [ProblemReport] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        )) ?? []
        return files.compactMap { url in
            guard Self.isLiovaReport(url.lastPathComponent),
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return nil }
            return ProblemReport(url: url, date: date)
        }
    }
}
