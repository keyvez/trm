import Foundation

/// Manages real-time tracking of Claude Code context window usage.
/// Polls the Trm C API for context usage data sent via Text Tap hooks,
/// tracks per-session history, and persists daily/weekly aggregates.
@MainActor
final class ContextUsageManager: ObservableObject {
    @Published var currentUsage: Trm.ContextUsageData?
    @Published var dailyTokensUsed: UInt64 = 0
    @Published var weeklyTokensUsed: UInt64 = 0

    /// Per-session peak usage for aggregate tracking.
    private var sessionPeaks: [String: UInt64] = [:]

    /// Timestamped snapshots for persistence.
    private var snapshots: [UsageSnapshot] = []
    private var snapshotsSinceLastSave: Int = 0

    private var timer: Timer?

    /// How often to poll for updates (seconds).
    var pollInterval: TimeInterval = 1.0

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

        currentUsage = usage

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

        computeAggregates()

        // Auto-save every 10 snapshots
        if snapshotsSinceLastSave >= 10 {
            saveHistory()
            snapshotsSinceLastSave = 0
        }
    }

    /// Flush all data to disk.
    func flush() {
        saveHistory()
        snapshotsSinceLastSave = 0
    }

    // MARK: - Aggregation

    private func computeAggregates() {
        let now = Date()
        let calendar = Calendar.current

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

    private func saveHistory() {
        // Prune before saving
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date()) ?? Date()
        snapshots = snapshots.filter { $0.timestamp >= cutoff }

        let url = historyFileURL
        if let data = try? JSONEncoder().encode(snapshots) {
            try? data.write(to: url, options: .atomic)
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
