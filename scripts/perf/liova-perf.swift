// Measures a built Liova.app against the performance budget in docs/PERFORMANCE.md.
//
//   swiftc -O scripts/perf/liova-perf.swift -o build/liova-perf
//   build/liova-perf build/Build/Products/Release/Liova.app [--runs 5] [--seconds 30]
//                    [--manual "play music"] [--json out.json]
//   build/liova-perf build/Build/Products/Release/Liova.app --timeline 40
//
// For each run it launches the app, times launch until the notch panel is on screen, lets it
// settle, then reads the kernel's own counters (proc_pid_rusage) for Liova and its helper
// processes: CPU time, memory footprint, wakeups and energy. Exact, unlike `ps`, which rounds.
// The median of all runs is compared with the budget; any miss exits with status 1.
//
// `--manual` measures a scenario a person has to set up (music playing, moving the pointer):
// it prints the instruction, waits for Return, then measures.
//
// `--timeline N` launches once and prints CPU and wakeups for each of the first N seconds,
// to see when Liova goes quiet after launch.

import AppKit
import Darwin
import Foundation

struct Options {
    var app = ""
    var runs = 5
    var seconds = 30.0
    var settle = 20.0
    var manual: String?
    var json: String?
    var timeline: Int?
    var launchBudget = 300.0
    var cpuBudget = 0.05
    /// Extra launch arguments, e.g. `-headphonesEnabled NO` to measure a feature's cost.
    var appArguments: [String] = []
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--runs": options.runs = Int(args.next() ?? "") ?? options.runs
        case "--seconds": options.seconds = Double(args.next() ?? "") ?? options.seconds
        case "--settle": options.settle = Double(args.next() ?? "") ?? options.settle
        case "--manual": options.manual = args.next()
        case "--json": options.json = args.next()
        case "--timeline": options.timeline = Int(args.next() ?? "")
        // CI virtual machines start apps far slower than real Macs; they pass a looser limit.
        case "--launch-budget": options.launchBudget = Double(args.next() ?? "") ?? options.launchBudget
        // Each wakeup costs a VM several times the CPU it costs a Mac; CI passes a looser idle limit.
        case "--cpu-budget": options.cpuBudget = Double(args.next() ?? "") ?? options.cpuBudget
        // `--arg -headphonesEnabled --arg NO`: passed to Liova (a settings override for this launch only).
        case "--arg": options.appArguments.append(args.next() ?? "")
        case "-h", "--help":
            print("usage: liova-perf <Liova.app> [--runs N] [--seconds S] [--settle S] [--manual TEXT] "
                + "[--json FILE] [--launch-budget MS] [--cpu-budget PERCENT] [--timeline N]")
            exit(0)
        default: options.app = arg
        }
    }
    guard !options.app.isEmpty else {
        FileHandle.standardError.write(Data("liova-perf: give the path to Liova.app\n".utf8))
        exit(2)
    }
    return options
}

// MARK: - Kernel counters

struct Usage {
    var cpuNanoseconds: UInt64 = 0
    var footprintBytes: UInt64 = 0
    var wakeups: UInt64 = 0
    var energyNanojoules: UInt64 = 0

    static func + (lhs: Usage, rhs: Usage) -> Usage {
        Usage(
            cpuNanoseconds: lhs.cpuNanoseconds + rhs.cpuNanoseconds,
            footprintBytes: lhs.footprintBytes + rhs.footprintBytes,
            wakeups: lhs.wakeups + rhs.wakeups,
            energyNanojoules: lhs.energyNanojoules + rhs.energyNanojoules
        )
    }
}

let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func usage(of pid: pid_t) -> Usage? {
    var info = rusage_info_v6()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
        }
    }
    guard status == 0 else { return nil }
    // CPU times are in Mach absolute time units on Apple Silicon.
    let ticks = info.ri_user_time + info.ri_system_time
    return Usage(
        cpuNanoseconds: ticks * UInt64(timebase.numer) / UInt64(timebase.denom),
        footprintBytes: info.ri_phys_footprint,
        wakeups: info.ri_interrupt_wkups + info.ri_pkg_idle_wkups,
        energyNanojoules: info.ri_energy_nj
    )
}

