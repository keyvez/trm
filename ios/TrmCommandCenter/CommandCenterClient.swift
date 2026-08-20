import Foundation
import Network
import SwiftUI

/// One agent, as the Mac's Command Center describes it.
struct BoardEntry: Identifiable, Equatable {
    let pane: Int
    let watermark: String
    let agent: String
    let message: String
    let briefing: String?
    let location: String?
    let host: String?
    let prompt: String?
    let errorText: String?
    let errors: Int
    let working: Bool
    let needsAttention: Bool
    let updatedAt: Date?

    var id: Int { pane }

    /// How much of your attention this is asking for, ranked by what it costs
    /// to ignore. Mirrors the Mac panel's own ordering so the phone and the
    /// desk agree about what is urgent.
    enum Status: String {
        case needsYou = "needs you"
        case checkThis = "check this"
        case working
        case idle

        var color: Color {
            switch self {
            case .needsYou: return .orange
            case .checkThis: return .red
            case .working: return .green
            case .idle: return .secondary
            }
        }
    }

    var status: Status {
        if needsAttention { return .needsYou }
        if errors > 0 { return .checkThis }
        if working { return .working }
        return .idle
    }

    /// The line to lead with: the Mac's one-sentence briefing when it made
    /// one, the raw message otherwise.
    var headline: String { briefing ?? message }

    init?(json: [String: Any]) {
        guard let pane = json["pane"] as? Int,
              let watermark = json["watermark"] as? String else { return nil }
        self.pane = pane
        self.watermark = watermark
        agent = json["agent"] as? String ?? "Agent"
        message = json["message"] as? String ?? ""
        briefing = json["briefing"] as? String
        location = json["location"] as? String
        host = json["host"] as? String
        prompt = json["prompt"] as? String
        errorText = json["errorText"] as? String
        errors = json["errors"] as? Int ?? 0
        working = json["working"] as? Bool ?? false
        needsAttention = json["needsAttention"] as? Bool ?? false
        updatedAt = (json["updatedAt"] as? Double).map(Date.init(timeIntervalSince1970:))
    }
}

/// Where a Mac lives and how to prove we're allowed to talk to it.
struct Pairing: Codable, Equatable {
    var name: String
    var host: String
    var port: UInt16
    var token: String

    /// Parse the `trm://pair?…` URL a Mac shows as a QR code.
    init?(url: URL) {
        guard url.scheme == "trm", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value,
              let portString = items.first(where: { $0.name == "port" })?.value,
              let port = UInt16(portString) else { return nil }
        let name = items.first(where: { $0.name == "name" })?.value ?? "Mac"
        self.name = name
        // The QR carries no address: the Mac may be on Wi-Fi now and a Tailnet
        // later, and its Bonjour name is the thing that stays true. A manually
        // entered host overrides this.
        self.host = items.first(where: { $0.name == "host" })?.value ?? "\(name).local"
        self.port = port
        self.token = token
    }

    init(name: String, host: String, port: UInt16, token: String) {
        self.name = name
        self.host = host
        self.port = port
        self.token = token
    }
}

/// Holds the connection to one Mac and the board it publishes.
///
/// Deliberately simple: one long-lived TCP connection carrying newline
/// delimited JSON, reconnecting when the phone comes back from sleep or
/// changes network. The Mac pushes the board; the phone only ever sends a
/// message it was asked to deliver.
@MainActor
final class CommandCenterClient: ObservableObject {

    enum State: Equatable {
        case idle
        case connecting
        case connected(host: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var entries: [BoardEntry] = []
    /// Panes whose reply is in flight, so a row can show it was sent.
    @Published private(set) var sending: Set<Int> = []

    @AppStorage("pairing") private var pairingData: Data = Data()

    private var connection: NWConnection?
    private var buffer = Data()
    private var reconnectAttempts = 0

    var pairing: Pairing? {
        get {
            guard !pairingData.isEmpty else { return nil }
            return try? JSONDecoder().decode(Pairing.self, from: pairingData)
        }
        set {
            pairingData = (try? JSONEncoder().encode(newValue)) ?? Data()
            connect()
        }
    }

    // MARK: - Connection

    func connect() {
        disconnect()
        guard let pairing else { state = .idle; return }
        state = .connecting

        let host = NWEndpoint.Host(pairing.host)
        let port = NWEndpoint.Port(rawValue: pairing.port) ?? .any
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let connection = NWConnection(host: host, port: port, using: params)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.reconnectAttempts = 0
                    self.send(["type": "hello", "token": pairing.token, "client": "iphone"])
                    self.receive()
                case .failed(let error):
                    self.state = .failed(error.localizedDescription)
                    self.scheduleReconnect()
                case .cancelled:
                    break
                case .waiting(let error):
                    self.state = .failed(error.localizedDescription)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        buffer.removeAll()
    }

    /// Reconnect with a backoff. A phone spends most of its life asleep or on
    /// a different network, so dropping is the normal case, not the error one.
    private func scheduleReconnect() {
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pairing != nil else { return }
            if case .connected = self.state { return }
            self.connect()
        }
    }

    func refresh() { send(["type": "refresh"]) }

    /// Type a message into a pane on the Mac.
    func send(text: String, toPane pane: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sending.insert(pane)
        send(["type": "send", "pane": pane, "text": trimmed])
    }

    private func send(_ payload: [String: Any]) {
        guard let connection, var data = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        data.append(0x0a)
        connection.send(content: data, completion: .idempotent)
    }

    // MARK: - Receive

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    while let newline = self.buffer.firstIndex(of: 0x0a) {
                        let line = self.buffer[self.buffer.startIndex..<newline]
                        self.buffer.removeSubrange(self.buffer.startIndex...newline)
                        if !line.isEmpty { self.handle(Data(line)) }
                    }
                }
                if isComplete || error != nil {
                    self.state = .failed(error?.localizedDescription ?? "Disconnected")
                    self.scheduleReconnect()
                    return
                }
                self.receive()
            }
        }
    }

    private func handle(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "welcome":
            state = .connected(host: object["host"] as? String ?? pairing?.name ?? "Mac")
        case "snapshot":
            let rows = object["entries"] as? [[String: Any]] ?? []
            entries = rows.compactMap(BoardEntry.init(json:))
            sending.removeAll()
        case "ack":
            if let pane = object["pane"] as? Int { sending.remove(pane) }
        case "error":
            state = .failed(object["message"] as? String ?? "Refused")
        default:
            break
        }
    }
}
