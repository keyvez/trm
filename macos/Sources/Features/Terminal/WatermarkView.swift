import SwiftUI

/// Renders a large, faint watermark label behind terminal content.
/// Displayed at 7% opacity so it's visible but doesn't interfere with reading.
/// Each instance observes `Trm.highlightPane` notifications directly and
/// flashes to 80% opacity when its own `paneId` is highlighted, giving users
/// a visual cue when a pane gains focus or is moved.
struct WatermarkView: View {
    let text: String
    let cellHeight: CGFloat
    let paneId: Int

    /// True while Cmd+Shift is held. The watermark normally sits at 0.07 —
    /// a background texture — so peeking has to override it outright rather
    /// than nudge it.
    var isPeeking: Bool = false

    private static let baselineOpacity: Double = 0.07
    private static let highlightOpacity: Double = 0.80
    private static let peekOpacity: Double = 0.95

    @State private var opacity: Double = baselineOpacity

    /// Opacity to draw at: peek wins over the transient highlight animation.
    private var effectiveOpacity: Double {
        isPeeking ? Self.peekOpacity : opacity
    }

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.system(
                    size: cellHeight * 5.0,
                    weight: .bold,
                    design: .monospaced
                ))
                .foregroundColor(.primary.opacity(effectiveOpacity))
                .animation(.easeOut(duration: 0.12), value: isPeeking)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onReceive(NotificationCenter.default.publisher(for: Trm.highlightPane)) { notification in
                    guard let pid = notification.userInfo?["paneId"] as? Int,
                          pid == paneId else { return }
                    flashHighlight()
                }
                .onReceive(NotificationCenter.default.publisher(for: Trm.hoverPane)) { notification in
                    guard let pid = notification.userInfo?["paneId"] as? Int,
                          pid == paneId,
                          notification.userInfo?["hovering"] as? Bool == true else { return }
                    flashHighlight()
                }
                .onAppear {
                    opacity = Self.baselineOpacity
                }
        }
    }

    private func flashHighlight() {
        withAnimation(.easeIn(duration: 0.08)) {
            opacity = Self.highlightOpacity
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.6)) {
                opacity = Self.baselineOpacity
            }
        }
    }
}
