import Foundation
import SwiftUI

// MARK: - Host → Plugin Messages

/// Messages sent from the host process to a subprocess plugin over stdin.
enum HostMessage: Encodable {
    case configure(config: HostConfigPayload)
    case start
    case terminalOutput(pane: Int, text: String, hash: String)
    case paneClosed(pane: Int)
    case notification(name: String, pane: Int)
    case commandFinished(pane: Int)
    case contextUsage(usedTokens: UInt64, totalTokens: UInt64, percentage: Int, sessionId: String)
    case stop

    private enum CodingKeys: String, CodingKey {
        case type, config, pane, text, hash, name
        case usedTokens = "used_tokens"
        case totalTokens = "total_tokens"
        case percentage
        case sessionId = "session_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .configure(let config):
            try container.encode("configure", forKey: .type)
            try container.encode(config, forKey: .config)
        case .start:
            try container.encode("start", forKey: .type)
        case .terminalOutput(let pane, let text, let hash):
            try container.encode("terminal_output", forKey: .type)
            try container.encode(pane, forKey: .pane)
            try container.encode(text, forKey: .text)
            try container.encode(hash, forKey: .hash)
        case .paneClosed(let pane):
            try container.encode("pane_closed", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .notification(let name, let pane):
            try container.encode("notification", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(pane, forKey: .pane)
        case .commandFinished(let pane):
            try container.encode("command_finished", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .contextUsage(let used, let total, let pct, let sessionId):
            try container.encode("context_usage", forKey: .type)
            try container.encode(used, forKey: .usedTokens)
            try container.encode(total, forKey: .totalTokens)
            try container.encode(pct, forKey: .percentage)
            try container.encode(sessionId, forKey: .sessionId)
        case .stop:
            try container.encode("stop", forKey: .type)
        }
    }
}

/// Configuration payload sent with the `configure` message.
struct HostConfigPayload: Codable {
    var patterns: [String]?
}

// MARK: - Plugin → Host Messages

/// Messages received from a subprocess plugin over stdout.
struct PluginMessage: Decodable {
    let type: MessageType
    let overlay: String?
    let alignment: String?
    let panes: [String: PluginPaneValue]?
    let message: String?
    /// Action requests (type == .action). Each entry mirrors the TrmAction
    /// wire schema used by the LLM path: {"type": "send_command", ...}.
    let actions: [PluginActionPayload]?

    enum MessageType: String, Decodable {
        case ready
        case state
        case error
        case action
    }
}

/// One action requested by a subprocess plugin. Same wire vocabulary as the
/// LLM response actions; mapped to `TrmAction` and capability-gated by the
/// host before execution.
struct PluginActionPayload: Decodable {
    let type: String
    let pane: Int?
    let command: String?
    let title: String?
    let watermark: String?
    let text: String?
    let body: String?
    let url: String?
}

/// A pane value from the plugin can be a bool, a string, or an array of strings.
/// This covers the data shapes used by all built-in overlay templates.
enum PluginPaneValue: Decodable, Equatable {
    case bool(Bool)
    case string(String)
    case strings([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([String].self) {
            self = .strings(arr)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Pane value must be bool, string, or [string]"
            )
        }
    }
}

// MARK: - Overlay Template

/// Known overlay templates that subprocess plugins can reference.
/// The host owns all SwiftUI rendering — plugins only provide data.
enum OverlayTemplate: String, Codable {
    case serverURLBanner = "server_url_banner"
    case attentionIcon = "attention_icon"
    case processPill = "process_pill"
    /// Generic label/value pill for metrics (e.g. agent quota). Pane value:
    /// ["<label>", "<value>", "<color>"] where color is green|yellow|red|gray.
    case metricPill = "metric_pill"
}

// MARK: - Alignment Mapping

/// Maps wire-protocol alignment strings to SwiftUI `Alignment` values.
enum AlignmentCodec {
    static func decode(_ string: String) -> Alignment {
        switch string.lowercased() {
        case "top": return .top
        case "topleading": return .topLeading
        case "toptrailing": return .topTrailing
        case "bottom": return .bottom
        case "bottomleading": return .bottomLeading
        case "bottomtrailing": return .bottomTrailing
        case "leading": return .leading
        case "trailing": return .trailing
        case "center": return .center
        default: return .top
        }
    }
}

// MARK: - JSON Line Helpers

enum PluginMessageCodec {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [] // compact, no newlines
        return e
    }()

    private static let decoder = JSONDecoder()

    /// Encode a host message to a single JSON line (with trailing newline).
    static func encode(_ message: HostMessage) -> Data? {
        guard var data = try? encoder.encode(message) else { return nil }
        data.append(0x0A) // newline
        return data
    }

    /// Decode a single JSON line from the plugin into a `PluginMessage`.
    static func decode(_ line: String) -> PluginMessage? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? decoder.decode(PluginMessage.self, from: data)
    }
}
