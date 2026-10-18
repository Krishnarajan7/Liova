import Darwin
import Foundation
@testable import LiovaIPC
import Testing

/// A throwaway home-like directory. Never touches the real `~/.codex`, `~/.gemini` or `~/.cursor`.
struct TemporaryAgentHome {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("liova-agents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(_ agent: AgentKind) -> URL {
        agent.defaultSettingsURL(homeDirectory: directory.path(percentEncoded: false))
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) throws -> String {
        try #require(String(bytes: Data(contentsOf: url), encoding: .utf8))
    }

    func json(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func files(besides url: URL) -> [String] {
        let folder = url.deletingLastPathComponent().path(percentEncoded: false)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Codex, Gemini CLI and Cursor installers")
struct AgentMultiInstallerTests {
    static let binary = "/Applications/Liova.app/Contents/MacOS/liova"
    static let others: [AgentKind] = [.codex, .geminiCLI, .cursor]

    /// A realistic existing file per agent, with someone else's hooks and unrelated settings.
    static func existing(_ agent: AgentKind) -> String {
        switch agent {
        case .codex:
            """
            {"hooks": {"PreToolUse": [{"matcher": "^Bash$", "hooks": [
              {"type": "command", "command": "python3 ~/.codex/hooks/guard.py", "timeout": 30,
               "statusMessage": "Checking command"}]}],
              "Stop": [{"hooks": [{"type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff"}]}]}}
            """
        case .geminiCLI:
            """
            {"general": {"vimMode": true}, "model": {"name": "gemini-2.5-pro"},
             "mcpServers": {"github": {"command": "npx", "args": ["-y", "@mcp/github"]}},
             "hooksConfig": {"notifications": true},
             "hooks": {"BeforeTool": [{"matcher": "write_file|replace", "hooks": [
               {"name": "security-check", "type": "command", "command": "~/.gemini/hooks/security.sh",
                "timeout": 5000}]}]}}
            """
        case .cursor:
            """
            {"version": 1, "hooks": {
              "beforeShellExecution": [{"command": "./hooks/audit.sh"}],
              "stop": [{"command": "./hooks/notify.sh", "timeout": 10}]},
             "extraTopLevel": {"keep": [1, 2.50, "x"]}}
            """
        case .claudeCode:
            "{}"
        }
    }

    /// The foreign command in ``existing(_:)``, which must survive everything.
    static func foreignCommand(_ agent: AgentKind) -> String {
        switch agent {
        case .codex: "python3 ~/.codex/hooks/guard.py"
        case .geminiCLI: "~/.gemini/hooks/security.sh"
        case .cursor: "./hooks/audit.sh"
        case .claudeCode: ""
        }
    }

    static func events(_ agent: AgentKind) -> [String] {
        switch agent {
        case .codex: [
                "SessionStart",
                "UserPromptSubmit",
                "PreToolUse",
                "PostToolUse",
                "PermissionRequest",
                "Stop",
                "SessionEnd",
            ]
        case .geminiCLI: [
                "SessionStart",
                "BeforeAgent",
                "BeforeTool",
                "AfterTool",
                "Notification",
                "AfterAgent",
                "SessionEnd",
            ]
        case .cursor: [
                "sessionStart",
                "beforeSubmitPrompt",
                "preToolUse",
                "postToolUse",
                "postToolUseFailure",
                "stop",
                "sessionEnd",
            ]
        case .claudeCode: []
        }
    }

    @Test(arguments: others)
    func freshInstallCreatesTheFile(agent: AgentKind) throws {
        let home = try TemporaryAgentHome()
        defer { home.remove() }
        let installer = home.installer(agent)
        let plan = try installer.plan(.install)
        #expect(plan.original == nil)
        #expect(plan.changes.map(\.kind) == Array(repeating: .added, count: Self.events(agent).count))
        try installer.apply(plan)
        let json = try home.json(home.url(agent))
        let command = "\(Self.binary) hook \(agent.rawValue)"
        #expect(registeredCommands(json) ==
            Dictionary(uniqueKeysWithValues: Self.events(agent).map { ($0, [command]) }))
        #expect(try installer.status() == AgentHookStatus(state: .installed, commands: [command]))
        if agent == .cursor {
            #expect(try home.read(home.url(agent)).hasPrefix("{\n  \"version\": 1,"))
        }
    }

    @Test func handlerShapesMatchEachAgentsFormat() throws {
        let home = try TemporaryAgentHome()
        defer { home.remove() }
        for agent in Self.others {
            try home.installer(agent).apply(home.installer(agent).plan(.install))
        }
        let codex = try #require(try home.json(home.url(.codex))["hooks"] as? [String: Any])
        let permission = try #require((codex["PermissionRequest"] as? [[String: Any]])?.first)
        #expect(permission["matcher"] as? String == "*")
        let handler = try #require((permission["hooks"] as? [[String: Any]])?.first)
        #expect(handler["timeout"] as? Int == 310)
        let sessionEnd = try #require((codex["SessionEnd"] as? [[String: Any]])?.first)
        #expect((sessionEnd["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int == 3)
        #expect(sessionEnd["matcher"] == nil)

        let gemini = try #require(try home.json(home.url(.geminiCLI))["hooks"] as? [String: Any])
        let beforeTool = try #require((gemini["BeforeTool"] as? [[String: Any]])?.first)
        let geminiHandler = try #require((beforeTool["hooks"] as? [[String: Any]])?.first)
        #expect(beforeTool["matcher"] as? String == "*")
        #expect(geminiHandler["name"] as? String == "liova")
        #expect(geminiHandler["timeout"] as? Int == 5000)

        let cursor = try home.json(home.url(.cursor))
        #expect(cursor["version"] as? Int == 1)
        let stop = try #require(((cursor["hooks"] as? [String: Any])?["stop"] as? [[String: Any]])?.first)
        #expect(stop.keys.sorted() == ["command", "timeout"])
        #expect(stop["timeout"] as? Int == 5)
    }

    @Test(arguments: others)
    func installKeepsForeignContentAndUninstallRestoresIt(agent: AgentKind) throws {
        let home = try TemporaryAgentHome()
        defer { home.remove() }
        let url = home.url(agent)
        try home.write(Self.existing(agent), to: url)
        let before = try home.json(url)
        let installer = home.installer(agent)
        let result = try installer.apply(installer.plan(.install), now: Date(timeIntervalSince1970: 1_800_000_000))
        let backup = try #require(result.backupURL)
        #expect(try home.read(backup) == Self.existing(agent))

        let installed = try home.json(url)
        #expect(registeredCommands(installed).values.flatMap(\.self).contains(Self.foreignCommand(agent)))
        for (key, value) in before where key != "hooks" {
            #expect(installed[key] as? NSObject == value as? NSObject, "\(key) changed")
        }

        try installer.apply(installer.plan(.uninstall), now: Date(timeIntervalSince1970: 1_800_000_100))
        let restored = try home.json(url)
        #expect(restored as NSDictionary == before as NSDictionary)
    }

    @Test(arguments: others)
    func reinstallIsIdempotentAndMovingTheBinaryUpdatesInPlace(agent: AgentKind) throws {
        let home = try TemporaryAgentHome()
        defer { home.remove() }
        let url = home.url(agent)
        try home.write(Self.existing(agent), to: url)
        let old = home.installer(agent, binary: "/old/place/liova")
        try old.apply(old.plan(.install))
        let first = try home.read(url)
        let again = try old.plan(.install)
        #expect(!again.needsWrite)
        #expect(again.changes.allSatisfy { $0.kind == .unchanged })
        #expect(try home.read(url) == first)

        let moved = home.installer(agent, binary: "/Applications/My Apps/Liova.app/Contents/MacOS/liova")
        #expect(try moved.status().state == .outdated)
        let plan = try moved.plan(.install)
        #expect(plan.changes.allSatisfy { $0.kind == .updated })
        try moved.apply(plan)
        let commands = try registeredCommands(home.json(url)).values.flatMap(\.self)
        #expect(commands.filter { $0.contains("hook \(agent.rawValue)") }.count == Self.events(agent).count)
        #expect(commands.allSatisfy { !$0.contains("/old/place") })
        #expect(try moved.status().state == .installed)
    }

    @Test(arguments: others)
    func invalidFilesAreRefusedAndLeftUntouched(agent: AgentKind) throws {
        let home = try TemporaryAgentHome()
        defer { home.remove() }
        let url = home.url(agent)
        let broken = "{\"hooks\": {},}\n// a comment\n"
        try home.write(broken, to: url)
        for operation in [AgentInstallPlan.Operation.install, .uninstall] {
            #expect(throws: AgentInstallerError.self) { try home.installer(agent).plan(operation) }
        }
        #expect(throws: AgentInstallerError.self) { try home.installer(agent).status() }
        #expect(try home.read(url) == broken)
        #expect(home.files(besides: url) == [url.lastPathComponent])
    }

    @Test(arguments: [
        (AgentKind.codex, #"{"hooks": []}"#),
        (.geminiCLI, #"{"hooks": {"BeforeTool": {"matcher": "*"}}}"#),
        (.cursor, #"{"version": 2, "hooks": {}}"#),
        (.cursor, #"{"version": "1", "hooks": {}}"#),
        (.cursor, #"{"version": 1, "hooks": {"stop": {"command": "x"}}}"#),
        (.cursor, #"["not", "an", "object"]"#),
    ])
    func unexpectedShapesAreRefused(agent: AgentKind, text: String) throws {
        let home = try TemporaryAgentHome()
        defer { home.remove() }
        try home.write(text, to: home.url(agent))
        #expect(throws: AgentInstallerError.self) { try home.installer(agent).plan(.install) }
        #expect(try home.read(home.url(agent)) == text)
    }

    @Test(arguments: others)
    func dryRunWritesNothing(agent: AgentKind) throws {
        let home = try TemporaryAgentHome()
        defer { home.remove() }
        let url = home.url(agent)
        let fresh = try home.installer(agent).plan(.install)
        #expect(fresh.needsWrite)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        let report = AgentCLIOutput.report(for: fresh, agent: agent, result: nil, dryRun: true)
        #expect(report.contains("Dry run: nothing was written."))
        #expect(report.contains("(new file)"))

        try home.write(Self.existing(agent), to: url)
        let plan = try home.installer(agent).plan(.install)
        #expect(plan.needsWrite)
        #expect(try home.read(url) == Self.existing(agent))
        #expect(home.files(besides: url) == [url.lastPathComponent])
    }

    @Test(arguments: others)
    func uninstallWithoutOurHooksChangesNothing(agent: AgentKind) throws {
        let home = try TemporaryAgentHome()
        defer { home.remove() }
        #expect(try !home.installer(agent).plan(.uninstall).needsWrite)
        try home.write(Self.existing(agent), to: home.url(agent))
        let plan = try home.installer(agent).plan(.uninstall)
        #expect(!plan.needsWrite)
        #expect(try home.installer(agent).status().state == .notInstalled)
    }
}

extension TemporaryAgentHome {
    func installer(_ agent: AgentKind, binary: String = AgentMultiInstallerTests.binary) -> AgentHookInstaller {
        AgentHookInstaller(agent: agent, settingsURL: url(agent), executablePath: binary)
    }
}

/// Every command registered per event, flattening matcher groups where the format has them.
func registeredCommands(_ json: [String: Any]) -> [String: [String]] {
    let hooks = json["hooks"] as? [String: Any] ?? [:]
    var result: [String: [String]] = [:]
    for (event, value) in hooks {
        let entries = value as? [[String: Any]] ?? []
        result[event] = entries.flatMap { entry -> [String] in
            if let handlers = entry["hooks"] as? [[String: Any]] {
                return handlers.compactMap { $0["command"] as? String }
            }
            return (entry["command"] as? String).map { [$0] } ?? []
        }
    }
    return result
}
