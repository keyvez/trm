import Foundation
import Network
import os

/// Serves the Command Center to trm's iPhone app.
///
/// The board answers "which of my agents needs me, and what do I say back",
/// and that question is at its most useful when you are not at the machine.
/// So the same entries the panel draws are published over the network, and a
/// phone can answer an agent the way the panel does — by typing into its pane.
///
/// Deliberately its own small protocol rather than opening Text Tap to the
/// network: Text Tap can drive anything in the app, while this can do exactly
/// two things — read the board and type a message into a pane it lists.
///
/// Newline-delimited JSON over TCP, discovered over Bonjour (`_trm-cc._tcp`),
/// gated by a token the phone gets once by scanning a QR code. It listens on
/// every interface because the useful case is a phone on the same Tailnet, not
/// only the same Wi-Fi; nothing is served until a connection presents the
/// token.
@MainActor
final class CommandCenterServer: ObservableObject {

    static let shared = CommandCenterServer()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.trm",
        category: "CommandCenterServer"
    )

    /// Bonjour service type for the phone to find.
    static let serviceType = "_trm-cc._tcp"

    /// Wire protocol version. The phone refuses a server it doesn't know.
    static let protocolVersion = 1

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16?
    @Published private(set) var connectedClients: Int = 0

    /// Why the listener didn't come up, in words a person can act on.
    struct StartupFailure: Error {
        let reason: String
    }

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var pushTimer: Timer?
    /// Callbacks waiting for the listener to settle, so the pairing dialog can
    /// show a code or a reason instead of guessing after a fixed delay.
    private var readinessWaiters: [(Result<UInt16, StartupFailure>) -> Void] = []
    /// Hash of the last snapshot sent, so an idle board sends nothing.
    private var lastSnapshotHash: Int?

    private init() {}

    // MARK: - Pairing

    /// Shared secret the phone must present. Generated once and kept in
    /// defaults — rotating it is how you revoke a phone.
    var token: String {
        if let existing = UserDefaults.standard.string(forKey: "CommandCenterToken"),
           !existing.isEmpty {
            return existing
        }
        let fresh = Self.freshToken()
        UserDefaults.standard.set(fresh, forKey: "CommandCenterToken")
        return fresh
    }

    @discardableResult
    func rotateToken() -> String {
        let fresh = Self.freshToken()
        UserDefaults.standard.set(fresh, forKey: "CommandCenterToken")
        // Everything holding the old one is now talking to nobody.
        for (_, client) in clients { client.connection.cancel() }
        clients.removeAll()
        connectedClients = 0
        return fresh
    }

    private static func freshToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Everything the phone needs, as a URL small enough to be a QR code.
    func pairingURL() -> URL? {
        guard let port else { return nil }
        var components = URLComponents()
        components.scheme = "trm"
        components.host = "pair"
        components.queryItems = [
            .init(name: "name", value: Host.current().localizedName ?? NSUserName()),
            .init(name: "port", value: String(port)),
            .init(name: "token", value: token),
        ]
        return components.url
    }

    // MARK: - Lifecycle

    /// Start serving and call back when the listener has actually settled.
    ///
    /// Not a fire-and-forget with a delay afterwards: coming up involves
    /// registering a Bonjour service and, on recent macOS, possibly waiting
    /// for the user to grant local network access — which took longer than the
    /// third of a second the pairing dialog used to allow, so pairing reported
    /// a server that "didn't come up" while it was still coming up.
    func start(completion: ((Result<UInt16, StartupFailure>) -> Void)? = nil) {
        if let completion {
            if let port, isRunning {
                completion(.success(port))
            } else {
                readinessWaiters.append(completion)
                // Never leave the dialog waiting forever on a listener that
                // neither succeeds nor fails.
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    self?.settle(.failure(StartupFailure(reason:
                        "The server didn't come up within ten seconds. If macOS asked for "
                        + "permission to use the local network, allow it and try again.")))
                }
            }
        }
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let listener = try NWListener(using: params)
            listener.service = NWListener.Service(
                name: Self.advertisedName,
                type: Self.serviceType,
                domain: nil,
                txtRecord: NWTXTRecord(["v": String(Self.protocolVersion)]).data
            )
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        let port = listener.port?.rawValue
                        self?.port = port
                        self?.isRunning = true
                        Self.logger.info("Command Center server ready on port \(port ?? 0)")
                        self?.settle(port.map { .success($0) }
                            ?? .failure(StartupFailure(reason: "The server came up without a port.")))
                    case .failed(let error):
                        Self.logger.error("Command Center server failed: \(error.localizedDescription)")
                        self?.settle(.failure(StartupFailure(reason: error.localizedDescription)))
                        self?.stop()
                    case .cancelled:
                        self?.isRunning = false
                        self?.port = nil
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener

            // The board is pushed rather than polled: a phone that has to ask
            // is a phone that is either out of date or draining its battery.
            CommandCenterMonitor.shared.subscribe()
            pushTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pushSnapshotIfChanged() }
            }
        } catch {
            Self.logger.error("Could not start Command Center server: \(error.localizedDescription)")
            settle(.failure(StartupFailure(reason: error.localizedDescription)))
        }
    }

    /// Hand the outcome to whoever is waiting, once.
    private func settle(_ result: Result<UInt16, StartupFailure>) {
        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        for waiter in waiters { waiter(result) }
    }

    func stop() {
        pushTimer?.invalidate()
        pushTimer = nil
        for (_, client) in clients { client.connection.cancel() }
        clients.removeAll()
        connectedClients = 0
        listener?.cancel()
        listener = nil
        isRunning = false
        port = nil
        lastSnapshotHash = nil
        CommandCenterMonitor.shared.unsubscribe()
    }

    func toggle() { isRunning || listener != nil ? stop() : start() }

    private static var advertisedName: String {
        Host.current().localizedName ?? NSUserName()
    }

    // MARK: - Connections

    /// One connected phone. Unauthenticated until it presents the token, and
    /// sent nothing until then.
    private final class Client {
        let connection: NWConnection
        var authenticated = false
        var buffer = Data()
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        clients[ObjectIdentifier(connection)] = client
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .cancelled:
                    self?.drop(connection)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection)
    }

    private func drop(_ connection: NWConnection) {
        clients.removeValue(forKey: ObjectIdentifier(connection))
        connectedClients = clients.values.filter(\.authenticated).count
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty { self.ingest(data, from: connection) }
                if isComplete || error != nil {
                    connection.cancel()
                    self.drop(connection)
                    return
                }
                self.receive(on: connection)
            }
        }
    }

    private func ingest(_ data: Data, from connection: NWConnection) {
        guard let client = clients[ObjectIdentifier(connection)] else { return }
        client.buffer.append(data)
        // A phone on a flaky link sends partial lines; frames are newline
        // delimited so a half-frame just waits for the rest.
        while let newline = client.buffer.firstIndex(of: 0x0a) {
            let line = client.buffer[client.buffer.startIndex..<newline]
            client.buffer.removeSubrange(client.buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            handle(line: Data(line), from: client)
        }
        // A client that never sends a newline must not grow the buffer forever.
        if client.buffer.count > 256 * 1024 {
            connection.cancel()
            drop(connection)
        }
    }

    private func handle(line: Data, from client: Client) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return }

        switch type {
        case "hello":
            // Constant-time-ish compare: the token is a hex string of fixed
            // length, so a plain equality check leaks nothing useful, but the
            // length check first avoids comparing against a huge input.
            let presented = object["token"] as? String ?? ""
            guard presented.count == token.count, presented == token else {
                send(["type": "error", "message": "bad token"], to: client)
                client.connection.cancel()
                drop(client.connection)
                return
            }
            client.authenticated = true
            connectedClients = clients.values.filter(\.authenticated).count
            send([
                "type": "welcome",
                "version": Self.protocolVersion,
                "host": Self.advertisedName,
            ], to: client)
            send(snapshotPayload(), to: client)

        case "refresh":
            guard client.authenticated else { return }
            CommandCenterMonitor.shared.refresh()
            send(snapshotPayload(), to: client)

        case "send":
            guard client.authenticated,
                  let paneId = object["pane"] as? Int,
                  let text = object["text"] as? String else { return }
            let delivered = deliver(text: text, toPaneId: paneId)
            send(["type": "ack", "pane": paneId, "delivered": delivered], to: client)
            // The reply changes the board; don't make the phone wait for the
            // next tick to see its own message land.
            CommandCenterMonitor.shared.refresh()
            send(snapshotPayload(), to: client)

        default:
            break
        }
    }

    /// Type a message into the pane behind an entry, exactly as the panel's
    /// compose box does.
    private func deliver(text: String, toPaneId paneId: Int) -> Bool {
        for controller in TerminalController.all {
            for surface in controller.surfaceTree where surface.paneId == paneId {
                controller.sendMessageToSurface(surface, text: text)
                return true
            }
        }
        return false
    }

    // MARK: - Snapshots

    private func pushSnapshotIfChanged() {
        let authenticated = clients.values.filter(\.authenticated)
        guard !authenticated.isEmpty else { return }
        let payload = snapshotPayload()
        let hash = "\(payload)".hashValue
        guard hash != lastSnapshotHash else { return }
        lastSnapshotHash = hash
        for client in authenticated { send(payload, to: client) }
    }

    private func snapshotPayload() -> [String: Any] {
        let entries: [[String: Any]] = CommandCenterMonitor.shared.entries.map { entry in
            var row: [String: Any] = [
                "pane": entry.paneId,
                "watermark": entry.watermark,
                "agent": entry.kind.displayName,
                "message": entry.message,
                "working": entry.isWorking,
                "needsAttention": entry.needsAttention,
                "errors": entry.errorCount,
            ]
            row["briefing"] = CommandCenterMonitor.shared.briefings[entry.id]
            row["location"] = entry.location
            row["host"] = entry.host
            row["prompt"] = entry.prompt
            row["errorText"] = entry.errorText
            row["updatedAt"] = entry.updatedAt?.timeIntervalSince1970
            return row
        }
        return ["type": "snapshot", "entries": entries]
    }

    private func send(_ payload: [String: Any], to client: Client) {
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0a)
        client.connection.send(content: data, completion: .idempotent)
    }
}
