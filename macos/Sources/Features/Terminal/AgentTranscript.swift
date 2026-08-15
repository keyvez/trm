import Foundation

/// Which coding agent produced a transcript. Each kind knows where its
/// sessions live and how to parse them; everything downstream (the overview
/// model and view) is agent-agnostic.
enum AgentKind: String, Equatable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// Executable basename of the agent's CLI process.
    var processName: String { rawValue }
}

/// A parsed view of a coding agent's most recent turn.
///
/// Currently reads Claude Code's JSONL transcripts
/// (`~/.claude/projects/<encoded-cwd>/*.jsonl`). The parsing is deliberately
/// isolated behind `AgentTranscriptReader` so a second agent (Codex, Gemini,
/// …) can be added later by implementing another reader that produces the same
/// `AgentTranscript` value — nothing in the view layer knows about Claude.
struct AgentTranscript: Equatable {
    /// Rich content blocks of the last assistant message, in order.
    var blocks: [Block] = []

    /// Tool calls from the current (or most recent) turn, oldest first.
    var activity: [ToolActivity] = []

    /// The last thing the human asked, for context at the top of the view.
    var lastUserPrompt: String? = nil

    /// True when the agent appears to still be working: the newest transcript
    /// entry is a tool call that never received a result.
    var isWorking: Bool = false

    /// When the underlying transcript was last modified.
    var updatedAt: Date? = nil

    /// Percentage (0–100) of the agent's context window currently used, when
    /// the transcript reports token usage.
    var contextUsedPercent: Int? = nil

    var isEmpty: Bool {
        blocks.isEmpty && activity.isEmpty && lastUserPrompt == nil
    }

    /// One renderable piece of an assistant message.
    ///
    /// Prose and code are separated so the view can lay code out in its own
    /// block (monospaced, horizontally scrollable) and apply bionic-reading
    /// emphasis to prose only — bolding fragments of code would be noise.
    enum Block: Equatable, Identifiable {
        case paragraph(String)
        case code(language: String?, text: String)

        var id: String {
            switch self {
            case .paragraph(let t): return "p:\(t.hashValue)"
            case .code(let lang, let t): return "c:\(lang ?? "")\(t.hashValue)"
            }
        }
    }

    /// A single tool invocation surfaced in the activity strip.
    struct ToolActivity: Equatable, Identifiable {
        let id: String
        /// Tool name as the agent reported it, e.g. "Bash", "Read", "Edit".
        let name: String
        /// A short human-readable subject: a file path, a command, a query.
        let detail: String?
        /// False while the call has no matching tool_result yet.
        let finished: Bool
        /// True when the tool returned an error (`is_error` on the result).
        /// Errors are a needle-in-a-haystack in a long session — a few among
        /// hundreds of calls — so they get their own view.
        var isError: Bool = false
        /// First line of the error text, when this call failed.
        var errorText: String? = nil
    }
}

/// Which sections an agent overview shows.
///
/// The sections are independent and additive, not alternatives: watching the
/// commands an agent is running while also reading its reply is the normal
/// case, so this is a set rather than a single choice. An empty set falls back
/// to showing everything — a pane that renders nothing would just look broken.
struct AgentOverviewSections: OptionSet, Hashable {
    let rawValue: Int

    /// The human's last prompt.
    static let prompt = AgentOverviewSections(rawValue: 1 << 0)
    /// Tool calls — the commands the agent is running.
    static let activity = AgentOverviewSections(rawValue: 1 << 1)
    /// The agent's prose reply.
    static let reply = AgentOverviewSections(rawValue: 1 << 2)
    /// Tool calls that failed.
    static let errors = AgentOverviewSections(rawValue: 1 << 3)

    static let all: AgentOverviewSections = [.prompt, .activity, .reply, .errors]
    /// What a new overview shows: everything except the errors list, which is
    /// noise until something actually fails.
    static let `default`: AgentOverviewSections = [.prompt, .activity, .reply]

