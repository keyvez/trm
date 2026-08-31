import Foundation

/// What a plain shell pane has been doing, reconstructed from its scrollback.
///
/// An agent pane has a transcript: a file the agent writes, in which every
/// turn, tool call and result is already separated for us. A shell pane has
/// nothing of the sort — just the bytes it printed. But the shape is the same
/// one: you type something, it answers. So the overview reads the scrollback
/// back into that shape — command, output, did it fail — and everything above
/// it (turn paging, sections, cards, copying) works on a shell pane exactly as
/// it does on an agent's.
///
/// The separator is the prompt. There is no shell integration to lean on here
/// (trm panes run under `zmx`, and the scrollback that comes back from
/// `zmx history` is rendered text with no OSC 133 marks left in it), so the
/// prompt is found by what it looks like, and the rules below are deliberately
/// conservative: a wrong split invents commands that were never run, which is
/// worse than showing one long block of output.
enum ShellTranscriptReader {

    /// Characters that end an interactive prompt, most distinctive first.
    ///
    /// `>` is last and is only accepted when nothing else is present: it opens
    /// quoted lines, appears in diffs and in `>>>` REPL banners, and treating
    /// it as a prompt on equal footing turns a page of quoted mail into thirty
    /// imaginary commands.
    static let promptMarkers: [Character] = ["❯", "➜", "»", "λ", "$", "%", "#", ">"]

    /// A right-hand prompt (RPROMPT — a clock, a git branch, a timer) is
    /// pushed to the far edge with padding, and once the line is trimmed it
    /// sits on the same line as the command with a run of spaces before it.
    /// Anything past a gap this wide is that, not part of what was typed.
    private static let rightPromptGap = 8

    // MARK: - Parsing

    /// Split scrollback into the commands that produced it.
    ///
    /// - Parameter cwdName: the pane's working directory name, when known.
    ///   Themes that print the directory *after* the marker (robbyrussell's
    ///   `➜  trm git:(main) ✗ ` is the one on this machine) leave it sitting
    ///   where the command should be, and knowing what the directory is
    ///   called is the difference between reading `git status` and reading
    ///   `trm git:(main) ✗ git status`.
    static func commands(
        inScrollback text: String, cwdName: String? = nil
    ) -> [ShellCommand] {
        let lines = unwrapped(text
            .components(separatedBy: "\n")
            .map { String($0.reversed().drop { $0 == " " || $0 == "\t" }.reversed()) })
        guard !lines.isEmpty else { return [] }

        // Pass one: every line that could be a prompt, whatever its marker.
        var candidates: [Int: (marker: Character, command: String)] = [:]
        for (index, line) in lines.enumerated() {
            if let found = promptSplit(line) { candidates[index] = found }
        }

        // Pass two: pick the marker this shell actually uses, and keep only
        // its lines. A prompt repeats; a false positive in output usually
        // does not, and when it does it is outnumbered.
        guard let marker = dominantMarker(in: candidates.values.map(\.marker)) else {
            // No prompt anywhere. That is not a parse failure — it is a pane
            // sitting inside one long-running program (a dev server, a
            // `tail -f`, an installer), and all of its output belongs to that.
            let output = trimmedTrailingBlanks(lines)
            guard !output.isEmpty else { return [] }
            return [ShellCommand(
                index: 0, command: "", output: output, finished: false)]
        }

        // Pass three: some themes keep printing prompt after the marker —
        // the directory, the branch, a dirty flag. Whatever of that survived
        // the per-line strip is found by repetition across the window and
        // taken off every command.
        let leading = repeatedLeadingToken(
            in: candidates.values.filter { $0.marker == marker }.map(\.command),
            cwdName: cwdName)

        var commands: [ShellCommand] = []
        var current: (command: String, output: [String])? = nil
        var preamble: [String] = []

        func flush(finished: Bool) {
            guard let open = current else { return }
            commands.append(ShellCommand(
                index: commands.count,
                command: open.command,
                output: trimmedTrailingBlanks(open.output),
                finished: finished))
            current = nil
        }

        for (index, line) in lines.enumerated() {
            if let found = candidates[index], found.marker == marker {
                // Any prompt at all ends the command above it: the shell only
                // draws one once the previous command has returned.
                flush(finished: true)
                let command = strippingLeadingToken(found.command, token: leading)
                if !command.isEmpty {
                    current = (command: command, output: [])
                }
                continue
            }
            if current != nil {
                current?.output.append(line)
            } else if commands.isEmpty {
                // Output that predates the first prompt in the window. It is
                // the tail of something that scrolled off, and it is often the
                // most interesting thing on screen, so it is kept as a command
                // with no command line rather than discarded.
                preamble.append(line)
            }
        }
        // Whatever is still open ran without a prompt after it, which is what
        // "still running" looks like from out here.
        flush(finished: false)

        let head = trimmedTrailingBlanks(preamble)
        if !head.isEmpty {
            commands.insert(
                ShellCommand(index: 0, command: "", output: head, finished: true),
                at: 0)
            for i in commands.indices { commands[i].index = i }
        }
        return commands.filter { !($0.command.isEmpty && $0.output.isEmpty) }
    }

