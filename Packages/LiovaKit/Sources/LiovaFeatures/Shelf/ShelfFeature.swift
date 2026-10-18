import AppKit
import Foundation
import LiovaCore
import Observation

/// The File Shelf: drop files on the notch to keep them handy, drag them out anywhere,
/// AirDrop them in one click. Items are references, not copies, and survive restarts.
@MainActor
@Observable
public final class ShelfFeature {
    public private(set) var items: [ShelfItem] = []

    public static let pageID = "shelf"
    public static let maxItems = 40

    @ObservationIgnored private let store: ShelfStore
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(store: ShelfStore = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
        items = store.load()
    }

    /// Adds files (newest first), skipping ones already on the Shelf. Returns how many were added.
    @discardableResult
    public func add(_ urls: [URL]) -> Int {
        let existing = Set(items.compactMap { ShelfBookmarks.resolve($0)?.url.standardizedFileURL.path })
        var added: [ShelfItem] = []
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            guard !existing.contains(path), !added.contains(where: { $0.lastKnownPath == path }),
                  let bookmark = ShelfBookmarks.make(for: url)
            else { continue }
            added.append(ShelfItem(bookmark: bookmark, lastKnownPath: path, addedAt: now()))
        }
        guard !added.isEmpty else { return 0 }
        items = Array((added.reversed() + items).prefix(Self.maxItems))
        persist()
        Log.feature.info("Shelf: added \(added.count) item(s)")
        return added.count
    }

    public func remove(_ id: ShelfItem.ID) {
        items.removeAll { $0.id == id }
        persist()
    }

    public func clear() {
        items.removeAll()
        persist()
    }

    /// The file's current location, updating the stored bookmark if the file moved.
    public func url(for item: ShelfItem) -> URL? {
        guard let resolved = ShelfBookmarks.resolve(item) else { return nil }
        if let refreshed = resolved.refreshed, let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].bookmark = refreshed
            items[index].lastKnownPath = resolved.url.path
            persist()
        }
        return resolved.url
    }

    public func open(_ item: ShelfItem) {
        guard let url = url(for: item) else { return }
        NSWorkspace.shared.open(url)
    }

    public func revealInFinder(_ item: ShelfItem) {
        guard let url = url(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens the AirDrop picker for the given items (all items when empty).
    public func airDrop(_ selection: [ShelfItem] = []) {
        let urls = (selection.isEmpty ? items : selection).compactMap(url(for:))
        airDrop(urls: urls)
    }

    public func airDrop(urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate()
        if service.canPerform(withItems: urls) {
            service.perform(withItems: urls)
        }
    }

    private func persist() {
        do {
            try store.save(items)
        } catch {
            Log.feature.error("Shelf couldn't be saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
