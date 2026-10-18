import Foundation
@testable import LiovaFeatures
import Testing

@MainActor
struct ShelfTests {
    let directory: URL
    let store: ShelfStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("liova-shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ShelfStore(fileURL: directory.appendingPathComponent("state/shelf.json"))
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    @Test func addsNewestFirstAndSkipsDuplicates() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = ShelfFeature(store: store)
        let first = try makeFile("a.txt")
        let second = try makeFile("b.txt")
        #expect(shelf.add([first]) == 1)
        #expect(shelf.add([second, first]) == 1)
        #expect(shelf.items.map(\.name) == ["b.txt", "a.txt"])
    }

    @Test func persistsAcrossLaunches() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile("report.pdf")
        ShelfFeature(store: store).add([file])
        let reloaded = ShelfFeature(store: store)
        #expect(reloaded.items.map(\.name) == ["report.pdf"])
        #expect(reloaded.url(for: reloaded.items[0])?.lastPathComponent == "report.pdf")
    }

    @Test func followsAMovedFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = ShelfFeature(store: store)
        let file = try makeFile("draft.key")
        shelf.add([file])
        let moved = directory.appendingPathComponent("final.key")
        try FileManager.default.moveItem(at: file, to: moved)
        #expect(shelf.url(for: shelf.items[0])?.lastPathComponent == "final.key")
        #expect(shelf.items[0].name == "final.key")
    }

    @Test func deletedFileResolvesToNil() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = ShelfFeature(store: store)
        let file = try makeFile("gone.txt")
        shelf.add([file])
        try FileManager.default.removeItem(at: file)
        #expect(shelf.url(for: shelf.items[0]) == nil)
        #expect(shelf.items[0].name == "gone.txt")
    }

    @Test func removeAndClear() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = ShelfFeature(store: store)
        try shelf.add([makeFile("1"), makeFile("2"), makeFile("3")])
        shelf.remove(shelf.items[0].id)
        #expect(shelf.items.count == 2)
        shelf.clear()
        #expect(shelf.items.isEmpty)
        #expect(ShelfFeature(store: store).items.isEmpty)
    }

    @Test func isCapped() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = ShelfFeature(store: store)
        let files = try (0 ..< ShelfFeature.maxItems + 5).map { try makeFile("f\($0)") }
        shelf.add(files)
        #expect(shelf.items.count == ShelfFeature.maxItems)
    }

    @Test func corruptStateStartsEmpty() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{not json".utf8).write(to: store.fileURL)
        #expect(ShelfFeature(store: store).items.isEmpty)
    }

    @Test func nonFileURLsAreIgnored() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = ShelfFeature(store: store)
        #expect(try shelf.add([#require(URL(string: "https://example.com/file.zip"))]) == 0)
    }
}
