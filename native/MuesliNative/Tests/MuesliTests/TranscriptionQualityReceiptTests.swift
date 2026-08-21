import CryptoKit
import Foundation
import MuesliCore
import Testing

private typealias Receipt = TranscriptionQualityReceipt
private typealias Policy = TranscriptionQualityDecision

// MARK: - Decision policy

/// R16's winner selection, proved against constructed score sets (KTD10).
///
/// Every input here is invented rather than measured, which is the point: the policy has to be a
/// function of the numbers, so the numbers can be chosen to isolate one rule at a time.
@Suite("Transcription quality decision policy")
struct TranscriptionQualityDecisionTests {
    // MARK: AE10 — the faithfulness gate

    @Test("a lower-WER backend that changed language is excluded and the best faithful one wins")
    func faithfulnessGateExcludesTheTranslator() throws {
        // The defect this whole harness exists to catch: fluent English rendered from Arabic speech
        // scores a *better* error rate than damaged-but-Arabic output, so error rate alone would
        // crown it.
        let subject = makeReceipt([
            measured("translator", cohort: .egyptianArabic, wers: [0.10, 0.12, 0.08], faithfulness: 0.40),
            measured("faithful", cohort: .egyptianArabic, wers: [0.30, 0.35, 0.33], faithfulness: 0.98),
        ])

        let decision = try #require(Policy.evaluate(subject).cohorts.first)

        #expect(decision.ranking.map(\.backend) == ["faithful"])
        #expect(decision.winner == "faithful")
        #expect(decision.verdict == .soleEligible(backend: "faithful"))
        #expect(decision.excluded.map(\.backend) == ["translator"])
        let exclusion = try #require(decision.excluded.first)
        #expect(exclusion.reason.contains("0.400"))
        #expect(exclusion.reason.contains("0.900"))
        // AE10 asks for the exclusion *and its reason* in the report, not only in the model.
        let report = TranscriptionQualityReport.markdown(for: subject)
        #expect(report.contains("Excluded by the faithfulness gate"))
        #expect(report.contains(exclusion.reason))
    }

    @Test("the gate applies at raw ASR, so a faithful recognizer is not gated for what cleanup did")
    func gateReadsRawASRNotFinalOutput() throws {
        let cleanupTranslated = Receipt.Backend(
            backend: "recognizer",
            model: "recognizer-model",
            label: "recognizer",
            languageConfiguration: "automatic",
            cohorts: [Receipt.CohortResult(cohort: .egyptianArabic, utterances: [
                Receipt.Utterance(
                    sampleID: "s0",
                    corpusID: "corpus",
                    rawASR: stage(wer: 0.20, faithfulness: 0.99),
                    finalOutput: stage(wer: 0.90, faithfulness: 0.05),
                    endToEndSeconds: 1,
                    speechRecognitionSeconds: 0.8,
                    audioDurationSeconds: 5
                ),
            ])]
        )

        let decision = try #require(Policy.evaluate(makeReceipt([cleanupTranslated])).cohorts.first)

        #expect(decision.excluded.isEmpty)
        #expect(decision.winner == "recognizer")
    }

    // MARK: AE11 — ties and missing data

    @Test("two backends inside the interval tie, and a not-runnable third is absent rather than last")
    func tieIsDeclaredAndNotRunnableIsAbsent() throws {
        // Means 0.200 and 0.210 — a hair apart, with per-utterance differences that swing either
        // way, which is exactly the case a naive "lowest number wins" would call decisively.
        let subject = makeReceipt([
            measured("alpha", cohort: .english, wers: [0.10, 0.30, 0.20, 0.25, 0.15], faithfulness: 0.99, seconds: 1.5),
            measured("beta", cohort: .english, wers: [0.30, 0.10, 0.22, 0.18, 0.25], faithfulness: 0.99, seconds: 0.5),
            notRunnable("gamma", reason: "requires macOS 15 or later; host is 14.2.0"),
        ])

        let decision = try #require(Policy.evaluate(subject).cohorts.first)

        // R16.4: no winner claimed, tied backends listed fastest first.
        #expect(decision.verdict == .tie(backends: ["beta", "alpha"]))
        #expect(decision.winner == nil)
        // R16.5: absent from the ranking entirely, never ranked last.
        #expect(decision.ranking.map(\.backend) == ["alpha", "beta"])
        #expect(decision.absent.map(\.backend) == ["gamma"])
        #expect(decision.absent.first?.reason.contains("macOS 15") == true)

        let report = TranscriptionQualityReport.markdown(for: subject)
        #expect(report.contains("**Tie: beta, alpha**"))
        #expect(!report.contains("**Winner"))
    }

