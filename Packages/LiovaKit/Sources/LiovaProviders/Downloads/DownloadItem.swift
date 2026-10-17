import Foundation

/// One download as Liova sees it: built from file-system metadata (names, sizes, dates)
/// and from the progress other apps publish. Never from a file's contents.
public struct DownloadItem: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case active
        case finished
        /// Cancelled, deleted, or stalled for too long. Ends quietly.
        case failed
    }

    /// Stable for the life of the download.
    public var id: String
    /// What to call it, e.g. `Movie.mkv` (never the partial name).
    public var displayName: String
    /// The app doing the download, when it can be told, e.g. "Safari" or "Telegram".
    public var sourceApp: String?
    public var bytesCompleted: Int64
    /// `nil` when the size isn't known (Telegram for macOS, some servers).
    public var totalBytes: Int64?
    /// Smoothed bytes per second.
    public var throughput: Double?
    public var estimatedTimeRemaining: TimeInterval?
    public var state: State
    public var startDate: Date
    public var lastChangeDate: Date
    /// Where the finished file is expected to land. Used to tell when two sources see
    /// the same download.
    public var finalURL: URL?

    public init(
        id: String,
        displayName: String,
        sourceApp: String? = nil,
        bytesCompleted: Int64,
        totalBytes: Int64? = nil,
        throughput: Double? = nil,
        estimatedTimeRemaining: TimeInterval? = nil,
        state: State = .active,
        startDate: Date,
        lastChangeDate: Date,
        finalURL: URL? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.sourceApp = sourceApp
        self.bytesCompleted = max(0, bytesCompleted)
        self.totalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }
        self.throughput = throughput.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.estimatedTimeRemaining = estimatedTimeRemaining.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.state = state
        self.startDate = startDate
        self.lastChangeDate = lastChangeDate
        self.finalURL = finalURL
    }

    /// Completed fraction in `0...1`, when the total is known.
    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(max(Double(bytesCompleted) / Double(totalBytes), 0), 1)
    }

    public var isActive: Bool {
        state == .active
    }

    /// Key for matching the same download seen by two sources: the expected final path.
    var matchKey: String? {
        finalURL?.standardizedFileURL.path
    }
}

/// A source of downloads. Behind a protocol so the feature is testable with a fake.
///
/// Every delivery is the full list of current downloads. An item that just finished or
/// failed is delivered once with its terminal state and is absent from later deliveries.
@MainActor
public protocol DownloadSourcing: AnyObject {
    func start(onChange: @escaping @MainActor ([DownloadItem]) -> Void)
    func stop()
}
