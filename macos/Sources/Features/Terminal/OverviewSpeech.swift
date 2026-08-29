import AVFoundation
import Foundation

/// One persistent MLX worker shared by desktop playback and phone streams.
///
/// Loading Qwen and compiling its Metal kernels costs several seconds once.
/// Keeping the worker alive makes subsequent requests start yielding playable
/// half-second PCM chunks in a few hundred milliseconds instead of paying that
/// startup on every update.
final class LocalNeuralSpeechEngine: @unchecked Sendable {
    static let shared = LocalNeuralSpeechEngine()

    struct Chunk: Sendable {
        let pcm16: Data
        let sampleRate: Double
    }

    enum SpeechError: LocalizedError {
        case notInstalled
        case launch(String)
        case render(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Local voice is not installed. Run scripts/install-local-tts.sh."
            case .launch(let detail):
                return "Couldn't start the local voice: \(detail)"
            case .render(let detail):
                return detail.isEmpty ? "The local voice couldn't render that update." : detail
            }
        }
    }

    private typealias StreamContinuation = AsyncThrowingStream<Chunk, Error>.Continuation

    private let queue = DispatchQueue(label: "app.roj.trm.local-speech", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var stderrTail = ""
    private var streams: [String: StreamContinuation] = [:]

    private init() {}

    /// Start loading the model before the first click, without blocking UI.
    func prewarm() {
        queue.async { [weak self] in
            try? self?.ensureProcess()
        }
    }

    /// PCM arrives as Qwen generates it; callers never wait for a complete file.
    func stream(_ text: String) -> AsyncThrowingStream<Chunk, Error> {
        let id = UUID().uuidString
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { self?.streams.removeValue(forKey: id) }
            }
            queue.async { [weak self] in
                guard let self else {
                    continuation.finish(throwing: SpeechError.render("Speech engine closed."))
                    return
                }
                do {
                    try self.ensureProcess()
                    self.streams[id] = continuation
                    try self.send(["id": id, "text": text])
                } catch {
                    self.streams.removeValue(forKey: id)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func ensureProcess() throws {
        if let process, process.isRunning { return }

        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".trm/tts", isDirectory: true)
        let python = root.appendingPathComponent("venv/bin/python")
        let worker = root.appendingPathComponent("trm-tts-worker.py")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: worker.path) else {
            throw SpeechError.notInstalled
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = python
        process.arguments = [worker.path]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.queue.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(4_000))
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.queue.async { self?.workerExited(status: process.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw SpeechError.launch(error.localizedDescription)
        }
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        outputBuffer.removeAll(keepingCapacity: true)
        stderrTail = ""
    }

    private func send(_ object: [String: String]) throws {
        guard let input else { throw SpeechError.render("Speech worker has no input pipe.") }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0a)
        input.write(data)
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0a) {
            let line = Data(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String else {
                // MLX/Hugging Face startup logs may share stdout. They are not protocol events.
                continue
            }
            let id = object["id"] as? String ?? ""
            switch type {
            case "chunk":
                guard let continuation = streams[id],
                      let encoded = object["pcm"] as? String,
                      let pcm = Data(base64Encoded: encoded),
                      let rate = (object["sampleRate"] as? NSNumber)?.doubleValue else { continue }
                continuation.yield(Chunk(pcm16: pcm, sampleRate: rate))
            case "end":
                streams.removeValue(forKey: id)?.finish()
            case "error":
                let detail = object["message"] as? String ?? "Local speech failed."
                streams.removeValue(forKey: id)?.finish(throwing: SpeechError.render(detail))
            case "fatal":
                let detail = object["message"] as? String ?? "Local speech worker stopped."
                finishAll(with: SpeechError.render(detail))
            default:
                break
            }
        }
    }

    private func workerExited(status: Int32) {
        let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        finishAll(with: SpeechError.render(
            detail.isEmpty ? "Local speech worker exited with status \(status)." : detail))
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        input = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer.removeAll(keepingCapacity: true)
    }

    private func finishAll(with error: Error) {
        let current = streams.values
        streams.removeAll()
        for continuation in current { continuation.finish(throwing: error) }
    }
}