    @Test("a backend measured on another cohort is absent here rather than ranked last")
    func noDataInCohortIsAbsent() throws {
        let subject = makeReceipt([
            measured("alpha", cohort: .english, wers: [0.10, 0.12], faithfulness: 0.99),
            measured("beta", cohort: .egyptianArabic, wers: [0.10, 0.12], faithfulness: 0.99),
        ])

        let english = try #require(Policy.evaluate(subject).cohorts.first { $0.cohort == .english })

        #expect(english.ranking.map(\.backend) == ["alpha"])
        #expect(english.absent.map(\.backend) == ["beta"])
        #expect(english.absent.first?.reason.contains("no measured samples") == true)
    }

    // MARK: Winner and margin

    @Test("a clear advantage produces a winner and reports the margin over the runner-up")
    func clearAdvantageProducesAWinnerWithAMargin() throws {
        let subject = makeReceipt([
            measured("alpha", cohort: .english, wers: [0.10, 0.11, 0.09, 0.12, 0.10], faithfulness: 0.99),
            measured("beta", cohort: .english, wers: [0.30, 0.32, 0.28, 0.31, 0.29], faithfulness: 0.99, seconds: 2),
        ])

        let decision = try #require(Policy.evaluate(subject).cohorts.first)

        guard case let .winner(backend, comparison) = decision.verdict else {
            Issue.record("expected an outright winner, got \(decision.verdict)")
            return
        }
        #expect(backend == "alpha")
        #expect(comparison.challenger == "beta")
        #expect(abs(comparison.margin - 0.196) < 1e-9)
        #expect(comparison.pairedUtterances == 5)
        #expect(comparison.isSignificant)
        #expect(comparison.lowerBound > 0)
        #expect(comparison.lowerBound <= comparison.margin)
        #expect(comparison.upperBound >= comparison.margin)

        let report = TranscriptionQualityReport.markdown(for: subject)
        #expect(report.contains("**Winner: alpha**"))
        #expect(report.contains("0.196"))
    }

    @Test("no eligible backend leaves the cohort without a winner rather than crowning the least bad")
    func allGatedOutLeavesNoWinner() throws {
        let subject = makeReceipt([
            measured("a", cohort: .egyptianArabic, wers: [0.10], faithfulness: 0.20),
            measured("b", cohort: .egyptianArabic, wers: [0.20], faithfulness: 0.30),
        ])

        let decision = try #require(Policy.evaluate(subject).cohorts.first)

        #expect(decision.verdict == .noEligibleBackend)
        #expect(decision.ranking.isEmpty)
        #expect(decision.excluded.count == 2)
        #expect(TranscriptionQualityReport.markdown(for: subject).contains("**No winner**"))
    }

    // MARK: R5 — the ranking statistic

    @Test("the ranking pools errors over reference length rather than averaging per-utterance rates")
    func rankingIsPooledRatherThanAveraged() throws {
        // Both backends transcribed the same two utterances: one word long, and thirty words long.
        // `chatty` misses the single word and nothing else; `steady` gets the short one right and
        // misses nine words of the long one. Pooled, chatty is nine times the better recognizer;
        // averaged per utterance the one-word miss counts as much as thirty words and flips it.
        let subject = makeReceipt([
            weighted("chatty", cohort: .english, counts: [(1, 1), (0, 30)], faithfulness: 0.99),
            weighted("steady", cohort: .english, counts: [(0, 1), (9, 30)], faithfulness: 0.99),
        ])

        let decision = try #require(Policy.evaluate(subject).cohorts.first)

        #expect(decision.ranking.map(\.backend) == ["chatty", "steady"])
        #expect(abs(decision.ranking[0].normalizedWER - 1.0 / 31.0) < 1e-12)
        #expect(abs(decision.ranking[1].normalizedWER - 9.0 / 31.0) < 1e-12)
        // The bootstrap has to compare the same statistic the ranking does, or the interval would be
        // about a quantity no one is ranking on.
        let comparison = try #require(decision.comparisons.first)
        #expect(comparison.leader == "chatty")
        #expect(abs(comparison.margin - 8.0 / 31.0) < 1e-12)
    }

    // MARK: Determinism (KTD10)

