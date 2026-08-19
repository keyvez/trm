import AVFoundation

/// Speaks an overview reply aloud using the best speech voice installed on
/// this Mac. Apple's premium/enhanced neural voices (downloaded via System
/// Settings → Accessibility → Spoken Content) are fully local — the
/// synthesizer never touches the network — and the ranking below picks the
/// highest-quality one automatically, so a Mac with a premium voice sounds
/// like a person, and every Mac at least gets the system default.
@MainActor
final class OverviewSpeaker: NSObject, ObservableObject {
    /// Drives the header button's icon (speaker vs stop).
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speak `text`, or stop if already speaking — one button does both.
    func toggle(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            isSpeaking = false
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.bestVoice()
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// The highest-quality installed voice for the user's language: premium
    /// beats enhanced beats compact, and an exact locale match breaks ties.
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let locale = AVSpeechSynthesisVoice.currentLanguageCode()
        let base = locale.prefix(2)

        func score(_ voice: AVSpeechSynthesisVoice) -> Int {
            var value: Int
            switch voice.quality {
            case .premium: value = 20
            case .enhanced: value = 10
            default: value = 0
            }
            if voice.language == locale { value += 1 }
            return value
        }

        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(base) }
        guard let best = candidates.max(by: { score($0) < score($1) }) else {
            return AVSpeechSynthesisVoice(language: nil)
        }
        return best
    }

    /// The reply as natural speech: prose paragraphs with markdown markers
    /// stripped. Code blocks and images are skipped — hearing symbols read
    /// character by character is noise, and the pane is right there to read.
    static func spokenText(blocks: [AgentTranscript.Block]) -> String {
        blocks.compactMap { block -> String? in
            guard case .paragraph(let text) = block else { return nil }
            let cleaned = plainProse(text)
            return cleaned.isEmpty ? nil : cleaned
        }.joined(separator: "\n\n")
    }

    /// Strip inline markdown down to what should be pronounced.
    static func plainProse(_ text: String) -> String {
        var value = text
        // Table rows speak as comma-separated cells; separator rows are
        // punctuation, not content.
        if value.contains("|") {
            value = value.components(separatedBy: "\n").compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("|") else { return line }
                if OverviewMarkdownBlock.isTableSeparator(trimmed) { return nil }
                let cells = OverviewMarkdownBlock.tableCells(trimmed).filter { !$0.isEmpty }
                return cells.joined(separator: ", ")
            }.joined(separator: "\n")
        }
        // [title](url) → title
        value = value.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression
        )
        // Emphasis and code markers.
        for marker in ["**", "__", "`", "*", "_"] {
            value = value.replacingOccurrences(of: marker, with: "")
        }
        // Leading heading/bullet/quote markers, per line.
        value = value.replacingOccurrences(
            of: #"(?m)^\s*(#{1,6}\s+|[-+•]\s+|>\s+|\d+\.\s+)"#,
            with: "", options: .regularExpression
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension OverviewSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
