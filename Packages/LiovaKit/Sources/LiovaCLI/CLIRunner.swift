import Darwin
import Foundation
import LiovaIPC
import LiovaPluginKit

/// Parses arguments, talks to Liova and maps the outcome to output and an exit code.
enum CLIRunner {
    static func run(arguments: [String]) -> Int32 {
        let invocation: CLIInvocation
        do {
            invocation = try CLIParser.parse(arguments)
        } catch where CLIParser.isHookInvocation(arguments) {
            // Agents treat some exit codes as "block this action", so a broken hook command
            // line must never fail loudly. It is reported only when debugging.
            AgentCommandRunner.debugLog("Bad hook command line: \(error.message)")
            return CLIOutput.ExitCode.success.rawValue
        } catch {
            if let usage = error.usage {
                writeError(usage + "\n")
            }
            writeError("liova: error: \(error.message)\n")
            writeError("Run '\(error.command) --help' for usage.\n")
            return CLIOutput.ExitCode.usage.rawValue
        }

        switch invocation {
        case let .showHelp(text):
            print(text)
            return CLIOutput.ExitCode.success.rawValue
        case .showVersion:
            print("liova \(CLIParser.toolVersion) (plugin API v\(LiovaPluginKit.apiVersion))")
            return CLIOutput.ExitCode.success.rawValue
        case let .send(command, options):
            return send(command, options: options)
        case let .hook(options):
            return AgentCommandRunner.runHook(options)
        case let .agents(request):
            return AgentCommandRunner.run(request)
        }
    }

    private static func send(_ command: IPCCommand, options: CLIOptions) -> Int32 {
        let socketURL = options.socketPath.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? IPCPaths.defaultSocketURL
        let client = IPCClient(socketURL: socketURL, timeout: options.timeout)

        let response: IPCResponse
        do {
            response = try client.send(command)
        } catch {
            writeError("liova: error: \(error.description)\n")
            if case .serverNotRunning = error {
                return CLIOutput.ExitCode.serverNotRunning.rawValue
            }
            return CLIOutput.ExitCode.serverError.rawValue
        }

        if options.json {
            print(CLIOutput.json(response))
        } else if response.ok, let text = CLIOutput.text(for: command, response: response) {
            print(text)
        }
        guard response.ok else {
            if !options.json {
                let error = response.error ?? IPCErrorInfo(.internal, "Liova reported an unspecified error.")
                writeError("liova: error: \(error.message) [\(error.code)]\n")
            }
            return CLIOutput.ExitCode.serverError.rawValue
        }
        return CLIOutput.ExitCode.success.rawValue
    }

    static func writeError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
