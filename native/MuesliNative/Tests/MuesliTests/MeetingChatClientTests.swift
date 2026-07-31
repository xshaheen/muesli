import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("MeetingChatClient")
struct MeetingChatClientTests {
    private func message(_ role: MeetingChatMessage.Role, _ content: String) -> MeetingChatMessage {
        MeetingChatMessage(role: role, content: content)
    }

    private func roles(_ body: [String: Any], key: String) -> [String] {
        let entries = (body[key] as? [[String: Any]]) ?? []
        return entries.compactMap { $0["role"] as? String }
    }

    // MARK: - Backend resolution

    @Test("empty backend selection resolves to ChatGPT")
    func emptyBackendResolvesToChatGPT() {
        var config = AppConfig()
        config.meetingSummaryBackend = ""

        #expect(MeetingChatClient.resolvedBackend(config: config) == MeetingSummaryBackendOption.chatGPT.backend)
    }

    @Test("each configured backend resolves to itself")
    func explicitBackendsResolveToThemselves() {
        for option in MeetingSummaryBackendOption.all {
            var config = AppConfig()
            config.meetingSummaryBackend = option.backend

            #expect(MeetingChatClient.resolvedBackend(config: config) == option.backend)
        }
    }

    @Test("backend resolution is case-insensitive")
    func backendResolutionLowercases() {
        var config = AppConfig()
        config.meetingSummaryBackend = "OpenRouter"

        #expect(MeetingChatClient.resolvedBackend(config: config) == "openrouter")
    }

    // MARK: - Wire formats

    @Test("OpenAI Responses uses input and max_output_tokens")
    func openAIResponsesShape() {
        // Regression guard: /v1/responses rejects the chat-completions token key.
        let body = MeetingChatClient.openAIResponsesBody(
            messages: [message(.system, "ctx"), message(.user, "q")],
            model: "gpt-5.4-mini"
        )

        #expect(body["input"] != nil)
        #expect(body["messages"] == nil)
        #expect(body["max_output_tokens"] != nil)
        #expect(body["max_completion_tokens"] == nil)
        #expect(roles(body, key: "input") == ["system", "user"])
    }

    @Test("chat-completions uses max_completion_tokens only for OpenAI hosts")
    func chatCompletionsTokenKeyIsHostAware() {
        let openAIHosted = MeetingChatClient.chatCompletionsBody(
            messages: [message(.user, "q")],
            model: "m",
            requestURL: URL(string: "https://api.openai.com/v1/chat/completions")!
        )
        #expect(openAIHosted["max_completion_tokens"] != nil)
        #expect(openAIHosted["max_tokens"] == nil)

        let otherHost = MeetingChatClient.chatCompletionsBody(
            messages: [message(.user, "q")],
            model: "m",
            requestURL: URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        )
        #expect(otherHost["max_tokens"] != nil)
        #expect(otherHost["max_completion_tokens"] == nil)
    }

    @Test("Ollama sends messages with streaming disabled")
    func ollamaShape() {
        let body = MeetingChatClient.ollamaBody(
            messages: [message(.system, "ctx"), message(.user, "q")],
            model: "qwen3.5"
        )

        #expect(body["stream"] as? Bool == false)
        #expect(roles(body, key: "messages") == ["system", "user"])
    }

    @Test("Anthropic lifts system out of the turn list")
    func anthropicShape() {
        let body = MeetingChatClient.anthropicBody(
            messages: [
                message(.system, "transcript context"),
                message(.user, "q"),
                message(.assistant, "a"),
                message(.user, "follow-up"),
            ],
            model: "claude"
        )

        #expect(body["system"] as? String == "transcript context")
        #expect(roles(body, key: "messages") == ["user", "assistant", "user"])
    }

    @Test("multi-turn order and roles survive body construction")
    func multiTurnOrderPreserved() {
        let messages = [
            message(.system, "ctx"),
            message(.user, "first"),
            message(.assistant, "answer"),
            message(.user, "second"),
        ]
        let body = MeetingChatClient.chatCompletionsBody(
            messages: messages,
            model: "m",
            requestURL: URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        )

        #expect(roles(body, key: "messages") == ["system", "user", "assistant", "user"])
        let contents = ((body["messages"] as? [[String: Any]]) ?? []).compactMap { $0["content"] as? String }
        #expect(contents == ["ctx", "first", "answer", "second"])
    }

    // MARK: - Budget

    @Test("an under-budget request passes through unchanged")
    func underBudgetUnchanged() throws {
        let messages = [message(.system, "short"), message(.user, "q")]

        let result = try MeetingChatClient.budgetedMessages(messages, backend: "openrouter")

        #expect(result == messages)
    }

    @Test("local backends get a smaller budget than hosted ones")
    func localBudgetIsSmaller() {
        let local = MeetingChatClient.Budget.characters(forBackend: MeetingSummaryBackendOption.ollama.backend)
        let hosted = MeetingChatClient.Budget.characters(forBackend: MeetingSummaryBackendOption.openRouter.backend)

        #expect(local < hosted)
    }

