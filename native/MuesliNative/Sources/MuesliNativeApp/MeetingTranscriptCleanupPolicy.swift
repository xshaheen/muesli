import Foundation

/// Where a cleanup backend actually processes the transcript.
///
/// This is not a property of the backend's name. Ollama, LM Studio, and a custom
/// endpoint each carry a user-configurable URL, so the same backend is on-device
/// when it points at loopback and off-device when it points at a LAN box or a
/// hosted service.
enum MeetingCleanupLocality: Equatable {
    /// Loopback -- the transcript never leaves this machine.
    case onThisMachine
    /// Anything else, including a LAN address. Named for the disclosure text.
    case offThisMachine(destination: String)
}

/// Whether meeting cleanup can run at all, and what the user must be told.
enum MeetingTranscriptCleanupPolicy {

    /// Backends that cannot serve meeting cleanup.
    ///
    /// Both are on-device post-processors with no `llmBackend`, so
    /// `TranscriptCleanupClient.clean` throws `missingConfiguration` for them.
    /// `Qwen3PostProcessor.maxContextTokens` is 1024 for the *entire* context --
    /// prompt, transcript, and output together -- which no useful chunking of a
    /// meeting transcript fits inside, and its API is shaped for dictation.
    static func isEligible(_ backend: TranscriptCleanupBackendOption) -> Bool {
        backend.llmBackend != nil
    }

    static func ineligibilityReason(_ backend: TranscriptCleanupBackendOption) -> String? {
        guard !isEligible(backend) else { return nil }
        return "\(backend.label) runs on-device with a context too small for a whole "
            + "meeting. Choose another cleanup backend to enable this."
    }

    /// Where the configured backend will send the transcript.
    ///
    /// Returns nil when the backend is ineligible or its endpoint is unresolvable,
    /// so callers state nothing rather than guessing about private conversations.
    static func locality(
        for backend: TranscriptCleanupBackendOption,
        config: AppConfig
    ) -> MeetingCleanupLocality? {
        guard let llmBackend = backend.llmBackend else { return nil }
        switch llmBackend {
        case .chatGPT, .openAI:
            return .offThisMachine(destination: "OpenAI")
        case .openRouter:
            return .offThisMachine(destination: "OpenRouter")
        case .ollama:
            return locality(ofURLString: config.ollamaURL, default: "http://localhost:11434")
        case .lmStudio:
            return locality(ofURLString: config.lmStudioURL, default: "http://localhost:1234")
        case .customLLM:
            return locality(ofURLString: config.customLLMURL, default: nil)
        default:
            return nil
        }
    }

    /// The sentence shown under the toggle.
    ///
    /// Meeting cleanup sends the entire transcript of a private conversation
    /// involving people who never agreed to anything -- a materially different
    /// disclosure from dictation's, where the unit of data is one sentence the user
    /// just spoke. It has to be accurate per endpoint: claiming a cloud upload that
    /// does not happen would push people away from the most private option they
    /// have, and omitting one that does happen is worse.
    static func disclosure(
        for backend: TranscriptCleanupBackendOption,
        config: AppConfig
    ) -> String {
        switch locality(for: backend, config: config) {
        case .onThisMachine:
            return "Full meeting transcripts are sent to \(backend.label) on this machine. "
                + "Nothing leaves your Mac."
        case .offThisMachine(let destination):
            return "Full meeting transcripts are sent to \(destination) for processing."
        case nil:
            return "Configure a cleanup backend to see where transcripts would be sent."
        }
    }

    private static func locality(
        ofURLString raw: String,
        default fallback: String?
    ) -> MeetingCleanupLocality? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? fallback : trimmed
        guard
            let candidate,
            let host = URLComponents(string: candidate)?.host?.lowercased()
        else { return nil }
        // Loopback only. A LAN address such as 192.168.1.5 is another machine, and
        // telling someone their meeting stayed on their Mac when it crossed the
        // network would be exactly the wrong reassurance.
        let loopback: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"]
        return loopback.contains(host)
            ? .onThisMachine
            : .offThisMachine(destination: host)
    }
}
