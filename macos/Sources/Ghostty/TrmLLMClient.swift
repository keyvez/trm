import Foundation

/// Actions the LLM can perform against the terminal, matching the Zig `TermaniaAction` types.
enum TrmAction: Equatable {
    case sendCommand(pane: Int, command: String)
    case sendToAll(command: String)
    case setTitle(pane: Int, title: String)
    case setWatermark(pane: Int, watermark: String)
    case clearWatermark(pane: Int)
    case spawnPane
    case closePane(pane: Int)
    case focusPane(pane: Int)
    case message(text: String)

    /// Human-readable description for display in the command palette.
    var displayDescription: String {
        switch self {
        case .sendCommand(let pane, let command):
            return "[pane \(pane)] $ \(command)"
        case .sendToAll(let command):
            return "[all] $ \(command)"
        case .setTitle(let pane, let title):
            return "[pane \(pane)] title = \"\(title)\""
        case .setWatermark(let pane, let watermark):
            return "[pane \(pane)] watermark = \"\(watermark)\""
        case .clearWatermark(let pane):
            return "[pane \(pane)] clear watermark"
        case .spawnPane:
            return "spawn new pane"
        case .closePane(let pane):
            return "close pane \(pane)"
        case .focusPane(let pane):
            return "focus pane \(pane)"
        case .message(let text):
            return text
        }
    }
}

/// A parsed LLM response containing an explanation and a list of actions.
struct TrmLLMResponse {
    let explanation: String
    let actions: [TrmAction]
}

/// Context about a single pane, provided to the LLM in the system prompt.
struct PaneContext {
    let index: Int
    let title: String
    let isFocused: Bool
    let visibleText: String
}

/// Swift-native LLM client using URLSession to call the Claude API.
final class TrmLLMClient {
    private static let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-sonnet-4-20250514"
    private static let maxTokens = 4096