    /// The individual sections, in display order, for building menus.
    static let allCases: [AgentOverviewSections] = [.prompt, .activity, .reply, .errors]

    var menuTitle: String {
        switch self {
        case .prompt: return "What I Asked"
        case .activity: return "Recent Activity"
        case .reply: return "What Claude Said"
        case .errors: return "Errors Only"
        default: return "Sections"
        }
    }

    var menuSubtitle: String {
        switch self {
        case .prompt: return "Your last prompt"
        case .activity: return "Commands the agent is running"
        case .reply: return "The agent's reply"
        case .errors: return "Tool calls that failed"
        default: return ""
        }
    }

    var symbolName: String {
        switch self {
        case .prompt: return "person.bubble"
        case .activity: return "terminal"
        case .reply: return "sparkle"
        case .errors: return "exclamationmark.triangle"
        default: return "list.bullet.rectangle"
        }
    }

    /// Short label for the header bar, naming the selection at a glance.
    var barLabel: String {
        if self == Self.all { return "Everything" }
        if isEmpty { return "Everything" }
        let names = Self.allCases.filter { contains($0) }
        if names.count == 1 { return names[0].menuTitle }
        return "\(names.count) sections"
    }

    /// Serialised for the session TOML as a stable comma-separated list, so a
    /// checkpoint stays readable and survives reordering of the flags.
    var tomlValue: String {
        let tokens: [String] = Self.allCases.compactMap { section in
            guard contains(section) else { return nil }
            switch section {
            case .prompt: return "prompt"
            case .activity: return "activity"
            case .reply: return "reply"
            case .errors: return "errors"
            default: return nil
            }
        }
        return tokens.joined(separator: ",")
    }

    init(rawValue: Int) { self.rawValue = rawValue }

    /// Parse the TOML form. Unknown tokens are ignored; an empty or
    /// unparseable value means "everything", matching the render fallback.
    init(tomlValue: String) {
        var result: AgentOverviewSections = []
        for token in tomlValue.split(separator: ",") {
            switch token.trimmingCharacters(in: .whitespaces) {
            case "prompt": result.insert(.prompt)
            case "activity": result.insert(.activity)
            case "reply": result.insert(.reply)
            case "errors": result.insert(.errors)
            // Older checkpoints wrote a single mode name rather than a token
            // list. "fullHistory" meant every section; without this it fell
            // through to `default` and the saved mode was silently replaced
            // by `.default` on every restore.
            case "fullHistory": result.formUnion(.all)
            default: break
            }
        }
        self = result.isEmpty ? Self.default : result
    }
}

// MARK: - Reader

enum AgentTranscriptReader {

    /// Maximum human-prompt text retained by the overview model.
    ///
    /// Transcript `user` records are not inherently bounded. In particular,
    /// Claude writes injected skill documents as user messages; one observed
    /// record was 923 KB / 16K lines. Letting a payload of that size reach a
    /// SwiftUI `Text` inside each restored overview can trap CoreText in a
    /// layout/re-measure loop and grow the process by gigabytes. The overview
    /// is a glanceable reading surface, so keep a generous prefix while the
    /// complete prompt remains available in the source transcript.
    static let maxPromptCharacters = 16 * 1024

    static func boundedPrompt(_ text: String) -> String {
        guard let end = text.index(
            text.startIndex,
            offsetBy: maxPromptCharacters,
            limitedBy: text.endIndex
        ), end != text.endIndex else {
            return text
        }
        return String(text[..<end]) + "\n\n… [prompt truncated in overview]"
    }

    /// Collapse what Claude Code's CLI also collapses: large pasted text.
    ///
    /// The CLI shows `[Pasted text #1 +257 lines]` chips, but that is
    /// presentation only — the transcript stores the entire paste inline in
    /// the user message. The overview re-derives the collapsed form: a
    /// prompt beyond a few lines keeps its head and reports the remainder
    /// as a paste badge; a single enormous line (minified JSON, base64)
    /// collapses by characters. The full text stays in the transcript.
    static let pasteCollapseLineThreshold = 12
    static let pasteCollapseKeptLines = 6
    static let pasteCollapseCharThreshold = 1_500
    static let pasteCollapseKeptChars = 1_000

