import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("ChatGPTResponsesClient — multi-turn request shaping")
struct ChatGPTResponsesMessagesTests {
    private func inputEntries(_ body: [String: Any]) -> [[String: Any]] {
        (body["input"] as? [[String: Any]]) ?? []
    }

    private func text(_ entry: [String: Any]) -> String? {
        guard
            let content = entry["content"] as? [[String: Any]],
            let first = content.first
        else { return nil }
        return first["text"] as? String
    }

    private func contentType(_ entry: [String: Any]) -> String? {
        guard
            let content = entry["content"] as? [[String: Any]],
            let first = content.first
        else { return nil }
        return first["type"] as? String
    }

    @Test("system content becomes instructions, not an input entry")
    func systemGoesToInstructions() {
        let body = ChatGPTResponsesClient.requestBody(
            messages: [
                ChatGPTResponsesMessage(role: .system, content: "You summarize meetings."),
                ChatGPTResponsesMessage(role: .user, content: "What did I miss?"),
            ],
            model: "gpt-5.4-mini"
        )

        #expect(body["instructions"] as? String == "You summarize meetings.")

        let entries = inputEntries(body)
        #expect(entries.count == 1)
        #expect(entries.first?["role"] as? String == "user")
        #expect(text(entries[0]) == "What did I miss?")
    }

    @Test("multi-turn history preserves order and roles")
    func historyPreservesOrderAndRoles() {
        let body = ChatGPTResponsesClient.requestBody(
            messages: [
                ChatGPTResponsesMessage(role: .system, content: "Transcript context."),
                ChatGPTResponsesMessage(role: .user, content: "first question"),
                ChatGPTResponsesMessage(role: .assistant, content: "first answer"),
                ChatGPTResponsesMessage(role: .user, content: "follow-up"),
            ],
            model: "gpt-5.4-mini"
        )

        let entries = inputEntries(body)
        #expect(entries.count == 3)
        #expect(entries.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(entries.map { text($0) } == ["first question", "first answer", "follow-up"])
    }

    @Test("user turns use input_text and assistant history uses output_text")
    func replayedTurnsUseRoleMatchedContentTypes() {
        // The live API requires assistant-role content to be `output_text` even when
        // replayed as input: sending `input_text` fails with 400 "Invalid value:
        // 'input_text'. Supported values are: 'output_text' and 'refusal'."
        // (observed 03-08-2026 on the default ChatGPT backend).
        let body = ChatGPTResponsesClient.requestBody(
            messages: [
                ChatGPTResponsesMessage(role: .user, content: "q"),
                ChatGPTResponsesMessage(role: .assistant, content: "a"),
            ],
            model: "gpt-5.4-mini"
        )

        let entries = inputEntries(body)
        #expect(contentType(entries[0]) == "input_text")
        #expect(contentType(entries[1]) == "output_text")
    }

    @Test("two-prompt form produces the same body as its two-message equivalent")
    func twoPromptFormDelegatesToMessageForm() {
        // Guards the refactor that made the legacy entry point delegate: the two paths must
        // not drift, or ChatGPT requests would differ between summary and chat.
        let legacy = ChatGPTResponsesClient.requestBody(
            systemPrompt: "System",
            userPrompt: "User",
            model: "gpt-5.4-mini"
        )
        let viaMessages = ChatGPTResponsesClient.requestBody(
            messages: [
                ChatGPTResponsesMessage(role: .system, content: "System"),
                ChatGPTResponsesMessage(role: .user, content: "User"),
            ],
            model: "gpt-5.4-mini"
        )

        #expect(legacy["instructions"] as? String == viaMessages["instructions"] as? String)
        #expect(legacy["model"] as? String == viaMessages["model"] as? String)
        #expect(legacy["stream"] as? Bool == viaMessages["stream"] as? Bool)
        #expect(legacy["store"] as? Bool == viaMessages["store"] as? Bool)

        let legacyEntries = inputEntries(legacy)
        let messageEntries = inputEntries(viaMessages)
        #expect(legacyEntries.count == messageEntries.count)
        #expect(legacyEntries.map { text($0) } == messageEntries.map { text($0) })
        #expect(legacyEntries.map { contentType($0) } == messageEntries.map { contentType($0) })
    }

    @Test("reasoning effort still resolves through the message form")
    func reasoningEffortSurvivesMessageForm() {
        let body = ChatGPTResponsesClient.requestBody(
            messages: [ChatGPTResponsesMessage(role: .user, content: "q")],
            model: "gpt-5.6-sol"
        )

        #expect((body["reasoning"] as? [String: String])?["effort"] == "high")
    }

    @Test("multiple system messages join rather than overwrite")
    func multipleSystemMessagesJoin() {
        let body = ChatGPTResponsesClient.requestBody(
            messages: [
                ChatGPTResponsesMessage(role: .system, content: "First."),
                ChatGPTResponsesMessage(role: .system, content: "Second."),
                ChatGPTResponsesMessage(role: .user, content: "q"),
            ],
            model: "gpt-5.4-mini"
        )

        let instructions = body["instructions"] as? String
        #expect(instructions?.contains("First.") == true)
        #expect(instructions?.contains("Second.") == true)
    }
}

@Suite("ChatGPTResponsesClient — truncation reporting")
struct ChatGPTResponsesTruncationTests {
    private func payload(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test("a terminal response.incomplete event reports a cap hit")
    func incompleteTerminalEventIsTruncated() throws {
        // Regression guard: cleanup used to hardcode wasTruncated to false on this
        // backend, so a chunk cut off mid-sentence passed validation and was stored
        // as the repaired transcript.
        let event = try payload(
            """
            {
              "type": "response.incomplete",
              "response": {
                "status": "incomplete",
                "incomplete_details": { "reason": "max_output_tokens" }
              }
            }
            """
        )

        #expect(ChatGPTResponsesClient.hitOutputCap(event))
    }

    @Test("a completed response reports no cap hit")
    func completedTerminalEventIsNotTruncated() throws {
        let event = try payload(
            """
            {
              "type": "response.completed",
              "response": { "status": "completed", "incomplete_details": null }
            }
            """
        )

        #expect(ChatGPTResponsesClient.hitOutputCap(event) == false)
    }

    @Test("in-progress and delta events never report a cap hit")
    func inFlightEventsAreNotTruncated() throws {
        // `in_progress` responses carry the same envelope as the terminal event, so
        // matching on the envelope alone would flag every stream as truncated.
        let inProgress = try payload(
            """
            {"type": "response.in_progress", "response": {"status": "in_progress"}}
            """
        )
        let delta = try payload(
            """
            {"type": "response.output_text.delta", "delta": "hello"}
            """
        )

        #expect(ChatGPTResponsesClient.hitOutputCap(inProgress) == false)
        #expect(ChatGPTResponsesClient.hitOutputCap(delta) == false)
    }
}
