import SwiftUI

/// A small semi-transparent overlay at the bottom of a pane showing a live LLM summary.
struct LiveSummaryOverlayView: View {
    let summary: String
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }
            Text(summary)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.65))
        )
        .padding(8)
        .allowsHitTesting(false)
    }
}
