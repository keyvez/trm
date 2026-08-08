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
    }
}

// MARK: - Reader

enum AgentTranscriptReader {
    /// Bytes read from the end of the transcript. Claude transcripts grow to
    /// many megabytes over a long session; the last turn is always at the tail,
    /// so reading the whole file would be wasted I/O on every poll.
    ///
    /// Sized in megabytes, not kilobytes, because a single transcript line can
    /// be enormous: a screenshot tool result embeds the image as base64, and
    /// one 2 MB PNG becomes a ~2.7 MB line. A small tail window can land
    /// entirely inside one such line and parse to nothing — observed live as
    /// the overview going blank the moment screenshots entered the session.
    private static let tailBytes: UInt64 = 12 * 1024 * 1024

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
                        result.lastUserPrompt = trimmed
                        // A new human turn supersedes the previous turn's activity.
                        toolOrder.removeAll()
                        tools.removeAll()
                        latestBlocks.removeAll()
                    }
                } else if let arr = message["content"] as? [[String: Any]] {
                    var sawToolResult = false
                    for block in arr {
                        switch block["type"] as? String {
                        case "tool_result":
                            sawToolResult = true
                            if let id = block["tool_use_id"] as? String,
                               let existing = tools[id] {
                                tools[id] = .init(
                                    id: existing.id,
                                    name: existing.name,
                                    detail: existing.detail,
                                    finished: true
                                )
                            }
                        case "text":
                            if let t = block["text"] as? String {
                                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty, !isSyntheticPrompt(trimmed) {
                                    result.lastUserPrompt = trimmed
                                }
                            }
                        default:
                            break
                        }
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
        text.hasPrefix("[Image")
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
    /// Same sizing rationale as AgentTranscriptReader: single lines can be
    /// large, and a turn spans many entries.
    private static let tailBytes: UInt64 = 12 * 1024 * 1024

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
                            result.lastUserPrompt = trimmed
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
