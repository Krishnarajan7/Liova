import AppKit
import Darwin
import Foundation

/// How much of the Mac one app is using right now. An app's helper processes (Chrome's tabs,
/// Spotify's renderer) count toward the app, as they do in Activity Monitor's energy view.
public struct AppUsage: Identifiable, Equatable, Sendable {
    /// The app's bundle path, or `pid:<n>` for a process outside any app.
    public var id: String
    public var name: String
    /// Nil for a process outside any app (a command-line tool).
    public var bundlePath: String?
    public var pids: [pid_t]
    /// Share of one core: 1.45 is 145%, as Activity Monitor counts it.
    public var cpu: Double
    /// Physical memory footprint, in bytes.
    public var memory: UInt64
    /// Set for macOS's own background work (Photos analyzing the library), which can't be quit.
    public var work: SystemWork?

    public init(
        id: String, name: String, bundlePath: String?, pids: [pid_t], cpu: Double, memory: UInt64,
        work: SystemWork? = nil
    ) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.pids = pids
        self.cpu = cpu
        self.memory = memory
        self.work = work
    }

    /// macOS's own work isn't the user's to quit.
    public var canQuit: Bool {
        work == nil
    }
}

/// One process's reading, before processes are grouped into apps.
public struct ProcessReading: Equatable, Sendable {
    public var pid: pid_t
    /// What the process counts toward: an app bundle, or the process's own executable.
    public var path: String
    /// The process's own name, for one outside any app: `claude`, not its versioned file name.
    public var name: String?
    public var cpu: Double
    public var memory: UInt64
    public var work: SystemWork?

    public init(
        pid: pid_t, path: String, name: String? = nil, cpu: Double, memory: UInt64, work: SystemWork? = nil
    ) {
        self.pid = pid
        self.path = path
        self.name = name
        self.cpu = cpu
        self.memory = memory
        self.work = work
    }
}

/// Reads every process the user owns with `proc_pid_rusage` (no permission needed), and
/// groups them into apps.
///
/// CPU is a difference between two readings, so the first `sample()` reports 0 for every
/// app. macOS's own processes are left out, unless an app started them (Safari's web pages)
/// or they're background work worth naming (`SystemWork`): the user can't do anything about
/// the rest. A pass over every process takes about a
/// millisecond; callers decide how often.
public final class AppUsageReader: @unchecked Sendable {
    /// Guarded by being used from one place at a time (the sampler's task).
    private var previous: [pid_t: (start: UInt64, cpuTime: UInt64)] = [:]
    private var previousUptime: UInt64?
    private var paths: [pid_t: (start: UInt64, path: String)] = [:]
    private let ownPID = getpid()
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    public init() {}

    /// Apps by CPU, busiest first.
    public func sample() -> [AppUsage] {
        Self.group(readProcesses())
    }

    private func readProcesses() -> [ProcessReading] {
        let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = previousUptime.map { uptime > $0 ? Double(uptime - $0) : 0 } ?? 0
        previousUptime = uptime

        var current: [pid_t: (start: UInt64, cpuTime: UInt64)] = [:]
        var readings: [ProcessReading] = []
        for pid in Self.allPIDs() where pid > 0 && pid != ownPID {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            // Fails for other users' processes (root's daemons): nothing to do about those.
            guard result == 0 else { continue }
            let start = info.ri_proc_start_abstime
            guard let path = path(for: pid, start: start) else { continue }
            let owner = Self.owner(of: path, responsiblePath: responsiblePath(for: pid, path: path))
            let work = owner == nil ? Self.work(at: path) : nil
            guard let owner = owner ?? work.map({ "system:\($0.id)" }) else { continue }
            // Mach time units on Apple Silicon, nanoseconds on Intel (timebase 1/1).
            let cpuTime = (info.ri_user_time + info.ri_system_time) * timebase.numer / timebase.denom
            current[pid] = (start, cpuTime)
            var cpu = 0.0
            if elapsed > 0, let old = previous[pid], old.start == start, cpuTime >= old.cpuTime {
                cpu = Double(cpuTime - old.cpuTime) / elapsed
            }
            let name = Self.appBundle(for: owner) == nil && work == nil ? Self.processName(pid) : nil
            readings.append(ProcessReading(
                pid: pid, path: owner, name: name, cpu: cpu, memory: info.ri_phys_footprint, work: work
            ))
        }
        previous = current
        paths = paths.filter { current[$0.key]?.start == $0.value.start }
        return readings
    }

