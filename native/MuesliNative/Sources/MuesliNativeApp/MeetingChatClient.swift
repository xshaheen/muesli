import Foundation
import MuesliCore
import os

/// One turn in a meeting-transcript conversation.
struct MeetingChatMessage: Equatable {
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

enum MeetingChatError: LocalizedError, Equatable {
    case backendFailed(backend: String, statusCode: Int?, message: String)
    case emptyResponse(backend: String)
    case requestFailed(backend: String, message: String)
    case notConfigured(backend: String)
    /// The question cannot fit even after trimming. Reported before the request leaves,
    /// because a backend's own context error is far less legible than this one.
    case contextOverflow(backend: String, limit: Int)

    var errorDescription: String? {
        switch self {
        case let .backendFailed(backend, statusCode, message):
            let statusText = statusCode.map { " Status \($0)." } ?? ""
            return "\(backend) could not answer.\(statusText) \(message)"
        case let .emptyResponse(backend):
            return "\(backend) returned an empty answer."
        case let .requestFailed(backend, message):
            return "\(backend) could not be reached. \(message)"
        case let .notConfigured(backend):
            return "\(backend) is not configured. Add an API key in Settings."
        case let .contextOverflow(backend, limit):
            return "This question is too long for \(backend) (limit ~\(limit) characters). Shorten it or start a new conversation."
        }
    }
}

/// Multi-turn chat over a meeting transcript.
///
/// Transport is deliberately split. ChatGPT streams SSE behind its own client, so it cannot
/// use the non-streaming helpers; every other backend is request/response JSON and reuses
/// `MeetingSummaryClient`'s validation, extraction, and URL resolution rather than
/// duplicating them. Errors always surface as `MeetingChatError` -- a summary error would
/// tell the user their meeting notes failed, which is not what happened.
enum MeetingChatClient {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingChat")
    private static let openAIURL = URL(string: "https://api.openai.com/v1/responses")!
    private static let openRouterURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let defaultOllamaBaseURL = URL(string: "http://localhost:11434")!

    private static let defaultOpenAIModel = "gpt-5.4-mini"
    private static let defaultOpenRouterModel = "stepfun/step-3.5-flash:free"
    private static let defaultChatGPTModel = "gpt-5.4-mini"
    private static let defaultOllamaModel = "qwen3.5"

    private static let chatTimeout: TimeInterval = 120
    private static let maxAnswerTokens = 2048

    // MARK: - Context budget

    /// Character budgets, not token counts. No config field carries a context limit for a
    /// user-entered model id, so deriving one would be guesswork dressed as precision.
    /// These are deliberately conservative: under-filling a large window costs a little
    /// context, overflowing a small one fails the request outright.
    enum Budget {
        static let hosted = 320_000
        static let local = 48_000

        static func characters(forBackend backend: String) -> Int {
            switch backend {
            case MeetingSummaryBackendOption.ollama.backend,
                 MeetingSummaryBackendOption.lmStudio.backend,
                 MeetingSummaryBackendOption.customLLM.backend:
                return local
            default:
                return hosted
            }
        }
    }

    // MARK: - Entry point

    static func send(messages: [MeetingChatMessage], config: AppConfig) async throws -> String {
        let backend = resolvedBackend(config: config)
        let budgeted = try budgetedMessages(messages, backend: backend)

        switch backend {
        case MeetingSummaryBackendOption.chatGPT.backend:
            return try await sendWithChatGPT(messages: budgeted, config: config)
        case MeetingSummaryBackendOption.openAI.backend:
            return try await sendWithOpenAIResponses(messages: budgeted, config: config)
        case MeetingSummaryBackendOption.openRouter.backend:
            return try await sendWithOpenRouter(messages: budgeted, config: config)
        case MeetingSummaryBackendOption.ollama.backend:
            return try await sendWithOllama(messages: budgeted, config: config)
        case MeetingSummaryBackendOption.lmStudio.backend:
            return try await sendWithLMStudio(messages: budgeted, config: config)
        case MeetingSummaryBackendOption.customLLM.backend:
            return try await sendWithCustomLLM(messages: budgeted, config: config)
        default:
            return try await sendWithChatGPT(messages: budgeted, config: config)
        }
    }

