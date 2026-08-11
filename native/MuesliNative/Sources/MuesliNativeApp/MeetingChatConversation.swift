import Foundation
import MuesliCore
import Observation

typealias MeetingChatTurn = MeetingChatTurnRecord

/// Conversation state for one meeting.
///
/// Owned above the views, not inside them. Both chat surfaces -- the meeting detail tab and
/// the floating panel -- render the same composer, so view-local state would give each its
/// own copy and a question asked in the panel would vanish when the user switched to the
/// tab. Shared ownership keeps history continuous across surfaces; the registry's store-backed
/// instance keeps completed exchanges continuous across cache eviction and app restarts.
@MainActor
@Observable
final class MeetingChatConversation {
    private(set) var turns: [MeetingChatTurn] = []
    private(set) var isSending = false
    private(set) var lastError: String?
    private let persistTurns: (([MeetingChatTurn]) async throws -> Void)?

    init(
        turns: [MeetingChatTurn] = [],
        lastError: String? = nil,
        persistTurns: (([MeetingChatTurn]) async throws -> Void)? = nil
    ) {
        self.turns = turns
        self.lastError = lastError
        self.persistTurns = persistTurns
    }

    var isEmpty: Bool { turns.isEmpty }

    func clearError() {
        lastError = nil
    }

    /// Composes the request, sends it, and records the reply.
    ///
    /// The transcript is supplied per call rather than stored, because it changes as the
    /// meeting runs and differs by surface state (live vs. finalized).
    func send(
        displayText: String,
        sentText: String? = nil,
        transcript: String,
        systemPrompt: String,
        manualNotes: String = "",
        config: AppConfig,
        send: (([MeetingChatMessage], AppConfig) async throws -> String)? = nil
    ) async {
        let question = (sentText ?? displayText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return }

        lastError = nil
        isSending = true
        turns.append(
            MeetingChatTurn(role: .user, displayText: displayText, sentText: question)
        )

        let request = requestMessages(
            transcript: transcript,
            systemPrompt: systemPrompt,
            manualNotes: manualNotes
        )
        let transport = send ?? { try await MeetingChatClient.send(messages: $0, config: $1) }

        do {
            let answer = try await transport(request, config)
            turns.append(MeetingChatTurn(role: .assistant, displayText: answer))
            if let persistenceError = await persistHistoryError() {
                lastError = persistenceError
            }
        } catch {
            // The failed question stays in the list; removing it would leave the user
            // staring at an error with no record of what they asked. It is marked unanswered
            // so it does not enter later requests.
            if let index = turns.lastIndex(where: { $0.role == .user }) {
                turns[index].wasAnswered = false
            }
            lastError = error.localizedDescription
            if let persistenceError = await persistHistoryError() {
                lastError = "\(lastError ?? "The request failed.") \(persistenceError)"
            }
        }

        isSending = false
    }

    private func persistHistoryError() async -> String? {
        guard let persistTurns else { return nil }
        do {
            try await persistTurns(turns)
            return nil
        } catch {
            return "Chat history could not be saved: \(error.localizedDescription)"
        }
    }

    /// System context plus the answered turn history, oldest first.
    /// The conversation as plain text, for the panel's copy button.
    func transcriptForCopying() -> String {
        turns.map { turn in
            let speaker = turn.role == .user ? "You" : "Muesli"
            return "\(speaker): \(turn.displayText)"
        }.joined(separator: "\n\n")
    }

    func requestMessages(
        transcript: String,
        systemPrompt: String,
        manualNotes: String = ""
    ) -> [MeetingChatMessage] {
        let system = systemContent(
            transcript: transcript,
            systemPrompt: systemPrompt,
            manualNotes: manualNotes
        )
        var messages: [MeetingChatMessage] = [
            MeetingChatMessage(
                role: .system,
                content: system.content,
                trimEligibleTailStart: system.trimEligibleTailStart
            )
        ]
        for turn in turns where turn.wasAnswered {
            messages.append(
                MeetingChatMessage(
                    role: turn.role == .user ? .user : .assistant,
                    content: turn.sentText
                )
            )
        }
        return messages
    }

    private func systemContent(
        transcript: String,
        systemPrompt: String,
        manualNotes: String
    ) -> (content: String, trimEligibleTailStart: Int) {
        var content = systemPrompt
        // The user's own notes are what they chose to write down -- often the
        // decision or the action item the transcript only implies. Without them
        // "what did I miss" answers from the conversation alone and misses the
        // thing the user themselves flagged as mattering.
        let notes = manualNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            content += MeetingChatClient.transcriptSeparator
                + "The user's own notes from this meeting:\n" + notes
        }
        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            content += MeetingChatClient.transcriptSeparator
        }
        let trimEligibleTailStart = content.count
        content += body
        return (content, trimEligibleTailStart)
    }
}

/// Meeting-keyed registry so both surfaces resolve the same conversation instance.
@MainActor
final class MeetingChatConversations {
    static let shared = MeetingChatConversations(
        store: DictationStore(
            databaseURL: MuesliPaths.defaultDatabaseURL(
                appName: AppIdentity.supportDirectoryName
            )
        )
    )

