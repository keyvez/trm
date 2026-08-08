import SwiftUI
import AppKit
import Foundation
import GhosttyKit

enum PluginPaneKind: String {
    case notes
    case fileBrowser = "file_browser"
    case processMonitor = "process_monitor"
    case logViewer = "log_viewer"
    case markdownPreview = "markdown_preview"
    case systemInfo = "system_info"
    case gitStatus = "git_status"

    static func fromPaneType(_ value: String) -> PluginPaneKind? {
        PluginPaneKind(rawValue: value.lowercased())
    }

    var title: String {
        switch self {
        case .notes: return "Notes"
        case .fileBrowser: return "File Browser"
        case .processMonitor: return "Process Monitor"
        case .logViewer: return "Log Viewer"
        case .markdownPreview: return "Markdown Preview"
        case .systemInfo: return "System Info"
        case .gitStatus: return "Git Status"
        }
    }
}

/// Runtime model for non-terminal utility panes.
final class PluginPane: ObservableObject, Identifiable {
    private struct Snapshot {
        let text: String
    }

    let id = UUID()
    let kind: PluginPaneKind
    let configuredTitle: String?
    let cwd: String?
    let file: String?
    let content: String?
    let target: String?
    let targetTitle: String?
    let path: String?
    let repo: String?
    let refreshMs: UInt64?

    @Published var notesText: String
    @Published var bodyText: String = ""
    @Published var lastUpdated: Date? = nil

    private var timer: Timer? = nil

    var title: String {
        if let configuredTitle, !configuredTitle.isEmpty {
            return configuredTitle
        }
        return kind.title
    }

    init(kind: PluginPaneKind, config: Trm.TrmPaneConfig) {
        self.kind = kind
        self.configuredTitle = config.title
        self.cwd = config.cwd
        self.file = config.file
        self.content = config.content
        self.target = config.target
        self.targetTitle = config.targetTitle
        self.path = config.path
        self.repo = config.repo
        self.refreshMs = config.refreshMs
        self.notesText = config.content ?? ""

        refresh()
        setupTimer()
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        switch kind {
        case .notes:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.bodyText = self.notesText.isEmpty ? "Start typing notes..." : self.notesText
                self.lastUpdated = Date()
            }
        default:
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let snapshot = self.buildSnapshot()
                DispatchQueue.main.async {
                    self.bodyText = snapshot.text
                    self.lastUpdated = Date()
                }
            }
        }
    }

    private func setupTimer() {
        let ms = refreshMs ?? defaultRefreshMs
        guard let ms, ms > 0 else { return }
        let interval = max(Double(ms) / 1000.0, 0.5)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private var defaultRefreshMs: UInt64? {
        switch kind {
        case .processMonitor: return 3000
        case .logViewer: return 2000
        case .systemInfo: return 5000
        case .gitStatus: return 3000
        case .notes, .fileBrowser, .markdownPreview: return nil
        }
    }

    private func buildSnapshot() -> Snapshot {
        switch kind {
        case .fileBrowser:
            return Snapshot(text: fileBrowserText())
        case .processMonitor:
            return Snapshot(text: runShellCommand("ps -axo pid,ppid,%cpu,%mem,comm | head -n 25", cwd: resolvedDirectory()))
        case .logViewer:
            return Snapshot(text: logViewerText())
        case .markdownPreview:
            return Snapshot(text: markdownSourceText())
        case .systemInfo:
            return Snapshot(text: systemInfoText())
        case .gitStatus:
            return Snapshot(text: gitStatusText())
        case .notes:
            return Snapshot(text: notesText)
        }
    }

    private func fileBrowserText() -> String {
        let directory = resolvedDirectory()
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory) else {
            return "Directory not found: \(directory)"
        }

        do {
            let entries = try fm.contentsOfDirectory(atPath: directory).sorted()
            if entries.isEmpty { return "(empty directory)\n\(directory)" }

            let preview = entries.prefix(300).map { name -> String in
                let full = (directory as NSString).appendingPathComponent(name)
                var isDir = ObjCBool(false)
                _ = fm.fileExists(atPath: full, isDirectory: &isDir)
                return isDir.boolValue ? name + "/" : name
            }
            return "\(directory)\n\n" + preview.joined(separator: "\n")
        } catch {
            return "Failed to list \(directory): \(error.localizedDescription)"
        }
    }

    private func logViewerText() -> String {
        let resolved = expandPath(path ?? file)
        guard let resolved else { return "Set `path` (or `file`) for log_viewer pane." }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: resolved))
            let text = String(data: data, encoding: .utf8) ?? ""
            let lines = text.components(separatedBy: .newlines)
            return lines.suffix(300).joined(separator: "\n")
        } catch {
            return "Failed to read log file: \(resolved)\n\(error.localizedDescription)"
        }
    }

    private func markdownSourceText() -> String {
        if let filePath = expandPath(file), !filePath.isEmpty,
           let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
           let markdown = String(data: data, encoding: .utf8) {
            return markdown
        }

        if let content, !content.isEmpty {
            return content
        }

        return """
        # Markdown Preview

        Set `content` or `file` in the pane config.
        """
    }

    private func systemInfoText() -> String {
        let info = ProcessInfo.processInfo
        let host = Host.current().localizedName ?? "Unknown"
        let os = "\(info.operatingSystemVersionString)"
        let cpu = info.processorCount
        let memory = ByteCountFormatter.string(fromByteCount: Int64(info.physicalMemory), countStyle: .memory)
        let uptime = formatDuration(info.systemUptime)

        return """
        Host: \(host)
        OS: \(os)
        CPUs: \(cpu)
        Memory: \(memory)
        Uptime: \(uptime)
        """
    }

    private func gitStatusText() -> String {
        let directory = expandPath(repo) ?? resolvedDirectory()
        let status = runShellCommand("git -C \"\(directory)\" status --short --branch", cwd: directory)
        return "Repository: \(directory)\n\n\(status)"
    }


    private func runShellCommand(_ command: String, cwd: String?) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()

            var text = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""
            if !err.isEmpty {
                if !text.isEmpty { text.append("\n") }
                text.append(err)
            }
            return text.isEmpty ? "(no output)" : text
        } catch {
            return "Failed to run command: \(command)\n\(error.localizedDescription)"
        }
    }

    private func resolvedDirectory() -> String {
        if let path = expandPath(path) {
            return path
        }
        if let cwd = expandPath(cwd) {
            return cwd
        }
        return NSHomeDirectory()
    }

    private func expandPath(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return NSString(string: value).expandingTildeInPath
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let mins = (total % 3600) / 60
        return "\(days)d \(hours)h \(mins)m"
    }
}

