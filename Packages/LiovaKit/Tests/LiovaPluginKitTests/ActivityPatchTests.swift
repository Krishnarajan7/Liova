import Foundation
import LiovaPluginKit
import Testing

@Suite("ActivityPatch")
struct ActivityPatchTests {
    private let base = Activity(
        id: "build",
        source: "ci",
        priority: .normal,
        title: "Building",
        subtitle: "main",
        symbol: "hammer",
        progress: 0.25,
        tint: .accent,
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )

    @Test func emptyPatchChangesNothing() {
        let patch = ActivityPatch(id: "build")
        #expect(patch.isEmpty)
        #expect(patch.applied(to: base) == base)
    }

    @Test func setsOnlyTheGivenFields() {
        let patch = ActivityPatch(id: "build", title: "Linking", progress: 0.9, tint: .green)
        let result = patch.applied(to: base)
        #expect(result.title == "Linking")
        #expect(result.progress == 0.9)
        #expect(result.tint == .green)
        #expect(result.subtitle == "main")
        #expect(result.symbol == "hammer")
        #expect(result.priority == .normal)
        #expect(result.expiresAt == base.expiresAt)
        #expect(result.source == "ci")
        #expect(result.id == "build")
    }

    @Test func setsEveryField() {
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let patch = ActivityPatch(
            id: "build",
            title: "T",
            subtitle: "S",
            symbol: "checkmark",
            progress: 1,
            tint: .red,
            priority: .critical,
            expiresAt: date
        )
        let result = patch.applied(to: base)
        #expect(result == Activity(
            id: "build",
            source: "ci",
            priority: .critical,
            title: "T",
            subtitle: "S",
            symbol: "checkmark",
            progress: 1,
            tint: .red,
            expiresAt: date
        ))
    }

    @Test(arguments: ActivityPatch.Field.allCases)
    func clearsEachOptionalField(field: ActivityPatch.Field) {
        let result = ActivityPatch(id: "build", clear: [field]).applied(to: base)
        switch field {
        case .subtitle: #expect(result.subtitle == nil)
        case .symbol: #expect(result.symbol == nil)
        case .progress: #expect(result.progress == nil)
        case .expiresAt: #expect(result.expiresAt == nil)
        }
        #expect(result.title == base.title)
    }

    @Test func clearingAnAbsentFieldIsHarmless() {
        var plain = base
        plain.progress = nil
        #expect(ActivityPatch(id: "build", clear: [.progress]).applied(to: plain) == plain)
    }

    @Test func clampsProgressWhenApplied() {
        #expect(ActivityPatch(id: "build", progress: 7).applied(to: base).progress == 1)
        #expect(ActivityPatch(id: "build", progress: -2).applied(to: base).progress == 0)
    }

    @Test func detectsConflictingSetAndClear() {
        let patch = ActivityPatch(id: "build", subtitle: "x", progress: 0.5, clear: [.progress, .symbol])
        #expect(patch.conflictingFields == [.progress])
    }

    // MARK: Coding

    private func decodePatch(_ json: String) throws -> ActivityPatch {
        try LiovaWire.makeDecoder().decode(ActivityPatch.self, from: Data(json.utf8))
    }

    @Test func decodesClearList() throws {
        let patch = try decodePatch(#"{"id":"build","clear":["progress","subtitle"]}"#)
        #expect(patch.clear == [.progress, .subtitle])
        #expect(patch.progress == nil)
    }

    @Test func nullMeansClear() throws {
        let patch = try decodePatch(#"{"id":"build","progress":null,"symbol":null,"title":"New"}"#)
        #expect(patch.clear == [.progress, .symbol])
        #expect(patch.title == "New")
        let result = patch.applied(to: base)
        #expect(result.progress == nil)
        #expect(result.symbol == nil)
        #expect(result.subtitle == "main")
    }

    @Test(arguments: ["title", "tint", "priority"])
    func requiredFieldsCannotBeNulled(field: String) {
        #expect(throws: DecodingError.self) {
            try decodePatch(#"{"id":"build","\#(field)":null}"#)
        }
    }

    @Test(arguments: ["title", "id", "source", "tint", ""])
    func onlyOptionalFieldsCanBeCleared(field: String) {
        #expect(throws: DecodingError.self) {
            try decodePatch(#"{"id":"build","clear":["\#(field)"]}"#)
        }
    }

    @Test func encodesClearAsSortedListAndOmitsNils() throws {
        let patch = ActivityPatch(id: "build", progress: 0.5, clear: [.symbol, .expiresAt, .subtitle])
        let json = try #require(String(bytes: LiovaWire.makeEncoder().encode(patch), encoding: .utf8))
        #expect(json == #"{"clear":["expiresAt","subtitle","symbol"],"id":"build","progress":0.5}"#)
    }

    @Test func omitsEmptyClear() throws {
        let json = try #require(String(bytes: LiovaWire.makeEncoder().encode(ActivityPatch(id: "a")), encoding: .utf8))
        #expect(json == #"{"id":"a"}"#)
    }
}
