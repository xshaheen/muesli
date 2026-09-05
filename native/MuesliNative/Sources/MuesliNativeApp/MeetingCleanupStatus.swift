import Foundation
import MuesliCore

/// The Meetings pane's read-only account of mixed-language repair (R11).
///
/// Pure, so the wording is testable without a view, and so "on" can never be
/// shown for a configuration that would skip cleanup.
enum MeetingCleanupStatus {

    struct Description: Equatable {
        let state: String
        let detail: String
    }

    static func describe(config: AppConfig, isChatGPTAuthenticated: Bool) -> Description {
        let backend = MeetingCleanupTransport.backend(for: config)

        guard config.meetingSpokenLanguage.isBilingual else {
            return Description(
                state: "Off",
                detail: "Select two or more meeting languages to repair mixed-language transcripts."
            )
        }
        if let reason = MeetingTranscriptCleanupPolicy.ineligibilityReason(backend) {
            return Description(state: "Off", detail: reason)
        }
        guard MeetingCleanupTransport.isConfigured(
            config: config,
            isChatGPTAuthenticated: isChatGPTAuthenticated
        ) else {
            return Description(
                state: "Off",
                detail: "Configure the meeting notes backend to repair mixed-language transcripts."
            )
        }
        return Description(
            state: "On",
            detail: MeetingTranscriptCleanupPolicy.disclosure(for: backend, config: config)
        )
    }
}