    /// Paths only change with a new process, so each is looked up once.
    private func path(for pid: pid_t, start: UInt64) -> String? {
        if let cached = paths[pid], cached.start == start {
            return cached.path
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0, let path = Self.string(buffer, length: length) else { return nil }
        paths[pid] = (start, path)
        return path
    }

    /// The app that started a background process: Safari for its web pages, which run from
    /// /System. Asked only of macOS's own processes, so a tool run from Terminal stays itself
    /// instead of counting as Terminal.
    private func responsiblePath(for pid: pid_t, path: String) -> String? {
        guard Self.isSystemPath(path), Self.appBundle(for: path) == nil,
              let responsible = ResponsibleProcess.pid(for: pid), responsible != pid
        else { return nil }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(responsible, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return self.path(for: responsible, start: info.ri_proc_start_abstime)
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return string(buffer, length: length)
    }

    /// The first `length` bytes of a C string buffer.
    private static func string(_ buffer: [CChar], length: Int32) -> String? {
        String(bytes: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    // MARK: - Grouping (pure, so it's unit-tested)

    /// macOS's own programs: not the user's to quit.
    static func isSystemPath(_ path: String) -> Bool {
        if path.hasPrefix("/usr/local/") {
            return false
        }
        return ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    /// macOS background work worth naming, for a process of macOS's own.
    static func work(at path: String) -> SystemWork? {
        isSystemPath(path) ? SystemWork.of(process: (path as NSString).lastPathComponent) : nil
    }

    /// The outermost `.app` in `path`: a helper inside Chrome.app belongs to Chrome. Xcode's
    /// own apps (Simulator, Instruments) are apps of their own, not Xcode's helpers.
    static func appBundle(for path: String) -> String? {
        if let developer = path.range(of: ".app/Contents/Developer/Applications/"),
           let app = path[developer.upperBound...].range(of: ".app")
        {
            return String(path[..<app.upperBound])
        }
        if let range = path.range(of: ".app/") {
            return String(path[..<range.lowerBound]) + ".app"
        }
        return path.hasSuffix(".app") ? path : nil
    }

    /// What a process counts toward, as a path: its app, the app that started it, or the
    /// process itself when it's the user's own tool. Nil for parts of macOS (the Dock, Finder,
    /// daemons), which aren't the user's to quit.
    static func owner(of path: String, responsiblePath: String?, simulator: String = simulatorPath) -> String? {
        // The Simulator's devices, their apps and its rendering all count as the Simulator:
        // apart, each looks small, together they're often what heats the Mac.
        if path.contains("/CoreSimulator") {
            return simulator
        }
        if let bundle = appBundle(for: path) {
            return isCoreService(bundle) ? nil : bundle
        }
        if isSystemPath(path) {
            guard let responsiblePath, let bundle = appBundle(for: responsiblePath), !isCoreService(bundle)
            else { return nil }
            return bundle
        }
        return path
    }

    /// Where Simulator.app is; looked up once.
    static let simulatorPath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iphonesimulator")?
        .path ?? "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"

    /// Apps that are part of macOS itself, like Finder and the Dock. Music and Safari live under
    /// /System too, but they're the user's apps.
    private static func isCoreService(_ bundle: String) -> Bool {
        bundle.hasPrefix("/System/Library/") || bundle.hasPrefix("/Library/Apple/")
    }

    /// Processes added up per app, busiest first.
    public static func group(_ processes: [ProcessReading]) -> [AppUsage] {
        var apps: [String: AppUsage] = [:]
        for process in processes {
            let bundle = appBundle(for: process.path)
            let id = bundle ?? (process.work == nil ? "pid:\(process.pid)" : process.path)
            var app = apps[id] ?? AppUsage(
                id: id,
                name: process.work?.name ?? process.name ?? name(bundle: bundle, path: process.path),
                bundlePath: bundle,
                pids: [],
                cpu: 0,
                memory: 0,
                work: process.work
            )
            app.pids.append(process.pid)
            app.cpu += process.cpu
            app.memory += process.memory
            apps[id] = app
        }
        return apps.values.sorted { ($0.cpu, $0.memory, $0.name) > ($1.cpu, $1.memory, $1.name) }
    }

    private static func name(bundle: String?, path: String) -> String {
        guard let bundle else { return (path as NSString).lastPathComponent }
        return ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

/// Quits apps on the user's behalf: politely first, by force when asked.
@MainActor
public enum AppTerminator {
    /// Asks the app to quit, as the Dock's Quit does; it may ask to save first. Returns false
    /// when nothing could be asked.
    @discardableResult
    public static func quit(_ app: AppUsage) -> Bool {
        let running = runningApps(for: app)
        if !running.isEmpty {
            return running.map { $0.terminate() }.contains(true)
        }
        return signal(app, SIGTERM)
    }

    /// Ends the app right away, as Force Quit does. Unsaved work is lost.
    @discardableResult
    public static func forceQuit(_ app: AppUsage) -> Bool {
        let running = runningApps(for: app)
        let forced = running.map { $0.forceTerminate() }.contains(true)
        return signal(app, SIGKILL) || forced
    }

    private static func runningApps(for app: AppUsage) -> [NSRunningApplication] {
        guard let bundlePath = app.bundlePath else { return [] }
        let url = URL(fileURLWithPath: bundlePath).standardizedFileURL
        return NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL == url && $0.processIdentifier != getpid()
        }
    }

    private static func signal(_ app: AppUsage, _ signal: Int32) -> Bool {
        let own = getpid()
        return app.pids.filter { $0 != own && $0 > 1 }.map { kill($0, signal) == 0 }.contains(true)
    }
}

/// The process macOS holds responsible for another: the app behind its helpers and XPC
/// services (Safari behind a web page, Chrome behind its audio service).
public enum ResponsibleProcess {
    /// Not in the public headers, but stable since macOS 10.14; Activity Monitor groups by it.
    private typealias Lookup = @convention(c) (pid_t) -> pid_t
    private static let lookup: Lookup? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Lookup.self)
    }()

    /// Nil when it can't be told.
    public static func pid(for pid: pid_t) -> pid_t? {
        guard let responsible = lookup?(pid), responsible > 0 else { return nil }
        return responsible
    }
}