    @Test("the same receipt scored twice yields identical winners, ties, and Qwen3 verdict")
    func policyIsDeterministic() {
        let subject = makeReceipt([
            measured("alpha", cohort: .english, wers: [0.10, 0.30, 0.20, 0.25, 0.15], faithfulness: 0.99, seconds: 1.5),
            measured("beta", cohort: .english, wers: [0.30, 0.10, 0.22, 0.18, 0.25], faithfulness: 0.99, seconds: 0.5),
            measured("qwen", cohort: .egyptianArabic, wers: [0.40, 0.42], faithfulness: 0.95),
            measured("parakeet", cohort: .egyptianArabic, wers: [0.20, 0.22], faithfulness: 0.97),
        ])

        #expect(Policy.evaluate(subject) == Policy.evaluate(subject))
        #expect(
            TranscriptionQualityReport.markdown(for: subject)
                == TranscriptionQualityReport.markdown(for: subject)
        )
    }

    @Test("the recorded seed is what the interval comes from, and the observed margin is not")
    func seedDrivesTheIntervalButNotTheMargin() throws {
        // Two permutations of the same error rates: the paired differences swing widely while the
        // means match exactly, which is the shape that makes the interval, not the margin, decisive.
        let backends = [
            measured("alpha", cohort: .english, wers: spread(step: 7), faithfulness: 0.99),
            measured("beta", cohort: .english, wers: spread(step: 13), faithfulness: 0.99),
        ]
        let first = Policy.evaluate(makeReceipt(backends))
        let second = Policy.evaluate(
            makeReceipt(backends, thresholds: Receipt.Thresholds(bootstrapSeed: 7))
        )

        let left = try #require(first.cohorts.first?.comparisons.first)
        let right = try #require(second.cohorts.first?.comparisons.first)
        // The observed margin is data, not randomness, so it must not move with the seed.
        #expect(abs(left.margin - right.margin) < 1e-12)
        #expect(left.lowerBound != right.lowerBound || left.upperBound != right.upperBound)
        #expect(!left.isSignificant)
    }

    // MARK: R17 — language configuration

    @Test("a backend that cannot select the cohort's language is marked in the ranking")
    func pinnedLanguageIsMarkedInTheRanking() throws {
        let subject = makeReceipt([
            measured(
                "cohere",
                cohort: .egyptianArabic,
                wers: [0.30],
                faithfulness: 0.95,
                language: "pinned:en"
            ),
        ])

        let decision = try #require(Policy.evaluate(subject).cohorts.first)
        let entry = try #require(decision.ranking.first)

        #expect(!entry.canSelectCohortLanguage)
        #expect(entry.languageConfiguration == "pinned:en")
        let report = TranscriptionQualityReport.markdown(for: subject)
        #expect(report.contains("pinned en"))
        #expect(report.contains("could not select this cohort's language"))
    }

    @Test("an automatic backend can target every cohort, and a pinned one cannot code-switch")
    func languageTargeting() {
        #expect(TranscriptionQualityLanguageConfiguration(rawValue: "automatic") == .automatic)
        #expect(TranscriptionQualityLanguageConfiguration(rawValue: "pinned:ar") == .pinned("ar"))

        for cohort in TranscriptionQuality.Cohort.allCases {
            #expect(TranscriptionQualityLanguageConfiguration.automatic.canTarget(cohort))
        }
        #expect(TranscriptionQualityLanguageConfiguration.pinned("ar").canTarget(.egyptianArabic))
        #expect(!TranscriptionQualityLanguageConfiguration.pinned("ar").canTarget(.english))
        // A single pinned language cannot cover a code-switching cohort at all.
        #expect(!TranscriptionQualityLanguageConfiguration.pinned("ar").canTarget(.arabicEnglish))
        #expect(!TranscriptionQualityLanguageConfiguration.pinned("hi").canTarget(.egyptianArabic))
    }

    // MARK: R16.6 — the Qwen3 verdict

    @Test("Qwen3 is kept when it leads an Arabic cohort, and the alternative is named")
    func qwen3KeptWhenItLeadsAnArabicCohort() {
        let subject = makeReceipt([
            measured("qwen", cohort: .egyptianArabic, wers: [0.10, 0.11, 0.09], faithfulness: 0.97),
            measured("parakeet", cohort: .egyptianArabic, wers: [0.40, 0.41, 0.39], faithfulness: 0.97),
        ])

        let verdict = Policy.evaluate(subject).qwen3

        #expect(verdict.decision == .keep)
        #expect(verdict.cohort == .egyptianArabic)
        #expect(verdict.comparedAgainst == "parakeet")
        // KTD5: the verdict is conditional on the configuration it ran under.
        #expect(verdict.languageConfiguration == "automatic")
        #expect(verdict.rationale.contains("automatic"))
        #expect(verdict.rationale.contains("parakeet"))
    }

    @Test("a tie for first on an Arabic cohort keeps Qwen3")
    func qwen3KeptOnATieForFirst() {
        let subject = makeReceipt([
            measured("qwen", cohort: .arabicEnglish, wers: [0.10, 0.30, 0.20, 0.25, 0.15], faithfulness: 0.97),
            measured("parakeet", cohort: .arabicEnglish, wers: [0.30, 0.10, 0.22, 0.18, 0.25], faithfulness: 0.97),
        ])

        let verdict = Policy.evaluate(subject).qwen3

        #expect(verdict.decision == .keep)
        #expect(verdict.rationale.contains("ties for first"))
    }

    @Test("Qwen3 is dropped when it is gated out, and the report says by whom and why")
    func qwen3DroppedWhenGatedOut() {
        let subject = makeReceipt([
            measured("qwen", cohort: .egyptianArabic, wers: [0.10], faithfulness: 0.30),
            measured("parakeet", cohort: .egyptianArabic, wers: [0.40], faithfulness: 0.97),
        ])

        let verdict = Policy.evaluate(subject).qwen3

        #expect(verdict.decision == .drop)
        #expect(verdict.comparedAgainst == "parakeet")
        #expect(verdict.rationale.contains("faithfulness"))
        #expect(TranscriptionQualityReport.markdown(for: subject).contains("Qwen3 verdict: drop"))
    }

    @Test("winning English alone does not keep Qwen3")
    func qwen3EnglishWinDoesNotDecideIt() {
        let subject = makeReceipt([
            measured("qwen", cohort: .english, wers: [0.05], faithfulness: 0.99),
            measured("parakeet", cohort: .english, wers: [0.40], faithfulness: 0.99),
        ])

        #expect(Policy.evaluate(subject).qwen3.decision == .undecided)
    }

    @Test("a not-runnable Qwen3 decides nothing rather than being dropped on no evidence")
    func qwen3NotRunnableIsUndecided() {
        let subject = makeReceipt([
            notRunnable("qwen", reason: "model is not downloaded, and the harness never downloads one"),
            measured("parakeet", cohort: .egyptianArabic, wers: [0.40], faithfulness: 0.97),
        ])

        let verdict = Policy.evaluate(subject).qwen3

        #expect(verdict.decision == .undecided)
        #expect(verdict.rationale.contains("no measurement"))
    }
}

