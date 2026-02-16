import SwiftUI

/// Renders a large, faint watermark label behind terminal content.
/// Displayed at 7% opacity so it's visible but doesn't interfere with reading.
struct WatermarkView: View {
    let text: String
    let cellHeight: CGFloat

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.system(
                    size: cellHeight * 5.0,
                    weight: .bold,
                    design: .monospaced
                ))
                .foregroundColor(.primary.opacity(0.07))
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
