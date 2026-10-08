import Foundation
import ImlaCore
import Testing
@testable import ImlaNativeApp

@Suite("Hosted dictation outcome")
struct HostedDictationOutcomeTests {
    struct SuccessCase: Sendable, CustomTestStringConvertible {
        let label: String
        let hosted: HostedDictationResult
        let expectedIdentity: DictationModelIdentity
        var testDescription: String { label }
    }

    @Test("hosted success records the hosted identity and skips cleanup", arguments: [
        SuccessCase(
            label: "openai realtime",
            hosted: HostedDictationResult(
                text: "hello",
                backend: "openai-realtime",
                model: "gpt-realtime-transcribe",
                endpoint: "wss://api.openai.com/v1/realtime"
            ),
            expectedIdentity: DictationModelIdentity(
                backend: "openai-realtime",
                model: "gpt-realtime-transcribe",
                name: "gpt-realtime-transcribe",
                endpoint: "wss://api.openai.com/v1/realtime"
            )
        ),
        SuccessCase(
            label: "openrouter",
            hosted: HostedDictationResult(
                text: "hello",
                backend: "openrouter-stt",
                model: "provider/transcribe",
                endpoint: "https://openrouter.ai/api/v1/audio/transcriptions"
            ),
            expectedIdentity: DictationModelIdentity(
                backend: "openrouter-stt",
                model: "provider/transcribe",
                name: "provider/transcribe",
                endpoint: "https://openrouter.ai/api/v1/audio/transcriptions"
            )
        ),
        SuccessCase(
            label: "provider without model metadata",
            hosted: HostedDictationResult(text: "hello", backend: "openai-realtime"),
            expectedIdentity: DictationModelIdentity(
                backend: "openai-realtime",
                model: "",
                name: "Not recorded"
            )
        ),
    ])
    func hostedSuccess(_ testCase: SuccessCase) throws {
        var fallbacksConsulted = false
        let decision = try HostedDictationDecision.resolve(
            hostedOutcome: .success(testCase.hosted),
            selected: .parakeetUnified,
            taskIsCancelled: false,
            isCurrentSession: true,
            availableFallbacks: {
                fallbacksConsulted = true
                return [.parakeetUnified]
            }
        )

        #expect(decision.source == .hosted(testCase.hosted))
        #expect(decision.transcriptionModel == testCase.expectedIdentity)
        #expect(decision.skipsCleanup)
        // The downloaded-model scan stays off the hosted success path.
        #expect(!fallbacksConsulted)
    }

    struct FallbackCase: Sendable, CustomTestStringConvertible {
        let label: String
        let error: any Error & Sendable
        let selected: BackendOption
        let available: [BackendOption]
        let expectedFallback: BackendOption
        var testDescription: String { label }
    }

    @Test("provider failure with a downloaded local model records the fallback identity", arguments: [
        FallbackCase(
            label: "timeout falls back to the selected local model",
            error: OpenAITranscriptionError.timedOut,
            selected: .whisperSmall,
            available: [.parakeetUnified, .whisperSmall],
            expectedFallback: .whisperSmall
        ),
        FallbackCase(
            label: "network error falls back to the first compatible model",
            error: URLError(.notConnectedToInternet),
            selected: .nemotron35Multilingual,
            available: [.nemotron35Multilingual, .parakeetUnified],
            expectedFallback: .parakeetUnified
        ),
    ])
    func providerFailureFallsBack(_ testCase: FallbackCase) throws {
        let decision = try HostedDictationDecision.resolve(
            hostedOutcome: .failure(testCase.error),
            selected: testCase.selected,
            taskIsCancelled: false,
            isCurrentSession: true,
            availableFallbacks: { testCase.available }
        )

        #expect(decision.source == .localFallback(testCase.expectedFallback))
        #expect(decision.transcriptionModel == DictationModelIdentity(
            backend: testCase.expectedFallback.backend,
            model: testCase.expectedFallback.model,
            name: testCase.expectedFallback.label
        ))
        #expect(decision.transcriptionModel.endpoint == nil)
        #expect(!decision.skipsCleanup)
    }

    struct PropagationCase: Sendable, CustomTestStringConvertible {
        let label: String
        let error: any Error & Sendable
        let taskIsCancelled: Bool
        let isCurrentSession: Bool
        let available: [BackendOption]
        var testDescription: String { label }
    }

    @Test("cancellation and unrecoverable failures propagate rather than falling back", arguments: [
        PropagationCase(
            label: "cancellation error",
            error: CancellationError(),
            taskIsCancelled: false,
            isCurrentSession: true,
            available: [.parakeetUnified]
        ),
        PropagationCase(
            label: "cancelled URL request",
            error: URLError(.cancelled),
            taskIsCancelled: false,
            isCurrentSession: true,
            available: [.parakeetUnified]
        ),
        PropagationCase(
            label: "provider failure after the job was cancelled",
            error: OpenAITranscriptionError.timedOut,
            taskIsCancelled: true,
            isCurrentSession: true,
            available: [.parakeetUnified]
        ),
        PropagationCase(
            label: "provider failure from a superseded session",
            error: OpenAITranscriptionError.timedOut,
            taskIsCancelled: false,
            isCurrentSession: false,
            available: [.parakeetUnified]
        ),
        PropagationCase(
            label: "provider failure with no downloaded fallback",
            error: OpenAITranscriptionError.timedOut,
            taskIsCancelled: false,
            isCurrentSession: true,
            available: []
        ),
        PropagationCase(
            label: "provider failure with only a streaming model downloaded",
            error: OpenAITranscriptionError.timedOut,
            taskIsCancelled: false,
            isCurrentSession: true,
            available: [.nemotron35Multilingual]
        ),
    ])
    func failurePropagates(_ testCase: PropagationCase) throws {
        var thrown: Error?
        do {
            _ = try HostedDictationDecision.resolve(
                hostedOutcome: .failure(testCase.error),
                selected: .parakeetUnified,
                taskIsCancelled: testCase.taskIsCancelled,
                isCurrentSession: testCase.isCurrentSession,
                availableFallbacks: { testCase.available }
            )
        } catch {
            thrown = error
        }

        let error = try #require(thrown)
        // The provider's own error propagates, so callers can still tell a
        // cancellation from a failure.
        #expect(String(reflecting: error) == String(reflecting: testCase.error))
    }
}