    /// Mirrors `MeetingSummaryClient.summarizeOnce`: empty selection means ChatGPT.
    static func resolvedBackend(config: AppConfig) -> String {
        let raw = config.meetingSummaryBackend
        return (raw.isEmpty ? MeetingSummaryBackendOption.chatGPT.backend : raw).lowercased()
    }

    // MARK: - Budgeting

    /// Bounds the whole request, not just the transcript.
    ///
    /// Order matters: trim the transcript first (it is the largest and most redundant
    /// input), then drop oldest turns, then refuse. Trimming the transcript keeps its tail
    /// because the newest speech is what a mid-meeting question is usually about.
    static func budgetedMessages(
        _ messages: [MeetingChatMessage],
        backend: String
    ) throws -> [MeetingChatMessage] {
        let limit = Budget.characters(forBackend: backend)
        guard totalCharacters(messages) > limit else { return messages }

        var working = messages
        let systemOriginal = working.first(where: { $0.role == .system })?.content

        // History first, then the transcript. Evicting history can free enough room that the
        // transcript needs no trimming at all, whereas trimming first would discard meeting
        // content while stale turns still occupy the budget.
        //
        // Whole exchanges go together: dropping a question but keeping its answer leaves an
        // orphaned assistant turn and two consecutive user turns, which some providers
        // reject outright and others answer against the wrong question.
        while totalCharacters(working) > limit {
            guard let oldestTurn = working.firstIndex(where: { $0.role != .system }),
                  oldestTurn < lastUserIndex(working) ?? -1
            else { break }
            working.remove(at: oldestTurn)
            if oldestTurn < working.count,
               working[oldestTurn].role == .assistant,
               oldestTurn < lastUserIndex(working) ?? -1 {
                working.remove(at: oldestTurn)
            }
        }

        // Recompute the transcript's allowance against whatever history survived.
        if let systemIndex = working.firstIndex(where: { $0.role == .system }),
           let systemOriginal {
            let others = totalCharacters(working) - working[systemIndex].content.count
            let allowanceForSystem = limit - others
            if allowanceForSystem > 0, systemOriginal.count > allowanceForSystem {
                working[systemIndex] = MeetingChatMessage(
                    role: .system,
                    content: trimmedKeepingTail(systemOriginal, to: allowanceForSystem)
                )
            }
        }

        if totalCharacters(working) > limit {
            throw MeetingChatError.contextOverflow(backend: backendLabel(backend), limit: limit)
        }

        return working
    }

    private static func totalCharacters(_ messages: [MeetingChatMessage]) -> Int {
        messages.reduce(0) { $0 + $1.content.count }
    }

    private static func lastUserIndex(_ messages: [MeetingChatMessage]) -> Int? {
        messages.lastIndex(where: { $0.role == .user })
    }

    /// Separates the grounding instructions from the transcript inside the system message.
    /// Trimming splits here so the instructions always survive.
    static let transcriptSeparator = "\n\n---\n\n"

    /// Trims the transcript, never the instructions.
    ///
    /// The system message is `prompt + separator + transcript`. Trimming it as one blob from
    /// the head would eat the prompt first on any long meeting, leaving raw transcript
    /// labelled as system content -- ungrounded, and a free path for anything said in the
    /// meeting to read as instruction. The prompt is preserved whole and only the transcript
    /// gives ground.
    static func trimmedKeepingTail(_ content: String, to limit: Int) -> String {
        guard content.count > limit, limit > 0 else { return content }

        let marker = "[earlier transcript trimmed]\n"

        guard let separatorRange = content.range(of: transcriptSeparator) else {
            // No transcript attached: this is instructions only, so keep the newest part
            // rather than dropping the message entirely.
            let keep = max(0, limit - marker.count)
            return marker + String(content.suffix(keep))
        }

        let prompt = String(content[content.startIndex ..< separatorRange.lowerBound])
        let transcript = String(content[separatorRange.upperBound...])
        let fixedCost = prompt.count + transcriptSeparator.count + marker.count
        let keep = limit - fixedCost

        // If the instructions alone cannot fit, the caller's budget is too small for any
        // useful request; return the prompt and let the caller's overflow check refuse.
        guard keep > 0 else { return prompt }

        return prompt + transcriptSeparator + marker + String(transcript.suffix(keep))
    }

