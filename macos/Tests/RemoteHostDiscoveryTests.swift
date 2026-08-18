import Testing
import Foundation
@testable import trm

/// Identifying this machine's own Bonjour advertisement so it is never
/// offered — or worse, auto-picked — as a remote pane target.
@MainActor
struct RemoteHostDiscoveryTests {

    @Test func serviceNameMapsToResolvableLocalName() {
        #expect(RemoteHostDiscovery.mdnsHostname(forServiceName: "Gaurav's Mac mini")
                == "Gaurav-s-Mac-mini.local")
        #expect(RemoteHostDiscovery.mdnsHostname(forServiceName: "mini")
                == "mini.local")
    }

    @Test func alreadyQualifiedNamePassesThrough() {
        // The always-on LaunchAgent registers "<LocalHostName>.local"
        // directly as the instance name.
        #expect(RemoteHostDiscovery.mdnsHostname(forServiceName: "mini.local")
                == "mini.local")
    }

    @Test func ownHostnameMatchesCaseInsensitively() {
        // LocalHostName keeps macOS's mixed case ("Gauravs-MacBook-Pro")
        // while DNS-derived names are typically lowercase. The advertisement
        // and the filter reach the name through different APIs, so a
        // case-sensitive compare lets the machine discover itself.
        let localNames: Set<String> = ["gauravs-macbook-pro.local"]
        #expect(RemoteHostDiscovery.isOwnHostname(
            "Gauravs-MacBook-Pro.local", localNames: localNames))
        #expect(RemoteHostDiscovery.isOwnHostname(
            "gauravs-macbook-pro.local", localNames: localNames))
        #expect(!RemoteHostDiscovery.isOwnHostname(
            "mini.local", localNames: localNames))
    }

    @Test func advertisedNameIsAlwaysInOwnNameSet() {
        // Whatever name this machine advertises under must be caught by the
        // self-filter, or a lone machine offers itself as the only "remote"
        // host and the no-dialog auto-pick connects a pane to itself.
        let advertised = RemoteHostDiscovery.mdnsHostname(
            forServiceName: RemoteHostDiscovery.localHostName)
        #expect(RemoteHostDiscovery.isOwnHostname(
            advertised, localNames: RemoteHostDiscovery.localMdnsNames))
    }
}
