import Foundation

/// The state machine behind partial-file detection, separate from FSEvents so every rule
/// is unit-tested. Feed it sizes (metadata only) and it decides what is a download.
///
/// - A partial file becomes a visible download once it has grown, is at least
///   `minimumSize`, and was first seen at least `minimumAge` ago. Anything that finishes
///   sooner was never shown and is dropped quietly.
/// - It finishes when the partial file disappears and the final file exists.
/// - It fails (quietly) when it disappears without a final file, or stops growing for
///   `stallTimeout`.
public struct PartialDownloadTracker: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var minimumSize: Int64
        public var minimumAge: TimeInterval
        public var stallTimeout: TimeInterval
        public var smoothingTimeConstant: TimeInterval

        public init(
            minimumSize: Int64 = 1_000_000,
            minimumAge: TimeInterval = 2,
            stallTimeout: TimeInterval = 60,
            smoothingTimeConstant: TimeInterval = 3
        ) {
            self.minimumSize = minimumSize
            self.minimumAge = minimumAge
            self.stallTimeout = stallTimeout
            self.smoothingTimeConstant = smoothingTimeConstant
        }
    }

    struct Entry: Sendable {
        let id: String
        let classification: PartialFileRules.Classification
        let firstSeen: Date
        var lastGrowth: Date
        var size: Int64
        var hasGrown = false
        var isConfirmed = false
        var estimator: ThroughputEstimator
    }

    public let configuration: Configuration
    private var entries: [String: Entry] = [:]
    private var terminal: [DownloadItem] = []

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Paths being watched, confirmed or not. The sampler runs only while this isn't empty.
    public var trackedPaths: [String] {
        Array(entries.keys)
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public func classification(for path: String) -> PartialFileRules.Classification? {
        entries[path]?.classification
    }

    /// Records the current size of a partial file.
    public mutating func observe(_ classification: PartialFileRules.Classification, size: Int64, at date: Date) {
        let path = classification.trackedPath
        guard var entry = entries[path] else {
            var estimator = ThroughputEstimator(timeConstant: configuration.smoothingTimeConstant)
            estimator.add(bytes: size, at: date)
            entries[path] = Entry(
                id: Self.stableID(for: path),
                classification: classification,
                firstSeen: date,
                lastGrowth: date,
                size: size,
                estimator: estimator
            )
            return
        }
        if size != entry.size {
            // Growth, or a restart (smaller): either way it's alive.
            if size > entry.size {
                entry.hasGrown = true
            }
            entry.lastGrowth = date
            entry.size = size
        }
        entry.estimator.add(bytes: size, at: date)
        if !entry.isConfirmed,
           entry.hasGrown,
           entry.size >= configuration.minimumSize,
           date.timeIntervalSince(entry.firstSeen) >= configuration.minimumAge
        {
            entry.isConfirmed = true
        }
        entries[path] = entry
    }

    /// The partial file is gone. `finalPath` is where the finished file now exists, if it does.
    public mutating func vanished(path: String, finalPath: String?, at date: Date) {
        guard let entry = entries.removeValue(forKey: path), entry.isConfirmed else { return }
        var item = item(for: entry)
        item.lastChangeDate = date
        item.throughput = nil
        item.estimatedTimeRemaining = nil
        if let finalPath {
            item.state = .finished
            item.finalURL = URL(fileURLWithPath: finalPath)
            if entry.classification.finalNameIsMeaningful {
                item.displayName = (finalPath as NSString).lastPathComponent
            }
        } else {
            item.state = .failed
        }
        terminal.append(item)
    }

    /// Drops downloads that haven't grown for `stallTimeout`.
    public mutating func expireStalled(at date: Date) {
        for (path, entry) in entries where date.timeIntervalSince(entry.lastGrowth) >= configuration.stallTimeout {
            entries[path] = nil
            if entry.isConfirmed {
                var item = item(for: entry)
                item.state = .failed
                item.lastChangeDate = date
                terminal.append(item)
            }
        }
    }

    /// Visible downloads, oldest first, plus each that just ended (delivered exactly once).
    public mutating func drain() -> [DownloadItem] {
        let active = entries.values
            .filter(\.isConfirmed)
            .sorted { ($0.firstSeen, $0.id) < ($1.firstSeen, $1.id) }
            .map(item(for:))
        let ended = terminal
        terminal = []
        return active + ended
    }

    private func item(for entry: Entry) -> DownloadItem {
        DownloadItem(
            id: entry.id,
            displayName: entry.classification.displayName,
            sourceApp: entry.classification.sourceApp,
            bytesCompleted: entry.size,
            throughput: entry.estimator.displayRate,
            startDate: entry.firstSeen,
            lastChangeDate: entry.lastGrowth,
            finalURL: entry.classification.finalPath.map { URL(fileURLWithPath: $0) }
        )
    }

    /// A short ID that's the same for the same path (FNV-1a; `hashValue` is seeded per run).
    static func stableID(for path: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return "partial-" + String(hash, radix: 16)
    }
}
