import Foundation

/// Parsed `extension.toml` manifest describing a trm extension.
///
/// Two kinds:
/// - `rules`: declarative if-this-then-that rules evaluated natively by
///   `RulesEnginePlugin`. No code runs; safe and leak-free by construction.
/// - `program`: an executable (any language) supervised by
///   `SubprocessPluginHost`, speaking newline-delimited JSON over stdio.
///
/// Example:
/// ```toml
/// name = "build-fail-notify"
/// version = "1"
/// kind = "rules"
/// description = "Notify when a build fails"
///
/// [[rules]]
/// cooldown_seconds = 10
///
/// [rules.trigger]
/// type = "output_regex"
/// pattern = "BUILD FAILED"
/// scope = "all"            # all | watermark:<name> | pane:<id>
///
/// [[rules.actions]]
/// type = "notify"
/// title = "Build failed"
/// body = "A pane printed BUILD FAILED"
/// ```
struct ExtensionManifest {
    enum Kind: String {
        case rules
        case program
    }

    var name: String
    var version: String
    var kind: Kind
    var description: String
    /// Executable path relative to the extension directory (`program` only).
    var exec: String?
    /// Capability strings requested by a `program` extension. Enforced at
    /// the action bridge in SubprocessPluginHost.
    var capabilities: [String] = []
    /// Memory cap for `program` extensions (MB). Default applied by host.
    var memoryLimitMB: Int?
    /// CPU-seconds cap for `program` extensions. Default applied by host.
    var cpuLimitSeconds: Int?
    /// Free-form pattern strings passed to `program` extensions via the
    /// configure message.
    var patterns: [String] = []
    var rules: [ExtensionRule] = []

    /// The directory this manifest was loaded from (set by the loader).
    var directory: URL?
}

/// One if-this-then-that rule in a `rules` extension.
struct ExtensionRule {
    /// Which pane(s) a trigger applies to.
    enum Scope {
        case all
        case watermark(String)
        case pane(Int)

        static func parse(_ raw: String) -> Scope {
            if raw.isEmpty || raw == "all" { return .all }
            if raw.hasPrefix("watermark:") {
                return .watermark(String(raw.dropFirst("watermark:".count)))
            }
            if raw.hasPrefix("pane:"), let id = Int(raw.dropFirst("pane:".count)) {
                return .pane(id)
            }
            return .all
        }
    }

    enum Trigger {
        case outputRegex(pattern: String, scope: Scope)
        case commandFinished(scope: Scope)
        case paneClosed
        case attention
        /// Fires when context usage crosses the threshold (edge-triggered).
        case contextUsage(thresholdPct: Int)
        case interval(seconds: Double)
    }

    /// Which pane an action targets: the pane that fired the trigger, or a
    /// fixed pane id.
    enum PaneRef {
        case trigger
        case id(Int)

        static func parse(_ raw: String?) -> PaneRef {
            guard let raw, !raw.isEmpty, raw != "trigger" else { return .trigger }
            return Int(raw).map { .id($0) } ?? .trigger
        }

        func resolve(triggerPane: Int?) -> Int? {
            switch self {
            case .trigger: return triggerPane
            case .id(let id): return id
            }
        }
    }

    enum Action {
        case sendCommand(pane: PaneRef, command: String)
        case sendToAll(command: String)
        case setWatermark(pane: PaneRef, watermark: String)
        case setTitle(pane: PaneRef, title: String)
        case clearWatermark(pane: PaneRef)
        case focusPane(pane: PaneRef)
        case spawnPane
        case closePane(pane: PaneRef)
        case message(text: String)
        case notify(title: String, body: String)
        case runShell(command: String)
        case openURL(url: String)
    }

    var name: String?
    var cooldownSeconds: Double = 5
    var trigger: Trigger
    var actions: [Action]
}

// MARK: - Parsing

extension ExtensionManifest {
    enum ParseError: Error, CustomStringConvertible {
        case missingField(String)
        case invalidValue(key: String, value: String)
        case ruleWithoutTrigger(index: Int)
        case ruleWithoutActions(index: Int)

        var description: String {
            switch self {
            case .missingField(let f): return "missing required field: \(f)"
            case .invalidValue(let k, let v): return "invalid value for \(k): \(v)"
            case .ruleWithoutTrigger(let i): return "rule #\(i + 1) has no [rules.trigger]"
            case .ruleWithoutActions(let i): return "rule #\(i + 1) has no [[rules.actions]]"
            }
        }
    }

