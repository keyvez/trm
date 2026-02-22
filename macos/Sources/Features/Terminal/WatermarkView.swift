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

    private static let baselineOpacity: Double = 0.07
    private static let highlightOpacity: Double = 0.80

    @State private var opacity: Double = baselineOpacity

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.system(
                    size: cellHeight * 5.0,
                    weight: .bold,
                    design: .monospaced
                ))
                .foregroundColor(.primary.opacity(opacity))
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onReceive(NotificationCenter.default.publisher(for: Trm.highlightPane)) { notification in
                    guard let pid = notification.userInfo?["paneId"] as? Int,
                          pid == paneId else { return }
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