/// A sum type representing a single pane in the grid layout.
///
/// Each cell in `TrmGridView` is either a terminal surface, an inline webview,
/// a utility plugin pane, or a vertical stack of panes sharing one grid cell.
enum GridPane: Identifiable {
    case terminal(Ghostty.SurfaceView)
    case webview(WebViewPane)
    case plugin(PluginPane)
    case agentOverview(AgentOverviewPane)
    case stack([GridPane])

    var id: ObjectIdentifier {
        switch self {
        case .terminal(let surface): return ObjectIdentifier(surface)
        case .webview(let pane): return ObjectIdentifier(pane)
        case .plugin(let pane): return ObjectIdentifier(pane)
        case .agentOverview(let pane): return ObjectIdentifier(pane)
        case .stack(let children):
            // Use the first child's identity as the stack's identity.
            guard let first = children.first else {
                // Should never happen — stacks always have ≥2 children.
                return ObjectIdentifier(Self.self)
            }
            return first.id
        }
    }

    /// Whether this pane is a vertical stack of sub-panes.
    var isStack: Bool {
        if case .stack = self { return true }
        return false
    }

    /// The children of this stack, or `nil` if this is not a stack.
    var stackChildren: [GridPane]? {
        if case .stack(let children) = self { return children }
        return nil
    }

    /// The first terminal surface in this pane (descending into stacks), if any.
    var firstTerminalSurface: Ghostty.SurfaceView? {
        switch self {
        case .terminal(let surface): return surface
        case .stack(let children):
            return children.lazy.compactMap { $0.firstTerminalSurface }.first
        default: return nil
        }
    }
}

/// Which edge of the target cell a dropped pane lands on when stacking.
/// Stacks render top-to-bottom, so `.top` inserts the pane as the first
/// sub-pane and `.bottom` appends it as the last.
enum StackDropEdge: Equatable {
    case top
    case bottom
}