/// Speaks only the part of an overview worth interrupting a developer for.
@MainActor
final class OverviewSpeaker: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPreparing = false
    @Published private(set) var lastError: String?
    /// Playback rate, pitch held steady. Remembered between replies — someone
    /// who listens at 1.5× wants 1.5× next time too.
    @Published var rate: Float = UserDefaults.standard.object(forKey: rateKey) as? Float ?? 1 {
        didSet {
            let clamped = min(max(rate, 0.5), 2)
            if clamped != rate { rate = clamped; return }
            timePitch?.rate = rate
            UserDefaults.standard.set(rate, forKey: Self.rateKey)
        }
    }
    /// How far in, and how much there is, in seconds of rendered audio.
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var rendered: TimeInterval = 0
    /// True once the whole reply has been generated; until then `rendered`
    /// is still growing and the end of the scrubber is not the end of the text.
    @Published private(set) var isComplete = false

    var isActive: Bool { isSpeaking || isPreparing }
    var canSeek: Bool { !buffers.isEmpty }

    private static let rateKey = "OverviewSpeaker.rate"

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var timePitch: AVAudioUnitTimePitch?
    private var generationTask: Task<Void, Never>?
    private var requestID: UUID?
    private var pendingBuffers = 0
    private var streamEnded = false
    private var sampleRate: Double?

    /// Every buffer rendered for this reply, in order.
    ///
    /// Kept so playback can go backwards: the synthesiser streams forwards
    /// once and cannot be asked to produce the same audio again, so seeking
    /// means rescheduling audio already in hand. At roughly half a second per
    /// buffer a long reply is a few hundred of them — a few megabytes, freed
    /// when playback stops.
    private var buffers: [AVAudioPCMBuffer] = []
    /// Index of the next buffer to schedule; everything before it has played
    /// or been skipped.
    private var cursor = 0
    /// Seconds of audio before `cursor`, so elapsed does not need the node's
    /// clock — which resets on every reschedule.
    private var playedSeconds: TimeInterval = 0

    override init() {
        super.init()
        LocalNeuralSpeechEngine.shared.prewarm()
    }

    func toggle(_ text: String) {
        if isActive {
            stop()
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let id = UUID()
        requestID = id
        isPreparing = true
        lastError = nil
        streamEnded = false
        pendingBuffers = 0
        buffers = []
        cursor = 0
        playedSeconds = 0
        elapsed = 0
        rendered = 0
        isComplete = false
        generationTask = Task { [weak self] in
            do {
                for try await chunk in LocalNeuralSpeechEngine.shared.stream(trimmed) {
                    try Task.checkCancellation()
                    guard let self, self.requestID == id else { return }
                    try self.schedule(chunk)
                }
                guard let self, self.requestID == id else { return }
                self.streamEnded = true
                self.isComplete = true
                self.finishIfDrained()
            } catch is CancellationError {
                // The stop button is not an error.
            } catch {
                guard let self, self.requestID == id else { return }
                self.stopAudio()
                self.isPreparing = false
                self.isSpeaking = false
                self.requestID = nil
                self.lastError = error.localizedDescription
            }
        }
    }

    func stop() {
        requestID = nil
        generationTask?.cancel()
        generationTask = nil
        stopAudio()
        isPreparing = false
        isSpeaking = false
    }

    private func schedule(_ chunk: LocalNeuralSpeechEngine.Chunk) throws {
        if sampleRate != chunk.sampleRate || audioEngine == nil {
            stopAudio()
            try configureAudio(sampleRate: chunk.sampleRate)
        }
        guard let playerNode,
              let format = AVAudioFormat(
                standardFormatWithSampleRate: chunk.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(chunk.pcm16.count / MemoryLayout<Int16>.size)),
              let destination = buffer.floatChannelData?[0] else {
            throw LocalNeuralSpeechEngine.SpeechError.render("Couldn't create an audio buffer.")
        }

        let frames = chunk.pcm16.count / MemoryLayout<Int16>.size
        buffer.frameLength = AVAudioFrameCount(frames)
        chunk.pcm16.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<frames {
                let bits = UInt16(bytes[index * 2]) | (UInt16(bytes[index * 2 + 1]) << 8)
                destination[index] = Float(Int16(bitPattern: bits)) / 32768.0
            }
        }

        buffers.append(buffer)
        rendered += Double(frames) / chunk.sampleRate
        // Only schedule what the cursor has reached. After a skip back the
        // cursor trails the newest buffer, and freshly arriving audio must
        // queue behind the replay rather than jump the line.
        if cursor == buffers.count - 1 {
            enqueue(buffer)
            cursor = buffers.count
        }
        if !playerNode.isPlaying { playerNode.play() }
        isPreparing = false
        isSpeaking = true
    }

    /// Hand one buffer to the node and count it as in flight.
    private func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard let playerNode else { return }
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        pendingBuffers += 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                self.playedSeconds += seconds
                self.elapsed = self.playedSeconds
                // A skip back leaves the cursor behind the rendered end;
                // keep feeding it as the node drains.
                if self.cursor < self.buffers.count {
                    let next = self.buffers[self.cursor]
                    self.cursor += 1
                    self.enqueue(next)
                    if self.playerNode?.isPlaying == false { self.playerNode?.play() }
                }
                self.finishIfDrained()
            }
        }
    }

    // MARK: Seeking

    /// Move by `offset` seconds through the audio rendered so far.
    ///
    /// Seeks land on a buffer boundary — about half a second — because that is
    /// the granularity the synthesiser produced and splitting one is not worth
    /// the arithmetic. Backwards is the useful direction: it is for "what did
    /// it just say", not for scrubbing a recording.
    func seek(by offset: TimeInterval) {
        guard !buffers.isEmpty else { return }
        let target = max(0, min(playedSeconds + offset, rendered))
        var index = 0
        var seconds: TimeInterval = 0
        while index < buffers.count {
            let length = Double(buffers[index].frameLength) / buffers[index].format.sampleRate
            if seconds + length > target { break }
            seconds += length
            index += 1
        }
        restart(from: index, at: seconds)
    }

    func restart() { restart(from: 0, at: 0) }

    private func restart(from index: Int, at seconds: TimeInterval) {
        guard let playerNode else { return }
        // Stopping clears the node's queue, which is the only way to unschedule
        // buffers already handed to it.
        playerNode.stop()
        pendingBuffers = 0
        cursor = index
        playedSeconds = seconds
        elapsed = seconds
        // Prime a few so playback resumes without waiting on the generator.
        let priming = min(buffers.count, index + 8)
        while cursor < priming {
            let buffer = buffers[cursor]
            cursor += 1
            enqueue(buffer)
        }
        if cursor > index {
            playerNode.play()
            isSpeaking = true
        }
    }

    private func configureAudio(sampleRate: Double) throws {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw LocalNeuralSpeechEngine.SpeechError.render("Unsupported speech sample rate.")
        }
        // Time-pitch rather than varispeed: changing the rate should make the
        // voice faster, not higher.
        let speed = AVAudioUnitTimePitch()
        speed.rate = min(max(rate, 0.5), 2)
        engine.attach(node)
        engine.attach(speed)
        engine.connect(node, to: speed, format: format)
        engine.connect(speed, to: engine.mainMixerNode, format: format)
        try engine.start()
        self.audioEngine = engine
        self.playerNode = node
        self.timePitch = speed
        self.sampleRate = sampleRate
    }

    private func finishIfDrained() {
        guard streamEnded, pendingBuffers == 0, cursor >= buffers.count else { return }
        stopAudio()
        generationTask = nil
        requestID = nil
        isPreparing = false
        isSpeaking = false
    }

    private func stopAudio() {
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        timePitch = nil
        sampleRate = nil
        pendingBuffers = 0
        buffers = []
        cursor = 0
        playedSeconds = 0
        elapsed = 0
        rendered = 0
    }

    /// Questions, failures, outcomes, tests, deploy state, and decisions make
    /// the cut. Tool-by-tool narration and "let me inspect that" chatter do not.
    static func developerBriefing(for transcript: AgentTranscript) -> String {
        var lead: [String] = []
        if let question = transcript.questions.last(where: { !$0.finished }) {
            lead.append("Needs your input: " + clipped(plainProse(question.text), limit: 220))
        }
        if let failure = transcript.activity.last(where: \.isError) {
            let detail = failure.errorText ?? "\(failure.name) failed."
            lead.append("A tool failed: " + clipped(plainProse(detail), limit: 200))
        }

        let prose = transcript.blocks.compactMap { block -> String? in
            guard case .paragraph(let text) = block else { return nil }
            let cleaned = plainProse(text)
            return cleaned.isEmpty ? nil : cleaned
        }
        let sentences = prose.flatMap(speechSentences)
        let count = max(1, sentences.count)
        let ranked = sentences.enumerated().compactMap { index, sentence -> Candidate? in
            let value = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 8 else { return nil }
            let score = signalScore(value) + (index * 3 / count)
            guard score >= 3 else { return nil }
            return Candidate(index: index, text: clipped(value, limit: 240), score: score)
        }
        .sorted {
            if $0.score == $1.score { return $0.index > $1.index }
            return $0.score > $1.score
        }

        var chosen: [Candidate] = []
        for candidate in ranked {
            guard lead.count + chosen.count < 3 else { break }
            let lower = candidate.text.lowercased()
            guard !lead.contains(where: { $0.lowercased().contains(lower) }),
                  !chosen.contains(where: {
                    let existing = $0.text.lowercased()
                    return existing.contains(lower) || lower.contains(existing)
                  }) else { continue }
            chosen.append(candidate)
        }
        chosen.sort { $0.index < $1.index }
        return clipped((lead + chosen.map(\.text)).joined(separator: " "), limit: 620)
    }

    private struct Candidate {
        let index: Int
        let text: String
        let score: Int
    }

    private static func signalScore(_ sentence: String) -> Int {
        let lower = sentence.lowercased()
        let words = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        let outcomes: Set<String> = [
            "fixed", "implemented", "installed", "deployed", "shipped", "verified",
            "passed", "passes", "green", "complete", "completed", "done", "resolved",
            "working", "live",
        ]
        let attention: Set<String> = [
            "failed", "failing", "error", "errors", "blocked", "blocker", "cannot",
            "needs", "need", "caveat", "tradeoff", "risk", "regression", "broken",
        ]
        let engineering: Set<String> = [
            "test", "tests", "build", "release", "production", "config", "metric",
            "latency", "deploy", "deployment",
        ]

        var score = 0
        if !words.isDisjoint(with: outcomes) { score += 4 }
        if !words.isDisjoint(with: attention) { score += 4 }
        if !words.isDisjoint(with: engineering) { score += 2 }
        if [
            "not deployed", "still needs", "your call", "next step", "all green",
            "did not", "can't", "hasn't", "haven't", "i recommend", "i'd change",
        ].contains(where: { lower.contains($0) }) { score += 4 }
        if sentence.contains("?") { score += 2 }
        if [
            "let me ", "i'll ", "i will ", "now let ", "first i'll ", "first i will ",
            "i'm going to ", "i am going to ", "i'm checking ", "i am checking ",
        ].contains(where: { lower.hasPrefix($0) }) { score -= 6 }
        return score
    }

    private static func speechSentences(_ text: String) -> [String] {
        var result: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var parts: [String] = []
            trimmed.enumerateSubstrings(
                in: trimmed.startIndex..<trimmed.endIndex,
                options: [.bySentences, .localized]
            ) { substring, _, _, _ in
                if let substring { parts.append(substring) }
            }
            result += parts.isEmpty ? [trimmed] : parts
        }
        return result
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) + "…" }
        return String(cut) + "…"
    }

    /// All prose, retained for formatting tests.
    static func spokenText(blocks: [AgentTranscript.Block]) -> String {
        blocks.compactMap { block -> String? in
            guard case .paragraph(let text) = block else { return nil }
            let cleaned = plainProse(text)
            return cleaned.isEmpty ? nil : cleaned
        }.joined(separator: "\n\n")
    }

    // MARK: The full reading

    /// The whole reply, read the way a person would read it aloud.
    ///
    /// The briefing above answers "what do I need to know"; this answers "read
    /// me what it said", which is the thing you usually want and was the wrong
    /// way round before. Reading everything does not mean reading it
    /// *literally*: a diff, a table, a git invocation and a forty-character
    /// hash are all things a person skips or names rather than pronounces, and
    /// a synthesiser that spells them out is worse than one that stays quiet.
    static func fullReading(for transcript: AgentTranscript) -> String {
        var parts: [String] = []
        var pendingCode: [String] = []

        func flushCode() {
            guard !pendingCode.isEmpty else { return }
            // Consecutive blocks collapse into one phrase: three in a row is
            // one interruption, not three.
            let kinds = Set(pendingCode)
            let noun: String
            if kinds.count == 1, let only = kinds.first {
                noun = pendingCode.count == 1
                    ? "a \(only)" : "\(spelled(pendingCode.count)) \(only)s"
            } else {
                noun = "\(spelled(pendingCode.count)) code blocks"
            }
            parts.append("Then \(noun).")
            pendingCode = []
        }

        for block in transcript.blocks {
            switch block {
            case .paragraph(let text):
                let spoken = speakableProse(text)
                if !spoken.isEmpty {
                    flushCode()
                    parts.append(spoken)
                }
            case .code(let language, let text):
                pendingCode.append(codeNoun(language: language, text: text))
            case .image:
                flushCode()
                parts.append("Then an image.")
            }
        }
        flushCode()
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What to call a code block without reading it.
    private static func codeNoun(language: String?, text: String) -> String {
        let lowered = (language ?? "").lowercased()
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["diff", "patch"].contains(lowered) { return "diff" }
        if ["sh", "bash", "zsh", "shell", "console", "terminal"].contains(lowered) {
            return body.hasPrefix("git ") ? "git command" : "shell command"
        }
        if lowered.isEmpty {
            // Unlabelled fences are usually a command or a diff; both are
            // recognisable from the first line and neither should be read.
            if body.hasPrefix("diff ") || body.hasPrefix("--- ") || body.hasPrefix("+++ ") {
                return "diff"
            }
            if body.hasPrefix("git ") { return "git command" }
            if let first = body.split(separator: "\n").first,
               shellVerbs.contains(String(first.split(separator: " ").first ?? "")) {
                return "shell command"
            }
            return "code block"
        }
        return "\(lowered) block"
    }

    static let shellVerbs: Set<String> = [
        "git", "npm", "npx", "yarn", "pnpm", "cargo", "zig", "swift", "xcodebuild",
        "make", "cmake", "docker", "kubectl", "ssh", "scp", "rsync", "curl", "wget",
        "python", "python3", "pip", "pip3", "node", "deno", "bun", "go", "rustc",
        "brew", "apt", "sudo", "cd", "ls", "rm", "mv", "cp", "mkdir", "cat", "grep",
        "sed", "awk", "find", "chmod", "chown", "tar", "open", "defaults", "codesign",
    ]

    private static func spelled(_ count: Int) -> String {
        switch count {
        case 2: return "two"
        case 3: return "three"
        case 4: return "four"
        case 5: return "five"
        default: return "\(count)"
        }
    }

    /// One paragraph, with the parts nobody can pronounce turned into the
    /// short phrase a person would use instead.
    static func speakableProse(_ text: String) -> String {
        // A table is data, not a sentence. Naming its size beats reading a
        // hundred cells separated by commas, which is what used to happen.
        var lines: [String] = []
        var tableRows = 0
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") {
                if !OverviewMarkdownBlock.isTableSeparator(trimmed) { tableRows += 1 }
                continue
            }
            if tableRows > 0 {
                lines.append(tablePhrase(rows: tableRows))
                tableRows = 0
            }
            lines.append(line)
        }
        if tableRows > 0 { lines.append(tablePhrase(rows: tableRows)) }

        var value = lines.joined(separator: "\n")
        value = value.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // Inline code is judged span by span rather than stripped wholesale:
        // `retry` is a word, `git filter-repo --force` is not.
        value = replacingInlineCode(in: value)
        for marker in ["**", "__", "*", "_"] {
            value = value.replacingOccurrences(of: marker, with: "")
        }
        value = value.replacingOccurrences(
            of: #"(?m)^\s*(#{1,6}\s+|[-+•]\s+|>\s+|\d+\.\s+)"#,
            with: "", options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"https?://\S+"#, with: "a link", options: .regularExpression)
        // A bare token nobody could say out loud — a hash, a UUID, a base64
        // blob — is named or dropped rather than spelled.
        value = value.replacingOccurrences(
            of: #"(?<![\w/])[0-9a-fA-F]{7,40}(?![\w/])"#,
            with: "a commit", options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"\S{32,}"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tablePhrase(rows: Int) -> String {
        rows <= 1 ? "Then a table." : "Then a table of \(rows) rows."
    }

    /// Decide, per backticked span, whether it is a word or a machine.
    private static func replacingInlineCode(in text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "`") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "`") else {
                result += rest[open...]
                return result
            }
            result += spokenForm(of: String(rest[afterOpen..<close]))
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
    }

    /// What a backticked span becomes when spoken.
    static func spokenForm(of span: String) -> String {
        let value = span.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return "" }
        let words = value.split(separator: " ")
        let head = String(words.first ?? "")

        if head == "git" { return "a git command" }
        if shellVerbs.contains(head) { return "a command" }
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return "a link" }
        // A path: say the file, which is the part a person would say. The
        // character check is what stops a JSON blob — which also contains a
        // slash — from being read as its own last path component.
        if value.contains("/"), words.count == 1,
           value.range(of: #"^[A-Za-z0-9._/~\-]+$"#, options: .regularExpression) != nil {
            let last = value.split(separator: "/").last.map(String.init) ?? value
            return last.count <= 24 ? last : "a file"
        }
        if value.range(of: #"^[0-9a-fA-F]{7,40}$"#, options: .regularExpression) != nil {
            return "a commit"
        }
        // A short, wordy identifier is readable; a long or symbol-heavy one is
        // not, and there is no useful way to pronounce it.
        if value.count <= 24, words.count <= 3,
           value.range(of: #"^[A-Za-z0-9 _.\-]+$"#, options: .regularExpression) != nil {
            return value
        }
        return words.count > 1 ? "a command" : "a value"
    }

    static func plainProse(_ text: String) -> String {
        var value = text
        if value.contains("|") {
            value = value.components(separatedBy: "\n").compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("|") else { return line }
                if OverviewMarkdownBlock.isTableSeparator(trimmed) { return nil }
                let cells = OverviewMarkdownBlock.tableCells(trimmed).filter { !$0.isEmpty }
                return cells.joined(separator: ", ")
            }.joined(separator: "\n")
        }
        value = value.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression
        )
        for marker in ["**", "__", "`", "*", "_"] {
            value = value.replacingOccurrences(of: marker, with: "")
        }
        value = value.replacingOccurrences(
            of: #"(?m)^\s*(#{1,6}\s+|[-+•]\s+|>\s+|\d+\.\s+)"#,
            with: "", options: .regularExpression
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
