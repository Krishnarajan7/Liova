import Foundation
import os

/// Now Playing for every player, through the vendored `mediaremote-adapter`.
///
/// Runs `/usr/bin/perl mediaremote-adapter.pl <framework> stream` as a child process.
/// macOS lets Perl (an Apple-signed binary) read Now Playing data; Liova itself never
/// impersonates an Apple bundle ID. The stream is push-based: the helper writes a line
/// only when something changes, so this costs nothing while music plays steadily.
///
/// The helper runs under a small guard (see `helperGuard`) so it can never outlive Liova,
/// even when Liova crashes or is force quit.
///
/// Lines are parsed on a background queue (artwork arrives as large base64 strings) and
/// results are delivered to the main actor in order. If the helper exits unexpectedly it
/// is restarted with exponential backoff; after repeated fast failures it gives up and
/// reports `isAvailable == false`.
@MainActor
public final class MediaRemoteAdapterProvider: NowPlayingProviding {
    /// Where the adapter's script and framework live.
    public struct Location: Sendable, Equatable {
        public var scriptURL: URL
        public var frameworkURL: URL

        public init(scriptURL: URL, frameworkURL: URL) {
            self.scriptURL = scriptURL
            self.frameworkURL = frameworkURL
        }

        /// The copy bundled inside Liova.app (`Contents/Frameworks` and `Contents/Resources`).
        public static func bundled(in bundle: Bundle = .main) -> Location? {
            guard let script = bundle.url(forResource: "mediaremote-adapter", withExtension: "pl"),
                  let frameworks = bundle.privateFrameworksURL
            else { return nil }
            let framework = frameworks.appendingPathComponent("MediaRemoteAdapter.framework")
            guard FileManager.default.fileExists(atPath: framework.path) else { return nil }
            return Location(scriptURL: script, frameworkURL: framework)
        }
    }

    public private(set) var isAvailable = true

    private let location: Location
    private let perl = URL(fileURLWithPath: "/usr/bin/perl")
    private var stream: AdapterStream?
    private var onChange: (@MainActor (NowPlayingInfo?) -> Void)?
    private var restartTask: Task<Void, Never>?
    private var consecutiveFailures = 0

    private static let log = Logger(subsystem: "app.liova.Liova", category: "nowplaying")
    private static let maxConsecutiveFailures = 5
    /// A run shorter than this counts as a failure for backoff purposes.
    private static let healthyRunDuration: TimeInterval = 10

