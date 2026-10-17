import Darwin
import Foundation
@testable import LiovaIPC
import LiovaPluginKit
import Testing

/// End-to-end tests: a real ``IPCServer`` on a temporary Unix socket, driven by ``IPCClient``.
@Suite("Server integration", .serialized)
struct ServerIntegrationTests {
    private let activity = Activity(id: "build", source: "ci", title: "Building", progress: 0.1)

    // MARK: Requests reach the handler

    @Test func handlerReceivesEveryCommand() async throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        let client = running.client()
        let activity = activity
        let commands: [IPCCommand] = [
            .start(activity),
            .update(ActivityPatch(id: "build", progress: 0.5, clear: [.subtitle])),
            .end("build"),
            .endAll(source: "ci"),
            .list,
        ]
        for command in commands {
            let response = try await blocking { try client.send(command) }
            #expect(response.ok)
            #expect(response.serverVersion == LiovaPluginKit.apiVersion)
        }
        #expect(running.recorder.received == commands)
        let uid = getuid()
        #expect(running.recorder.receivedClients.allSatisfy { $0.uid == uid })
        #expect(running.recorder.receivedClients.allSatisfy { $0.pid == getpid() })
    }

    @Test func listReturnsTheHandlersActivities() async throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        let client = running.client()
        let response = try await blocking { try client.send(.list) }
        #expect(response.activities == sampleActivities)
    }

    @Test func pingIsAnsweredByTheServerItself() async throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        let client = running.client()
        let response = try await blocking { try client.send(.ping) }
        #expect(response == .success())
        #expect(running.recorder.received.isEmpty)
    }

    @Test func handlerFailuresAreForwarded() async throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        let client = running.client()
        let response = try await blocking { try client.send(.update(ActivityPatch(id: "missing", title: "x"))) }
        #expect(!response.ok)
        #expect(response.error?.code == .notFound)
    }

    @Test func multipleRequestsShareOneConnection() async throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        let client = running.client()
        let activity = activity
        let responses = try await blocking {
            let connection = try client.connect()
            defer { connection.close() }
            return try [
                connection.send(.ping),
                connection.send(.start(activity)),
                connection.send(.list),
                connection.send(.end("build")),
            ]
        }
        #expect(responses.map(\.ok) == [true, true, true, true])
        #expect(responses[2].activities == sampleActivities)
        let connectionIDs = Set(running.recorder.receivedClients.map(\.connectionID))
        #expect(connectionIDs.count == 1)
    }

    @Test func pipelinedRequestsAreAnsweredInOrder() async throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        let client = running.client()
        let lines = try await blocking {
            let connection = try client.connect()
            defer { connection.close() }
            var batch = try LiovaWire.encodeLine(IPCRequest(command: .list))
            try batch.append(LiovaWire.encodeLine(IPCRequest(command: .ping)))
            batch.append(Data("\r\n   \n".utf8)) // Blank lines are ignored.
            try batch.append(LiovaWire.encodeLine(IPCRequest(command: .end("x"))))
            let deadline = Date(timeIntervalSinceNow: 5)
            try connection.write(batch, deadline: deadline)
            return try (0 ..< 3).map { _ in try connection.readLine(deadline: deadline) }
        }
        let responses = try lines.map(decodeResponse)
        #expect(responses.map(\.ok) == [true, true, true])
        #expect(responses[0].activities == sampleActivities)
        #expect(responses[1].activities == nil)
        #expect(running.recorder.received == [.list, .end("x")])
    }

    @Test func crlfAndUnterminatedFinalLineAreAccepted() async throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        let client = running.client()
        let lines = try await blocking {
            let connection = try client.connect()
            defer { connection.close() }
            let deadline = Date(timeIntervalSinceNow: 5)
            try connection.write(Data(#"{"v":1,"op":"ping"}"#.utf8 + [0x0D, 0x0A]), deadline: deadline)
            try connection.write(Data(#"{"v":1,"op":"list"}"#.utf8), deadline: deadline)
            connection.finishWriting()
            return try [connection.readLine(deadline: deadline), connection.readLine(deadline: deadline)]
        }
        #expect(try lines.map(decodeResponse).map(\.ok) == [true, true])
        #expect(running.recorder.received == [.list])
    }
}

extension ServerIntegrationTests {
    // MARK: Hostile input

    @Test func malformedJSONGetsBadRequestAndTheConnectionKeepsWorking() async throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        let client = running.client()
        let (bad, notObject, good) = try await blocking {
            let connection = try client.connect()
            defer { connection.close() }
            let bad = try connection.exchange(Data("{not json\n".utf8))
            let notObject = try connection.exchange(Data("[1,2,3]\n".utf8))
            let good = try connection.send(.ping)
            return (bad, notObject, good)
        }
        #expect(try decodeResponse(bad).error?.code == .badRequest)
        #expect(try decodeResponse(notObject).error?.code == .badRequest)
        #expect(good.ok)
        #expect(running.server.isRunning)
    }

    @Test(arguments: [
        (#"{"v":1,"op":"explode"}"#, IPCErrorCode.badRequest),
        (#"{"v":99,"op":"ping"}"#, .unsupportedVersion),
        (#"{"v":0,"op":"ping"}"#, .unsupportedVersion),
        (#"{"op":"ping"}"#, .badRequest),
        (#"{"v":1,"op":"start","activity":{"id":"a","source":"system.hud","title":"x"}}"#, .forbidden),
        (#"{"v":1,"op":"endAll","source":"system"}"#, .forbidden),
        (#"{"v":1,"op":"start","activity":{"id":"a b","title":"x"}}"#, .badRequest),
        (#"{"v":1,"op":"end"}"#, .badRequest),
    ])
    func invalidRequestsAreRejectedBeforeTheHandler(line: String, code: IPCErrorCode) async throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        let client = running.client()
        let reply = try await blocking {
            let connection = try client.connect()
            defer { connection.close() }
            return try connection.exchange(Data((line + "\n").utf8))
        }
        let response = try decodeResponse(reply)
        #expect(!response.ok)
        #expect(response.error?.code == code)
        #expect(running.recorder.received.isEmpty)
    }

    @Test func oversizedLineGetsTooLargeAndTheConnectionCloses() async throws {
        let running = try RunningServer(configuration: .init(maxLineBytes: 1024))
        defer { running.tearDown() }
        let client = running.client()
        let (reply, afterwards) = try await blocking {
            let connection = try client.connect()
            defer { connection.close() }
            let huge = Data(repeating: UInt8(ascii: "a"), count: 200 * 1024) + Data([0x0A])
            let reply = try connection.exchange(huge)
            let afterwards = Result { () throws(IPCClientError) in try connection.send(.ping) }
            return (reply, afterwards)
        }
        #expect(try decodeResponse(reply).error?.code == .tooLarge)
        guard case let .failure(error) = afterwards else {
            Issue.record("The connection should be closed after tooLarge.")
            return
        }
        #expect(error == .connectionClosed)
        #expect(await eventually { running.server.connectionCount == 0 })
        // The server itself keeps serving.
        let pong = try await blocking { try client.send(.ping) }
        #expect(pong.ok)
    }

    @Test func lineExactlyAtTheLimitIsAccepted() async throws {
        let running = try RunningServer(configuration: .init(maxLineBytes: 64))
        defer { running.tearDown() }
        let client = running.client()
        let reply = try await blocking {
            let connection = try client.connect()
            defer { connection.close() }
            var line = Data(#"{"v":1,"op":"ping"}"#.utf8)
            line.append(Data(repeating: UInt8(ascii: " "), count: 64 - line.count))
            return try connection.exchange(line + Data([0x0A]))
        }
        #expect(try decodeResponse(reply).ok)
    }

    @Test func rateLimitKicksInAfterTheBurst() async throws {
        let running = try RunningServer(configuration: .init(rateLimitBurst: 3, rateLimitPerSecond: 0.001))
        defer { running.tearDown() }
        let client = running.client()
        let responses = try await blocking {
            let connection = try client.connect()
            defer { connection.close() }
            return try (0 ..< 5).map { _ in try connection.send(.ping) }
        }
        #expect(responses.map(\.ok) == [true, true, true, false, false])
        #expect(responses.last?.error?.code == .rateLimited)
    }

    @Test func connectionsBeyondTheLimitGetBusy() async throws {
        let running = try RunningServer(configuration: .init(maxConnections: 1))
        defer { running.tearDown() }
        let client = running.client()
        let (first, second) = try await blocking {
            let holder = try client.connect()
            defer { holder.close() }
            let first = try holder.send(.ping)
            let second = Result { () throws(IPCClientError) in try client.send(.ping) }
            return (first, second)
        }
        #expect(first.ok)
        #expect(try second.get().error?.code == .busy)
    }

    @Test func idleConnectionsAreClosed() async throws {
        let running = try RunningServer(configuration: .init(idleTimeout: 0.05))
        defer { running.tearDown() }
        let client = running.client()
        let box = try await blocking { try ConnectionBox(client.connect()) }
        defer { box.connection.close() }
        #expect(await eventually { running.server.connectionCount == 1 })
        #expect(await eventually { running.server.connectionCount == 0 })
    }

    @Test func clientTimesOutWhenTheHandlerIsSlow() async throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        let client = running.client(timeout: 0.1)
        let slow = Activity(id: "slow", source: "ci", title: "slow")
        let result = try await blocking {
            Result { () throws(IPCClientError) in try client.send(.start(slow)) }
        }
        #expect(throws: IPCClientError.timedOut(after: 0.1)) { try result.get() }
    }

    @Test func concurrentClientsAreAllServed() async throws {
        let running = try RunningServer()
        defer { running.tearDown() }
        let client = running.client()
        let clients = 16
        let requestsEach = 10
        let okCount = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0 ..< clients {
                group.addTask {
                    try await blocking {
                        let connection = try client.connect()
                        defer { connection.close() }
                        var succeeded = 0
                        for step in 0 ..< requestsEach
                            where try connection.send(.end(ActivityID("c\(index)-\(step)"))).ok
                        {
                            succeeded += 1
                        }
                        return succeeded
                    }
                }
            }
            return try await group.reduce(0, +)
        }
        #expect(okCount == clients * requestsEach)
        #expect(running.recorder.received.count == clients * requestsEach)
        #expect(Set(running.recorder.receivedClients.map(\.connectionID)).count == clients)
    }
}