// MARK: - Receipt and report

@Suite("Transcription quality receipt")
struct TranscriptionQualityReceiptTests {
    // MARK: AE8 — nothing but derived results

    @Test("a receipt built from scored text round-trips and carries neither reference nor hypothesis")
    func receiptCarriesNoTranscriptText() throws {
        let reference = "الاجتماع بكرة الصبح في المكتب"
        let hypothesis = "the meeting is tomorrow morning at the office"
        let scored = Receipt.Utterance(
            sampleID: "arzen-0042",
            corpusID: "arzen",
            rawASR: Receipt.StageSummary(TranscriptionQuality.StageScore(
                stage: .rawASR,
                cohort: .egyptianArabic,
                reference: reference,
                hypothesis: hypothesis
            )),
            finalOutput: Receipt.StageSummary(TranscriptionQuality.StageScore(
                stage: .finalOutput,
                cohort: .egyptianArabic,
                reference: reference,
                hypothesis: hypothesis
            )),
            endToEndSeconds: 2.4,
            speechRecognitionSeconds: 2.1,
            audioDurationSeconds: 5.8
        )
        let original = makeReceipt([
            Receipt.Backend(
                backend: "qwen",
                model: "qwen3-asr",
                label: "Qwen3 ASR",
                languageConfiguration: "automatic",
                warmup: Receipt.Warmup(sampleID: "arzen-0001", endToEndSeconds: 31.2, failureMessage: nil),
                cohorts: [Receipt.CohortResult(cohort: .egyptianArabic, utterances: [scored])],
                failedSampleIDs: ["arzen-0099"]
            ),
        ])

        let encoded = try JSONEncoder().encode(original)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains(reference))
        #expect(!json.contains(hypothesis))
        // The measurement still made it through: the scores are the point of keeping the text out.
        #expect(scored.rawASR.faithfulness < TranscriptionQuality.Threshold.faithfulnessGate)

