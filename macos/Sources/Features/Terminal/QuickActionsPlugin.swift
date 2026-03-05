import Foundation
import SwiftUI
import Combine
import Darwin

/// The type of a quick action: a direct shell command or an LLM-driven script.
enum QuickActionType: String, Equatable {
    case command
    case script
}

/// A persistent quick-action command that can be executed from a pill overlay.
struct QuickAction: Identifiable, Equatable {
    let id = UUID()
    var paneWatermark: String   // Empty string means pane 0
    var name: String
    var actionType: QuickActionType = .command
    var command: String = ""    // Used when .command
    var script: String = ""     // Used when .script
    var icon: String?           // Optional SF Symbol name
    var isScript: Bool { actionType == .script }
}

/// Info about a pane for the `#` autocomplete picker.
struct PanePickerItem: Identifiable {
    let id: Int
    let watermark: String?
    let title: String
    let processName: String?
    let detectedURLs: [URL]

    var displayLabel: String {
        var parts: [String] = ["#\(id)"]
        if let wm = watermark, !wm.isEmpty {
            parts.append("— \(wm)")
        } else if !title.isEmpty {
            parts.append("— \(title)")
        }
        if let proc = processName, !proc.isEmpty {
            parts.append("(\(proc))")
        }
        let portStrings = detectedURLs.compactMap { url -> String? in
            guard let port = url.port else { return nil }
            return ":\(port)"
        }
        if !portStrings.isEmpty {
            parts.append(portStrings.joined(separator: " "))
        }
        return parts.joined(separator: " ")
    }
}

/// Service plugin that loads quick actions from `.trm-actions.toml`, renders
/// pill overlays on matching panes, and watches the file for hot-reload.
@MainActor
final class QuickActionsPlugin: ObservableObject, ServicePlugin, ObservableServicePlugin, ServicePluginOverlayProvider {

    // MARK: - ServicePlugin

    let pluginId = "quick_actions"
    let displayName = "Quick Actions"

    static let requiredCapabilities: Set<PluginCapability> = [.fileSystemRead]

    private weak var registry: ServicePluginRegistry?

    func configure(registry: ServicePluginRegistry) {
        self.registry = registry
    }

    // MARK: - Published State

    @Published var actions: [QuickAction] = []

    /// The ID of the action currently being executed (shows a spinner on the pill).
    @Published var executingActionId: UUID?

    // MARK: - File Path

    /// Absolute path to the `.trm-actions.toml` file.
    var actionsFilePath: String? {
        didSet {
            if actionsFilePath != oldValue {
                loadActions()
                startFileWatcher()
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        loadActions()
        startFileWatcher()
    }

    func stop() {
        stopFileWatcher()
        actions.removeAll()
    }

    // MARK: - ServicePluginOverlayProvider

    var overlayAlignment: Alignment { .bottomTrailing }

    func overlayView(forPaneId paneId: Int) -> AnyView? {
        let paneActions = actionsForPane(paneId)
        guard !paneActions.isEmpty else { return nil }
        return AnyView(
            QuickActionsOverlayView(
                actions: paneActions,
                executingActionId: executingActionId,
                onExecute: { [weak self] action in
                    self?.executeAction(action, paneId: paneId)
                },
                onDelete: { [weak self] action in
                    self?.deleteAction(action)
                }
            )
            .padding(.bottom, 8)
            .padding(.trailing, 8)
        )
    }

    // MARK: - Pane Matching

    /// Returns actions that match the given pane.
    /// Empty watermark matches all panes; otherwise matches the pane's watermark (case-insensitive).
    func actionsForPane(_ paneId: Int) -> [QuickAction] {
        actions.filter { action in
            if action.paneWatermark.isEmpty {
                return true
            }
            guard let watermark = Trm.shared.watermark(forPaneId: UInt32(paneId)) else {
                return false
            }
            return action.paneWatermark.localizedCaseInsensitiveCompare(watermark) == .orderedSame
        }
    }

    // MARK: - Mutating Actions

    /// Add a new command quick action and save to disk.
    func addAction(paneWatermark: String, name: String, command: String, icon: String? = nil) {
        let action = QuickAction(paneWatermark: paneWatermark, name: name, command: command, icon: icon)
        actions.append(action)
        saveActions()
    }

    /// Add a new script quick action and save to disk.
    func addScriptAction(paneWatermark: String, name: String, script: String, icon: String? = nil) {
        var action = QuickAction(paneWatermark: paneWatermark, name: name, icon: icon)
        action.actionType = .script
        action.script = script
        actions.append(action)
        saveActions()
    }

    /// Remove a quick action and save to disk.
    func deleteAction(_ action: QuickAction) {
        actions.removeAll { $0.id == action.id }
        saveActions()
    }

    // MARK: - Execute

    private func executeAction(_ action: QuickAction, paneId: Int) {
        switch action.actionType {
        case .command:
            NotificationCenter.default.post(
                name: .trmQuickActionExecute,
                object: nil,
                userInfo: [
                    "command": action.command,
                    "paneId": paneId,
                ]
            )
        case .script:
            executingActionId = action.id
            NotificationCenter.default.post(
                name: .trmQuickActionScriptExecute,
                object: nil,
                userInfo: [
                    "script": action.script,
                    "paneId": paneId,
                    "actionName": action.name,
                    "actionId": action.id,
                ]
            )
        }
    }

    // MARK: - Pane Picker

    /// Build a list of pane picker items for the `#` autocomplete.
    static func buildPanePickerItems(
        surfaces: [Ghostty.SurfaceView],
        serverURLPlugin: ServerURLDetectorPlugin?
    ) -> [PanePickerItem] {
        surfaces.enumerated().map { index, surface in
            let paneId = surface.paneId ?? index
            let watermark = Trm.shared.watermark(forPaneId: UInt32(paneId))
            let title = surface.title.isEmpty ? "Shell" : surface.title
            let detectedURLs = serverURLPlugin?.urls[paneId] ?? []

            var processName: String?
            let childPid = Trm.shared.paneChildPid(paneId: UInt32(paneId))
            if childPid > 0 {
                processName = Self.processName(forPid: childPid)
            }

            return PanePickerItem(
                id: paneId,
                watermark: watermark,
                title: title,
                processName: processName,
                detectedURLs: detectedURLs
            )
        }
    }

    /// Get the process name for a given PID via libproc.
    private static func processName(forPid pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 1024)
        let len = proc_name(pid, &buf, UInt32(buf.count))
        guard len > 0 else { return nil }
        return String(cString: buf)
    }

    // MARK: - TOML Parsing

    /// Load actions from the `.trm-actions.toml` file.
    func loadActions() {
        guard let path = actionsFilePath else { return }
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            actions = []
            return
        }
        actions = parseActionsToml(content)
    }

