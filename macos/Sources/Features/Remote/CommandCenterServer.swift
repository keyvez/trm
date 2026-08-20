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
    ///
    /// 2 addresses rows by an opaque `id` (`pane:7`, `session:trm-a3335756`)
    /// instead of a pane number, because the board now carries rows that have
    /// no pane on this machine at all — the sessions it hosts.
    static let protocolVersion = 2

    /// The port to ask for, so a paired phone keeps working across restarts.
    ///
    /// An ephemeral port made every pairing code expire the next time trm
    /// launched: the phone kept dialling the old number and got "connection
    /// refused", which reads exactly like a broken server. The port is
    /// remembered and re-requested; if something else has taken it, a new one
    /// is chosen and remembered instead — and the code has to be scanned
    /// again, which is at least rare rather than every launch.
    static let preferredPort: UInt16 = 51735

    private static var rememberedPort: UInt16 {
        get {
            let saved = UserDefaults.standard.integer(forKey: "CommandCenterServerPort")
            return saved > 0 && saved <= 65535 ? UInt16(saved) : preferredPort
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: "CommandCenterServerPort") }
    }

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

    /// Whether this Mac serves the Command Center, remembered across launches.
    ///
    /// A paired phone is paired with the *machine*, not with one run of the
    /// app: leaving the server tied to the pairing dialog meant every relaunch
    /// silently dropped the phone, with nothing on either end saying so. Set
    /// by pairing, cleared by Stop Serving.
    static var isEnabledByDefault: Bool {
        get { UserDefaults.standard.bool(forKey: "CommandCenterServerEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "CommandCenterServerEnabled") }
    }

    /// Bring the server back up if it was serving when trm last quit.
    static func startIfPreviouslyEnabled() {
        guard isEnabledByDefault else { return }
        shared.start()
    }

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
    ///
    /// Carries *every* address this Mac answers to rather than one, because
    /// the right one depends on where the phone is standing: a Bonjour name
    /// works on the same Wi-Fi and nowhere else, while a Tailscale address
    /// works from anywhere and means nothing to a phone that isn't on the
    /// tailnet. The phone tries them in order, so the code stays true when you
    /// leave the house.
    func pairingURL() -> URL? {
        guard let port else { return nil }
        var components = URLComponents()
        components.scheme = "trm"
        components.host = "pair"
        components.queryItems = [
            .init(name: "name", value: Host.current().localizedName ?? NSUserName()),
            .init(name: "port", value: String(port)),
            .init(name: "hosts", value: Self.reachableAddresses().joined(separator: ",")),
            .init(name: "token", value: token),
        ]
        return components.url
    }

    /// Addresses this Mac can be reached at, best first.
    ///
    /// Tailscale leads: it is the one that survives leaving the network, and a
    /// phone that has it will get there. Then the Bonjour name for the same
    /// Wi-Fi, then any private LAN address as a last resort — some networks
    /// block mDNS but route fine.
    static func reachableAddresses() -> [String] {
        // The tailnet address comes from the same place remote panes get
        // theirs, so a phone and a pane agree about where this Mac is.
        var tailscale: [String] = RemoteHostDiscovery.tailscaleAddress.map { [$0] } ?? []
        var lan: [String] = []

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [bonjourName] }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0,
                  let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)

            // Tailscale hands out 100.64.0.0/10, the carrier-grade NAT range.
            let parts = text.split(separator: ".").compactMap { UInt8($0) }
            guard parts.count == 4 else { continue }
            if parts[0] == 100, parts[1] >= 64, parts[1] <= 127 {
                if !tailscale.contains(text) { tailscale.append(text) }
            } else if parts[0] == 192 && parts[1] == 168
                        || parts[0] == 10
                        || (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) {
                lan.append(text)
            }
        }

        return tailscale + [bonjourName] + lan
    }

    /// The name this Mac answers to on the local network.
    static var bonjourName: String {
        let name = (Host.current().localizedName ?? NSUserName())
            .replacingOccurrences(of: " ", with: "-")
        return name.hasSuffix(".local") ? name : name + ".local"
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
        Self.isEnabledByDefault = true
        startListener(on: Self.rememberedPort)
    }

    /// Bring up a listener, falling back to any free port if the one we want
    /// is taken.
    private func startListener(on preferred: UInt16?) {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            // Reload Latest UI deliberately overlaps the old and new app, so
            // the new one asks for a port the outgoing one still holds.
            // Without this it fell back to an ephemeral port — and every
            // phone paired to the old number got "connection refused".
            params.allowLocalEndpointReuse = true
            let listener: NWListener
            if let preferred, let port = NWEndpoint.Port(rawValue: preferred) {
                listener = try NWListener(using: params, on: port)
            } else {
                listener = try NWListener(using: params)
            }
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
                        // Only a *chosen* port is worth remembering. Recording
                        // a fallback would make one unlucky launch permanent,
                        // and the next start would ask for the wrong number
                        // rather than the one paired phones know.
                        if let port, preferred != nil { Self.rememberedPort = port }
                        Self.logger.info("Command Center server ready on port \(port ?? 0)")
                        self?.settle(port.map { .success($0) }
                            ?? .failure(StartupFailure(reason: "The server came up without a port.")))
                    case .failed(let error):
                        Self.logger.error("Command Center server failed: \(error.localizedDescription)")
                        // Most likely the remembered port is in use. Let go of
                        // it and take whatever is free rather than refusing to
                        // serve at all.
                        if preferred != nil {
                            Self.logger.info("Retrying the Command Center server on a free port")
                            self?.listener?.cancel()
                            self?.listener = nil
                            self?.startListener(on: nil)
                            return
                        }
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
            if preferred != nil {
                startListener(on: nil)
                return
            }
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
        Self.isEnabledByDefault = false
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
                // Close only once the refusal is actually on the wire.
                // Cancelling straight after `send` reset the connection before
                // the bytes left, so the phone saw a dropped socket and had
                // nothing to tell the user — observed while testing this.
                send(["type": "error", "message": "bad token"], to: client) { [weak self] in
                    client.connection.cancel()
                    self?.drop(client.connection)
                }
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
            // `id` is protocol 2. A phone still on 1 addresses by pane number
            // and never learns otherwise — it doesn't check the version we
            // send it — so accept both. Without this, an un-updated phone
            // keeps drawing a board and silently drops every reply, which is
            // the worst of the available failures.
            guard client.authenticated,
                  let text = object["text"] as? String else { return }
            let rowId: String
            if let id = object["id"] as? String {
                rowId = id
            } else if let pane = object["pane"] as? Int {
                rowId = "pane:\(pane)"
            } else {
                return
            }
            let delivered = deliver(text: text, to: rowId)
            // Ack carries both spellings for the same reason: an older phone
            // clears its in-flight row on `pane`, a current one on `id`.
            var ack: [String: Any] = ["type": "ack", "id": rowId, "delivered": delivered]
            if rowId.hasPrefix("pane:"), let pane = Int(rowId.dropFirst("pane:".count)) {
                ack["pane"] = pane
            }
            send(ack, to: client)
            // The reply changes the board; don't make the phone wait for the
            // next tick to see its own message land. A paneless session's row
            // is rebuilt by a scan rather than read live, so force one.
            CommandCenterMonitor.shared.refresh()
            HostSessionBoard.shared.refresh()
            send(snapshotPayload(), to: client)

        default:
            break
        }
    }

    /// Route a reply to whatever the row actually is.
    ///
    /// `pane:<id>` goes through the pane, exactly as the panel's compose box
    /// does — the surface is here, and typing into it is what the person at
    /// the desk would see happen. `session:<name>` has no pane on this
    /// machine and goes to the daemon directly.
    private func deliver(text: String, to rowId: String) -> Bool {
        if rowId.hasPrefix("pane:"), let paneId = Int(rowId.dropFirst("pane:".count)) {
            return deliver(text: text, toPaneId: paneId)
        }
        if rowId.hasPrefix("session:") {
            let name = String(rowId.dropFirst("session:".count))
            return HostSessionBoard.deliver(text: text, toSession: name)
        }
        return false
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
        // Cheap when the last scan is still fresh; the scan itself is slow and
        // runs on its own cadence.
        HostSessionBoard.shared.refreshIfStale()
        let payload = snapshotPayload()
        let hash = "\(payload)".hashValue
        guard hash != lastSnapshotHash else { return }
        lastSnapshotHash = hash
        for client in authenticated { send(payload, to: client) }
    }

    private func snapshotPayload() -> [String: Any] {
        var entries: [[String: Any]] = CommandCenterMonitor.shared.entries.map { entry in
            var row: [String: Any] = [
                "id": "pane:\(entry.paneId)",
                "pane": entry.paneId,
                "watermark": entry.watermark,
                "agent": entry.kind.displayName,
                "message": entry.message,
                "working": entry.isWorking,
                "needsAttention": entry.needsAttention,
                "errors": entry.errorCount,
            ]
            let briefing = CommandCenterMonitor.shared.briefings[entry.id]
            row["briefing"] = briefing?.sentence
            // Prose bullets or none — the phone shouldn't show a column of
            // command lines any more than the panel should.
            row["bullets"] = briefing?.bullets ?? []
            row["location"] = entry.location
            row["host"] = entry.host
            row["prompt"] = entry.prompt
            row["errorText"] = entry.errorText
            row["updatedAt"] = entry.updatedAt?.timeIntervalSince1970
            return row
        }

        // Then the agents this machine is running that nobody here is looking
        // at. From a phone these are the whole point: the sessions live on the
        // machine that hosts them, and whether a window happens to be open for
        // one says nothing about whether it needs you.
        entries += HostSessionBoard.shared.sessions.map { info in
            var row: [String: Any] = [
                "id": "session:\(info.name)",
                // A session name is a hash; the watermark is what the pane
                // called itself, and the only readable identity a paneless
                // row has. Falling back to the name is better than blank.
                "watermark": info.watermark ?? info.name,
                "agent": info.agentKind?.displayName ?? "shell",
                "message": info.summary ?? info.command ?? "",
                "working": info.isWorking,
                "needsAttention": info.needsAttention,
                "errors": 0,
                // Says the row has no pane here, so the phone can show it as
                // a session rather than implying there is a window to reveal.
                "detached": !info.attached,
            ]
            row["briefing"] = info.summary
            row["bullets"] = [String]()
            row["location"] = info.shortCwd
            row["prompt"] = info.lastPrompt
            return row
        }

        return ["type": "snapshot", "entries": entries]
    }

    private func send(
        _ payload: [String: Any], to client: Client, then finished: (() -> Void)? = nil
    ) {
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else {
            finished?()
            return
        }
        data.append(0x0a)
        guard let finished else {
            client.connection.send(content: data, completion: .idempotent)
            return
        }
        client.connection.send(content: data, completion: .contentProcessed { _ in
            Task { @MainActor in finished() }
        })
    }
}
