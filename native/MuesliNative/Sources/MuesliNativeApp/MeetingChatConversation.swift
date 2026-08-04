import Foundation
import MuesliCore
import Observation

/// One exchange in the conversation.
///
/// `displayText` and `sentText` differ when a saved prompt ("recipe") is used: the list
/// shows "What did I miss", the model receives the full instruction. Keeping both here
/// means the recipe layer adds no state of its own.
struct MeetingChatTurn: Identifiable, Equatable {
    enum Role: Equatable {
        case user, assistant
    }

    let id: UUID
    let role: Role
    let displayText: String
    let sentText: String
    /// False for a question whose request failed. It stays on screen so the user can see
    /// what they asked, but it is withheld from later requests: replaying an unanswered
    /// question would produce two consecutive user turns and invite the model to answer the
    /// stale one.
    var wasAnswered: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        displayText: String,
        sentText: String? = nil,
        wasAnswered: Bool = true
    ) {
        self.id = id
        self.role = role
        self.displayText = displayText
        self.sentText = sentText ?? displayText
        self.wasAnswered = wasAnswered
    }
}

/// Conversation state for one meeting.
///
/// Owned above the views, not inside them. Both chat surfaces -- the meeting detail tab and
/// the floating panel -- render the same composer, so view-local state would give each its
/// own copy and a question asked in the panel would vanish when the user switched to the
/// tab. Shared ownership is what makes history continuous across surfaces.
@MainActor
@Observable
final class MeetingChatConversation {
    private(set) var turns: [MeetingChatTurn] = []
    private(set) var isSending = false
    private(set) var lastError: String?

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
        } catch {
            // The failed question stays in the list; removing it would leave the user
            // staring at an error with no record of what they asked. It is marked unanswered
            // so it does not enter later requests.
            if let index = turns.lastIndex(where: { $0.role == .user }) {
                turns[index].wasAnswered = false
            }
            lastError = error.localizedDescription
        }

        isSending = false
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
    static let shared = MeetingChatConversations()

    private static let capacity = 10
    private var byMeeting: [Int64: MeetingChatConversation] = [:]
    private var meetingIDsByRecency: [Int64] = []

    func conversation(for meetingID: Int64) -> MeetingChatConversation {
        if let existing = byMeeting[meetingID] {
            markRecentlyUsed(meetingID)
            return existing
        }

        if byMeeting.count >= Self.capacity,
           let leastRecentlyUsedMeetingID = meetingIDsByRecency.first {
            byMeeting.removeValue(forKey: leastRecentlyUsedMeetingID)
            meetingIDsByRecency.removeFirst()
        }

        let created = MeetingChatConversation()
        byMeeting[meetingID] = created
        meetingIDsByRecency.append(meetingID)
        return created
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
