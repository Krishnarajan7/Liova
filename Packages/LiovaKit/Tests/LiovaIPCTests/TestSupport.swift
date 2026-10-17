import Darwin
import Dispatch
import Foundation
@testable import LiovaIPC
import LiovaPluginKit
import Testing

/// A private temporary directory with a short path (Unix socket paths are limited to 103
/// bytes), removed again by ``remove()``.
struct TemporarySocketDirectory {
    let directory: String

    init() {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let suffix = String((0 ..< 8).map { _ in alphabet.randomElement() ?? "x" })
        directory = "/tmp/lv-\(suffix)"
    }

    /// The default socket path inside the directory. The directory itself is not created.
    var socketPath: String {
        directory + "/s.sock"
    }

    var socketURL: URL {
        URL(fileURLWithPath: socketPath)
    }

    func remove() {
        // Restore permissions first so a test that locked a file down can't block cleanup.
        _ = chmod(directory, 0o700)
        try? FileManager.default.removeItem(atPath: directory)
    }
}

/// Records every command the server hands to the handler.
final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [IPCCommand] = []
    private var clients: [IPCClientInfo] = []

    func record(_ command: IPCCommand, _ client: IPCClientInfo) {
        lock.withLock {
            commands.append(command)
            clients.append(client)
        }
    }

    var received: [IPCCommand] {
        lock.withLock { commands }
    }

    var receivedClients: [IPCClientInfo] {
        lock.withLock { clients }
    }
}

/// Carries a client connection across `await`s. Tests only touch it from one place at a time.
final class ConnectionBox: @unchecked Sendable {
    let connection: IPCClientConnection

    init(_ connection: IPCClientConnection) {
        self.connection = connection
    }
}

/// Activities returned by the test handler for `list`.
let sampleActivities = [
    Activity(id: "build", source: "ci", priority: .high, title: "Building", progress: 0.5),
    Activity(id: "music", source: "player", priority: .low, title: "Song"),
]

/// A handler that records commands and answers `list` with ``sampleActivities``. A start
/// whose title is `slow` sleeps for `slowDelay` first (cancellation ends the sleep early).
func makeRecordingHandler(_ recorder: CommandRecorder, slowDelay: Duration = .seconds(10)) -> IPCClosureHandler {
    IPCClosureHandler { command, client in
        recorder.record(command, client)
        switch command {
        case .list:
            return .success(activities: sampleActivities)
        case let .start(activity) where activity.title == "slow":
            try? await Task.sleep(for: slowDelay)
            return .success()
        case let .update(patch) where patch.id == "missing":
            return .failure(.notFound, "No live activity with ID 'missing'.")
        default:
            return .success()
        }
    }
}

/// A started server in a fresh temporary directory, stopped and cleaned up by ``tearDown()``.
struct RunningServer {
    let temp: TemporarySocketDirectory
    let server: IPCServer
    let recorder: CommandRecorder

    init(configuration: IPCServer.Configuration = IPCServer.Configuration()) throws {
        temp = TemporarySocketDirectory()
        recorder = CommandRecorder()
        server = IPCServer(
            socketURL: temp.socketURL,
            configuration: configuration,
            handler: makeRecordingHandler(recorder)
        )
        do {
            try server.start()
        } catch {
            temp.remove()
            throw error
        }
    }

    func client(timeout: TimeInterval = 5) -> IPCClient {
        IPCClient(socketURL: temp.socketURL, timeout: timeout)
    }

    func tearDown() {
        server.stop()
        temp.remove()
    }
}

/// Runs blocking socket code on a plain thread instead of Swift's cooperative pool, so a
/// blocked client can never starve the server's handler tasks.
func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(with: Result { try body() })
        }
    }
}

/// Polls `condition` every few milliseconds until it holds or `timeout` passes.
func eventually(
    timeout: Duration = .seconds(3),
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Decodes a raw response line.
func decodeResponse(_ line: Data) throws -> IPCResponse {
    try LiovaWire.makeDecoder().decode(IPCResponse.self, from: line)
}

/// Creates a socket file at `path` with nobody listening, as a crashed server would leave.
func makeStaleSocket(at path: String) throws {
    let fd = try UnixSocket.makeStreamSocket(nonBlocking: false)
    defer { close(fd) }
    let address = try UnixSocket.address(for: path)
    #expect(UnixSocket.bind(fd, to: address) == 0)
}

/// The permission bits of a file, without following a final symlink.
func permissions(of path: String) -> mode_t? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return info.st_mode & 0o777
}
