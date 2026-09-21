import Foundation
import ImlaCore

/// The disclosure the Meetings pane shows when mixed-language repair will run.
///
/// Repair has no switch of its own: selecting two or more meeting languages on a
/// configured cleanup backend turns it on, and it then sends every finished meeting's
/// full transcript to that backend. That is a network path the user never toggled
/// explicitly, so the pane must say where the transcript goes — and must say nothing
/// when repair would be skipped, because a "sent to" line for a path that is not
/// taken is as misleading as silence for one that is.
///
/// Pure, so the wording is testable without a view, and so the line can never be
/// shown for a configuration that would skip cleanup.
enum MeetingCleanupStatus {
    static func activeDisclosure(config: AppConfig, isChatGPTAuthenticated: Bool) -> String? {
        let backend = MeetingCleanupTransport.backend(for: config)
        guard MeetingTranscriptCleanup.isEnabled(
            config: config,
            backend: backend,
            isChatGPTAuthenticated: isChatGPTAuthenticated
        ) else { return nil }
        return "Mixed-language transcripts are repaired after each meeting. "
            + MeetingTranscriptCleanupPolicy.disclosure(for: backend, config: config)
    }
}
