import Testing
import Foundation
import MuesliCore
import SQLite3
@testable import MuesliNativeApp

private actor MeetingChatReplyGate {
    private var continuation: CheckedContinuation<String, Never>?
    private var pendingReply: String?

    func wait() async -> String {
        if let pendingReply {
            self.pendingReply = nil
            return pendingReply
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(returning reply: String) {
        if let continuation {
            continuation.resume(returning: reply)
            self.continuation = nil
        } else {
            pendingReply = reply
        }
    }
}

@Suite("MeetingChatConversation")
@MainActor
struct MeetingChatConversationTests {
    private enum PersistenceTestError: Error, LocalizedError {
        case unavailable

        var errorDescription: String? { "test storage unavailable" }
    }

    private func stubTransport(_ reply: String) -> ([MeetingChatMessage], AppConfig) async throws -> String {
        { _, _ in reply }
    }

    private func failingTransport(_ error: MeetingChatError) -> ([MeetingChatMessage], AppConfig) async throws -> String {
        { _, _ in throw error }
    }

    private func makeStoreAndMeeting() throws -> (
        store: DictationStore,
        meetingID: Int64,
        temporaryDirectory: URL
    ) {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-chat-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let databaseURL = temporaryDirectory.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: databaseURL)
        try store.migrateIfNeeded()
        let now = Date()
        let meetingID = try store.insertMeeting(
            title: "Persisted chat",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "Transcript",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        return (store, meetingID, temporaryDirectory)
    }

    private func setRawChatHistory(
        _ json: String,
        meetingID: Int64,
        store: DictationStore
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK else {
            throw PersistenceTestError.unavailable
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "UPDATE meetings SET chat_history_json = ? WHERE id = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw PersistenceTestError.unavailable
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (json as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 2, meetingID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersistenceTestError.unavailable
        }
    }

    private func rawChatHistory(meetingID: Int64, store: DictationStore) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK else {
            throw PersistenceTestError.unavailable
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT chat_history_json FROM meetings WHERE id = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw PersistenceTestError.unavailable
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw PersistenceTestError.unavailable
        }
        return String(cString: value)
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
        let registry = MeetingChatConversations()
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
        let registry = MeetingChatConversations()
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
    }

    @Test("different meetings get different conversations")
    func registrySeparatesMeetings() {
        let registry = MeetingChatConversations()
        let first = registry.conversation(for: 1)
        let second = registry.conversation(for: 2)

        #expect(first !== second)
    }

    @Test("the registry evicts the least recently used conversation at capacity")
    func registryEvictsLeastRecentlyUsedConversation() {
        let registry = MeetingChatConversations()
        let conversations = (1 ... 10).map { meetingID in
            registry.conversation(for: Int64(meetingID))
        }

        // Reading the oldest conversation makes meeting 2 the least recently used.
        #expect(registry.conversation(for: 1) === conversations[0])

        _ = registry.conversation(for: 11)

        #expect(registry.conversation(for: 1) === conversations[0])
        #expect(registry.conversation(for: 2) !== conversations[1])
    }

    @Test("the registry does not evict a conversation while its request is in flight")
    func registryKeepsInFlightConversationResident() async throws {
        let (store, meetingID, temporaryDirectory) = try makeStoreAndMeeting()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let registry = MeetingChatConversations(store: store)
        let conversation = registry.conversation(for: meetingID)
        let replyGate = MeetingChatReplyGate()
        let sendTask = Task {
            await conversation.send(
                displayText: "Still working?",
                transcript: "T",
                systemPrompt: "P",
                config: AppConfig(),
                send: { _, _ in await replyGate.wait() }
            )
        }
        while !conversation.isSending {
            await Task.yield()
        }

        for otherMeetingID in 2 ... 11 {
            _ = registry.conversation(for: Int64(otherMeetingID))
        }

        #expect(registry.conversation(for: meetingID) === conversation)

        await replyGate.resume(returning: "Finished.")
        await sendTask.value
        #expect(try store.meetingChatTurns(meetingID: meetingID).count == 2)
    }

    @Test("conversation history survives registry reconstruction")
    func conversationHistorySurvivesRegistryReconstruction() async throws {
        let (store, meetingID, temporaryDirectory) = try makeStoreAndMeeting()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let firstRegistry = MeetingChatConversations(store: store)

        await firstRegistry.conversation(for: meetingID).send(
            displayText: "What did I miss?",
            sentText: "Summarize the latest decisions.",
            transcript: "T",
            systemPrompt: "P",
            config: AppConfig(),
            send: stubTransport("The launch moved to Friday.")
        )

        let reloaded = MeetingChatConversations(store: store).conversation(for: meetingID)

        #expect(reloaded.turns.count == 2)
        #expect(reloaded.turns[0].role == .user)
        #expect(reloaded.turns[0].displayText == "What did I miss?")
        #expect(reloaded.turns[0].sentText == "Summarize the latest decisions.")
        #expect(reloaded.turns[1].role == .assistant)
        #expect(reloaded.turns[1].displayText == "The launch moved to Friday.")
    }

    @Test("failed exchanges survive reconstruction without entering later requests")
    func failedExchangeSurvivesRegistryReconstruction() async throws {
        let (store, meetingID, temporaryDirectory) = try makeStoreAndMeeting()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let registry = MeetingChatConversations(store: store)

        await registry.conversation(for: meetingID).send(
            displayText: "Question that failed",
            transcript: "T",
            systemPrompt: "P",
            config: AppConfig(),
            send: failingTransport(.notConfigured(backend: "OpenAI"))
        )

        let reloaded = MeetingChatConversations(store: store).conversation(for: meetingID)
        #expect(reloaded.turns.count == 1)
        #expect(reloaded.turns[0].wasAnswered == false)
        #expect(reloaded.requestMessages(transcript: "T", systemPrompt: "P").count == 1)
    }

    @Test("persistence failures remain visible after successful and failed requests")
    func persistenceFailuresRemainVisible() async {
        let success = MeetingChatConversation(
            persistTurns: { _ in throw PersistenceTestError.unavailable }
        )
        await success.send(
            displayText: "Question",
            transcript: "T",
            systemPrompt: "P",
            config: AppConfig(),
            send: stubTransport("Answer")
        )
        #expect(success.lastError?.contains("test storage unavailable") == true)

        let failure = MeetingChatConversation(
            persistTurns: { _ in throw PersistenceTestError.unavailable }
        )
        await failure.send(
            displayText: "Question",
            transcript: "T",
            systemPrompt: "P",
            config: AppConfig(),
            send: failingTransport(.notConfigured(backend: "OpenAI"))
        )
        #expect(failure.lastError?.contains("test storage unavailable") == true)
        #expect(failure.lastError?.contains("OpenAI") == true)
    }

    @Test("an unreadable history is not overwritten by the next exchange")
    func unreadableHistoryIsPreserved() async throws {
        let (store, meetingID, temporaryDirectory) = try makeStoreAndMeeting()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let malformedJSON = "not valid JSON"
        try setRawChatHistory(malformedJSON, meetingID: meetingID, store: store)
        let conversation = MeetingChatConversations(store: store).conversation(for: meetingID)

        #expect(conversation.lastError?.contains("could not be loaded") == true)
        await conversation.send(
            displayText: "New question",
            transcript: "T",
            systemPrompt: "P",
            config: AppConfig(),
            send: stubTransport("New answer")
        )

        #expect(try rawChatHistory(meetingID: meetingID, store: store) == malformedJSON)
        #expect(conversation.lastError?.contains("could not be saved") == true)
    }

    // MARK: - The user's own notes as context

    @Test("the user's notes reach the model alongside the transcript")
    func manualNotesRideInSystemMessage() {
        // Notes are where the user records the decision the transcript only implies.
        // Without them, "what did I miss" answers from the conversation alone.
        let conversation = MeetingChatConversation()

        let request = conversation.requestMessages(
            transcript: "[10:00:00] Speaker 1: we shipped it",
            systemPrompt: MeetingChatPrompts.completed,
            manualNotes: "follow up with Ahmed about the migration"
        )

        #expect(request.count == 1)
        #expect(request[0].content.contains("follow up with Ahmed about the migration"))
        #expect(request[0].content.contains("we shipped it"))
    }

    @Test("notes are labelled as the user's, not as another speaker")
    func manualNotesAreLabelled() {
        let conversation = MeetingChatConversation()

        let request = conversation.requestMessages(
            transcript: "T",
            systemPrompt: "P",
            manualNotes: "my note"
        )

        #expect(request[0].content.contains("The user's own notes"))
    }

    @Test("no notes means no notes section")
    func absentNotesAddNothing() {
        let conversation = MeetingChatConversation()

        let request = conversation.requestMessages(
            transcript: "T",
            systemPrompt: "P",
            manualNotes: "   "
        )

        #expect(request[0].content.contains("The user's own notes") == false)
    }

    @Test("a meeting with notes but no transcript still asks a usable question")
    func notesWithoutTranscript() {
        let conversation = MeetingChatConversation()

        let request = conversation.requestMessages(
            transcript: "",
            systemPrompt: "P",
            manualNotes: "just my notes"
        )

        #expect(request[0].content.contains("just my notes"))
    }

    @Test("budgeting preserves all manual notes and trims only the transcript tail")
    func budgetingPreservesManualNotes() throws {
        let conversation = MeetingChatConversation()
        let limit = MeetingChatClient.Budget.characters(forBackend: "ollama")
        let notes = "KEEP-NOTES-BEFORE"
            + MeetingChatClient.transcriptSeparator
            + "KEEP-NOTES-AFTER"
        let transcriptHead = "EARLIEST-TRANSCRIPT "
            + String(repeating: "OLD-TRANSCRIPT ", count: limit / 4)
        let transcriptTail = "NEWEST-TRANSCRIPT"
        let request = conversation.requestMessages(
            transcript: transcriptHead + transcriptTail,
            systemPrompt: "GROUNDING-PROMPT",
            manualNotes: notes
        ) + [MeetingChatMessage(role: .user, content: "what changed?")]

        let budgeted = try MeetingChatClient.budgetedMessages(request, backend: "ollama")
        let system = try #require(budgeted.first)

        #expect(system.content.contains("GROUNDING-PROMPT"))
        #expect(system.content.contains("KEEP-NOTES-BEFORE"))
        #expect(system.content.contains("KEEP-NOTES-AFTER"))
        #expect(system.content.contains("NEWEST-TRANSCRIPT"))
        #expect(system.content.contains("EARLIEST-TRANSCRIPT") == false)
        #expect(system.content.contains("[earlier transcript trimmed]"))
    }

    @Test("both prompts ask for markdown, because the view renders it")
    func promptsRequestMarkdown() {
        #expect(MeetingChatPrompts.live.contains("Markdown"))
        #expect(MeetingChatPrompts.completed.contains("Markdown"))
    }

    // MARK: - Copying a conversation

    @Test("copying a conversation yields both sides, labelled")
    func copyIncludesBothSides() async {
        let conversation = MeetingChatConversation()
        await conversation.send(
            displayText: "what did I miss?",
            transcript: "T",
            systemPrompt: "P",
            config: AppConfig(),
            send: { _, _ in "They shipped it." }
        )

        let copied = conversation.transcriptForCopying()

        #expect(copied.contains("You: what did I miss?"))
        #expect(copied.contains("Muesli: They shipped it."))
    }

    @Test("copying an empty conversation yields nothing rather than stray labels")
    func copyEmptyConversation() {
        #expect(MeetingChatConversation().transcriptForCopying().isEmpty)
    }
}
