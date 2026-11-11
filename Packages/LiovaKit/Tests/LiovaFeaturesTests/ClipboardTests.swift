import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaProviders
import Testing

@MainActor
final class FakeClipboardWatcher: ClipboardWatching {
    private var onCopy: (@MainActor (ClipboardCapture) -> Void)?
    private(set) var isStarted = false
    private(set) var written: [ClipboardContent] = []

    func start(onCopy: @escaping @MainActor (ClipboardCapture) -> Void) {
        isStarted = true
        self.onCopy = onCopy
    }

    func stop() {
        isStarted = false
        onCopy = nil
    }

    func write(_ content: ClipboardContent) {
        written.append(content)
    }

    func copy(_ content: ClipboardContent, in app: String? = "com.apple.Safari") {
        onCopy?(ClipboardCapture(content: content, sourceBundleID: app))
    }
}

final class ClipboardClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ seconds: TimeInterval) {
        now += seconds
    }
}

@MainActor
struct ClipboardTests {
    let watcher = FakeClipboardWatcher()
    let settings: LiovaSettings
    let store: ClipboardPinStore
    let feature: ClipboardFeature
    private let scratch = ScratchDefaults()
    private let clock = ClipboardClock()

    init() {
        settings = LiovaSettings(defaults: scratch.defaults)
        store = ClipboardPinStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("liova-clipboard-\(UUID().uuidString).json"))
        feature = Self.make(settings: settings, watcher: watcher, store: store, clock: clock)
        feature.syncWithSettings()
    }

    private static func make(
        settings: LiovaSettings, watcher: FakeClipboardWatcher, store: ClipboardPinStore, clock: ClipboardClock
    ) -> ClipboardFeature {
        ClipboardFeature(settings: settings, watcher: watcher, store: store, now: { clock.now })
    }

    private var texts: [String] {
        feature.items.compactMap {
            if case let .text(text) = $0.content {
                text
            } else {
                nil
            }
        }
    }

    @Test func newestFirst() {
        watcher.copy(.text("one"))
        clock.advance(1)
        watcher.copy(.text("two"))
        #expect(texts == ["two", "one"])
        #expect(feature.items.first?.sourceBundleID == "com.apple.Safari")
    }

    @Test func copyingAgainMovesItUpInsteadOfRepeating() {
        watcher.copy(.text("one"))
        clock.advance(1)
        watcher.copy(.text("two"))
        clock.advance(1)
        watcher.copy(.text("one"))
        #expect(texts == ["one", "two"])
    }

    @Test func clickingCopiesItBackAndMovesItUp() throws {
        watcher.copy(.text("one"))
        clock.advance(1)
        watcher.copy(.text("two"))
        clock.advance(1)
        let one = try #require(feature.items.last)
        feature.copy(one)
        #expect(watcher.written == [.text("one")])
        #expect(texts == ["one", "two"])
        #expect(feature.justCopied == one.id)
    }

    @Test func oldCopiesFallOffButPinsStay() throws {
        watcher.copy(.text("keep me"))
        try feature.togglePin(#require(feature.items.first))
        for index in 0 ..< ClipboardFeature.maxItems + 5 {
            clock.advance(1)
            watcher.copy(.text("copy \(index)"))
        }
        #expect(feature.items.count == ClipboardFeature.maxItems + 1)
        #expect(texts.first == "keep me")
        #expect(!texts.contains("copy 0"))
    }

    @Test func onlyAFewImagesAreKept() {
        for index in 0 ..< ClipboardFeature.maxImages + 3 {
            clock.advance(1)
            watcher.copy(.image(data: Data([UInt8(index)]), type: "public.png"))
        }
        watcher.copy(.text("text"))
        let images = feature.items.filter {
            if case .image = $0.content {
                true
            } else {
                false
            }
        }
        #expect(images.count == ClipboardFeature.maxImages)
        #expect(texts == ["text"])
    }

    @Test func pinsSurviveARestartAndNothingElseIsSaved() throws {
        watcher.copy(.text("secret-ish"))
        clock.advance(1)
        try watcher.copy(.link(#require(URL(string: "https://liova.app"))))
        try feature.togglePin(#require(feature.items.first))
        let restarted = Self.make(settings: settings, watcher: FakeClipboardWatcher(), store: store, clock: clock)
        #expect(try restarted.items.map(\.content) == [.link(#require(URL(string: "https://liova.app")))])
        #expect(restarted.items.first?.isPinned == true)
        try? FileManager.default.removeItem(at: store.fileURL)
    }

    @Test func turningItOffForgetsHistory() throws {
        watcher.copy(.text("one"))
        clock.advance(1)
        watcher.copy(.text("pinned"))
        try feature.togglePin(#require(feature.items.first))
        settings.clipboardHistoryEnabled = false
        feature.syncWithSettings()
        #expect(!watcher.isStarted)
        #expect(texts == ["pinned"])
        try? FileManager.default.removeItem(at: store.fileURL)
    }

    @Test func clearKeepsPins() throws {
        watcher.copy(.text("one"))
        clock.advance(1)
        watcher.copy(.text("pinned"))
        try feature.togglePin(#require(feature.items.first))
        feature.clear()
        #expect(texts == ["pinned"])
        try? FileManager.default.removeItem(at: store.fileURL)
    }

    @Test func ageReadsNaturally() {
        let now = Date()
        #expect(ClipboardText.age(now.addingTimeInterval(-10), now: now) == "now")
        #expect(ClipboardText.age(now.addingTimeInterval(-600), now: now) != "now")
    }
}
