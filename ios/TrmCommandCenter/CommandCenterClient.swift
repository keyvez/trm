import Combine
import Foundation
import Network
import SwiftUI

/// One agent, as a Mac's Command Center describes it.
struct BoardEntry: Identifiable, Equatable {
    /// Opaque row address, minted by the Mac: `pane:7` for something in one of
    /// its windows, `session:trm-a3335756` for a session it hosts with no pane
    /// open. The phone never parses it — it sends it back to reply.
    let id: String
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
    /// True for a session running on the Mac with nothing attached to it. The
    /// agent is live either way; the difference is only whether a window is
    /// open on it, which is worth saying because it explains why the row can't
    /// be revealed by walking over to the machine.
    let detached: Bool
    let updatedAt: Date?

    /// Which Mac published this row. Stamped by the link that received it,
    /// not carried on the wire — a machine has no need to tell you its own
    /// name on every row.
    var machine: String = ""

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
        guard let watermark = json["watermark"] as? String else { return nil }
        // Protocol 2 addresses rows by an opaque id. A pane number is still
        // accepted so a phone that updated first can talk to a Mac that
        // hasn't — it degrades to panes-only rather than to a blank board.
        if let id = json["id"] as? String {
            self.id = id
        } else if let pane = json["pane"] as? Int {
            self.id = "pane:\(pane)"
        } else {
            return nil
        }
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
        detached = json["detached"] as? Bool ?? false
        updatedAt = (json["updatedAt"] as? Double).map(Date.init(timeIntervalSince1970:))
    }
}

/// Where a Mac lives and how to prove we're allowed to talk to it.
struct Pairing: Codable, Equatable, Identifiable {
    var name: String
    /// The address currently believed to work; the first candidate until one
    /// proves itself.
    var host: String
    /// Every address the Mac said it answers to, best first — Tailscale, then
    /// its Bonjour name, then LAN addresses. A phone moves between networks
    /// and only one of these is right at a time.
    var hosts: [String] = []
    var port: UInt16
    var token: String

    /// The machine's name identifies the pairing: scanning a Mac's code again
    /// after its token was rotated should replace that Mac's entry rather than
    /// leaving a dead one beside a live one.
    var id: String { name }

    /// Parse the `trm://pair?…` URL a Mac shows as a QR code.
    init?(url: URL) {
        guard url.scheme == "trm", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value,
              let portString = items.first(where: { $0.name == "port" })?.value,
              let port = UInt16(portString) else { return nil }
        let name = items.first(where: { $0.name == "name" })?.value ?? "Mac"
        self.name = name
        let advertised = (items.first(where: { $0.name == "hosts" })?.value ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let single = items.first(where: { $0.name == "host" })?.value
        let candidates = advertised.isEmpty
            ? [single ?? "\(name).local"].compactMap { $0 }
            : advertised
        self.hosts = candidates
        self.host = candidates.first ?? "\(name).local"
        self.port = port
        self.token = token
    }

    init(name: String, host: String, hosts: [String] = [], port: UInt16, token: String) {
        self.name = name
        self.host = host
        self.hosts = hosts.isEmpty ? [host] : hosts
        self.port = port
        self.token = token
    }
}

/// What one machine's connection is doing.
enum LinkState: Equatable {
    case idle
    case connecting
    case connected(host: String)
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// The connection to one Mac and the board it publishes.
///
/// One of these per paired machine, each dialling its own machine directly.
/// That is the point of pairing with more than one: the mini's agents stay
/// visible when the laptop is shut, because nothing about reaching the mini
/// goes through the laptop.
///
/// One long-lived TCP connection carrying newline-delimited JSON, reconnecting
/// when the phone wakes or changes network. The Mac pushes the board; the
/// phone only ever sends a message it was asked to deliver.
@MainActor
final class MachineLink: ObservableObject, Identifiable {

    @Published private(set) var state: LinkState = .idle
    @Published private(set) var entries: [BoardEntry] = []
    /// Rows whose reply is in flight, so one can show it was sent.
    @Published private(set) var sending: Set<String> = []
    /// Scrollback per row, as the Mac last sent it.
    @Published private(set) var scrollback: [String: String] = [:]
    /// Why a row has no scrollback, when there is a reason worth saying.
    @Published private(set) var scrollbackNote: [String: String] = [:]
    /// Rows with a scrollback request in flight.
    @Published private(set) var loadingScrollback: Set<String> = []
    @Published private(set) var pairing: Pairing

    /// Called when the link learns something worth persisting — which address
    /// actually answered — so the next launch starts there.
    var onPairingLearned: ((Pairing) -> Void)?

    nonisolated var id: String { name }
    nonisolated let name: String

    private var connection: NWConnection?
    private var buffer = Data()
    private var reconnectAttempts = 0
    /// Which candidate address is being tried right now.
    private var candidateIndex = 0
    /// Cancelled when a candidate answers; fires when it doesn't.
    private var candidateTimeout: DispatchWorkItem?
    /// Set while the link is being torn down, so a cancelled connection
    /// doesn't schedule a reconnect to a machine that was just unpaired.
    private var isRetired = false

