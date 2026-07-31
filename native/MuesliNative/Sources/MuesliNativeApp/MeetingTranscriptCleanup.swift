import Foundation
import MuesliCore
import os

/// Runs AI cleanup over a finalized meeting transcript.
///
/// All-or-nothing by construction: every chunk must come back complete, or the
/// whole result is discarded and the meeting keeps its raw transcript. A half-
/// repaired transcript is worse than an unrepaired one, because it reads as
/// correct and would then hide the complete raw text from every surface.
enum MeetingTranscriptCleanup {

    private static let logger = Logger(subsystem: "com.muesli.native", category: "meeting-cleanup")

    /// Characters per chunk.
    ///
    /// Sized well under the token cap below, because Arabic tokenizes far worse
    /// than English -- an English-calibrated estimate under-counts, and the cost of
    /// under-counting is a truncated response.
    static let chunkBudget = 2_400

    /// Output cap per chunk. Generous relative to `chunkBudget` so a legitimately
    /// expanding repair has room; truncation should mean something went wrong, not
    /// that the budget was tight.
    static let maxOutputTokensPerChunk = 4_000

    /// Cleans `transcript`, or returns nil if it cannot be shown to be complete.
    ///
    /// - Parameter send: injected so tests can drive every failure mode without a
    ///   network. Production passes `liveSender(backend:config:)`.
    static func clean(
        transcript: String,
        send: (String) async throws -> TranscriptCleanupResult
    ) async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let units = MeetingTranscriptChunker.units(in: transcript, budget: chunkBudget)
        guard !units.isEmpty else { return nil }
        let chunks = MeetingTranscriptChunker.chunks(of: units, budget: chunkBudget)

        var cleanedUnits: [MeetingTranscriptUnit] = []
        for (position, chunk) in chunks.enumerated() {
            let payload = MeetingTranscriptCleanupValidator.requestPayload(for: chunk)
            let result: TranscriptCleanupResult
            do {
                result = try await send(payload)
            } catch {
                // Never propagates. The meeting is already complete and durable;
                // cleanup is an improvement that either lands or does not.
                logger.error("chunk \(position + 1)/\(chunks.count) failed: \(error.localizedDescription)")
                return nil
            }
            switch MeetingTranscriptCleanupValidator.validate(
                chunk: chunk,
                response: result.cleanedOutput,
                wasTruncated: result.wasTruncated
            ) {
            case .success(let validated):
                cleanedUnits.append(contentsOf: validated)
            case .failure(let rejection):
                // Discarding everything, including chunks that came back fine. A
                // transcript repaired up to the failure point and raw after it is
                // the invisible failure this whole unit exists to prevent.
                logger.error("chunk \(position + 1)/\(chunks.count) rejected: \(rejection.reason)")
                return nil
            }
        }

        let cleaned = MeetingTranscriptChunker.reassemble(cleanedUnits)
        let cleanedTrimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTrimmed.isEmpty, cleaned != transcript else { return nil }
        return cleaned
    }

    /// The production sender. Kept separate from `clean` so the orchestration above
    /// is testable without a backend.
    static func liveSender(
        backend: TranscriptCleanupBackendOption,
        config: AppConfig
    ) -> (String) async throws -> TranscriptCleanupResult {
        { payload in
            try await TranscriptCleanupClient.clean(
                text: payload,
                systemPrompt: MeetingTranscriptCleanupPrompt.systemPrompt,
                // No app context: focused app, URL, and OCR text are dictation
                // concepts with no meaning during a meeting.
                appContext: nil,
                backend: backend,
                config: config,
                options: TranscriptCleanupRequestOptions(
                    maxOutputTokens: maxOutputTokensPerChunk,
                    disableProviderRetention: true,
                    preserveLineStructure: true
                )
            )
        }
    }

    /// Whether cleanup should run at all for the current configuration.
    static func isEnabled(
        config: AppConfig,
        backend: TranscriptCleanupBackendOption,
        isChatGPTAuthenticated: Bool
    ) -> Bool {
        guard config.enableMeetingTranscriptCleanup else { return false }
        guard MeetingTranscriptCleanupPolicy.isEligible(backend) else { return false }
        return TranscriptCleanupClient.hasRequiredSettings(
            for: backend,
            config: config,
            isChatGPTAuthenticated: isChatGPTAuthenticated
        )
    }
}
