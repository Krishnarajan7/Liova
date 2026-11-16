import CoreServices
import Foundation

/// Finds downloads by watching partial files grow, for apps that don't publish progress
/// (Chrome and other Chromium browsers, Firefox, Opera, Telegram).
///
/// Event-driven: one FSEvents stream over the watched roots wakes it when something changes.
/// While at least one partial file is being tracked, a single coalesced 1 Hz timer samples
/// the sizes of those files only (for speed and stall detection); it stops when none are.
/// Only names and sizes are read, never a download's contents. The one file opened is the
/// small record Telegram keeps beside a download (`TelegramPartialMeta`).
@MainActor
public final class PartialFileDownloadSource: DownloadSourcing {
    public struct Root: Sendable, Equatable {
        public var path: String
        public var kind: PartialFileRules.RootKind

        public init(path: String, kind: PartialFileRules.RootKind) {
            self.path = path
            self.kind = kind
        }
    }

    public struct Configuration: Sendable {
        public var tracker: PartialDownloadTracker.Configuration
        /// FSEvents coalescing latency.
        public var latency: TimeInterval
        public var sampleInterval: TimeInterval
        public var sampleLeeway: TimeInterval

        public init(
            tracker: PartialDownloadTracker.Configuration = .init(),
            latency: TimeInterval = 0.75,
            sampleInterval: TimeInterval = 1,
            sampleLeeway: TimeInterval = 0.25
        ) {
            self.tracker = tracker
            self.latency = latency
            self.sampleInterval = sampleInterval
            self.sampleLeeway = sampleLeeway
        }
    }

    private let rootsProvider: @Sendable () -> [Root]
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private var monitor: PartialFileMonitor?
    private var onChange: (@MainActor ([DownloadItem]) -> Void)?

    /// Watches `roots` (resolved when `start()` is called, so folders created later count).
    public init(
        roots: @escaping @Sendable () -> [Root],
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        rootsProvider = roots
        self.configuration = configuration
        self.now = now
    }

    /// Watches `~/Downloads`, and Telegram for macOS' media folders when `includeTelegram`.
    public convenience init(includeTelegram: Bool = false) {
        self.init(roots: { DownloadLocations.partialFileRoots(includeTelegram: includeTelegram) })
    }

    /// Bumped on every start/stop so a slow root discovery can't start a stale monitor.
    private var generation = 0

    /// True once root discovery finished and the file-system watcher is running.
    var isMonitoring: Bool {
        monitor != nil
    }

    public func start(onChange: @escaping @MainActor ([DownloadItem]) -> Void) {
        stop()
        self.onChange = onChange
        generation += 1
        let current = generation
        let provider = rootsProvider
        // Discovering roots touches the file system and may wait on a privacy prompt;
        // never do that on the main thread.
        Task.detached(priority: .utility) { [weak self] in
            let roots = provider().compactMap { root -> Root? in
                guard let resolved = DownloadLocations.resolvedDirectory(root.path) else { return nil }
                return Root(path: resolved, kind: root.kind)
            }
            await self?.startMonitor(roots: roots, generation: current)
        }
    }

    private func startMonitor(roots: [Root], generation started: Int) {
        guard started == generation, onChange != nil, !roots.isEmpty else { return }
        let monitor = PartialFileMonitor(roots: roots, configuration: configuration, now: now)
        let identity = ObjectIdentifier(monitor)
        monitor.start { [weak self] items in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let current = self.monitor, ObjectIdentifier(current) == identity else { return }
                    self.onChange?(items)
                }
            }
        }
        self.monitor = monitor
    }

    public func stop() {
        generation += 1
        monitor?.stop()
        monitor = nil
        onChange = nil
    }
}

/// The FSEvents stream, the sampler and the tracker, all confined to one serial queue.
final class PartialFileMonitor: @unchecked Sendable {
    private let roots: [PartialFileDownloadSource.Root]
    private let configuration: PartialFileDownloadSource.Configuration
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "app.liova.downloads.partial-files", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()

    // Queue-confined state.
    private var stream: FSEventStreamRef?
    private var timer: (any DispatchSourceTimer)?
    private var tracker: PartialDownloadTracker
    private var lastDelivered: [DownloadItem] = []
    /// The last progress record read for each tracked path, and the record's stamp then.
    private var records: [String: (stamp: FileMetadata.Stamp, progress: TelegramPartialProgress)] = [:]
    private var emit: (@Sendable ([DownloadItem]) -> Void)?

    init(
        roots: [PartialFileDownloadSource.Root],
        configuration: PartialFileDownloadSource.Configuration,
        now: @escaping @Sendable () -> Date
    ) {
        self.roots = roots
        self.configuration = configuration
        self.now = now
        tracker = PartialDownloadTracker(configuration: configuration.tracker)
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        teardown()
    }

    func start(emit: @escaping @Sendable ([DownloadItem]) -> Void) {
        queue.sync {
            self.emit = emit
            createStream()
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            teardown()
        } else {
            queue.sync { teardown() }
        }
    }

    private func teardown() {
        emit = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        timer?.cancel()
        timer = nil
    }

    // MARK: - FSEvents