    /// Runs its arguments as a Perl child and ends that child when Liova goes away.
    ///
    /// Liova holds the write end of the guard's stdin. However Liova exits (quit, crash,
    /// `kill -9`), the kernel closes that pipe, the guard's blocking read returns end of file,
    /// and it stops the helper: no polling, nothing left running. A plain child would linger
    /// until its next write failed, which can be never when nothing plays. The guard exits
    /// with the helper's status, so restarts work exactly as before. It's a separate Perl
    /// process because the vendored script stays unmodified (see VENDORED.md).
    nonisolated static let helperGuard = #"""
    use strict; use warnings; use POSIX ();
    my $pid;
    my $status = sub { my $s = shift; ($s & 127) ? 128 + ($s & 127) : $s >> 8 };
    $SIG{CHLD} = sub { POSIX::_exit($status->($?)) if defined $pid && waitpid($pid, POSIX::WNOHANG()) == $pid };
    $SIG{$_} = sub { kill 'TERM', $pid if $pid } for qw(TERM INT HUP);
    $pid = fork() // POSIX::_exit(71);
    if ($pid == 0) {
      open(STDIN, '<', '/dev/null');
      exec { '/usr/bin/perl' } '/usr/bin/perl', @ARGV or POSIX::_exit(127);
    }
    while (1) {
      my $read = sysread(STDIN, my $ignored, 512);
      last if defined $read && $read == 0;
      next if !defined $read && $!{EINTR};
      last unless defined $read;
    }
    kill 'TERM', $pid;
    waitpid($pid, 0);
    POSIX::_exit($status->($?));
    """#

    public init(location: Location) {
        self.location = location
    }

    public func start(onChange: @escaping @MainActor (NowPlayingInfo?) -> Void) {
        stop()
        self.onChange = onChange
        consecutiveFailures = 0
        isAvailable = true
        launchStream()
    }

    public func stop() {
        restartTask?.cancel()
        restartTask = nil
        stream?.terminate()
        stream = nil
        onChange = nil
    }

    public func send(_ command: NowPlayingCommand) {
        runOneShot(["send", String(command.rawValue)])
    }

    public func seek(to seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        runOneShot(["seek", String(Int64(seconds * 1_000_000))])
    }

    // MARK: - Stream lifecycle

    private func launchStream() {
        let arguments = [
            "-e",
            Self.helperGuard,
            "--",
            location.scriptURL.path,
            location.frameworkURL.path,
            "stream",
            "--debounce=50",
        ]
        let startedAt = Date()
        let stream = AdapterStream(executable: perl, arguments: arguments) { [weak self] info in
            self?.onChange?(info)
        } onExit: { [weak self] status in
            self?.streamExited(status: status, ranFor: Date().timeIntervalSince(startedAt))
        }
        do {
            try stream.run()
            self.stream = stream
            Self.log.info("Now Playing stream started")
        } catch {
            Self.log.error("Now Playing helper failed to launch: \(error.localizedDescription, privacy: .public)")
            streamExited(status: -1, ranFor: 0)
        }
    }

    private func streamExited(status: Int32, ranFor duration: TimeInterval) {
        guard onChange != nil else { return } // stopped on purpose
        stream = nil
        onChange?(nil)
        consecutiveFailures = duration >= Self.healthyRunDuration ? 1 : consecutiveFailures + 1
        guard consecutiveFailures < Self.maxConsecutiveFailures else {
            isAvailable = false
            Self.log.error("Now Playing helper keeps exiting (status \(status)); giving up")
            return
        }
        let delay = min(30, pow(2, Double(consecutiveFailures - 1)))
        Self.log.notice("Now Playing helper exited (status \(status)); restarting in \(delay)s")
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, onChange != nil else { return }
            launchStream()
        }
    }

    private func runOneShot(_ command: [String]) {
        let process = Process()
        process.executableURL = perl
        process.arguments = [location.scriptURL.path, location.frameworkURL.path] + command
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Self.log.error("Now Playing command failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Owns one `stream` child process and parses its output off the main thread.
///
/// `@unchecked Sendable`: mutable state (`buffer`, `parser`) is only touched from the pipe's
/// readability handler, which Foundation calls serially; the process reference is immutable.
private final class AdapterStream: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    /// Never written; Liova holding it open is what keeps the helper alive (see `helperGuard`).
    private let lifeline = Pipe()
    private var buffer = Data()
    private var parser = NowPlayingStreamParser()
    private let deliver: @MainActor (NowPlayingInfo?) -> Void
    private let onExit: @MainActor (Int32) -> Void
    private let lock = OSAllocatedUnfairLock()
    private var terminatedOnPurpose = false

    /// Guards against a runaway line (the adapter never sends more than a few MB of artwork).
    private static let maxLineBytes = 16 * 1024 * 1024
    private static let log = Logger(subsystem: "app.liova.Liova", category: "nowplaying")

    init(
        executable: URL,
        arguments: [String],
        deliver: @escaping @MainActor (NowPlayingInfo?) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) {
        self.deliver = deliver
        self.onExit = onExit
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardInput = lifeline
        process.standardError = FileHandle.nullDevice
    }

    func run() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            output.fileHandleForReading.readabilityHandler = nil
            let onPurpose = lock.withLock { terminatedOnPurpose }
            guard !onPurpose else { return }
            let status = process.terminationStatus
            let onExit = onExit
            DispatchQueue.main.async { MainActor.assumeIsolated { onExit(status) } }
        }
        try process.run()
    }

    func terminate() {
        lock.withLock { terminatedOnPurpose = true }
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        try? lifeline.fileHandleForWriting.close()
    }

    private func receive(_ chunk: Data) {
        guard !chunk.isEmpty else { return } // EOF; terminationHandler reports the exit
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            handle(Data(line))
        }
        if buffer.count > Self.maxLineBytes {
            Self.log.error("Now Playing line exceeded \(Self.maxLineBytes) bytes; dropping it")
            buffer.removeAll(keepingCapacity: false)
        }
    }

    private func handle(_ line: Data) {
        guard !line.isEmpty else { return }
        do {
            guard case let .info(info) = try parser.consume(line) else { return }
            let deliver = deliver
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(info) } }
        } catch {
            Self.log.error("Unreadable Now Playing line: \(String(describing: error), privacy: .public)")
        }
    }
}
