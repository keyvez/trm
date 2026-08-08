import Testing
import Foundation
@testable import trm

@MainActor
struct ExtensionManifestTests {

    // MARK: - Rules manifests

    private let rulesToml = """
    name = "build-fail-notify"
    version = "1"
    kind = "rules"
    description = "Notify when a build fails"

    [[rules]]
    name = "notify-on-fail"
    cooldown_seconds = 10

    [rules.trigger]
    type = "output_regex"
    pattern = "BUILD FAILED"
    scope = "all"

    [[rules.actions]]
    type = "notify"
    title = "Build failed"
    body = "A pane printed BUILD FAILED"

    [[rules.actions]]
    type = "set_watermark"
    pane = "trigger"
    watermark = "FAILED"
    """

    @Test func parsesRulesManifest() throws {
        let m = try ExtensionManifest.parse(rulesToml)
        #expect(m.name == "build-fail-notify")
        #expect(m.kind == .rules)
        #expect(m.rules.count == 1)
        let rule = m.rules[0]
        #expect(rule.name == "notify-on-fail")
        #expect(rule.cooldownSeconds == 10)
        guard case .outputRegex(let pattern, let scope) = rule.trigger else {
            Issue.record("wrong trigger type")
            return
        }
        #expect(pattern == "BUILD FAILED")
        if case .all = scope {} else { Issue.record("wrong scope") }
        #expect(rule.actions.count == 2)
        guard case .notify(let title, let body) = rule.actions[0] else {
            Issue.record("wrong action 0")
            return
        }
        #expect(title == "Build failed")
        #expect(body == "A pane printed BUILD FAILED")
        guard case .setWatermark(let pane, let wm) = rule.actions[1] else {
            Issue.record("wrong action 1")
            return
        }
        if case .trigger = pane {} else { Issue.record("wrong pane ref") }
        #expect(wm == "FAILED")
    }

    @Test func parsesScopeVariants() {
        #expect({ if case .all = ExtensionRule.Scope.parse("all") { return true } else { return false } }())
        #expect({
            if case .watermark(let w) = ExtensionRule.Scope.parse("watermark:prod") {
                return w == "prod"
            } else { return false }
        }())
        #expect({
            if case .pane(let id) = ExtensionRule.Scope.parse("pane:3") {
                return id == 3
            } else { return false }
        }())
    }

    @Test func rejectsInvalidRegex() {
        let bad = rulesToml.replacingOccurrences(of: "BUILD FAILED", with: "([unclosed")
        #expect(throws: (any Error).self) {
            try ExtensionManifest.parse(bad)
        }
    }

    @Test func rejectsMissingName() {
        #expect(throws: (any Error).self) {
            try ExtensionManifest.parse("kind = \"rules\"")
        }
    }

    @Test func rejectsRuleWithoutActions() {
        let toml = """
        name = "x"
        kind = "rules"

        [[rules]]
        [rules.trigger]
        type = "attention"
        """
        #expect(throws: (any Error).self) {
            try ExtensionManifest.parse(toml)
        }
    }

    @Test func parsesIntervalAndContextTriggers() throws {
        let toml = """
        name = "t"
        kind = "rules"

        [[rules]]
        [rules.trigger]
        type = "interval"
        seconds = 300
        [[rules.actions]]
        type = "run_shell"
        command = "echo hi"

        [[rules]]
        [rules.trigger]
        type = "context_usage"
        threshold_pct = 80
        [[rules.actions]]
        type = "notify"
        title = "Context high"
        """
        let m = try ExtensionManifest.parse(toml)
        #expect(m.rules.count == 2)
        guard case .interval(let secs) = m.rules[0].trigger else {
            Issue.record("wrong trigger 0")
            return
        }
        #expect(secs == 300)
        guard case .contextUsage(let pct) = m.rules[1].trigger else {
            Issue.record("wrong trigger 1")
            return
        }
        #expect(pct == 80)
    }

    // MARK: - Program manifests

    @Test func parsesProgramManifest() throws {
        let toml = """
        name = "agent-quota"
        kind = "program"
        description = "Quota pill"
        exec = "agent-quota.py"
        capabilities = ["notifications", "send_input"]
        memory_limit_mb = 64
        """
        let m = try ExtensionManifest.parse(toml)
        #expect(m.kind == .program)
        #expect(m.exec == "agent-quota.py")
        #expect(m.capabilities == ["notifications", "send_input"])
        #expect(m.memoryLimitMB == 64)
    }

    @Test func programRequiresExec() {
        #expect(throws: (any Error).self) {
            try ExtensionManifest.parse("name = \"x\"\nkind = \"program\"")
        }
    }

    @Test func capabilityParsingRejectsUnknown() {
        #expect(PluginCapability.parse("send_input") == .sendInput)
        #expect(PluginCapability.parse("pane_control") == .paneControl)
        #expect(PluginCapability.parse("definitely_not_a_capability") == nil)
    }

    // MARK: - Fence extraction (builder)

    @Test func extractsFencedBlocks() {
        let response = """
        Here you go:
        ```toml
        name = "x"
        kind = "rules"
        ```
        And the program:
        ```python
        print("hi")
        ```
        """
        let toml = ExtensionBuilder.extractBlock(response, hint: "toml")
        #expect(toml?.contains("name = \"x\"") == true)
        let py = ExtensionBuilder.extractBlock(response, hint: "python")
        #expect(py == "print(\"hi\")")
    }
}
