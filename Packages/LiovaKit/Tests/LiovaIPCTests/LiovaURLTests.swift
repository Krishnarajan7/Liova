import Foundation
import LiovaIPC
import LiovaPluginKit
import Testing

@Suite("liova:// URLs")
struct LiovaURLTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func command(_ string: String) throws(IPCErrorInfo) -> IPCCommand {
        guard let url = URL(string: string) else {
            throw IPCErrorInfo(.badRequest, "Test URL didn't parse: \(string)")
        }
        return try LiovaURL.command(from: url, now: now)
    }

    private func errorCode(_ string: String) -> IPCErrorCode? {
        do {
            _ = try command(string)
            return nil
        } catch {
            return error.code
        }
    }

    private func startedActivity(_ string: String) throws -> Activity {
        guard case let .start(activity) = try command(string) else {
            throw IPCErrorInfo(.internal, "Expected start")
        }
        return activity
    }

    private func patch(_ string: String) throws -> ActivityPatch {
        guard case let .update(patch) = try command(string) else {
            throw IPCErrorInfo(.internal, "Expected update")
        }
        return patch
    }

    // MARK: Valid URLs

    @Test func startWithEveryField() throws {
        let activity = try startedActivity(
            "liova://activity/start?id=build&title=Deploying%20app&subtitle=staging&symbol=hammer.fill"
                + "&progress=0.4&tint=Blue&priority=low&ttl=120"
        )
        #expect(activity == Activity(
            id: "build",
            source: LiovaURL.source,
            priority: .low,
            title: "Deploying app",
            subtitle: "staging",
            symbol: "hammer.fill",
            progress: 0.4,
            tint: .blue,
            expiresAt: now.addingTimeInterval(120)
        ))
    }

    @Test func startAppliesTheDefaultTTL() throws {
        let activity = try startedActivity("liova://activity/start?id=a&title=Hi")
        #expect(activity.expiresAt == now.addingTimeInterval(LiovaURL.defaultTTL))
        #expect(activity.priority == .normal)
        #expect(activity.tint == .accent)
        #expect(activity.source == "url")
    }

    @Test func schemeHostAndActionAreCaseInsensitive() throws {
        let activity = try startedActivity("LIOVA://Activity/START?id=a&title=Hi")
        #expect(activity.id == "a")
    }

    @Test func updateParsesFieldsAndClear() throws {
        let patch =
            try patch("liova://activity/update?id=build&progress=0.8&title=Linking&clear=subtitle,symbol&ttl=60")
        #expect(patch == ActivityPatch(
            id: "build",
            title: "Linking",
            progress: 0.8,
            expiresAt: now.addingTimeInterval(60),
            clear: [.subtitle, .symbol]
        ))
    }

    @Test func endParsesTheID() throws {
        #expect(try command("liova://activity/end?id=build") == .end("build"))
        #expect(try command("liova://activity/end/?id=build") == .end("build"))
    }

    // MARK: Low-trust caps

    @Test(arguments: ["high", "critical", "400", "1000", "301"])
    func priorityIsCappedAtNormal(value: String) throws {
        #expect(try startedActivity("liova://activity/start?id=a&title=T&priority=\(value)").priority == .normal)
        #expect(try patch("liova://activity/update?id=a&priority=\(value)").priority == .normal)
    }

    @Test func lowerPrioritiesAreKept() throws {
        #expect(try startedActivity("liova://activity/start?id=a&title=T&priority=150").priority.rawValue == 150)
    }

    @Test(arguments: ["3601", "86400", "1e9"])
    func ttlIsCappedAtOneHour(value: String) throws {
        let activity = try startedActivity("liova://activity/start?id=a&title=T&ttl=\(value)")
        #expect(activity.expiresAt == now.addingTimeInterval(LiovaURL.maxTTL))
        #expect(try patch("liova://activity/update?id=a&ttl=\(value)").expiresAt == now.addingTimeInterval(3600))
    }

    @Test func ttlAtTheLimitIsKept() throws {
        let activity = try startedActivity("liova://activity/start?id=a&title=T&ttl=3600")
        #expect(activity.expiresAt == now.addingTimeInterval(3600))
    }

    @Test(arguments: ["0", "-5", "abc", "nan", "inf", ""])
    func invalidTTLIsRejected(value: String) {
        #expect(errorCode("liova://activity/start?id=a&title=T&ttl=\(value)") == .badRequest)
    }

    @Test func expiryCantBeCleared() {
        #expect(errorCode("liova://activity/update?id=a&clear=ttl") == .forbidden)
        #expect(errorCode("liova://activity/update?id=a&clear=expiresAt") == .forbidden)
    }

    @Test func sourceCantBeChosen() {
        #expect(errorCode("liova://activity/start?id=a&title=T&source=system.battery") == .badRequest)
        #expect(errorCode("liova://activity/start?id=a&title=T&source=evil") == .badRequest)
    }

    // MARK: Malicious and malformed URLs

    @Test(arguments: [
        "https://activity/start?id=a&title=T", // Wrong scheme.
        "liova://evil/start?id=a&title=T", // Unknown host.
        "liova://activity/delete?id=a", // Unknown action.
        "liova://activity/start/extra?id=a&title=T",
        "liova://activity?id=a&title=T", // No action.
        "liova:activity/start?id=a&title=T", // No host.
        "liova://activity/start?title=T", // Missing ID.
        "liova://activity/start?id=a", // Missing title.
        "liova://activity/start?id=a&title=", // Empty title.
        "liova://activity/start?id=a&id=b&title=T", // Duplicate parameter.
        "liova://activity/start?id=a&title=T&color=red", // Unknown parameter.
        "liova://activity/start?id=../../etc/passwd&title=T", // Path traversal in the ID.
        "liova://activity/start?id=a&title=line%0Abreak", // Control characters.
        "liova://activity/start?id=a&title=T&symbol=..%2Fx",
        "liova://activity/start?id=a&title=T&progress=2",
        "liova://activity/start?id=a&title=T&progress=-0.1",
        "liova://activity/start?id=a&title=T&tint=chartreuse",
        "liova://activity/start?id=a&title=T&priority=urgent",
        "liova://activity/start?id=a&title=T&priority=-5",
        "liova://activity/update?id=a&clear=title",
        "liova://activity/end?id=a&source=cli",
        "liova://activity/end",
    ])
    func malformedURLsAreBadRequests(url: String) {
        #expect(errorCode(url) == .badRequest)
    }

    @Test func credentialsAndPortsAreRejected() {
        #expect(errorCode("liova://user:pass@activity/start?id=a&title=T") == .badRequest)
        #expect(errorCode("liova://activity:8080/start?id=a&title=T") == .badRequest)
    }

    @Test func oversizedURLIsTooLarge() {
        let title = String(repeating: "a", count: LiovaURL.maxURLLength)
        #expect(errorCode("liova://activity/start?id=a&title=\(title)") == .tooLarge)
    }

    @Test func longTitleWithinTheURLLimitStillFailsValidation() {
        let title = String(repeating: "a", count: LiovaValidation.maxTitleLength + 1)
        #expect(errorCode("liova://activity/start?id=a&title=\(title)") == .badRequest)
    }

    @Test func errorMessagesTruncateHostileInput() {
        let junk = String(repeating: "z", count: 1000)
        do {
            _ = try command("liova://activity/\(junk)?id=a")
            Issue.record("Expected an error")
        } catch {
            #expect(error.message.count < 200)
        }
    }
}
