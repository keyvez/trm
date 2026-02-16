import SwiftUI

/// A compact pill overlay in the bottom-right corner showing Claude Code context window usage.
/// Tap to expand for detailed token counts, daily/weekly usage, and auto-compact warnings.
struct ContextUsageOverlayView: View {
    let usage: Trm.ContextUsageData
    let dailyTokensUsed: UInt64
    let weeklyTokensUsed: UInt64

    @State private var isExpanded = false
    @State private var pulseAnimation = false

    private var gaugeColor: Color {
        switch usage.warningLevel {
        case .normal: return .green
        case .elevated: return .yellow
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        Group {
            if isExpanded {
                expandedView
            } else {
                compactPill
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
        .onAppear {
            if usage.warningLevel == .critical {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulseAnimation = true
                }
            }
        }
        .onChange(of: usage.percentage) { newValue in
            let level = Trm.ContextWarningLevel(percentage: newValue)
            if level == .critical {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulseAnimation = true
                }
            } else {
                pulseAnimation = false
            }
        }
    }

    // MARK: - Compact Pill

    private var compactPill: some View {
        HStack(spacing: 6) {
            // Circular gauge
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 2.5)
                    .frame(width: 18, height: 18)
                Circle()
                    .trim(from: 0, to: CGFloat(usage.percentage) / 100.0)
                    .stroke(gaugeColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 18, height: 18)
            }

            Text("\(usage.percentage)%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))

            if usage.isPreCompact {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.7))
        )
        .overlay(
            Capsule()
                .stroke(gaugeColor.opacity(pulseAnimation ? 0.6 : 0.2), lineWidth: 1)
        )
        .opacity(pulseAnimation && usage.warningLevel == .critical ? 0.85 : 1.0)
        .padding(8)
    }

    // MARK: - Expanded View

    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "brain")
                    .font(.system(size: 12))
                    .foregroundColor(gaugeColor)
                Text("Context Usage")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text("\(usage.percentage)%")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(gaugeColor)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(gaugeColor)
                        .frame(width: geo.size.width * CGFloat(usage.percentage) / 100.0, height: 6)
                }
            }
            .frame(height: 6)

            // Token counts
            HStack {
                Text(usage.formattedTokens)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
            }

            Divider()
                .background(Color.white.opacity(0.2))

            // Daily / Weekly
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("24h")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                    Text(formatTokens(dailyTokensUsed))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("7d")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                    Text(formatTokens(weeklyTokensUsed))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                }
                Spacer()
            }

            // Pre-compact warning
            if usage.isPreCompact {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("Auto-compact imminent")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(12)
        .frame(width: 200)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(gaugeColor.opacity(0.3), lineWidth: 1)
        )
        .padding(8)
    }

    private func formatTokens(_ count: UInt64) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }
}
