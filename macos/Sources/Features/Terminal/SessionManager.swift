import Cocoa
import Foundation
import os

/// Manages auto-save and named session persistence for TRM windows.
///
/// Sessions are stored as TOML files in `~/Library/Application Support/trm/sessions/`.
/// Auto-save files use the `_autosave_` prefix; named sessions are plain `<name>.toml`.
@MainActor
enum SessionManager {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.trm",
        category: "SessionManager"
    )

    // MARK: - Data Types

    struct AutoSaveEntry: Codable {
        let filename: String
        let timestamp: String
        let frame: FrameRect
    }

    struct FrameRect: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: NSRect) {
            self.x = rect.origin.x
            self.y = rect.origin.y
            self.width = rect.size.width
            self.height = rect.size.height
        }

        var nsRect: NSRect {
            NSRect(x: x, y: y, width: width, height: height)
        }
    }

    struct AutoSaveManifest: Codable {
        let entries: [AutoSaveEntry]
        let savedAt: String
    }

    struct NamedSession {
        let name: String
        let path: String
        let modificationDate: Date
    }

    // MARK: - Directory

    static var sessionsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport
            .appendingPathComponent("trm", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)

        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        }
        return dir
    }

    // MARK: - Auto-Save

    static func autoSaveAllWindows() {
        clearAutoSaves()

        let controllers = TerminalController.all
        guard !controllers.isEmpty else { return }

        let dir = sessionsDirectory
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let now = dateFormatter.string(from: Date())

        var entries: [AutoSaveEntry] = []

        for (index, controller) in controllers.enumerated() {
            let toml = controller.buildCurrentConfigToml()
            let filename = "_autosave_\(index).toml"
            let fileURL = dir.appendingPathComponent(filename)

            let frame: NSRect = controller.window?.frame ?? .zero

            do {
                try toml.write(to: fileURL, atomically: true, encoding: .utf8)
                entries.append(AutoSaveEntry(
                    filename: filename,
                    timestamp: now,
                    frame: FrameRect(frame)
                ))
            } catch {
                logger.error("Failed to auto-save window \(index): \(error.localizedDescription)")
            }
        }

        let manifest = AutoSaveManifest(entries: entries, savedAt: now)
        let manifestURL = dir.appendingPathComponent("_autosave_manifest.json")

        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            logger.error("Failed to write auto-save manifest: \(error.localizedDescription)")
        }
    }

    static func autoSaveSingleWindow(_ controller: BaseTerminalController) {
        let dir = sessionsDirectory
        let toml = controller.buildCurrentConfigToml()
        let fileURL = dir.appendingPathComponent("_autosave_last.toml")

        do {
            try toml.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to auto-save single window: \(error.localizedDescription)")
        }
    }

    static func clearAutoSaves() {
        let dir = sessionsDirectory
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return }

        for file in files where file.hasPrefix("_autosave_") {
            try? fm.removeItem(at: dir.appendingPathComponent(file))
        }
    }

    // MARK: - Auto-Restore

    /// Maximum number of panes per window that auto-restore will attempt.
    /// Sessions with more panes are skipped to avoid overwhelming the system
    /// at startup (each terminal pane spawns a PTY + Ghostty surface).
    private static let maxAutoRestorePanes = 20

    /// Check whether a config is safe to auto-restore.
    private static func isSafeForAutoRestore(_ config: Trm.TrmGridConfig) -> Bool {
        let paneCount = config.panes.isEmpty
            ? max(1, config.rows * config.cols)
            : config.panes.count
        if paneCount > maxAutoRestorePanes {
            logger.warning(
                "Skipping auto-restore: session has \(paneCount) panes (limit \(maxAutoRestorePanes))"
            )
            return false
        }
        return true
    }

    @discardableResult
    static func restoreLastSession(ghostty: Ghostty.App) -> Bool {
        let dir = sessionsDirectory
        let manifestURL = dir.appendingPathComponent("_autosave_manifest.json")

        // Try manifest-based restore (multi-window)
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(AutoSaveManifest.self, from: data) {

            var restored = false
            for entry in manifest.entries {
                let fileURL = dir.appendingPathComponent(entry.filename)
                guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
                guard let config = Trm.gridConfig(fromConfigPath: fileURL.path) else { continue }
                guard isSafeForAutoRestore(config) else { continue }

                let controller = TerminalController.newWindow(
                    ghostty,
                    withGridConfig: config,
                    withConfigPath: fileURL.path
                )

                // Restore window frame
                let frame = entry.frame.nsRect
                if frame.width > 0 && frame.height > 0 {
                    controller.window?.setFrame(frame, display: true)
                }

                restored = true
            }

            if restored {
                logger.info("Restored \(manifest.entries.count) window(s) from auto-save manifest")
                return true
            }
        }

        // Fallback: single-window auto-save
        let lastURL = dir.appendingPathComponent("_autosave_last.toml")
        guard FileManager.default.fileExists(atPath: lastURL.path) else { return false }
        guard let config = Trm.gridConfig(fromConfigPath: lastURL.path) else { return false }
        guard isSafeForAutoRestore(config) else { return false }

        _ = TerminalController.newWindow(
            ghostty,
            withGridConfig: config,
            withConfigPath: lastURL.path
        )
        logger.info("Restored window from _autosave_last.toml")
        return true
    }

    // MARK: - Named Sessions

    static func saveNamedSession(name: String, controller: BaseTerminalController) {
        let sanitized = sanitizeFilename(name)
        guard !sanitized.isEmpty else { return }

        let dir = sessionsDirectory
        let fileURL = dir.appendingPathComponent("\(sanitized).toml")
        let toml = controller.buildCurrentConfigToml()

        do {
            try toml.write(to: fileURL, atomically: true, encoding: .utf8)
            logger.info("Saved named session: \(sanitized).toml")
        } catch {
            logger.error("Failed to save named session '\(sanitized)': \(error.localizedDescription)")
        }
    }

    static func listNamedSessions() -> [NamedSession] {
        let dir = sessionsDirectory
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }

        return files
            .filter { $0.hasSuffix(".toml") && !$0.hasPrefix("_autosave_") }
            .compactMap { filename -> NamedSession? in
                let path = dir.appendingPathComponent(filename).path
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let modDate = attrs[.modificationDate] as? Date else { return nil }
                let name = String(filename.dropLast(5)) // remove .toml
                return NamedSession(name: name, path: path, modificationDate: modDate)
            }
            .sorted { $0.modificationDate > $1.modificationDate }
    }

    @discardableResult
    static func restoreNamedSession(path: String, ghostty: Ghostty.App) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let config = Trm.gridConfig(fromConfigPath: path) else { return false }

        _ = TerminalController.newWindow(
            ghostty,
            withGridConfig: config,
            withConfigPath: path
        )
        return true
    }

    // MARK: - Helpers

    private static func sanitizeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        return name
            .unicodeScalars
            .filter { allowed.contains($0) }
            .map { String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