    init(pairing: Pairing) {
        self.pairing = pairing
        self.name = pairing.name
    }

    // MARK: - Connection

    func connect() {
        guard !isRetired else { return }
        candidateIndex = 0
        connectToCandidate()
    }

    /// Try the current candidate, moving to the next when it doesn't answer.
    ///
    /// A Mac's Bonjour name and its Tailscale address are both true, in
    /// different places, and the phone can't know which one it is standing in
    /// — so it asks them in order rather than guessing.
    private func connectToCandidate() {
        disconnect()
        guard !isRetired else { return }
        let candidates = pairing.hosts.isEmpty ? [pairing.host] : pairing.hosts
        guard candidateIndex < candidates.count else {
            // Name every endpoint that was dialled. "Couldn't reach it" sends
            // you to check the Mac; "couldn't reach it at 100.93.182.104:51735"
            // tells you whether the phone is even aiming at the right machine
            // and port, which is the actual question when pairing goes stale.
            let tried = candidates
                .map { "\($0):\(pairing.port)" }
                .joined(separator: "\n")
            state = .failed("Couldn't reach \(pairing.name). Tried:\n\(tried)")
            candidateIndex = 0
            scheduleReconnect()
            return
        }
        let candidate = candidates[candidateIndex]
        state = .connecting

        // Don't sit on an address that isn't answering: a wrong one usually
        // hangs rather than refuses, and there is another to try.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.candidateIndex += 1
            self.connectToCandidate()
        }
        candidateTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)

        let host = NWEndpoint.Host(candidate)
        let port = NWEndpoint.Port(rawValue: pairing.port) ?? .any
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let connection = NWConnection(host: host, port: port, using: params)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.isRetired else { return }
                switch state {
                case .ready:
                    self.candidateTimeout?.cancel()
                    self.reconnectAttempts = 0
                    // Remember what worked, so the next launch starts there.
                    if self.pairing.host != candidate {
                        self.pairing.host = candidate
                        self.onPairingLearned?(self.pairing)
                    }
                    self.send(["type": "hello", "token": self.pairing.token, "client": "iphone"])
                    self.receive()
                case .failed:
                    self.candidateTimeout?.cancel()
                    self.candidateIndex += 1
                    self.connectToCandidate()
                case .cancelled:
                    break
                case .waiting(let error):
                    // Still trying; the timeout above moves on if it stays
                    // stuck. The endpoint goes in the message because this is
                    // where "Connection refused" (POSIX 61) surfaces, and a
                    // refusal without an address can't be acted on — it is
                    // equally consistent with the right Mac not listening and
                    // with the phone holding a stale port from an old pairing.
                    self.state = .failed(
                        "\(error.localizedDescription)\n\(candidate):\(self.pairing.port)"
                    )
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    func disconnect() {
        candidateTimeout?.cancel()
        candidateTimeout = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
    }

    /// Stop for good. Unlike `disconnect`, nothing reconnects afterwards.
    func retire() {
        isRetired = true
        disconnect()
        entries = []
        state = .idle
    }

    /// Reconnect with a backoff. A phone spends most of its life asleep or on
    /// a different network, so dropping is the normal case, not the error one.
    private func scheduleReconnect() {
        guard !isRetired else { return }
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isRetired else { return }
            if self.state.isConnected { return }
            self.connect()
        }
    }

    func refresh() { send(["type": "refresh"]) }

    /// Ask for the terminal behind a row — what the pane would be showing if
    /// you were sitting in front of it.
    func requestScrollback(for rowId: String, lines: Int = 400) {
        loadingScrollback.insert(rowId)
        send(["type": "history", "id": rowId, "lines": lines])
    }

    /// Type a message into one of this machine's rows.
    ///
    /// Sends the pane number alongside the row id when the row has one, so a
    /// Mac still on protocol 1 can deliver the reply. The two ends get updated
    /// on their own schedules — there are several Macs — and a board that
    /// draws fine while silently dropping every reply is the worst way for
    /// that gap to show up.
    func send(text: String, to rowId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sending.insert(rowId)
        var payload: [String: Any] = ["type": "send", "id": rowId, "text": trimmed]
        if rowId.hasPrefix("pane:"), let pane = Int(rowId.dropFirst("pane:".count)) {
            payload["pane"] = pane
        }
        send(payload)
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
                guard let self, !self.isRetired else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    while let newline = self.buffer.firstIndex(of: 0x0a) {
                        let line = self.buffer[self.buffer.startIndex..<newline]
                        self.buffer.removeSubrange(self.buffer.startIndex...newline)
                        if !line.isEmpty { self.handle(Data(line)) }
                    }
                }
                if isComplete || error != nil {
                    let reason = error?.localizedDescription ?? "Disconnected"
                    self.state = .failed("\(reason)\n\(self.pairing.host):\(self.pairing.port)")
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
            state = .connected(host: object["host"] as? String ?? pairing.name)
        case "snapshot":
            let rows = object["entries"] as? [[String: Any]] ?? []
            entries = rows.compactMap(BoardEntry.init(json:)).map { row in
                var row = row
                row.machine = name
                return row
            }
            sending.removeAll()
        case "history":
            guard let id = object["id"] as? String else { return }
            loadingScrollback.remove(id)
            scrollback[id] = object["text"] as? String ?? ""
            if let note = object["note"] as? String, !note.isEmpty {
                scrollbackNote[id] = note
            } else {
                scrollbackNote.removeValue(forKey: id)
            }
        case "ack":
            if let id = object["id"] as? String {
                sending.remove(id)
            } else if let pane = object["pane"] as? Int {
                sending.remove("pane:\(pane)")
            }
        case "error":
            state = .failed(object["message"] as? String ?? "Refused")
        default:
            break
        }
    }
}

