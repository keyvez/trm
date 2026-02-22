import SwiftUI

/// Renders a large, faint watermark label behind terminal content.
/// Displayed at 7% opacity so it's visible but doesn't interfere with reading.
/// When `highlighted` is true, the watermark briefly flashes to 80% opacity
/// and animates back to baseline, giving users a visual cue when a pane
/// gains focus.
struct WatermarkView: View {
    let text: String
    let cellHeight: CGFloat
    var highlighted: Bool = false

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
                .onChange(of: highlighted) { isHighlighted in
                    if isHighlighted {
                        flashHighlight()
                    }
                }
                .onAppear {
                    if highlighted {
                        flashHighlight()
                    }
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
