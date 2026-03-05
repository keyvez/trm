import Foundation

/// Shared observable state for AI mode that persists between palette open/close cycles.
/// Lives on the controller so it survives palette dismissal.
@MainActor
final class CommandPaletteAIState: ObservableObject {
    @Published var isThinking = false
    @Published var responseText: String?
    @Published var streamingText: String = ""
    @Published var pendingActions: [TrmAction] = []
    @Published var statusMessages: [StatusMessage] = []
    @Published var isAgentActive = false
    var streamTask: Task<Void, Never>?

    struct StatusMessage: Identifiable {
        let id = UUID()
        let text: String
        let timestamp: Date = .now
    }

    func reset() {
        streamTask?.cancel()
        streamTask = nil
        isThinking = false
        responseText = nil
        streamingText = ""
        pendingActions = []
    }

    func appendStatus(_ text: String) {
        statusMessages.append(StatusMessage(text: text))
        // Cap at ~20 messages
        if statusMessages.count > 20 {
            statusMessages.removeFirst(statusMessages.count - 20)
        }
    }
}
