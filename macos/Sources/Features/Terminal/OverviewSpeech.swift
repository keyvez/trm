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
        /// Index into the segments the request asked for. Which words are
        /// sounding right now is not recoverable from elapsed time alone.
        let segment: Int
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
    /// Render `segments` in order, streaming audio as it is made.
    ///
    /// Segmentation belongs to the app rather than the worker now. The worker
    /// could split the text itself and did, but then only the worker knew
    /// where the seams were — and the app is the side that has to say which
    /// sentence is sounding, and which sentences a resumed reading has
    /// already been through.
    func stream(
        segments: [String], direction: String? = nil
    ) -> AsyncThrowingStream<Chunk, Error> {
        let id = UUID().uuidString
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] reason in
                self?.queue.async {
                    // Already gone means the worker finished this request and
                    // said so; there is nothing left to call off.
                    guard self?.streams.removeValue(forKey: id) != nil else { return }
                    guard case .cancelled = reason else { return }
                    // Dropping our end of the stream is not enough. The worker
                    // renders one request at a time and does not look at the
                    // next one until the current one is done, so a reading
                    // nobody is listening to still has to finish before the
                    // next press of play is even read. Tell it to stop.
                    try? self?.send(["id": id, "cancel": true])
                }
            }
            queue.async { [weak self] in
                guard let self else {
                    continuation.finish(throwing: SpeechError.render("Speech engine closed."))
                    return
                }
                do {
                    try self.ensureProcess()
                    self.streams[id] = continuation
                    var request: [String: Any] = [
                        "id": id,
                        // `text` stays for a worker that predates segments.
                        "text": segments.joined(separator: " "),
                        "segments": segments,
                    ]
                    if let direction, !direction.isEmpty {
                        request["instruct"] = direction
                    }
                    try self.send(request)
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

    private func send(_ object: [String: Any]) throws {
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
                let segment = (object["segment"] as? NSNumber)?.intValue ?? 0
                continuation.yield(
                    Chunk(pcm16: pcm, sampleRate: rate, segment: segment))
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

/// The one reading that is playing right now, wherever it started.
///
/// A reading outlives the panel it was started from. Peeking a terminal opens
/// an overview to peek alongside it, and Escape closes that overview again —
/// which used to take the voice with it, because the speaker was owned by the
/// pane and nothing else held it. Pressing Escape means "put this view away",
/// never "stop talking": you dismiss a peek to get back to your grid, often
/// *because* you would rather listen than read.
///
/// So the reading is held here for as long as it lasts, and the Command
/// Center draws the controls for it at the top of the board. The pane it came
/// from may be gone; the voice, the scrubber and the speed are not.
@MainActor
final class SpeechNowPlaying: ObservableObject {
    static let shared = SpeechNowPlaying()

    /// The speaker currently reading, held strongly — this reference is what
    /// keeps a reading alive once its overview has closed.
    @Published private(set) var speaker: OverviewSpeaker?

    /// What is being read, for the bar that offers to stop it. A reading with
    /// no name attached to it is a mystery noise with a stop button.
    @Published private(set) var label: String = ""

    /// The pane whose overview started it, so reopening that overview adopts
    /// the reading already in progress instead of showing a play button for
    /// audio that is audibly already playing.
    private(set) var paneId: Int?

    private init() {}

    func begin(_ speaker: OverviewSpeaker, label: String, paneId: Int?) {
        self.speaker = speaker
        self.label = label
        self.paneId = paneId
    }

    /// Clear, but only if `speaker` is still the one playing. A reading that
    /// ends after another has started must not silence the newer one's
    /// controls.
    func end(_ speaker: OverviewSpeaker) {
        guard self.speaker === speaker else { return }
        self.speaker = nil
        self.label = ""
        self.paneId = nil
    }

    /// The reading already running for this pane, if there is one.
    func adopt(paneId: Int?) -> OverviewSpeaker? {
        guard let paneId, self.paneId == paneId, let speaker, speaker.isActive else {
            return nil
        }
        return speaker
    }

    /// Keep the name current: a pane renamed mid-reading should not leave a
    /// stale label sitting over the controls.
    func relabel(_ speaker: OverviewSpeaker, to label: String) {
        guard self.speaker === speaker, !label.isEmpty, label != self.label else { return }
        self.label = label
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

    /// The stretch of the reading being spoken right now, as a range into the
    /// reading text — what the view underlines so you can follow along.
    ///
    /// Nil when nothing is playing, and nil rather than stale when playback
    /// has run past what has been rendered.
    @Published private(set) var spokenRange: Range<String.Index>?

    /// The reading this speaker is part-way through, kept while paused.
    ///
    /// Stopping used to throw the reading away, so pressing play again started
    /// the whole reply from the top — which for a four-minute reply means
    /// hearing three minutes you have already heard to get back to where you
    /// were. Stop is a pause now: the text, the audio already made, and the
    /// position in it are all still here.
    private(set) var reading: Reading?

    /// A reading, cut into the pieces the worker renders one at a time.
    struct Reading: Equatable {
        let text: String
        let direction: String?
        /// Each segment's text, and where it sits in `text`, so the spoken
        /// segment can be pointed at in the original.
        let segments: [Segment]

        struct Segment: Equatable {
            let text: String
            let range: Range<String.Index>
        }
    }

    var isActive: Bool { isSpeaking || isPreparing }

    /// The words being spoken right now, for the view to find and mark.
    ///
    /// The text rather than the range, because the view is not showing the
    /// reading — it is showing the reply the reading was made from, styled,
    /// with the markdown taken off. Both sides have had the markers stripped,
    /// so the sentence can be looked up in what is on screen; an offset into
    /// the reading would point at the wrong characters entirely.
    var spokenText: String? {
        guard let reading, let spokenRange else { return nil }
        let text = String(reading.text[spokenRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    var canSeek: Bool { !buffers.isEmpty }

    /// What to call this reading where it is offered without its overview —
    /// the pane's watermark, kept current by the owning pane. Set before
    /// `toggle`, so the reading is named the moment it starts.
    var sourceLabel: String = "Agent Overview" {
        didSet { SpeechNowPlaying.shared.relabel(self, to: sourceLabel) }
    }

    /// The pane this reading belongs to, so reopening that pane's overview
    /// finds the reading rather than starting a second one.
    var sourcePaneId: Int?

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

    /// Which segment each buffer came from, parallel to `buffers`. Elapsed
    /// time says how far in you are; this says what you are hearing.
    private var bufferSegments: [Int] = []

    /// How many of the reading's segments the worker has finished. A resumed
    /// reading asks only for the ones after this.
    private var renderedSegments = 0

    /// Where a paused reading left off, in seconds.
    private var pausedAt: TimeInterval = 0

    override init() {
        super.init()
        LocalNeuralSpeechEngine.shared.prewarm()
    }

    func toggle(_ text: String, direction: String? = nil) {
        if isActive {
            pause()
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Same words as the reading we paused? Then this is "carry on", not
        // "read it to me again". A reply that has changed underneath us is a
        // different reading and starts from the top.
        if let reading, reading.text == trimmed, !buffers.isEmpty {
            resume()
            return
        }
        start(Self.reading(of: trimmed, direction: direction))
    }

    /// Cut a reading into segments the worker renders one at a time.
    ///
    /// Sentences grouped up to a limit, which is what the worker used to do
    /// for itself — a call has fixed overhead, and one per "Yes." would spend
    /// more time starting than speaking. The limit is smaller than the
    /// worker's old 320 because a segment is also the unit that gets
    /// highlighted, and three sentences lighting up at once is not following
    /// along. It is not one sentence either: sentences synthesised entirely
    /// alone lose the prosody that carries across a full stop.
    static func reading(of text: String, direction: String?) -> Reading {
        var segments: [Reading.Segment] = []
        var current: Range<String.Index>?

        for sentence in speechSentenceRanges(in: text) {
            guard let open = current else { current = sentence; continue }
            let joined = open.lowerBound..<sentence.upperBound
            if text.distance(from: joined.lowerBound, to: joined.upperBound) <= segmentLimit {
                current = joined
            } else {
                segments.append(.init(text: String(text[open]), range: open))
                current = sentence
            }
        }
        if let open = current {
            segments.append(.init(text: String(text[open]), range: open))
        }
        if segments.isEmpty {
            segments = [.init(text: text, range: text.startIndex..<text.endIndex)]
        }
        return Reading(text: text, direction: direction, segments: segments)
    }

    /// Characters per segment. Roughly a sentence or two of ordinary prose.
    static let segmentLimit = 160

    private func start(_ reading: Reading) {
        self.reading = reading
        renderedSegments = 0
        buffers = []
        bufferSegments = []
        cursor = 0
        playedSeconds = 0
        pausedAt = 0
        elapsed = 0
        rendered = 0
        spokenRange = nil
        render(from: 0)
    }

    /// Ask the worker for the reading from `segment` on, and play what comes.
    private func render(from segment: Int) {
        guard let reading, segment < reading.segments.count else {
            // Nothing left to make: what is already here is the whole thing.
            streamEnded = true
            isComplete = true
            finishIfDrained()
            return
        }

        let id = UUID()
        requestID = id
        isPreparing = true
        lastError = nil
        streamEnded = false
        pendingBuffers = 0
        isComplete = false
        let wanted = Array(reading.segments[segment...]).map(\.text)
        // Held for as long as it plays, so closing the overview that started
        // it — Escape on a peek, most often — does not deallocate the voice.
        SpeechNowPlaying.shared.begin(self, label: sourceLabel, paneId: sourcePaneId)
        generationTask = Task { [weak self] in
            do {
                for try await chunk in LocalNeuralSpeechEngine.shared.stream(
                    segments: wanted, direction: reading.direction) {
                    try Task.checkCancellation()
                    guard let self, self.requestID == id else { return }
                    // The worker numbers from the start of what it was asked
                    // for; a resumed reading asked for a tail of the whole.
                    try self.schedule(chunk, segment: segment + chunk.segment)
                }
                guard let self, self.requestID == id else { return }
                self.streamEnded = true
                self.isComplete = true
                self.renderedSegments = self.reading?.segments.count ?? self.renderedSegments
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
                SpeechNowPlaying.shared.end(self)
            }
        }
    }

    /// Stop speaking, and remember where.
    ///
    /// The audio already made is kept, along with the position in it, so
    /// pressing play again carries on rather than reading the whole reply
    /// from the top. The worker is still told to stop — there is no point
    /// synthesising into a void — and what it had not reached yet is asked
    /// for again on resume.
    func pause() {
        requestID = nil
        generationTask?.cancel()
        generationTask = nil
        pausedAt = playedSeconds
        // Only the engine goes; the buffers are the reading.
        releaseEngine()
        dropUnfinishedSegment()
        isPreparing = false
        isSpeaking = false
        spokenRange = nil
        SpeechNowPlaying.shared.end(self)
    }

    /// Throw away the audio of a segment the worker was cut off partway
    /// through.
    ///
    /// Cancelling stops the render mid-segment, so the last segment's audio is
    /// a fragment. Resuming asks for that segment again — whole — and without
    /// this the fragment would still be sitting in front of it and you would
    /// hear the first half of the sentence twice. Dropping it also puts the
    /// resume point on a sentence boundary, which is where you want to be
    /// picked up anyway.
    private func dropUnfinishedSegment() {
        guard !isComplete, let last = bufferSegments.last else { return }
        while let owner = bufferSegments.last, owner == last {
            let dropped = buffers.removeLast()
            bufferSegments.removeLast()
            rendered -= Double(dropped.frameLength) / dropped.format.sampleRate
        }
        renderedSegments = last
        rendered = max(0, rendered)
        pausedAt = min(pausedAt, rendered)
        cursor = min(cursor, buffers.count)
    }

    /// Pick a paused reading back up where it left off.
    private func resume() {
        guard reading != nil else { return }
        let target = min(pausedAt, rendered)
        var index = 0
        var seconds: TimeInterval = 0
        while index < buffers.count {
            let length = Double(buffers[index].frameLength) / buffers[index].format.sampleRate
            if seconds + length > target { break }
            seconds += length
            index += 1
        }
        cursor = index
        playedSeconds = seconds
        elapsed = seconds
        updateSpokenRange()
        // Everything up to here is already in hand; ask only for the rest.
        render(from: renderedSegments)
    }

    /// Throw the reading away as well as the audio. The reading is finished,
    /// or is being replaced, and there is nothing to come back to.
    func stop() {
        requestID = nil
        generationTask?.cancel()
        generationTask = nil
        stopAudio()
        reading = nil
        renderedSegments = 0
        pausedAt = 0
        isPreparing = false
        isSpeaking = false
        SpeechNowPlaying.shared.end(self)
    }

    private func schedule(
        _ chunk: LocalNeuralSpeechEngine.Chunk, segment: Int
    ) throws {
        if sampleRate != chunk.sampleRate || audioEngine == nil {
            // A resumed reading needs an engine again, and its buffers are
            // the point — building one must not throw them away.
            let keep = buffers.isEmpty ? nil : (buffers, bufferSegments, cursor, playedSeconds)
            stopAudio()
            try configureAudio(sampleRate: chunk.sampleRate)
            if let (saved, owners, at, played) = keep {
                buffers = saved
                bufferSegments = owners
                cursor = at
                playedSeconds = played
                elapsed = played
                rendered = saved.reduce(0) {
                    $0 + Double($1.frameLength) / $1.format.sampleRate
                }
            }
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
        bufferSegments.append(segment)
        // The worker only moves to the next segment once this one is done, so
        // seeing a chunk of segment N means every segment before it is made.
        renderedSegments = max(renderedSegments, segment)
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
                self.updateSpokenRange()
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
        updateSpokenRange()
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
        SpeechNowPlaying.shared.end(self)
    }

    /// Tear down the engine but keep the audio. Pausing wants this: the
    /// buffers are the reading, and rebuilding them costs a re-render.
    private func releaseEngine() {
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        timePitch = nil
        sampleRate = nil
        pendingBuffers = 0
    }

    private func stopAudio() {
        releaseEngine()
        buffers = []
        bufferSegments = []
        cursor = 0
        playedSeconds = 0
        elapsed = 0
        rendered = 0
        spokenRange = nil
    }

    /// The stretch of the reading being spoken at `playedSeconds`.
    ///
    /// The segment is known exactly — every buffer is stamped with the one it
    /// came from. Where inside the segment is an estimate: speech takes about
    /// as long as its characters are many, so the elapsed fraction of the
    /// segment's audio picks the sentence at that fraction of its text. Good
    /// to well within a sentence, which is all the eye needs to follow along.
    private func updateSpokenRange() {
        guard let reading, !buffers.isEmpty, !bufferSegments.isEmpty else {
            spokenRange = nil
            return
        }
        // Which buffer is sounding. Not `cursor` — that is the next buffer to
        // hand to the node, and it runs ahead of the speaker by whatever is
        // queued.
        var index = 0
        var start: TimeInterval = 0
        while index < buffers.count - 1 {
            let length = Double(buffers[index].frameLength) / buffers[index].format.sampleRate
            if start + length > elapsed { break }
            start += length
            index += 1
        }
        guard index < bufferSegments.count else { spokenRange = nil; return }
        let segment = bufferSegments[index]
        guard segment < reading.segments.count else { spokenRange = nil; return }

        // Where this segment's audio begins, and how long it runs.
        var segmentStart: TimeInterval = 0
        var segmentLength: TimeInterval = 0
        for (position, owner) in bufferSegments.enumerated() {
            let length = Double(buffers[position].frameLength)
                / buffers[position].format.sampleRate
            if owner < segment {
                segmentStart += length
            } else if owner == segment {
                segmentLength += length
            }
        }

        let whole = reading.segments[segment].range
        let sentences = Self.speechSentenceRanges(in: reading.text, within: whole)
        guard sentences.count > 1, segmentLength > 0 else {
            spokenRange = whole
            return
        }
        let fraction = min(max((elapsed - segmentStart) / segmentLength, 0), 1)
        let span = reading.text.distance(from: whole.lowerBound, to: whole.upperBound)
        let mark = reading.text.index(
            whole.lowerBound,
            offsetBy: Int((Double(span) * fraction).rounded(.down)),
            limitedBy: whole.upperBound) ?? whole.upperBound
        spokenRange = sentences.first { $0.upperBound > mark } ?? sentences.last
    }

    // MARK: - How it should sound

    /// The mood a reading is delivered in, and what earns it.
    ///
    /// A reader that says "the test failed for the fourth time" in the same
    /// bright tone it used for "every test passes" is reading words rather
    /// than telling you something. The point of hearing a reply instead of
    /// reading it is that you are doing something else — so the tone has to
    /// carry the part you would have seen at a glance.
    ///
    /// Deliberately a small vocabulary, and deliberately *slight*. An agent
    /// that sounds distraught about a lint warning is worse than a flat one:
    /// you stop believing the tone, and then it carries nothing.
    enum Mood: String, CaseIterable {
        case neutral
        /// The same thing has failed again, and again. This is the one the
        /// tone is really for — repetition is invisible in any single
        /// sentence and obvious across a session.
        case frustrated
        case concerned
        case pleased
        case asking

        /// Appended to the voice description. The description itself never
        /// changes, so the speaker stays the same person and only the
        /// delivery moves.
        var direction: String {
            switch self {
            case .neutral: return ""
            case .frustrated:
                return " Sounding a little tired and frustrated — this has gone wrong before."
            case .concerned:
                return " Sounding mildly concerned, careful about what it found."
            case .pleased:
                return " Sounding quietly pleased and relieved."
            case .asking:
                return " Sounding like someone putting a question to you and waiting."
            }
        }
    }

    /// How many times one thing has to fail before it stops being bad luck.
    ///
    /// Two is a retry. Three is a pattern, and the point at which a person
    /// reading this out would start to sound like they had had enough.
    private static let repetitionThreshold = 3

    /// The complete direction for a reading: a fixed voice plus a mood.
    static func direction(for transcript: AgentTranscript, reading: String) -> String {
        baseVoice + mood(for: transcript, reading: reading).direction
    }

    /// The voice itself, which never varies. Kept apart from the mood so that
    /// a change of mood cannot turn into a change of speaker.
    static let baseVoice =
        "A calm, clear voice giving a concise engineering update. Natural, measured delivery."

    /// Pick the mood for a reading.
    ///
    /// Ordered by what a person would react to most strongly, and the first
    /// match wins: being stuck beats a single failure, a single failure beats
    /// good news, and a question you are being asked outranks all of it
    /// because it is the only one that is about *you*.
    static func mood(for transcript: AgentTranscript, reading: String) -> Mood {
        if transcript.questions.contains(where: { !$0.finished }) { return .asking }
        if isStuck(transcript) { return .frustrated }

        let text = reading.lowercased()
        if transcript.activity.contains(where: \.isError) || mentions(text, failureWords) {
            return .concerned
        }
        if mentions(text, successWords) { return .pleased }
        return .neutral
    }

    /// Is the agent going round in circles?
    ///
    /// Counting errors is not enough — five different failures is a bad
    /// afternoon, but the *same* failure five times is being stuck, and only
    /// the second one is worth a change of tone. So failures are grouped by
    /// the tool and the shape of the error rather than counted in bulk.
    static func isStuck(_ transcript: AgentTranscript) -> Bool {
        var counts: [String: Int] = [:]
        for call in transcript.activity where call.isError {
            let key = call.name + "\u{1}" + errorShape(call.errorText ?? call.detail ?? "")
            counts[key, default: 0] += 1
            if counts[key]! >= repetitionThreshold { return true }
        }
        return false
    }

    /// Reduce an error to the part that repeats.
    ///
    /// The same failure rarely arrives as the same string: line numbers,
    /// paths, durations and pids move between attempts. Stripping digits and
    /// keeping the opening words leaves what actually recurs, so "3 tests
    /// failed in 4.1s" and "3 tests failed in 3.8s" count as one thing.
    private static func errorShape(_ text: String) -> String {
        let lowered = text.lowercased()
        let letters = lowered.map { $0.isNumber ? "#" : $0 }
        return String(String(letters).prefix(60))
    }

    private static func mentions(_ text: String, _ words: [String]) -> Bool {
        words.contains { text.contains($0) }
    }

    /// Words that mean something went wrong, in the vocabulary agents
    /// actually use. Present tense only: "fixing the error" is not an error.
    private static let failureWords = [
        "failed", "failing", "error", "errors", "exception", "crash",
        "broken", "cannot ", "could not", "timed out", "rejected", "denied",
    ]

    private static let successWords = [
        "passes", "passed", "fixed", "works", "working now", "succeeded",
        "all green", "landed", "no errors", "builds clean", "done",
    ]

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

    /// Sentence ranges, into the string they came from.
    ///
    /// The by-string version above copies what it finds, which is fine for
    /// choosing what to say and useless for pointing at it: a highlight needs
    /// to know where in the original the sentence sits, not what it said.
    static func speechSentenceRanges(
        in text: String, within bounds: Range<String.Index>? = nil
    ) -> [Range<String.Index>] {
        let scope = bounds ?? text.startIndex..<text.endIndex
        guard !text.isEmpty, scope.lowerBound < scope.upperBound else { return [] }
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(
            in: scope, options: [.bySentences, .localized]
        ) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges.isEmpty ? [scope] : ranges
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
        value = spokenNumbers(value)
        value = value.replacingOccurrences(
            of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Money, magnitudes and ranges, put the way a person says them.
    ///
    /// "$15-45k" is four problems in seven characters: a symbol spoken *after*
    /// the number it sits before, a dash that means "to" and not "minus", a
    /// magnitude letter belonging to both numbers rather than the one it
    /// touches, and an order that has to be rebuilt instead of read left to
    /// right. Synthesisers guess at it, and guess differently each time — the
    /// reason a figure in a reply came out as noise exactly when it was the
    /// part you were listening for.
    ///
    /// Digits are left as digits, which every voice reads correctly. Only the
    /// symbols and the shape are rewritten.
    /// - Parameter bareMagnitudes: also expand a magnitude letter with no
    ///   currency in front of it, as in "45k". Only safe where the span is
    ///   known to be a figure and nothing else — in running prose "3M" is as
    ///   likely to be three megabytes as three million.
    static func spokenNumbers(_ text: String, bareMagnitudes: Bool = false) -> String {
        var value = text
        // Ranges first: "$15-45k" has to be seen whole, or the single-amount
        // rule below would take "$15" and leave "-45k" stranded behind it.
        value = rewrite(value, #"([$£€])\s*(\d[\d,]*(?:\.\d+)?)(?:\s*([kKmMbB])\b)?\s*(?:[-–—]|\s+to\s+)\s*[$£€]?\s*(\d[\d,]*(?:\.\d+)?)(?:\s*([kKmMbB])\b)?"#) { g in
            let currency = currencyWord(g[1])
            let first = number(g[2]), second = number(g[4])
            // A magnitude written once governs both ends: in "$15-45k" the
            // fifteen is fifteen thousand, not fifteen.
            let firstUnit = magnitudeWord(g[3]) ?? magnitudeWord(g[5])
            let secondUnit = magnitudeWord(g[5]) ?? magnitudeWord(g[3])
            if firstUnit == secondUnit {
                return [first, "to", second, firstUnit, currency]
                    .compactMap { $0 }.joined(separator: " ")
            }
            return [first, firstUnit, "to", second, secondUnit, currency]
                .compactMap { $0 }.joined(separator: " ")
        }
        // A single amount: "$15k", "£200".
        value = rewrite(value, #"([$£€])\s*(\d[\d,]*(?:\.\d+)?)(?:\s*([kKmMbB])\b)?"#) { g in
            [number(g[2]), magnitudeWord(g[3]), currencyWord(g[1])]
                .compactMap { $0 }.joined(separator: " ")
        }
        if bareMagnitudes {
            value = rewrite(value, #"(\d[\d,]*(?:\.\d+)?)\s*([kKmMbB])\b"#) { g in
                [number(g[1]), magnitudeWord(g[2])].compactMap { $0 }.joined(separator: " ")
            }
        }
        // "10-20%" has the same dash-means-to problem without the symbol.
        value = rewrite(value, #"(\d[\d,]*(?:\.\d+)?)\s*[-–—]\s*(\d[\d,]*(?:\.\d+)?)\s*%"#) { g in
            "\(number(g[1]) ?? "") to \(number(g[2]) ?? "") percent"
        }
        return value
    }

    /// Replace every match, newest first so earlier ranges stay valid, handing
    /// the capture groups to `body` as strings (nil where the group is absent).
    private static func rewrite(
        _ text: String, _ pattern: String, _ body: ([Int: String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var value = text
        let whole = NSRange(value.startIndex..., in: value)
        for match in regex.matches(in: value, range: whole).reversed() {
            var groups: [Int: String] = [:]
            for index in 1..<match.numberOfRanges {
                if let range = Range(match.range(at: index), in: value) {
                    groups[index] = String(value[range])
                }
            }
            guard let range = Range(match.range, in: value) else { continue }
            value.replaceSubrange(range, with: body(groups))
        }
        return value
    }

    private static func number(_ raw: String?) -> String? {
        // Thousands separators are for the eye. "15,000" spoken as written
        // invites a pause in the middle of one number.
        raw?.replacingOccurrences(of: ",", with: "")
    }

    private static func currencyWord(_ symbol: String?) -> String? {
        switch symbol {
        case "$": return "dollars"
        case "£": return "pounds"
        case "€": return "euros"
        default: return nil
        }
    }

    private static func magnitudeWord(_ letter: String?) -> String? {
        switch letter?.lowercased() {
        case "k": return "thousand"
        case "m": return "million"
        case "b": return "billion"
        default: return nil
        }
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

        // A figure in backticks is a figure, not a machine. Agents write
        // amounts in code spans constantly, and every one of them used to
        // fall all the way through to "a value" — the least useful thing
        // that can be said about the number you are being asked to react to.
        if value.range(
            of: #"^[$£€]?\d[\d,]*(?:\.\d+)?\s*[kKmMbB]?(?:\s*(?:[-–—]|to)\s*[$£€]?\d[\d,]*(?:\.\d+)?\s*[kKmMbB]?)?%?$"#,
            options: .regularExpression) != nil {
            return spokenNumbers(value, bareMagnitudes: true)
        }

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
        return spokenNumbers(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
