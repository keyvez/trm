import Foundation

/// Manages real-time tracking of Claude Code context window usage.
/// Polls the Trm C API for context usage data sent via Text Tap hooks,
/// tracks per-session history, and persists daily/weekly aggregates.
@MainActor
final class ContextUsageManager: ObservableObject {
    /// The reading this window should display, or nil when the reading
    /// belongs to another window's pane (or has gone stale).
    @Published var currentUsage: Trm.ContextUsageData?
    @Published var dailyTokensUsed: UInt64 = 0
    @Published var weeklyTokensUsed: UInt64 = 0

    /// Last reading seen from the C API, regardless of whether this window
    /// displays it. Drives change detection so a filtered-out reading is
    /// still recorded in the aggregates exactly once.
    private var lastPolled: Trm.ContextUsageData?

    /// Per-session peak usage for aggregate tracking.
    private var sessionPeaks: [String: UInt64] = [:]

    /// Timestamped snapshots for persistence.
    private var snapshots: [UsageSnapshot] = []
    private var snapshotsSinceLastSave: Int = 0

    /// Per-session peaks inside the rolling daily/weekly windows. Maintained
    /// incrementally on each poll; rebuilt from `snapshots` by the periodic
    /// full recompute so expired sessions eventually fall out of the sums.
    private var dailyPeaks: [String: UInt64] = [:]
    private var weeklyPeaks: [String: UInt64] = [:]
    private var lastFullRecompute: Date = .distantPast
    private var lastSaveDate: Date = .distantPast

    /// How often to do a full O(n) recompute over all snapshots (seconds).
    /// Between recomputes, aggregates are bumped incrementally in O(1).
    private static let fullRecomputeInterval: TimeInterval = 300

    /// Minimum time between history saves (seconds).
    private static let saveInterval: TimeInterval = 60

    /// Hard cap on in-memory snapshots; oldest are dropped beyond this.
    private static let maxSnapshots = 50_000

    private var timer: Timer?

    /// How often to poll for updates (seconds).
    var pollInterval: TimeInterval = 1.0

    /// Returns the stable pane IDs owned by this manager's window. The
    /// context reading is process-wide (one agent hook writes it for the
    /// whole app), so without this every window would show every agent's
    /// pill. Left nil, the manager keeps the old global behavior.
    var ownedPaneIds: (() -> Set<Int>)?

    /// How long a reading stays displayable after its last update. An agent
    /// that goes idle or ends its session stops sending hooks; without this
    /// the pill would linger forever showing a stale number.
    static let stalenessInterval: TimeInterval = 30 * 60

    /// True when a reading belongs to this window and is recent enough to
    /// show. Unattributed readings (no pane in the hook payload) fall back
    /// to showing everywhere, preserving behavior for older hook scripts.
    func shouldDisplay(_ usage: Trm.ContextUsageData, now: Date = Date()) -> Bool {
        if now.timeIntervalSince(usage.lastUpdate) > Self.stalenessInterval {
            return false
        }
        guard let paneId = usage.paneId, let owned = ownedPaneIds else { return true }
        return owned().contains(paneId)
    }

    private static let historyFileName = "context_usage_history.json"
    private static let retentionDays = 7

    func start() {
        loadHistory()
        computeAggregates()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollOnce()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        flush()
    }

    private func pollOnce() {
        guard let usage = Trm.shared.pollContextUsage() else { return }

        // Fast path: if nothing changed since the last poll, skip all work.
        // Poll runs at 1Hz and `computeAggregates` iterates all snapshots,
        // which gets expensive over long sessions and can cause typing lag.
        let changed = lastPolled?.usedTokens != usage.usedTokens
            || lastPolled?.sessionId != usage.sessionId
            || lastPolled?.lastUpdate != usage.lastUpdate
        // Even when the reading itself is unchanged, the pill may need to
        // expire (staleness) — re-evaluate visibility before bailing out.
        let displayable = shouldDisplay(usage)
        if !changed {
            if (currentUsage != nil) != displayable {
                currentUsage = displayable ? usage : nil
            }
            return
        }
        lastPolled = usage

        // The pill is per-window: only the window owning the agent's pane
        // shows it. Aggregates below still track every reading, since
        // daily/weekly totals are process-wide by design.
        currentUsage = displayable ? usage : nil

        // Track per-session peak
        if !usage.sessionId.isEmpty {
            let current = sessionPeaks[usage.sessionId] ?? 0
            if usage.usedTokens > current {
                sessionPeaks[usage.sessionId] = usage.usedTokens
            }
        }

        // Record snapshot
        let snapshot = UsageSnapshot(
            timestamp: usage.lastUpdate,
            sessionId: usage.sessionId,
            usedTokens: usage.usedTokens,
            totalTokens: usage.totalTokens,
            percentage: usage.percentage
        )
        snapshots.append(snapshot)
        snapshotsSinceLastSave += 1

        // Full recompute is O(all snapshots); doing it on every changed poll
        // (up to 1Hz) grows quadratic over long sessions and caused typing
        // lag. Bump incrementally and recompute fully only every few minutes
        // so sessions that age out of the daily/weekly windows are dropped.
        if Date().timeIntervalSince(lastFullRecompute) >= Self.fullRecomputeInterval {
            computeAggregates()
        } else {
            bumpAggregates(sessionId: usage.sessionId, usedTokens: usage.usedTokens)
        }

        // Auto-save, throttled by time so a busy session doesn't re-encode
        // the whole history every few seconds.
        if snapshotsSinceLastSave >= 10,
           Date().timeIntervalSince(lastSaveDate) >= Self.saveInterval {
            saveHistory()
            snapshotsSinceLastSave = 0
        }
    }

