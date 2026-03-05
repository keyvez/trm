import SwiftUI

/// Vertical marquee that shows one shortcut at a time, cycling every 3 seconds.
/// The old shortcut slides up and out while the new one slides in from below.
struct ShortcutExtractorOverlayView: View {
    let shortcuts: [ExtractedShortcut]
    let onExecute: (ExtractedShortcut) -> Void

    @State private var currentIndex: Int = 0
    @State private var timer: Timer?

    private var current: ExtractedShortcut {
        shortcuts[currentIndex % shortcuts.count]
    }

    var body: some View {
        if shortcuts.count == 1 {
            ShortcutPill(
                shortcut: shortcuts[0],
                onExecute: { onExecute(shortcuts[0]) }
            )
        } else if shortcuts.count > 1 {
            // Fixed-height container clips the slide animation.
            ZStack {
                ShortcutPill(
                    shortcut: current,
                    onExecute: { onExecute(current) }
                )
                .id(current.id)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
            }
            .frame(height: 24)
            .clipped()
            .animation(.easeInOut(duration: 0.35), value: currentIndex)
            .onAppear { startTimer() }
            .onDisappear { stopTimer() }
            .onChange(of: shortcuts.count) { _ in
                if currentIndex >= shortcuts.count {
                    currentIndex = 0
                }
            }
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in
                withAnimation {
                    currentIndex = (currentIndex + 1) % shortcuts.count
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// A single shortcut pill: indigo-tinted button showing the key character
/// in a small rounded square, with the label beside it.
struct ShortcutPill: View {
    let shortcut: ExtractedShortcut
    let onExecute: () -> Void

    @State private var isHovering = false

    private static let pillColor = Color.indigo

    var body: some View {
        Button(action: onExecute) {
            HStack(spacing: 4) {
                Text(shortcut.key)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 16, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.2))
                    )
                Text(shortcut.label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Self.pillColor.opacity(isHovering ? 1.0 : 0.75))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .help(shortcut.label)
    }
}
