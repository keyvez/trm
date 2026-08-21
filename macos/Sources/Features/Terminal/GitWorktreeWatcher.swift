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

    /// Every worktree path already accounted for.
    ///
    /// Seeded from the first scan of each repository rather than starting
    /// empty, so opening trm in a repo that already has six worktrees doesn't
    /// announce six "new" ones. Only what appears *after* trm is looking
    /// counts as new.
    private var known: Set<String> = []
    /// Repositories whose baseline has been taken.
    private var baselined: Set<String> = []
    private var timer: Timer?
    private var isScanning = false

    private init() {}

    func start() {
        guard timer == nil else { return }
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

            for (root, paths) in found {
                guard baselined.contains(root) else {
                    // First sight of this repository: everything it already
                    // has is the starting state, not news.
                    baselined.insert(root)
                    known.formUnion(paths)
                    continue
                }
                for path in paths where !known.contains(path) {
                    known.insert(path)
                    Self.logger.info("New worktree appeared: \(path, privacy: .public)")
                    onWorktreeAppeared?(path)
                }
            }
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
