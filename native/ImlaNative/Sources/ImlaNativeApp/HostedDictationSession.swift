import Foundation
import ImlaCore

struct HostedDictationResult: Equatable, Sendable {
    let text: String
    let backend: String
    var model: String? = nil
    var endpoint: String? = nil
}

protocol HostedDictationSession: AnyObject {
    var acceptsLiveAudio: Bool { get }
    func append(_ samples: [Float])
    func finish(recordedWAVURL: URL) async throws -> HostedDictationResult
    func cancel()
}

final class OpenAIHostedDictationSession: HostedDictationSession {
    private let stream: OpenAIRealtimeDictationStream
    private let model: String

    let acceptsLiveAudio = true

    init(configuration: OpenAIDictationConfiguration) {
        model = configuration.model
        stream = OpenAIRealtimeDictationStream(configuration: configuration)
    }

    func append(_ samples: [Float]) {
        stream.append(samples)
    }

    func finish(recordedWAVURL _: URL) async throws -> HostedDictationResult {
        HostedDictationResult(text: try await stream.finish(), backend: "openai-realtime", model: model,
            endpoint: OpenAIRealtimeProtocol.endpoint.absoluteString)
    }

    func cancel() {
        stream.cancel()
    }
}

final class OpenRouterHostedDictationSession: HostedDictationSession, @unchecked Sendable {
    private let configuration: OpenRouterDictationConfiguration
    private let client: OpenRouterTranscriptionClient
    private let lock = NSLock()
    private var task: Task<OpenRouterTranscriptionResult, Error>?
    private var cancelled = false

    let acceptsLiveAudio = false

    init(
        configuration: OpenRouterDictationConfiguration,
        client: OpenRouterTranscriptionClient = OpenRouterTranscriptionClient()
    ) {
        self.configuration = configuration
        self.client = client
    }

    func append(_: [Float]) {}

    func finish(recordedWAVURL: URL) async throws -> HostedDictationResult {
        let task = Task { try await client.transcribe(wavURL: recordedWAVURL, configuration: configuration) }
        lock.withLock {
            self.task = task
            if cancelled { task.cancel() }
        }
        defer { lock.withLock { self.task = nil } }
        let result = try await task.value
        return HostedDictationResult(text: result.text, backend: "openrouter-stt",
            model: OpenRouterTranscriptionClient.normalizedModel(configuration.model),
            endpoint: OpenRouterTranscriptionClient.endpoint.absoluteString)
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            task?.cancel()
        }
    }
}

enum HostedDictationFallbackPolicy {
    static func shouldFallback(
        after error: Error,
        taskIsCancelled: Bool = false,
        isCurrentSession: Bool = true
    ) -> Bool {
        guard !taskIsCancelled, isCurrentSession else { return false }
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }
        return true
    }
}

/// What a hosted dictation job transcribes with once its provider has finished.
/// Kept apart from the controller so the hosted-versus-local choice is testable
/// without a recorder, a provider connection, or a loaded model.
struct HostedDictationDecision: Equatable {
    enum Source: Equatable {
        /// The provider's finished prose.
        case hosted(HostedDictationResult)
        /// The provider failed, so this local model transcribes the saved capture.
        case localFallback(BackendOption)
    }

    let source: Source
    /// The identity recorded with the dictation, so history names what actually
    /// produced the text rather than the provider the user selected.
    let transcriptionModel: DictationModelIdentity

    /// Hosted transcription models already produce finished prose, so a hosted
    /// success skips local cleanup, as the provider choice intends.
    var skipsCleanup: Bool {
        if case .hosted = source { return true }
        return false
    }

    /// Cancellation, a superseded session, and a failure with no local model able
    /// to serve dictation rethrow the provider's error, so a dropped dictation
    /// never silently becomes another. `availableFallbacks` is read only after a
    /// failure, keeping the downloaded-model scan off the hosted success path.
    static func resolve(
        hostedOutcome: Result<HostedDictationResult, Error>,
        selected: BackendOption,
        taskIsCancelled: Bool,
        isCurrentSession: Bool,
        availableFallbacks: () -> [BackendOption]
    ) throws -> HostedDictationDecision {
        switch hostedOutcome {
        case .success(let hosted):
            return HostedDictationDecision(
                source: .hosted(hosted),
                transcriptionModel: DictationModelIdentity(
                    backend: hosted.backend,
                    model: hosted.model ?? "",
                    name: hosted.model ?? "Not recorded",
                    endpoint: hosted.endpoint
                )
            )
        case .failure(let error):
            guard HostedDictationFallbackPolicy.shouldFallback(
                after: error,
                taskIsCancelled: taskIsCancelled,
                isCurrentSession: isCurrentSession
            ),
                  let fallback = BackendOption.resolveHostedDictationFallback(
                    selected: selected,
                    available: availableFallbacks()
                  ) else { throw error }
            return HostedDictationDecision(
                source: .localFallback(fallback),
                transcriptionModel: DictationModelIdentity(
                    backend: fallback.backend,
                    model: fallback.model,
                    name: fallback.label
                )
            )
        }
    }
}

enum HostedDictationActivationPolicy {
    static func blockingMessage(
        provider: DictationProvider,
        openAIAPIKey: String,
        openRouterAPIKey: String,
        openRouterModel: String
    ) -> String? {
        switch provider {
        case .local:
            return nil
        case .openAI:
            return openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "OpenAI API key not configured. Add one in Settings → Dictation."
                : nil
        case .openRouter:
            if openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "OpenRouter is not connected. Connect it in Settings → Dictation."
            }
            return OpenRouterTranscriptionClient.normalizedModel(openRouterModel).isEmpty
                ? "Choose an OpenRouter transcription model in Settings → Dictation."
                : nil
        }
    }
}
