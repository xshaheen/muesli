import Foundation

enum ChatGPTResponsesError: LocalizedError {
    case backendFailed(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case let .backendFailed(statusCode, message):
            return "ChatGPT failed with status \(statusCode). \(message)"
        }
    }
}

/// One turn in a Responses-API conversation.
///
/// The Responses API does not carry system content as a message role: it goes in
/// `instructions`, and only user/assistant turns belong in `input`. Callers express
/// intent with roles and let `requestBody` place each one correctly.
struct ChatGPTResponsesMessage: Equatable {
    enum Role: String, Equatable {
        case system, user, assistant
    }

    let role: Role
    let content: String

    init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// A completed Responses reply, plus whether the provider cut it short.
struct ChatGPTResponsesResult {
    let text: String
    /// The response stopped at the output cap rather than finishing its thought.
    let wasTruncated: Bool
}

enum ChatGPTResponsesClient {
    private static let whamURL = URL(string: "https://chatgpt.com/backend-api/wham/responses")!
    private static let requestTimeout: TimeInterval = 120

    static func respond(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        logCategory: String,
        maxOutputTokens: Int? = nil
    ) async throws -> String {
        try await respondDetailed(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model,
            logCategory: logCategory,
            maxOutputTokens: maxOutputTokens
        ).text
    }

    /// Multi-turn variant. Preserves role order so a conversation's history reaches the model.
    static func respond(
        messages: [ChatGPTResponsesMessage],
        model: String,
        logCategory: String,
        maxOutputTokens: Int? = nil
    ) async throws -> String {
        try await respondDetailed(
            messages: messages,
            model: model,
            logCategory: logCategory,
            maxOutputTokens: maxOutputTokens
        ).text
    }

    /// Same request as `respond`, but reports whether the reply hit the output cap.
    static func respondDetailed(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        logCategory: String,
        maxOutputTokens: Int? = nil
    ) async throws -> ChatGPTResponsesResult {
        try await respondDetailed(
            messages: [
                ChatGPTResponsesMessage(role: .system, content: systemPrompt),
                ChatGPTResponsesMessage(role: .user, content: userPrompt),
            ],
            model: model,
            logCategory: logCategory,
            maxOutputTokens: maxOutputTokens
        )
    }

    static func respondDetailed(
        messages: [ChatGPTResponsesMessage],
        model: String,
        logCategory: String,
        maxOutputTokens: Int? = nil
    ) async throws -> ChatGPTResponsesResult {
        let (token, accountId) = try await ChatGPTAuthManager.shared.validAccessToken()
        let body = requestBody(messages: messages, model: model, maxOutputTokens: maxOutputTokens)

        var request = URLRequest(url: whamURL)
        request.timeoutInterval = requestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard httpStatus == 200 else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let message = extractErrorMessage(from: errorData)
                ?? String(data: errorData, encoding: .utf8)
                ?? "(unknown)"
            fputs("[\(logCategory)] ChatGPT WHAM: HTTP \(httpStatus): \(String(message.prefix(500)))\n", stderr)
            throw ChatGPTResponsesError.backendFailed(statusCode: httpStatus, message: message)
        }

        var deltaText = ""
        var finalText = ""
        var wasTruncated = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            if jsonString == "[DONE]" { break }
            guard let json = try decodeStreamPayload(jsonString, httpStatus: httpStatus) else { continue }

            applyStreamPayload(json, deltaText: &deltaText, finalText: &finalText)
            if hitOutputCap(json) { wasTruncated = true }
        }

