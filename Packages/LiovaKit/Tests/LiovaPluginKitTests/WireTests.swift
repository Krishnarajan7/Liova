import Foundation
@testable import LiovaPluginKit
import Testing

@Suite("Wire format")
struct WireTests {
    private let sampleActivity = Activity(
        id: "build",
        source: "ci",
        priority: .high,
        title: "Deploying",
        subtitle: "staging",
        symbol: "hammer.fill",
        progress: 0.4,
        tint: .blue,
        expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    private func encode(_ request: IPCRequest) throws -> String {
        try #require(String(data: LiovaWire.makeEncoder().encode(request), encoding: .utf8))
    }

    private func decode(_ json: String) -> Result<IPCRequest, IPCErrorInfo> {
        LiovaWire.decodeRequest(Data(json.utf8))
    }

    private func decoded(_ json: String) throws -> IPCCommand {
        try decode(json).get().command
    }

    private func errorCode(_ json: String) -> IPCErrorCode? {
        if case let .failure(error) = decode(json) {
            return error.code
        }
        return nil
    }

    // MARK: Encoding shape

    @Test func encodesReadableFlatShapes() throws {
        #expect(try encode(IPCRequest(command: .ping)) == #"{"op":"ping","v":1}"#)
        #expect(try encode(IPCRequest(command: .list)) == #"{"op":"list","v":1}"#)
        #expect(try encode(IPCRequest(command: .end("build"))) == #"{"id":"build","op":"end","v":1}"#)
        #expect(try encode(IPCRequest(command: .endAll(source: "ci"))) == #"{"op":"endAll","source":"ci","v":1}"#)
        #expect(
            try encode(IPCRequest(command: .update(ActivityPatch(id: "build", progress: 0.5))))
                == #"{"op":"update","patch":{"id":"build","progress":0.5},"v":1}"#
        )
    }

    @Test func encodesStartWithDatesAsSecondsAndPriorityAsInteger() throws {
        let json = try encode(IPCRequest(command: .start(sampleActivity)))
        #expect(json.contains(#""expiresAt":1800000000"#))
        #expect(json.contains(#""priority":300"#))
        #expect(json.hasPrefix(#"{"activity":{"#))
        #expect(!json.contains("\n"))
    }

    @Test func encodeLineEndsWithExactlyOneNewline() throws {
        let line = try LiovaWire.encodeLine(IPCRequest(command: .ping))
        #expect(line.last == 0x0A)
        #expect(line.filter { $0 == 0x0A }.count == 1)
    }

    // MARK: Round trips

    @Test(arguments: [
        IPCCommand.ping,
        .list,
        .end("build"),
        .endAll(source: "my-tool"),
        .update(ActivityPatch(id: "a", title: "T", progress: 0.2, tint: .red, priority: .low)),
        .update(ActivityPatch(id: "a", clear: [.progress, .subtitle, .symbol, .expiresAt])),
        .update(ActivityPatch(id: "a", expiresAt: Date(timeIntervalSince1970: 1_700_000_000.5))),
    ])
    func roundTripsEveryCommand(command: IPCCommand) throws {
        let line = try LiovaWire.encodeLine(IPCRequest(command: command))
        let request = try LiovaWire.decodeRequest(line.dropLast()).get()
        #expect(request.command == command)
        #expect(request.version == LiovaPluginKit.apiVersion)
    }

    @Test func roundTripsStart() throws {
        let line = try LiovaWire.encodeLine(IPCRequest(command: .start(sampleActivity)))
        #expect(try LiovaWire.decodeRequest(line.dropLast()).get().command == .start(sampleActivity))
    }

    @Test func roundTripsResponses() throws {
        let responses: [IPCResponse] = [
            .success(),
            .success(activities: [sampleActivity]),
            .failure(.notFound, "No activity 'x'."),
            IPCResponse(ok: false, error: IPCErrorInfo(IPCErrorCode(rawValue: "somethingNew"), "From the future")),
        ]
        for response in responses {
            let data = try LiovaWire.makeEncoder().encode(response)
            #expect(try LiovaWire.makeDecoder().decode(IPCResponse.self, from: data) == response)
        }
        let json = try #require(String(bytes: LiovaWire.makeEncoder().encode(IPCResponse.success()), encoding: .utf8))
        #expect(json == #"{"ok":true,"v":1}"#)
    }

    // MARK: Decoding leniency

