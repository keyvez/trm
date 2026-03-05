import SwiftUI

/// Minimized floating pill at bottom-center shown when the command palette is dismissed
/// during an active AI task. Displays the latest status message from `CommandPaletteAIState`.
struct FloatingStatusBar: View {
    @ObservedObject var aiState: CommandPaletteAIState
    var onTap: () -> Void

    @State private var displayedMessage: CommandPaletteAIState.StatusMessage?
    @State private var hideTimer: Task<Void, Never>?

    var body: some View {
        VStack {
            Spacer()

            HStack {
                Spacer()

                if let msg = displayedMessage {
                    Button(action: onTap) {
                        HStack(spacing: 6) {
                            Text("\u{2726}")
                                .font(.system(size: 11))
                                .foregroundStyle(.purple)
                            Text(msg.text)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.purple.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .id(msg.id)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
                }

                Spacer()
            }
            .padding(.bottom, 16)
        }
        .animation(.spring(duration: 0.3), value: displayedMessage?.id)
        .onChange(of: aiState.statusMessages.last?.id) { _ in
            if let latest = aiState.statusMessages.last {
                displayedMessage = latest
                scheduleAutoHide()
            }
        }
        .onChange(of: aiState.isAgentActive) { active in
            if !active {
                scheduleAutoHide()
            }
        }
    }

    private func scheduleAutoHide() {
        hideTimer?.cancel()
        hideTimer = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            if !aiState.isAgentActive {
                await MainActor.run {
                    withAnimation {
                        displayedMessage = nil
                    }
                }
            }
        }
    }
}
