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
    /// - Parameter isAuthorized: Rechecked immediately before every chunk leaves
    ///   the process. Meeting cleanup consent is mutable while a long transcript
    ///   is being processed, so authorization at scheduling time is insufficient.
    /// - Parameter send: injected so tests can drive every failure mode without a
    ///   network. Production passes `liveSender(backend:config:)`.
    static func clean(
        transcript: String,
        isAuthorized: () async -> Bool = { true },
        send: (String) async throws -> TranscriptCleanupResult
    ) async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let units = MeetingTranscriptChunker.units(in: transcript, budget: chunkBudget)
        guard !units.isEmpty else { return nil }
        let chunks = MeetingTranscriptChunker.chunks(of: units, budget: chunkBudget)

        var cleanedUnits: [MeetingTranscriptUnit] = []
        for (position, chunk) in chunks.enumerated() {
            guard !Task.isCancelled, await isAuthorized() else {
                fputs("[meeting-cleanup] cancelled before chunk \(position + 1)/\(chunks.count)\n", stderr)
                return nil
            }
            let payload = MeetingTranscriptCleanupValidator.requestPayload(for: chunk)
            let result: TranscriptCleanupResult
            do {
                result = try await send(payload)
            } catch {
                guard !Task.isCancelled else { return nil }
                // Never propagates. The meeting is already complete and durable;
                // cleanup is an improvement that either lands or does not.
                logger.error("chunk \(position + 1)/\(chunks.count) failed: \(error.localizedDescription)")
                // Type and status only: a backend's error body can echo request
                // content, and stderr has none of the unified log's privacy handling.
                let safeDescription: String
                if case let .backendFailed(statusCode, _)? = error as? ChatGPTResponsesError {
                    safeDescription = "ChatGPT HTTP \(statusCode)"
                } else {
                    safeDescription = String(describing: type(of: error))
                }
                fputs("[meeting-cleanup] chunk \(position + 1)/\(chunks.count) failed: \(safeDescription)\n", stderr)
                return nil
            }
            guard !Task.isCancelled, await isAuthorized() else {
                fputs("[meeting-cleanup] cancelled after chunk \(position + 1)/\(chunks.count)\n", stderr)
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
                fputs("[meeting-cleanup] chunk \(position + 1)/\(chunks.count) rejected: \(rejection.reason)\n", stderr)
                return nil
            }
        }

        let cleaned = MeetingTranscriptChunker.reassemble(cleanedUnits)
        let cleanedTrimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTrimmed.isEmpty, cleaned != transcript else {
            fputs("[meeting-cleanup] discarded: output empty or identical to the raw transcript\n", stderr)
            return nil
        }
        fputs("[meeting-cleanup] completed: \(chunks.count) chunk(s)\n", stderr)
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
                systemPrompt: MeetingInstructionsComposer.cleanupSystemPrompt(for: config),
                // No app context: focused app, URL, and OCR text are dictation
                // concepts with no meaning during a meeting.
                appContext: nil,
                backend: backend,
                config: config,
                model: MeetingCleanupTransport.model(for: config),
                options: TranscriptCleanupRequestOptions(
                    maxOutputTokens: maxOutputTokensPerChunk,
                    disableProviderRetention: true,
                    preserveLineStructure: true
                )
            )
        }
    }

    /// Whether cleanup should run at all, decided by the meeting language
    /// selection (KTD1, R10).
    ///
    /// No separate toggle: repair runs when the user told Muesli the meeting is
    /// bilingual and the summary backend it already uses can accept the request.
    static func isEnabled(
        config: AppConfig,
        backend: TranscriptCleanupBackendOption,
        isChatGPTAuthenticated: Bool
    ) -> Bool {
        guard config.meetingSpokenLanguage.isBilingual else { return false }
        guard MeetingTranscriptCleanupPolicy.isEligible(backend) else { return false }
        return MeetingCleanupTransport.isConfigured(
            config: config,
            isChatGPTAuthenticated: isChatGPTAuthenticated
        )
    }
}
