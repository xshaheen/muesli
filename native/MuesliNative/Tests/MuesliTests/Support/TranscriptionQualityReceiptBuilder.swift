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
///
/// Two mappings here are load-bearing and neither is obvious from the field names. A stage is
/// carried only when it is a *measurement of that stage* — the final stage is dropped for any
/// utterance the cleanup stage skipped, because the pipeline still returns a text there and scoring
/// it would report "cleanup changed nothing" about a cleanup that never ran. And a not-runnable
/// reason is carried as a code, with its failed sample ids in the field that already holds ids,
/// rather than as the sweep's rendered sentence.
extension TranscriptionQualityRun.Result {
    func receipt(
        runID: String = UUID().uuidString,
        generatedAt: Date = Date(),
        host: TranscriptionQualityReceipt.Host = .current(),
        store: TranscriptionCorpusStore,
        thresholds: TranscriptionQualityReceipt.Thresholds = TranscriptionQualityReceipt.Thresholds(),
        notes: [String] = [],
        dependencies: TranscriptionQualityReceipt.Dependencies? = .resolvedFromPackage()
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
                // What the run asked for, stated as such — and beside it what actually happened,
                // counted off the measurements rather than off the flag. A run configured with
                // cleanup on, whose cleanup model was never loadable, reports zero applied here
                // instead of presenting an untouched final stage as a cleanup result.
                cleanupRequested: cleanupEnabled,
                cleanupAppliedUtterances: cleanupAppliedUtterances,
                cleanupNotPerformed: cleanupNotPerformed,
                notes: notes
            ),
            backends: backends.map(\.receiptBackend),
            dependencies: dependencies
        )
    }

    /// Utterances across every measured backend whose final stage is genuinely the cleanup stage's
    /// product.
    private var cleanupAppliedUtterances: Int {
        measurements.reduce(0) { $0 + $1.cleanupAppliedCount }
    }

    /// Why cleanup did not run, pooled across backends, in a stable order.
    private var cleanupNotPerformed: [TranscriptionQualityReceipt.CleanupSkip] {
        var counts: [String: Int] = [:]
        for measurement in measurements {
            for (reason, count) in measurement.cleanupNotPerformedCounts {
                counts[reason, default: 0] += count
            }
        }
        return counts
            .sorted { $0.key < $1.key }
            .map { TranscriptionQualityReceipt.CleanupSkip(reason: $0.key, utterances: $0.value) }
    }

    private var measurements: [TranscriptionQualityRun.Measurement] {
        backends.compactMap {
            guard case let .measured(measurement) = $0.outcome else { return nil }
            return measurement
        }
    }
}

private extension TranscriptionQualityRun.BackendRun {
    var receiptBackend: TranscriptionQualityReceipt.Backend {
        switch outcome {
        case let .notRunnable(reason):
            // R12: a reason, never a row of zeros. Zeros would rank an unrunnable backend first.
            // The reason is a code and its failures travel in `failures`, so no rendered sentence —
            // and nothing a future case might interpolate into one — reaches the receipt. The
            // per-sample messages that do are bounded by `ReceiptProse` on the way in.
            return TranscriptionQualityReceipt.Backend(
                backend: backend,
                model: model,
                label: label,
                languageConfiguration: languageConfiguration,
                notRunnable: reason.receiptReason,
                failures: reason.failures.map(\.receiptFailure)
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
                // Named and explained, not counted: three bad files, three fewer samples and a model
                // that never loaded are three different facts, and only the message separates them.
                failures: measurement.failures.map(\.receiptFailure)
            )
        }
    }
}

