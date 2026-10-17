import Foundation
@testable import LiovaIPC
import LiovaPluginKit
import Testing

@Suite("CLI parsing")
struct CLIParserTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func parse(_ line: String) throws(CLIUsageError) -> CLIInvocation {
        try CLIParser.parse(split(line), now: now)
    }

    /// Splits like a shell would for these simple test lines: spaces separate words, and
    /// single quotes group them.
    private func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        var hasWord = false
        for character in line {
            if character == "'" {
                quoted.toggle()
                hasWord = true
            } else if character == " ", !quoted {
                if hasWord {
                    words.append(current)
                }
                current = ""
                hasWord = false
            } else {
                current.append(character)
                hasWord = true
            }
        }
        if hasWord {
            words.append(current)
        }
        return words
    }

    private func sent(_ line: String) throws -> (IPCCommand, CLIOptions) {
        guard case let .send(command, options) = try parse(line) else {
            throw CLIUsageError("Expected a command to send for: \(line)")
        }
        return (command, options)
    }

    private func command(_ line: String) throws -> IPCCommand {
        try sent(line).0
    }

    private func usageError(_ line: String) -> CLIUsageError? {
        do {
            _ = try parse(line)
            return nil
        } catch {
            return error
        }
    }

    // MARK: Help and version

    @Test(arguments: ["", "--help", "-h", "help"])
    func mainHelp(line: String) throws {
        if line.isEmpty {
            let error = try #require(usageError(line))
            #expect(error.usage == CLIHelp.main)
            #expect(error.message == "Missing command.")
        } else {
            #expect(try parse(line) == .showHelp(CLIHelp.main))
        }
    }

    @Test(arguments: [
        ("ping --help", CLIHelp.ping),
        ("activity --help", CLIHelp.activity),
        ("activity start --help", CLIHelp.start),
        ("activity update -h", CLIHelp.update),
        ("activity end --help", CLIHelp.end),
        ("activity list --help", CLIHelp.list),
        ("help activity", CLIHelp.activity),
        ("help activity start", CLIHelp.start),
        ("help ping", CLIHelp.ping),
        ("--help activity end", CLIHelp.end),
        // --help wins over missing or invalid values.
        ("activity start --help --progress 7", CLIHelp.start),
    ])
    func commandHelp(line: String, expected: String) throws {
        #expect(try parse(line) == .showHelp(expected))
    }

    @Test(arguments: ["--version", "ping --version", "activity start --version"])
    func version(line: String) throws {
        #expect(try parse(line) == .showVersion)
    }

    // MARK: Commands

    @Test func ping() throws {
        let (command, options) = try sent("ping")
        #expect(command == .ping)
        #expect(options == CLIOptions())
    }

    @Test func list() throws {
        #expect(try command("activity list") == .list)
    }

    @Test func startWithEveryOption() throws {
        let line = "activity start --id build --title 'Deploying app' --subtitle=staging --symbol hammer.fill "
            + "--progress 40% --tint Blue --priority high --ttl 10m --source ci"
        #expect(try command(line) == .start(Activity(
            id: "build",
            source: "ci",
            priority: .high,
            title: "Deploying app",
            subtitle: "staging",
            symbol: "hammer.fill",
            progress: 0.4,
            tint: .blue,
            expiresAt: now.addingTimeInterval(600)
        )))
    }

    @Test func startDefaults() throws {
        #expect(try command("activity start --id a --title Hi") == .start(Activity(
            id: "a",
            source: "cli",
            title: "Hi"
        )))
    }

    @Test func startWithoutIDUsesTheSource() throws {
        #expect(try command("activity start --title Hi") == .start(Activity(id: "cli", source: "cli", title: "Hi")))
        #expect(try command("activity start --title Hi --source ci") == .start(Activity(
            id: "ci",
            source: "ci",
            title: "Hi"
        )))
    }

    @Test(arguments: [
        ("low", ActivityPriority.low),
        ("NORMAL", .normal),
        ("high", .high),
        ("critical", .critical),
        ("250", ActivityPriority(rawValue: 250)),
        ("0", ActivityPriority(rawValue: 0)),
    ])
    func priorities(text: String, expected: ActivityPriority) throws {
        guard case let .start(activity) = try command("activity start --id a --title T --priority \(text)") else {
            Issue.record("Expected start")
            return
        }
        #expect(activity.priority == expected)
    }

    @Test(arguments: [
        ("30", 30.0), ("90s", 90), ("1.5m", 90), ("2h", 7200), ("1d", 86400), ("500ms", 0.5), (" 5S ", 5),
    ])
    func durations(text: String, seconds: TimeInterval) {
        #expect(CLIValues.duration(text) == seconds)
    }

    @Test(arguments: ["0", "-1", "abc", "", "5x", "nan", "inf", "m"])
    func invalidDurations(text: String) {
        #expect(CLIValues.duration(text) == nil)
    }

    @Test(arguments: [("0", 0.0), ("1", 1), ("0.25", 0.25), ("40%", 0.4), ("100%", 1)])
    func progressValues(text: String, value: Double) {
        #expect(CLIValues.progress(text) == value)
    }

    @Test func updateWithFieldsAndClear() throws {
        let line = "activity update --id build --progress 0.75 --title Linking --ttl 30 --clear subtitle,symbol"
        #expect(try command(line) == .update(ActivityPatch(
            id: "build",
            title: "Linking",
            progress: 0.75,
            expiresAt: now.addingTimeInterval(30),
            clear: [.subtitle, .symbol]
        )))
    }

    @Test func updateClearAcceptsAliasesAndSpaces() throws {
        let command = try command("activity update --id a --clear 'progress, ttl'")
        #expect(command == .update(ActivityPatch(id: "a", clear: [.progress, .expiresAt])))
    }

    @Test func endByIDOrSource() throws {
        #expect(try command("activity end --id build") == .end("build"))
        #expect(try command("activity end --source ci") == .endAll(source: "ci"))
    }

    @Test func globalOptions() throws {
        let (_, options) = try sent("--json activity list --socket /tmp/x.sock --timeout 2.5s")
        #expect(options == CLIOptions(json: true, socketPath: "/tmp/x.sock", timeout: 2.5))
    }

    @Test func doubleDashEndsOptions() throws {
        let error = try #require(usageError("activity list -- --json"))
        #expect(error.message.contains("Unexpected argument '--json'"))
    }

    @Test func valuesMayStartWithASingleDash() throws {
        guard case let .start(activity) = try command("activity start --id a --title -5") else {
            Issue.record("Expected start")
            return
        }
        #expect(activity.title == "-5")
    }

    @Test func valuesStartingWithDoubleDashNeedTheEqualsForm() throws {
        guard case let .start(activity) = try command("activity start --id a --title=--json") else {
            Issue.record("Expected start")
            return
        }
        #expect(activity.title == "--json")
        #expect(usageError("activity start --id a --title --json")?.message == "--title needs a value.")
    }

    // MARK: Usage errors

    @Test(arguments: [
        ("bogus", "Unknown command 'bogus'.", "liova"),
        ("pign", "Did you mean 'ping'?", "liova"),
        ("activity", "Missing subcommand", "liova activity"),
        ("activity strat --title T", "Did you mean 'start'?", "liova activity"),
        ("activity start", "Missing required option --title.", "liova activity start"),
        ("activity start --title", "--title needs a value.", "liova"),
        ("activity start --title T --title U", "--title was given more than once.", "liova"),
        ("activity start --title T --clear progress", "has no option --clear", "liova activity start"),
        ("activity start --title T --progress 1.5", "--progress must be a number from 0 to 1", "liova activity start"),
        ("activity start --title T --progress abc", "--progress must be", "liova activity start"),
        ("activity start --title T --priority urgent", "--priority must be low, normal", "liova activity start"),
        ("activity start --title T --priority 5000", "'priority' must be", "liova activity start"),
        ("activity start --title T --tint chartreuse", "Unknown --tint 'chartreuse'", "liova activity start"),
        ("activity start --title T --ttl soon", "--ttl must be a positive duration", "liova activity start"),
        ("activity start --title T --source system.battery", "reserved", "liova activity start"),
        ("activity start --title T --id 'a b'", "'id' must be", "liova activity start"),
        ("activity start --title '   '", "'title' must not be empty", "liova activity start"),
        ("activity start --title T --symbol ../x", "'symbol' must be", "liova activity start"),
        ("activity start --title T extra", "Unexpected argument 'extra'", "liova activity start"),
        ("activity start --titel T", "Did you mean '--title'?", "liova"),
        ("activity start -t T", "Unknown option '-t'", "liova"),
        ("activity update", "Missing required option --id.", "liova activity update"),
        ("activity update --id a", "Nothing to update", "liova activity update"),
        ("activity update --id a --clear title", "Can't clear 'title'", "liova activity update"),
        ("activity update --id a --clear ,", "--clear needs a comma-separated list", "liova activity update"),
        ("activity update --id a --progress 0.5 --clear progress", "can't both set and clear", "liova activity update"),
        ("activity update --id a --source ci --title T", "has no option --source", "liova activity update"),
        ("activity end", "Missing --id", "liova activity end"),
        ("activity end --id a --source b", "either --id or --source", "liova activity end"),
        ("activity end --source system", "reserved", "liova activity end"),
        ("activity list --id a", "has no option --id", "liova activity list"),
        ("ping --json=yes", "--json doesn't take a value.", "liova"),
        ("ping --timeout 0", "--timeout must be a duration", "liova ping"),
        ("ping --timeout 11m", "--timeout must be a duration", "liova ping"),
        ("ping --socket=", "--socket needs a path.", "liova ping"),
        ("help bogus", "Unknown command 'bogus'.", "liova"),
    ])
    func usageErrors(line: String, message: String, command: String) throws {
        let error = try #require(usageError(line), "Expected a usage error for: \(line)")
        #expect(error.message.contains(message), "Got: \(error.message)")
        #expect(error.command == command)
    }

    @Test func editDistance() {
        #expect(CLIParser.editDistance("", "abc") == 3)
        #expect(CLIParser.editDistance("ping", "ping") == 0)
        #expect(CLIParser.editDistance("pign", "ping") == 2)
        #expect(CLIParser.editDistance("titel", "title") == 2)
        #expect(CLIParser.editDistance("kitten", "sitting") == 3)
    }
}
