import Foundation
import Network
import os

/// Bonjour advertising and discovery for trm hosts on the local network.
///
/// Remote panes need an SSH destination, and typing `user@host` from memory is
/// the worst part of that flow. Every trm advertises itself over Bonjour, so
/// machines running trm on the same network can be picked from a list instead.
///
/// What is advertised is deliberately minimal — a hostname and the SSH port to
/// reach it on. trm does not open a network listener of its own for this: the
/// transport for a remote pane is plain SSH, already authenticated by the
/// user's keys. This only answers "which machines are around", never "let me
/// in". Discovery is LAN-scoped by Bonjour itself.
@MainActor
final class RemoteHostDiscovery {

    static let shared = RemoteHostDiscovery()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.trm",
        category: "RemoteHostDiscovery"
    )

    /// Bonjour service type. `_trm._tcp` under the standard local domain.
    static let serviceType = "_trm._tcp"

    /// A trm host found on the network.
    struct Host: Identifiable, Hashable {
        /// Bonjour instance name, typically the machine's sharing name.
        let name: String
        /// Hostname to SSH to (`endpointHost` or the resolved `.local` name).
        let hostname: String
        /// SSH port advertised by the host (22 unless overridden).
        let port: Int
        /// Account to log in as, when the host advertises one (`ssh_user`
        /// TXT entry). Machines don't share usernames, and a bare hostname
        /// makes ssh guess with the *connecting* machine's username.
        let user: String?

        var id: String { "\(name)|\(sshDestination):\(port)" }

        /// Destination string for an SSH command.
        var sshDestination: String {
            if let user { return "\(user)@\(hostname)" }
            return hostname
        }
    }

    /// Hosts currently visible on the network, excluding this machine.
    private(set) var hosts: [Host] = []

    /// Called whenever `hosts` changes, so UI can refresh.
    var onHostsChanged: (([Host]) -> Void)?

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]

    private init() {}

    // MARK: - Advertising

    /// Start advertising this machine as a trm host.
    ///
    /// The listener exists only to carry the Bonjour record — nothing is
    /// served on it, and it binds an ephemeral port. Remote panes connect over
    /// SSH, not to this port.
    func startAdvertising(sshPort: Int = 22) {
        guard listener == nil else { return }

        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = false
            let listener = try NWListener(using: params)

            let record = NWTXTRecord([
                "ssh_port": String(sshPort),
                "ssh_user": NSUserName(),
            ])
            listener.service = NWListener.Service(
                name: Self.localHostName,
                type: Self.serviceType,
                domain: nil,
                txtRecord: record.data
            )

            // Nothing is served here; accept and immediately close so a stray
            // connection can't accumulate state.
            listener.newConnectionHandler = { connection in
                connection.cancel()
            }
            // Captured up front: the handler runs off the main actor, where
            // the isolated `localHostName` can't be read.
            let advertisedName = Self.localHostName
            listener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    Self.logger.error("Bonjour advertising failed: \(error.localizedDescription)")
                case .ready:
                    Self.logger.info("Advertising as \(advertisedName) over Bonjour")
                default:
                    break
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            Self.logger.error("Could not start Bonjour advertising: \(error.localizedDescription)")
        }
    }

    func stopAdvertising() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Discovery

    /// Start browsing for other trm hosts.
    func startBrowsing() {
        guard browser == nil else { return }

        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: params
        )

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateHosts(from: results)
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Self.logger.error("Bonjour browsing failed: \(error.localizedDescription)")
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        hosts = []
    }

    /// Rebuild the host list from a browse result set.
    private func updateHosts(from results: Set<NWBrowser.Result>) {
        var found: [Host] = []
        let localMdns = Self.mdnsHostname(forServiceName: Self.localHostName)

        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }

            // Bonjour instance names are usually the sharing name; the
            // matching mDNS hostname is what SSH can actually resolve. An
            // always-on advertiser (scripts/install-bonjour-advertiser.sh)
            // registers the "<host>.local" name directly, so machines are
            // compared by hostname, not by instance name.
            let hostname = Self.mdnsHostname(forServiceName: name)

            // Don't offer this machine as a remote target.
            guard hostname != localMdns else { continue }

            var port = 22
            var user: String?
            if case let .bonjour(txt) = result.metadata {
                if case let .string(value) = txt.getEntry(for: "ssh_port"),
                   let parsed = Int(value), parsed > 0, parsed < 65536 {
                    port = parsed
                }
                // The username is interpolated into an ssh command
                // downstream, so hold TXT data (which any LAN peer can
                // publish) to the same strict character set destinations
                // are validated against.
                if case let .string(value) = txt.getEntry(for: "ssh_user"),
                   !value.isEmpty, value.count <= 64,
                   value.unicodeScalars.allSatisfy({ Self.allowedUserChars.contains($0) }) {
                    user = value
                }
            }

            found.append(Host(name: name, hostname: hostname, port: port, user: user))
        }

        // A machine can be advertised twice — by a running trm and by the
        // always-on LaunchAgent. One machine must be one entry, or "exactly
        // one host" flows (auto-pick without a dialog) break. When the two
        // records disagree on detail, the one that names a login user wins.
        found.sort {
            if ($0.user != nil) != ($1.user != nil) { return $0.user != nil }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        var seenDestinations = Set<String>()
        found = found.filter { seenDestinations.insert("\($0.hostname):\($0.port)").inserted }
        found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        guard found != hosts else { return }
        hosts = found
        onHostsChanged?(found)
    }

    /// Characters allowed in an advertised `ssh_user` value — the same set
    /// SSH destinations are validated against before shell interpolation.
    private static let allowedUserChars = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "._-"))

    // MARK: - Names

    /// This machine's Bonjour instance name.
    static var localHostName: String {
        // .localizedName is the user-facing sharing name; fall back to the
        // POSIX hostname when it isn't available.
        if let name = Host_localizedName(), !name.isEmpty { return name }
        return ProcessInfo.processInfo.hostName
    }

    private static func Host_localizedName() -> String? {
        // ProcessInfo.hostName returns e.g. "mac.local"; strip the domain so
        // the advertised name matches the sharing name users recognise.
        let raw = ProcessInfo.processInfo.hostName
        if let dot = raw.firstIndex(of: ".") {
            return String(raw[raw.startIndex..<dot])
        }
        return raw
    }

    /// Map a Bonjour instance name to a resolvable `.local` hostname.
    ///
    /// Sharing names allow spaces and other characters mDNS hostnames don't;
    /// macOS derives the hostname by replacing those with hyphens.
    static func mdnsHostname(forServiceName name: String) -> String {
        if name.hasSuffix(".local") { return name }
        let mapped = name.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "-" { return ch }
            return "-"
        }
        return String(mapped) + ".local"
    }
}