    private func createStream() {
        let box = Unmanaged.passRetained(WeakMonitor(self)).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: box,
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<WeakMonitor>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                guard let info else { return }
                Unmanaged<WeakMonitor>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info,
                  let monitor = Unmanaged<WeakMonitor>.fromOpaque(info).takeUnretainedValue().monitor,
                  let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]
            else { return }
            let events = (0 ..< min(count, list.count)).map { (list[$0], flags[$0]) }
            monitor.handle(events)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            roots.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            configuration.latency,
            flags
        )
        // The stream holds its own retain on the box now.
        Unmanaged<WeakMonitor>.fromOpaque(box).release()
        guard let created else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    /// Runs on `queue`.
    private func handle(_ events: [(String, FSEventStreamEventFlags)]) {
        guard emit != nil else { return }
        let rescanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
        )
        let arrivalFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCreated
        )
        let fileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        var touched: [String: PartialFileRules.Classification] = [:]
        var arrivals: [String] = []
        for (path, flag) in events {
            if flag & rescanFlags != 0 {
                for tracked in tracker.trackedPaths {
                    touched[tracked] = tracker.classification(for: tracked)
                }
                continue
            }
            guard let root = root(containing: path) else { continue }
            if let classification = PartialFileRules.classify(path: path, rootKind: root.kind) {
                touched[classification.trackedPath] = classification
            } else if flag & arrivalFlags != 0, flag & fileFlag != 0 {
                arrivals.append(path)
            }
        }
        let date = now()
        for (path, classification) in touched {
            refresh(path, classification, arrivals: arrivals, at: date)
        }
        finishPass(at: date)
    }

    private func root(containing path: String) -> PartialFileDownloadSource.Root? {
        roots.first { path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
    }

    // MARK: - Sampling

    private func sample() {
        let date = now()
        for path in tracker.trackedPaths {
            guard let classification = tracker.classification(for: path) else { continue }
            refresh(path, classification, arrivals: [], at: date)
        }
        finishPass(at: date)
    }

    private func refresh(
        _ path: String,
        _ classification: PartialFileRules.Classification,
        arrivals: [String],
        at date: Date
    ) {
        guard let size = FileMetadata.size(atPath: path, isBundle: classification.isBundle) else {
            if tracker.classification(for: path) != nil {
                tracker.vanished(path: path, finalPath: finalPath(for: classification, arrivals: arrivals), at: date)
            }
            return
        }
        guard let recordPath = classification.progressRecordPath else {
            tracker.observe(classification, size: size, at: date)
            return
        }
        // Telegram: the record says how much has arrived, and the partial file stays when
        // the download ends, so the final file appearing is what ends it. A finished one
        // that's only been touched is never tracked.
        let progress = progress(for: path, recordPath: recordPath)
        if classification.finalPath.map(FileMetadata.exists) == true || progress?.isComplete == true {
            tracker.vanished(path: path, finalPath: classification.finalPath, at: date)
            records[path] = nil
        } else {
            tracker.observe(classification, size: progress?.completed ?? size, total: progress?.total, at: date)
        }
    }

    /// The progress record for `path`, read again only when the record has changed. A record
    /// caught mid-write keeps the last good reading.
    private func progress(for path: String, recordPath: String) -> TelegramPartialProgress? {
        guard let stamp = FileMetadata.stamp(atPath: recordPath) else { return records[path]?.progress }
        if let known = records[path], known.stamp == stamp {
            return known.progress
        }
        guard let progress = TelegramPartialMeta.read(atPath: recordPath) else { return records[path]?.progress }
        records[path] = (stamp, progress)
        return progress
    }

    /// Where the finished file landed: the name without the partial suffix, or, if the app
    /// renamed it to something else (Chrome's "Unconfirmed 123.crdownload"), the one new
    /// file that arrived in the same folder in the same batch.
    private func finalPath(for classification: PartialFileRules.Classification, arrivals: [String]) -> String? {
        if let expected = classification.finalPath, FileMetadata.exists(expected) {
            return expected
        }
        let directory = (classification.trackedPath as NSString).deletingLastPathComponent
        let siblings = arrivals.filter {
            ($0 as NSString).deletingLastPathComponent == directory && FileMetadata.exists($0)
        }
        return siblings.count == 1 ? siblings[0] : nil
    }

    private func finishPass(at date: Date) {
        tracker.expireStalled(at: date)
        if !records.isEmpty {
            let tracked = Set(tracker.trackedPaths)
            records = records.filter { tracked.contains($0.key) }
        }
        updateTimer()
        let items = tracker.drain()
        guard items != lastDelivered else { return }
        lastDelivered = items
        emit?(items)
    }

    private func updateTimer() {
        if tracker.isEmpty {
            timer?.cancel()
            timer = nil
        } else if timer == nil {
            let source = DispatchSource.makeTimerSource(queue: queue)
            let interval = configuration.sampleInterval
            source.schedule(
                deadline: .now() + interval,
                repeating: interval,
                leeway: .milliseconds(Int(configuration.sampleLeeway * 1000))
            )
            source.setEventHandler { [weak self] in self?.sample() }
            source.resume()
            timer = source
        }
    }
}

/// Lets the FSEvents context hold the monitor without keeping it alive.
private final class WeakMonitor: @unchecked Sendable {
    weak var monitor: PartialFileMonitor?

    init(_ monitor: PartialFileMonitor) {
        self.monitor = monitor
    }
}
