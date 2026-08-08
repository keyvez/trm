import Foundation

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

    /// Parse the tail of a JSONL transcript file.
    static func parse(url: URL) -> AgentTranscript? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? 0
        let offset = size > tailBytes ? size - tailBytes : 0
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd() else { return nil }

        // A mid-file seek can slice a multi-byte character or a line in half.
        // Decoding leniently and dropping the first partial line keeps the
        // parse robust rather than failing the whole read.
        var text = String(decoding: data, as: UTF8.self)
        if offset > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        var transcript = parse(lines: text.components(separatedBy: "\n"))

        // A long tool-heavy turn can push every human message out of the tail
        // window. Only then do the wider (more expensive) read, and take just
        // the prompt from it — the message and activity from the tail are
        // already correct and current.
        if transcript.lastUserPrompt == nil, offset > 0 {
            transcript.lastUserPrompt = lastUserPrompt(in: url, upTo: promptSearchBytes)
        }

        transcript.updatedAt = mtime
        return transcript
    }

    /// Scan a wider window from the end of the file for the newest human prompt.
    private static func lastUserPrompt(in url: URL, upTo bytes: UInt64) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? 0
        let offset = size > bytes ? size - bytes : 0
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd() else { return nil }

        var text = String(decoding: data, as: UTF8.self)
        if offset > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return parse(lines: text.components(separatedBy: "\n")).lastUserPrompt
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
        return result
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