    // MARK: - ChatGPT (SSE)

    private static func sendWithChatGPT(messages: [MeetingChatMessage], config: AppConfig) async throws -> String {
        let model = config.chatGPTModel.isEmpty ? defaultChatGPTModel : config.chatGPTModel
        do {
            let text = try await ChatGPTResponsesClient.respond(
                messages: messages.map {
                    ChatGPTResponsesMessage(
                        role: ChatGPTResponsesMessage.Role(rawValue: $0.role.rawValue) ?? .user,
                        content: $0.content
                    )
                },
                model: model,
                logCategory: "meeting-chat"
            )
            guard !text.isEmpty else { throw MeetingChatError.emptyResponse(backend: "ChatGPT") }
            return text
        } catch let error as MeetingChatError {
            throw error
        } catch let error as ChatGPTResponsesError {
            throw MeetingChatError.backendFailed(
                backend: "ChatGPT",
                statusCode: nil,
                message: error.localizedDescription
            )
        } catch {
            throw MeetingChatError.requestFailed(backend: "ChatGPT", message: error.localizedDescription)
        }
    }

    // MARK: - OpenAI Responses

    /// `/v1/responses` takes `input` and `max_output_tokens`. It does not accept the
    /// chat-completions `max_completion_tokens` key.
    static func openAIResponsesBody(messages: [MeetingChatMessage], model: String) -> [String: Any] {
        [
            "model": model,
            "input": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "reasoning": ["effort": SummaryModelPreset.reasoningEffort(for: model) ?? "low"],
            "text": ["verbosity": "low"],
            "max_output_tokens": maxAnswerTokens,
            "store": false,
        ]
    }

    private static func sendWithOpenAIResponses(messages: [MeetingChatMessage], config: AppConfig) async throws -> String {
        // Same resolution order the summary path uses: an environment key is a supported
        // way to configure this, and chat rejecting it would contradict the readiness UI.
        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? config.openAIAPIKey
        guard !apiKey.isEmpty else { throw MeetingChatError.notConfigured(backend: "OpenAI") }
        let model = config.openAIModel.isEmpty ? defaultOpenAIModel : config.openAIModel

        var request = URLRequest(url: openAIURL)
        request.timeoutInterval = chatTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: openAIResponsesBody(messages: messages, model: model)
        )

        return try await perform(request: request, backend: "OpenAI") { data in
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return MeetingSummaryClient.extractOpenAIText(from: json)
        }
    }

    // MARK: - Chat-completions family

    /// `openrouter`, `lmstudio`, and `custom_llm` in chat-completions format.
    ///
    /// The output-token key is host-aware, matching `summarizeWithChatCompletions`: an
    /// OpenAI-hosted endpoint wants `max_completion_tokens`, everything else `max_tokens`.
    /// A custom endpoint pointed at OpenAI must get the OpenAI key.
    static func chatCompletionsBody(
        messages: [MeetingChatMessage],
        model: String,
        requestURL: URL
    ) -> [String: Any] {
        let isOpenAIHost = requestURL.host?.contains("openai.com") == true
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        body[isOpenAIHost ? "max_completion_tokens" : "max_tokens"] = maxAnswerTokens
        return body
    }

    private static func sendWithChatCompletions(
        messages: [MeetingChatMessage],
        model: String,
        requestURL: URL,
        apiKey: String?,
        backend: String,
        extraHeaders: [String: String] = [:]
    ) async throws -> String {
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = chatTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: chatCompletionsBody(messages: messages, model: model, requestURL: requestURL)
        )

