import AppKit
import Combine
import Foundation

/// The agent sessions this machine *hosts*, as distinct from the panes it
/// *shows*.
///
/// The Command Center board has always been a view of panes — what is on
/// screen in this Mac's windows. That is the right answer at the desk and the
/// wrong one from a phone. A session runs in a zmx daemon on the machine that
/// hosts it, while the pane displaying it can live in a different Mac's
/// window over SSH, or in no window at all. So a mini with nine working
/// agents and no trm window open publishes an empty board, which is exactly
/// backwards: that is the machine doing all the work.
///
/// The published board is therefore the union of the two — panes this Mac
/// draws, plus sessions this Mac hosts that no local pane is showing. A phone
/// paired with the mini sees the mini's agents whether or not anyone is
/// looking at them, and one paired with the laptop still sees its panes.
///
/// Scanning is not free (several process spawns per session), so it runs on
/// its own slow cadence off the main actor rather than on the board's push
/// tick.
@MainActor
final class HostSessionBoard: ObservableObject {

    static let shared = HostSessionBoard()

    /// Sessions running here that no local pane displays, as of the last scan.
    @Published private(set) var sessions: [ZmxSessionManager.SessionInfo] = []

    /// How long a scan stays fresh. The board pushes every second; scanning at
    /// that rate would keep `lsof` and `zmx history` running continuously for
    /// a board nobody is necessarily looking at.
    private static let scanInterval: TimeInterval = 5

    private var isScanning = false
    private var lastScan: Date?

    private init() {}

    /// Rescan if the last one has gone stale. Safe to call on every push.
    func refreshIfStale() {
        if let lastScan, Date().timeIntervalSince(lastScan) < Self.scanInterval { return }
        refresh()
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true

        // Sessions that already have a pane here are the monitor's to publish:
        // it has a live surface behind them and types replies into the pane.
        // Publishing them from both places would put one agent on the board
        // twice, under two different addresses.
        //
        // `zmxSessionName` and not `remoteZmxSession` — the latter names a
        // daemon on another machine, which was never in this list to begin
        // with, and whose own trm is the one that should be publishing it.
        var shownLocally: Set<String> = []
        for controller in TerminalController.all {
            for surface in controller.surfaceTree {
                if let name = surface.zmxSessionName { shownLocally.insert(name) }
            }
        }

        // A watermark belongs to the pane in its saved window, not to the
        // daemon, so it comes from the session TOMLs rather than the scan.
        // Without it a paneless row is identified only by its session name,
        // which is a hash and tells you nothing.
        var watermarks: [String: String] = [:]
        for group in ZmxSessionManager.sessionGroups() {
            for (name, mark) in group.watermarks { watermarks[name] = mark }
        }

        let names = ZmxSessionManager.listSessions().filter { !shownLocally.contains($0) }
        guard !names.isEmpty else {
            sessions = []
            isScanning = false
            lastScan = Date()
            return
        }

        let referenced = ZmxSessionManager.referencedSessions()
        let attached = ZmxSessionManager.attachedSessions()
        // Cached for the session's lifetime, so this is usually free — but it
        // can shell out to `lsof`, which is why it happens here and not inside
        // the fan-out.
        var shellPids: [String: pid_t] = [:]
        for name in names {
            if let pid = ZmxSessionManager.cachedServerShellPid(session: name) {
                shellPids[name] = pid
            }
        }

        Task {
            // The flag must clear however the scan ends, or every later call
            // hits the guard above and the board silently freezes at whatever
            // it last held.
            defer {
                self.isScanning = false
                self.lastScan = Date()
            }
            let scanned = await Task.detached(priority: .utility) {
                ZmxSessionManager.allSessionInfoConcurrently(
                    names: names,
                    referenced: referenced,
                    attached: attached,
                    shellPids: shellPids
                )
            }.value
            self.sessions = scanned.map { info in
                var info = info
                info.watermark = watermarks[info.name]
                return info
            }
        }
    }

    /// Type a message into a session that has no pane here.
    ///
    /// zmx is multi-client — this is the same thing `trm mirror` relies on —
    /// so a reply can be delivered to the daemon directly without a surface
    /// to route it through. The trailing carriage return is what submits it,
    /// matching what typing into a pane does.
    @discardableResult
    static func deliver(text: String, toSession name: String) -> Bool {
        guard !text.isEmpty, ZmxSessionManager.sessionExists(name) else { return false }
        return ZmxSessionManager.sendText(text + "\r", toSession: name)
    }
}