        let decoded = try JSONDecoder().decode(Receipt.self, from: encoded)
        #expect(decoded.schemaVersion == Receipt.currentSchemaVersion)
        #expect(decoded.backends.count == 1)
        #expect(decoded.backends[0].failedSampleIDs == ["arzen-0099"])
        let roundTripped = try #require(decoded.backends[0].result(for: .egyptianArabic)?.utterances.first)
        #expect(roundTripped == scored)
    }

    @Test("every key a receipt encodes is on the allow-list, so a text field cannot be added quietly")
    func encodedKeysAreOnTheAllowList() throws {
        let encoded = try JSONEncoder().encode(populatedReceipt())
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(jsonKeys(object).subtracting(allowedReceiptKeys).isEmpty)
    }

    @Test("the thresholds the verdict was reached under round-trip in the receipt")
    func thresholdsRoundTrip() throws {
        let thresholds = Receipt.Thresholds()
        #expect(thresholds.faithfulnessGate == TranscriptionQuality.Threshold.faithfulnessGate)
        #expect(thresholds.confidenceLevel == 0.95)

        let decoded = try JSONDecoder().decode(
            Receipt.self,
            from: JSONEncoder().encode(makeReceipt([], thresholds: thresholds))
        )

        #expect(decoded.thresholds == thresholds)
        #expect(decoded.thresholds.faithfulnessGate == 0.90)
        #expect(decoded.thresholds.bootstrapResamples == 1_000)
        #expect(decoded.thresholds.bootstrapSeed == Receipt.Thresholds.defaultSeed)
    }

    // MARK: Report

    @Test("a not-runnable backend renders its reason rather than a zero")
    func notRunnableRendersAReasonNotAZero() {
        let reason = "requires macOS 15 or later; host is 14.2.0"
        let subject = makeReceipt([
            measured("parakeet", cohort: .english, wers: [0.10, 0.12], faithfulness: 0.99),
            notRunnable("qwen", reason: reason),
        ])

        let report = TranscriptionQualityReport.markdown(for: subject)

        #expect(report.contains("## Not runnable on this host"))
        #expect(report.contains(reason))
        // The ranking table is numbered rows; a zeroed-out Qwen3 row would appear as one of them.
        let rankingRows = report.split(separator: "\n").filter {
            $0.hasPrefix("| 1 |") || $0.hasPrefix("| 2 |")
        }
        #expect(rankingRows.count == 1)
        #expect(rankingRows.allSatisfy { !$0.contains("qwen") })
    }

    @Test("the report states provenance, corpus identity, thresholds, and the disclosed judgement calls")
    func reportStatesProvenanceAndDisclosures() {
        let report = TranscriptionQualityReport.markdown(for: populatedReceipt())

        #expect(report.contains("Schema v2"))
        #expect(report.contains("Mac16,10"))
        #expect(report.contains("arzen"))
        #expect(report.contains("CC-BY-4.0"))
        #expect(report.contains("Faithfulness gate"))
        #expect(report.contains("Bootstrap seed"))
        #expect(report.contains("cold start"))
        #expect(report.contains("cleanup LLM stays resident"))
        #expect(report.contains("run under battery power"))
        // The disclosure that the statistic was an unweighted mean is gone because the statistic is
        // no longer one; the report has to state what it now is instead.
        #expect(!report.contains("unweighted mean"))
        #expect(report.contains("total edit distance over total reference length"))
    }

    @Test("the report reports each measured cohort separately rather than one headline figure")
    func reportSeparatesCohorts() {
        let report = TranscriptionQualityReport.markdown(for: populatedReceipt())

        #expect(report.contains("## Cohort: egyptian-arabic"))
        #expect(report.contains("## Cohort: arabic-english"))
        #expect(!report.contains("## Cohort: english"))
    }

    // MARK: Aggregation

    /// R5: published ASR figures are pooled, so a cohort figure that is not pooled is not the thing
    /// it is being compared against. One word wrong out of thirty-one spoken is a 3% error rate; the
    /// unweighted mean of the two utterance rates calls the same recording 50%.
    @Test("a cohort's error rate is total edit distance over total reference length")
    func cohortErrorRateIsPooled() throws {
        let cohort = Receipt.CohortResult(cohort: .english, utterances: [
            countedUtterance("short", errors: 1, referenceWords: 1),
            countedUtterance("long", errors: 0, referenceWords: 30),
        ])

        let pooled = try #require(cohort.pooledNormalizedWER(at: .rawASR))

        #expect(abs(pooled - 1.0 / 31.0) < 1e-12)
        // Characters run five to the word here, so the same pooling has to hold on CER.
        #expect(abs(try #require(cohort.pooledNormalizedCER(at: .rawASR)) - 1.0 / 31.0) < 1e-12)
        #expect(abs(try #require(cohort.pooledRawWER(at: .rawASR)) - 1.0 / 31.0) < 1e-12)
    }

    @Test("a cohort with no utterances reports nil rather than zero")
    func emptyCohortAggregatesToNil() {
        let empty = Receipt.CohortResult(cohort: .english, utterances: [])

        #expect(empty.pooledNormalizedWER(at: .rawASR) == nil)
        #expect(empty.pooledRawWER(at: .rawASR) == nil)
        #expect(empty.meanFaithfulness(at: .rawASR) == nil)
        #expect(empty.endToEndLatency == nil)
        #expect(empty.realTimeFactor == nil)
    }
}

// MARK: - v2 fixture contract (R15, AE9)

/// The v2 fixture directory has its own manifest, its own loader, and its own caps — and the v1
/// directory is asserted here to be exactly what its own manifest says, so a future file dropped
/// beside v1 fails loudly here as well as in v1's own suite.
@Suite("Transcription quality run fixture contract")
struct TranscriptionQualityRunFixtureContractTests {
    /// v1 is frozen. Written out rather than derived, so that editing v1's manifest to admit a new
    /// file does not also edit the assertion that would have caught it.
    static let version1Files: Set<String> = [
        "manifest.json", "PROVENANCE.md", "README.md", "baseline-v1.json", "samples.jsonl",
    ]