    enum LLMError: LocalizedError {
        case noAPIKey
        case requestFailed(String)
        case invalidResponse
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "No Claude API key configured."
            case .requestFailed(let msg):
                return "Request failed: \(msg)"
            case .invalidResponse:
                return "Could not parse API response."
            case .httpError(let code, let body):
                return "HTTP \(code): \(body)"
            }
        }
    }

    /// Submit a prompt to the Claude API and return parsed actions.
    func submit(prompt: String, paneContext: [PaneContext]) async throws -> TrmLLMResponse {
        guard let apiKey = Trm.shared.claudeAPIKey, !apiKey.isEmpty else {
            throw LLMError.noAPIKey
        }

        let systemPrompt = buildSystemPrompt(panes: paneContext)

        let requestBody: [String: Any] = [
            "model": Self.model,
            "max_tokens": Self.maxTokens,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpError(httpResponse.statusCode, body)
        }

        // Parse the Anthropic response to extract text content.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            throw LLMError.invalidResponse
        }

        // Parse the text into actions.
        return parseResponse(text)
    }

    // MARK: - Resolved Config

    /// Resolved LLM connection settings with provider-specific defaults.
    struct ResolvedConfig {
        let provider: String
        let apiURL: URL
        let model: String
        let apiKey: String?
        let maxTokens: Int
        let useAnthropicFormat: Bool
    }

    /// Build a resolved config from the termania TOML + UserDefaults fallback.
    func resolvedConfig() -> ResolvedConfig {
        let cfg = Trm.shared.llmConfig()
        let provider = cfg.provider.lowercased()

        let apiKey = cfg.apiKey ?? Trm.shared.claudeAPIKey
        let maxTokens = Int(cfg.maxTokens)

        switch provider {
        case "anthropic", "claude":
            return ResolvedConfig(
                provider: "anthropic",
                apiURL: URL(string: cfg.baseURL ?? "https://api.anthropic.com/v1/messages")!,
                model: cfg.model ?? "claude-sonnet-4-20250514",
                apiKey: apiKey,
                maxTokens: maxTokens,
                useAnthropicFormat: true
            )

        case "openai":
            return ResolvedConfig(
                provider: "openai",
                apiURL: URL(string: cfg.baseURL ?? "https://api.openai.com/v1/chat/completions")!,
                model: cfg.model ?? "gpt-4o",
                apiKey: apiKey,
                maxTokens: maxTokens,
                useAnthropicFormat: false
            )

        case "ollama":
            return ResolvedConfig(
                provider: "ollama",
                apiURL: URL(string: cfg.baseURL ?? "http://localhost:11434/v1/chat/completions")!,
                model: cfg.model ?? "llama3",
                apiKey: nil,
                maxTokens: maxTokens,
                useAnthropicFormat: false
            )

        default: // "lmstudio" and anything else
            return ResolvedConfig(
                provider: "lmstudio",
                apiURL: URL(string: cfg.baseURL ?? "http://localhost:1234/v1/chat/completions")!,
                model: cfg.model ?? "default",
                apiKey: nil,
                maxTokens: maxTokens,
                useAnthropicFormat: false
            )
        }
    }

    // MARK: - Summarize

    /// Summarize the visible text of a pane using the configured LLM provider.
    func summarize(visibleText: String, paneTitle: String) async throws -> String {
        let config = resolvedConfig()

        let systemContent = """
        You are a terminal output summarizer. Given the visible text from a terminal pane, \
        provide a very concise 1-2 sentence summary of what is happening. Focus on the most \
        recent activity. Keep it under 200 characters. Do NOT use markdown or formatting. \
        Return only the summary text, nothing else.
        """

        let userContent = "Pane: \"\(paneTitle)\"\n\nVisible output:\n\(visibleText)"
        let summaryMaxTokens = min(config.maxTokens, 256)

        let (data, response): (Data, URLResponse)
        if config.useAnthropicFormat {
            // Anthropic format
            let body: [String: Any] = [
                "model": config.model,
                "max_tokens": summaryMaxTokens,
                "system": systemContent,
                "messages": [["role": "user", "content": userContent]]
            ]
            var request = URLRequest(url: config.apiURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if let key = config.apiKey, !key.isEmpty {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 30
            (data, response) = try await URLSession.shared.data(for: request)
        } else {
            // OpenAI-compatible format (LM Studio, Ollama, OpenAI)
            let body: [String: Any] = [
                "model": config.model,
                "max_tokens": summaryMaxTokens,
                "messages": [
                    ["role": "system", "content": systemContent],
                    ["role": "user", "content": userContent]
                ]
            ]
            var request = URLRequest(url: config.apiURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            if let key = config.apiKey, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 30
            (data, response) = try await URLSession.shared.data(for: request)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        if httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpError(httpResponse.statusCode, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidResponse
        }

        // Parse Anthropic format
        if let content = json["content"] as? [[String: Any]],
           let first = content.first,
           let text = first["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Parse OpenAI-compatible format
        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let text = message["content"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        throw LLMError.invalidResponse
    }

    // MARK: - System Prompt

    private func buildSystemPrompt(panes: [PaneContext]) -> String {
        var prompt = """
        You are an AI assistant integrated into trm, a multi-pane terminal emulator. \
        You have deep programmatic control over the entire application.

        Current panes:

        """

        for pane in panes {
            let focusMarker = pane.isFocused ? " (focused)" : ""
            prompt += "\n--- Pane \(pane.index) [terminal]\(focusMarker) (\"\(pane.title)\") ---\n"
            let truncated = truncateToLastLines(pane.visibleText, maxLines: 30)
            if !truncated.isEmpty {
                prompt += "Last visible output:\n\(truncated)\n"
            }
        }

        prompt += """

        Respond with JSON in this exact format:
        ```json
        {
          "explanation": "Brief description of what you're doing",
          "actions": [
            {"type": "send_command", "pane": 0, "command": "ls -la"}
          ]
        }
        ```

        Available action types:
        - send_command: Send a command to a specific pane. Fields: pane (int), command (string)
        - send_to_all: Send a command to all panes. Fields: command (string)
        - set_title: Set the title of a pane. Fields: pane (int), title (string)
        - set_watermark: Set watermark text for a pane. Fields: pane (int), watermark (string)
        - clear_watermark: Clear watermark from a pane. Fields: pane (int)
        - spawn_pane: Create a new terminal pane. No additional fields required.
        - close_pane: Close a pane. Fields: pane (int)
        - focus_pane: Focus a pane. Fields: pane (int)
        - message: Display a message to the user. Fields: text (string)

        Return ONLY the JSON, no other text.
        """

        return prompt
    }

    private func truncateToLastLines(_ text: String, maxLines: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        if lines.count <= maxLines { return text }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    // MARK: - Response Parsing

    private func parseResponse(_ text: String) -> TrmLLMResponse {
        guard let jsonText = extractJSON(from: text),
              let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // If we can't parse JSON, return the raw text as a message.
            return TrmLLMResponse(
                explanation: text,
                actions: [.message(text: text)]
            )
        }

        let explanation = json["explanation"] as? String ?? ""
        var actions: [TrmAction] = []

        if let actionsArray = json["actions"] as? [[String: Any]] {
            for actionObj in actionsArray {
                if let action = parseAction(actionObj) {
                    actions.append(action)
                }
            }
        }

        return TrmLLMResponse(explanation: explanation, actions: actions)
    }

    private func parseAction(_ obj: [String: Any]) -> TrmAction? {
        guard let type = obj["type"] as? String else { return nil }

        switch type {
        case "send_command":
            guard let pane = obj["pane"] as? Int,
                  let command = obj["command"] as? String else { return nil }
            return .sendCommand(pane: pane, command: command)

        case "send_to_all":
            guard let command = obj["command"] as? String else { return nil }
            return .sendToAll(command: command)

        case "set_title":
            guard let pane = obj["pane"] as? Int,
                  let title = obj["title"] as? String else { return nil }
            return .setTitle(pane: pane, title: title)

        case "set_watermark":
            guard let pane = obj["pane"] as? Int,
                  let watermark = obj["watermark"] as? String else { return nil }
            return .setWatermark(pane: pane, watermark: watermark)

        case "clear_watermark":
            guard let pane = obj["pane"] as? Int else { return nil }
            return .clearWatermark(pane: pane)

        case "spawn_pane":
            return .spawnPane

        case "close_pane":
            guard let pane = obj["pane"] as? Int else { return nil }
            return .closePane(pane: pane)

        case "focus_pane":
            guard let pane = obj["pane"] as? Int else { return nil }
            return .focusPane(pane: pane)

        case "message":
            guard let text = obj["text"] as? String else { return nil }
            return .message(text: text)

        default:
            return nil
        }
    }

    /// Extract JSON from text, handling markdown code fences.
    private func extractJSON(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Direct JSON object
        if trimmed.hasPrefix("{") { return trimmed }

        // Strip ```json ... ```
        if let jsonStart = trimmed.range(of: "```json") {
            let after = trimmed[jsonStart.upperBound...]
            if let end = after.range(of: "```") {
                return String(after[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Strip ``` ... ```
        if let fenceStart = trimmed.range(of: "```") {
            let after = trimmed[fenceStart.upperBound...]
            if let newline = after.firstIndex(of: "\n") {
                let inner = after[after.index(after: newline)...]
                if let end = inner.range(of: "```") {
                    let candidate = String(inner[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidate.hasPrefix("{") { return candidate }
                }
            }
        }

        // Find first { to last }
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"), end > start {
            return String(trimmed[start...end])
        }

        return nil
    }
}
