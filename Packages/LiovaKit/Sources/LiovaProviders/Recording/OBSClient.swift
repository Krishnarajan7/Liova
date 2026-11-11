import CryptoKit
import Foundation

/// OBS's recording, as its WebSocket server reports it.
public struct OBSRecording: Equatable, Sendable {
    public var isPaused: Bool
    /// How much has been recorded, not counting pauses, as of `measuredAt`.
    public var elapsed: TimeInterval
    public var measuredAt: Date

    public init(isPaused: Bool, elapsed: TimeInterval, measuredAt: Date) {
        self.isPaused = isPaused
        self.elapsed = elapsed
        self.measuredAt = measuredAt
    }
}

public enum OBSConnection: Equatable, Sendable {
    case disconnected
    case connecting
    /// OBS is open but its WebSocket server is off (Tools → WebSocket Server Settings).
    case serverOff
    /// The server asks for a password and Liova has none, or the wrong one.
    case needsPassword
    case connected(recording: OBSRecording?)
}

@MainActor
public protocol OBSControlling: AnyObject {
    var connection: OBSConnection { get }
    func connect(password: String?, onChange: @escaping @MainActor (OBSConnection) -> Void)
    func disconnect()
    func send(_ command: OBSCommand)
}

public enum OBSCommand: String, Sendable {
    case start = "StartRecord"
    case stop = "StopRecord"
    case pause = "PauseRecord"
    case resume = "ResumeRecord"
    case status = "GetRecordStatus"
}

/// Talks to OBS over obs-websocket 5 (built into OBS 28 and later) on this Mac only:
/// recording state changes arrive as events, so nothing is polled.
@MainActor
public final class OBSClient: OBSControlling {
    public private(set) var connection = OBSConnection.disconnected
    private let url: URL
    private let session = URLSession(configuration: .ephemeral)
    private var task: URLSessionWebSocketTask?
    private var password: String?
    private var onChange: (@MainActor (OBSConnection) -> Void)?
    private var requestNumber = 0

    public init(port: Int = 4455) {
        url = URL(string: "ws://127.0.0.1:\(port)")!
    }

    public func connect(password: String?, onChange: @escaping @MainActor (OBSConnection) -> Void) {
        disconnect()
        self.password = password
        self.onChange = onChange
        let task = session.webSocketTask(with: url)
        self.task = task
        set(.connecting)
        task.resume()
        receive(on: task)
    }

    public func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        onChange = nil
        connection = .disconnected
    }

    public func send(_ command: OBSCommand) {
        requestNumber += 1
        send(opcode: 6, data: ["requestType": command.rawValue, "requestId": "\(command.rawValue)-\(requestNumber)"])
    }

    // MARK: - Messages

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case let .success(.string(text)):
                    self.handle(Data(text.utf8))
                    self.receive(on: task)
                case let .success(.data(data)):
                    self.handle(data)
                    self.receive(on: task)
                case .success:
                    self.receive(on: task)
                case .failure:
                    self.closed(code: task.closeCode)
                }
            }
        }
    }

    private func closed(code: URLSessionWebSocketTask.CloseCode) {
        task = nil
        // 4009: authentication failed.
        if code.rawValue == 4009 {
            set(.needsPassword)
        } else {
            set(connection == .connecting ? .serverOff : .disconnected)
        }
    }

    private func handle(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let opcode = message["op"] as? Int, let payload = message["d"] as? [String: Any]
        else { return }
        switch opcode {
        case 0: hello(payload)
        case 2:
            set(.connected(recording: nil))
            send(.status)
        case 5: event(payload)
        case 7: response(payload)
        default: break
        }
    }

    private func hello(_ payload: [String: Any]) {
        var identify: [String: Any] = ["rpcVersion": 1, "eventSubscriptions": 1 << 6] // Outputs
        if let auth = payload["authentication"] as? [String: Any],
           let challenge = auth["challenge"] as? String, let salt = auth["salt"] as? String
        {
            guard let password, !password.isEmpty else {
                set(.needsPassword)
                task?.cancel(with: .normalClosure, reason: nil)
                task = nil
                return
            }
            identify["authentication"] = Self.authentication(password: password, salt: salt, challenge: challenge)
        }
        send(opcode: 1, data: identify)
    }

    private func event(_ payload: [String: Any]) {
        guard payload["eventType"] as? String == "RecordStateChanged" else { return }
        // The event says what changed; the status says for how long.
        send(.status)
        if let data = payload["eventData"] as? [String: Any], data["outputActive"] as? Bool == false,
           data["outputState"] as? String == "OBS_WEBSOCKET_OUTPUT_STOPPED"
        {
            set(.connected(recording: nil))
        }
    }

    private func response(_ payload: [String: Any]) {
        guard payload["requestType"] as? String == OBSCommand.status.rawValue,
              let data = payload["responseData"] as? [String: Any]
        else { return }
        set(.connected(recording: Self.recording(from: data, at: Date())))
    }

    private func send(opcode: Int, data: [String: Any]) {
        guard let task, let json = try? JSONSerialization.data(withJSONObject: ["op": opcode, "d": data]),
              let text = String(data: json, encoding: .utf8)
        else { return }
        task.send(.string(text)) { _ in }
    }

    private func set(_ new: OBSConnection) {
        guard new != connection else { return }
        connection = new
        onChange?(new)
    }

    // MARK: - Pure parts, unit-tested

    /// obs-websocket's handshake: base64(sha256(base64(sha256(password + salt)) + challenge)).
    nonisolated static func authentication(password: String, salt: String, challenge: String) -> String {
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
    }

    nonisolated static func recording(from status: [String: Any], at date: Date) -> OBSRecording? {
        guard status["outputActive"] as? Bool == true else { return nil }
        let milliseconds = (status["outputDuration"] as? NSNumber)?.doubleValue ?? 0
        return OBSRecording(
            isPaused: status["outputPaused"] as? Bool ?? false,
            elapsed: milliseconds / 1000,
            measuredAt: date
        )
    }
}