    @Test("adding the v2 directory leaves the v1 directory's file set exactly as it was")
    func version1DirectoryIsUntouched() throws {
        let version1 = try FixtureDirectory.load("TranscriptionQuality")
        let manifest = try version1.decode(RunManifest.self, file: "manifest.json")

        #expect(manifest.schemaVersion == 1)
        #expect(version1.regularFilePaths == Self.version1Files)
        #expect(version1.regularFilePaths == Set(manifest.files.map(\.path) + ["manifest.json"]))

        // KTD3: v2 is a sibling directory, not a set of files added beside v1. Both directories
        // hold a `README.md` and a `manifest.json` of their own, so what has to be true is that no
        // *receipt* landed in v1 — that is the file whose arrival would break v1's own gate.
        let runs = try FixtureDirectory.load("TranscriptionQualityRuns")
        #expect(version1.root.path != runs.root.path)
        let receipts = runs.regularFilePaths.filter { $0.hasPrefix("run-") }
        #expect(!receipts.isEmpty)
        #expect(version1.regularFilePaths.isDisjoint(with: receipts))
        #expect(!version1.regularFilePaths.contains { $0.hasPrefix("run-") })
    }

    @Test("v2 files match their own manifest's hashes and size cap")
    func version2ManifestIsFrozen() throws {
        let directory = try FixtureDirectory.load("TranscriptionQualityRuns")
        let manifest = try directory.decode(RunManifest.self, file: "manifest.json")

        #expect(manifest.schemaVersion == Receipt.currentSchemaVersion)
        #expect(directory.regularFilePaths == Set(manifest.files.map(\.path) + ["manifest.json"]))
        #expect(directory.totalBytes <= (try #require(manifest.maximumDirectoryBytes)))

        for entry in manifest.files {
            let data = try Data(contentsOf: directory.root.appendingPathComponent(entry.path))
            #expect(data.count == entry.bytes)
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == entry.sha256)
        }
    }

    @Test("the committed example receipt decodes, scores, and carries no transcript-shaped key")
    func committedReceiptDecodesAndScores() throws {
        let directory = try FixtureDirectory.load("TranscriptionQualityRuns")
        let data = try Data(contentsOf: directory.root.appendingPathComponent("run-example-v2.json"))
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)

        #expect(receipt.schemaVersion == 2)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(jsonKeys(object).subtracting(allowedReceiptKeys).isEmpty)

        // The example encodes the AE10 shape: Qwen3 has the worse error rate *and* fails the gate.
        let evaluated = Policy.evaluate(receipt)
        let decision = try #require(evaluated.cohorts.first)
        #expect(decision.winner == "parakeet")
        #expect(decision.excluded.map(\.backend) == ["qwen"])
        #expect(decision.absent.map(\.backend) == ["indicasr"])
        #expect(evaluated.qwen3.decision == .drop)
        #expect(!TranscriptionQualityReport.markdown(for: receipt, decisions: evaluated).isEmpty)
    }
}

// MARK: - Fixture loading

private struct FixtureDirectory {
    let root: URL
    let totalBytes: Int
    let regularFilePaths: Set<String>

    static func load(_ name: String) throws -> FixtureDirectory {
        let root = try #require(Bundle.module.resourceURL?
            .appendingPathComponent("Fixtures/\(name)", isDirectory: true))
        let enumerator = try #require(FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ))
        var totalBytes = 0
        var paths = Set<String>()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            totalBytes += values.fileSize ?? 0
            paths.insert(String(url.path.dropFirst(root.path.count + 1)))
        }
        return FixtureDirectory(root: root, totalBytes: totalBytes, regularFilePaths: paths)
    }

    func decode<Value: Decodable>(_ type: Value.Type, file: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(contentsOf: root.appendingPathComponent(file)))
    }
}

/// Deliberately a separate declaration from v1's manifest type: R15 asks for an independent loader,
/// and sharing one would let a v2 change silently redefine what v1 is checked against.
private struct RunManifest: Decodable {
    let schemaVersion: Int
    /// v1 calls its cap `maximumCorpusBytes`; decoding v1's manifest through this type therefore
    /// only reads the fields both schemas share, which is the point of keeping the loaders apart.
    let maximumDirectoryBytes: Int?
    let files: [FileEntry]

    struct FileEntry: Decodable {
        let path: String
        let bytes: Int
        let sha256: String
    }
}

// MARK: - AE8 allow-list