    /// Load and parse `extension.toml` from an extension directory.
    static func load(fromDirectory dir: URL) throws -> ExtensionManifest {
        let path = dir.appendingPathComponent("extension.toml")
        let content = try String(contentsOf: path, encoding: .utf8)
        var manifest = try parse(content)
        manifest.directory = dir
        return manifest
    }

    /// Parse manifest TOML. Line-oriented section state machine in the house
    /// style (there is deliberately no TOML library in this codebase — see
    /// QuickActionsPlugin.parseActionsToml and Trm.parsePaneExtras).
    static func parse(_ content: String) throws -> ExtensionManifest {
        enum Section {
            case top
            case rule
            case trigger
            case action
        }

        // Accumulators for the rule being built.
        struct PendingAction {
            var kv: [String: String] = [:]
        }
        struct PendingRule {
            var name: String?
            var cooldown: Double = 5
            var triggerKV: [String: String]? = nil
            var actions: [PendingAction] = []
        }

        var top: [String: String] = [:]
        var topLists: [String: [String]] = [:]
        var pendingRules: [PendingRule] = []
        var section: Section = .top

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            switch line {
            case "[[rules]]":
                pendingRules.append(PendingRule())
                section = .rule
                continue
            case "[rules.trigger]":
                if !pendingRules.isEmpty {
                    pendingRules[pendingRules.count - 1].triggerKV = [:]
                }
                section = .trigger
                continue
            case "[[rules.actions]]":
                if !pendingRules.isEmpty {
                    pendingRules[pendingRules.count - 1].actions.append(PendingAction())
                }
                section = .action
                continue
            default:
                // Unknown sections put us back in a state where keys are
                // ignored until a known section starts.
                if line.hasPrefix("[") { section = .top; continue }
            }

            guard let (key, value) = parseKeyValue(line) else { continue }

            switch section {
            case .top:
                if value.hasPrefix("[") {
                    topLists[key] = parseStringArray(value)
                } else {
                    top[key] = value
                }
            case .rule:
                guard !pendingRules.isEmpty else { continue }
                switch key {
                case "name": pendingRules[pendingRules.count - 1].name = value
                case "cooldown_seconds":
                    pendingRules[pendingRules.count - 1].cooldown = Double(value) ?? 5
                default: break
                }
            case .trigger:
                guard !pendingRules.isEmpty else { continue }
                pendingRules[pendingRules.count - 1].triggerKV?[key] = value
            case .action:
                guard !pendingRules.isEmpty,
                      !pendingRules[pendingRules.count - 1].actions.isEmpty else { continue }
                let ri = pendingRules.count - 1
                let ai = pendingRules[ri].actions.count - 1
                pendingRules[ri].actions[ai].kv[key] = value
            }
        }

        guard let name = top["name"], !name.isEmpty else {
            throw ParseError.missingField("name")
        }
        guard let kindRaw = top["kind"], let kind = Kind(rawValue: kindRaw) else {
            throw ParseError.invalidValue(key: "kind", value: top["kind"] ?? "(missing)")
        }
        if kind == .program, top["exec"]?.isEmpty != false {
            throw ParseError.missingField("exec")
        }

        var rules: [ExtensionRule] = []
        for (i, pending) in pendingRules.enumerated() {
            guard let triggerKV = pending.triggerKV else {
                throw ParseError.ruleWithoutTrigger(index: i)
            }
            let trigger = try parseTrigger(triggerKV)
            guard !pending.actions.isEmpty else {
                throw ParseError.ruleWithoutActions(index: i)
            }
            let actions = pending.actions.compactMap { parseAction($0.kv) }
            guard !actions.isEmpty else {
                throw ParseError.ruleWithoutActions(index: i)
            }
            rules.append(ExtensionRule(
                name: pending.name,
                cooldownSeconds: pending.cooldown,
                trigger: trigger,
                actions: actions
            ))
        }

        if kind == .rules && rules.isEmpty {
            throw ParseError.missingField("[[rules]]")
        }

