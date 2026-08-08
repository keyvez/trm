import Foundation
import AppKit
import os

/// Builds trm extensions from natural-language descriptions using the
/// configured LLM provider.
///
/// Flow: describe → generate (manifest ± program) → validate (parse, with
/// up to 2 error-feedback retries) → dry-run (programs must print `ready`)
/// → user confirmation showing the manifest + capability list → install →
/// hot-load via ExtensionsManager.
///
/// Entry points: the command palette ("Create Extension…") and
/// `trm ext create "<desc>"`, which drops a request file into
/// `extensions/.requests/` that the app watches.
@MainActor
final class ExtensionBuilder {

    static let shared = ExtensionBuilder()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.trm",
        category: "ExtensionBuilder"
    )

    struct BuildResult {
        var manifest: ExtensionManifest
        var manifestContent: String
        /// Program source file (name, content) for `kind = "program"`.
        var programFile: (name: String, content: String)?
    }

    enum BuildError: Error, CustomStringConvertible {
        case noManifestInResponse
        case validationFailed(String)
        case dryRunFailed(String)

        var description: String {
            switch self {
            case .noManifestInResponse:
                return "the model response contained no extension.toml block"
            case .validationFailed(let e): return "manifest validation failed: \(e)"
            case .dryRunFailed(let e): return "dry run failed: \(e)"
            }
        }
    }

    private init() {}

    // MARK: - Generation

    /// Generate and validate an extension from a description. Feeds parse
    /// errors back to the model for up to 2 retries.
    func build(description: String) async throws -> BuildResult {
        var feedback: String? = nil
        var lastError: Error = BuildError.noManifestInResponse

        for _ in 0..<3 {
            var user = "Create a trm extension for this request:\n\n\(description)"
            if let feedback {
                user += "\n\nYour previous attempt failed validation with this error — fix it:\n\(feedback)"
            }

            let response = try await Trm.shared.llmClient.complete(
                system: Self.systemPrompt, user: user)

            guard let manifestContent = Self.extractBlock(response, hint: "toml") else {
                feedback = "no ```toml fenced block found in the response"
                lastError = BuildError.noManifestInResponse
                continue
            }

            do {
                let manifest = try ExtensionManifest.parse(manifestContent)
                var programFile: (String, String)? = nil
                if manifest.kind == .program {
                    guard let exec = manifest.exec,
                          let program = Self.extractBlock(response, hint: "python")
                            ?? Self.extractBlock(response, hint: "program") else {
                        feedback = "kind = \"program\" but no program source block was provided"
                        lastError = BuildError.validationFailed("missing program source")
                        continue
                    }
                    programFile = (exec, program)
                }
                return BuildResult(
                    manifest: manifest,
                    manifestContent: manifestContent,
                    programFile: programFile
                )
            } catch {
                feedback = "\(error)"
                lastError = BuildError.validationFailed("\(error)")
            }
        }
        throw lastError
    }

    // MARK: - Dry Run

    /// For program extensions: launch the program, send configure/start, and
    /// require a `ready` line within 5 seconds. Rules extensions are fully
    /// validated at parse time and need no dry run.
    nonisolated private static func dryRunProgram(executable: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec \"$0\"", executable.path]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let hello = "{\"type\":\"configure\",\"config\":{}}\n{\"type\":\"start\"}\n"
        try? stdin.fileHandleForWriting.write(contentsOf: Data(hello.utf8))

        let deadline = Date().addingTimeInterval(5)
        var buffer = Data()
        let fh = stdout.fileHandleForReading
        while Date() < deadline {
            // availableData blocks; bound it by checking in small reads.
            let chunk = fh.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if let text = String(data: buffer, encoding: .utf8),
               text.contains("\"ready\"") {
                return
            }
        }
        throw BuildError.dryRunFailed("program did not print a ready message within 5s")
    }

    // MARK: - Confirmation + Install

    /// Show the confirmation alert (manifest + capabilities) and install on
    /// approval. Returns true if installed.
    @discardableResult
    func confirmAndInstall(_ result: BuildResult, window: NSWindow? = nil) async -> Bool {
        let manifest = result.manifest
        let caps = manifest.capabilities.isEmpty
            ? "(none — display only)"
            : manifest.capabilities.joined(separator: ", ")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Install extension \"\(manifest.name)\"?"
        let kindDesc = manifest.kind == .rules
            ? "Declarative rules (no code runs)"
            : "Program: \(manifest.exec ?? "?") — supervised, memory-capped"
        alert.informativeText = """
        \(manifest.description)

        Kind: \(kindDesc)
        Capabilities: \(caps)

        \(String(result.manifestContent.prefix(1200)))
        """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        do {
            var files: [String: Data] = [:]
            if let (name, content) = result.programFile {
                files[name] = Data(content.utf8)
            }
            let dir = try ExtensionsManager.shared.install(
                name: manifest.name,
                manifestContent: result.manifestContent,
                files: files
            )

            // Dry-run programs post-install (needs the file on disk with +x);
            // uninstall on failure.
            if let (name, _) = result.programFile {
                let exe = dir.appendingPathComponent(name)
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try Self.dryRunProgram(executable: exe)
                    }.value
                } catch {
                    ExtensionsManager.shared.uninstall(name: ExtensionsManager.sanitizeName(manifest.name))
                    showError("Extension failed its dry run and was not installed:\n\(error)")
                    return false
                }
            }

            Trm.shared.showNotification(
                title: "Extension installed",
                body: "\(manifest.name) is active.")
            return true
        } catch {
            showError("Failed to install extension:\n\(error)")
            return false
        }
    }

    /// Full interactive flow used by the palette and the CLI request path.
    func createInteractively(description: String) {
        Task { @MainActor in
            do {
                let result = try await self.build(description: description)
                await self.confirmAndInstall(result)
            } catch {
                self.showError("Could not create the extension:\n\(error)")
            }
        }
    }

    private func showError(_ message: String) {
        Self.logger.error("\(message)")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Extension Builder"
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - CLI Request Channel

    /// Directory the CLI drops `trm ext create` requests into.
    static var requestsDirectory: URL {
        let dir = ExtensionsManager.extensionsDirectory
            .appendingPathComponent(".requests", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var requestWatcher: DispatchSourceFileSystemObject?

    /// Watch for CLI-dropped requests; each file's content is a description.
    func startWatchingRequests() {
        guard requestWatcher == nil else { return }
        let dir = Self.requestsDirectory
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in
            self?.drainRequests()
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        requestWatcher = source
        drainRequests()
    }

    private func drainRequests() {
        let fm = FileManager.default
        let dir = Self.requestsDirectory
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for file in files where file.hasSuffix(".txt") {
            let url = dir.appendingPathComponent(file)
            guard let description = try? String(contentsOf: url, encoding: .utf8),
                  !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                try? fm.removeItem(at: url)
                continue
            }
            try? fm.removeItem(at: url)
            createInteractively(
                description: description.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - System Prompt

    static let systemPrompt = """
    You create extensions for trm, a multi-pane terminal emulator. The user \
    describes what they want; you emit an extension as fenced code blocks.

    ALWAYS prefer `kind = "rules"` (declarative, no code) when the request \
    can be expressed as triggers and actions. Only use `kind = "program"` \
    when rules cannot express it (stateful logic, external data, custom \
    formatting).

    Respond with a ```toml block containing extension.toml. For programs, \
    also emit a ```python block with a single-file executable (it will be \
    saved as the `exec` file, chmod +x; start it with a `#!/usr/bin/env \
    python3` shebang).

    ## extension.toml schema

    name = "kebab-case-name"           # required
    version = "1"
    kind = "rules"                     # "rules" | "program"
    description = "One sentence."
    # program-only:
    # exec = "main.py"
    # capabilities = ["send_input", "pane_control", "pane_decorate", "notifications"]
    # memory_limit_mb = 256
    # cpu_limit_seconds = 300

    ## Rules (kind = "rules")

    [[rules]]
    cooldown_seconds = 5               # min seconds between fires

    [rules.trigger]                    # exactly one per rule
    type = "output_regex"              # output_regex | command_finished | pane_closed | attention | context_usage | interval
    pattern = "ERROR|FAILED"           # output_regex only (applies to visible pane text)
    scope = "all"                      # all | watermark:<name> | pane:<id>
    # threshold_pct = 80               # context_usage only (fires crossing the threshold)
    # seconds = 300                    # interval only

    [[rules.actions]]                  # one or more per rule
    type = "notify"                    # see action list
    title = "Title"                    # notify
    body = "Body"                      # notify
    # pane = "trigger"                 # target pane: "trigger" (the pane that fired) or an id
    # command = "..."                  # send_command / send_to_all / run_shell
    # watermark = "..."                # set_watermark
    # text = "..."                     # message / set_title(title=)
    # url = "https://..."              # open_url

    Actions: send_command, send_to_all, set_watermark, set_title, \
    clear_watermark, focus_pane, spawn_pane, close_pane, message, notify, \
    run_shell, open_url.

    ## Program protocol (kind = "program")

    The program reads newline-delimited JSON on stdin and writes it on \
    stdout. It MUST print {"type": "ready"} immediately at startup, before \
    and independent of any input. Incoming events:
    {"type":"configure","config":{...}}, {"type":"start"}, \
    {"type":"terminal_output","pane":N,"text":"...","hash":"..."}, \
    {"type":"pane_closed","pane":N}, {"type":"command_finished","pane":N}, \
    {"type":"context_usage","used_tokens":N,"total_tokens":N,"percentage":N,"session_id":"..."}, \
    {"type":"stop"}.

    Outgoing messages:
    - Overlay state: {"type":"state","overlay":"metric_pill","alignment":"toptrailing","panes":{"0":["label","value","green"]}}
      Templates: metric_pill (["label","value","green|yellow|red|gray"]), \
    attention_icon (true), process_pill (true), server_url_banner (["url",...]).
    - Actions: {"type":"action","actions":[{"type":"notify","title":"t","body":"b"}]}
      (Action types as above; each needs its capability granted in the manifest: \
    send_input for send_command/send_to_all, pane_control for spawn/close/focus/open_url, \
    pane_decorate for watermarks/titles, notifications for notify.)

    Programs must flush stdout after every line, use only the Python \
    standard library, never write files outside their own directory, and \
    keep memory modest (they are killed over their cap).

    Output ONLY the fenced blocks, no commentary.
    """

    // MARK: - Fence Extraction

    /// Extract the first fenced block whose info string contains `hint`,
    /// falling back to any fenced block for hint "toml" when the response
    /// has exactly one block.
    static func extractBlock(_ response: String, hint: String) -> String? {
        let pattern = "```([a-zA-Z0-9._-]*)[^\\n]*\\n(.*?)```"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(response.startIndex..., in: response)
        let matches = regex.matches(in: response, range: range)

        for match in matches {
            guard let infoRange = Range(match.range(at: 1), in: response),
                  let bodyRange = Range(match.range(at: 2), in: response) else { continue }
            let info = response[infoRange].lowercased()
            if info.contains(hint.lowercased()) {
                return String(response[bodyRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Fallback: a single unlabeled block is assumed to be the manifest.
        if hint == "toml", matches.count == 1, let match = matches.first,
           let bodyRange = Range(match.range(at: 2), in: response) {
            return String(response[bodyRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
