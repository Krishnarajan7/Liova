import Foundation

/// Finds downloads through the file progress other apps publish (`NSProgress` with a file
/// URL), the same mechanism Finder uses to draw progress on a file's icon. Safari,
/// AirDrop and many browsers publish this way.
///
/// Event-driven: KVO on each published progress, coalesced to at most four updates a
/// second per download. Nothing runs when no one is downloading.
@MainActor
public final class FileProgressDownloadSource: DownloadSourcing {
    private let directory: URL
    private let now: @Sendable () -> Date
    private var hub: ProgressHub?
    private var items: [String: DownloadItem] = [:]
    private var onChange: (@MainActor ([DownloadItem]) -> Void)?

    public init(directory: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    /// Watches `~/Downloads`.
    public convenience init() {
        self.init(directory: DownloadLocations.downloadsDirectory())
    }

    public func start(onChange: @escaping @MainActor ([DownloadItem]) -> Void) {
        stop()
        self.onChange = onChange
        let hub = ProgressHub(directory: directory, now: now)
        let identity = ObjectIdentifier(hub)
        hub.start { [weak self] item in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let current = self.hub, ObjectIdentifier(current) == identity else { return }
                    self.receive(item)
                }
            }
        }
        self.hub = hub
    }

    public func stop() {
        hub?.stop()
        hub = nil
        items = [:]
        onChange = nil
    }

    private func receive(_ item: DownloadItem) {
        if item.isActive {
            guard items[item.id] != item else { return }
            items[item.id] = item
            deliver(extra: [])
        } else {
            guard items.removeValue(forKey: item.id) != nil else { return }
            deliver(extra: [item])
        }
    }

    private func deliver(extra: [DownloadItem]) {
        let active = items.values.sorted { ($0.startDate, $0.id) < ($1.startDate, $1.id) }
        onChange?(active + extra)
    }
}

/// Owns the progress subscription and one observation per published progress.
/// Thread-safe: the publishing handler runs on a queue Foundation picks.
final class ProgressHub: @unchecked Sendable {
    private let directory: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var subscriber: Any?
    private var observations: [String: ProgressObservation] = [:]
    private var nextID = 0

    init(directory: URL, now: @escaping @Sendable () -> Date) {
        self.directory = directory
        self.now = now
    }

    func start(emit: @escaping @Sendable (DownloadItem) -> Void) {
        let token = Progress.addSubscriber(forFileURL: directory) { [weak self] progress in
            guard let self else { return nil }
            let observation = register(progress, emit: emit)
            return { [weak self] in
                observation.unpublished()
                self?.remove(observation.id)
            }
        }
        lock.withLock { subscriber = token }
    }

    func stop() {
        let (token, live) = lock.withLock {
            let state = (subscriber, Array(observations.values))
            subscriber = nil
            observations = [:]
            return state
        }
        if let token {
            Progress.removeSubscriber(token)
        }
        for observation in live {
            observation.invalidate()
        }
    }

    private func register(
        _ progress: Progress,
        emit: @escaping @Sendable (DownloadItem) -> Void
    ) -> ProgressObservation {
        let observation = lock.withLock {
            nextID += 1
            let observation = ProgressObservation(
                id: "progress-\(nextID)",
                progress: progress,
                now: now,
                emit: emit
            )
            observations[observation.id] = observation
            return observation
        }
        observation.start()
        return observation
    }

    private func remove(_ id: String) {
        lock.withLock { observations[id] = nil }
    }
}

/// KVO on one published progress, coalesced to at most one delivery per `minimumInterval`.
final class ProgressObservation: @unchecked Sendable {
    static let minimumInterval: TimeInterval = 0.25
    /// Operations that are downloads. Copies, uploads and decompression aren't.
    static let downloadKinds: Set<Progress.FileOperationKind> = [.downloading, .receiving]

    let id: String
    private let progress: Progress
    private let now: @Sendable () -> Date
    private let emit: @Sendable (DownloadItem) -> Void
    private let startDate: Date
    private let lock = NSLock()
    private static let queue = DispatchQueue(label: "app.liova.downloads.progress", qos: .utility)

    // Guarded by `lock`.
    private var observers: [NSKeyValueObservation] = []
    private var flushScheduled = false
    private var lastFlush: Date?
    private var isDone = false
    private var estimator = ThroughputEstimator()
    private var hasEmitted = false

    init(
        id: String,
        progress: Progress,
        now: @escaping @Sendable () -> Date,
        emit: @escaping @Sendable (DownloadItem) -> Void
    ) {
        self.id = id
        self.progress = progress
        self.now = now
        self.emit = emit
        startDate = now()
    }

