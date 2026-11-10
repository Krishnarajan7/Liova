import Foundation
@testable import LiovaProviders
import Testing

@MainActor
final class FakePasteboard: PasteboardAccess {
    private(set) var changeCount = 0
    var types: [String] = ["public.utf8-plain-text"]
    private(set) var content: ClipboardContent?

    func read() -> ClipboardContent? {
        content
    }

    func write(_ content: ClipboardContent) {
        self.content = content
        changeCount += 1
    }

    /// Another app copied something.
    func copy(_ content: ClipboardContent, types: [String] = ["public.utf8-plain-text"]) {
        self.types = types
        write(content)
    }
}

@MainActor
struct ClipboardWatcherTests {
    let pasteboard = FakePasteboard()
    var idle: TimeInterval = 0

    private func watcher(idle: TimeInterval = 0) -> SystemClipboardWatcher {
        SystemClipboardWatcher(pasteboard: pasteboard, secondsSinceInput: { idle })
    }

    @Test func onlyNewCopiesCount() {
        pasteboard.copy(.text("copied before Liova started"))
        let watcher = watcher()
        var copies: [ClipboardContent] = []
        watcher.start { copies.append($0.content) }
        watcher.check()
        #expect(copies.isEmpty)
        pasteboard.copy(.text("hello"))
        watcher.check()
        watcher.check()
        #expect(copies == [.text("hello")])
        watcher.stop()
    }

    @Test func passwordsAreNeverKept() {
        let watcher = watcher()
        var copies: [ClipboardContent] = []
        watcher.start { copies.append($0.content) }
        pasteboard.copy(.text("hunter2"), types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        watcher.check()
        pasteboard.copy(.text("one-time code"), types: ["org.nspasteboard.TransientType"])
        watcher.check()
        #expect(copies.isEmpty)
        watcher.stop()
    }

    @Test func copyingBackFromHistoryIsNotANewCopy() {
        let watcher = watcher()
        var copies: [ClipboardContent] = []
        watcher.start { copies.append($0.content) }
        watcher.write(.text("from history"))
        watcher.check()
        #expect(copies.isEmpty)
        #expect(pasteboard.content == .text("from history"))
        watcher.stop()
    }

    @Test func looksRarelyWhileYouAreAway() {
        let active = watcher(idle: 2)
        active.start { _ in }
        active.check()
        #expect(active.interval == SystemClipboardWatcher.activeInterval)
        active.stop()
        #expect(active.interval == nil)

        let away = watcher(idle: 600)
        away.start { _ in }
        away.check()
        #expect(away.interval == SystemClipboardWatcher.idleInterval)
        away.stop()
    }
}

struct ClipboardRulesTests {
    @Test func passwordManagersAndMarkedCopiesArePrivate() {
        #expect(ClipboardRules.isPrivate(types: ["org.nspasteboard.ConcealedType"], sourceBundleID: nil))
        #expect(ClipboardRules.isPrivate(types: ["public.utf8-plain-text"], sourceBundleID: "com.1password.1password"))
        #expect(ClipboardRules.isPrivate(types: [], sourceBundleID: "com.apple.Passwords"))
        #expect(!ClipboardRules.isPrivate(types: ["public.utf8-plain-text"], sourceBundleID: "com.apple.Safari"))
    }

    @Test func aWebAddressIsALink() throws {
        #expect(try ClipboardRules.content(fromText: " https://liova.app/download \n") ==
            .link(#require(URL(string: "https://liova.app/download"))))
        #expect(ClipboardRules.content(fromText: "see https://liova.app") == .text("see https://liova.app"))
        #expect(ClipboardRules.content(fromText: "mailto:me@example.com") == .text("mailto:me@example.com"))
        #expect(ClipboardRules.content(fromText: "ftp://example.com") == .text("ftp://example.com"))
    }

    @Test func emptyAndHugeTextIsLeftOut() {
        #expect(ClipboardRules.content(fromText: "  \n ") == nil)
        #expect(ClipboardRules.content(fromText: String(repeating: "a", count: 100_001)) == nil)
    }
}