/// Every JSON key the v2 schema may emit. R2's rule is enforced as an allow-list rather than a
/// blocklist of suspicious names: a field that can hold transcript text is caught because it is new,
/// not because someone guessed what it would be called.
private let allowedReceiptKeys: Set<String> = [
    "schemaVersion", "runID", "generatedAt",
    "host", "operatingSystemVersion", "machineModel", "architecture", "processorCount",
    "physicalMemoryBytes",
    "corpora", "id", "revision", "licenceIdentifier", "acquisition", "cohorts", "sampleCount",
    "issueCount",
    "thresholds", "faithfulnessGate", "confidenceLevel", "bootstrapResamples", "bootstrapSeed",
    "disclosures", "cleanupEnabled", "warmupSampleConsumed", "cleanupModelResidentAcrossSweep",
    "notes",
    "backends", "backend", "model", "label", "languageConfiguration", "notRunnableReason",
    "failedSampleIDs",
    "warmup", "sampleID", "endToEndSeconds", "failureMessage",
    "cohort", "utterances", "corpusID", "speechRecognitionSeconds", "audioDurationSeconds",
    "rawASR", "finalOutput",
    "rawWER", "rawCER", "normalizedWER", "normalizedCER", "faithfulness",
    "scriptChangeInflatesErrorRate",
    // Integer counts, not text: they are the denominators a pooled cohort rate is recomputed from,
    // and they reconstruct nothing that was said (R2, R5).
    "rawWordErrors", "rawReferenceWords", "rawCharacterErrors", "rawReferenceCharacters",
    "normalizedWordErrors", "normalizedReferenceWords", "normalizedCharacterErrors",
    "normalizedReferenceCharacters",
]

private func jsonKeys(_ value: Any) -> Set<String> {
    switch value {
    case let object as [String: Any]:
        return object.reduce(into: Set(object.keys)) { $0.formUnion(jsonKeys($1.value)) }
    case let array as [Any]:
        return array.reduce(into: Set()) { $0.formUnion(jsonKeys($1)) }
    default:
        return []
    }
}

// MARK: - Construction helpers

/// Every utterance is a hundred reference words long, so the pooled figure equals the requested rate
/// exactly and a test written about a *rate* still says what it meant to say. Length is varied only
/// where the test is about weighting — see `weighted`.
private func stage(wer: Double, faithfulness: Double) -> Receipt.StageSummary {
    let rates = TranscriptionQuality.ErrorRates(
        wordErrors: Int((wer * 100).rounded()),
        referenceWords: 100,
        characterErrors: Int((wer * 500).rounded()),
        referenceCharacters: 1_000
    )
    return Receipt.StageSummary(
        raw: rates,
        normalized: rates,
        faithfulness: faithfulness,
        scriptChangeInflatesErrorRate: false
    )
}

/// A stage built from edit distances and reference lengths rather than from a rate, so a test can
/// construct utterances of deliberately unequal length. Characters run five to the word: only the
/// differing denominators matter, not the ratio.
private func countedStage(
    errors: Int,
    referenceWords: Int,
    faithfulness: Double = 0.99
) -> Receipt.StageSummary {
    let rates = TranscriptionQuality.ErrorRates(
        wordErrors: errors,
        referenceWords: referenceWords,
        characterErrors: errors * 5,
        referenceCharacters: referenceWords * 5
    )
    return Receipt.StageSummary(
        raw: rates,
        normalized: rates,
        faithfulness: faithfulness,
        scriptChangeInflatesErrorRate: false
    )
}

private func countedUtterance(_ identifier: String, errors: Int, referenceWords: Int) -> Receipt.Utterance {
    Receipt.Utterance(
        sampleID: identifier,
        corpusID: "corpus",
        rawASR: countedStage(errors: errors, referenceWords: referenceWords),
        finalOutput: countedStage(errors: errors, referenceWords: referenceWords),
        endToEndSeconds: 1,
        speechRecognitionSeconds: 0.8,
        audioDurationSeconds: 5
    )
}

/// Like `measured`, but the utterances carry counts instead of rates and differ in length, which is
/// what separates a pooled figure from a mean of per-utterance rates.
private func weighted(
    _ identifier: String,
    cohort: TranscriptionQuality.Cohort,
    counts: [(errors: Int, referenceWords: Int)],
    faithfulness: Double,
    seconds: Double = 1
) -> Receipt.Backend {
    Receipt.Backend(
        backend: identifier,
        model: "\(identifier)-model",
        label: identifier,
        languageConfiguration: "automatic",
        cohorts: [Receipt.CohortResult(
            cohort: cohort,
            utterances: counts.enumerated().map { offset, count in
                Receipt.Utterance(
                    sampleID: "s\(offset)",
                    corpusID: "corpus",
                    rawASR: countedStage(
                        errors: count.errors,
                        referenceWords: count.referenceWords,
                        faithfulness: faithfulness
                    ),
                    finalOutput: countedStage(
                        errors: count.errors,
                        referenceWords: count.referenceWords,
                        faithfulness: faithfulness
                    ),
                    endToEndSeconds: seconds,
                    speechRecognitionSeconds: seconds * 0.8,
                    audioDurationSeconds: 5
                )
            }
        )]
    )
}

