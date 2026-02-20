import Foundation
import GhosttyKit
import UserNotifications

/// Singleton wrapper around the termania C API (trm_app_t).
/// Provides Swift-friendly access to multi-pane grid management,
/// plugin registry, LLM integration, overlays, and watermarks.
final class Trm {
    static let shared = Trm()

    /// Opaque handle to the termania app.
    private(set) var handle: trm_app_t?

    private init() {
        // Check if TRM_CWD was passed (from the `trm` CLI wrapper) and look
        // for trm.toml in that directory.
        if let cwd = ProcessInfo.processInfo.environment["TRM_CWD"] {
            let configPath = (cwd as NSString).appendingPathComponent("trm.toml")
            if FileManager.default.fileExists(atPath: configPath) {
                handle = configPath.withCString { ptr in
                    termania_create_with_config(ptr)
                }
                return
            }
        }
        handle = termania_create()
    }

    deinit {
        if let h = handle {
            termania_destroy(h)
        }
    }

    /// Whether the termania subsystem is available.
    var isAvailable: Bool { handle != nil }

    /// Helper: read a C string buffer into a Swift String.
    private static func stringFromBuffer(_ buf: UnsafeMutablePointer<CChar>, length: Int) -> String? {
        guard length > 0 else { return nil }
        return String(cString: buf)
    }

    // MARK: - Plugin Registry

    /// Number of registered plugin types.
    var pluginTypeCount: UInt32 {
        guard let h = handle else { return 0 }
        return termania_plugin_type_count(h)
    }

    /// Get the internal name of a plugin type by index.
    func pluginTypeName(at index: UInt32) -> String? {
        guard let h = handle else { return nil }
        var buf = [CChar](repeating: 0, count: 129)
        let len = termania_plugin_type_name(h, index, &buf, UInt32(buf.count - 1))
        guard len > 0 else { return nil }
        buf[Int(len)] = 0
        return String(cString: buf)
    }

    /// Get the display name of a plugin type by index.
    func pluginTypeDisplayName(at index: UInt32) -> String? {
        guard let h = handle else { return nil }
        var buf = [CChar](repeating: 0, count: 129)
        let len = termania_plugin_type_display(h, index, &buf, UInt32(buf.count - 1))
        guard len > 0 else { return nil }
        buf[Int(len)] = 0
        return String(cString: buf)
    }

    /// List all registered plugin types as (name, displayName) pairs.
    var pluginTypes: [(name: String, displayName: String)] {
        (0..<pluginTypeCount).compactMap { idx in
            guard let name = pluginTypeName(at: idx),
                  let display = pluginTypeDisplayName(at: idx) else { return nil }
            return (name, display)
        }
    }

    // MARK: - API Key Storage

    private static let apiKeyDefaultsKey = "trm.claude.api_key"

