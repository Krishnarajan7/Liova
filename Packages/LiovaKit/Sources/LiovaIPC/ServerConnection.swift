import Darwin
import Dispatch
import Foundation
import LiovaPluginKit

/// One client connection.
///
/// A small state machine driven entirely by dispatch sources on the server queue: a read
/// source, a write source created only when the kernel buffer is full, and a one-shot idle
/// timer. Requests are answered strictly in order; while one is with the handler (or its
/// response hasn't been written yet) the read source is suspended, which pushes back on
/// clients that pipeline faster than we answer.
///
/// Every mutable property is only touched on `queue`, which makes `@unchecked Sendable` sound.
final class ServerConnection: @unchecked Sendable {
    let client: IPCClientInfo
    private let fd: Int32
    private let configuration: IPCServer.Configuration
    private let handler: any IPCRequestHandler
    private let queue: DispatchQueue
    private let onClose: (UInt64) -> Void

    private var readSource: (any DispatchSourceRead)?
    private var readSuspended = false
    private var writeSource: (any DispatchSourceWrite)?
    private var writeSuspended = false
    private var idleTimer: (any DispatchSourceTimer)?

    private var input: LineBuffer
    private var output: [UInt8] = []
    private var inFlight: Task<Void, Never>?
    private var peerFinishedSending = false
    private var closeWhenFlushed = false
    private var closed = false

    private var rateLimiter: TokenBucket

    init(
        fd: Int32,
        client: IPCClientInfo,
        configuration: IPCServer.Configuration,
        handler: any IPCRequestHandler,
        queue: DispatchQueue,
        onClose: @escaping (UInt64) -> Void
    ) {
        self.fd = fd
        self.client = client
        self.configuration = configuration
        self.handler = handler
        self.queue = queue
        self.onClose = onClose
        input = LineBuffer(maxLineBytes: configuration.maxLineBytes)
        rateLimiter = TokenBucket(burst: configuration.rateLimitBurst, perSecond: configuration.rateLimitPerSecond)
    }

    func start() {
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        read.setEventHandler { [weak self] in self?.readAvailable() }
        readSource = read
        read.activate()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.idleTimerFired() }
        idleTimer = timer
        scheduleIdleTimer()
        timer.activate()
    }

    // MARK: Reading

    private func readAvailable() {
        guard !closed else { return }
        let count = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16 * 1024) { buffer -> Int in
            let count = read(fd, buffer.baseAddress, buffer.count)
            if count > 0 {
                input.append(UnsafeBufferPointer(rebasing: buffer[..<count]))
            }
            return count
        }
        if count > 0 {
            scheduleIdleTimer()
        } else if count == 0 {
            peerFinishedSending = true
        } else {
            switch errno {
            case EAGAIN, EINTR: return
            default: close(); return
            }
        }
        processInput()
    }

    /// Answers every complete buffered line it can, then decides whether to keep reading.
    private func processInput() {
        while !closed, !closeWhenFlushed, inFlight == nil, output.isEmpty {
            switch input.next() {
            case let .line(line):
                handleLine(line)
            case .tooLarge:
                finish(with: .failure(
                    .tooLarge,
                    "Request line exceeds \(configuration.maxLineBytes) bytes. Closing the connection."
                ))
                return
            case .incomplete:
                if peerFinishedSending {
                    // The client half-closed. A final line without "\n" still counts.
                    if input.isEmpty {
                        close()
                        return
                    }
                    handleLine(input.takeRemainder())
                    continue
                }
                updateReadInterest()
                return
            }
        }
        updateReadInterest()
    }

    private func updateReadInterest() {
        guard !closed, let readSource else { return }
        let wantsInput = !closeWhenFlushed && !peerFinishedSending && inFlight == nil && output.isEmpty
        if wantsInput, readSuspended {
            readSuspended = false
            readSource.resume()
        } else if !wantsInput, !readSuspended {
            readSuspended = true
            readSource.suspend()
        }
    }

    // MARK: Requests

    private func handleLine(_ rawLine: [UInt8]) {
        var line = rawLine[...]
        if line.last == 0x0D {
            line = line.dropLast()
        }
        // Blank lines are ignored, which keeps interactive `nc -U` sessions forgiving.
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
            return
        }

        guard rateLimiter.take() else {
            respond(.failure(.rateLimited, "Too many requests on this connection. Slow down and retry."))
            return
        }
        let request: IPCRequest
        switch LiovaWire.decodeRequest(Data(line)) {
        case let .success(decoded): request = decoded
        case let .failure(error): respond(.failure(error)); return
        }
        do {
            try LiovaValidation.validate(request.command)
        } catch {
            respond(.failure(error))
            return
        }
        if case .ping = request.command {
            respond(.success())
            return
        }
        dispatch(request.command)
    }

    private func dispatch(_ command: IPCCommand) {
        let handler = handler
        let client = client
        let queue = queue
        inFlight = Task { [weak self] in
            let response = await handler.handle(command, client: client)
            guard let self else { return }
            queue.async { self.handlerFinished(with: response) }
        }
        updateReadInterest()
    }

    private func handlerFinished(with response: IPCResponse) {
        guard !closed else { return }
        inFlight = nil
        scheduleIdleTimer()
        respond(response)
        processInput()
    }
}