/// Twenty error rates in a fixed but scattered order. Two different steps produce permutations of
/// the same multiset, so the two backends' means match exactly while their paired differences do
/// not — the only shape in which a bootstrap interval, and not the margin, decides the outcome.
private func spread(step: Int) -> [Double] {
    (0 ..< 20).map { 0.05 + Double(($0 * step) % 20) * 0.02 }
}

/// Sample ids are shared across backends by construction, which is what lets the paired bootstrap
/// pair them — the same property a real sweep has, since every backend sees the same corpus.
private func measured(
    _ identifier: String,
    cohort: TranscriptionQuality.Cohort,
    wers: [Double],
    faithfulness: Double,
    seconds: Double = 1,
    language: String = "automatic"
) -> Receipt.Backend {
    Receipt.Backend(
        backend: identifier,
        model: "\(identifier)-model",
        label: identifier,
        languageConfiguration: language,
        cohorts: [Receipt.CohortResult(
            cohort: cohort,
            utterances: wers.enumerated().map { offset, wer in
                Receipt.Utterance(
                    sampleID: "s\(offset)",
                    corpusID: "corpus",
                    rawASR: stage(wer: wer, faithfulness: faithfulness),
                    finalOutput: stage(wer: wer, faithfulness: faithfulness),
                    endToEndSeconds: seconds,
                    speechRecognitionSeconds: seconds * 0.8,
                    audioDurationSeconds: 5
                )
            }
        )]
    )
}

private func notRunnable(_ identifier: String, reason: String) -> Receipt.Backend {
    Receipt.Backend(
        backend: identifier,
        model: "\(identifier)-model",
        label: identifier,
        languageConfiguration: "automatic",
        notRunnableReason: reason
    )
}

private func makeReceipt(
    _ backends: [Receipt.Backend],
    thresholds: Receipt.Thresholds = Receipt.Thresholds()
) -> Receipt {
    Receipt(
        runID: "test",
        generatedAt: "2026-08-21T00:00:00Z",
        host: testHost,
        corpora: [],
        thresholds: thresholds,
        disclosures: Receipt.Disclosures(cleanupEnabled: true),
        backends: backends
    )
}

private let testHost = Receipt.Host(
    operatingSystemVersion: "26.0.0",
    machineModel: "Mac16,10",
    architecture: "Apple M4",
    processorCount: 10,
    physicalMemoryBytes: 17_179_869_184
)

/// A receipt with every optional field populated, so the allow-list and the report are checked
/// against the widest shape the schema can take rather than the narrowest.
private func populatedReceipt() -> Receipt {
    Receipt(
        runID: "populated",
        generatedAt: "2026-08-21T00:00:00Z",
        host: testHost,
        corpora: [Receipt.Corpus(
            id: "arzen",
            revision: "v1.0",
            licenceIdentifier: "CC-BY-4.0",
            acquisition: "hugging-face",
            cohorts: [.egyptianArabic, .arabicEnglish],
            sampleCount: 120,
            issueCount: 3
        )],
        disclosures: Receipt.Disclosures(cleanupEnabled: true, notes: ["run under battery power"]),
        backends: [
            Receipt.Backend(
                backend: "parakeet",
                model: "parakeet-tdt-0.6b-v3",
                label: "Parakeet v3",
                languageConfiguration: "automatic",
                warmup: Receipt.Warmup(
                    sampleID: "s0",
                    endToEndSeconds: nil,
                    failureMessage: "warmup sample could not be decoded"
                ),
                cohorts: [
                    Receipt.CohortResult(cohort: .egyptianArabic, utterances: [
                        Receipt.Utterance(
                            sampleID: "s1",
                            corpusID: "arzen",
                            rawASR: stage(wer: 0.30, faithfulness: 0.96),
                            finalOutput: stage(wer: 0.28, faithfulness: 0.95),
                            endToEndSeconds: 0.44,
                            speechRecognitionSeconds: 0.21,
                            audioDurationSeconds: 6.1
                        ),
                    ]),
                    // No audio duration, so the real-time factor has no denominator and must render
                    // as not-applicable rather than as an infinitely fast backend.
                    Receipt.CohortResult(cohort: .arabicEnglish, utterances: [
                        Receipt.Utterance(
                            sampleID: "m0",
                            corpusID: "arzen",
                            rawASR: stage(wer: 0.40, faithfulness: 0.93),
                            finalOutput: stage(wer: 0.38, faithfulness: 0.92),
                            endToEndSeconds: 0.50,
                            speechRecognitionSeconds: 0.30,
                            audioDurationSeconds: nil
                        ),
                    ]),
                ],
                failedSampleIDs: ["s9"]
            ),
            notRunnable("qwen", reason: "requires macOS 15 or later; host is 14.2.0"),
        ]
    )
}
