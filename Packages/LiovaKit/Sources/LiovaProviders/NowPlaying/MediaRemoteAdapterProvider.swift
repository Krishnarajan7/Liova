import Foundation
import os

/// Now Playing for every player, through the vendored `mediaremote-adapter`.
///
/// Runs `/usr/bin/perl mediaremote-adapter.pl <framework> stream` as a child process.
/// macOS lets Perl (an Apple-signed binary) read Now Playing data; Liova itself never
/// impersonates an Apple bundle ID. The stream is push-based: the helper writes a line
/// only when something changes, so this costs nothing while music plays steadily.
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
        let arguments = [location.scriptURL.path, location.frameworkURL.path, "stream", "--debounce=50"]
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
