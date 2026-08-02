import Foundation

enum TranscriptCleanupError: LocalizedError {
    case missingConfiguration(String)
    case rejectedOutput
    case emptyResponse(String)
    case backendFailed(String)

    var errorDescription: String? {
        switch self {
        case let .missingConfiguration(message):
            return message
        case .rejectedOutput:
            return "Transcript cleanup output was rejected by safety checks."
        case let .emptyResponse(backend):
            return "\(backend) returned an empty transcript cleanup response."
        case let .backendFailed(message):
            return message
        }
    }
}

struct TranscriptCleanupResult {
    let rawOutput: String
    let cleanedOutput: String
    let model: String
    /// The provider stopped because it hit the output cap, not because it was done.
    ///
    /// Without this a cap hit part-way through the final sentence is invisible:
    /// the response keeps every earlier line intact and simply ends mid-thought.
    var wasTruncated: Bool = false
}

/// One backend response, plus whether the provider cut it short.
struct TranscriptCleanupRawResponse {
    let text: String
    let wasTruncated: Bool
}

/// Per-request overrides that meeting cleanup needs and dictation must not get.
struct TranscriptCleanupRequestOptions {
    /// Output cap. `nil` leaves each backend's existing behaviour untouched --
    /// which for the ChatGPT path means sending no cap field at all, since it
    /// never has, and imposing the dictation default would newly truncate long
    /// dictations that work today.
    var maxOutputTokens: Int?
    /// Ask the provider not to retain the request. Meeting cleanup sends the whole
    /// transcript of a private conversation; OpenAI keeps `/v1/responses` state for
    /// at least 30 days unless told otherwise.
    var disableProviderRetention: Bool = false
    /// Preserve line structure in the response instead of collapsing whitespace.
    /// Dictation wants the collapse; a transcript is destroyed by it.
    var preserveLineStructure: Bool = false

    static let dictationDefaults = TranscriptCleanupRequestOptions()
}

enum TranscriptCleanupClient {
    private static let openAIResponsesURL = URL(string: "https://api.openai.com/v1/responses")!
    private static let openRouterURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let defaultOllamaBaseURL = URL(string: "http://localhost:11434")!
    private static let requestTimeout: TimeInterval = 120
    private static let defaultMaxOutputTokens = 1000
    private static let hostedAppContextCharacterLimit = 5_000

    static func defaultModel(for backend: TranscriptCleanupBackendOption) -> String {
        if backend == .gemma4LiteRT {
            return Gemma4LiteRTModelStore.repoID
        }
        switch backend.llmBackend {
        case .some(.chatGPT):
            return SummaryModelPreset.chatGPTTranscriptCleanupModels.first?.id ?? "gpt-5.6-terra"
        case .some(.openAI):
            return SummaryModelPreset.openAIModels.first?.id ?? "gpt-5.4-mini"
        case .some(.openRouter):
            return SummaryModelPreset.openRouterModels.first?.id ?? "stepfun/step-3.5-flash:free"
        case .some(.ollama):
            return "qwen3.5"
        case .some(.lmStudio), .some(.customLLM):
            return ""
        case nil:
            return PostProcessorOption.defaultOption.id
        default:
            return ""
        }
    }