    /// Rejoin lines the terminal wrapped.
    ///
    /// Scrollback is what was *drawn*, so a command longer than the pane is
    /// several lines by the time it gets here — on a live 79-column pane that
    /// turned `security unlock-keychain ~/Library/Keychains/login.keychain-db`
    /// into a command reading `security unlock-keychain ~/Lib` followed by
    /// two lines of "output". A wrapped line is exactly as wide as the pane
    /// and a deliberate one almost never is, so the width is found as the
    /// most common long line length and lines of exactly that length are
    /// joined to the one below.
    static func unwrapped(_ lines: [String]) -> [String] {
        var counts: [Int: Int] = [:]
        for line in lines where line.count >= 40 { counts[line.count, default: 0] += 1 }
        guard let (width, seen) = counts.max(by: { $0.value < $1.value }), seen >= 3 else {
            return lines
        }

        var result: [String] = []
        var pending: String? = nil
        for line in lines {
            var joined = (pending ?? "") + line
            pending = nil
            // A run of wrapped lines can be arbitrarily long; stop gluing
            // well before a single "line" becomes a page.
            if line.count == width, joined.count < 4000 {
                pending = joined
                continue
            }
            if joined.isEmpty && !line.isEmpty { joined = line }
            result.append(joined)
        }
        if let pending { result.append(pending) }
        return result
    }

    /// Split one line into prompt and command, when it looks like a prompt.
    static func promptSplit(_ line: String) -> (marker: Character, command: String)? {
        guard !line.isEmpty, line.count < 400 else { return nil }
        let chars = Array(line)
        for (offset, char) in chars.enumerated() {
            guard promptMarkers.contains(char) else { continue }
            // A marker ends the prompt only if a space or the line's end
            // follows it: `$HOME` and `100%` are not prompts.
            let next = offset + 1 < chars.count ? chars[offset + 1] : " "
            guard next == " " else { continue }
            // And only if what precedes it can be the end of a prompt —
            // the start of the line, or a path/word/bracket character.
            if offset > 0 {
                let prev = chars[offset - 1]
                let ok = prev == " " || prev.isLetter || prev.isNumber
                    || ")]}/~_-.:".contains(prev)
                guard ok else { continue }
                // `93% idle` is a measurement, not a zsh prompt and a
                // command. `$` is left alone here: `bash-5.2$` is a real
                // prompt with a digit against it.
                if char == "%", prev.isNumber { continue }
            }
            // A prompt is a prompt, not a paragraph: the part before the
            // marker is short, and holds no column padding — a wide run of
            // spaces means this is a table or a listing, not a prompt.
            let prefix = String(chars[0..<offset])
            guard prefix.count <= 120, !prefix.contains("    ") else { continue }

            var command = String(chars[(min(offset + 1, chars.count))...])
                .trimmingCharacters(in: .whitespaces)
            command = strippingRightPrompt(command)
            command = strippingPromptDecorations(command)
            if command.isEmpty { return (char, "") }
            guard looksLikeCommand(command) else { continue }
            return (char, command)
        }
        return nil
    }

