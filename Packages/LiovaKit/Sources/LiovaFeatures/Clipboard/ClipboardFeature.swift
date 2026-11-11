import Foundation
import LiovaCore
import LiovaProviders
import Observation

/// One thing in clipboard history.
public struct ClipboardItem: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var content: ClipboardContent
    public var sourceBundleID: String?
    public var copiedAt: Date
    public var isPinned = false
}

/// Clipboard history: what you copied lately, to copy again from the notch.
///
/// Kept in memory only, so it's gone when Liova quits, except what you pin. Passwords are
/// never kept (see `ClipboardRules`), and turning history off forgets it.
@MainActor
@Observable
public final class ClipboardFeature {
    /// Pinned first, then newest first.
    public private(set) var items: [ClipboardItem] = []
    /// The item just copied back, for a moment, so the page can say so.
    public private(set) var justCopied: ClipboardItem.ID?

    public static let pageID = "clipboard"
    /// Unpinned items kept; older ones fall off.
    static let maxItems = 30
    /// Images take the most memory, so fewer of them are kept.
    static let maxImages = 6

    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let watcher: any ClipboardWatching
    @ObservationIgnored private let store: ClipboardPinStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var copiedTask: Task<Void, Never>?

    public init(
        settings: LiovaSettings,
        watcher: any ClipboardWatching = SystemClipboardWatcher(),
        store: ClipboardPinStore = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.settings = settings
        self.watcher = watcher
        self.store = store
        self.now = now
        items = store.load()
    }

    public var isEnabled: Bool {
        settings.clipboardHistoryEnabled
    }

    public func syncWithSettings() {
        guard isEnabled else {
            stop()
            return
        }
        guard !isRunning else { return }
        isRunning = true
        watcher.start { [weak self] capture in self?.receive(capture) }
    }

    /// Stops watching and forgets everything not pinned.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        watcher.stop()
        items.removeAll { !$0.isPinned }
    }

    // MARK: - Actions

    /// Puts the item back on the clipboard, ready to paste, and moves it to the top.
    public func copy(_ item: ClipboardItem) {
        watcher.write(item.content)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].copiedAt = now()
            sort()
        }
        justCopied = item.id
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.justCopied = nil
        }
    }

    public func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
        sort()
        trim()
        savePins()
    }

    public func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        if item.isPinned {
            savePins()
        }
    }

    /// Clears history; pinned items stay.
    public func clear() {
        items.removeAll { !$0.isPinned }
    }

    // MARK: - Copies

    func receive(_ capture: ClipboardCapture) {
        if let index = items.firstIndex(where: { $0.content == capture.content }) {
            // Copied again: it moves up instead of showing twice.
            items[index].copiedAt = now()
            items[index].sourceBundleID = capture.sourceBundleID ?? items[index].sourceBundleID
        } else {
            items.append(ClipboardItem(
                id: UUID(),
                content: capture.content,
                sourceBundleID: capture.sourceBundleID,
                copiedAt: now()
            ))
        }
        sort()
        trim()
    }

    private func sort() {
        items.sort { lhs, rhs in
            lhs.isPinned != rhs.isPinned ? lhs.isPinned : lhs.copiedAt > rhs.copiedAt
        }
    }

    /// Drops the oldest unpinned items past the limits.
    private func trim() {
        var kept = 0
        var images = 0
        items.removeAll { item in
            guard !item.isPinned else { return false }
            kept += 1
            if case .image = item.content {
                images += 1
                if images > Self.maxImages {
                    return true
                }
            }
            return kept > Self.maxItems
        }
    }

    private func savePins() {
        do {
            try store.save(items.filter(\.isPinned))
        } catch {
            Log.feature.error("Clipboard pins couldn't be saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Pinned clipboard items, in Application Support. Nothing else is written to disk.
public struct ClipboardPinStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var standard: ClipboardPinStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ClipboardPinStore(fileURL: support.appendingPathComponent("Liova/clipboard-pins.json"))
    }

    public func load() -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ClipboardItem].self, from: data)) ?? []
    }

    public func save(_ items: [ClipboardItem]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Only the user can read it: pins can be anything they copied.
        try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