    static func configuredModel(for backend: TranscriptCleanupBackendOption, config: AppConfig) -> String {
        if backend == .gemma4LiteRT {
            return Gemma4LiteRTModelStore.repoID
        }
        let raw: String
        switch backend.llmBackend {
        case .some(.chatGPT):
            raw = config.postProcessorChatGPTModel
        case .some(.openAI):
            raw = config.postProcessorOpenAIModel
        case .some(.openRouter):
            raw = config.postProcessorOpenRouterModel
        case .some(.ollama):
            raw = config.postProcessorOllamaModel
        case .some(.lmStudio):
            raw = config.postProcessorLMStudioModel
        case .some(.customLLM):
            raw = config.postProcessorCustomLLMModel
        case nil:
            raw = config.activePostProcessorId
        default:
            raw = ""
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModel(for: backend) : trimmed
    }

    static func hasRequiredSettings(for backend: TranscriptCleanupBackendOption, config: AppConfig, isChatGPTAuthenticated: Bool) -> Bool {
        if backend == .gemma4LiteRT {
            return Gemma4LiteRTModelStore.isAvailableLocally()
        }
        switch backend.llmBackend {
        case .some(.chatGPT):
            return isChatGPTAuthenticated
        case .some(.openAI):
            return !config.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil
        case .some(.openRouter):
            return !config.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil
        case .some(.ollama):
            return resolveConfiguredOllamaURL(config: config) != nil
        case .some(.lmStudio):
            let model = configuredModel(for: backend, config: config)
            return !model.isEmpty
                && MeetingSummaryClient.resolveLMStudioURL(config: cleanupConfig(config, model: model)) != nil
        case .some(.customLLM):
            let model = configuredModel(for: backend, config: config)
            let format = CustomLLMFormat(rawValue: config.customLLMFormat) ?? .openAI
            let key = config.customLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            return !model.isEmpty
                && resolveConfiguredCustomLLMURL(config: config, format: format) != nil
                && (!MeetingSummaryClient.customLLMRequiresAPIKey(config: config) || !key.isEmpty)
        case nil:
            return true
        default:
            return false
        }
    }

    static func clean(
        text: String,
        systemPrompt: String,
        appContext: String?,
        backend: TranscriptCleanupBackendOption,
        config: AppConfig,
        options: TranscriptCleanupRequestOptions = .dictationDefaults
    ) async throws -> TranscriptCleanupResult {
        guard let llmBackend = backend.llmBackend else {
            throw TranscriptCleanupError.missingConfiguration("Local cleanup is handled by Qwen3PostProcessor.")
        }

        let model = configuredModel(for: backend, config: config)
        let userPrompt = Qwen3PostProcessorConfig.formatInput(
            text,
            appContext: appContext,
            maxAppContextCharacters: hostedAppContextCharacterLimit
        )
        let effectiveSystemPrompt = systemPromptWithAppContextGuidance(systemPrompt, appContext: appContext)
        let response: TranscriptCleanupRawResponse

        switch llmBackend {
        case .chatGPT:
            let chatGPTResult = try await ChatGPTResponsesClient.respondDetailed(
                systemPrompt: effectiveSystemPrompt,
                userPrompt: userPrompt,
                model: model,
                logCategory: "postproc",
                maxOutputTokens: options.maxOutputTokens
            )
            response = TranscriptCleanupRawResponse(
                text: chatGPTResult.text,
                wasTruncated: chatGPTResult.wasTruncated
            )
        case .openAI:
            response = try await cleanWithOpenAI(systemPrompt: effectiveSystemPrompt, userPrompt: userPrompt, model: model, config: config, options: options)
        case .openRouter:
            let apiKey = resolvedOpenRouterAPIKey(config: config)
            response = try await cleanWithChatCompletions(
                backend: "OpenRouter",
                requestURL: openRouterURL,
                apiKey: apiKey,
                systemPrompt: effectiveSystemPrompt,
                userPrompt: userPrompt,
                model: model,
                options: options
            )
        case .ollama:
            response = try await cleanWithOllama(systemPrompt: effectiveSystemPrompt, userPrompt: userPrompt, model: model, config: config, options: options)
        case .lmStudio:
            guard let requestURL = MeetingSummaryClient.resolveLMStudioURL(config: cleanupConfig(config, model: model)) else {
                throw TranscriptCleanupError.missingConfiguration("Invalid LM Studio URL: \(config.lmStudioURL)")
            }
            response = try await cleanWithChatCompletions(
                backend: "LM Studio",
                requestURL: requestURL,
                apiKey: "",
                systemPrompt: effectiveSystemPrompt,
                userPrompt: userPrompt,
                model: model,
                options: options
            )
        case .customLLM:
            let format = CustomLLMFormat(rawValue: config.customLLMFormat) ?? .openAI
            guard let requestURL = resolveConfiguredCustomLLMURL(config: config, format: format) else {
                throw TranscriptCleanupError.missingConfiguration("Invalid custom URL: \(config.customLLMURL)")
            }
            switch format {
            case .openAI:
                response = try await cleanWithChatCompletions(
                    backend: "Custom LLM",
                    requestURL: requestURL,
                    apiKey: config.customLLMAPIKey,
                    systemPrompt: effectiveSystemPrompt,
                    userPrompt: userPrompt,
                    model: model,
                    options: options
                )
            case .anthropic:
                response = try await cleanWithAnthropic(
                    requestURL: requestURL,
                    apiKey: config.customLLMAPIKey,
                    systemPrompt: effectiveSystemPrompt,
                    userPrompt: userPrompt,
                    model: model,
                    options: options
                )
            }
        default:
            throw TranscriptCleanupError.missingConfiguration("Unsupported transcript cleanup backend: \(backend.label)")
        }

        let raw = response.text
        // A transcript's newlines are structure. The dictation cleaner collapses
        // runs of whitespace, which would flatten a multi-line transcript into one
        // line before anything downstream could check it.
        let cleaned = options.preserveLineStructure ? lineSafeOutput(raw) : cleanOutput(raw)
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, Qwen3DeletionCueDetector.containsDeletionCue(text) {
            return TranscriptCleanupResult(rawOutput: raw, cleanedOutput: trimmed, model: model, wasTruncated: response.wasTruncated)
        }
        if !options.preserveLineStructure,
           Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(cleaned: trimmed, input: text) {
            throw TranscriptCleanupError.rejectedOutput
        }
        return TranscriptCleanupResult(rawOutput: raw, cleanedOutput: trimmed, model: model, wasTruncated: response.wasTruncated)
    }

    /// Normalizes a response without destroying line structure.
    ///
    /// Trims trailing spaces per line and normalizes line endings, but keeps every
    /// newline and blank line -- transcripts carry meaning in both, including the
    /// blank lines around a resume separator.
    static func lineSafeOutput(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text
            .replacingOccurrences(of: #"\r\n?"#, with: "\n", options: .regularExpression)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
            .joined(separator: "\n")
    }

    static func cleanOutput(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = Qwen3PostProcessorOutputCleaner.clean(text)
        result = result.replacingOccurrences(of: #"\r\n?"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t]+([,.;:!?])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?m)[ \t]+$"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func systemPromptWithAppContextGuidance(_ systemPrompt: String, appContext: String?) -> String {
        guard let appContext, !appContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return systemPrompt
        }
        guard !systemPrompt.contains("<APP-CONTEXT>") else { return systemPrompt }
        return systemPrompt + "\n\n" + appContextGuidance
    }

    private static let appContextGuidance = "The user input may include an <APP-CONTEXT> section with focused app, document, URL, selected text, or OCR screen text. Use it only to resolve obvious transcription errors, names, acronyms, and formatting intent. Never copy app context into the output unless the user dictated it."

    static func resolvedOpenRouterAPIKey(
        config: AppConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let key = config.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? (environment["OPENROUTER_API_KEY"] ?? "") : key
    }

    private static func cleanupConfig(_ config: AppConfig, model: String) -> AppConfig {
        var copy = config
        copy.lmStudioModel = model
        return copy
    }

    private static func resolveConfiguredCustomLLMURL(config: AppConfig, format: CustomLLMFormat) -> URL? {
        guard !config.customLLMURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return MeetingSummaryClient.resolveCustomLLMURL(config: config, format: format)
    }

    private static func cleanWithOpenAI(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        config: AppConfig,
        options: TranscriptCleanupRequestOptions
    ) async throws -> TranscriptCleanupRawResponse {
        let key = config.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = key.isEmpty ? (ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "") : key
        guard !apiKey.isEmpty else {
            throw TranscriptCleanupError.missingConfiguration("OpenAI API key is not configured.")
        }
        var body: [String: Any] = [
            "model": model,
            "instructions": systemPrompt,
            "input": userPrompt,
            "max_output_tokens": options.maxOutputTokens ?? defaultMaxOutputTokens,
        ]
        if options.disableProviderRetention {
            body["store"] = false
        }
        if let effort = SummaryModelPreset.reasoningEffort(for: model) {
            body["reasoning"] = ["effort": effort]
        }
        var request = URLRequest(url: openAIResponsesURL)
        request.timeoutInterval = requestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data, backend: "OpenAI")
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = extractResponsesText(from: json),
            !text.isEmpty
        else {
            throw TranscriptCleanupError.emptyResponse("OpenAI")
        }
        return TranscriptCleanupRawResponse(text: text, wasTruncated: responsesHitOutputCap(json))
    }

    private static func cleanWithOllama(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        config: AppConfig,
        options: TranscriptCleanupRequestOptions
    ) async throws -> TranscriptCleanupRawResponse {
        let baseURL = resolveConfiguredOllamaURL(config: config)
        guard let baseURL else {
            throw TranscriptCleanupError.missingConfiguration("Invalid Ollama URL: \(config.ollamaURL)")
        }
        let chatURL = baseURL.appendingPathComponent("api/chat")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "stream": false,
            "options": ["num_predict": options.maxOutputTokens ?? defaultMaxOutputTokens],
        ]
        var request = URLRequest(url: chatURL)
        request.timeoutInterval = requestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data, backend: "Ollama")
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let text = message["content"] as? String,
            !text.isEmpty
        else {
            throw TranscriptCleanupError.emptyResponse("Ollama")
        }
        // Ollama reports completion via `done_reason`; "length" means it hit the cap.
        let truncated = (json["done_reason"] as? String) == "length"
        return TranscriptCleanupRawResponse(text: text, wasTruncated: truncated)
    }

    private static func resolveConfiguredOllamaURL(config: AppConfig) -> URL? {
        let rawURL = config.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else { return defaultOllamaBaseURL }
        guard
            let url = URL(string: rawURL),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty
        else {
            return nil
        }
        return url
    }

    private static func cleanWithChatCompletions(
        backend: String,
        requestURL: URL,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        model: String,
        options: TranscriptCleanupRequestOptions
    ) async throws -> TranscriptCleanupRawResponse {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
        ]
        let tokenKey = requestURL.host?.contains("openai.com") == true ? "max_completion_tokens" : "max_tokens"
        body[tokenKey] = options.maxOutputTokens ?? defaultMaxOutputTokens
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = requestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data, backend: backend)
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = extractChatCompletionsText(from: json),
            !text.isEmpty
        else {
            throw TranscriptCleanupError.emptyResponse(backend)
        }
        return TranscriptCleanupRawResponse(text: text, wasTruncated: chatCompletionsHitOutputCap(json))
    }

    private static func cleanWithAnthropic(
        requestURL: URL,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        model: String,
        options: TranscriptCleanupRequestOptions
    ) async throws -> TranscriptCleanupRawResponse {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": options.maxOutputTokens ?? defaultMaxOutputTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userPrompt]],
        ]
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = requestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data, backend: "Custom LLM")
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = extractAnthropicText(from: json),
            !text.isEmpty
        else {
            throw TranscriptCleanupError.emptyResponse("Custom LLM")
        }
        return TranscriptCleanupRawResponse(text: text, wasTruncated: anthropicHitOutputCap(json))
    }

    private static func validateHTTPResponse(_ response: URLResponse, data: Data, backend: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = extractErrorMessage(from: data)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw TranscriptCleanupError.backendFailed("\(backend) cleanup failed. \(message)")
        }
    }

    /// Whether an OpenAI Responses reply stopped because it ran out of room.
    static func responsesHitOutputCap(_ payload: [String: Any]) -> Bool {
        if (payload["status"] as? String) == "incomplete" { return true }
        if let details = payload["incomplete_details"] as? [String: Any],
           (details["reason"] as? String) == "max_output_tokens" {
            return true
        }
        return false
    }

    /// Whether a chat-completions reply stopped because it ran out of room.
    static func chatCompletionsHitOutputCap(_ payload: [String: Any]) -> Bool {
        guard let choices = payload["choices"] as? [[String: Any]] else { return false }
        return choices.contains { choice in
            let reason = (choice["finish_reason"] as? String) ?? (choice["native_finish_reason"] as? String)
            return reason == "length"
        }
    }

    /// Whether an Anthropic reply stopped because it ran out of room.
    static func anthropicHitOutputCap(_ payload: [String: Any]) -> Bool {
        (payload["stop_reason"] as? String) == "max_tokens"
    }

    private static func extractResponsesText(from payload: [String: Any]) -> String? {
        if let outputText = payload["output_text"] as? String, !outputText.isEmpty {
            return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let output = payload["output"] as? [[String: Any]] {
            let parts = output.flatMap { item -> [String] in
                guard let content = item["content"] as? [[String: Any]] else { return [] }
                return content.compactMap { $0["text"] as? String }
            }
            let joined = parts.joined()
            return joined.isEmpty ? nil : joined.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func extractChatCompletionsText(from payload: [String: Any]) -> String? {
        guard let choices = payload["choices"] as? [[String: Any]] else { return nil }
        for choice in choices {
            if let message = choice["message"] as? [String: Any],
               let content = message["content"] as? String,
               !content.isEmpty {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let text = choice["text"] as? String, !text.isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func extractAnthropicText(from payload: [String: Any]) -> String? {
        guard let content = payload["content"] as? [[String: Any]] else { return nil }
        let parts = content.compactMap { item -> String? in
            guard (item["type"] as? String) == nil || (item["type"] as? String) == "text" else { return nil }
            return item["text"] as? String
        }
        let joined = parts.joined()
        return joined.isEmpty ? nil : joined.trimmingCharacters(in: .whitespacesAndNewlines)
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