/// Every paired Mac, each on its own connection.
///
/// The board is the union of what they publish, kept grouped by machine: a
/// row's watermark means something only next to the machine it is on, and a
/// machine that is unreachable is itself worth seeing — "the mini has nothing
/// running" and "the mini can't be reached" are different answers and must not
/// share a screen.
@MainActor
final class CommandCenterClient: ObservableObject {

    @Published private(set) var links: [MachineLink] = []

    private var cancellables: Set<AnyCancellable> = []

    private static let pairingsKey = "pairings"
    /// The single-pairing key this replaced. Read once, then left alone.
    private static let legacyPairingKey = "pairing"

    init() {
        for pairing in Self.loadPairings() { attach(pairing) }
    }

    // MARK: - Board

    /// Every row from every machine, for counts and badges. The board itself
    /// draws them per machine rather than from this.
    var entries: [BoardEntry] { links.flatMap(\.entries) }

    var isPaired: Bool { !links.isEmpty }

    /// True once every machine has either answered or given a reason. Until
    /// then an empty board means "still asking", not "nothing running".
    var hasSettled: Bool {
        links.allSatisfy { link in
            switch link.state {
            case .connected, .failed: return true
            case .idle, .connecting: return false
            }
        }
    }

    // MARK: - Pairing

    /// Add a machine, or replace it if it is already paired.
    ///
    /// Replacing rather than duplicating is what makes re-scanning a code the
    /// fix for a rotated token: the same Mac comes back with new credentials
    /// instead of appearing twice, once working and once not.
    func pair(_ pairing: Pairing) {
        if let existing = links.first(where: { $0.name == pairing.name }) {
            existing.retire()
            links.removeAll { $0 === existing }
        }
        attach(pairing)
        persist()
    }

    func unpair(_ link: MachineLink) {
        link.retire()
        links.removeAll { $0 === link }
        persist()
    }

    func unpairAll() {
        for link in links { link.retire() }
        links.removeAll()
        persist()
    }

    private func attach(_ pairing: Pairing) {
        let link = MachineLink(pairing: pairing)
        link.onPairingLearned = { [weak self] _ in self?.persist() }
        // A child's changes are the parent's changes: SwiftUI observes the
        // client, and without this a machine coming online would update
        // nothing on screen.
        link.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        links.append(link)
        link.connect()
    }

    // MARK: - Actions

    /// Bring up anything not already up. Called when the app appears; a phone
    /// that has been asleep usually has every link in `failed` waiting on a
    /// backoff, and the person looking at the screen is a better signal than
    /// the timer.
    func connect() {
        for link in links where !link.state.isConnected { link.connect() }
    }

    func refresh() {
        for link in links {
            if link.state.isConnected { link.refresh() } else { link.connect() }
        }
    }

    /// Send a reply to whichever machine published the row.
    func send(text: String, to entry: BoardEntry) {
        guard let link = links.first(where: { $0.name == entry.machine }) else { return }
        link.send(text: text, to: entry.id)
    }

    func link(for entry: BoardEntry) -> MachineLink? {
        links.first { $0.name == entry.machine }
    }

    func requestScrollback(for entry: BoardEntry) {
        link(for: entry)?.requestScrollback(for: entry.id)
    }

    func isSending(_ entry: BoardEntry) -> Bool {
        links.first(where: { $0.name == entry.machine })?.sending.contains(entry.id) ?? false
    }

    // MARK: - Persistence

    private func persist() {
        let pairings = links.map(\.pairing)
        UserDefaults.standard.set(
            (try? JSONEncoder().encode(pairings)) ?? Data(), forKey: Self.pairingsKey)
    }

    private static func loadPairings() -> [Pairing] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: pairingsKey),
           let list = try? JSONDecoder().decode([Pairing].self, from: data) {
            return list
        }
        // One-time migration from when the phone could only hold one Mac.
        // Left in place rather than deleted: a downgrade should still find it.
        if let data = defaults.data(forKey: legacyPairingKey), !data.isEmpty,
           let single = try? JSONDecoder().decode(Pairing.self, from: data) {
            defaults.set((try? JSONEncoder().encode([single])) ?? Data(), forKey: pairingsKey)
            return [single]
        }
        return []
    }
}