        let fullText = accumulatedOutputText(deltaText: deltaText, finalText: finalText)
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let truncationNote = wasTruncated ? " (hit output cap)" : ""
        fputs("[\(logCategory)] ChatGPT WHAM: collected \(trimmed.count) chars\(truncationNote)\n", stderr)
        return ChatGPTResponsesResult(text: trimmed, wasTruncated: wasTruncated)
    }

    static func requestBody(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        maxOutputTokens: Int? = nil
    ) -> [String: Any] {
        requestBody(
            messages: [
                ChatGPTResponsesMessage(role: .system, content: systemPrompt),
                ChatGPTResponsesMessage(role: .user, content: userPrompt),
            ],
            model: model,
            maxOutputTokens: maxOutputTokens
        )
    }

    /// - Parameter maxOutputTokens: omitted entirely when nil. This path has never
    ///   sent a cap, and defaulting it to the dictation limit would newly truncate
    ///   long dictations that work today. Meeting cleanup always passes one.
    static func requestBody(
        messages: [ChatGPTResponsesMessage],
        model: String,
        maxOutputTokens: Int? = nil
    ) -> [String: Any] {
        // System content is `instructions`, not an `input` entry. Multiple system messages
        // join in order rather than overwriting, so a caller that layers instructions keeps
        // all of them.
        var instructions: [String] = []
        var input: [[String: Any]] = []

        for message in messages {
            switch message.role {
            case .system:
                instructions.append(message.content)
            case .user:
                input.append([
                    "role": "user",
                    "content": [["type": "input_text", "text": message.content]],
                ] as [String: Any])
            case .assistant:
                // Assistant-role content must be `output_text` even when replayed as
                // input — the live API rejects `input_text` here with 400 "Invalid
                // value: 'input_text'. Supported values are: 'output_text' and
                // 'refusal'." (observed 03-08-2026). No id/status fields are needed
                // in the easy-input-message form.
                input.append([
                    "role": "assistant",
                    "content": [["type": "output_text", "text": message.content]],
                ] as [String: Any])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "instructions": instructions.joined(separator: "\n\n"),
            "input": input,
        ]
        if let maxOutputTokens {
            body["max_output_tokens"] = maxOutputTokens
        }
        if let effort = SummaryModelPreset.reasoningEffort(for: model) {
            body["reasoning"] = ["effort": effort]
        }
        return body
    }

    static func applyStreamPayload(_ payload: [String: Any], deltaText: inout String, finalText: inout String) {
        if let delta = extractOutputTextDelta(from: payload) {
            deltaText += delta
            return
        }

        if let outputText = extractOutputText(from: payload), !outputText.isEmpty {
            finalText = outputText
        }
    }

    static func accumulatedOutputText(deltaText: String, finalText: String) -> String {
        finalText.isEmpty ? deltaText : finalText
    }

    /// Whether a stream event says the response stopped because it ran out of room.
    ///
    /// The terminal `response.completed` / `response.incomplete` events carry the
    /// response object, which marks a capped reply with `status: "incomplete"` and
    /// `incomplete_details.reason == "max_output_tokens"`. In-progress events report
    /// `"in_progress"`, so only a finished-but-cut-short reply matches here.
    static func hitOutputCap(_ payload: [String: Any]) -> Bool {
        if (payload["status"] as? String) == "incomplete" { return true }
        if let details = payload["incomplete_details"] as? [String: Any],
           (details["reason"] as? String) == "max_output_tokens" {
            return true
        }
        if let response = payload["response"] as? [String: Any] {
            return hitOutputCap(response)
        }
        return false
    }

    static func decodeStreamPayload(_ jsonString: String, httpStatus: Int) throws -> [String: Any]? {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if shouldIgnoreNonJSONStreamPayload(trimmed) { return nil }
        guard
            let data = trimmed.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ChatGPTResponsesError.backendFailed(
                statusCode: httpStatus,
                message: "Malformed ChatGPT stream payload."
            )
        }
        return json
    }

    private static func shouldIgnoreNonJSONStreamPayload(_ payload: String) -> Bool {
        switch payload.lowercased() {
        case "ping", "heartbeat", "keep-alive":
            return true
        default:
            return false
        }
    }

    static func extractOutputText(from payload: [String: Any]) -> String? {
        if let outputText = payload["output_text"] as? String, !outputText.isEmpty {
            return outputText
        }
        if let response = payload["response"] as? [String: Any],
           let responseText = extractOutputText(from: response) {
            return responseText
        }
        if let outputText = extractText(fromOutput: payload["output"]) {
            return outputText
        }
        if let contentText = extractText(fromContent: payload["content"]) {
            return contentText
        }
        return nil
    }

    static func extractOutputTextDelta(from payload: [String: Any]) -> String? {
        guard
            (payload["type"] as? String) == "response.output_text.delta",
            let delta = payload["delta"] as? String,
            !delta.isEmpty
        else {
            return nil
        }
        return delta
    }

    private static func extractText(fromOutput output: Any?) -> String? {
        guard let output else { return nil }
        if let outputText = output as? String, !outputText.isEmpty {
            return outputText
        }
        if let item = output as? [String: Any] {
            return extractText(fromContent: item["content"]) ?? (item["text"] as? String)
        }
        if let items = output as? [[String: Any]] {
            let parts = items.compactMap { item -> String? in
                extractText(fromContent: item["content"]) ?? (item["text"] as? String)
            }
            let joined = parts.joined(separator: "")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func extractText(fromContent content: Any?) -> String? {
        guard let content else { return nil }
        if let text = content as? String, !text.isEmpty {
            return text
        }
        if let item = content as? [String: Any] {
            if let text = item["text"] as? String, !text.isEmpty { return text }
            if let text = item["content"] as? String, !text.isEmpty { return text }
            if let nested = item["text"] as? [String: Any],
               let value = nested["value"] as? String,
               !value.isEmpty {
                return value
            }
        }
        if let items = content as? [[String: Any]] {
            let parts = items.compactMap { item -> String? in
                if let text = item["text"] as? String, !text.isEmpty { return text }
                if let text = item["content"] as? String, !text.isEmpty { return text }
                if let nested = item["text"] as? [String: Any],
                   let value = nested["value"] as? String,
                   !value.isEmpty {
                    return value
                }
                return nil
            }
            let joined = parts.joined(separator: "")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty { return message }
            if let code = error["code"] as? String, !code.isEmpty { return code }
            return String(describing: error)
        }
        if let message = json["message"] as? String, !message.isEmpty { return message }
        if let detail = json["detail"] as? String, !detail.isEmpty { return detail }
        return nil
    }
}