extension ServerConnection {
    // MARK: Writing

    private static let fallbackLine = Array(
        #"{"error":{"code":"internal","message":"Couldn't encode the response."},"ok":false,"v":1}"#.utf8
    ) + [0x0A]

    private func respond(_ response: IPCResponse) {
        var response = response
        response.serverVersion = LiovaPluginKit.apiVersion
        if let line = try? LiovaWire.encodeLine(response) {
            output.append(contentsOf: line)
        } else {
            output.append(contentsOf: Self.fallbackLine)
        }
        flush()
    }

    /// Sends a last response, then closes once it's written.
    private func finish(with response: IPCResponse) {
        closeWhenFlushed = true
        input.removeAll()
        updateReadInterest()
        respond(response)
    }

    private func flush() {
        guard !closed else { return }
        while !output.isEmpty {
            let written = output.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                output.removeFirst(written)
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            if written < 0, errno == EAGAIN {
                break
            }
            close() // EPIPE, ECONNRESET...: the client is gone.
            return
        }
        scheduleIdleTimer()
        if output.isEmpty {
            setWriteInterest(false)
            if closeWhenFlushed {
                close()
            }
        } else {
            setWriteInterest(true)
        }
    }

    private func setWriteInterest(_ wanted: Bool) {
        if wanted {
            if let writeSource {
                if writeSuspended {
                    writeSuspended = false
                    writeSource.resume()
                }
            } else {
                let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.writable() }
                writeSource = source
                source.activate()
            }
        } else if let writeSource, !writeSuspended {
            writeSuspended = true
            writeSource.suspend()
        }
    }

    private func writable() {
        flush()
        if !closed, output.isEmpty {
            processInput()
        }
    }

    // MARK: Lifetime

    private func scheduleIdleTimer() {
        let timeout = max(configuration.idleTimeout, 0.001)
        let leeway = DispatchTimeInterval.milliseconds(Int(min(timeout * 100, 1000))) // 10%, at most 1 s
        idleTimer?.schedule(deadline: .now() + timeout, leeway: leeway)
    }

    private func idleTimerFired() {
        guard !closed else { return }
        if inFlight != nil {
            scheduleIdleTimer() // The handler is slow, not the client.
            return
        }
        close()
    }

    /// Tears everything down. The fd is closed once every source has finished cancelling, so
    /// a recycled descriptor number can never be seen by a stale source.
    func close() {
        guard !closed else { return }
        closed = true
        inFlight?.cancel()
        inFlight = nil
        idleTimer?.cancel()
        idleTimer = nil

        let sources: [(source: any DispatchSourceProtocol, suspended: Bool)] =
            [readSource.map { ($0, readSuspended) }, writeSource.map { ($0, writeSuspended) }].compactMap(\.self)
        readSource = nil
        writeSource = nil
        if sources.isEmpty {
            Darwin.close(fd)
        } else {
            let releaser = DescriptorReleaser(fd: fd, sourceCount: sources.count)
            for (source, suspended) in sources {
                source.setCancelHandler { releaser.sourceDidCancel() }
                // A suspended source never delivers its cancellation.
                if suspended {
                    source.resume()
                }
                source.cancel()
            }
        }
        input.removeAll()
        output.removeAll()
        onClose(client.connectionID)
    }
}

/// Closes a descriptor after the last of its dispatch sources has cancelled. Only used on the
/// server queue, where cancel handlers run serially.
private final class DescriptorReleaser: @unchecked Sendable {
    private let fd: Int32
    private var remaining: Int

    init(fd: Int32, sourceCount: Int) {
        self.fd = fd
        remaining = sourceCount
    }

    func sourceDidCancel() {
        remaining -= 1
        if remaining == 0 {
            close(fd)
        }
    }
}
