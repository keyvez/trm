import Foundation
import SwiftUI
import Combine

/// Adapter that runs a plugin as a subprocess, communicating via
/// newline-delimited JSON over stdin/stdout pipes. Conforms to all
/// `ServicePlugin` protocols so the registry, scanner, and overlay
/// pipeline require zero changes.
///
/// If the subprocess crashes, the host clears overlay state (so the
/// UI stays clean) and restarts with exponential backoff. After 3
/// consecutive failures the plugin is left dead — trm keeps running.
///
/// Containment: extensions run out-of-process, so the worst a buggy or
/// leaky extension can do is get itself killed. A memory watchdog SIGKILLs
/// the process over its cap (manifest `memory_limit_mb`, default 256), a
/// `ulimit -t` shim caps CPU seconds, and plugin-requested actions are
/// gated by manifest capabilities — repeated denials kill the plugin.
@MainActor
final class SubprocessPluginHost: ObservableObject, ServicePlugin, ObservableServicePlugin, TerminalOutputSubscriber, ServicePluginOverlayProvider {

    // MARK: - ServicePlugin

    let pluginId: String
    let displayName: String

    static let requiredCapabilities: Set<PluginCapability> = [.terminalOutputRead]

    private weak var registry: ServicePluginRegistry?

    func configure(registry: ServicePluginRegistry) {
        self.registry = registry
    }

    // MARK: - Configuration

    /// Path to the plugin executable.
    let executablePath: String

    /// Optional configuration payload forwarded to the plugin on launch.
    var configPayload: HostConfigPayload

    /// Capabilities granted to this instance (from its manifest). Actions
    /// requiring an ungranted capability are dropped.
    let capabilities: Set<PluginCapability>

    /// Memory cap; the watchdog SIGKILLs the process above this.
    let memoryLimitMB: Int

    /// CPU-seconds cap applied via `ulimit -t` in the launch shim.
    let cpuLimitSeconds: Int

    /// Executes capability-approved TrmActions. Set at registration.
    var actionExecutor: (([TrmAction]) -> Void)?

    /// Publisher of context usage updates, forwarded to the plugin as
    /// `context_usage` events. Set at registration.
    var contextUsagePublisher: AnyPublisher<Trm.ContextUsageData?, Never>? {
        didSet {
            contextCancellable = contextUsagePublisher?.sink { [weak self] usage in
                guard let usage else { return }
                self?.sendMessage(.contextUsage(
                    usedTokens: usage.usedTokens,
                    totalTokens: usage.totalTokens,
                    percentage: Int(usage.percentage),
                    sessionId: usage.sessionId
                ))
            }
        }
    }
    private var contextCancellable: AnyCancellable?

    /// Capability-denial counter; the plugin is killed for good once this
    /// crosses `maxViolations` (a misbehaving extension, not a buggy one).
    private var violationCount = 0
    private static let maxViolations = 20

    // MARK: - Published State

    @Published private(set) var overlayState: PluginOverlayState = .empty

    // MARK: - Process Management

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// Background queue for reading stdout from the subprocess.
    private let readQueue = DispatchQueue(label: "com.trm.subprocess-plugin.read", qos: .userInitiated)

    /// Whether `stop()` was called intentionally (don't restart).
    private var isIntentionallyStopped = false

    /// Number of consecutive restart attempts since last stable run.
    private var restartCount = 0

    /// Maximum restart attempts before giving up.
    private static let maxRestarts = 3

    /// Timer that resets `restartCount` after stable running.
    private var stabilityTimer: DispatchWorkItem?

    // MARK: - Init

    /// Create a subprocess plugin host.
    ///
    /// - Parameters:
    ///   - id: Unique plugin identifier.
    ///   - name: Human-readable display name.
    ///   - executablePath: Absolute path to the plugin executable.
    ///   - config: Optional configuration forwarded to the plugin.
    ///   - capabilities: Manifest-granted capabilities (action gating).
    ///   - memoryLimitMB: Memory cap for the watchdog (default 256 MB).
    ///   - cpuLimitSeconds: CPU-seconds cap via ulimit (default 300).
    init(
        id: String,
        name: String,
        executablePath: String,
        config: HostConfigPayload = HostConfigPayload(),
        capabilities: Set<PluginCapability> = [.terminalOutputRead],
        memoryLimitMB: Int = 256,
        cpuLimitSeconds: Int = 300
    ) {
        self.pluginId = id
        self.displayName = name
        self.executablePath = executablePath
        self.configPayload = config
        self.capabilities = capabilities
        self.memoryLimitMB = max(16, memoryLimitMB)
        self.cpuLimitSeconds = max(10, cpuLimitSeconds)
    }

    // MARK: - Lifecycle

    func start() {
        isIntentionallyStopped = false
        launchProcess()
    }

    func stop() {
        isIntentionallyStopped = true
        stabilityTimer?.cancel()
        stabilityTimer = nil
        sendMessage(.stop)
        terminateProcess()
        overlayState = .empty
    }