        return try await perform(request: request, backend: backend) { data in
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return MeetingSummaryClient.extractOpenRouterText(from: json)
        }
    }

    private static func sendWithOpenRouter(messages: [MeetingChatMessage], config: AppConfig) async throws -> String {
        let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? config.openRouterAPIKey
        guard !apiKey.isEmpty else { throw MeetingChatError.notConfigured(backend: "OpenRouter") }
        let model = config.openRouterModel.isEmpty ? defaultOpenRouterModel : config.openRouterModel
        return try await sendWithChatCompletions(
            messages: messages,
            model: model,
            requestURL: openRouterURL,
            apiKey: apiKey,
            backend: "OpenRouter"
        )
    }

    private static func sendWithLMStudio(messages: [MeetingChatMessage], config: AppConfig) async throws -> String {
        guard let url = MeetingSummaryClient.resolveLMStudioURL(config: config) else {
            throw MeetingChatError.notConfigured(backend: "LM Studio")
        }
        return try await sendWithChatCompletions(
            messages: messages,
            model: config.lmStudioModel,
            requestURL: url,
            apiKey: nil,
            backend: "LM Studio"
        )
    }

    // MARK: - Ollama

    static func ollamaBody(messages: [MeetingChatMessage], model: String) -> [String: Any] {
        [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": false,
            "options": ["num_predict": maxAnswerTokens],
        ]
    }

    private static func sendWithOllama(messages: [MeetingChatMessage], config: AppConfig) async throws -> String {
        let baseURL = URL(string: config.ollamaURL) ?? defaultOllamaBaseURL
        let chatURL = baseURL.appendingPathComponent("api/chat")
        let model = config.ollamaModel.isEmpty ? defaultOllamaModel : config.ollamaModel

        var request = URLRequest(url: chatURL)
        request.timeoutInterval = chatTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ollamaBody(messages: messages, model: model)
        )

        return try await perform(request: request, backend: "Ollama") { data in
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = json["message"] as? [String: Any]
            else { return nil }
            return message["content"] as? String
        }
    }

    // MARK: - Custom LLM

    static func anthropicBody(messages: [MeetingChatMessage], model: String) -> [String: Any] {
        // Anthropic separates the system prompt from the turn list rather than carrying it
        // as a message role.
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let turns = messages.filter { $0.role != .system }
        var body: [String: Any] = [
            "model": model,
            "messages": turns.map { ["role": $0.role.rawValue, "content": $0.content] },
            "max_tokens": maxAnswerTokens,
        ]
        if !system.isEmpty { body["system"] = system }
        return body
    }

    private static func sendWithCustomLLM(messages: [MeetingChatMessage], config: AppConfig) async throws -> String {
        let format = CustomLLMFormat(rawValue: config.customLLMFormat) ?? .openAI
        guard let url = MeetingSummaryClient.resolveCustomLLMURL(config: config, format: format) else {
            throw MeetingChatError.notConfigured(backend: "Custom LLM")
        }
        if MeetingSummaryClient.customLLMRequiresAPIKey(config: config), config.customLLMAPIKey.isEmpty {
            throw MeetingChatError.notConfigured(backend: "Custom LLM")
        }

        switch format {
        case .anthropic:
            var request = URLRequest(url: url)
            request.timeoutInterval = chatTimeout
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(config.customLLMAPIKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try? JSONSerialization.data(
                withJSONObject: anthropicBody(messages: messages, model: config.customLLMModel)
            )
            return try await perform(request: request, backend: "Custom LLM") { data in
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return MeetingSummaryClient.extractAnthropicText(from: json)
            }
        case .openAI:
            return try await sendWithChatCompletions(
                messages: messages,
                model: config.customLLMModel,
                requestURL: url,
                apiKey: config.customLLMAPIKey,
                backend: "Custom LLM"
            )
        }
    }

    // MARK: - Shared transport

    private static func perform(
        request: URLRequest,
        backend: String,
        extract: (Data) throws -> String?
    ) async throws -> String {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try MeetingSummaryClient.validateHTTPResponse(response, data: data, backend: backend)
            guard let text = try extract(data), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingChatError.emptyResponse(backend: backend)
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as MeetingChatError {
            throw error
        } catch {
            // Validation failures arrive as MeetingSummaryError, whose text talks about
            // meeting notes. Re-map so the user is told their question failed.
            throw mappedTransportError(error, backend: backend)
        }
    }

    private static func mappedTransportError(_ error: Error, backend: String) -> MeetingChatError {
        if case let MeetingSummaryError.backendFailed(_, statusCode, message) = error {
            return .backendFailed(backend: backend, statusCode: statusCode, message: message)
        }
        return .requestFailed(backend: backend, message: error.localizedDescription)
    }

    static func backendLabel(_ backend: String) -> String {
        MeetingSummaryBackendOption.resolved(backend).label
    }
}
