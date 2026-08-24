import Foundation
import MuesliCore
import Testing

/// R10's cross-run comparison: the test that decides whether a dependency upgrade moved
/// transcription quality.
///
/// The property worth protecting here is that the comparison answers a *different* question from
/// the ranking's interval and cannot be quietly substituted for it. So these cover the two ways it
/// can be wrong in the direction that matters: reporting movement that is not there, and pairing
/// samples that are not the same sample.
@Suite("Transcription quality upgrade comparison")
struct TranscriptionQualityUpgradeComparisonTests {

    // MARK: Builders

    private func utterance(
        corpus: String,
        sample: String,
        errors: Int,
        words: Int
    ) -> TranscriptionQualityReceipt.Utterance {
        let rates = TranscriptionQuality.ErrorRates(
            wordErrors: errors,
            referenceWords: words,
            characterErrors: errors,
            referenceCharacters: words * 5
        )
        return TranscriptionQualityReceipt.Utterance(
            sampleID: sample,
            corpusID: corpus,
            rawASR: TranscriptionQualityReceipt.StageSummary(
                raw: rates,
                normalized: rates,
                faithfulness: 1,
                scriptChangeInflatesErrorRate: false
            ),
            finalOutput: nil,
            endToEndSeconds: 1,
            speechRecognitionSeconds: 1,
            audioDurationSeconds: 4
        )
    }

    private func receipt(
        corpora: [(id: String, revision: String, samples: Int)],
        backends: [(backend: String, model: String, label: String, utterances: [TranscriptionQualityReceipt.Utterance])],
        fluidAudio: String?
    ) -> TranscriptionQualityReceipt {
        TranscriptionQualityReceipt(
            runID: UUID().uuidString,
            generatedAt: "2026-08-25T00:00:00Z",
            host: .current(),
            corpora: corpora.map {
                TranscriptionQualityReceipt.Corpus(
                    id: $0.id,
                    revision: $0.revision,
                    licenceIdentifier: "cc-by-4.0",
                    acquisition: "scripted",
                    cohorts: [.english],
                    sampleCount: $0.samples,
                    issueCount: 0
                )
            },
            disclosures: TranscriptionQualityReceipt.Disclosures(
                cleanupRequested: false,
                cleanupAppliedUtterances: 0,
                cleanupNotPerformed: [],
                warmupSampleConsumed: false,
                cleanupModelResidentAcrossSweep: false,
                notes: []
            ),
            backends: backends.map { entry in
                TranscriptionQualityReceipt.Backend(
                    backend: entry.backend,
                    model: entry.model,
                    label: entry.label,
                    languageConfiguration: "automatic",
                    notRunnable: nil,
                    warmup: nil,
                    cohorts: [
                        TranscriptionQualityReceipt.CohortResult(
                            cohort: .english,
                            utterances: entry.utterances
                        ),
                    ],
                    failures: []
                )
            },
            dependencies: fluidAudio.map { TranscriptionQualityReceipt.Dependencies(fluidAudio: $0) }
        )
    }

    private let corpus = [(id: "fleurs-en-us", revision: "abc123", samples: 3)]

    // MARK: Tests

    /// The upgrade's own gate. Identical scores on both sides must read as unmoved, with an
    /// interval that contains zero — not as an absent result, and not as movement.
    @Test("a backend that scored identically on both runs is reported as unmoved")
    func identicalScoresAreUnmoved() throws {
        let utterances = [
            utterance(corpus: "fleurs-en-us", sample: "0001", errors: 2, words: 20),
            utterance(corpus: "fleurs-en-us", sample: "0002", errors: 1, words: 15),
            utterance(corpus: "fleurs-en-us", sample: "0003", errors: 3, words: 25),
        ]
        let before = receipt(
            corpora: corpus,
            backends: [(backend: "fluidaudio", model: "p3", label: "Parakeet v3", utterances: utterances)],
            fluidAudio: "0.15.1"
        )
        let after = receipt(
            corpora: corpus,
            backends: [(backend: "fluidaudio", model: "p3", label: "Parakeet v3", utterances: utterances)],
            fluidAudio: "0.15.6"
        )

        let result = TranscriptionQualityUpgradeComparison.compare(before: before, after: after)
        #expect(result.voided == nil)
        let movement = try #require(result.movements.first)
        #expect(movement.margin == 0)
        #expect(movement.pairedUtterances == 3)
        #expect(!movement.moved, "identical scores must not read as a regression")
        #expect(movement.hasInterval)
        #expect(result.unmoved.count == 1)
        #expect(result.beforeDependencies?.fluidAudio == "0.15.1")
        #expect(result.afterDependencies?.fluidAudio == "0.15.6")
    }

