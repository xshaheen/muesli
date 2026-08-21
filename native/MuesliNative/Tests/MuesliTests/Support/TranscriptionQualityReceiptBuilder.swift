import Foundation
import MuesliCore

// Suite-free by design, like the rest of `Support/`: `scripts/test_ci_test_shards.sh` discovers
// `@Suite` declarations one level deep in `Tests/MuesliTests/`, so a suite parked here would evade
// shard registration instead of failing the guard.

/// Turns a completed sweep into the committed v2 receipt.
///
/// This lives in the test target because `TranscriptionQualityRun` does — the sweep's types depend
/// on `BackendOption` and the app pipeline, and `MuesliCore` stays Foundation-only. What crosses the
/// boundary is only what R2 permits: scores, identities, and provenance.
extension TranscriptionQualityRun.Result {
    func receipt(
        runID: String = UUID().uuidString,
        generatedAt: Date = Date(),
        host: TranscriptionQualityReceipt.Host = .current(),
        store: TranscriptionCorpusStore,
        thresholds: TranscriptionQualityReceipt.Thresholds = TranscriptionQualityReceipt.Thresholds(),
        notes: [String] = []
    ) -> TranscriptionQualityReceipt {
        TranscriptionQualityReceipt(
            runID: runID,
            generatedAt: ISO8601DateFormatter().string(from: generatedAt),
            host: host,
            corpora: store.corpora.map { corpus in
                TranscriptionQualityReceipt.Corpus(
                    id: corpus.id,
                    revision: corpus.descriptor.revision,
                    // The store refuses a corpus with no licence, so an accepted one always has an
                    // identifier; the fallback exists only so the mapping is total.
                    licenceIdentifier: corpus.descriptor.licence?.identifier ?? "unrecorded",
                    acquisition: corpus.descriptor.acquisition.rawValue,
                    cohorts: TranscriptionQuality.Cohort.allCases.filter { corpus.cohorts.contains($0) },
                    sampleCount: corpus.samples.count,
                    issueCount: corpus.issues.count
                )
            },
            thresholds: thresholds,
            disclosures: TranscriptionQualityReceipt.Disclosures(
                cleanupEnabled: cleanupEnabled,
                notes: notes
            ),
            backends: backends.map(\.receiptBackend)
        )
    }
}

private extension TranscriptionQualityRun.BackendRun {
    var receiptBackend: TranscriptionQualityReceipt.Backend {
        switch outcome {
        case let .notRunnable(reason):
            // R12: a reason, never a row of zeros. Zeros would rank an unrunnable backend first.
            return TranscriptionQualityReceipt.Backend(
                backend: backend,
                model: model,
                label: label,
                languageConfiguration: languageConfiguration,
                notRunnableReason: reason.description
            )
        case let .measured(measurement):
            return TranscriptionQualityReceipt.Backend(
                backend: backend,
                model: model,
                label: label,
                languageConfiguration: languageConfiguration,
                warmup: measurement.warmup.map {
                    TranscriptionQualityReceipt.Warmup(
                        sampleID: $0.sampleID,
                        endToEndSeconds: $0.endToEndSeconds,
                        failureMessage: $0.failureMessage
                    )
                },
                cohorts: measurement.cohorts.map { cohort in
                    TranscriptionQualityReceipt.CohortResult(
                        cohort: cohort,
                        utterances: measurement.samples(in: cohort).map(\.receiptUtterance)
                    )
                },
                // Named, not counted: three bad files and three fewer samples are different facts.
                failedSampleIDs: measurement.failures.map(\.sampleID)
            )
        }
    }
}

private extension TranscriptionQualityRun.SampleMeasurement {
    var receiptUtterance: TranscriptionQualityReceipt.Utterance {
        TranscriptionQualityReceipt.Utterance(
            sampleID: sampleID,
            corpusID: corpusID,
            rawASR: TranscriptionQualityReceipt.StageSummary(rawASR),
            finalOutput: TranscriptionQualityReceipt.StageSummary(finalOutput),
            endToEndSeconds: latency.endToEndSeconds,
            speechRecognitionSeconds: latency.speechRecognitionSeconds,
            audioDurationSeconds: latency.audioDurationSeconds
        )
    }
}