    private static let capacity = 10
    private var byMeeting: [Int64: MeetingChatConversation] = [:]
    private var meetingIDsByRecency: [Int64] = []
    private let store: DictationStore?

    init(store: DictationStore? = nil) {
        self.store = store
    }

    func conversation(for meetingID: Int64) -> MeetingChatConversation {
        if let existing = byMeeting[meetingID] {
            markRecentlyUsed(meetingID)
            return existing
        }

        evictIdleConversationsIfNeeded()

        let created: MeetingChatConversation
        if let store {
            let persistTurns = persistenceHandler(for: meetingID, store: store)
            do {
                let turns = try store.meetingChatTurns(meetingID: meetingID)
                created = MeetingChatConversation(
                    turns: turns,
                    persistTurns: persistTurns
                )
            } catch {
                created = MeetingChatConversation(
                    lastError: "Chat history could not be loaded: \(error.localizedDescription)",
                    persistTurns: recoveryPersistenceHandler(for: meetingID, store: store)
                )
            }
        } else {
            created = MeetingChatConversation()
        }
        byMeeting[meetingID] = created
        meetingIDsByRecency.append(meetingID)
        return created
    }

    private func persistenceHandler(
        for meetingID: Int64,
        store: DictationStore
    ) -> ([MeetingChatTurn]) async throws -> Void {
        let databaseURL = store.resolvedDatabaseURL
        return { turns in
            try await Task.detached(priority: .utility) {
                try DictationStore(databaseURL: databaseURL).replaceMeetingChatTurns(
                    meetingID: meetingID,
                    turns: turns
                )
            }.value
        }
    }

    /// A failed read must not turn the next send into a destructive whole-history overwrite.
    /// Retrying the read first lets transient failures recover while malformed payloads stay
    /// untouched for a future repair path.
    private func recoveryPersistenceHandler(
        for meetingID: Int64,
        store: DictationStore
    ) -> ([MeetingChatTurn]) async throws -> Void {
        let databaseURL = store.resolvedDatabaseURL
        return { turns in
            try await Task.detached(priority: .utility) {
                let backgroundStore = DictationStore(databaseURL: databaseURL)
                let storedTurns = try backgroundStore.meetingChatTurns(meetingID: meetingID)
                let storedIDs = Set(storedTurns.map(\.id))
                let mergedTurns = storedTurns + turns.filter { !storedIDs.contains($0.id) }
                try backgroundStore.replaceMeetingChatTurns(
                    meetingID: meetingID,
                    turns: mergedTurns
                )
            }.value
        }
    }

    private func evictIdleConversationsIfNeeded() {
        while byMeeting.count >= Self.capacity {
            guard let leastRecentlyUsedMeetingID = meetingIDsByRecency.first(where: {
                byMeeting[$0]?.isSending == false
            }) else {
                // An in-flight conversation may still persist after its transport returns.
                // Temporarily exceeding capacity preserves one writer for that meeting.
                return
            }
            byMeeting.removeValue(forKey: leastRecentlyUsedMeetingID)
            meetingIDsByRecency.removeAll { $0 == leastRecentlyUsedMeetingID }
        }
    }

    func forget(meetingID: Int64) {
        byMeeting.removeValue(forKey: meetingID)
        meetingIDsByRecency.removeAll { $0 == meetingID }
    }

    /// For bulk deletion. Clearing every meeting must also clear the questions and answers
    /// about them, which otherwise stay resident until the app quits.
    func forgetAll() {
        byMeeting.removeAll()
        meetingIDsByRecency.removeAll()
    }

    private func markRecentlyUsed(_ meetingID: Int64) {
        meetingIDsByRecency.removeAll { $0 == meetingID }
        meetingIDsByRecency.append(meetingID)
    }
}

/// System prompts. The post-meeting transcript carries diarized speaker labels that the live
/// transcript does not, so the model is told which it is looking at rather than left to guess.
enum MeetingChatPrompts {
    static let live = """
    You are helping someone during a live meeting. The transcript below is what has been said \
    so far, and may end mid-sentence. Speech-to-text errors are common; read for meaning. \
    Answer only from the transcript. If it does not contain the answer, say so plainly rather \
    than inventing one. Be brief -- the user is in a meeting.

    The user's own notes may be included above the transcript. Treat them as what \
    the user considered worth writing down, not as another speaker's words.

    Format your answer in Markdown: `-` for bullets, `**bold**` for emphasis, `##` \
    for any heading. Keep it short enough to read at a glance.
    """

    static let completed = """
    You are helping someone review a finished meeting. The transcript below is the final \
    record. Lines are labelled by speaker: "You" is the person you are helping, and \
    "Speaker 1", "Speaker 2" and so on are other participants, whose real names are unknown. \
    You may reason about who said what using those labels, but never invent a real name. \
    Speech-to-text errors are common; read for meaning. Answer only from the transcript, and \
    say so plainly when it does not contain the answer.

    The user's own notes may be included above the transcript. Treat them as what \
    the user considered worth writing down, not as another speaker's words.

    Format your answer in Markdown: `-` for bullets, `**bold**` for emphasis, `##` \
    for any heading.
    """
}