    /// A large, consistent regression across every paired utterance must be detected — otherwise
    /// the gate would pass an upgrade that genuinely broke transcription.
    @Test("a backend that got consistently worse is reported as moved")
    func consistentRegressionIsDetected() throws {
        let clean = (1 ... 40).map {
            utterance(corpus: "fleurs-en-us", sample: String(format: "%04d", $0), errors: 1, words: 20)
        }
        let degraded = (1 ... 40).map {
            utterance(corpus: "fleurs-en-us", sample: String(format: "%04d", $0), errors: 10, words: 20)
        }
        let before = receipt(
            corpora: [(id: "fleurs-en-us", revision: "abc123", samples: 40)],
            backends: [(backend: "fluidaudio", model: "p3", label: "Parakeet v3", utterances: clean)],
            fluidAudio: "0.15.1"
        )
        let after = receipt(
            corpora: [(id: "fleurs-en-us", revision: "abc123", samples: 40)],
            backends: [(backend: "fluidaudio", model: "p3", label: "Parakeet v3", utterances: degraded)],
            fluidAudio: "0.15.6"
        )

        let result = TranscriptionQualityUpgradeComparison.compare(before: before, after: after)
        let movement = try #require(result.movements.first)
        #expect(movement.before == 0.05)
        #expect(movement.after == 0.5)
        #expect(movement.margin > 0, "positive margin must mean the upgrade made it worse")
        #expect(movement.moved, "a 10x error-rate increase must be detected as movement")
        #expect(result.moved.count == 1)
    }

    /// R10's precondition. Two runs over different corpora cannot be paired, and the comparison has
    /// to say so rather than pairing whatever happens to overlap — which would silently compare
    /// different utterances and report the difference as an upgrade effect.
    @Test("a changed corpus revision voids the comparison instead of pairing anyway")
    func changedCorpusRevisionVoidsTheComparison() {
        let utterances = [utterance(corpus: "fleurs-en-us", sample: "0001", errors: 2, words: 20)]
        let before = receipt(
            corpora: [(id: "fleurs-en-us", revision: "abc123", samples: 3)],
            backends: [(backend: "fluidaudio", model: "p3", label: "Parakeet v3", utterances: utterances)],
            fluidAudio: "0.15.1"
        )
        let after = receipt(
            corpora: [(id: "fleurs-en-us", revision: "def456", samples: 3)],
            backends: [(backend: "fluidaudio", model: "p3", label: "Parakeet v3", utterances: utterances)],
            fluidAudio: "0.15.6"
        )

        let result = TranscriptionQualityUpgradeComparison.compare(before: before, after: after)
        #expect(result.voided != nil)
        #expect(result.movements.isEmpty, "a voided comparison must report no movements")
        #expect(result.voided?.explanation.contains("revision") ?? false)
    }

    @Test("a corpus that changed sample count voids the comparison")
    func changedSampleCountVoidsTheComparison() {
        let utterances = [utterance(corpus: "fleurs-en-us", sample: "0001", errors: 2, words: 20)]
        let before = receipt(
            corpora: [(id: "fleurs-en-us", revision: "abc123", samples: 3)],
            backends: [(backend: "fluidaudio", model: "p3", label: "Parakeet v3", utterances: utterances)],
            fluidAudio: "0.15.1"
        )
        let after = receipt(
            corpora: [(id: "fleurs-en-us", revision: "abc123", samples: 4)],
            backends: [(backend: "fluidaudio", model: "p3", label: "Parakeet v3", utterances: utterances)],
            fluidAudio: "0.15.6"
        )
        #expect(TranscriptionQualityUpgradeComparison.compare(before: before, after: after).voided != nil)
    }