    // MARK: - TerminalOutputSubscriber

    func terminalOutputDidChange(paneId: Int, text: String, hash: String) {
        sendMessage(.terminalOutput(pane: paneId, text: text, hash: hash))
    }

    func terminalPaneDidClose(paneId: Int) {
        sendMessage(.paneClosed(pane: paneId))
    }

    func terminalCommandDidFinish(paneId: Int) {
        sendMessage(.commandFinished(pane: paneId))
    }

    // MARK: - ServicePluginOverlayProvider

    var overlayAlignment: Alignment {
        overlayState.alignment
    }

    func overlayView(forPaneId paneId: Int) -> AnyView? {
        overlayState.renderView(forPaneId: paneId)
    }

    // MARK: - Process Lifecycle

    private func launchProcess() {
        guard !isIntentionallyStopped else { return }
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            NSLog("[SubprocessPluginHost] \(pluginId): executable not found at \(executablePath)")
            return
        }

        let proc = Process()
        // Launch through a sh shim so we can apply a hard CPU-seconds cap
        // (ulimit -t delivers SIGXCPU/SIGKILL to runaway spins). Memory is
        // handled by the watchdog below — ulimit -v is a no-op on macOS.
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [
            "-c",
            "ulimit -t \(cpuLimitSeconds) 2>/dev/null; exec \"$0\"",
            executablePath,
        ]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        // Handle unexpected termination
        proc.terminationHandler = { [weak self] terminatedProcess in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isIntentionallyStopped else { return }
                let status = terminatedProcess.terminationStatus
                NSLog("[SubprocessPluginHost] \(self.pluginId): process exited with status \(status)")
                self.handleProcessExit()
            }
        }

        do {
            try proc.run()
        } catch {
            NSLog("[SubprocessPluginHost] \(pluginId): failed to launch: \(error)")
            return
        }

        // Send configure + start messages
        sendMessage(.configure(config: configPayload))
        sendMessage(.start)

        // Start reading stdout on background queue
        startReadingStdout(stdout)

        // Log stderr for diagnostics
        startReadingStderr(stderr)

        // Schedule stability timer — reset restart count after 60s of stable running
        scheduleStabilityReset()

        // Memory watchdog
        startMemoryWatchdog(pid: proc.processIdentifier)
    }

    // MARK: - Memory Watchdog

    private var memoryWatchdog: Timer?

    /// Poll the process's physical footprint every 5s; SIGKILL it over the
    /// cap. The existing exit handler then restarts with backoff, so a
    /// leaking extension degrades to periodic restarts instead of eating
    /// the machine.
    private func startMemoryWatchdog(pid: pid_t) {
        memoryWatchdog?.invalidate()
        let capBytes = UInt64(memoryLimitMB) * 1024 * 1024
        memoryWatchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            var info = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
                ptr.withMemoryRebound(to: (rusage_info_t?.self), capacity: 1) { reboundPtr in
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, reboundPtr)
                }
            }
            guard result == 0 else {
                // Process is gone; exit handling owns cleanup.
                timer.invalidate()
                return
            }
            if info.ri_phys_footprint > capBytes {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    NSLog("[SubprocessPluginHost] \(self.pluginId): over memory cap (\(info.ri_phys_footprint / 1_048_576)MB > \(self.memoryLimitMB)MB), killing")
                    kill(pid, SIGKILL)
                }
                timer.invalidate()
            }
        }
    }

    private func terminateProcess() {
        memoryWatchdog?.invalidate()
        memoryWatchdog = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func handleProcessExit() {
        // Clear overlay state immediately so the UI stays clean
        overlayState = .empty
        terminateProcess()

        guard restartCount < Self.maxRestarts else {
            NSLog("[SubprocessPluginHost] \(pluginId): exceeded max restarts (\(Self.maxRestarts)), leaving plugin dead")
            return
        }

        restartCount += 1
        let delay = pow(2.0, Double(restartCount)) // 2s, 4s, 8s
        NSLog("[SubprocessPluginHost] \(pluginId): restarting in \(delay)s (attempt \(restartCount)/\(Self.maxRestarts))")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isIntentionallyStopped else { return }
            self.launchProcess()
        }
    }

    private func scheduleStabilityReset() {
        stabilityTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartCount = 0
        }
        stabilityTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: item)
    }

    // MARK: - stdin (Host → Plugin)

    private func sendMessage(_ message: HostMessage) {
        guard let pipe = stdinPipe,
              let data = PluginMessageCodec.encode(message) else { return }

        // Write on a background queue to avoid blocking the main thread
        // if the pipe buffer is full.
        let fileHandle = pipe.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try fileHandle.write(contentsOf: data)
            } catch {
                // Pipe broken — process likely already exiting,
                // terminationHandler will handle cleanup.
            }
        }
    }

    // MARK: - stdout (Plugin → Host)

    private func startReadingStdout(_ pipe: Pipe) {
        let fileHandle = pipe.fileHandleForReading

        readQueue.async { [weak self] in
            var buffer = Data()

            while true {
                let chunk = fileHandle.availableData
                guard !chunk.isEmpty else {
                    // EOF — process exited (terminationHandler handles restart)
                    break
                }

                buffer.append(chunk)

                // Process complete lines
                while let newlineRange = buffer.range(of: Data([0x0A])) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                    buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                    guard let line = String(data: lineData, encoding: .utf8),
                          !line.isEmpty,
                          let message = PluginMessageCodec.decode(line) else {
                        continue
                    }

                    DispatchQueue.main.async { [weak self] in
                        self?.handlePluginMessage(message)
                    }
                }
            }
        }
    }

    private func startReadingStderr(_ pipe: Pipe) {
        let fileHandle = pipe.fileHandleForReading

        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let chunk = fileHandle.availableData
                guard !chunk.isEmpty else { break }
                if let text = String(data: chunk, encoding: .utf8) {
                    let id = self?.pluginId ?? "unknown"
                    NSLog("[SubprocessPluginHost] \(id) stderr: \(text)")
                }
            }
        }
    }

    // MARK: - Message Handling

    private func handlePluginMessage(_ message: PluginMessage) {
        switch message.type {
        case .ready:
            NSLog("[SubprocessPluginHost] \(pluginId): plugin ready")

        case .state:
            guard let overlayName = message.overlay,
                  let template = OverlayTemplate(rawValue: overlayName) else {
                NSLog("[SubprocessPluginHost] \(pluginId): unknown overlay template '\(message.overlay ?? "nil")'")
                return
            }

            let alignment = message.alignment.map(AlignmentCodec.decode) ?? .top

            overlayState = PluginOverlayState(
                template: template,
                alignment: alignment,
                paneData: message.panes ?? [:]
            )

        case .error:
            NSLog("[SubprocessPluginHost] \(pluginId): plugin error: \(message.message ?? "unknown")")

        case .action:
            handleActionRequest(message.actions ?? [])
        }
    }

    // MARK: - Action Channel (capability-gated)

    /// The capability an action needs before the host will execute it.
    private static func requiredCapability(forActionType type: String) -> PluginCapability? {
        switch type {
        case "send_command", "send_to_all":
            return .sendInput
        case "spawn_pane", "close_pane", "focus_pane", "open_url":
            return .paneControl
        case "set_watermark", "set_title", "clear_watermark":
            return .paneDecorate
        case "notify":
            return .userNotifications
        case "message":
            return nil // benign: shows text in the palette status area
        default:
            return nil
        }
    }

    private func handleActionRequest(_ payloads: [PluginActionPayload]) {
        var approved: [TrmAction] = []
        for payload in payloads {
            if let needed = Self.requiredCapability(forActionType: payload.type),
               !capabilities.contains(needed) {
                violationCount += 1
                NSLog("[SubprocessPluginHost] \(pluginId): DENIED action '\(payload.type)' (missing capability, violation \(violationCount)/\(Self.maxViolations))")
                if violationCount >= Self.maxViolations {
                    NSLog("[SubprocessPluginHost] \(pluginId): too many capability violations, stopping plugin")
                    stop()
                    return
                }
                continue
            }

            switch payload.type {
            case "send_command":
                if let pane = payload.pane, let cmd = payload.command {
                    approved.append(.sendCommand(pane: pane, command: cmd))
                }
            case "send_to_all":
                if let cmd = payload.command {
                    approved.append(.sendToAll(command: cmd))
                }
            case "set_title":
                if let pane = payload.pane, let title = payload.title {
                    approved.append(.setTitle(pane: pane, title: title))
                }
            case "set_watermark":
                if let pane = payload.pane, let wm = payload.watermark {
                    approved.append(.setWatermark(pane: pane, watermark: wm))
                }
            case "clear_watermark":
                if let pane = payload.pane {
                    approved.append(.clearWatermark(pane: pane))
                }
            case "spawn_pane":
                approved.append(.spawnPane)
            case "close_pane":
                if let pane = payload.pane {
                    approved.append(.closePane(pane: pane))
                }
            case "focus_pane":
                if let pane = payload.pane {
                    approved.append(.focusPane(pane: pane))
                }
            case "message":
                if let text = payload.text {
                    approved.append(.message(text: text))
                }
            case "notify":
                Trm.shared.showNotification(
                    title: payload.title ?? displayName,
                    body: payload.body ?? "")
            case "open_url":
                if let raw = payload.url, let url = URL(string: raw) {
                    NSWorkspace.shared.open(url)
                }
            default:
                NSLog("[SubprocessPluginHost] \(pluginId): unknown action type '\(payload.type)'")
            }
        }
        if !approved.isEmpty {
            actionExecutor?(approved)
        }
    }
}
