import Foundation
import MuesliCore

/// Where a meeting transcript-cleanup request is sent, and on what model.
///
/// Cleanup rides the meeting summary backend rather than the dictation
/// post-processor backend (KTD3). That endpoint already receives the full
/// transcript to write the notes, so repairing the same transcript there adds no
/// destination the user has not already configured for meeting content.
enum MeetingCleanupTransport {

    /// The cleanup backend for the configured summary backend.
    ///
    /// Resolves through `MeetingSummaryBackendOption` first. Handing the raw
    /// stored string to the cleanup resolver would turn an empty value into the
    /// on-device option, which is ineligible, so cleanup would silently never run
    /// for a user on the default backend while readiness still reported configured.
    static func backend(for config: AppConfig) -> TranscriptCleanupBackendOption {
        let summary = MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend)
        return TranscriptCleanupBackendOption.resolved(summary.backend)
    }

    /// The summary-side model, so cleanup and notes travel on the same one.
    static func model(for config: AppConfig) -> String {
        MeetingSummaryClient.resolvedSummaryModel(config: config)
    }

    /// Whether the summary backend has everything it needs to accept a request.
    ///
    /// Reuses the summary client's own check rather than restating per-backend
    /// credential rules that would then drift from it.
    static func isConfigured(config: AppConfig, isChatGPTAuthenticated: Bool) -> Bool {
        MeetingSummaryClient.isBackendConfigured(
            config: config,
            isChatGPTAuthenticated: isChatGPTAuthenticated
        )
    }
}