    /// The stored Claude API key.
    var claudeAPIKey: String? {
        get { UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.apiKeyDefaultsKey) }
    }

    /// Whether an API token is configured (TOML config, OAuth, or UserDefaults).
    var hasAPIKey: Bool {
        // Check TOML config first
        if let configKey = llmConfig().apiKey, !configKey.isEmpty {
            return true
        }
        // Check OAuth Keychain credentials
        if OAuthTokenManager.shared.isAvailable {
            return true
        }
        // Fall back to UserDefaults
        guard let key = claudeAPIKey else { return false }
        return !key.isEmpty
    }

    /// Resolve the best available API key, preferring OAuth tokens.
    /// Priority: TOML config > OAuth Keychain > UserDefaults > env var.
    func resolvedAPIKey() async -> String? {
        // 1. TOML config always wins
        if let configKey = llmConfig().apiKey, !configKey.isEmpty {
            return configKey
        }
        // 2. OAuth token from Keychain
        if let token = try? await OAuthTokenManager.shared.validAccessToken() {
            return token
        }
        // 3. UserDefaults stored key
        if let key = claudeAPIKey, !key.isEmpty {
            return key
        }
        // 4. Environment variable
        if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        return nil
    }

    // MARK: - LLM Integration

    /// The shared LLM client instance.
    lazy var llmClient: TrmLLMClient = TrmLLMClient()

    /// Submit a prompt to the LLM.
    @discardableResult
    func llmSubmit(prompt: String) -> Bool {
        guard let h = handle else { return false }
        return prompt.withCString { cstr in
            termania_llm_submit(h, cstr, UInt32(prompt.utf8.count)) != 0
        }
    }

    /// Current LLM status.
    enum LLMStatus: UInt8 {
        case idle = 0
        case thinking = 1
        case done = 2
        case failed = 3
    }

    var llmStatus: LLMStatus {
        guard let h = handle else { return .idle }
        return LLMStatus(rawValue: termania_llm_status(h)) ?? .idle
    }

    /// Get the LLM response text.
    var llmResponseText: String? {
        guard let h = handle else { return nil }
        var buf = [CChar](repeating: 0, count: 4097)
        let len = termania_llm_response_text(h, &buf, UInt32(buf.count - 1))
        guard len > 0 else { return nil }
        buf[Int(len)] = 0
        return String(cString: buf)
    }

    /// Number of actions in the LLM response.
    var llmActionCount: UInt32 {
        guard let h = handle else { return 0 }
        return termania_llm_action_count(h)
    }

    /// Get the description of an LLM action.
    func llmActionDescription(at index: UInt32) -> String? {
        guard let h = handle else { return nil }
        var buf = [CChar](repeating: 0, count: 257)
        let len = termania_llm_action_desc(h, index, &buf, UInt32(buf.count - 1))
        guard len > 0 else { return nil }
        buf[Int(len)] = 0
        return String(cString: buf)
    }

    /// Execute pending LLM actions.
    func llmExecute() {
        guard let h = handle else { return }
        termania_llm_execute(h)
    }

    // MARK: - Overlays

    /// Add an overlay pane of the given type on top of fg pane.
    @discardableResult
    func addOverlay(fgIndex: UInt32, paneType: String = "terminal") -> Bool {
        guard let h = handle else { return false }
        return paneType.withCString { cstr in
            termania_add_overlay(h, fgIndex, cstr, UInt32(paneType.utf8.count)) != 0
        }
    }

    /// Remove overlay from fg pane.
    func removeOverlay(fgIndex: UInt32) {
        guard let h = handle else { return }
        termania_remove_overlay(h, fgIndex)
    }

    /// Swap overlay layers.
    func swapOverlay(fgIndex: UInt32) {
        guard let h = handle else { return }
        termania_swap_overlay(h, fgIndex)
    }

    /// Toggle focus between overlay layers.
    func toggleOverlayFocus(fgIndex: UInt32) {
        guard let h = handle else { return }
        termania_toggle_overlay_focus(h, fgIndex)
    }

    /// Check if a pane has an overlay.
    func hasOverlay(fgIndex: UInt32) -> Bool {
        guard let h = handle else { return false }
        return termania_has_overlay(h, fgIndex) != 0
    }

    // MARK: - Notifications

    /// Request notification permission from the user.
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Poll the C backend: reads pty output, processes text tap commands (send),
    /// and performs periodic health checks on the text tap socket.
    func poll() {
        guard let h = handle else { return }
        _ = termania_poll(h)
    }

    /// Drain pending send commands from the text tap queue.
    /// Returns an array of (paneIndex, text) tuples. paneIndex == -1 means "all panes".
    func drainSendCommands() -> [(pane: Int, text: String)] {
        guard let h = handle else { return [] }
        var results: [(pane: Int, text: String)] = []
        var paneIndex: UInt32 = 0
        var textBuf = [CChar](repeating: 0, count: 1025)
        var textLen: UInt32 = 0
        while termania_drain_send(h, &paneIndex, &textBuf, UInt32(textBuf.count - 1), &textLen) != 0 {
            let text = String(bytes: textBuf.prefix(Int(textLen)).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
            let pane = paneIndex == 0xFFFFFFFF ? -1 : Int(paneIndex)
            results.append((pane: pane, text: text))
            textLen = 0
        }
        return results
    }

    /// Poll the C API for a pending notification. Returns (title, body) or nil.
    func pollNotification() -> (title: String, body: String)? {
        guard let h = handle else { return nil }
        var titleBuf = [CChar](repeating: 0, count: 257)
        var bodyBuf = [CChar](repeating: 0, count: 513)
        let result = termania_poll_notification(h, &titleBuf, UInt32(titleBuf.count - 1), &bodyBuf, UInt32(bodyBuf.count - 1))
        guard result != 0 else { return nil }
        let title = String(cString: titleBuf)
        let body = String(cString: bodyBuf)
        return (title, body)
    }

    /// Show a native macOS notification.
    func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Start a timer that polls for notifications from the Text Tap socket.
    private var notificationTimer: Timer?

    func startNotificationPolling() {
        requestNotificationPermission()
        notificationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            _ = self.poll()
            let sendCmds = self.drainSendCommands()
            for cmd in sendCmds {
                NotificationCenter.default.post(
                    name: .trmTextTapSend,
                    object: nil,
                    userInfo: ["pane": cmd.pane, "text": cmd.text]
                )
            }
            if let notification = self.pollNotification() {
                self.showNotification(title: notification.title, body: notification.body)
                let paneIndex: Int
                if let h = self.handle {
                    paneIndex = Int(termania_focused_pane(h))
                } else {
                    paneIndex = 0
                }
                NotificationCenter.default.post(
                    name: .trmClaudeNeedsAttention,
                    object: nil,
                    userInfo: ["paneIndex": paneIndex]
                )
            }
        }
    }

    func stopNotificationPolling() {
        notificationTimer?.invalidate()
        notificationTimer = nil
    }

    // MARK: - Context Usage Tracking

    /// Warning level based on context window usage percentage.
    enum ContextWarningLevel {
        case normal      // 0-49%
        case elevated    // 50-74%
        case warning     // 75-89%
        case critical    // 90-100%

        init(percentage: UInt8) {
            switch percentage {
            case 0..<50: self = .normal
            case 50..<75: self = .elevated
            case 75..<90: self = .warning
            default: self = .critical
            }
        }
    }

    /// Data about Claude Code's context window usage.
    struct ContextUsageData {
        let usedTokens: UInt64
        let totalTokens: UInt64
        let percentage: UInt8
        let isPreCompact: Bool
        let sessionId: String
        let lastUpdate: Date

        var warningLevel: ContextWarningLevel {
            ContextWarningLevel(percentage: percentage)
        }

        /// Human-readable token count (e.g., "45.2K / 200K").
        var formattedTokens: String {
            "\(Self.formatTokens(usedTokens)) / \(Self.formatTokens(totalTokens))"
        }

        private static func formatTokens(_ count: UInt64) -> String {
            if count >= 1_000_000 {
                return String(format: "%.1fM", Double(count) / 1_000_000)
            } else if count >= 1_000 {
                return String(format: "%.1fK", Double(count) / 1_000)
            } else {
                return "\(count)"
            }
        }
    }

    /// Poll the C API for context usage data. Returns nil if no data available.
    func pollContextUsage() -> ContextUsageData? {
        guard let h = handle else { return nil }

        var used: UInt64 = 0
        var total: UInt64 = 0
        var pct: UInt8 = 0
        var preCompact: UInt8 = 0

        let result = termania_context_usage(h, &used, &total, &pct, &preCompact)
        guard result != 0 else { return nil }

        // Read session ID
        var sidBuf = [CChar](repeating: 0, count: 129)
        let sidLen = termania_context_session_id(h, &sidBuf, UInt32(sidBuf.count - 1))
        let sessionId: String
        if sidLen > 0 {
            sidBuf[Int(sidLen)] = 0
            sessionId = String(cString: sidBuf)
        } else {
            sessionId = ""
        }

        // Read last update timestamp
        let timestamp = termania_context_last_update(h)
        let lastUpdate = Date(timeIntervalSince1970: TimeInterval(timestamp))

        return ContextUsageData(
            usedTokens: used,
            totalTokens: total,
            percentage: pct,
            isPreCompact: preCompact != 0,
            sessionId: sessionId,
            lastUpdate: lastUpdate
        )
    }

    // MARK: - Process Info

    /// Get the child PID (shell process) for a pane.
    func paneChildPid(at index: UInt32) -> pid_t {
        guard let h = handle else { return 0 }
        return pid_t(termania_pane_child_pid(h, index))
    }

    // MARK: - Text Tap

    /// Returns a bitset of panes that have been targeted by Text Tap send commands.
    /// Bit N is set if pane N received a send/send_command from a socket client.
    func textTapActivePanes() -> UInt64 {
        guard let h = handle else { return 0 }
        return termania_text_tap_active_panes(h)
    }

    /// Check if a specific pane is targeted by a Text Tap client.
    func isTextTapActive(pane index: Int) -> Bool {
        guard index >= 0, index < 64 else { return false }
        return (textTapActivePanes() >> UInt64(index)) & 1 != 0
    }

    // MARK: - Watermarks

    /// Get the watermark text for a pane.
    func watermark(forPane index: UInt32) -> String? {
        guard let h = handle else { return nil }
        var buf = [CChar](repeating: 0, count: 129)
        let len = termania_pane_watermark(h, index, &buf, UInt32(buf.count - 1))
        guard len > 0 else { return nil }
        buf[Int(len)] = 0
        return String(cString: buf)
    }

    /// Notification posted when any pane watermark changes.
    static let watermarkDidChange = Notification.Name("TrmWatermarkDidChange")

    /// Set the watermark text for a pane.
    func setWatermark(forPane index: UInt32, text: String) {
        guard let h = handle else { return }
        text.withCString { cstr in
            termania_set_watermark(h, index, cstr, UInt32(text.utf8.count))
        }
        NotificationCenter.default.post(name: Trm.watermarkDidChange, object: nil)
    }

    // MARK: - Session / Grid Config

    /// Configured pane config from termania.toml.
    struct TrmPaneConfig {
        let paneType: String
        let command: String?
        let cwd: String?
        let watermark: String?
        let title: String?
        let url: String?
        let file: String?
        let content: String?
        let target: String?
        let targetTitle: String?
        let path: String?
        let refreshMs: UInt64?
        let repo: String?
        let initialCommands: [String]
        let patterns: [String]
    }

    /// Grid layout config from termania.toml.
    struct TrmGridConfig {
        let rows: Int
        let cols: Int
        let gap: CGFloat
        let padding: CGFloat
        let panes: [TrmPaneConfig]
    }

    /// Read grid/session config from a specific config file path.
    /// Uses `termania_create_config_only` to avoid starting the text tap
    /// server, which would steal the socket from the primary instance.
    static func gridConfig(fromConfigPath path: String) -> TrmGridConfig? {
        guard let h = path.withCString({ ptr in termania_create_config_only(ptr) }) else {
            return nil
        }
        defer { termania_destroy(h) }
        return readGridConfig(from: h)
    }

    /// Read the grid/session config from termania.toml.
    func gridConfig() -> TrmGridConfig {
        guard let h = handle else {
            return TrmGridConfig(rows: 1, cols: 1, gap: 4, padding: 4, panes: [])
        }

        return Self.readGridConfig(from: h)
    }

    private static func readGridConfig(from h: trm_app_t) -> TrmGridConfig {
        let rows = Int(termania_grid_rows(h))
        let cols = Int(termania_grid_cols(h))
        let gap = CGFloat(termania_grid_gap(h))
        let padding = CGFloat(termania_grid_padding(h))

        let paneCount = Int(termania_config_pane_count(h))
        var panes: [TrmPaneConfig] = []
        for i in 0..<UInt32(paneCount) {
            let paneType = readPaneField(h, pane: i, field: 4) ?? "terminal"
            let command = readPaneField(h, pane: i, field: 0)
            let cwd = readPaneField(h, pane: i, field: 1)
            let watermark = readPaneField(h, pane: i, field: 2)
            let title = readPaneField(h, pane: i, field: 3)
            let url = readPaneField(h, pane: i, field: 5)
            let file = readPaneField(h, pane: i, field: 6)
            let content = readPaneField(h, pane: i, field: 7)
            let target = readPaneField(h, pane: i, field: 8)
            let targetTitle = readPaneField(h, pane: i, field: 9)
            let path = readPaneField(h, pane: i, field: 10)
            let refreshMs = readPaneField(h, pane: i, field: 11).flatMap(UInt64.init)
            let repo = readPaneField(h, pane: i, field: 12)

            var initialCommands: [String] = []
            let cmdCount = Int(termania_config_pane_initial_cmd_count(h, i))
            for j in 0..<UInt32(cmdCount) {
                if let cmd = readPaneInitialCommand(h, pane: i, cmdIndex: j) {
                    initialCommands.append(cmd)
                }
            }

            var patterns: [String] = []
            let patCount = Int(termania_config_pane_patterns_count(h, i))
            for j in 0..<UInt32(patCount) {
                if let pat = readPanePattern(h, pane: i, patIndex: j) {
                    patterns.append(pat)
                }
            }

            panes.append(TrmPaneConfig(
                paneType: paneType,
                command: command,
                cwd: cwd,
                watermark: watermark,
                title: title,
                url: url,
                file: file,
                content: content,
                target: target,
                targetTitle: targetTitle,
                path: path,
                refreshMs: refreshMs,
                repo: repo,
                initialCommands: initialCommands,
                patterns: patterns
            ))
        }

        return TrmGridConfig(rows: rows, cols: cols, gap: gap, padding: padding, panes: panes)
    }

    // MARK: - LLM Config

    /// LLM configuration read from termania.toml [llm] section.
    struct LLMConfig {
        let provider: String
        let apiKey: String?
        let model: String?
        let baseURL: String?
        let maxTokens: UInt32
        let systemPrompt: String?
    }

    /// Read the LLM config from the termania C API.
    func llmConfig() -> LLMConfig {
        guard let h = handle else {
            return LLMConfig(provider: "anthropic", apiKey: nil, model: nil, baseURL: nil, maxTokens: 1024, systemPrompt: nil)
        }

        let provider = readStringField { buf, max in termania_config_llm_provider(h, buf, max) } ?? "lmstudio"
        let apiKey = readStringField { buf, max in termania_config_llm_api_key(h, buf, max) }
        let model = readStringField { buf, max in termania_config_llm_model(h, buf, max) }
        let baseURL = readStringField { buf, max in termania_config_llm_base_url(h, buf, max) }
        let maxTokens = termania_config_llm_max_tokens(h)
        let systemPrompt = readStringField { buf, max in termania_config_llm_system_prompt(h, buf, max) }

        return LLMConfig(
            provider: provider,
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            maxTokens: maxTokens,
            systemPrompt: systemPrompt
        )
    }

    /// Generic helper to read a buffer-copy C API field into a Swift String.
    private func readStringField(_ reader: (UnsafeMutablePointer<CChar>, UInt32) -> UInt32) -> String? {
        var buf = [CChar](repeating: 0, count: 1025)
        let len = reader(&buf, UInt32(buf.count - 1))
        guard len > 0 else { return nil }
        buf[Int(len)] = 0
        return String(cString: buf)
    }

    private static func readPaneField(_ h: trm_app_t, pane: UInt32, field: UInt8) -> String? {
        var buf = [CChar](repeating: 0, count: 513)
        let len = termania_config_pane_field(h, pane, field, &buf, UInt32(buf.count - 1))
        guard len > 0 else { return nil }
        buf[Int(len)] = 0
        return String(cString: buf)
    }

    private static func readPaneInitialCommand(_ h: trm_app_t, pane: UInt32, cmdIndex: UInt32) -> String? {
        var buf = [CChar](repeating: 0, count: 513)
        let len = termania_config_pane_initial_cmd(h, pane, cmdIndex, &buf, UInt32(buf.count - 1))
        guard len > 0 else { return nil }
        buf[Int(len)] = 0
        return String(cString: buf)
    }

    private static func readPanePattern(_ h: trm_app_t, pane: UInt32, patIndex: UInt32) -> String? {
        var buf = [CChar](repeating: 0, count: 513)
        let len = termania_config_pane_pattern(h, pane, patIndex, &buf, UInt32(buf.count - 1))
        guard len > 0 else { return nil }
        buf[Int(len)] = 0
        return String(cString: buf)
    }
}
