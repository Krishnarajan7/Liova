import Darwin
import Foundation
@testable import LiovaIPC
import Testing

/// A throwaway directory for a settings file. Never touches the real `~/.claude`.
struct TemporarySettings {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("liova-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var settingsURL: URL {
        directory.appendingPathComponent(".claude/settings.json")
    }

    func write(_ text: String, mode: mode_t = 0o644) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: settingsURL)
        chmod(settingsURL.path(percentEncoded: false), mode)
    }

    func read() throws -> String {
        try contents(of: settingsURL)
    }

    func contents(of url: URL) throws -> String {
        try #require(String(bytes: Data(contentsOf: url), encoding: .utf8))
    }

    func json() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
    }

    func files() -> [String] {
        let folder = settingsURL.deletingLastPathComponent().path(percentEncoded: false)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Claude Code hook installer")
struct AgentInstallerTests {
    static let binary = "/Applications/Liova.app/Contents/MacOS/liova"
    static let command = "/Applications/Liova.app/Contents/MacOS/liova hook claude-code"
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Notification", "Stop", "SessionEnd",
    ]

    static let existing = """
    {
      "model": "claude-opus-4-1",
      "env": {"EDITOR": "vim", "RATIO": 0.10},
      "permissions": {"allow": ["Bash(npm test:*)"], "deny": []},
      "hooks": {
        "PreToolUse": [
          {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/audit.sh", "timeout": 30}]}
        ],
        "Stop": [{"hooks": [{"type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff"}]}],
        "PreCompact": [{"hooks": [{"type": "command", "command": "echo compacting"}]}]
      },
      "statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}
    }
    """

    private func installer(_ temp: TemporarySettings, binary: String = binary) -> ClaudeCodeHookInstaller {
        ClaudeCodeHookInstaller(settingsURL: temp.settingsURL, executablePath: binary)
    }

    /// Commands registered per event, in order.
    private func commands(_ json: [String: Any]) -> [String: [String]] {
        let hooks = json["hooks"] as? [String: Any] ?? [:]
        return hooks.mapValues { groups in
            (groups as? [[String: Any]] ?? []).flatMap { group in
                (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
            }
        }
    }

    @Test func freshInstallCreatesTheFileAndDirectory() throws {
        let temp = try TemporarySettings()
        defer { temp.remove() }
        let installer = installer(temp)
        let plan = try installer.plan(.install)
        #expect(plan.original == nil)
        #expect(plan.changes.map(\.kind) == Array(repeating: .added, count: 8))
        let result = try installer.apply(plan)
        #expect(result.written)
        #expect(result.backupURL == nil)
        #expect(temp.files() == ["settings.json"])
        #expect(permissions(of: temp.settingsURL.path(percentEncoded: false)) == 0o600)

        let json = try temp.json()
        #expect(commands(json) == Dictionary(uniqueKeysWithValues: Self.events.map { ($0, [Self.command]) }))
        let hooks = try #require(json["hooks"] as? [String: [[String: Any]]])
        for event in Self.events {
            let handler = try #require((hooks[event]?.first?["hooks"] as? [[String: Any]])?.first)
            #expect(handler["type"] as? String == "command")
            #expect(handler["timeout"] as? Int == (event == "PermissionRequest" ? 310 : 5))
            let isToolEvent = ["PreToolUse", "PostToolUse", "PermissionRequest"].contains(event)
            #expect(hooks[event]?.first?["matcher"] as? String == (isToolEvent ? "*" : nil))
        }
        #expect(try installer.status() == AgentHookStatus(state: .installed, commands: [Self.command]))
    }

    @Test func installPreservesUnrelatedKeysAndOtherHooks() throws {
        let temp = try TemporarySettings()
        defer { temp.remove() }
        try temp.write(Self.existing, mode: 0o640)
        let installer = installer(temp)
        try installer.apply(installer.plan(.install))

        let text = try temp.read()
        let json = try temp.json()
        #expect((json["env"] as? [String: Any])?["EDITOR"] as? String == "vim")
        #expect(text.contains(#""RATIO": 0.10"#), "Number literals are kept as written")
        #expect((json["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(npm test:*)"])
        #expect((json["statusLine"] as? [String: Any])?["command"] as? String == "~/.claude/statusline.sh")
        let commands = commands(json)
        #expect(commands["PreToolUse"] == ["~/bin/audit.sh", Self.command])
        #expect(commands["Stop"] == ["afplay /System/Library/Sounds/Glass.aiff", Self.command])
        #expect(commands["PreCompact"] == ["echo compacting"])
        // Original key order is kept; new events are appended.
        let keys = try OrderedJSON.parse(Data(text.utf8)).members?.map(\.key)
        #expect(keys == ["model", "env", "permissions", "hooks", "statusLine"])
        #expect(permissions(of: temp.settingsURL.path(percentEncoded: false)) == 0o640)
    }

    @Test func backupHoldsTheExactPreviousBytes() throws {
        let temp = try TemporarySettings()
        defer { temp.remove() }
        try temp.write(Self.existing, mode: 0o600)
        let installer = installer(temp)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try installer.apply(installer.plan(.install), now: date)
        let backup = try #require(first.backupURL)
        #expect(backup.lastPathComponent == ClaudeCodeHookInstaller.backupName(for: "settings.json", at: date))
        #expect(backup.lastPathComponent.hasPrefix("settings.json.liova-backup-2027"))
        #expect(try temp.contents(of: backup) == Self.existing)
        #expect(permissions(of: backup.path(percentEncoded: false)) == 0o600)

        // A second write in the same second never overwrites the first backup.
        let second = try installer.apply(installer.plan(.uninstall), now: date)
        #expect(try #require(second.backupURL).lastPathComponent == backup.lastPathComponent + "-2")
        #expect(try temp.contents(of: backup) == Self.existing)
    }

    @Test func reinstallIsIdempotent() throws {
        let temp = try TemporarySettings()
        defer { temp.remove() }
        try temp.write(Self.existing)
        let installer = installer(temp)
        try installer.apply(installer.plan(.install))
        let once = try temp.read()
        let filesAfterFirst = temp.files()

        let plan = try installer.plan(.install)
        #expect(!plan.needsWrite)
        #expect(plan.changes.allSatisfy { $0.kind == .unchanged })
        #expect(try installer.apply(plan) == AgentInstallResult(written: false, backupURL: nil))
        #expect(try temp.read() == once)
        #expect(temp.files() == filesAfterFirst, "No extra backup when nothing changes")
    }

    @Test func reinstallAfterTheBinaryMovedReplacesOurEntriesInPlace() throws {
        let temp = try TemporarySettings()
        defer { temp.remove() }
        try temp.write(Self.existing)
        let old = installer(temp, binary: "/old/place/liova")
        try old.apply(old.plan(.install))
        let moved = installer(temp, binary: "/Applications/My Apps/Liova.app/Contents/MacOS/liova")
        #expect(try moved.status().state == .outdated)

        let plan = try moved.plan(.install)
        #expect(plan.changes.allSatisfy { $0.kind == .updated })
        try moved.apply(plan)
        let expected = "'/Applications/My Apps/Liova.app/Contents/MacOS/liova' hook claude-code"
        let commands = try commands(temp.json())
        #expect(commands["PreToolUse"] == ["~/bin/audit.sh", expected])
        #expect(commands["Stop"] == ["afplay /System/Library/Sounds/Glass.aiff", expected])
        #expect(commands.values.allSatisfy { !$0.contains("/old/place/liova hook claude-code") })
        #expect(try moved.status().state == .installed)
    }

    @Test func uninstallRemovesOnlyOurHandlers() throws {
        let temp = try TemporarySettings()
        defer { temp.remove() }
        try temp.write(Self.existing)
        let installer = installer(temp)
        try installer.apply(installer.plan(.install))
        let plan = try installer.plan(.uninstall)
        #expect(plan.changes.count == 8)
        #expect(plan.changes.allSatisfy { $0.kind == .removed })
        try installer.apply(plan)

        let original = try OrderedJSON.parse(Data(Self.existing.utf8))
        #expect(try OrderedJSON.parse(Data(temp.read().utf8)) == original)
        #expect(try installer.status().state == .notInstalled)
        #expect(try !installer.plan(.uninstall).needsWrite)
    }

    @Test func uninstallOfAFreshInstallLeavesAnEmptyObject() throws {
        let temp = try TemporarySettings()
        defer { temp.remove() }
        let installer = installer(temp)
        try installer.apply(installer.plan(.install))
        try installer.apply(installer.plan(.uninstall))
        #expect(try temp.read() == "{}\n")
    }

    @Test func handlersSharingAGroupWithForeignHooksAreRemovedAlone() throws {
        let temp = try TemporarySettings()
        defer { temp.remove() }
        try temp.write("""
        {"hooks": {"Stop": [{"hooks": [
          {"type": "command", "command": "say done"},
          {"type": "command", "command": "/usr/local/bin/liova hook claude-code --timeout 60"},
          {"type": "command", "command": "liova hook claude-code"},
          {"type": "command", "command": "/opt/not-liova hook claude-code"},
          {"type": "command", "command": "echo liova hook claude-code"}
        ]}]}}
        """)
        let installer = installer(temp)
        try installer.apply(installer.plan(.uninstall))
        #expect(try commands(temp.json())["Stop"] == [
            "say done", "/opt/not-liova hook claude-code", "echo liova hook claude-code",
        ])
    }

    @Test func invalidJSONIsRefusedAndLeftUntouched() throws {
        let temp = try TemporarySettings()
        defer { temp.remove() }
        let broken = "{\n  \"model\": \"opus\",\n}\n"
        try temp.write(broken)
        let installer = installer(temp)
        #expect {
            try installer.plan(.install)
        } throws: { error in
            guard case let .invalidJSON(_, detail)? = error as? AgentInstallerError else { return false }
            return detail.contains("line 3")
        }
        #expect(throws: AgentInstallerError.self) { try installer.plan(.uninstall) }
        #expect(throws: AgentInstallerError.self) { try installer.status() }
        #expect(try temp.read() == broken)
        #expect(temp.files() == ["settings.json"])
    }

    @Test(arguments: [
        #"["not", "an", "object"]"#,
        #"{"hooks": []}"#,
        #"{"hooks": {"PreToolUse": {"matcher": "*"}}}"#,
    ])
    func unexpectedShapesAreRefused(text: String) throws {
        let temp = try TemporarySettings()
        defer { temp.remove() }
        try temp.write(text)
        #expect(throws: AgentInstallerError.self) { try installer(temp).plan(.install) }
        #expect(try temp.read() == text)
    }

    @Test func blankFileIsTreatedAsEmpty() throws {
        let temp = try TemporarySettings()
        defer { temp.remove() }
        try temp.write("  \n")
        let installer = installer(temp)
        let result = try installer.apply(installer.plan(.install))
        #expect(result.backupURL != nil)
        #expect(try installer.status().state == .installed)
    }

    @Test func dryRunWritesNothing() throws {
        let temp = try TemporarySettings()
        defer { temp.remove() }
        let fresh = try installer(temp).plan(.install)
        #expect(fresh.needsWrite)
        #expect(!FileManager.default.fileExists(atPath: temp.settingsURL.path(percentEncoded: false)))
        let folder = temp.settingsURL.deletingLastPathComponent().path(percentEncoded: false)
        #expect(!FileManager.default.fileExists(atPath: folder))

        try temp.write(Self.existing)
        let plan = try installer(temp).plan(.install)
        let report = AgentCLIOutput.report(for: plan, agent: .claudeCode, result: nil, dryRun: true)
        #expect(report.contains("Dry run: nothing was written."))
        #expect(report.contains("Add: SessionStart, UserPromptSubmit"))
        #expect(report.contains("Update") == false)
        #expect(report.contains(Self.command))
        #expect(try temp.read() == Self.existing)
        #expect(temp.files() == ["settings.json"])
    }

    @Test func symlinkedSettingsAreEditedAtTheTarget() throws {
        let temp = try TemporarySettings()
        defer { temp.remove() }
        let dotfiles = temp.directory.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("claude-settings.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createDirectory(
            at: temp.settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: temp.settingsURL.path(percentEncoded: false),
            withDestinationPath: "../dotfiles/claude-settings.json"
        )
        let installer = installer(temp)
        try installer.apply(installer.plan(.install))
        let link = try FileManager.default.destinationOfSymbolicLink(
            atPath: temp.settingsURL.path(percentEncoded: false)
        )
        #expect(link == "../dotfiles/claude-settings.json")
        #expect(try temp.contents(of: target).contains(Self.command))
    }
}

