import SwiftUI

/// Maps subprocess plugin state updates to SwiftUI overlay views using the
/// fixed catalog of overlay templates. The host owns all rendering — plugins
/// only send data keyed by template name and pane index.
struct PluginOverlayState {
    var template: OverlayTemplate?
    var alignment: Alignment = .top
    /// Pane data keyed by pane index (as string from the wire protocol).
    var paneData: [String: PluginPaneValue] = [:]

    static let empty = PluginOverlayState()

    /// Returns a SwiftUI view for the given pane, or `nil` if there is no
    /// data for that pane or the template is unknown.
    func renderView(forPaneId paneId: Int) -> AnyView? {
        guard let template else { return nil }
        let key = String(paneId)
        guard let value = paneData[key] else { return nil }

        switch template {
        case .serverURLBanner:
            guard let urls = urlsFromValue(value), !urls.isEmpty else { return nil }
            return AnyView(
                ServerURLBannerView(urls: urls)
                    .padding(.top, 8)
            )

        case .attentionIcon:
            guard case .bool(true) = value else { return nil }
            return AnyView(
                ClaudeAttentionIconView()
                    .padding(.top, 8)
                    .padding(.leading, 8)
            )

        case .processPill:
            guard case .bool(true) = value else { return nil }
            return AnyView(
                SendTextIndicatorView()
                    .padding(.bottom, 8)
                    .padding(.leading, 8)
            )

        case .metricPill:
            guard case .strings(let parts) = value, parts.count >= 2 else { return nil }
            let color = parts.count >= 3 ? parts[2] : "gray"
            return AnyView(
                MetricPillView(label: parts[0], value: parts[1], colorName: color)
                    .padding(.top, 8)
                    .padding(.trailing, 8)
            )
        }
    }

    // MARK: - Value Helpers

    private func urlsFromValue(_ value: PluginPaneValue) -> [URL]? {
        switch value {
        case .strings(let arr):
            return arr.compactMap { URL(string: $0) }
        case .string(let s):
            return [URL(string: s)].compactMap { $0 }
        case .bool:
            return nil
        }
    }

    private func stringFromValue(_ value: PluginPaneValue) -> String? {
        switch value {
        case .string(let s): return s
        case .strings(let arr): return arr.first
        case .bool: return nil
        }
    }
}

// MARK: - Metric Pill

/// Generic label/value pill for the `metric_pill` template — the display
/// surface for quota/metric extensions (e.g. "ctx 42%").
struct MetricPillView: View {
    let label: String
    let value: String
    let colorName: String

    private var color: Color {
        switch colorName.lowercased() {
        case "green": return .green
        case "yellow", "orange": return .orange
        case "red": return .red
        default: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
    }
}
