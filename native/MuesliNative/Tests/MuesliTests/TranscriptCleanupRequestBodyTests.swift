import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("TranscriptCleanupClient — output cap wiring")
struct TranscriptCleanupRequestBodyTests {
    private var meetingOptions: TranscriptCleanupRequestOptions {
        TranscriptCleanupRequestOptions(
            maxOutputTokens: MeetingTranscriptCleanup.maxOutputTokensPerChunk,
            disableProviderRetention: true,
            preserveLineStructure: true
        )
    }

    private func numPredict(_ body: [String: Any]) -> Int? {
        (body["options"] as? [String: Any])?["num_predict"] as? Int
    }

    // MARK: - Ollama

    @Test("Ollama num_predict carries the caller's cap")
    func ollamaHonorsRequestedCap() {
        // Regression guard: this path hardcoded the dictation default, so meeting
        // chunks were capped at 1000 and every one of them came back truncated.
        let body = TranscriptCleanupClient.ollamaRequestBody(
            systemPrompt: "clean this",
            userPrompt: "transcript",
            model: "qwen3.5",
            options: meetingOptions
        )

        #expect(numPredict(body) == MeetingTranscriptCleanup.maxOutputTokensPerChunk)
    }

    @Test("Ollama falls back to the dictation cap when none is requested")
    func ollamaFallsBackToDefaultCap() {
        let body = TranscriptCleanupClient.ollamaRequestBody(
            systemPrompt: "clean this",
            userPrompt: "transcript",
            model: "qwen3.5",
            options: .dictationDefaults
        )

        #expect(numPredict(body) == TranscriptCleanupClient.defaultMaxOutputTokens)
    }

    // MARK: - Anthropic

    @Test("Anthropic max_tokens carries the caller's cap")
    func anthropicHonorsRequestedCap() {
        let body = TranscriptCleanupClient.anthropicRequestBody(
            systemPrompt: "clean this",
            userPrompt: "transcript",
            model: "claude-sonnet-4",
            options: meetingOptions
        )

        #expect(body["max_tokens"] as? Int == MeetingTranscriptCleanup.maxOutputTokensPerChunk)
    }

    @Test("Anthropic falls back to the dictation cap when none is requested")
    func anthropicFallsBackToDefaultCap() {
        let body = TranscriptCleanupClient.anthropicRequestBody(
            systemPrompt: "clean this",
            userPrompt: "transcript",
            model: "claude-sonnet-4",
            options: .dictationDefaults
        )

        #expect(body["max_tokens"] as? Int == TranscriptCleanupClient.defaultMaxOutputTokens)
    }

    // MARK: - Truncation detection

    @Test("each backend reports a cap hit from its own completion field")
    func hitOutputCapReadsBackendSpecificFields() {
        #expect(TranscriptCleanupClient.responsesHitOutputCap(["status": "incomplete"]))
        #expect(TranscriptCleanupClient.responsesHitOutputCap([
            "incomplete_details": ["reason": "max_output_tokens"],
        ]))
        #expect(TranscriptCleanupClient.responsesHitOutputCap(["status": "completed"]) == false)

        #expect(TranscriptCleanupClient.chatCompletionsHitOutputCap([
            "choices": [["finish_reason": "length"]],
        ]))
        #expect(TranscriptCleanupClient.chatCompletionsHitOutputCap([
            "choices": [["finish_reason": "stop"]],
        ]) == false)

        #expect(TranscriptCleanupClient.anthropicHitOutputCap(["stop_reason": "max_tokens"]))
        #expect(TranscriptCleanupClient.anthropicHitOutputCap(["stop_reason": "end_turn"]) == false)
    }
}
