import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("MeetingChatConversation")
@MainActor
struct MeetingChatConversationTests {
    private func stubTransport(_ reply: String) -> ([MeetingChatMessage], AppConfig) async throws -> String {
        { _, _ in reply }
    }

    private func failingTransport(_ error: MeetingChatError) -> ([MeetingChatMessage], AppConfig) async throws -> String {
        { _, _ in throw error }
    }

    @Test("a successful exchange records question then answer, in order")
    func successfulExchangeRecordsBothTurns() async {
        let conversation = MeetingChatConversation()

        await conversation.send(
            displayText: "what did I miss?",
            transcript: "[10:00:00] Speaker 1: we shipped it",
            systemPrompt: MeetingChatPrompts.live,
            config: AppConfig(),
            send: stubTransport("They shipped it.")
        )

        #expect(conversation.turns.count == 2)
        #expect(conversation.turns[0].role == .user)
        #expect(conversation.turns[0].displayText == "what did I miss?")
        #expect(conversation.turns[1].role == .assistant)
        #expect(conversation.turns[1].displayText == "They shipped it.")
        #expect(conversation.isSending == false)
        #expect(conversation.lastError == nil)
    }

    @Test("a failed send records the error and keeps the question visible")
    func failedSendKeepsQuestionAndRecordsError() async {
        let conversation = MeetingChatConversation()

        await conversation.send(
            displayText: "why did it fail?",
            transcript: "transcript",
            systemPrompt: MeetingChatPrompts.live,
            config: AppConfig(),
            send: failingTransport(.notConfigured(backend: "OpenAI"))
        )

        // Removing the question would leave the user reading an error with no record of
        // what they asked.
        #expect(conversation.turns.count == 1)
        #expect(conversation.turns[0].role == .user)
        #expect(conversation.lastError?.contains("OpenAI") == true)
        #expect(conversation.isSending == false)
    }

    @Test("a failed question stays visible but is withheld from later requests")
    func failedQuestionExcludedFromHistory() async {
        // Replaying an unanswered question would send two consecutive user turns and invite
        // the model to answer the stale one instead of the new question.
        let conversation = MeetingChatConversation()

        await conversation.send(
            displayText: "failed question",
            transcript: "T",
            systemPrompt: "P",
            config: AppConfig(),
            send: failingTransport(.notConfigured(backend: "OpenAI"))
        )

        #expect(conversation.turns.count == 1)
        #expect(conversation.turns[0].wasAnswered == false)

        let request = conversation.requestMessages(transcript: "T", systemPrompt: "P")
        #expect(request.count == 1)
        #expect(request[0].role == .system)
        #expect(request.contains(where: { $0.content == "failed question" }) == false)
    }

    @Test("bulk clear drops every conversation")
    func bulkClearDropsAll() async {
        let registry = MeetingChatConversations.shared
        let first = registry.conversation(for: 9001)
        await first.send(
            displayText: "q",
            transcript: "T",
            systemPrompt: "P",
            config: AppConfig(),
            send: stubTransport("a")
        )
        #expect(registry.conversation(for: 9001).turns.isEmpty == false)

        registry.forgetAll()

        #expect(registry.conversation(for: 9001).turns.isEmpty)
    }

    @Test("prior history reaches the request in order")
    func historyReachesRequest() async {
        let conversation = MeetingChatConversation()

        await conversation.send(
            displayText: "first",
            transcript: "T",
            systemPrompt: "P",
            config: AppConfig(),
            send: stubTransport("answer one")
        )

        let request = conversation.requestMessages(transcript: "T", systemPrompt: "P")

        #expect(request.map(\.role) == [.system, .user, .assistant])
        #expect(request[1].content == "first")
        #expect(request[2].content == "answer one")
    }

    @Test("display text and sent text can differ, and the model receives the sent text")
    func displayAndSentTextDiffer() async {
        // This is what lets a recipe chip show its name while sending its full prompt.
        let conversation = MeetingChatConversation()

        await conversation.send(
            displayText: "What did I miss",
            sentText: "Summarize the most recent conversation beats in a few bullets.",
            transcript: "T",
            systemPrompt: "P",
            config: AppConfig(),
            send: stubTransport("ok")
        )

        #expect(conversation.turns[0].displayText == "What did I miss")

        let request = conversation.requestMessages(transcript: "T", systemPrompt: "P")
        #expect(request[1].content == "Summarize the most recent conversation beats in a few bullets.")
    }

    @Test("the transcript is carried as system context, not as a turn")
    func transcriptRidesInSystemMessage() {
        let conversation = MeetingChatConversation()

        let request = conversation.requestMessages(
            transcript: "[10:00:00] You: hello",
            systemPrompt: MeetingChatPrompts.completed
        )

        #expect(request.count == 1)
        #expect(request[0].role == .system)
        #expect(request[0].content.contains("[10:00:00] You: hello"))
        #expect(request[0].content.contains("Speaker 1"))
    }

    @Test("an empty transcript still produces a usable system prompt")
    func emptyTranscriptStillPrompts() {
        let conversation = MeetingChatConversation()

        let request = conversation.requestMessages(transcript: "   ", systemPrompt: "PROMPT")

        #expect(request[0].content == "PROMPT")
    }

    @Test("blank questions are ignored")
    func blankQuestionIgnored() async {
        let conversation = MeetingChatConversation()

        await conversation.send(
            displayText: "   ",
            transcript: "T",
            systemPrompt: "P",
            config: AppConfig(),
            send: stubTransport("should not happen")
        )

        #expect(conversation.turns.isEmpty)
    }

    @Test("the live and completed prompts differ on speaker labels")
    func promptsDifferOnDiarization() {
        // The finalized transcript carries speaker labels the live one lacks; the model is
        // told which it is reading rather than left to infer.
        #expect(MeetingChatPrompts.completed.contains("Speaker 1"))
        #expect(MeetingChatPrompts.live.contains("Speaker 1") == false)
        #expect(MeetingChatPrompts.completed.contains("never invent a real name"))
    }

    @Test("both surfaces resolve the same conversation for one meeting")
    func registryReturnsSharedInstance() async {
        // The property that makes history continuous between the detail tab and the
        // floating panel. Separate instances would silently split the conversation.
        let registry = MeetingChatConversations.shared
        registry.forget(meetingID: 4242)

        let fromTab = registry.conversation(for: 4242)
        let fromPanel = registry.conversation(for: 4242)

        await fromTab.send(
            displayText: "asked in the tab",
            transcript: "T",
            systemPrompt: "P",
            config: AppConfig(),
            send: stubTransport("reply")
        )

        #expect(fromPanel.turns.count == 2)
        #expect(fromPanel.turns[0].displayText == "asked in the tab")

        registry.forget(meetingID: 4242)
    }

    @Test("different meetings get different conversations")
    func registrySeparatesMeetings() {
        let registry = MeetingChatConversations.shared
        registry.forget(meetingID: 1)
        registry.forget(meetingID: 2)

        let first = registry.conversation(for: 1)
        let second = registry.conversation(for: 2)

        #expect(first !== second)

        registry.forget(meetingID: 1)
        registry.forget(meetingID: 2)
    }
}
