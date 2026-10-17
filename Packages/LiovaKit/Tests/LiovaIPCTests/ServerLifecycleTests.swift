import Darwin
import Foundation
@testable import LiovaIPC
import LiovaPluginKit
import Testing

/// Starting, stopping and securing a real ``IPCServer`` on a temporary Unix socket.
@Suite("Server lifecycle", .serialized)
struct ServerLifecycleTests {
    @Test func socketDirectoryIsPrivateAndSocketIsOwnerOnly() throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        #expect(permissions(of: running.temp.directory) == 0o700)
        #expect(permissions(of: running.temp.socketPath) == 0o600)
    }

    @Test func tooOpenDirectoryIsTightened() throws {
        let temp = TemporarySocketDirectory()
        defer { temp.remove() }
        #expect(mkdir(temp.directory, 0o755) == 0)
        #expect(chmod(temp.directory, 0o755) == 0)
        let server = IPCServer(socketURL: temp.socketURL, handler: makeRecordingHandler(CommandRecorder()))
        try server.start()
        defer { server.stop() }
        #expect(permissions(of: temp.directory) == 0o700)
    }

    @Test func symlinkedDirectoryIsRefused() throws {
        let target = TemporarySocketDirectory()
        let link = TemporarySocketDirectory()
        defer {
            target.remove()
            unlink(link.directory)
        }
        #expect(mkdir(target.directory, 0o700) == 0)
        #expect(symlink(target.directory, link.directory) == 0)
        let server = IPCServer(socketURL: link.socketURL, handler: makeRecordingHandler(CommandRecorder()))
        #expect(throws: IPCServerError.insecureDirectory(path: link.directory, reason: "it is a symbolic link")) {
            try server.start()
        }
        #expect(!server.isRunning)
    }

    @Test func directoryOwnedBySomeoneElseIsRefused() throws {
        // `/tmp` itself belongs to root.
        let server = IPCServer(
            socketURL: URL(fileURLWithPath: "/private/tmp/lv-root-owned.sock"),
            handler: makeRecordingHandler(CommandRecorder())
        )
        do {
            try server.start()
            server.stop()
            Issue.record("Expected insecureDirectory")
        } catch {
            guard case .insecureDirectory = error else {
                Issue.record("Expected insecureDirectory, got \(error)")
                return
            }
        }
    }

    @Test func staleSocketIsRecovered() async throws {
        let temp = TemporarySocketDirectory()
        defer { temp.remove() }
        #expect(mkdir(temp.directory, 0o700) == 0)
        try makeStaleSocket(at: temp.socketPath)
        #expect(UnixSocket.lstatIdentity(temp.socketPath).map { UnixSocket.isSocket($0.mode) } == true)

        let server = IPCServer(socketURL: temp.socketURL, handler: makeRecordingHandler(CommandRecorder()))
        try server.start()
        defer { server.stop() }
        let client = IPCClient(socketURL: temp.socketURL)
        let response = try await blocking { try client.send(.ping) }
        #expect(response.ok)
    }

    @Test func nonSocketAtThePathIsLeftAlone() throws {
        let temp = TemporarySocketDirectory()
        defer { temp.remove() }
        #expect(mkdir(temp.directory, 0o700) == 0)
        #expect(FileManager.default.createFile(atPath: temp.socketPath, contents: Data("keep".utf8)))
        let server = IPCServer(socketURL: temp.socketURL, handler: makeRecordingHandler(CommandRecorder()))
        #expect(throws: IPCServerError.pathOccupied(socketPath: temp.socketPath)) { try server.start() }
        #expect(FileManager.default.contents(atPath: temp.socketPath) == Data("keep".utf8))
    }

    @Test func secondServerOnTheSamePathReportsAlreadyRunning() async throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        let second = IPCServer(socketURL: running.temp.socketURL, handler: makeRecordingHandler(CommandRecorder()))
        #expect(throws: IPCServerError.alreadyRunning(socketPath: running.temp.socketPath)) {
            try second.start()
        }
        // The failed start must not have disturbed the first server.
        second.stop()
        let client = running.client()
        let response = try await blocking { try client.send(.ping) }
        #expect(response.ok)
    }

    @Test func startingTwiceIsAnError() throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        #expect(throws: IPCServerError.alreadyStarted) { try running.server.start() }
        #expect(running.server.isRunning)
    }

    @Test func tooLongSocketPathIsRejected() {
        let path = "/tmp/" + String(repeating: "x", count: 120) + "/s.sock"
        let server = IPCServer(socketURL: URL(fileURLWithPath: path), handler: makeRecordingHandler(CommandRecorder()))
        #expect(throws: IPCServerError.socketPathTooLong(socketPath: path, maxBytes: IPCPaths.maxSocketPathBytes)) {
            try server.start()
        }
        let client = IPCClient(socketURL: URL(fileURLWithPath: path))
        #expect(throws: IPCClientError.socketPathTooLong(socketPath: path, maxBytes: IPCPaths.maxSocketPathBytes)) {
            try client.send(.ping)
        }
    }

    @Test func stopUnlinksTheSocketAndClosesConnections() async throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        let client = running.client()
        let box = try await blocking { try ConnectionBox(client.connect()) }
        defer { box.connection.close() }
        _ = try await blocking { try box.connection.send(.ping) }
        #expect(running.server.connectionCount == 1)

        running.server.stop()
        #expect(!running.server.isRunning)
        #expect(running.server.connectionCount == 0)
        #expect(permissions(of: running.temp.socketPath) == nil)
        let afterStop = try await blocking { Result { () throws(IPCClientError) in try box.connection.send(.ping) } }
        #expect(throws: IPCClientError.connectionClosed) { try afterStop.get() }
        #expect(throws: IPCClientError.serverNotRunning(socketPath: running.temp.socketPath)) {
            try client.send(.ping)
        }
        running.server.stop() // Idempotent.
    }

    @Test func stopDuringAnInFlightRequestReturnsPromptly() async throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        let client = running.client()
        let slow = Activity(id: "slow", source: "ci", title: "slow")
        async let outcome = blocking { Result { () throws(IPCClientError) in try client.send(.start(slow)) } }
        #expect(await eventually { running.recorder.received.count == 1 })

        let clock = ContinuousClock()
        let elapsed = clock.measure { running.server.stop() }
        #expect(elapsed < .seconds(1))
        let result = try await outcome
        #expect(throws: IPCClientError.connectionClosed) { try result.get() }
    }

    @Test func serverCanRestartAfterStop() async throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        running.server.stop()
        try running.server.start()
        let client = running.client()
        let response = try await blocking { try client.send(.ping) }
        #expect(response.ok)
    }

    @Test func clientReportsServerNotRunning() {
        let temp = TemporarySocketDirectory()
        let client = IPCClient(socketURL: temp.socketURL)
        #expect(throws: IPCClientError.serverNotRunning(socketPath: temp.socketPath)) { try client.send(.ping) }
    }
}