private extension TranscriptionQualityRun.NotRunnable {
    var receiptReason: TranscriptionQualityReceipt.NotRunnable {
        switch self {
        case let .requiresNewerMacOS(required, host):
            return TranscriptionQualityReceipt.NotRunnable(
                code: .requiresNewerMacOS,
                requiredMacOSMajorVersion: required,
                hostOperatingSystemVersion: host
            )
        case .modelNotDownloaded:
            return TranscriptionQualityReceipt.NotRunnable(code: .modelNotDownloaded)
        case .noSamples:
            return TranscriptionQualityReceipt.NotRunnable(code: .noSamples)
        case .noMeasuredSamples:
            return TranscriptionQualityReceipt.NotRunnable(code: .noMeasuredSamples)
        }
    }

    /// The failures the `noMeasuredSamples` reason used to spell out in prose.
    var failures: [TranscriptionQualityRun.SampleFailure] {
        guard case let .noMeasuredSamples(failures) = self else { return [] }
        return failures
    }
}

private extension TranscriptionQualityRun.SampleFailure {
    /// The message is bounded rather than trusted: a thrown error can quote the audio path, the
    /// hypothesis it failed on, or anything else the backend chose to interpolate.
    var receiptFailure: TranscriptionQualityReceipt.SampleFailure {
        TranscriptionQualityReceipt.SampleFailure(sampleID: sampleID, reason: message)
    }
}

private extension TranscriptionQualityRun.SampleMeasurement {
    var receiptUtterance: TranscriptionQualityReceipt.Utterance {
        TranscriptionQualityReceipt.Utterance(
            sampleID: sampleID,
            corpusID: corpusID,
            rawASR: TranscriptionQualityReceipt.StageSummary(rawASR),
            // `measuredFinalOutput`, never `pipelineFinalOutput`: when cleanup did not run, the
            // pipeline's final text is not that stage's result and the receipt has to say so with an
            // absent stage rather than with a figure that reads as an unchanged one.
            finalOutput: measuredFinalOutput.map(TranscriptionQualityReceipt.StageSummary.init),
            endToEndSeconds: latency.endToEndSeconds,
            speechRecognitionSeconds: latency.speechRecognitionSeconds,
            audioDurationSeconds: latency.audioDurationSeconds
        )
    }
}

extension TranscriptionQualityReceipt.Dependencies {
    /// Reads the pins out of `Package.resolved` rather than taking a hand-typed string.
    ///
    /// A version a maintainer types into a run is a claim about the build; one read from the
    /// resolution file is the build. This is what lets a later comparison say "these numbers
    /// came from 0.15.1 and those from 0.15.6" without anyone having to remember.
    ///
    /// Returns nil rather than guessing when the file cannot be found or parsed: an absent
    /// version is honest, and an invented one would silently mislabel a run.
    static func resolvedFromPackage(
        packageResolved: URL? = TranscriptionCorpusStorePaths.packageResolvedURL()
    ) -> TranscriptionQualityReceipt.Dependencies? {
        guard let packageResolved,
              let data = try? Data(contentsOf: packageResolved),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = root["pins"] as? [[String: Any]]
        else { return nil }

        func version(ofIdentity identity: String) -> String? {
            for pin in pins {
                guard let pinIdentity = pin["identity"] as? String,
                      pinIdentity.caseInsensitiveCompare(identity) == .orderedSame,
                      let state = pin["state"] as? [String: Any]
                else { continue }
                return state["version"] as? String
            }
            return nil
        }

        let fluid = version(ofIdentity: "fluidaudio")
        let whisper = version(ofIdentity: "whisperkit")
        guard fluid != nil || whisper != nil else { return nil }
        return TranscriptionQualityReceipt.Dependencies(fluidAudio: fluid, whisperKit: whisper)
    }
}

enum TranscriptionCorpusStorePaths {
    /// Walks up from this source file to the package root. The harness only ever runs from a
    /// checkout, so the resolution file is beside `Package.swift`; nil when it is not there.
    static func packageResolvedURL(file: StaticString = #filePath) -> URL? {
        var directory = URL(fileURLWithPath: String(describing: file)).deletingLastPathComponent()
        for _ in 0 ..< 6 {
            let candidate = directory.appendingPathComponent("Package.resolved")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}