    func start() {
        let handler: @Sendable (Progress) -> Void = { [weak self] _ in self?.changed() }
        let created: [NSKeyValueObservation] = [
            progress.observe(\.fractionCompleted) { progress, _ in handler(progress) },
            progress.observe(\.completedUnitCount) { progress, _ in handler(progress) },
            progress.observe(\.totalUnitCount) { progress, _ in handler(progress) },
            progress.observe(\.userInfo) { progress, _ in handler(progress) },
            progress.observe(\.fileURL) { progress, _ in handler(progress) },
            progress.observe(\.isCancelled) { progress, _ in handler(progress) },
            progress.observe(\.isFinished) { progress, _ in handler(progress) },
        ]
        lock.withLock { observers = created }
        flush()
    }

    /// The publisher withdrew the progress: the download ended one way or another.
    func unpublished() {
        guard let item = lock.withLock({ () -> DownloadItem? in
            guard !isDone else { return nil }
            isDone = true
            invalidateLocked()
            return snapshotLocked(ending: true)
        }) else { return }
        emit(item)
    }

    func invalidate() {
        lock.withLock {
            isDone = true
            invalidateLocked()
        }
    }

    private func changed() {
        let delay: TimeInterval? = lock.withLock {
            guard !isDone, !flushScheduled else { return nil }
            flushScheduled = true
            let elapsed = lastFlush.map { now().timeIntervalSince($0) } ?? .infinity
            return max(0, Self.minimumInterval - elapsed)
        }
        guard let delay else { return }
        Self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flush() }
    }

    private func flush() {
        let item: DownloadItem? = lock.withLock {
            flushScheduled = false
            guard !isDone else { return nil }
            lastFlush = now()
            guard let item = snapshotLocked(ending: false) else { return nil }
            if !item.isActive {
                isDone = true
                invalidateLocked()
            }
            return item
        }
        if let item {
            emit(item)
        }
    }

    private func invalidateLocked() {
        for observer in observers {
            observer.invalidate()
        }
        observers = []
    }

    /// Reads the progress (thread-safe) into an item. `nil` when it isn't a download.
    private func snapshotLocked(ending: Bool) -> DownloadItem? {
        var forcedState: DownloadItem.State?
        let info = progress.userInfo
        let kind = progress.fileOperationKind
            ?? (info[.fileOperationKindKey] as? String).map(Progress.FileOperationKind.init(rawValue:))
        if let kind, !Self.downloadKinds.contains(kind) {
            // Not a download, or no longer one (Safari unzipping what it just downloaded).
            guard hasEmitted else { return nil }
            forcedState = kind == .decompressingAfterDownloading ? .finished : .failed
        }
        hasEmitted = true
        let date = now()
        let completed = max(0, progress.completedUnitCount)
        let total = progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
        estimator.add(bytes: completed, at: date)
        // A subscriber sees a proxy whose file URL and kind live in `userInfo`.
        let url = progress.fileURL ?? info[.fileURLKey] as? URL
        let name = url?.lastPathComponent ?? ""
        let finalName = PartialFileRules.finalName(forPartialName: name) ?? name
        let finalURL = url.map { $0.deletingLastPathComponent().appendingPathComponent(finalName) }
        let ext = url?.pathExtension.lowercased() ?? ""
        let sourceApp = kind == .receiving ? "AirDrop"
            : PartialFileRules.partialExtensions[ext] ?? nil

        let reachedTotal = total.map { completed >= $0 } ?? false
        let state: DownloadItem.State = if let forcedState {
            forcedState
        } else if progress.isCancelled {
            .failed
        } else if progress.isFinished || reachedTotal && ending {
            .finished
        } else if ending {
            // Withdrawn without finishing: it finished only if the final file is there
            // under a different name than the partial one.
            finalURL.map { $0 != url && FileMetadata.exists($0.path) } == true ? .finished : .failed
        } else {
            .active
        }
        let published = (info[.throughputKey] as? NSNumber)?.doubleValue
        let throughput = published.flatMap { $0 > 0 ? $0 : nil } ?? estimator.displayRate
        let remaining = (info[.estimatedTimeRemainingKey] as? NSNumber)?.doubleValue
            ?? throughput.flatMap { rate in total.map { Double(max(0, $0 - completed)) / rate } }
        return DownloadItem(
            id: id,
            displayName: finalName.isEmpty || PartialFileRules.isChromeUnconfirmed(finalName) ? "Download" : finalName,
            sourceApp: sourceApp,
            bytesCompleted: completed,
            totalBytes: total,
            throughput: state == .active ? throughput : nil,
            estimatedTimeRemaining: state == .active ? remaining : nil,
            state: state,
            startDate: startDate,
            lastChangeDate: date,
            finalURL: finalURL
        )
    }
}