    /// Simple TOML parser: splits on `[[action]]` markers, parses `key = "value"` pairs.
    private func parseActionsToml(_ content: String) -> [QuickAction] {
        var result: [QuickAction] = []
        let blocks = content.components(separatedBy: "[[action]]")

        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            var paneWatermark = ""
            var name: String?
            var command: String?
            var script: String?
            var icon: String?
            var typeStr: String?

            for line in trimmed.components(separatedBy: .newlines) {
                let stripped = line.trimmingCharacters(in: .whitespaces)
                // Skip comments and empty lines
                guard !stripped.isEmpty, !stripped.hasPrefix("#") else { continue }

                guard let eqIdx = stripped.firstIndex(of: "=") else { continue }
                let key = stripped[stripped.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
                var value = stripped[stripped.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)

                // Strip surrounding quotes
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }

                switch key {
                case "pane": paneWatermark = value
                case "name": name = value
                case "command": command = value
                case "script": script = value
                case "type": typeStr = value
                case "icon": icon = value.isEmpty ? nil : value
                default: break
                }
            }

            guard let name, !name.isEmpty else { continue }

            let actionType = QuickActionType(rawValue: typeStr ?? "command") ?? .command

            switch actionType {
            case .command:
                guard let command, !command.isEmpty else { continue }
                result.append(QuickAction(
                    paneWatermark: paneWatermark,
                    name: name,
                    actionType: .command,
                    command: command,
                    icon: icon
                ))
            case .script:
                guard let script, !script.isEmpty else { continue }
                result.append(QuickAction(
                    paneWatermark: paneWatermark,
                    name: name,
                    actionType: .script,
                    script: script,
                    icon: icon
                ))
            }
        }

        return result
    }

    // MARK: - TOML Serialization

    /// Save current actions to the `.trm-actions.toml` file.
    private func saveActions() {
        guard let path = actionsFilePath else { return }
        let content = serializeActionsToml(actions)
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Serialize actions to TOML format.
    private func serializeActionsToml(_ actions: [QuickAction]) -> String {
        actions.map { action in
            var lines = ["[[action]]"]
            lines.append("pane = \"\(action.paneWatermark)\"")
            lines.append("name = \"\(action.name)\"")
            switch action.actionType {
            case .command:
                lines.append("command = \"\(action.command)\"")
            case .script:
                lines.append("type = \"script\"")
                lines.append("script = \"\(action.script)\"")
            }
            if let icon = action.icon {
                lines.append("icon = \"\(icon)\"")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: - File Watcher

    private var fileWatcher: DispatchSourceFileSystemObject?
    private var reloadDebounce: DispatchWorkItem?

    private func startFileWatcher() {
        guard let path = actionsFilePath else { return }
        openFileWatcher(path: path)
    }

    private func openFileWatcher(path: String) {
        stopFileWatcher()

        let fd = open(path, O_EVTONLY)
        // If file doesn't exist yet, that's fine — we'll create it when adding actions.
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Atomic save: file was replaced. Re-open after a short delay.
                self.stopFileWatcher()
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                    guard let self else { return }
                    self.openFileWatcher(path: path)
                    self.debounceReload()
                }
            } else {
                self.debounceReload()
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        fileWatcher = source
    }

    private func stopFileWatcher() {
        reloadDebounce?.cancel()
        reloadDebounce = nil
        if let watcher = fileWatcher {
            watcher.cancel()
            fileWatcher = nil
        }
    }

    /// Debounce reload to coalesce rapid saves (300ms).
    private func debounceReload() {
        reloadDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.loadActions()
        }
        reloadDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: item)
    }
}
