import Darwin
import Foundation
import LiovaIPC

/// Runs `liova hook ...` and `liova agents ...`: the I/O around LiovaIPC's pure pieces.
enum AgentCommandRunner {
    private static let debugEnabled = AgentHookRunner.isDebugEnabled(ProcessInfo.processInfo.environment)

    /// Writes to stderr only when `LIOVA_HOOK_DEBUG` is set.
    static func debugLog(_ message: String) {
        guard debugEnabled else { return }
        FileHandle.standardError.write(Data("liova hook: \(message)\n".utf8))
    }

    // MARK: liova hook

    /// Always returns 0: a hook must never fail, block or slow down the agent.
    static func runHook(_ options: AgentHookOptions) -> Int32 {
        // If the agent stops reading our stdout, a write must fail quietly, not kill us.
        signal(SIGPIPE, SIG_IGN)
        let socketURL = options.socketPath.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? IPCPaths.defaultSocketURL
        var runner = AgentHookRunner(
            agent: options.agent,
            socketURL: socketURL,
            permissionTimeout: options.permissionTimeout
        )
        if debugEnabled {
            runner.log = { message in debugLog(message) }
        }
        if options.statusLine {
            return runStatusLine(options, runner: runner)
        }
        if let output = runner.run(input: input(for: options)) {
            FileHandle.standardOutput.write(Data((output + "\n").utf8))
        }
        return CLIOutput.ExitCode.success.rawValue
    }

    /// Claude Code's status line: tell Liova the usage, then print the user's own status
    /// line (theirs runs with the same input) or, if they had none, a short one.
    private static func runStatusLine(_ options: AgentHookOptions, runner: AgentHookRunner) -> Int32 {
        let input = AgentHookInput.read()
        runner.reportUsage(input: input)
        guard let input else { return CLIOutput.ExitCode.success.rawValue }
        guard let command = options.thenCommand else {
            FileHandle.standardOutput.write(Data((ClaudeCodeStatusLine.defaultLine(from: input) + "\n").utf8))
            return CLIOutput.ExitCode.success.rawValue
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe()
        process.standardInput = stdin
        // Its output goes straight to ours, which is what Claude Code reads.
        do {
            try process.run()
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {
            debugLog("Couldn't run the original status line: \(error.localizedDescription)")
        }
        return CLIOutput.ExitCode.success.rawValue
    }

    /// The hook payload: the argument Codex's `notify` passes, or else stdin. With an argument,
    /// stdin is never touched (it may be an inherited terminal or a pipe nobody closes).
    private static func input(for options: AgentHookOptions) -> Data? {
        guard let payload = options.payload else { return AgentHookInput.read() }
        let data = Data(payload.utf8)
        return data.count <= AgentHookRunner.maxInputBytes ? data : nil
    }

    // MARK: liova agents

    static func run(_ request: AgentsRequest) -> Int32 {
        switch request {
        case let .install(agent, settingsPath, dryRun):
            change(.install, agent: agent, settingsPath: settingsPath, dryRun: dryRun)
        case let .uninstall(agent, settingsPath, dryRun):
            change(.uninstall, agent: agent, settingsPath: settingsPath, dryRun: dryRun)
        case let .status(agent, settingsPath):
            status(agents: agent.map { [$0] } ?? AgentKind.allCases, settingsPath: settingsPath)
        case let .usage(enabled, settingsPath):
            usage(enabled: enabled, settingsPath: settingsPath)
        }
    }

    private static func usage(enabled: Bool, settingsPath: String?) -> Int32 {
        guard let executable = AgentExecutable.currentPath() else {
            CLIRunner.writeError("liova: error: Couldn't find the path of the liova binary.\n")
            return CLIOutput.ExitCode.serverError.rawValue
        }
        let settingsURL = settingsPath.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL
        }
        let installer = ClaudeCodeUsageInstaller(settingsURL: settingsURL, executablePath: executable)
        do {
            let plan = try installer.plan(enabled ? .install : .uninstall)
            try installer.apply(plan)
            let path = plan.targetURL.path(percentEncoded: false)
            if !plan.needsWrite {
                print("Nothing to change in \(path).")
            } else if enabled {
                print("Claude Code's usage will show in the notch. Changed the status line in \(path).")
                print("Start a new Claude Code session to pick it up.")
            } else {
                print("Removed Liova's status line from \(path).")
            }
            return CLIOutput.ExitCode.success.rawValue
        } catch {
            CLIRunner.writeError("liova: error: \(error.description)\n")
            return CLIOutput.ExitCode.serverError.rawValue
        }
    }

    private static func change(
        _ operation: AgentInstallPlan.Operation,
        agent: AgentKind,
        settingsPath: String?,
        dryRun: Bool
    ) -> Int32 {
        guard let installer = installer(for: agent, settingsPath: settingsPath) else {
            return CLIOutput.ExitCode.serverError.rawValue
        }
        if operation == .install {
            if let problem = AgentExecutable.installProblem(for: installer.executablePath) {
                CLIRunner.writeError("liova: error: \(problem)\n")
                return CLIOutput.ExitCode.serverError.rawValue
            }
            if let warning = AgentExecutable.installWarning(for: installer.executablePath) {
                CLIRunner.writeError("liova: warning: \(warning)\n")
            }
        }
        do {
            let plan = try installer.plan(operation)
            let result = dryRun ? nil : try installer.apply(plan)
            print(AgentCLIOutput.report(for: plan, agent: agent, result: result, dryRun: dryRun))
            if operation == .install {
                for warning in installer.warnings() {
                    CLIRunner.writeError("liova: warning: \(warning)\n")
                }
            }
            return CLIOutput.ExitCode.success.rawValue
        } catch {
            CLIRunner.writeError("liova: error: \(error.description)\n")
            return CLIOutput.ExitCode.serverError.rawValue
        }
    }

    /// Reports every agent in `agents`; one unreadable file doesn't hide the others.
    private static func status(agents: [AgentKind], settingsPath: String?) -> Int32 {
        var allInstalled = true
        for agent in agents {
            guard let installer = installer(for: agent, settingsPath: settingsPath) else {
                return CLIOutput.ExitCode.serverError.rawValue
            }
            do {
                let status = try installer.status()
                allInstalled = allInstalled && status.state == .installed
                let path = installer.settingsURL.path(percentEncoded: false)
                print(AgentCLIOutput.status(status, agent: agent, settingsPath: path))
            } catch {
                allInstalled = false
                print("\(agent.displayName): unknown")
                CLIRunner.writeError("liova: error: \(error.description)\n")
            }
        }
        return allInstalled ? CLIOutput.ExitCode.success.rawValue : CLIOutput.ExitCode.serverError.rawValue
    }

    private static func installer(for agent: AgentKind, settingsPath: String?) -> AgentHookInstaller? {
        guard let executable = AgentExecutable.currentPath() else {
            CLIRunner.writeError("liova: error: Couldn't find the path of the liova binary.\n")
            return nil
        }
        let settingsURL = settingsPath.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL
        }
        return AgentHookInstaller(agent: agent, settingsURL: settingsURL, executablePath: executable)
    }
}