    /// Drop a right-hand prompt that shares the command's line.
    private static func strippingRightPrompt(_ command: String) -> String {
        let gap = String(repeating: " ", count: rightPromptGap)
        guard let range = command.range(of: gap) else { return command }
        return String(command[..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
    }

    /// Glyphs a theme prints between the marker and the command. None of them
    /// can begin a command, so anything up to the last one is prompt.
    private static let promptGlyphs = ["✗", "✘", "✓", "±", "⨯", "⚡", "⇡", "⇣", "❯"]

    /// Strip prompt segments that follow the marker.
    ///
    /// oh-my-zsh's default theme — the one on this machine — draws
    /// `➜  trm git:(main) ✗ ` and the marker is the *first* thing on the line,
    /// so everything from the directory to the dirty flag lands where the
    /// command should be. The branch segment and the status glyphs are
    /// unambiguous, so they are taken off here; the bare directory needs the
    /// repetition test in `repeatedLeadingToken`.
    static func strippingPromptDecorations(_ command: String) -> String {
        var text = command
        if let open = text.range(of: "git:("),
           let close = text[open.upperBound...].firstIndex(of: ")") {
            text = String(text[text.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
        }
        for glyph in promptGlyphs {
            while let range = text.range(of: glyph + " "),
                  text.distance(from: text.startIndex, to: range.lowerBound) < 100 {
                text = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }

    /// A directory name that opens nearly every command line, which means it
    /// is the prompt rather than the command.
    ///
    /// Repetition alone is not enough — someone whose every command starts
    /// with `git` would lose the word — so the repeated token must also look
    /// like a place: `~`, an absolute or home-relative path, or the name of
    /// the directory the pane is actually in.
    static func repeatedLeadingToken(
        in commands: [String], cwdName: String?
    ) -> String? {
        let firsts = commands.compactMap { $0.split(separator: " ").first.map(String.init) }
        guard firsts.count >= 3 else { return nil }
        var counts: [String: Int] = [:]
        for word in firsts { counts[word, default: 0] += 1 }
        guard let (token, count) = counts.max(by: { $0.value < $1.value }) else { return nil }
        guard Double(count) / Double(firsts.count) >= 0.6 else { return nil }
        let looksLikeAPlace = token == "~" || token.hasPrefix("~/") || token.hasPrefix("/")
            || (cwdName.map { $0 == token || token.hasSuffix("/" + $0) } ?? false)
        guard looksLikeAPlace else { return nil }
        // Only when something follows it: a prompt line whose whole content
        // is the directory is an idle prompt, and is already handled.
        guard commands.contains(where: {
            $0.hasPrefix(token + " ") && $0.count > token.count + 1
        }) else { return nil }
        return token
    }

    private static func strippingLeadingToken(_ command: String, token: String?) -> String {
        guard let token else { return command }
        // A prompt line holding nothing but the directory is an idle prompt,
        // not a command called after the directory.
        if command == token { return "" }
        guard command.hasPrefix(token + " ") else { return command }
        return String(command.dropFirst(token.count))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Whether the text after a prompt marker is plausibly a command.
    ///
    /// The first word of a command is a program name, a path, a variable
    /// assignment or a subshell — never a sentence. This is the rule that
    /// keeps prose containing a stray `$` or `%` out of the command list.
    static func looksLikeCommand(_ command: String) -> Bool {
        guard let first = command.split(separator: " ").first else { return false }
        let word = String(first)
        guard word.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./~+-=:@")
        guard word.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard let head = word.unicodeScalars.first else { return false }
        // Leading punctuation is only a command when it is a path or a
        // subshell: `./build`, `../x`, `~/bin/thing`.
        if !(CharacterSet.alphanumerics.contains(head) || head == "." || head == "/"
             || head == "~" || head == "_") {
            return false
        }
        return true
    }

    /// The marker this shell's prompt uses.
    ///
    /// Counted rather than configured: a prompt repeats down the scrollback,
    /// and whichever marker repeats most is the one drawing it. `>` only wins
    /// when it is the only marker present at all.
    static func dominantMarker(in markers: [Character]) -> Character? {
        guard !markers.isEmpty else { return nil }
        var counts: [Character: Int] = [:]
        for marker in markers { counts[marker, default: 0] += 1 }
        let ranked = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            let li = promptMarkers.firstIndex(of: lhs.key) ?? .max
            let ri = promptMarkers.firstIndex(of: rhs.key) ?? .max
            return li < ri
        }
        if ranked[0].key == ">", ranked.count > 1 { return ranked[1].key }
        return ranked[0].key
    }

    private static func trimmedTrailingBlanks(_ lines: [String]) -> [String] {
        var out = lines
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            out.removeLast()
        }
        while let first = out.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            out.removeFirst()
        }
        return out
    }

    // MARK: - Transcript

    /// How much of a command's output the reply section shows. The full log
    /// is always one copy away; a 40,000-line build poured into a SwiftUI
    /// column is not a reading surface.
    static let outputPreviewLines = 60

    /// Render parsed commands as the same `AgentTranscript` the overview
    /// draws for an agent, so nothing downstream needs to know which it has.
    static func transcript(
        commands: [ShellCommand], updatedAt: Date?
    ) -> AgentTranscript {
        var transcript = AgentTranscript()
        transcript.turns = commands.map(turn(for:))
        if let last = transcript.turns.last {
            transcript.blocks = last.blocks
            transcript.latestBlocks = last.blocks
            transcript.activity = last.activity
            transcript.lastUserPrompt = last.prompt
            transcript.promptBlocks = last.promptBlocks
        }
        transcript.turnID = transcript.turns.last?.id
        transcript.updatedAt = updatedAt
        // A shell is "working" when its last command has not returned. There
        // is no equivalent of an agent's still-being-written transcript here:
        // a pane whose command finished an hour ago and one whose command
        // finished a second ago are both idle.
        transcript.isWorking = commands.last.map { !$0.finished } ?? false
        return transcript
    }

    static func turn(for command: ShellCommand) -> AgentTranscript.Turn {
        var turn = AgentTranscript.Turn()
        turn.prompt = command.command.isEmpty ? "(output above the first prompt)" : command.command
        turn.promptBlocks = command.command.isEmpty
            ? []
            : [.code(language: "shell", text: command.command)]

        let summary = command.summary
        var blocks: [AgentTranscript.Block] = []
        if !summary.headline.isEmpty {
            blocks.append(.paragraph(summary.headline))
        }
        let preview = command.outputPreview(lines: outputPreviewLines)
        if !preview.isEmpty {
            blocks.append(.code(language: nil, text: preview))
        }
        turn.blocks = blocks
        turn.latestBlocks = blocks

        turn.activity = [AgentTranscript.ToolActivity(
            id: command.id,
            name: command.program.isEmpty ? "output" : command.program,
            detail: command.arguments.isEmpty ? nil : command.arguments,
            finished: command.finished,
            isError: summary.errorCount > 0,
            errorText: command.firstErrorLine)]
        return turn
    }
}

/// One command run in a shell pane, with everything it printed.
struct ShellCommand: Equatable, Identifiable {
    /// Position in the window, oldest first.
    var index: Int
    /// What was typed. Empty for output that predates the first prompt, or
    /// for a pane that has been inside one program the whole time.
    let command: String
    /// Output lines, blank-trimmed at both ends.
    let output: [String]
    /// False when no prompt followed — which is what a running command looks
    /// like from the outside.
    let finished: Bool

    /// Stable while a command runs: its output grows on every poll, so the
    /// identity is the command line and where it sits, not what it printed.
    var id: String { "\(index):\(command)" }

    var outputText: String { output.joined(separator: "\n") }

    /// The program invoked, ignoring leading environment assignments — a row
    /// that says `FOO=1` instead of `cargo` names the wrong thing.
    var program: String {
        for word in command.split(separator: " ") {
            let text = String(word)
            if text.contains("=") && !text.hasPrefix("/") && !text.hasPrefix(".") { continue }
            return (text as NSString).lastPathComponent
        }
        return ""
    }

    var arguments: String {
        guard !program.isEmpty else { return "" }
        guard let range = command.range(of: program) else { return "" }
        return String(command[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    var kind: ShellCommandKind { ShellCommandKind.classify(command) }

    /// Indices into `output` of the lines that report a failure.
    var errorLineIndices: [Int] {
        output.indices.filter { ShellOutputSummary.isErrorLine(output[$0]) }
    }

    var firstErrorLine: String? {
        errorLineIndices.first.map { output[$0].trimmingCharacters(in: .whitespaces) }
    }

    var summary: ShellOutputSummary { ShellOutputSummary(command: self) }

    /// The tail of the output, which is where a command says how it went.
    func outputPreview(lines: Int) -> String {
        guard output.count > lines else { return outputText }
        return (["… \(output.count - lines) earlier lines"]
                + output.suffix(lines)).joined(separator: "\n")
    }

    /// The error, with the lines around it.
    ///
    /// A bare error line is rarely enough — the line above says which file or
    /// target it was compiling, and the lines below carry the trace. This is
    /// the excerpt worth pasting into a message or handing to an agent.
    func errorExcerpt(context: Int = 3) -> String? {
        guard let first = errorLineIndices.first else { return nil }
        let last = errorLineIndices.last ?? first
        let lower = max(0, first - context)
        let upper = min(output.count - 1, last + context)
        guard lower <= upper else { return nil }
        var excerpt = Array(output[lower...upper])
        if !command.isEmpty { excerpt.insert("$ \(command)", at: 0) }
        return excerpt.joined(separator: "\n")
    }

    /// The last few lines, for "what did it just say".
    func tail(lines: Int = 20) -> String {
        output.suffix(lines).joined(separator: "\n")
    }

    /// The command and everything it printed, in full.
    var fullLog: String {
        let head = command.isEmpty ? "" : "$ \(command)\n"
        return head + outputText
    }
}

/// What kind of work a command is. Used to label a card and to colour it —
/// a failing test run and a failing `ls` deserve different attention.
enum ShellCommandKind: String, Equatable, CaseIterable {
    case vcs
    case build
    case test
    case packages
    case run
    case files
    case search
    case network
    case remote
    case containers
    case editor
    case process
    case agent
    case shell
    case output

    var title: String {
        switch self {
        case .vcs: return "Version control"
        case .build: return "Build"
        case .test: return "Tests"
        case .packages: return "Packages"
        case .run: return "Run"
        case .files: return "Files"
        case .search: return "Search"
        case .network: return "Network"
        case .remote: return "Remote"
        case .containers: return "Containers"
        case .editor: return "Editor"
        case .process: return "Processes"
        case .agent: return "Agent"
        case .shell: return "Shell"
        case .output: return "Output"
        }
    }

    var symbol: String {
        switch self {
        case .vcs: return "arrow.triangle.branch"
        case .build: return "hammer"
        case .test: return "checklist"
        case .packages: return "shippingbox"
        case .run: return "play.circle"
        case .files: return "folder"
        case .search: return "magnifyingglass"
        case .network: return "network"
        case .remote: return "antenna.radiowaves.left.and.right"
        case .containers: return "cube.box"
        case .editor: return "square.and.pencil"
        case .process: return "gauge.with.dots.needle.bottom.50percent"
        case .agent: return "sparkle"
        case .shell: return "terminal"
        case .output: return "text.alignleft"
        }
    }

    /// Classify by the program, and by its subcommand where the program alone
    /// does not say — `cargo build` and `cargo test` are different jobs.
    static func classify(_ command: String) -> ShellCommandKind {
        let words = command.split(separator: " ").map(String.init)
            .filter { !($0.contains("=") && !$0.hasPrefix("/") && !$0.hasPrefix(".")) }
        guard let first = words.first else { return .output }
        let program = (first as NSString).lastPathComponent.lowercased()
        let rest = words.dropFirst().map { $0.lowercased() }
        let sub = rest.first { !$0.hasPrefix("-") } ?? ""
        // A build tool's real job is named by its subcommands, and they can
        // be stacked — `zig build test` and `zig build run` are the same
        // program doing two different things.
        let asks = { (word: String) in rest.contains(word) }

        // Test runners name themselves.
        if ["pytest", "jest", "vitest", "rspec", "phpunit", "ctest", "tox"]
            .contains(program) || program.hasSuffix("test") {
            return .test
        }
        if ["git", "gh", "gh-axi", "jj", "hg", "svn", "tig", "lazygit"].contains(program) {
            return .vcs
        }
        if ["make", "cmake", "ninja", "xcodebuild", "gradle", "mvn", "bazel", "tsc",
            "swiftc", "gcc", "clang", "rustc", "zig", "cargo", "go", "swift", "dotnet"]
            .contains(program) {
            if asks("test") || asks("tests") { return .test }
            if asks("run") || asks("serve") { return .run }
            if asks("add") || asks("install") || asks("get") || asks("fetch") {
                return .packages
            }
            return .build
        }
        if ["npm", "pnpm", "yarn", "bun", "brew", "pip", "pip3", "uv", "gem", "apt",
            "apt-get", "port", "nix", "poetry", "conda", "mise", "asdf"].contains(program) {
            if sub == "test" { return .test }
            if ["run", "start", "dev", "serve", "exec"].contains(sub) { return .run }
            if sub == "build" { return .build }
            return .packages
        }
        if ["node", "python", "python3", "ruby", "deno", "php", "java", "bun"]
            .contains(program) || first.hasPrefix("./") || first.hasPrefix("/") {
            return .run
        }
        if ["ls", "ll", "cd", "cat", "bat", "cp", "mv", "rm", "mkdir", "touch", "open",
            "less", "more", "head", "tail", "tree", "du", "df", "chmod", "chown", "ln",
            "pwd", "stat", "file", "zip", "unzip", "tar"].contains(program) {
            return .files
        }
        if ["grep", "rg", "ag", "ack", "find", "fd", "fzf", "locate", "awk", "sed"]
            .contains(program) {
            return .search
        }
        if ["ssh", "scp", "rsync", "sftp", "tailscale", "mosh"].contains(program) {
            return .remote
        }
        if ["curl", "wget", "ping", "dig", "nslookup", "host", "traceroute", "nc",
            "http", "httpie"].contains(program) {
            return .network
        }
        if ["docker", "docker-compose", "podman", "kubectl", "k9s", "helm", "colima"]
            .contains(program) {
            return .containers
        }
        if ["vim", "nvim", "nano", "emacs", "code", "hx", "micro"].contains(program) {
            return .editor
        }
        if ["ps", "top", "htop", "kill", "killall", "lsof", "launchctl", "systemctl",
            "service", "pgrep", "jobs", "sudo"].contains(program) {
            return .process
        }
        if ["claude", "codex", "aider", "llm", "ollama", "moltis"].contains(program) {
            return .agent
        }
        return .shell
    }
}

/// What a command's output amounts to.
///
/// Three things, in the order they are wanted: did it fail, what did it say
/// about how it went, and how much of it is there. The facts are pulled from
/// the lines tools actually print at the end of a run — test counts, file
/// counts, "Build succeeded" — because those are the lines a person scrolls
/// back up to find.
struct ShellOutputSummary: Equatable {
    let lineCount: Int
    let errorCount: Int
    /// One line saying how it went, or the empty string when there is nothing
    /// worth claiming.
    let headline: String
    /// Short measured facts, at most a handful.
    let facts: [String]
    let firstError: String?

    init(command: ShellCommand) {
        let output = command.output
        lineCount = output.count
        let errorIndices = command.errorLineIndices
        errorCount = errorIndices.count
        firstError = errorIndices.first.map {
            output[$0].trimmingCharacters(in: .whitespaces)
        }
        facts = Self.facts(in: output, command: command)
        headline = Self.headline(
            command: command, errorCount: errorCount, firstError: firstError,
            facts: facts)
    }

    private static func headline(
        command: ShellCommand, errorCount: Int, firstError: String?, facts: [String]
    ) -> String {
        if !command.finished {
            return command.output.isEmpty
                ? "Still running."
                : "Still running — \(command.output.count) lines so far."
        }
        if let firstError {
            let more = errorCount > 1 ? " (\(errorCount) failing lines)" : ""
            return "Failed\(more): \(firstError)"
        }
        if let first = facts.first { return first }
        if command.output.isEmpty { return "No output." }
        return "\(command.output.count) lines of output."
    }

    /// Lines a person would scroll back to find.
    static func facts(in output: [String], command: ShellCommand) -> [String] {
        var found: [String] = []
        let patterns: [String] = [
            #"\b\d+ (?:tests?|examples?|specs?|assertions?) (?:passed|failed|ok)\b"#,
            #"\b(?:all )?\d+ tests? pass(?:ed|ing)?\b"#,
            #"\btests?:\s*\d+ (?:passed|failed)"#,
            #"\b\d+ (?:passed|failed|skipped)(?:,| )"#,
            #"\bbuild (?:succeeded|failed|complete[d]?)\b"#,
            #"\bcompiled? (?:successfully|in \d+)"#,
            #"\b\d+ files? changed\b"#,
            #"\bnothing to commit\b"#,
            #"\b\d+ (?:packages?|dependencies) (?:added|installed|updated|removed)\b"#,
            #"\bexit (?:code|status) \d+\b"#,
            #"\bdone in \d+"#,
            #"\bup to date\b"#,
        ]
        for line in output {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.count <= 160 else { continue }
            for pattern in patterns
            where trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                if !found.contains(trimmed) { found.append(trimmed) }
                break
            }
            if found.count >= 4 { break }
        }
        return found
    }

    /// Whether a line reports a failure.
    ///
    /// Tuned against the lines that are ordinary in a working session: a
    /// summary that says `0 errors`, a `--no-error` flag echoed back, the word
    /// "warning". Those are the false positives that make an error filter
    /// useless, because a list that flags everything flags nothing.
    static func isErrorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 500 else { return false }
        let lower = trimmed.lowercased()

        // A zero count is a report of success, however the tool words it.
        if lower.range(of: #"\b(0|no) (errors?|failures?|failed|problems?)\b"#,
                       options: .regularExpression) != nil {
            return false
        }
        if lower.hasPrefix("warning") || lower.contains("--no-error") { return false }

        let markers = [
            #"^error\b"#, #"\berror:"#, #"^fatal\b"#, #"\bfatal:"#, #"^e/"#,
            #"\bcommand not found\b"#, #"\bno such file or directory\b"#,
            #"\bpermission denied\b"#, #"\bpanic:"#, #"^npm err!"#,
            #"\btraceback \(most recent call last\)"#, #"\bsegmentation fault\b"#,
            #"^\s*(assertion|abort)(ed)?\b"#, #"\b\d+ (tests?|examples?) failed\b"#,
            #"\bfailed with (exit )?(code|status) [1-9]"#, #"\bexit (code|status) [1-9]"#,
            #"^fail(ed|ure)?\b"#, #"\bbuild failed\b"#, #"\btest failed\b"#,
            #"\b(syntaxerror|typeerror|valueerror|keyerror|runtimeerror|nameerror)\b"#,
            #"\bunresolved\b"#, #"\bundefined reference\b"#, #"\bcannot find\b"#,
            #"\bnot recognized\b"#, #"\bis not a\b.*\bcommand\b"#,
            // What a CLI says when it was called wrongly. It rarely uses the
            // word "error" and it always means the command did not run.
            #"\b(invalid|illegal|unknown|unrecognized) (option|argument|flag|value|command)\b"#,
        ]
        return markers.contains {
            lower.range(of: $0, options: .regularExpression) != nil
        }
    }
}
