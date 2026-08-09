import Foundation

/// Decides which loaded ASR backends the transcription coordinator may release.
///
/// The coordinator caches every backend it has ever loaded, so trying three
/// models in one session leaves all three resident for the life of the process —
/// several gigabytes for backends the user has already moved on from. Only the
/// backends standing behind a currently designated slot earn that memory; the
/// rest lazy-load again the next time they are selected.
enum TranscriptionBackendResidencyPolicy {
    /// The backend identifiers a running app still needs.
    ///
    /// A nil slot means "nothing designated here" (meetings disabled, live
    /// captions off, hosted cleanup), not "keep whatever is loaded".
    struct Designation: Equatable {
        var dictation: String?
        var meetingTranscription: String?
        var meetingLiveCaption: String?
        /// Set only for on-device cleanup engines that are also ASR backends, so
        /// a Gemma cleanup selection is not unloaded by an ASR-side reconcile.
        var postProcessor: String?

        var backendIdentifiers: Set<String> {
            Set(
                [dictation, meetingTranscription, meetingLiveCaption, postProcessor]
                    .compactMap { $0 }
            )
        }
    }

    /// Loaded backends that are no longer designated and are not mid-transcription.
    ///
    /// `inFlight` is what keeps a reconcile from pulling models out from under a
    /// dictation or meeting chunk that is already running against them: the
    /// coordinator is an actor, so a reconcile can interleave with any awaited
    /// transcription. Sorted so unload order, and its logging, is deterministic.
    static func backendsToUnload(
        loaded: Set<String>,
        designation: Designation,
        inFlight: Set<String> = []
    ) -> [String] {
        loaded
            .subtracting(designation.backendIdentifiers)
            .subtracting(inFlight)
            .sorted()
    }
}