    /// Flush all data to disk.
    func flush() {
        saveHistory(synchronous: true)
        snapshotsSinceLastSave = 0
    }

    // MARK: - Aggregation

    /// O(1) incremental update for the common case: a new reading for a
    /// session already inside both windows can only raise its peak.
    private func bumpAggregates(sessionId: String, usedTokens: UInt64) {
        var changed = false
        if usedTokens > (dailyPeaks[sessionId] ?? 0) {
            dailyPeaks[sessionId] = usedTokens
            changed = true
        }
        if usedTokens > (weeklyPeaks[sessionId] ?? 0) {
            weeklyPeaks[sessionId] = usedTokens
            changed = true
        }
        if changed {
            dailyTokensUsed = dailyPeaks.values.reduce(0, +)
            weeklyTokensUsed = weeklyPeaks.values.reduce(0, +)
        }
    }

    private func computeAggregates() {
        let now = Date()
        let calendar = Calendar.current
        lastFullRecompute = now

        let dayAgo = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        // Group snapshots by session, find peak per session within each window
        var dailyPeaks: [String: UInt64] = [:]
        var weeklyPeaks: [String: UInt64] = [:]

        for snapshot in snapshots {
            if snapshot.timestamp >= weekAgo {
                let current = weeklyPeaks[snapshot.sessionId] ?? 0
                if snapshot.usedTokens > current {
                    weeklyPeaks[snapshot.sessionId] = snapshot.usedTokens
                }
            }
            if snapshot.timestamp >= dayAgo {
                let current = dailyPeaks[snapshot.sessionId] ?? 0
                if snapshot.usedTokens > current {
                    dailyPeaks[snapshot.sessionId] = snapshot.usedTokens
                }
            }
        }

        // Also include in-memory session peaks for the current session
        for (sid, peak) in sessionPeaks {
            let existingDaily = dailyPeaks[sid] ?? 0
            if peak > existingDaily { dailyPeaks[sid] = peak }
            let existingWeekly = weeklyPeaks[sid] ?? 0
            if peak > existingWeekly { weeklyPeaks[sid] = peak }
        }

        self.dailyPeaks = dailyPeaks
        self.weeklyPeaks = weeklyPeaks
        dailyTokensUsed = dailyPeaks.values.reduce(0, +)
        weeklyTokensUsed = weeklyPeaks.values.reduce(0, +)
    }

    // MARK: - Persistence

    private var historyFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let trmDir = appSupport.appendingPathComponent("trm", isDirectory: true)
        try? FileManager.default.createDirectory(at: trmDir, withIntermediateDirectories: true)
        return trmDir.appendingPathComponent(Self.historyFileName)
    }

    private func loadHistory() {
        let url = historyFileURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([UsageSnapshot].self, from: data) else {
            return
        }

        // Prune old entries
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date()) ?? Date()
        snapshots = decoded.filter { $0.timestamp >= cutoff }
    }

    /// Save history to disk. Encoding happens off the main thread unless
    /// `synchronous` is set (used on quit, where a detached task could be
    /// dropped before it runs).
    private func saveHistory(synchronous: Bool = false) {
        // Prune before saving
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date()) ?? Date()
        snapshots = snapshots.filter { $0.timestamp >= cutoff }
        if snapshots.count > Self.maxSnapshots {
            snapshots = Array(snapshots.suffix(Self.maxSnapshots))
        }
        lastSaveDate = Date()

        let toWrite = snapshots
        let url = historyFileURL
        let work: @Sendable () -> Void = {
            if let data = try? JSONEncoder().encode(toWrite) {
                try? data.write(to: url, options: .atomic)
            }
        }
        if synchronous {
            work()
        } else {
            Task.detached(priority: .utility) { work() }
        }
    }
}

// MARK: - Data Types

struct UsageSnapshot: Codable {
    let timestamp: Date
    let sessionId: String
    let usedTokens: UInt64
    let totalTokens: UInt64
    let percentage: UInt8
}
