import Darwin
import LiovaIPC

// Entry point for the `liova` command. All logic lives in CLIRunner (I/O) and
// LiovaIPC's CLIParser (pure argument parsing).
exit(CLIRunner.run(arguments: Array(CommandLine.arguments.dropFirst())))