    /// The removal this upgrade shipped: Qwen3 was measured in the baseline and does not exist in
    /// the later run. That is a fact about the change, so it is reported rather than dropped — and
    /// it must not be mistaken for a backend that regressed.
    @Test("a backend measured only in the baseline is reported, not treated as a regression")
    func removedBackendIsReportedSeparately() {
        let utterances = [utterance(corpus: "fleurs-en-us", sample: "0001", errors: 2, words: 20)]
        let before = receipt(
            corpora: corpus,
            backends: [
                (backend: "fluidaudio", model: "p3", label: "Parakeet v3", utterances: utterances),
                (backend: "qwen", model: "q3", label: "Qwen3 ASR", utterances: utterances),
            ],
            fluidAudio: "0.15.1"
        )
        let after = receipt(
            corpora: corpus,
            backends: [(backend: "fluidaudio", model: "p3", label: "Parakeet v3", utterances: utterances)],
            fluidAudio: "0.15.6"
        )

        let result = TranscriptionQualityUpgradeComparison.compare(before: before, after: after)
        #expect(result.onlyInBefore == ["qwen/q3"])
        #expect(result.onlyInAfter.isEmpty)
        #expect(result.movements.count == 1, "only the shared backend is comparable")
        #expect(result.moved.isEmpty)
    }

    /// Sample ids are each corpus's own, so two corpora can both number a row `0001`. Pairing on
    /// the id alone would match utterances from different corpora and report the difference between
    /// two different recordings as an upgrade effect.
    @Test("utterances are paired within their own corpus, not across corpora")
    func pairingIsScopedToTheCorpus() throws {
        let before = receipt(
            corpora: [
                (id: "fleurs-en-us", revision: "r1", samples: 1),
                (id: "mgb3-egyptian", revision: "r1", samples: 1),
            ],
            backends: [(
                backend: "fluidaudio", model: "p3", label: "Parakeet v3",
                utterances: [
                    utterance(corpus: "fleurs-en-us", sample: "0001", errors: 1, words: 20),
                    utterance(corpus: "mgb3-egyptian", sample: "0001", errors: 9, words: 20),
                ]
            )],
            fluidAudio: "0.15.1"
        )
        let after = receipt(
            corpora: [
                (id: "fleurs-en-us", revision: "r1", samples: 1),
                (id: "mgb3-egyptian", revision: "r1", samples: 1),
            ],
            backends: [(
                backend: "fluidaudio", model: "p3", label: "Parakeet v3",
                utterances: [
                    utterance(corpus: "fleurs-en-us", sample: "0001", errors: 1, words: 20),
                    utterance(corpus: "mgb3-egyptian", sample: "0001", errors: 9, words: 20),
                ]
            )],
            fluidAudio: "0.15.6"
        )

        let movement = try #require(
            TranscriptionQualityUpgradeComparison.compare(before: before, after: after).movements.first
        )
        // Both rows pair with their own corpus's twin, so nothing moved. Had `0001` matched across
        // corpora, the 1-error row would have paired with the 9-error row and shown a difference.
        #expect(movement.pairedUtterances == 2)
        #expect(movement.margin == 0)
        #expect(!movement.moved)
    }

    /// A receipt from before the dependency field existed still compares; the comparison simply
    /// cannot say what produced the earlier numbers, which is the honest answer.
    @Test("a baseline without recorded dependencies still compares")
    func missingDependenciesStillCompares() throws {
        let utterances = [utterance(corpus: "fleurs-en-us", sample: "0001", errors: 2, words: 20)]
        let before = receipt(
            corpora: corpus,
            backends: [(backend: "fluidaudio", model: "p3", label: "Parakeet v3", utterances: utterances)],
            fluidAudio: nil
        )
        let after = receipt(
            corpora: corpus,
            backends: [(backend: "fluidaudio", model: "p3", label: "Parakeet v3", utterances: utterances)],
            fluidAudio: "0.15.6"
        )

        let result = TranscriptionQualityUpgradeComparison.compare(before: before, after: after)
        #expect(result.voided == nil)
        #expect(result.beforeDependencies == nil)
        #expect(result.afterDependencies?.fluidAudio == "0.15.6")
        #expect(try #require(result.movements.first).hasInterval)
    }
}
