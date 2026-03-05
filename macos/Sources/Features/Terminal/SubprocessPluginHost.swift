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
    init(id: String, name: String, executablePath: String, config: HostConfigPayload = HostConfigPayload()) {
        self.pluginId = id
        self.displayName = name
        self.executablePath = executablePath
        self.configPayload = config
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
        proc.executableURL = URL(fileURLWithPath: executablePath)

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
    }

    private func terminateProcess() {
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
        }
    }
}
