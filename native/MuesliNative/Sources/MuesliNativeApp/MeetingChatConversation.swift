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

    init(id: UUID = UUID(), role: Role, displayText: String, sentText: String? = nil) {
        self.id = id
        self.role = role
        self.displayText = displayText
        self.sentText = sentText ?? displayText
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

        let request = requestMessages(transcript: transcript, systemPrompt: systemPrompt)
        let transport = send ?? { try await MeetingChatClient.send(messages: $0, config: $1) }

        do {
            let answer = try await transport(request, config)
            turns.append(MeetingChatTurn(role: .assistant, displayText: answer))
        } catch {
            // The failed question stays in the list; removing it would leave the user
            // staring at an error with no record of what they asked.
            lastError = error.localizedDescription
        }

        isSending = false
    }

    /// System context plus the full turn history, oldest first.
    func requestMessages(transcript: String, systemPrompt: String) -> [MeetingChatMessage] {
        var messages: [MeetingChatMessage] = [
            MeetingChatMessage(role: .system, content: systemContent(transcript: transcript, systemPrompt: systemPrompt))
        ]
        for turn in turns {
            messages.append(
                MeetingChatMessage(
                    role: turn.role == .user ? .user : .assistant,
                    content: turn.sentText
                )
            )
        }
        return messages
    }

    private func systemContent(transcript: String, systemPrompt: String) -> String {
        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return systemPrompt }
        return systemPrompt + "\n\n---\n\n" + body
    }
}

/// Meeting-keyed registry so both surfaces resolve the same conversation instance.
@MainActor
final class MeetingChatConversations {
    static let shared = MeetingChatConversations()

    private var byMeeting: [Int64: MeetingChatConversation] = [:]

    func conversation(for meetingID: Int64) -> MeetingChatConversation {
        if let existing = byMeeting[meetingID] { return existing }
        let created = MeetingChatConversation()
        byMeeting[meetingID] = created
        return created
    }

    func forget(meetingID: Int64) {
        byMeeting.removeValue(forKey: meetingID)
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
    """

    static let completed = """
    You are helping someone review a finished meeting. The transcript below is the final \
    record. Lines are labelled by speaker: "You" is the person you are helping, and \
    "Speaker 1", "Speaker 2" and so on are other participants, whose real names are unknown. \
    You may reason about who said what using those labels, but never invent a real name. \
    Speech-to-text errors are common; read for meaning. Answer only from the transcript, and \
    say so plainly when it does not contain the answer.
    """
}
