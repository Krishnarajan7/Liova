import Foundation

/// Recognizes in-progress downloads by name alone. Pure: no file-system access.
public enum PartialFileRules {
    /// What a watched directory holds, which decides what counts as a download inside it.
    public enum RootKind: Sendable, Equatable {
        /// `~/Downloads` and its subfolders: browser partial files.
        case downloads
        /// Telegram for macOS' media cache: only `*/postbox/media/*_partial`.
        case telegramMedia
    }

    /// A path recognized as a download in progress.
    public struct Classification: Sendable, Equatable {
        /// The path whose size grows: the partial file, or the `.download` bundle.
        public var trackedPath: String
        public var displayName: String
        public var sourceApp: String?
        /// Where the finished file is expected, when the name tells us.
        public var finalPath: String?
        /// True for a Safari `.download` bundle (a directory), measured as the sum of its files.
        public var isBundle: Bool
        /// False when the finished file's name is an opaque cache key (Telegram), so the
        /// display name is kept when it finishes.
        public var finalNameIsMeaningful: Bool

        public init(
            trackedPath: String,
            displayName: String,
            sourceApp: String?,
            finalPath: String?,
            isBundle: Bool = false,
            finalNameIsMeaningful: Bool = true
        ) {
            self.trackedPath = trackedPath
            self.displayName = displayName
            self.sourceApp = sourceApp
            self.finalPath = finalPath
            self.isBundle = isBundle
            self.finalNameIsMeaningful = finalNameIsMeaningful
        }
    }

    /// Extensions browsers give a file while it downloads, mapped to the app when it's
    /// unambiguous (`.crdownload` is shared by every Chromium browser, `.part` by several).
    static let partialExtensions: [String: String?] = [
        "crdownload": nil, // Chrome, Edge, Brave, Arc, Vivaldi
        "part": nil, // Firefox and others
        "partial": nil,
        "download": "Safari",
        "opdownload": "Opera",
    ]

    static let telegramSuffix = "_partial"
    static let telegramMediaMarker = "/postbox/media/"
    static let telegramDesktopFolder = "/Telegram Desktop/"
    /// Chrome's name for a download before the server has told it the real one.
    static let chromeUnconfirmedPrefix = "Unconfirmed "

    /// The name a partial file will have when it finishes: `Movie.mkv.crdownload` → `Movie.mkv`.
    /// `nil` when the name isn't a partial-download name.
    public static func finalName(forPartialName name: String) -> String? {
        guard !name.hasPrefix(".") else { return nil }
        if name.hasSuffix(telegramSuffix) {
            let stem = String(name.dropLast(telegramSuffix.count))
            return stem.isEmpty ? nil : stem
        }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...].lowercased()
        guard partialExtensions.keys.contains(ext) else { return nil }
        let stem = String(name[..<dot])
        return stem.isEmpty || stem.hasSuffix(".") ? nil : stem
    }

    /// Classifies a path reported under a root of `kind`. Returns `nil` for anything that
    /// isn't a download in progress, so callers can ignore it without touching the disk.
    public static func classify(path: String, rootKind: RootKind) -> Classification? {
        switch rootKind {
        case .downloads: classifyDownloads(path)
        case .telegramMedia: classifyTelegram(path)
        }
    }

    private static func classifyDownloads(_ path: String) -> Classification? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        // Inside a Safari bundle (`Movie.mkv.download/Movie.mkv`): the bundle is the download.
        if let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".download") }),
           index < components.count - 1
        {
            let bundle = "/" + components[...index].joined(separator: "/")
            return classifyDownloads(bundle)
        }
        guard let name = components.last.map(String.init), let final = finalName(forPartialName: name) else {
            return nil
        }
        let ext = (name as NSString).pathExtension.lowercased()
        let directory = (path as NSString).deletingLastPathComponent
        var sourceApp = partialExtensions[ext] ?? nil
        if path.contains(telegramDesktopFolder) {
            sourceApp = "Telegram"
        }
        let unconfirmed = isChromeUnconfirmed(final)
        return Classification(
            trackedPath: path,
            displayName: unconfirmed ? "Download" : final,
            sourceApp: sourceApp,
            finalPath: unconfirmed ? nil : (directory as NSString).appendingPathComponent(final),
            isBundle: ext == "download"
        )
    }

    private static func classifyTelegram(_ path: String) -> Classification? {
        let name = (path as NSString).lastPathComponent
        guard path.contains(telegramMediaMarker),
              name.hasSuffix(telegramSuffix),
              name.count > telegramSuffix.count,
              !name.hasPrefix(".")
        else { return nil }
        return Classification(
            trackedPath: path,
            // Telegram's cache names (`telegram-cloud-document-…`) say nothing useful.
            displayName: "Telegram download",
            sourceApp: "Telegram",
            finalPath: String(path.dropLast(telegramSuffix.count)),
            finalNameIsMeaningful: false
        )
    }

    /// `Unconfirmed 123456` → true.
    static func isChromeUnconfirmed(_ name: String) -> Bool {
        guard name.hasPrefix(chromeUnconfirmedPrefix) else { return false }
        let rest = name.dropFirst(chromeUnconfirmedPrefix.count)
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }
}

/// Bytes-per-second with exponential smoothing that accounts for uneven sample spacing,
/// so a late timer tick doesn't distort the speed. Pure.
public struct ThroughputEstimator: Sendable, Equatable {
    /// Seconds for an old sample's weight to fall to 1/e.
    public var timeConstant: TimeInterval
    /// Samples closer together than this are merged into the next one.
    public var minimumInterval: TimeInterval
    public private(set) var bytesPerSecond: Double?
    private var lastBytes: Int64?
    private var lastDate: Date?

    public init(timeConstant: TimeInterval = 3, minimumInterval: TimeInterval = 0.2) {
        self.timeConstant = max(timeConstant, 0.01)
        self.minimumInterval = minimumInterval
    }

    public mutating func add(bytes: Int64, at date: Date) {
        guard let lastBytes, let lastDate else {
            reset(bytes: bytes, at: date)
            return
        }
        let elapsed = date.timeIntervalSince(lastDate)
        guard elapsed >= minimumInterval else { return }
        guard bytes >= lastBytes else {
            // The file shrank: the download restarted.
            reset(bytes: bytes, at: date)
            bytesPerSecond = nil
            return
        }
        let instant = Double(bytes - lastBytes) / elapsed
        let alpha = 1 - exp(-elapsed / timeConstant)
        bytesPerSecond = bytesPerSecond.map { $0 + alpha * (instant - $0) } ?? instant
        self.lastBytes = bytes
        self.lastDate = date
    }

    /// The speed worth showing: `nil` before two samples, or once it has decayed below 1 KB/s.
    public var displayRate: Double? {
        guard let bytesPerSecond, bytesPerSecond >= 1000 else { return nil }
        return bytesPerSecond
    }

    /// Seconds left at the current speed, when the total is known.
    public func timeRemaining(completed: Int64, total: Int64?) -> TimeInterval? {
        guard let total, total > completed, let rate = displayRate else { return nil }
        return Double(total - completed) / rate
    }

    private mutating func reset(bytes: Int64, at date: Date) {
        lastBytes = bytes
        lastDate = date
    }
}