    static func collapsedPrompt(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        if lines.count > pasteCollapseLineThreshold {
            var head = lines.prefix(pasteCollapseKeptLines).joined(separator: "\n")
            if head.count > pasteCollapseKeptChars {
                head = String(head.prefix(pasteCollapseKeptChars)) + "…"
            }
            return head + "\n[Pasted text +\(lines.count - pasteCollapseKeptLines) lines]"
        }
        if text.count > pasteCollapseCharThreshold {
            let kept = String(text.prefix(pasteCollapseKeptChars))
            return kept + "… [Pasted text +\(text.count - pasteCollapseKeptChars) chars]"
        }
        return text
    }

    /// First non-empty line of a `tool_result` block's content.
    ///
    /// The content is either a plain string or an array of typed parts, so
    /// both shapes are handled. Truncated because this renders in a narrow
    /// pane — the first line carries the actual error nearly every time.
    static func firstLine(ofToolResult block: [String: Any]) -> String? {
        var text: String? = nil
        if let s = block["content"] as? String {
            text = s
        } else if let parts = block["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.first
        }
        guard let raw = text else { return nil }
        let line = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
        guard let line, !line.isEmpty else { return nil }
        return line.count > 300 ? String(line.prefix(300)) + "…" : line
    }

    /// Bytes read from the end of the transcript. Claude transcripts grow to
    /// many megabytes over a long session; the last turn is always at the tail,
    /// so reading the whole file would be wasted I/O on every poll.
    ///
    /// Sized in megabytes, not kilobytes, because a single transcript line can
    /// be enormous: a screenshot tool result embeds the image as base64, and
    /// one 2 MB PNG becomes a ~2.7 MB line. A small tail window can land
    /// entirely inside one such line and parse to nothing — observed live as
    /// the overview going blank the moment screenshots entered the session.
    ///
    /// The window is re-read and re-parsed on every 1.5 s poll of every
    /// overview pane, so its size is a recurring per-pane cost, not a one-off.
    /// Measured against a real 69 MB transcript, a 12 MB window cost ~156 ms to
    /// read and JSON-parse: six overview panes therefore spent ~0.94 s of every
    /// 1.5 s tick on this alone — most of a core, permanently, plus the
    /// transient Foundation objects to match. 3 MB still clears a ~2.7 MB
    /// base64 screenshot line while cutting that cost by four.
    private static let tailBytes: UInt64 = 3 * 1024 * 1024

    /// Bytes scanned when the tail window contained no human prompt.
    ///
    /// A single tool-heavy turn easily exceeds `tailBytes` — one turn in a real
    /// session pushed every user message out of a 512 KB window — leaving the
    /// "You asked" line blank. When that happens we take one wider pass to
    /// recover the prompt rather than showing nothing.
    private static let promptSearchBytes: UInt64 = 24 * 1024 * 1024

    /// Maximum tool calls kept in the activity strip.
    private static let maxActivity = 12

    /// Map a working directory to its Claude project transcript directory.
    /// e.g. `/Users/foo/dev/trm` → `~/.claude/projects/-Users-foo-dev-trm`
    static func projectDir(forCwd cwd: String) -> URL {
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(encoded)
    }

    /// The most recently modified `.jsonl` in a directory.
    static func latestJSONL(in dir: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        return items
            .filter { $0.pathExtension == "jsonl" }
            .max(by: {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            })
    }

    /// Read and parse the transcript for a working directory.
    /// Returns nil when there is no transcript for this directory at all.
    static func read(cwd: String) -> AgentTranscript? {
        guard let url = latestJSONL(in: projectDir(forCwd: cwd)) else { return nil }
        return parse(url: url)
    }

    /// Read the last `bytes` of a file as complete lines (the first, possibly
    /// partial, line after a mid-file seek is dropped). Shared by both agent
    /// readers.
    static func readTailLines(url: URL, bytes: UInt64) -> [String]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? 0
        let offset = size > bytes ? size - bytes : 0
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd() else { return nil }

