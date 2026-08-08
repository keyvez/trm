import Foundation
import AppKit
import Combine
import os

/// Evaluates one rules-extension's if-this-then-that rules natively.
///
/// One instance is registered per enabled `kind = "rules"` extension. Rules
/// react to scanner events (output change / command finish / pane close),
/// agent attention, context-usage thresholds, and interval timers, and fire
/// actions through the host controller's `executeTrmActions` plus a few
/// native-only actions (notify / run_shell / open_url).
///
/// Because rules are data, not code, this tier cannot leak or block: regex
/// inputs are length-capped, every rule has a cooldown, and shell actions
/// run detached with a timeout.
@MainActor
final class RulesEnginePlugin: ServicePlugin, TerminalOutputSubscriber {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.trm",
        category: "RulesEngine"
    )

    /// Max bytes of pane text a regex is applied to (tail of the output).
    /// NSRegularExpression has no timeout; bounding the input bounds the cost.
    private static let regexInputCap = 16 * 1024

    /// Interval/attention/context rules must fire once app-wide, not once
    /// per window (each window controller has its own registry). The first
    /// live instance for an extension claims ownership of those triggers.
    private static var globalTriggerOwners: [String: ObjectIdentifier] = [:]

    let pluginId: String
    let displayName: String
    static let requiredCapabilities: Set<PluginCapability> = [
        .terminalOutputRead, .userNotifications,
    ]

    /// Executes TrmActions against the owning controller. Set at registration.
    var actionExecutor: (([TrmAction]) -> Void)?
    /// Resolves a watermark for a pane id (for scope matching). Set at registration.
    var watermarkProvider: ((Int) -> String?)?
    /// Publisher of context usage updates from the owning controller.
    var contextUsagePublisher: AnyPublisher<Trm.ContextUsageData?, Never>?

    private let manifest: ExtensionManifest
    private weak var registry: ServicePluginRegistry?

    /// Compiled regexes by rule index.
    private var compiledRegexes: [Int: NSRegularExpression] = [:]
    /// Last fire time by rule index (cooldown enforcement).
    private var lastFired: [Int: Date] = [:]
    /// Whether a context_usage rule is currently above threshold (edge trigger).
    private var contextAboveThreshold: [Int: Bool] = [:]

    private var intervalTimers: [Timer] = []
    private var attentionObserver: NSObjectProtocol?
    private var contextCancellable: AnyCancellable?

    init(manifest: ExtensionManifest) {
        self.manifest = manifest
        self.pluginId = "ext.\(manifest.name)"
        self.displayName = manifest.name

        for (i, rule) in manifest.rules.enumerated() {
            if case .outputRegex(let pattern, _) = rule.trigger {
                compiledRegexes[i] = try? NSRegularExpression(pattern: pattern)
            }
        }
    }

    func configure(registry: ServicePluginRegistry) {
        self.registry = registry
    }

    func start() {
        // Claim app-wide triggers if unowned.
        let key = manifest.name
        if Self.globalTriggerOwners[key] == nil {
            Self.globalTriggerOwners[key] = ObjectIdentifier(self)
        }
        guard Self.globalTriggerOwners[key] == ObjectIdentifier(self) else { return }

        for (i, rule) in manifest.rules.enumerated() {
            switch rule.trigger {
            case .interval(let seconds):
                let timer = Timer.scheduledTimer(
                    withTimeInterval: seconds, repeats: true
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.fire(ruleIndex: i, triggerPane: nil)
                    }
                }
                intervalTimers.append(timer)

            case .attention:
                if attentionObserver == nil {
                    attentionObserver = NotificationCenter.default.addObserver(
                        forName: .trmClaudeNeedsAttention,
                        object: nil,
                        queue: .main
                    ) { [weak self] notification in
                        let pane = notification.userInfo?["paneId"] as? Int
                        Task { @MainActor [weak self] in
                            self?.attentionFired(pane: pane)
                        }
                    }
                }

            case .contextUsage:
                if contextCancellable == nil, let publisher = contextUsagePublisher {
                    contextCancellable = publisher.sink { [weak self] usage in
                        guard let usage else { return }
                        self?.contextUsageChanged(usage)
                    }
                }

            default:
                break
            }
        }
    }

    func stop() {
        let key = manifest.name
        if Self.globalTriggerOwners[key] == ObjectIdentifier(self) {
            Self.globalTriggerOwners[key] = nil
        }
        for timer in intervalTimers { timer.invalidate() }
        intervalTimers.removeAll()
        if let attentionObserver {
            NotificationCenter.default.removeObserver(attentionObserver)
            self.attentionObserver = nil
        }
        contextCancellable?.cancel()
        contextCancellable = nil
        lastFired.removeAll()
    }

    // MARK: - TerminalOutputSubscriber

    func terminalOutputDidChange(paneId: Int, text: String, hash: String) {
        for (i, rule) in manifest.rules.enumerated() {
            guard case .outputRegex(_, let scope) = rule.trigger,
                  scopeMatches(scope, paneId: paneId),
                  let regex = compiledRegexes[i] else { continue }

            let capped = String(text.suffix(Self.regexInputCap))
            let range = NSRange(capped.startIndex..., in: capped)
            guard regex.firstMatch(in: capped, range: range) != nil else { continue }
            fire(ruleIndex: i, triggerPane: paneId)
        }
    }

    func terminalPaneDidClose(paneId: Int) {
        for (i, rule) in manifest.rules.enumerated() {
            guard case .paneClosed = rule.trigger else { continue }
            fire(ruleIndex: i, triggerPane: paneId)
        }
    }

    func terminalCommandDidFinish(paneId: Int) {
        for (i, rule) in manifest.rules.enumerated() {
            guard case .commandFinished(let scope) = rule.trigger,
                  scopeMatches(scope, paneId: paneId) else { continue }
            fire(ruleIndex: i, triggerPane: paneId)
        }
    }

    // MARK: - Other Triggers

    private func attentionFired(pane: Int?) {
        for (i, rule) in manifest.rules.enumerated() {
            guard case .attention = rule.trigger else { continue }
            fire(ruleIndex: i, triggerPane: pane)
        }
    }

    private func contextUsageChanged(_ usage: Trm.ContextUsageData) {
        for (i, rule) in manifest.rules.enumerated() {
            guard case .contextUsage(let threshold) = rule.trigger else { continue }
            let above = Int(usage.percentage) >= threshold
            let wasAbove = contextAboveThreshold[i] ?? false
            contextAboveThreshold[i] = above
            // Edge-triggered: fire only on the below→above transition.
            if above && !wasAbove {
                fire(ruleIndex: i, triggerPane: nil)
            }
        }
    }

    // MARK: - Firing

    private func scopeMatches(_ scope: ExtensionRule.Scope, paneId: Int) -> Bool {
        switch scope {
        case .all:
            return true
        case .pane(let id):
            return id == paneId
        case .watermark(let name):
            return watermarkProvider?(paneId) == name
        }
    }

    private func fire(ruleIndex: Int, triggerPane: Int?) {
        let rule = manifest.rules[ruleIndex]

        // Cooldown: prevents send_command → output-change → re-trigger loops.
        let now = Date()
        if let last = lastFired[ruleIndex],
           now.timeIntervalSince(last) < rule.cooldownSeconds {
            return
        }
        lastFired[ruleIndex] = now

        Self.logger.info("extension \(self.manifest.name) rule #\(ruleIndex) fired (pane \(triggerPane ?? -1))")

        var trmActions: [TrmAction] = []
        for action in rule.actions {
            switch action {
            case .sendCommand(let pane, let command):
                if let id = pane.resolve(triggerPane: triggerPane) {
                    trmActions.append(.sendCommand(pane: id, command: command))
                }
            case .sendToAll(let command):
                trmActions.append(.sendToAll(command: command))
            case .setWatermark(let pane, let watermark):
                if let id = pane.resolve(triggerPane: triggerPane) {
                    trmActions.append(.setWatermark(pane: id, watermark: watermark))
                }
            case .setTitle(let pane, let title):
                if let id = pane.resolve(triggerPane: triggerPane) {
                    trmActions.append(.setTitle(pane: id, title: title))
                }
            case .clearWatermark(let pane):
                if let id = pane.resolve(triggerPane: triggerPane) {
                    trmActions.append(.clearWatermark(pane: id))
                }
            case .focusPane(let pane):
                if let id = pane.resolve(triggerPane: triggerPane) {
                    trmActions.append(.focusPane(pane: id))
                }
            case .spawnPane:
                trmActions.append(.spawnPane)
            case .closePane(let pane):
                if let id = pane.resolve(triggerPane: triggerPane) {
                    trmActions.append(.closePane(pane: id))
                }
            case .message(let text):
                trmActions.append(.message(text: text))
            case .notify(let title, let body):
                Trm.shared.showNotification(title: title, body: body)
            case .runShell(let command):
                runShell(command)
            case .openURL(let url):
                if let parsed = URL(string: url) {
                    NSWorkspace.shared.open(parsed)
                }
            }
        }

        if !trmActions.isEmpty {
            actionExecutor?(trmActions)
        }
    }

    /// Run a shell command detached with a hard timeout. Output is logged,
    /// never displayed — rules that want visible output should send_command
    /// into a pane instead.
    private func runShell(_ command: String) {
        let name = manifest.name
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Self.logger.error("extension \(name) run_shell failed: \(error.localizedDescription)")
            return
        }
        // Hard timeout so a hung command can't accumulate processes.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
            if process.isRunning {
                process.terminate()
                Self.logger.warning("extension \(name) run_shell timed out after 30s, terminated")
            }
        }
    }
}
