import CryptoKit
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

    private static let consentFingerprintVersion = "v1"

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

    /// A non-reversible identity for the backend and exact resolved request URL.
    ///
    /// Hashing avoids persisting credentials if a custom URL embeds them. The
    /// backend remains part of the identity even when two providers share a host,
    /// because selecting a provider is itself part of the user's consent.
    static func consentFingerprint(
        for backend: TranscriptCleanupBackendOption,
        config: AppConfig
    ) -> String? {
        guard isEligible(backend),
              let destination = TranscriptCleanupClient.resolvedMeetingCleanupDestinationURL(
                for: backend,
                config: config
              ),
              let normalizedDestination = normalizedDestination(destination) else {
            return nil
        }
        let material = "\(consentFingerprintVersion)|\(backend.backend)|\(normalizedDestination)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    @discardableResult
    static func grantConsent(
        for backend: TranscriptCleanupBackendOption,
        config: inout AppConfig
    ) -> Bool {
        guard let fingerprint = consentFingerprint(for: backend, config: config) else {
            revokeConsent(in: &config)
            return false
        }
        config.enableMeetingTranscriptCleanup = true
        config.meetingTranscriptCleanupConsentFingerprint = fingerprint
        return true
    }

    static func revokeConsent(in config: inout AppConfig) {
        config.enableMeetingTranscriptCleanup = false
        config.meetingTranscriptCleanupConsentFingerprint = nil
    }

    static func hasCurrentConsent(
        for backend: TranscriptCleanupBackendOption,
        config: AppConfig
    ) -> Bool {
        guard config.enableMeetingTranscriptCleanup,
              let stored = config.meetingTranscriptCleanupConsentFingerprint,
              !stored.isEmpty,
              let current = consentFingerprint(for: backend, config: config) else {
            return false
        }
        return stored == current
    }

    /// Keeps the persisted toggle honest after any config mutation or decode.
    static func reconcileConsent(in config: inout AppConfig) {
        let backend = TranscriptCleanupBackendOption.resolved(config.postProcessorBackend)
        guard hasCurrentConsent(for: backend, config: config) else {
            revokeConsent(in: &config)
            return
        }
    }

    private static func normalizedDestination(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if (scheme == "http" && components.port == 80)
            || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        if let queryItems = components.queryItems {
            components.queryItems = queryItems.sorted {
                if $0.name == $1.name {
                    return ($0.value ?? "") < ($1.value ?? "")
                }
                return $0.name < $1.name
            }
        }
        return components.string
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