        // A mid-file seek can slice a multi-byte character or a line in half.
        // Decoding leniently and dropping the first partial line keeps the
        // parse robust rather than failing the whole read.
        var text = String(decoding: data, as: UTF8.self)
        if offset > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return text.components(separatedBy: "\n")
    }

    /// Parse the tail of a JSONL transcript file.
    ///
    /// Wrapped in an autorelease pool: this runs every poll on a background
    /// task and materialises megabytes of transient Foundation objects
    /// (strings, JSON graphs); without draining, peak footprint balloons.
    static func parse(url: URL) -> AgentTranscript? {
        autoreleasepool { parseInner(url: url) }
    }

    private static func parseInner(url: URL) -> AgentTranscript? {
        guard let lines = readTailLines(url: url, bytes: tailBytes) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 ?? 0

        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        var transcript = parse(lines: lines)

        // A long tool-heavy turn can push every human message out of the tail
        // window. Only then do the wider (more expensive) read, and take just
        // the prompt from it — the message and activity from the tail are
        // already correct and current.
        if transcript.lastUserPrompt == nil, size > tailBytes {
            transcript.lastUserPrompt = lastUserPrompt(in: url, upTo: promptSearchBytes)
        }

        transcript.updatedAt = mtime
        return transcript
    }

    /// Scan a wider window from the end of the file for the newest human prompt.
    private static func lastUserPrompt(in url: URL, upTo bytes: UInt64) -> String? {
        guard let lines = readTailLines(url: url, bytes: bytes) else { return nil }
        return parse(lines: lines).lastUserPrompt
    }

    /// Parse already-split JSONL lines. Exposed for testing.
    static func parse(lines: [String]) -> AgentTranscript {
        var result = AgentTranscript()

        // Tool calls keyed by tool_use id, in call order, so a later
        // tool_result can mark the matching call finished.
        var toolOrder: [String] = []
        var tools: [String: AgentTranscript.ToolActivity] = [:]

        // Blocks of the newest assistant message that carried any text. An
        // assistant entry that only makes tool calls must not blank out the
        // prose the agent wrote just before it.
        var latestBlocks: [AgentTranscript.Block] = []

        // Context tokens in the newest assistant entry that reported usage:
        // input + cache creation + cache read is what occupies the window.
        var latestContextTokens: Int? = nil

        for line in lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let type = obj["type"] as? String
            guard let message = obj["message"] as? [String: Any] else { continue }

            switch type {
            case "user":
                // Content is either a plain string (a typed prompt) or an array
                // that may hold tool_result blocks echoed back to the model.
                if let str = message["content"] as? String {
                    let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, !isSyntheticPrompt(trimmed) {
                        result.lastUserPrompt = boundedPrompt(collapsedPrompt(trimmed))
                        // A new human turn supersedes the previous turn's activity.
                        toolOrder.removeAll()
                        tools.removeAll()
                        latestBlocks.removeAll()
                    }
                } else if let arr = message["content"] as? [[String: Any]] {
                    var sawToolResult = false
                    var textPrompt: String? = nil
                    var imageCount = 0
                    for block in arr {
                        switch block["type"] as? String {
                        case "tool_result":
                            sawToolResult = true
                            if let id = block["tool_use_id"] as? String,
                               let existing = tools[id] {
                                // `is_error` marks a failed call. Capture the
                                // first line of the message so the errors view
                                // can say what went wrong without re-reading
                                // the transcript.
                                let failed = (block["is_error"] as? Bool) ?? false
                                tools[id] = .init(
                                    id: existing.id,
                                    name: existing.name,
                                    detail: existing.detail,
                                    finished: true,
                                    isError: failed,
                                    errorText: failed ? Self.firstLine(ofToolResult: block) : nil
                                )
                            }
                        case "text":
                            if let t = block["text"] as? String {
                                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty, !isSyntheticPrompt(trimmed) {
                                    textPrompt = trimmed
                                }
                            }
                        case "image":
                            // A human-attached image. The CLI shows it as an
                            // [Image #N] chip; the transcript embeds the raw
                            // base64, useless as prose.
                            imageCount += 1
                        default:
                            break
                        }
                    }
                    // Images inside a tool_result entry are results (e.g.
                    // screenshots coming back), not something the human
                    // attached to a prompt.
                    if sawToolResult { imageCount = 0 }
                    if textPrompt != nil || imageCount > 0 {
                        var parts: [String] = []
                        if let textPrompt { parts.append(collapsedPrompt(textPrompt)) }
                        parts.append(contentsOf: (0..<imageCount).map { "[Image #\($0 + 1)]" })
                        result.lastUserPrompt = boundedPrompt(parts.joined(separator: "\n"))
                    }
                    // A pure tool_result entry is the harness replying to the
                    // agent, not a new human turn, so it must not reset state.
                    if !sawToolResult, result.lastUserPrompt != nil {
                        toolOrder.removeAll()
                        tools.removeAll()
                        latestBlocks.removeAll()
                    }
                }

            case "assistant":
                if let usage = message["usage"] as? [String: Any] {
                    let input = usage["input_tokens"] as? Int ?? 0
                    let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
                    let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                    let total = input + cacheCreate + cacheRead
                    if total > 0 { latestContextTokens = total }
                }
                guard let arr = message["content"] as? [[String: Any]] else { continue }
                var blocks: [AgentTranscript.Block] = []
                for block in arr {
                    switch block["type"] as? String {
                    case "text":
                        if let t = block["text"] as? String {
                            blocks.append(contentsOf: splitProseAndCode(t))
                        }
                    case "tool_use":
                        guard let id = block["id"] as? String else { continue }
                        let name = block["name"] as? String ?? "Tool"
                        let input = block["input"] as? [String: Any]
                        if tools[id] == nil { toolOrder.append(id) }
                        tools[id] = .init(
                            id: id,
                            name: name,
                            detail: toolDetail(name: name, input: input),
                            finished: false
                        )
                    default:
                        break
                    }
                }
                if !blocks.isEmpty { latestBlocks = blocks }

            default:
                continue
            }
        }

        result.blocks = latestBlocks
        result.activity = Array(
            toolOrder.compactMap { tools[$0] }.suffix(maxActivity)
        )
        result.isWorking = result.activity.contains { !$0.finished }
        result.contextUsedPercent = latestContextTokens.map(contextPercent(usedTokens:))
        return result
    }

    /// Convert used context tokens to a window percentage.
    ///
    /// Claude transcripts don't record the context window size, and the model
    /// id strips long-context markers (a 1M-context session still says
    /// "claude-fable-5"). Infer instead: assume the standard 200k window, and
    /// when usage already exceeds it the session must be on the 1M window.
    /// Exposed for testing.
    static func contextPercent(usedTokens: Int) -> Int {
        let standard = 200_000
        let large = 1_000_000
        let window = usedTokens > standard ? large : standard
        return min(100, usedTokens * 100 / window)
    }

    /// Claude Code injects synthetic user turns (command output, hook payloads,
    /// system reminders, image-attachment captions). Those are not things the
    /// human typed, so showing them as "you asked" would be wrong.
    private static func isSyntheticPrompt(_ text: String) -> Bool {
        text.hasPrefix("<") ||
        text.hasPrefix("Caveat:") ||
        text.hasPrefix("[Request interrupted") ||
        text.hasPrefix("[Image") ||
        // Claude injects the selected skill's full SKILL.md (and sometimes
        // its bundled references) as a user record immediately after the
        // real prompt. It is harness context, not something the human asked.
        text.hasPrefix("Base directory for this skill:")
    }

    /// A short subject line for a tool call, chosen per tool so the strip reads
    /// like "what is it touching" rather than a blob of JSON.
    static func toolDetail(name: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }

        func str(_ key: String) -> String? {
            guard let v = input[key] as? String,
                  !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return v
        }

        let raw: String?
        switch name {
        case "Bash":
            // Long shell commands are dominated by env-var assignments and
            // absolute paths; drop leading VAR=… tokens so the row leads with
            // the actual command word ("screencapture …", not "TESTDIR=/…").
            raw = str("command").map { cmd -> String in
                let flat = cmd.replacingOccurrences(of: "\n", with: "; ")
                var tokens = flat.split(separator: " ", omittingEmptySubsequences: true)[...]
                while let first = tokens.first,
                      first.contains("="),
                      !first.hasPrefix("\""), !first.hasPrefix("'"),
                      first.firstIndex(of: "=")! < (first.firstIndex(of: "/") ?? first.endIndex) {
                    tokens = tokens.dropFirst()
                }
                let joined = tokens.joined(separator: " ")
                return joined.isEmpty ? flat : joined
            }
        case "Read", "Write", "Edit", "NotebookEdit":
            raw = str("file_path").map { ($0 as NSString).lastPathComponent }
        case "Glob", "Grep":
            raw = str("pattern")
        case "WebFetch":
            raw = str("url")
        case "WebSearch":
            raw = str("query")
        case "Task", "Agent":
            raw = str("description")
        case "Skill":
            raw = str("skill")
        default:
            raw = str("description") ?? str("file_path") ?? str("command") ?? str("query")
        }

        guard let raw else { return nil }
        let flat = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > 72 ? String(flat.prefix(71)) + "…" : flat
    }

    /// Split markdown text into prose paragraphs and fenced code blocks.
    ///
    /// Only fenced blocks become `.code`; indented text stays prose, since
    /// agents routinely indent prose for emphasis and misreading that as code
    /// would scatter monospace boxes through the message.
    static func splitProseAndCode(_ text: String) -> [AgentTranscript.Block] {
        var blocks: [AgentTranscript.Block] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String? = nil
        var inFence = false

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            prose.removeAll()
        }

        func flushCode() {
            // Keep interior blank lines but drop leading/trailing ones.
            var lines = code
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            if !lines.isEmpty {
                blocks.append(.code(language: language, text: lines.joined(separator: "\n")))
            }
            code.removeAll()
            language = nil
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    flushCode()
                    inFence = false
                } else {
                    flushProse()
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                    inFence = true
                }
                continue
            }
            if inFence { code.append(line) } else { prose.append(line) }
        }

        // An unterminated fence still holds real code — emit it rather than
        // dropping the tail of a message that is still streaming in.
        if inFence { flushCode() } else { flushProse() }
        return blocks
    }
}

