import Foundation
import LiovaPluginKit
import Testing

@Suite("Validation")
struct ValidationTests {
    private func code(_ body: () throws(IPCErrorInfo) -> Void) -> IPCErrorCode? {
        do {
            try body()
            return nil
        } catch {
            return error.code
        }
    }

    private func activity(
        id: String = "build",
        source: String = "ci",
        title: String = "Building",
        subtitle: String? = nil,
        symbol: String? = nil,
        priority: ActivityPriority = .normal,
        expiresAt: Date? = nil
    ) -> Activity {
        Activity(
            id: ActivityID(id),
            source: source,
            priority: priority,
            title: title,
            subtitle: subtitle,
            symbol: symbol,
            expiresAt: expiresAt
        )
    }

    private func startCode(_ activity: Activity) -> IPCErrorCode? {
        code { () throws(IPCErrorInfo) in try LiovaValidation.validate(.start(activity)) }
    }

    // MARK: IDs and sources

    @Test(arguments: ["a", "build", "Build-42", "com.example.tool_1", String(repeating: "x", count: 128)])
    func acceptsValidIDs(id: String) {
        #expect(startCode(activity(id: id)) == nil)
    }

    @Test(arguments: [
        "", " ", "a b", "a/b", "../etc", "naïve", "emoji🎉", "tab\t", "new\nline", "semi;colon",
        String(repeating: "x", count: 129),
    ])
    func rejectsInvalidIDs(id: String) {
        #expect(startCode(activity(id: id)) == .badRequest)
        #expect(code { () throws(IPCErrorInfo) in try LiovaValidation.validate(.end(ActivityID(id))) } == .badRequest)
    }

    @Test(arguments: ["system.battery", "system.", "SYSTEM.hud", "System", "system"])
    func reservedSourcesAreForbidden(source: String) {
        #expect(LiovaValidation.isReservedSource(source))
        #expect(startCode(activity(source: source)) == .forbidden)
        #expect(code { () throws(IPCErrorInfo) in try LiovaValidation.validate(.endAll(source: source)) } == .forbidden)
    }

    @Test(arguments: ["systemd", "my.system.tool", "cli", "url", "com.example.system"])
    func similarLookingSourcesAreAllowed(source: String) {
        #expect(!LiovaValidation.isReservedSource(source))
        #expect(startCode(activity(source: source)) == nil)
    }

    @Test func trustedCallersMayUseReservedSources() {
        #expect(code { () throws(IPCErrorInfo) in
            try LiovaValidation.validate(.start(activity(source: "system.battery")), allowReservedSources: true)
        } == nil)
    }

    @Test func rejectsMalformedSources() {
        #expect(startCode(activity(source: "")) == .badRequest)
        #expect(startCode(activity(source: "my tool")) == .badRequest)
        #expect(startCode(activity(source: String(repeating: "s", count: 129))) == .badRequest)
    }

    // MARK: Text

    @Test func titleLengthLimit() {
        #expect(startCode(activity(title: String(repeating: "a", count: 200))) == nil)
        #expect(startCode(activity(title: String(repeating: "a", count: 201))) == .badRequest)
        // Measured in Unicode scalars, so stacked combining marks can't sneak past.
        #expect(startCode(activity(title: "e" + String(repeating: "\u{301}", count: 250))) == .badRequest)
    }

    @Test(arguments: ["", "   ", "\t"])
    func titleMustNotBeBlank(title: String) {
        #expect(startCode(activity(title: title)) == .badRequest)
    }

    @Test(arguments: ["line\nbreak", "bell\u{7}", "nul\u{0}", "esc\u{1B}[31m", "sep\u{2028}", "c1\u{85}"])
    func rejectsControlCharacters(text: String) {
        #expect(startCode(activity(title: text)) == .badRequest)
        #expect(startCode(activity(subtitle: text)) == .badRequest)
    }

    @Test func acceptsInternationalTextAndEmoji() {
        #expect(startCode(activity(title: "Déploiement 🚀 完成", subtitle: "Ünïcödé — ok")) == nil)
    }

    @Test func subtitleLimitsAndEmptySubtitle() {
        #expect(startCode(activity(subtitle: "")) == nil)
        #expect(startCode(activity(subtitle: String(repeating: "b", count: 200))) == nil)
        #expect(startCode(activity(subtitle: String(repeating: "b", count: 201))) == .badRequest)
    }

    // MARK: Symbols, priority, dates

    @Test(arguments: ["hammer", "hammer.fill", "checkmark.circle.fill", "1.circle", "arrow.up.right.square"])
    func acceptsSymbolNames(symbol: String) {
        #expect(startCode(activity(symbol: symbol)) == nil)
    }

    @Test(arguments: ["", ".hidden", "trailing.", "a..b", "../../etc/passwd", "/abs", "has space", "ünï"])
    func rejectsBadSymbolNames(symbol: String) {
        #expect(startCode(activity(symbol: symbol)) == .badRequest)
    }

    @Test func priorityRange() {
        #expect(startCode(activity(priority: ActivityPriority(rawValue: 0))) == nil)
        #expect(startCode(activity(priority: ActivityPriority(rawValue: 1000))) == nil)
        #expect(startCode(activity(priority: ActivityPriority(rawValue: -1))) == .badRequest)
        #expect(startCode(activity(priority: ActivityPriority(rawValue: 1001))) == .badRequest)
        #expect(startCode(activity(priority: ActivityPriority(rawValue: .max))) == .badRequest)
    }

    @Test func expiryMustBeSensible() {
        #expect(startCode(activity(expiresAt: Date(timeIntervalSince1970: 1_800_000_000))) == nil)
        #expect(startCode(activity(expiresAt: Date(timeIntervalSince1970: -5))) == .badRequest)
        #expect(startCode(activity(expiresAt: Date(timeIntervalSince1970: 1e300))) == .badRequest)
    }

    // MARK: Patches

    private func patchCode(_ patch: ActivityPatch) -> IPCErrorCode? {
        code { () throws(IPCErrorInfo) in try LiovaValidation.validate(.update(patch)) }
    }

    @Test func validatesPatchFields() {
        #expect(patchCode(ActivityPatch(id: "a", title: "ok", progress: 0.5)) == nil)
        #expect(patchCode(ActivityPatch(id: "a")) == nil)
        #expect(patchCode(ActivityPatch(id: "a b")) == .badRequest)
        #expect(patchCode(ActivityPatch(id: "a", title: " ")) == .badRequest)
        #expect(patchCode(ActivityPatch(id: "a", subtitle: "x\ny")) == .badRequest)
        #expect(patchCode(ActivityPatch(id: "a", symbol: "../x")) == .badRequest)
        #expect(patchCode(ActivityPatch(id: "a", progress: .nan)) == .badRequest)
        #expect(patchCode(ActivityPatch(id: "a", progress: .infinity)) == .badRequest)
        #expect(patchCode(ActivityPatch(id: "a", priority: ActivityPriority(rawValue: 5000))) == .badRequest)
    }

    @Test func rejectsSettingAndClearingTheSameField() {
        #expect(patchCode(ActivityPatch(id: "a", progress: 0.5, clear: [.progress])) == .badRequest)
        #expect(patchCode(ActivityPatch(id: "a", progress: 0.5, clear: [.subtitle])) == nil)
    }

    @Test func pingAndListAlwaysValidate() {
        #expect(code { () throws(IPCErrorInfo) in try LiovaValidation.validate(.ping) } == nil)
        #expect(code { () throws(IPCErrorInfo) in try LiovaValidation.validate(.list) } == nil)
    }
}
