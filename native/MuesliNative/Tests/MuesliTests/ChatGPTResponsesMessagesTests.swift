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

    @Test("assistant turns use output_text, user turns use input_text")
    func assistantTurnsUseOutputText() {
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
