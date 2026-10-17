import Foundation

/// Merges a primary source (published progress, which knows totals and speed) with a
/// fallback (growing partial files). When both see the same download, the primary wins.
@MainActor
public final class CompositeDownloadSource: DownloadSourcing {
    private let primary: any DownloadSourcing
    private let fallback: any DownloadSourcing
    private var primaryItems: [DownloadItem] = []
    private var fallbackItems: [DownloadItem] = []
    /// Final paths of downloads the primary ended recently, so the fallback's view of the
    /// same file finishing doesn't flash a second time.
    private var recentlyEnded: [String: Date] = [:]
    /// How long an ended primary download keeps hiding the fallback's copy.
    static let endedMemory: TimeInterval = 15
    private let now: @Sendable () -> Date
    private var onChange: (@MainActor ([DownloadItem]) -> Void)?

    public init(
        primary: any DownloadSourcing,
        fallback: any DownloadSourcing,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.primary = primary
        self.fallback = fallback
        self.now = now
    }

    /// Published file progress first, growing partial files second.
    public convenience init(includeTelegram: Bool = false) {
        self.init(
            primary: FileProgressDownloadSource(),
            fallback: PartialFileDownloadSource(includeTelegram: includeTelegram)
        )
    }

    public func start(onChange: @escaping @MainActor ([DownloadItem]) -> Void) {
        stop()
        self.onChange = onChange
        primary.start { [weak self] items in self?.receivePrimary(items) }
        fallback.start { [weak self] items in self?.receiveFallback(items) }
    }

    public func stop() {
        primary.stop()
        fallback.stop()
        primaryItems = []
        fallbackItems = []
        recentlyEnded = [:]
        onChange = nil
    }

    private func receivePrimary(_ items: [DownloadItem]) {
        let date = now()
        recentlyEnded = recentlyEnded.filter { date.timeIntervalSince($0.value) < Self.endedMemory }
        for item in items where !item.isActive {
            if let key = item.matchKey {
                recentlyEnded[key] = date
            }
        }
        primaryItems = items.filter(\.isActive)
        onChange?(items + deduplicated(fallbackItems))
    }

    private func receiveFallback(_ items: [DownloadItem]) {
        fallbackItems = items.filter(\.isActive)
        onChange?(primaryItems + deduplicated(items))
    }

    private func deduplicated(_ items: [DownloadItem]) -> [DownloadItem] {
        let date = now()
        let hidden = Set(primaryItems.compactMap(\.matchKey))
        return items.filter { item in
            guard let key = item.matchKey else { return true }
            if hidden.contains(key) {
                return false
            }
            guard let ended = recentlyEnded[key] else { return true }
            return date.timeIntervalSince(ended) >= Self.endedMemory
        }
    }
}