    @Test func decodesMinimalStartWithDefaults() throws {
        let command = try decoded(#"{"v":1,"op":"start","activity":{"id":"x","title":"Hello"}}"#)
        guard case let .start(activity) = command else {
            Issue.record("Expected start, got \(command)")
            return
        }
        #expect(activity.source == "unknown")
        #expect(activity.priority == .normal)
        #expect(activity.tint == .accent)
        #expect(activity.progress == nil)
    }

    @Test(arguments: [("\"high\"", 300), ("\"low\"", 100), ("\"critical\"", 400), ("250", 250)])
    func acceptsPriorityAsNameOrInteger(raw: String, expected: Int) throws {
        let command = try decoded(#"{"v":1,"op":"update","patch":{"id":"x","priority":\#(raw)}}"#)
        #expect(command == .update(ActivityPatch(id: "x", priority: ActivityPriority(rawValue: expected))))
    }

    @Test func acceptsDatesAsSecondsOrISO8601() throws {
        let expected = Date(timeIntervalSince1970: 1_800_000_000)
        for raw in ["1800000000", "\"2027-01-15T08:00:00Z\"", "\"2027-01-15T08:00:00.000Z\""] {
            let command = try decoded(#"{"v":1,"op":"update","patch":{"id":"x","expiresAt":\#(raw)}}"#)
            #expect(command == .update(ActivityPatch(id: "x", expiresAt: expected)), "\(raw)")
        }
        #expect(errorCode(#"{"v":1,"op":"update","patch":{"id":"x","expiresAt":"tomorrow"}}"#) == .badRequest)
    }

    @Test func ignoresUnknownFieldsForForwardCompatibility() throws {
        let command = try decoded(#"{"v":1,"op":"end","id":"x","future":{"a":[1,2]}}"#)
        #expect(command == .end("x"))
    }

    // MARK: Errors

    @Test func rejectsUnknownOp() {
        let result = decode(#"{"v":1,"op":"explode"}"#)
        guard case let .failure(error) = result else {
            Issue.record("Expected failure")
            return
        }
        #expect(error.code == .badRequest)
        #expect(error.message.contains("explode"))
        #expect(error.message.contains("start"))
    }

    @Test(arguments: [2, 99, 0, -1])
    func rejectsUnsupportedVersions(version: Int) {
        #expect(errorCode(#"{"v":\#(version),"op":"ping"}"#) == .unsupportedVersion)
    }

    @Test func versionIsCheckedBeforeTheBody() {
        // A future client may send ops and shapes this server doesn't know.
        #expect(errorCode(#"{"v":2,"op":"teleport","whatever":true}"#) == .unsupportedVersion)
    }

    @Test(arguments: [
        "",
        "   ",
        "null",
        "[]",
        "\"ping\"",
        "{",
        "{\"op\":\"ping\"}",
        "{\"v\":\"1\",\"op\":\"ping\"}",
        "{\"v\":1.5,\"op\":\"ping\"}",
        "{\"v\":1}",
        "{\"v\":1,\"op\":42}",
        "{\"v\":1,\"op\":\"start\"}",
        "{\"v\":1,\"op\":\"start\",\"activity\":{\"id\":\"x\"}}",
        "{\"v\":1,\"op\":\"start\",\"activity\":{\"id\":\"x\",\"title\":\"t\",\"tint\":\"plaid\"}}",
        "{\"v\":1,\"op\":\"start\",\"activity\":{\"id\":\"x\",\"title\":\"t\",\"priority\":\"urgent\"}}",
        "{\"v\":1,\"op\":\"update\",\"patch\":{\"id\":\"x\",\"clear\":[\"title\"]}}",
        "{\"v\":1,\"op\":\"update\",\"patch\":{\"id\":\"x\",\"title\":null}}",
        "{\"v\":1,\"op\":\"end\"}",
        "{\"v\":1,\"op\":\"end\",\"id\":7}",
        "{\"v\":1,\"op\":\"endAll\"}",
    ])
    func rejectsMalformedRequestsAsBadRequest(json: String) {
        #expect(errorCode(json) == .badRequest, "\(json)")
    }

    @Test func rejectsInvalidUTF8() {
        let bytes = Data([0x7B, 0xFF, 0xFE, 0x7D])
        guard case let .failure(error) = LiovaWire.decodeRequest(bytes) else {
            Issue.record("Expected failure")
            return
        }
        #expect(error.code == .badRequest)
    }

    @Test func errorMessagesNameTheMissingField() {
        guard case let .failure(error) = decode(#"{"v":1,"op":"start","activity":{"id":"x"}}"#) else {
            Issue.record("Expected failure")
            return
        }
        #expect(error.message.contains("title"))
    }

    @Test func survivesDeeplyNestedJSON() {
        let nested = String(repeating: "[", count: 10000) + String(repeating: "]", count: 10000)
        // Either outcome is fine; the point is that hostile nesting can't crash the decoder.
        _ = decode(#"{"v":1,"op":"ping","x":\#(nested)}"#)
        #expect(errorCode(nested) == .badRequest)
    }
}
