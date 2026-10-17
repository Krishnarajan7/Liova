import Foundation
import LiovaPluginKit
import Testing

private let fullActivity = Activity(
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

/// The wire format as a client of `LiovaIPC` sees it. Deeper model tests live in
/// LiovaPluginKitTests; these cover the request/response contract end to end.
@Suite("Wire protocol")
struct WireProtocolTests {
    private func decode(_ json: String) -> Result<IPCRequest, IPCErrorInfo> {
        LiovaWire.decodeRequest(Data(json.utf8))
    }

    private func errorCode(_ json: String) -> IPCErrorCode? {
        if case let .failure(error) = decode(json) {
            return error.code
        }
        return nil
    }

    // MARK: Round trips

    @Test(arguments: [
        IPCCommand.ping,
        .list,
        .start(fullActivity),
        .start(Activity(id: "min", source: "cli", title: "Minimal")),
        .update(ActivityPatch(id: "build", title: "New", subtitle: "s", symbol: "bolt", progress: 1, tint: .green)),
        .update(ActivityPatch(id: "build", priority: ActivityPriority(rawValue: 250))),
        .update(ActivityPatch(id: "build", expiresAt: Date(timeIntervalSince1970: 1_900_000_000))),
        .update(ActivityPatch(id: "build", clear: Set(ActivityPatch.Field.allCases))),
        .end("build"),
        .endAll(source: "my-tool"),
    ])
    func everyCommandRoundTrips(command: IPCCommand) throws {
        let line = try LiovaWire.encodeLine(IPCRequest(command: command))
        #expect(line.last == 0x0A)
        #expect(!line.dropLast().contains(0x0A))
        let decoded = try LiovaWire.decodeRequest(line.dropLast()).get()
        #expect(decoded.command == command)
        #expect(decoded.version == LiovaPluginKit.apiVersion)
    }

    @Test(arguments: [
        IPCResponse.success(),
        .success(activities: []),
        .success(activities: [fullActivity]),
        .failure(.notFound, "No live activity with ID 'x'."),
        .failure(.rateLimited, "Slow down."),
        IPCResponse(ok: false, error: IPCErrorInfo(IPCErrorCode(rawValue: "fromTheFuture"), "New code")),
    ])
    func everyResponseRoundTrips(response: IPCResponse) throws {
        let line = try LiovaWire.encodeLine(response)
        #expect(try LiovaWire.makeDecoder().decode(IPCResponse.self, from: line.dropLast()) == response)
    }

    @Test func documentedExamplesDecode() throws {
        let examples = [
            #"{"v":1,"op":"ping"}"#,
            #"{"v":1,"op":"list"}"#,
            #"{"v":1,"op":"start","activity":{"id":"build","source":"ci","title":"Building","progress":0.4}}"#,
            #"{"v":1,"op":"update","patch":{"id":"build","progress":0.8,"clear":["subtitle"]}}"#,
            #"{"v":1,"op":"end","id":"build"}"#,
            #"{"v":1,"op":"endAll","source":"ci"}"#,
        ]
        for example in examples {
            #expect(throws: Never.self) { try decode(example).get() }
        }
    }

    // MARK: Errors

    @Test func unknownOpIsABadRequestNamingTheValidOps() {
        guard case let .failure(error) = decode(#"{"v":1,"op":"reboot"}"#) else {
            Issue.record("Expected a failure")
            return
        }
        #expect(error.code == .badRequest)
        #expect(error.message.contains("reboot"))
        #expect(error.message.contains("endAll"))
    }

    @Test(arguments: [#"{"v":2,"op":"ping"}"#, #"{"v":0,"op":"ping"}"#, #"{"v":-1,"op":"ping"}"#])
    func wrongVersionIsUnsupported(json: String) {
        #expect(errorCode(json) == .unsupportedVersion)
    }

    @Test func versionIsCheckedBeforeTheBody() {
        // A newer client sending a command this server doesn't know still learns the real problem.
        #expect(errorCode(#"{"v":2,"op":"teleport","whatever":true}"#) == .unsupportedVersion)
    }

    @Test(arguments: [
        "", "null", "42", "[]", "\"ping\"", "{", #"{"op":"ping"}"#, #"{"v":"1","op":"ping"}"#,
        #"{"v":1}"#, #"{"v":1,"op":7}"#, #"{"v":1,"op":"start"}"#, #"{"v":1,"op":"start","activity":{}}"#,
        #"{"v":1,"op":"update","patch":{"title":"x"}}"#, #"{"v":1,"op":"end","id":5}"#,
    ])
    func malformedRequestsAreBadRequests(json: String) {
        #expect(errorCode(json) == .badRequest)
    }

    @Test func invalidUTF8IsABadRequest() {
        let bytes = Data([0x7B, 0xFF, 0xFE, 0x7D])
        guard case let .failure(error) = LiovaWire.decodeRequest(bytes) else {
            Issue.record("Expected a failure")
            return
        }
        #expect(error.code == .badRequest)
    }

    // MARK: Priority

    @Test(arguments: [
        ("\"low\"", ActivityPriority.low),
        ("\"normal\"", .normal),
        ("\"high\"", .high),
        ("\"critical\"", .critical),
        ("300", .high),
        ("250", ActivityPriority(rawValue: 250)),
    ])
    func priorityAcceptsNamesAndIntegers(value: String, expected: ActivityPriority) throws {
        let json = #"{"v":1,"op":"start","activity":{"id":"a","source":"ci","title":"T","priority":"#
            + value + "}}"
        guard case let .start(activity) = try decode(json).get().command else {
            Issue.record("Expected start")
            return
        }
        #expect(activity.priority == expected)
    }

    @Test func unknownPriorityNameIsRejected() {
        #expect(errorCode(#"{"v":1,"op":"start","activity":{"id":"a","title":"T","priority":"urgent"}}"#) ==
            .badRequest)
    }

    @Test func prioritiesAreEncodedAsIntegers() throws {
        let data = try LiovaWire.makeEncoder().encode(ActivityPatch(id: "a", priority: .critical))
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(json == #"{"id":"a","priority":400}"#)
    }

    // MARK: Patches

    @Test func patchApplySetsAndClears() {
        let patch = ActivityPatch(
            id: "build",
            title: "Linking",
            progress: 0.9,
            tint: .green,
            clear: [.subtitle, .symbol]
        )
        let result = patch.applied(to: fullActivity)
        #expect(result.title == "Linking")
        #expect(result.progress == 0.9)
        #expect(result.tint == .green)
        #expect(result.subtitle == nil)
        #expect(result.symbol == nil)
        #expect(result.priority == .high)
        #expect(result.expiresAt == fullActivity.expiresAt)
        #expect(result.id == "build")
        #expect(result.source == "ci")
    }

    @Test func emptyPatchChangesNothing() {
        let patch = ActivityPatch(id: "build")
        #expect(patch.isEmpty)
        #expect(patch.applied(to: fullActivity) == fullActivity)
    }

    @Test func patchClampsProgress() {
        let result = ActivityPatch(id: "build", progress: 7).applied(to: fullActivity)
        #expect(result.progress == 1)
    }

    @Test func explicitNullClearsAField() throws {
        let request = try decode(#"{"v":1,"op":"update","patch":{"id":"build","progress":null}}"#).get()
        #expect(request.command == .update(ActivityPatch(id: "build", clear: [.progress])))
    }

    @Test func clearingAnUnclearableFieldIsRejected() {
        #expect(errorCode(#"{"v":1,"op":"update","patch":{"id":"build","clear":["title"]}}"#) == .badRequest)
        #expect(errorCode(#"{"v":1,"op":"update","patch":{"id":"build","title":null}}"#) == .badRequest)
    }

    // MARK: Validation

    @Test(arguments: ["system", "system.battery", "System.HUD", "SYSTEM."])
    func reservedSourcesAreForbidden(source: String) {
        #expect(LiovaValidation.isReservedSource(source))
        let start = IPCCommand.start(Activity(id: "a", source: source, title: "T"))
        #expect(validationCode(start) == .forbidden)
        #expect(validationCode(.endAll(source: source)) == .forbidden)
        #expect(validationCode(start, allowReserved: true) == nil)
    }

    @Test(arguments: ["systemd", "my.system.tool", "cli", "url", "com.example.build"])
    func lookalikeSourcesAreAllowed(source: String) {
        #expect(!LiovaValidation.isReservedSource(source))
        #expect(validationCode(.start(Activity(id: "a", source: source, title: "T"))) == nil)
    }

    @Test func validationEdgeCases() {
        func start(_ activity: Activity) -> IPCErrorCode? {
            validationCode(.start(activity))
        }
        let long = String(repeating: "x", count: 201)
        #expect(start(Activity(id: "a", source: "s", title: "   ")) == .badRequest)
        #expect(start(Activity(id: "a", source: "s", title: long)) == .badRequest)
        #expect(start(Activity(id: "a", source: "s", title: String(long.dropLast()))) == nil)
        #expect(start(Activity(id: "a", source: "s", title: "line\nbreak")) == .badRequest)
        #expect(start(Activity(id: "a", source: "s", title: "T", subtitle: "bell\u{7}")) == .badRequest)
        #expect(start(Activity(id: "a", source: "s", title: "Émoji 🎉 ok")) == nil)
        #expect(start(Activity(id: "a", source: "s", title: "T", symbol: "../x")) == .badRequest)
        #expect(start(Activity(id: "a", source: "s", title: "T", symbol: "hammer..fill")) == .badRequest)
        #expect(start(Activity(id: "a", source: "s", priority: ActivityPriority(rawValue: 1001), title: "T")) ==
            .badRequest)
        #expect(start(Activity(id: "a", source: "s", priority: ActivityPriority(rawValue: -1), title: "T")) ==
            .badRequest)
        #expect(start(Activity(id: "", source: "s", title: "T")) == .badRequest)
        #expect(start(Activity(id: "a", source: "", title: "T")) == .badRequest)
        #expect(start(Activity(id: "a/b", source: "s", title: "T")) == .badRequest)
        #expect(start(Activity(id: "a", source: "s", title: "T", expiresAt: Date(timeIntervalSince1970: 1e12))) ==
            .badRequest)
        #expect(validationCode(.update(ActivityPatch(id: "a", progress: .nan))) == .badRequest)
        #expect(validationCode(.update(ActivityPatch(id: "a", progress: 0.5, clear: [.progress]))) == .badRequest)
        #expect(validationCode(.end("a b")) == .badRequest)
        #expect(validationCode(.ping) == nil)
        #expect(validationCode(.list) == nil)
    }

    private func validationCode(_ command: IPCCommand, allowReserved: Bool = false) -> IPCErrorCode? {
        do {
            try LiovaValidation.validate(command, allowReservedSources: allowReserved)
            return nil
        } catch {
            return error.code
        }
    }
}