func children(of pid: pid_t) -> [pid_t] {
    var pids = [pid_t](repeating: 0, count: 64)
    let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return count > 0 ? Array(pids.prefix(Int(count))) : []
}

func descendants(of pid: pid_t) -> [pid_t] {
    children(of: pid).flatMap { [$0] + descendants(of: $0) }
}

/// Liova plus its helpers (the Now Playing bridge and its guard), summed.
func totalUsage(of pid: pid_t) -> (app: Usage, helpers: Usage)? {
    guard let app = usage(of: pid) else { return nil }
    let helpers = descendants(of: pid).compactMap(usage(of:)).reduce(Usage(), +)
    return (app, helpers)
}

// MARK: - Launch

func panelIsOnScreen(pid: pid_t) -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
}

/// Starts the binary directly (not through `open`) so the launch clock is honest, with
/// first-run UI turned off through the arguments domain, which leaves saved settings alone.
func launch(app: String, arguments: [String] = []) throws -> (Process, launchMilliseconds: Double?) {
    let bundle = URL(fileURLWithPath: app)
    guard let executable = Bundle(url: bundle)?.executableURL else {
        throw NSError(domain: "liova-perf", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not an app: \(app)"])
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["-hasSeenWelcome", "YES"] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let start = DispatchTime.now()
    try process.run()
    let deadline = Date() + 10
    while Date() < deadline {
        if panelIsOnScreen(pid: process.processIdentifier) {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            return (process, elapsed)
        }
        usleep(2000)
    }
    return (process, nil)
}

// MARK: - A run

struct RunResult: Codable {
    var launchMilliseconds: Double?
    var cpuPercent: Double
    var helperCPUPercent: Double
    var footprintMB: Double
    var helperFootprintMB: Double
    var wakeupsPerSecond: Double
    var milliwatts: Double
}

func measure(_ options: Options, waitForPerson: Bool) throws -> RunResult {
    let (process, launchMs) = try launch(app: options.app, arguments: options.appArguments)
    defer {
        process.terminate()
        process.waitUntilExit()
    }
    Thread.sleep(forTimeInterval: options.settle)
    if waitForPerson, let manual = options.manual {
        print("  → \(manual), then press Return (it measures for \(Int(options.seconds)) s)")
        _ = readLine()
    }
    let pid = process.processIdentifier
    guard let before = totalUsage(of: pid) else { throw NSError(domain: "liova-perf", code: 2) }
    let start = DispatchTime.now()
    Thread.sleep(forTimeInterval: options.seconds)
    guard let after = totalUsage(of: pid) else { throw NSError(domain: "liova-perf", code: 3) }
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    let percent = { (a: UInt64, b: UInt64) in Double(b &- a) / 1e9 / seconds * 100 }
    return RunResult(
        launchMilliseconds: launchMs,
        cpuPercent: percent(before.app.cpuNanoseconds, after.app.cpuNanoseconds),
        helperCPUPercent: percent(before.helpers.cpuNanoseconds, after.helpers.cpuNanoseconds),
        footprintMB: Double(after.app.footprintBytes) / 1_048_576,
        helperFootprintMB: Double(after.helpers.footprintBytes) / 1_048_576,
        wakeupsPerSecond: Double(after.app.wakeups &- before.app.wakeups) / seconds,
        milliwatts: Double(after.app.energyNanojoules &- before.app.energyNanojoules) / 1e6 / seconds
    )
}

// MARK: - Budget

struct Check {
    let name: String
    let value: Double?
    let limit: Double
    let unit: String
    var passed: Bool {
        value.map { $0 <= limit } ?? false
    }
}

func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}

func timeline(_ options: Options, seconds: Int) throws {
    let (process, launchMs) = try launch(app: options.app, arguments: options.appArguments)
    defer {
        process.terminate()
        process.waitUntilExit()
    }
    print("Launch \(launchMs.map { String(format: "%.0f ms", $0) } ?? "–"); per second after it:")
    var previous = totalUsage(of: process.processIdentifier)
    for second in 1 ... seconds {
        Thread.sleep(forTimeInterval: 1)
        guard let now = totalUsage(of: process.processIdentifier), let before = previous else { break }
        print(String(
            format: "  %3d s  CPU %6.3f%%  helpers %6.3f%%  wakeups %4llu",
            second, Double(now.app.cpuNanoseconds &- before.app.cpuNanoseconds) / 1e7,
            Double(now.helpers.cpuNanoseconds &- before.helpers.cpuNanoseconds) / 1e7,
            now.app.wakeups &- before.app.wakeups
        ))
        previous = now
    }
}

let options = parseOptions()
if let seconds = options.timeline {
    try timeline(options, seconds: seconds)
    exit(0)
}

let scenario = options.manual ?? "idle, notch closed"
print("Liova performance: \(scenario), \(options.runs) run(s) of \(Int(options.seconds)) s")
var results: [RunResult] = []
for run in 1 ... options.runs {
    do {
        let result = try measure(options, waitForPerson: options.manual != nil)
        results.append(result)
        print(String(
            format: "  run %d: launch %@ ms, CPU %.3f%% (+%.3f%% helpers), %.1f MB (+%.1f MB helpers), "
                + "%.1f wakeups/s, %.2f mW",
            run, result.launchMilliseconds.map { String(format: "%.0f", $0) } ?? "–",
            result.cpuPercent, result.helperCPUPercent, result.footprintMB, result.helperFootprintMB,
            result.wakeupsPerSecond, result.milliwatts
        ))
    } catch {
        print("  run \(run) failed: \(error.localizedDescription)")
    }
}

/// Budgets from docs/PERFORMANCE.md. "0.0%" idle is checked as under 0.05%, what rounds to 0.0.
var checks = [
    Check(
        name: "Cold launch to visible notch",
        value: median(results.compactMap(\.launchMilliseconds)),
        limit: options.launchBudget,
        unit: "ms"
    ),
    Check(
        name: "Memory footprint (app + helpers)",
        value: median(results.map { $0.footprintMB + $0.helperFootprintMB }),
        limit: 60,
        unit: "MB"
    ),
]
if options.manual == nil {
    checks.append(Check(
        name: "CPU, idle (app + helper)",
        value: median(results.map { $0.cpuPercent + $0.helperCPUPercent }),
        limit: options.cpuBudget,
        unit: "%"
    ))
    checks.append(Check(name: "Wakeups, idle", value: median(results.map(\.wakeupsPerSecond)), limit: 2, unit: "/s"))
}

print("")
for check in checks {
    let value = check.value.map { String(format: "%.3f", $0) } ?? "not measured"
    print(
        "  \(check.passed ? "pass" : "FAIL")  \(check.name): \(value) \(check.unit) (budget ≤ \(check.limit) \(check.unit))"
    )
}

if let summary = ProcessInfo.processInfo.environment["GITHUB_STEP_SUMMARY"] {
    var table = "### Liova performance: \(scenario)\n\n| Check | Value | Budget | |\n| --- | --- | --- | --- |\n"
    for check in checks {
        let value = check.value.map { String(format: "%.3f %@", $0, check.unit) } ?? "not measured"
        table += "| \(check.name) | \(value) | ≤ \(check.limit) \(check.unit) | \(check.passed ? "✅" : "❌") |\n"
    }
    if let handle = FileHandle(forWritingAtPath: summary) {
        handle.seekToEndOfFile()
        handle.write(Data(table.utf8))
        try? handle.close()
    }
}

if let path = options.json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    struct Report: Codable {
        let scenario: String
        let runs: [RunResult]
        let passed: Bool
    }
    let report = Report(scenario: scenario, runs: results, passed: checks.allSatisfy(\.passed))
    try? encoder.encode(report).write(to: URL(fileURLWithPath: path))
}

exit(checks.allSatisfy(\.passed) && !results.isEmpty ? 0 : 1)