        return ExtensionManifest(
            name: name,
            version: top["version"] ?? "1",
            kind: kind,
            description: top["description"] ?? "",
            exec: top["exec"],
            capabilities: topLists["capabilities"] ?? [],
            memoryLimitMB: top["memory_limit_mb"].flatMap(Int.init),
            cpuLimitSeconds: top["cpu_limit_seconds"].flatMap(Int.init),
            patterns: topLists["patterns"] ?? [],
            rules: rules
        )
    }

    private static func parseTrigger(_ kv: [String: String]) throws -> ExtensionRule.Trigger {
        let scope = ExtensionRule.Scope.parse(kv["scope"] ?? "all")
        switch kv["type"] ?? "" {
        case "output_regex":
            guard let pattern = kv["pattern"], !pattern.isEmpty else {
                throw ParseError.missingField("trigger.pattern")
            }
            // Validate the regex at parse time so a bad extension fails to
            // load instead of failing silently at runtime.
            guard (try? NSRegularExpression(pattern: pattern)) != nil else {
                throw ParseError.invalidValue(key: "trigger.pattern", value: pattern)
            }
            return .outputRegex(pattern: pattern, scope: scope)
        case "command_finished":
            return .commandFinished(scope: scope)
        case "pane_closed":
            return .paneClosed
        case "attention":
            return .attention
        case "context_usage":
            guard let pct = kv["threshold_pct"].flatMap(Int.init), (1...100).contains(pct) else {
                throw ParseError.invalidValue(
                    key: "trigger.threshold_pct", value: kv["threshold_pct"] ?? "(missing)")
            }
            return .contextUsage(thresholdPct: pct)
        case "interval":
            guard let secs = kv["seconds"].flatMap(Double.init), secs >= 1 else {
                throw ParseError.invalidValue(
                    key: "trigger.seconds", value: kv["seconds"] ?? "(missing)")
            }
            return .interval(seconds: secs)
        default:
            throw ParseError.invalidValue(key: "trigger.type", value: kv["type"] ?? "(missing)")
        }
    }

    private static func parseAction(_ kv: [String: String]) -> ExtensionRule.Action? {
        let pane = ExtensionRule.PaneRef.parse(kv["pane"])
        switch kv["type"] ?? "" {
        case "send_command":
            guard let cmd = kv["command"], !cmd.isEmpty else { return nil }
            return .sendCommand(pane: pane, command: cmd)
        case "send_to_all":
            guard let cmd = kv["command"], !cmd.isEmpty else { return nil }
            return .sendToAll(command: cmd)
        case "set_watermark":
            guard let wm = kv["watermark"] else { return nil }
            return .setWatermark(pane: pane, watermark: wm)
        case "set_title":
            guard let title = kv["title"] else { return nil }
            return .setTitle(pane: pane, title: title)
        case "clear_watermark":
            return .clearWatermark(pane: pane)
        case "focus_pane":
            return .focusPane(pane: pane)
        case "spawn_pane":
            return .spawnPane
        case "close_pane":
            return .closePane(pane: pane)
        case "message":
            guard let text = kv["text"], !text.isEmpty else { return nil }
            return .message(text: text)
        case "notify":
            let title = kv["title"] ?? "trm"
            return .notify(title: title, body: kv["body"] ?? "")
        case "run_shell":
            guard let cmd = kv["command"], !cmd.isEmpty else { return nil }
            return .runShell(command: cmd)
        case "open_url":
            guard let url = kv["url"], !url.isEmpty else { return nil }
            return .openURL(url: url)
        default:
            return nil
        }
    }

    /// Parse `key = value`, unquoting basic strings.
    private static func parseKeyValue(_ line: String) -> (String, String)? {
        guard let eqIdx = line.firstIndex(of: "=") else { return nil }
        let key = line[line.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
        var value = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
        // Strip trailing comments on unquoted values.
        if !value.hasPrefix("\"") , let hash = value.firstIndex(of: "#") {
            value = value[value.startIndex..<hash].trimmingCharacters(in: .whitespaces)
        }
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    /// Parse a `["a", "b"]` TOML string array.
    private static func parseStringArray(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("["), s.hasSuffix("]") else { return [] }
        s = String(s.dropFirst().dropLast())
        return s.components(separatedBy: ",").compactMap { item in
            var v = item.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return nil }
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            return v.isEmpty ? nil : v
        }
    }
}
