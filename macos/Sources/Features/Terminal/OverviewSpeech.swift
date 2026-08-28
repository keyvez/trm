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

    var isActive: Bool { isSpeaking || isPreparing }

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var generationTask: Task<Void, Never>?
    private var requestID: UUID?
    private var pendingBuffers = 0
    private var streamEnded = false
    private var sampleRate: Double?

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
        generationTask = Task { [weak self] in
            do {
                for try await chunk in LocalNeuralSpeechEngine.shared.stream(trimmed) {
                    try Task.checkCancellation()
                    guard let self, self.requestID == id else { return }
                    try self.schedule(chunk)
                }
                guard let self, self.requestID == id else { return }
                self.streamEnded = true
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

        pendingBuffers += 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                self.finishIfDrained()
            }
        }
        if !playerNode.isPlaying { playerNode.play() }
        isPreparing = false
        isSpeaking = true
    }

    private func configureAudio(sampleRate: Double) throws {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw LocalNeuralSpeechEngine.SpeechError.render("Unsupported speech sample rate.")
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        self.audioEngine = engine
        self.playerNode = node
        self.sampleRate = sampleRate
    }

    private func finishIfDrained() {
        guard streamEnded, pendingBuffers == 0 else { return }
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
        sampleRate = nil
        pendingBuffers = 0
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

    /// All prose, retained for formatting tests. Playback uses the selective briefing above.
    static func spokenText(blocks: [AgentTranscript.Block]) -> String {
        blocks.compactMap { block -> String? in
            guard case .paragraph(let text) = block else { return nil }
            let cleaned = plainProse(text)
            return cleaned.isEmpty ? nil : cleaned
        }.joined(separator: "\n\n")
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