    @Test("an over-budget transcript is trimmed from the top, keeping the tail")
    func transcriptTrimmedKeepingTail() throws {
        let limit = MeetingChatClient.Budget.characters(forBackend: "ollama")
        let head = String(repeating: "A", count: limit)
        let tail = "NEWEST-SPEECH-MARKER"
        let messages = [
            message(.system, head + tail),
            message(.user, "what did I miss?"),
        ]

        let result = try MeetingChatClient.budgetedMessages(messages, backend: "ollama")
        let system = try #require(result.first(where: { $0.role == .system }))

        #expect(system.content.contains(tail))
        #expect(!system.content.contains(head))
        #expect(result.contains(where: { $0.role == .user && $0.content == "what did I miss?" }))
    }

    @Test("over-budget history drops oldest turns and keeps the newest question")
    func historyDropsOldestTurns() throws {
        let limit = MeetingChatClient.Budget.characters(forBackend: "ollama")
        let bulky = String(repeating: "B", count: limit / 3)
        let messages = [
            message(.system, "ctx"),
            message(.user, bulky),
            message(.assistant, bulky),
            message(.user, bulky),
            message(.user, "NEWEST-QUESTION"),
        ]

        let result = try MeetingChatClient.budgetedMessages(messages, backend: "ollama")

        #expect(result.count < messages.count)
        #expect(result.first?.role == .system)
        #expect(result.last?.content == "NEWEST-QUESTION")
    }

    @Test("trimming preserves the grounding instructions and cuts only the transcript")
    func trimmingPreservesInstructions() {
        // The failure this prevents: the system message is prompt + transcript, so trimming
        // it as one blob from the head eats the instructions first on any long meeting,
        // leaving raw transcript labelled as system content -- ungrounded, and an open path
        // for meeting speech to read as instruction.
        let prompt = MeetingChatPrompts.completed
        let transcript = String(repeating: "X", count: 5_000) + "NEWEST-SPEECH"
        let system = prompt + MeetingChatClient.transcriptSeparator + transcript

        let trimmed = MeetingChatClient.trimmedKeepingTail(system, to: prompt.count + 400)

        #expect(trimmed.hasPrefix(prompt))
        #expect(trimmed.contains("never invent a real name"))
        #expect(trimmed.contains("NEWEST-SPEECH"))
        #expect(trimmed.count < system.count)
    }

    @Test("trimming a budgeted request keeps the prompt intact end to end")
    func budgetedMessagesKeepInstructions() throws {
        let prompt = MeetingChatPrompts.live
        let transcript = String(repeating: "Y", count: 200_000) + "TAIL-MARKER"
        let messages = [
            message(.system, prompt + MeetingChatClient.transcriptSeparator + transcript),
            message(.user, "what did I miss?"),
        ]

        let result = try MeetingChatClient.budgetedMessages(messages, backend: "ollama")
        let system = try #require(result.first(where: { $0.role == .system }))

        #expect(system.content.hasPrefix(prompt))
        #expect(system.content.contains("TAIL-MARKER"))
    }

    @Test("a newest turn that alone exceeds budget fails preflight rather than being sent")
    func oversizedNewestTurnFailsPreflight() {
        let limit = MeetingChatClient.Budget.characters(forBackend: "ollama")
        let messages = [message(.user, String(repeating: "C", count: limit + 1_000))]

        #expect(throws: MeetingChatError.self) {
            _ = try MeetingChatClient.budgetedMessages(messages, backend: "ollama")
        }
    }

    // MARK: - Errors

    @Test("chat errors never claim meeting notes failed")
    func chatErrorsDoNotMentionNotes() {
        // Guards the decision to keep a chat-specific error type: reusing the summary
        // mapper would tell the user their notes failed after a failed question.
        let errors: [MeetingChatError] = [
            .backendFailed(backend: "OpenAI", statusCode: 500, message: "boom"),
            .emptyResponse(backend: "Ollama"),
            .requestFailed(backend: "LM Studio", message: "offline"),
            .notConfigured(backend: "OpenRouter"),
            .contextOverflow(backend: "Ollama", limit: 1000),
        ]

        for error in errors {
            let text = try? #require(error.errorDescription)
            #expect(text?.lowercased().contains("meeting notes") == false)
            #expect(text?.isEmpty == false)
        }
    }

    @Test("each error names its backend")
    func errorsNameTheirBackend() {
        #expect(MeetingChatError.notConfigured(backend: "OpenRouter").errorDescription?.contains("OpenRouter") == true)
        #expect(MeetingChatError.emptyResponse(backend: "Ollama").errorDescription?.contains("Ollama") == true)
        #expect(
            MeetingChatError.backendFailed(backend: "OpenAI", statusCode: 429, message: "rate limited")
                .errorDescription?.contains("429") == true
        )
    }

    @Test("unconfigured API-key backends refuse before sending")
    func unconfiguredBackendThrowsNotConfigured() async {
        var config = AppConfig()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.openAI.backend
        config.openAIAPIKey = ""

        await #expect(throws: MeetingChatError.self) {
            _ = try await MeetingChatClient.send(
                messages: [MeetingChatMessage(role: .user, content: "q")],
                config: config
            )
        }
    }
}
