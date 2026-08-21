import Foundation
import os

/// Notices git worktrees appearing under the repositories trm has panes in.
///
/// A worktree is a branch you can be in two places at once, which is exactly
/// the shape of work trm is for — one pane on `main`, another on the branch an
/// agent is building. The moment that second checkout exists it wants a pane,
/// and asking someone to go and make one by hand is asking them to do the
/// bookkeeping the tool exists to do.
///
/// Crucially it watches for worktrees *anyone* made, not only trm's own — an
/// agent running `git worktree add` is the common case, and it has no way to
/// tell trm what it did.
///
/// The scan is deliberately cheap and bounded: one `git worktree list` per
/// distinct repository root, only for repositories a pane is currently sitting
/// in, and only while at least one window is open. A machine with no panes
/// costs nothing.
@MainActor
final class GitWorktreeWatcher {

    static let shared = GitWorktreeWatcher()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.trm",
        category: "GitWorktreeWatcher"
    )

    /// How often to look. Slow on purpose: creating a worktree is a human-scale
    /// event, and two shell-outs per repository is not something to do at
    /// animation rate.
    private static let interval: TimeInterval = 6

    /// Called with the path of each newly-appeared worktree.
    var onWorktreeAppeared: ((String) -> Void)?

    /// Every worktree path already offered a pane.
    ///
    /// Not a record of what existed at startup — a worktree that was already
    /// there when trm opened still wants a pane, which is the whole point of
    /// having them on the shelf. This only stops the same one being offered
    /// twice, so a pane you deliberately closed stays closed.
    private var known: Set<String> = []
    private var timer: Timer?
    private var isScanning = false
    /// When watching began, for the settling window below.
    private var startedAt: Date?

    /// How long to let panes report where they are before deciding a worktree
    /// has none.
    ///
    /// A restored window's surfaces take a moment to have a working directory,
    /// and acting inside that gap would open a second pane for a worktree that
    /// already has one on screen. Nothing is lost by waiting: the scan that
    /// runs after it sees the same worktrees.
    private static let settling: TimeInterval = 10

    private init() {}

    func start() {
        guard timer == nil else { return }
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        scan()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Treat a path as already known, so a worktree trm creates itself doesn't
    /// come back through the watcher and open a second pane for it.
    func markKnown(_ path: String) {
        known.insert(Self.normalize(path))
    }

    private func scan() {
        guard !isScanning else { return }
        // Repository roots are derived from where panes actually are. A pane
        // is the only evidence trm has that a repository matters to anyone.
        let directories = Self.paneDirectories()
        guard !directories.isEmpty else { return }
        isScanning = true

        Task {
            defer { isScanning = false }
            let found = await Task.detached(priority: .utility) {
                Self.worktrees(under: directories)
            }.value

            // Let panes settle before concluding a worktree hasn't got one.
            if let startedAt, Date().timeIntervalSince(startedAt) < Self.settling { return }

            let occupied = Self.paneDirectories().map(Self.normalize)
            for (_, paths) in found {
                for path in paths where !known.contains(path) {
                    known.insert(path)
                    // The repository you are already sitting in is itself a
                    // worktree in git's listing, and so is any other one that
                    // already has a pane. Offering those a second pane would
                    // duplicate what is on screen — which is why this asks
                    // "is anything already here", not "is this new".
                    guard !Self.isOccupied(path, by: occupied) else { continue }
                    Self.logger.info("Worktree without a pane: \(path, privacy: .public)")
                    onWorktreeAppeared?(path)
                }
            }
        }
    }

    /// Whether any pane already sits in this worktree.
    ///
    /// Containment rather than equality: a pane deep in `repo/src/termania` is
    /// still a pane in `repo`, and testing for an exact match would decide the
    /// repository was unattended and open a redundant pane for it. The
    /// separator check keeps `repo-feat` from counting as inside `repo`.
    nonisolated static func isOccupied(_ worktree: String, by directories: [String]) -> Bool {
        directories.contains { dir in
            dir == worktree || dir.hasPrefix(worktree.hasSuffix("/") ? worktree : worktree + "/")
        }
    }

    /// Working directories of every terminal pane in every window.
    private static func paneDirectories() -> [String] {
        var seen: Set<String> = []
        for controller in TerminalController.all {
            for surface in controller.surfaceTree {
                // A remote pane's cwd is on another machine; a local
                // `git worktree list` there would describe the wrong repo.
                guard surface.remoteHost == nil else { continue }
                guard let cwd = AgentOverviewPane.workingDirectory(for: surface) else { continue }
                seen.insert(cwd)
            }
        }
        return Array(seen)
    }

    /// Map each distinct repository root to the worktrees it currently has.
    ///
    /// Runs off the main actor: two process spawns per directory, and a
    /// directory on a slow or unmounted volume can make git block.
    private nonisolated static func worktrees(under directories: [String]) -> [String: Set<String>] {
        var byRoot: [String: Set<String>] = [:]
        for dir in directories {
            guard let root = run(["-C", dir, "rev-parse", "--show-toplevel"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty else { continue }
            let key = normalize(root)
            // Several panes usually sit in one repository; ask it once.
            guard byRoot[key] == nil else { continue }
            guard let listing = run(["-C", root, "worktree", "list", "--porcelain"]) else { continue }
            var paths: Set<String> = []
            for line in listing.components(separatedBy: .newlines) where line.hasPrefix("worktree ") {
                let path = String(line.dropFirst("worktree ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { paths.insert(normalize(path)) }
            }
            byRoot[key] = paths
        }
        return byRoot
    }

    /// Resolve symlinks and drop a trailing slash, so `/tmp/x` and
    /// `/private/tmp/x/` are one worktree rather than two.
    nonisolated static func normalize(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
    }

    /// Run git and capture stdout, or nil if it failed.
    nonisolated static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