// MARK: - Codex reader

/// Reads OpenAI Codex CLI rollout transcripts
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) into the same
/// `AgentTranscript` the view renders for Claude.
///
/// Rollout entries are `{"type": ..., "payload": {...}}`. The ones that matter:
/// `response_item` payloads of type `message` (roles user/assistant/developer),
/// `custom_tool_call`/`function_call` and their `*_output` twins matched by
/// `call_id`, and `session_meta` (whose `cwd` supports pane matching).
enum CodexTranscriptReader {
    /// Same sizing rationale as AgentTranscriptReader, including the polling
    /// cost that motivates keeping this window small.
    private static let tailBytes: UInt64 = 3 * 1024 * 1024

    private static let maxActivity = 12

    /// Root of all Codex session rollouts.
    static var sessionsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    /// Parse the tail of a rollout file. Autorelease-pooled for the same
    /// reason as `AgentTranscriptReader.parse(url:)` — this runs per poll.
    static func parse(url: URL) -> AgentTranscript? {
        autoreleasepool {
            guard let lines = AgentTranscriptReader.readTailLines(url: url, bytes: tailBytes) else { return nil }
            var transcript = parse(lines: lines)
            transcript.updatedAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            return transcript
        }
    }

    /// The `cwd` recorded in a rollout's `session_meta` (first line), used to
    /// match a session to a pane when fd inspection can't.
    static func sessionCwd(of url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 64 * 1024),
              let text = String(data: data, encoding: .utf8),
              let first = text.components(separatedBy: "\n").first,
              let obj = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any]
        else { return nil }
        return payload["cwd"] as? String
    }

    /// Newest rollout whose session cwd matches the pane's, scanning recent
    /// files only (rollouts are date-sharded; 30 newest is plenty).
    static func latestRollout(matchingCwd cwd: String) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            candidates.append((url, mtime))
        }
        return candidates
            .sorted { $0.1 > $1.1 }
            .prefix(30)
            .first { sessionCwd(of: $0.0) == cwd }?.0
    }

    /// Parse already-split rollout lines. Exposed for testing.
    static func parse(lines: [String]) -> AgentTranscript {
        var result = AgentTranscript()
        var toolOrder: [String] = []
        var tools: [String: AgentTranscript.ToolActivity] = [:]
        var latestBlocks: [AgentTranscript.Block] = []

        var latestPercent: Int? = nil

        for line in lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any]
            else { continue }

            let entryType = obj["type"] as? String

            // Codex reports context usage as periodic token_count events with
            // an explicit model_context_window — no inference needed.
            if entryType == "event_msg" {
                if payload["type"] as? String == "token_count",
                   let info = payload["info"] as? [String: Any],
                   let window = info["model_context_window"] as? Int, window > 0,
                   let last = info["last_token_usage"] as? [String: Any],
                   let total = last["total_tokens"] as? Int {
                    latestPercent = min(100, max(0, total * 100 / window))
                }
                continue
            }

            guard entryType == "response_item" else { continue }

            switch payload["type"] as? String {
            case "message":
                let role = payload["role"] as? String
                let content = payload["content"] as? [[String: Any]] ?? []
                if role == "user" {
                    // Codex wraps environment/skill context in <...> blocks in
                    // synthetic user messages — same filter shape as Claude's.
                    for block in content {
                        guard let text = block["text"] as? String else { continue }
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty, !isSynthetic(trimmed) {
                            result.lastUserPrompt = AgentTranscriptReader.boundedPrompt(
                                AgentTranscriptReader.collapsedPrompt(trimmed))
                            toolOrder.removeAll()
                            tools.removeAll()
                            latestBlocks.removeAll()
                        }
                    }
                } else if role == "assistant" {
                    var blocks: [AgentTranscript.Block] = []
                    for block in content {
                        if let text = block["text"] as? String {
                            blocks.append(contentsOf: AgentTranscriptReader.splitProseAndCode(text))
                        }
                    }
                    if !blocks.isEmpty { latestBlocks = blocks }
                }
                // Developer messages are harness plumbing — ignored.

            case "custom_tool_call", "function_call":
                guard let callId = payload["call_id"] as? String else { continue }
                let name = payload["name"] as? String ?? "tool"
                let rawDetail = (payload["input"] as? String) ?? (payload["arguments"] as? String)
                if tools[callId] == nil { toolOrder.append(callId) }
                tools[callId] = .init(
                    id: callId,
                    name: name,
                    detail: rawDetail.map(flattenDetail),
                    finished: false
                )

            case "custom_tool_call_output", "function_call_output":
                if let callId = payload["call_id"] as? String, let existing = tools[callId] {
                    tools[callId] = .init(
                        id: existing.id,
                        name: existing.name,
                        detail: existing.detail,
                        finished: true
                    )
                }

            default:
                continue
            }
        }

        result.blocks = latestBlocks
        result.activity = Array(toolOrder.compactMap { tools[$0] }.suffix(maxActivity))
        result.isWorking = result.activity.contains { !$0.finished }
        result.contextUsedPercent = latestPercent
        return result
    }

    private static func isSynthetic(_ text: String) -> Bool {
        text.hasPrefix("<")
    }

    private static func flattenDetail(_ raw: String) -> String {
        let flat = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > 72 ? String(flat.prefix(71)) + "…" : flat
    }
}