@Suite("Claude Code hook status and commands")
struct AgentInstallerStatusTests {
    private func installer(
        _ temp: TemporarySettings,
        binary: String = AgentInstallerTests.binary
    ) -> ClaudeCodeHookInstaller {
        ClaudeCodeHookInstaller(settingsURL: temp.settingsURL, executablePath: binary)
    }

    @Test func concurrentEditsAreNotClobbered() throws {
        let temp = try TemporarySettings()
        defer { temp.remove() }
        try temp.write(AgentInstallerTests.existing)
        let installer = installer(temp)
        let plan = try installer.plan(.install)
        try temp.write(#"{"model": "changed meanwhile"}"#)
        #expect(throws: AgentInstallerError.self) { try installer.apply(plan) }
        #expect(try temp.read() == #"{"model": "changed meanwhile"}"#)
    }

    @Test func statusReportsMissingEventsAndForeignBinaries() throws {
        let temp = try TemporarySettings()
        defer { temp.remove() }
        try temp.write("""
        {"hooks": {"Stop": [{"hooks": [
          {"type": "command", "command": "\(AgentInstallerTests.command)", "timeout": 5}
        ]}]}}
        """)
        let status = try installer(temp).status()
        #expect(status.state == .outdated)
        #expect(status.problems.first?.hasPrefix("Missing hooks for SessionStart, UserPromptSubmit") == true)
        let other = try installer(temp, binary: "/elsewhere/liova").status()
        #expect(other.problems.contains { $0.contains("not this liova") })
        let text = AgentCLIOutput.status(other, agent: .claudeCode, settingsPath: "/x/settings.json")
        #expect(text.hasPrefix("Claude Code: outdated (/x/settings.json)"))
        #expect(text.contains("liova agents install claude-code"))
    }

    @Test(arguments: [
        ("/Applications/Liova.app/Contents/MacOS/liova hook claude-code", true),
        ("'/Applications/My Apps/liova' hook claude-code", true),
        ("liova hook claude-code", true),
        ("/usr/local/bin/liova hook claude-code --timeout 60", true),
        ("/usr/local/bin/liova hook claude-codex", false),
        ("/usr/local/bin/liova activity start --title x", false),
        ("/opt/bin/liova-wrapper hook claude-code", false),
        ("echo liova hook claude-code", false),
        ("sh -c 'liova hook claude-code'", false),
    ])
    func recognisesOurCommands(command: String, isOurs: Bool) {
        #expect(ClaudeCodeSettingsEditor.isLiovaCommand(command) == isOurs)
    }

    @Test func pathsWithSpacesAreQuoted() {
        #expect(ClaudeCodeSettingsEditor.command(executablePath: "/Applications/My Apps/liova")
            == "'/Applications/My Apps/liova' hook claude-code")
        let command = ClaudeCodeSettingsEditor.command(executablePath: AgentInstallerTests.binary)
        #expect(command == AgentInstallerTests.command)
    }

    @Test func defaultSettingsPathIsInTheHomeDirectory() {
        #expect(ClaudeCodeHookInstaller.defaultSettingsURL(homeDirectory: "/Users/someone").path(percentEncoded: false)
            == "/Users/someone/.claude/settings.json")
    }

    @Test func executableChecks() {
        #expect(AgentExecutable.currentPath()?.hasPrefix("/") == true)
        #expect(AgentExecutable.installProblem(
            for: "/private/var/folders/x/AppTranslocation/ABC/d/Liova.app/Contents/MacOS/liova"
        ) != nil)
        #expect(AgentExecutable.installProblem(for: AgentInstallerTests.binary) == nil)
        #expect(AgentExecutable.installWarning(for: "/src/Liova/.build/debug/liova") != nil)
        #expect(AgentExecutable.installWarning(for: AgentInstallerTests.binary) == nil)
    }
}
