import Foundation

// The R16 winner-selection policy and the paired bootstrap it gates on, split out of
// `TranscriptionQualityReceipt.swift`: the schema, the policy and the renderer are three
// concerns with one dependency direction between them, and reading any one of them should not
// mean scrolling past the other two.

/// R16's winner selection: a pure, deterministic function of a receipt (KTD10).
///
/// Nothing here consults the clock, the environment, or a system RNG. Given the same receipt it
/// returns the same verdict, which is what makes the report reproducible rather than an opinion.
///
/// Everything is keyed on `Backend.identity`, never on `Backend.backend`: the latter is a family
/// name shared by six Whisper checkpoints, and keying on it merged distinct models into one row.
public enum TranscriptionQualityDecision {
    /// A backend that is in the running for a cohort.
    public struct Entry: Sendable, Equatable {
        /// `backend/model` — unique across the inventory.
        public let identity: String
        /// The family, kept so a verdict about "Qwen3" can still be asked for by family name.
        public let backend: String
        public let label: String
        public let languageConfiguration: String
        public let sampleCount: Int
        /// Pooled over the cohort's reference length, not averaged per utterance (R5).
        public let normalizedWER: Double
        public let finalOutputNormalizedWER: Double?
        public let faithfulness: Double
        /// How many utterances that faithfulness figure rests on, which is below `sampleCount`
        /// whenever some references carried nothing script-bearing.
        public let faithfulnessSampleCount: Int
        public let finalOutputFaithfulness: Double?
        /// Utterances whose final stage is the cleanup stage's product. Zero means this backend
        /// measured nothing about cleanup, whatever the run asked for.
        public let finalOutputMeasuredCount: Int
        public let p50Seconds: Double?
        public let p95Seconds: Double?
        public let realTimeFactor: Double?
        /// R17's mark. `false` means the backend could not select this cohort's language, so its
        /// position is a statement about a configuration, not about the model's ability.
        public let canSelectCohortLanguage: Bool
        /// R9's cold start misbehaved for this backend. It still scored its samples, but a model
        /// that failed its very first call is not a clean win.
        public let warmupFailed: Bool
    }

    /// A backend the faithfulness gate removed, kept in the report with its reason (AE10).
    public struct Exclusion: Sendable, Equatable {
        public let identity: String
        public let backend: String
        public let label: String
        public let normalizedWER: Double
        public let faithfulness: Double
        /// The receipt's own gate, not the compiled-in constant: a receipt scored under a different
        /// threshold must state the threshold it was actually scored under.
        public let gate: Double
        public let canSelectCohortLanguage: Bool

        public var reason: String {
            "raw-ASR faithfulness \(TranscriptionQualityDecision.format(faithfulness)) is below the "
                + "\(TranscriptionQualityDecision.format(gate)) gate"
        }
    }

    /// A backend with no usable data for this cohort. Listed apart from the ranking because R16.5
    /// forbids ranking it last: not measured is not the same as measured badly.
    public struct Absent: Sendable, Equatable {
        public let identity: String
        public let backend: String
        public let label: String
        public let reason: String
    }

    /// The paired bootstrap's answer about two backends on one cohort.
    public struct Comparison: Sendable, Equatable {
        public let leader: String
        public let challenger: String
        /// Challenger minus leader pooled normalized WER over the utterances both measured.
        /// Positive means the leader is ahead.
        public let margin: Double
        /// `nil` when no interval could be computed: nothing paired, or a threshold set that cannot
        /// resample. Absent bounds never separate anyone — an interval that does not exist is not
        /// evidence of an advantage.
        public let lowerBound: Double?
        public let upperBound: Double?
        public let pairedUtterances: Int
        /// The two populations the *ranking* pooled. The ranking uses every utterance a backend
        /// measured while the interval can only use the overlap, so when these differ the placement
        /// and the interval describe different data and the report has to say so.
        public let leaderUtterances: Int
        public let challengerUtterances: Int

        /// The leader's advantage clears the interval, so the ordering is not resampling noise.
        public var isSignificant: Bool {
            guard let lowerBound else { return false }
            return lowerBound > 0
        }

        /// The interval rests on exactly the utterances both rankings were pooled from.
        public var isFullyPaired: Bool {
            pairedUtterances == leaderUtterances && pairedUtterances == challengerUtterances
        }
    }

    public enum Verdict: Sendable, Equatable {
        /// Won outright: ahead of the runner-up by more than the interval.
        case winner(backend: String, over: Comparison)
        /// The only backend that passed the gate, so there was no contest to win.
        case soleEligible(backend: String)
        /// Backends whose differences sit inside the interval, in ascending p50 latency (R16.4).
        case tie(backends: [String])
        case noEligibleBackend
    }

    public struct CohortDecision: Sendable, Equatable {
        public let cohort: TranscriptionQuality.Cohort
        /// Eligible backends, ascending normalized WER at `rawASR`. Identified by `Entry.identity`.
        public let ranking: [Entry]
        public let excluded: [Exclusion]
        public let absent: [Absent]
        public let verdict: Verdict
        /// Every leader-vs-challenger comparison, so the report can show why a tie is a tie.
        public let comparisons: [Comparison]

        public var winner: String? {
            switch verdict {
            case let .winner(backend, _): backend
            case let .soleEligible(backend): backend
            case .tie, .noEligibleBackend: nil
            }
        }

        /// Backends that are first-equal: the outright winner, or every member of the tie. Values
        /// are identities.
        public var leaders: [String] {
            switch verdict {
            case let .winner(backend, _): [backend]
            case let .soleEligible(backend): [backend]
            case let .tie(backends): backends
            case .noEligibleBackend: []
            }
        }

        /// Whether the verdict rests on more than one eligible backend. A lead over an empty field
        /// is not a win, and R16.6 is the rule that has to know the difference.
        public var wasContested: Bool { ranking.count > 1 }

        public func entry(identity: String) -> Entry? {
            ranking.first { $0.identity == identity }
        }

        public func label(for identity: String) -> String {
            entry(identity: identity)?.label
                ?? excluded.first { $0.identity == identity }?.label
                ?? absent.first { $0.identity == identity }?.label
                ?? identity
        }
    }

    /// R16.6's verdict on the backend this whole exercise was commissioned to settle.
    public struct Qwen3Verdict: Sendable, Equatable {
        public enum Decision: String, Sendable {
            case keep
            case drop
            /// Qwen3 led a cohort in which it was the only backend to pass the faithfulness gate.
            /// R16.6 keeps Qwen3 when it *wins or ties for first*, and neither happened: winning
            /// against an empty field is not a comparison, and retaining a backend on it would be
            /// reading the absence of a competitor as evidence of quality.
            case uncontested
            /// Qwen3 produced no data on either Arabic cohort, so there is nothing to decide on.
            case undecided
        }

        public let decision: Decision
        /// The cohort that carried the decision, when one did.
        public let cohort: TranscriptionQuality.Cohort?
        /// KTD5: the verdict holds only for the configuration Qwen3 actually ran under.
        public let languageConfiguration: String?
        /// The backend it was measured against, named so "Qwen3 loses" is never an unattributed
        /// claim. `nil` for `uncontested` and `undecided`, which are exactly the verdicts with no
        /// opponent to name.
        public let comparedAgainst: String?
        public let rationale: String
    }

    public struct Report: Sendable, Equatable {
        public let cohorts: [CohortDecision]
        public let qwen3: Qwen3Verdict
    }

    /// The backend *family* the Qwen3 verdict is about, as `BackendOption.backend` spells it.
    public static let qwen3BackendIdentifier = "qwen"

    /// The cohorts R16.6 lets Qwen3 justify itself on. English is not among them: Qwen3 is under
    /// consideration for Arabic, and winning English would not answer the question asked.
    public static let qwen3DecidingCohorts: [TranscriptionQuality.Cohort] = [.egyptianArabic, .arabicEnglish]

    public static func evaluate(_ receipt: TranscriptionQualityReceipt) -> Report {
        let cohorts = receipt.measuredCohorts.map { decide(cohort: $0, receipt: receipt) }
        return Report(cohorts: cohorts, qwen3: qwen3Verdict(cohorts: cohorts, receipt: receipt))
    }

    // MARK: Per-cohort

    static func decide(
        cohort: TranscriptionQuality.Cohort,
        receipt: TranscriptionQualityReceipt
    ) -> CohortDecision {
        var ranking: [Entry] = []
        var excluded: [Exclusion] = []
        var absent: [Absent] = []
        var utterancesByIdentity: [String: [TranscriptionQualityReceipt.Utterance]] = [:]

        for backend in receipt.backends {
            let canTarget = backend.language.canTarget(cohort)
            func markAbsent(_ reason: String) {
                absent.append(Absent(
                    identity: backend.identity,
                    backend: backend.backend,
                    label: backend.label,
                    reason: reason
                ))
            }
            // R16.5, AE11: not-runnable and no-data are the same thing to a ranking — absent. A
            // backend that never produced a number must not be given the worst one.
            guard backend.isRunnable else {
                markAbsent(backend.notRunnableDescription ?? "not runnable")
                continue
            }
            guard let result = backend.result(for: cohort), result.sampleCount > 0,
                  let normalizedWER = result.pooledNormalizedWER(at: .rawASR)
            else {
                markAbsent("no measured samples in this cohort")
                continue
            }
            // A2: a cohort whose references carry no script-bearing token has no language evidence
            // in it. It is absent from the ranking, not gate-passing — the gate would otherwise be
            // cleared by an average over nothing.
            guard let faithfulness = result.meanFaithfulness(at: .rawASR) else {
                markAbsent(
                    "faithfulness is not applicable to any of this cohort's \(result.sampleCount) "
                        + "references, so the gate has nothing to decide on"
                )
                continue
            }

            // R16.1, KTD10: the gate is applied before any error rate is compared, because the two
            // are not commensurable — no WER advantage buys back a language change.
            guard faithfulness >= receipt.thresholds.faithfulnessGate else {
                excluded.append(Exclusion(
                    identity: backend.identity,
                    backend: backend.backend,
                    label: backend.label,
                    normalizedWER: normalizedWER,
                    faithfulness: faithfulness,
                    gate: receipt.thresholds.faithfulnessGate,
                    canSelectCohortLanguage: canTarget
                ))
                continue
            }

            let latency = result.endToEndLatency
            utterancesByIdentity[backend.identity] = result.utterances
            ranking.append(Entry(
                identity: backend.identity,
                backend: backend.backend,
                label: backend.label,
                languageConfiguration: backend.languageConfiguration,
                sampleCount: result.sampleCount,
                normalizedWER: normalizedWER,
                finalOutputNormalizedWER: result.pooledNormalizedWER(at: .finalOutput),
                faithfulness: faithfulness,
                faithfulnessSampleCount: result.faithfulnessMeasuredCount(at: .rawASR),
                finalOutputFaithfulness: result.meanFaithfulness(at: .finalOutput),
                finalOutputMeasuredCount: result.measuredCount(at: .finalOutput),
                p50Seconds: latency?.p50,
                p95Seconds: latency?.p95,
                realTimeFactor: result.realTimeFactor,
                canSelectCohortLanguage: canTarget,
                warmupFailed: backend.warmup?.didFail == true
            ))
        }

        // R16.2. The tiebreak on identity is not a preference; it stops the order of the inventory
        // from deciding which of two identical scores is called the leader. Identity, not family:
        // two Whisper checkpoints share a family and the family is not a total order over them.
        ranking.sort {
            $0.normalizedWER == $1.normalizedWER
                ? $0.identity < $1.identity
                : $0.normalizedWER < $1.normalizedWER
        }

        guard let leader = ranking.first else {
            return CohortDecision(
                cohort: cohort,
                ranking: ranking,
                excluded: excluded,
                absent: absent,
                verdict: .noEligibleBackend,
                comparisons: []
            )
        }
        guard ranking.count > 1 else {
            return CohortDecision(
                cohort: cohort,
                ranking: ranking,
                excluded: excluded,
                absent: absent,
                verdict: .soleEligible(backend: leader.identity),
                comparisons: []
            )
        }

        let comparisons = ranking.dropFirst().map { challenger in
            TranscriptionQualityBootstrap.compare(
                leader: leader.identity,
                leaderUtterances: utterancesByIdentity[leader.identity] ?? [],
                challenger: challenger.identity,
                challengerUtterances: utterancesByIdentity[challenger.identity] ?? [],
                thresholds: receipt.thresholds
            )
        }

        // R16.3, R16.4. The tie is a *prefix* of the ranking, not a set. Each comparison is a paired
        // bootstrap over its own overlap, so the intervals are not nested: the leader can separate
        // itself from #2 and fail to separate from #3. Collecting every unseparated challenger would
        // then print "tie: leader, #3" and quietly drop the backend that outranked #3 — a verdict no
        // comparison in the receipt supports. Stopping at the first separation cannot skip anyone.
        var tied = [leader.identity]
        for comparison in comparisons {
            guard !comparison.isSignificant else { break }
            tied.append(comparison.challenger)
        }

        let verdict: Verdict
        if tied.count > 1 {
            // A backend with no latency figure sorts last rather than first: an unmeasured p50 is
            // not a fast one. `uniquingKeysWith` rather than `uniqueKeysWithValues` so a future
            // duplicate identity degrades instead of trapping mid-report.
            let p50 = Dictionary(
                ranking.map { ($0.identity, $0.p50Seconds ?? .infinity) },
                uniquingKeysWith: min
            )
            // R16.4: fastest first among equals, since latency is the only thing left to separate
            // backends the accuracy interval could not.
            verdict = .tie(backends: tied.sorted {
                let left = p50[$0] ?? .infinity
                let right = p50[$1] ?? .infinity
                return left == right ? $0 < $1 : left < right
            })
        } else {
            verdict = .winner(backend: leader.identity, over: comparisons[0])
        }

        return CohortDecision(
            cohort: cohort,
            ranking: ranking,
            excluded: excluded,
            absent: absent,
            verdict: verdict,
            comparisons: comparisons
        )
    }

    // MARK: Qwen3

    /// Precedence is deliberate and is the whole of R16.6's reading.
    ///
    /// A contested win or tie on either deciding cohort keeps Qwen3, and takes priority over a loss
    /// on the other — R16.6 asks whether Qwen3 wins *a* cohort, not every one. A measured loss comes
    /// next, because it is evidence. An uncontested lead comes last of the outcomes that saw data,
    /// because it is not.
    static func qwen3Verdict(
        cohorts: [CohortDecision],
        receipt: TranscriptionQualityReceipt
    ) -> Qwen3Verdict {
        let entries = receipt.backends(inFamily: qwen3BackendIdentifier)
        let language = entries.first?.languageConfiguration
        let identities = Set(entries.map(\.identity))
        let deciding = cohorts.filter { qwen3DecidingCohorts.contains($0.cohort) }

        func configuration() -> String {
            TranscriptionQualityLanguageConfiguration(rawValue: language ?? "automatic").description
        }

        // 1. A lead that was actually contested.
        for decision in deciding
            where decision.wasContested && decision.leaders.contains(where: identities.contains)
        {
            let alternative = bestAlternative(in: decision, excluding: identities)
            let against = alternative.map { "\($0.label) [\($0.identity)]" } ?? "no other faithful backend"
            let outcome = decision.leaders.count > 1 ? "ties for first with" : "wins outright over"
            return Qwen3Verdict(
                decision: .keep,
                cohort: decision.cohort,
                languageConfiguration: language,
                comparedAgainst: alternative?.identity,
                rationale: "Qwen3 \(outcome) \(against) on the \(decision.cohort.rawValue) cohort, "
                    + "running \(configuration())."
            )
        }

        // 2. Ranked but never first, or gated out: either way it lost, and the report has to say to
        // whom.
        for decision in deciding {
            let rankedOrExcluded = decision.ranking.contains { identities.contains($0.identity) }
                || decision.excluded.contains { identities.contains($0.identity) }
            guard rankedOrExcluded, !decision.leaders.contains(where: identities.contains) else { continue }
            let alternative = bestAlternative(in: decision, excluding: identities)
            let against = alternative.map { "\($0.label) [\($0.identity)]" } ?? "no faithful backend"
            let gated = decision.excluded.first { identities.contains($0.identity) }
            let why = gated.map { "it was excluded because \($0.reason)" }
                ?? "it did not lead the cohort"
            return Qwen3Verdict(
                decision: .drop,
                cohort: decision.cohort,
                languageConfiguration: language,
                comparedAgainst: alternative?.identity,
                rationale: "Qwen3 lost the \(decision.cohort.rawValue) cohort to \(against): \(why), "
                    + "running \(configuration())."
            )
        }

        // 3. It led, but nothing else passed the gate. Not a win — there was no field.
        for decision in deciding where decision.leaders.contains(where: identities.contains) {
            let gatedOut = decision.excluded.count
            let unmeasured = decision.absent.count
            return Qwen3Verdict(
                decision: .uncontested,
                cohort: decision.cohort,
                languageConfiguration: language,
                comparedAgainst: nil,
                rationale: "Qwen3 was the only backend to pass the faithfulness gate on the "
                    + "\(decision.cohort.rawValue) cohort — \(gatedOut) excluded, \(unmeasured) with "
                    + "no data — so it led an unopposed field, running \(configuration()). R16.6 keeps "
                    + "Qwen3 when it wins or ties for first against a comparable backend, and there "
                    + "was none; this run therefore does not settle the question."
            )
        }

        return Qwen3Verdict(
            decision: .undecided,
            cohort: nil,
            languageConfiguration: language,
            comparedAgainst: nil,
            rationale: "Qwen3 produced no measurement on either Arabic cohort, so this run decides nothing about it."
        )
    }

    /// The best-scoring eligible backend that is not Qwen3 — the thing R16.6 requires the verdict
    /// to name rather than leave implicit.
    private static func bestAlternative(
        in decision: CohortDecision,
        excluding identities: Set<String>
    ) -> Entry? {
        decision.ranking.first { !identities.contains($0.identity) }
    }

    static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

// MARK: - Paired bootstrap

/// The 95% interval R16.3 gates a winner on, resampled over utterances.
///
/// Paired because the two backends transcribed the *same* utterances: resampling utterance indices
/// once and reading both backends at those indices removes the corpus's own difficulty variation
/// from the comparison, which is what makes a small accuracy gap decidable at all on a few hundred
/// samples.
public enum TranscriptionQualityBootstrap {
    public static func compare(
        leader: String,
        leaderUtterances: [TranscriptionQualityReceipt.Utterance],
        challenger: String,
        challengerUtterances: [TranscriptionQualityReceipt.Utterance],
        thresholds: TranscriptionQualityReceipt.Thresholds
    ) -> TranscriptionQualityDecision.Comparison {
        let paired = pairedCounts(leader: leaderUtterances, challenger: challengerUtterances)

        func comparison(
            margin: Double,
            lowerBound: Double?,
            upperBound: Double?
        ) -> TranscriptionQualityDecision.Comparison {
            TranscriptionQualityDecision.Comparison(
                leader: leader,
                challenger: challenger,
                margin: margin,
                lowerBound: lowerBound,
                upperBound: upperBound,
                pairedUtterances: paired.count,
                leaderUtterances: leaderUtterances.count,
                challengerUtterances: challengerUtterances.count
            )
        }

        guard !paired.isEmpty else {
            // Nothing was measured on both backends, so no advantage can be established. Absent
            // bounds read, correctly, as "no interval" rather than as a zero-width one around zero.
            return comparison(margin: 0, lowerBound: nil, upperBound: nil)
        }

        var observed = Totals()
        for pair in paired { observed.add(pair) }

        // A decoded receipt can carry any threshold set, zero resamples included. Indexing the
        // empty margin array used to trap here and take report generation with it; the observed
        // margin is still data, so it is reported without an interval rather than not at all.
        guard thresholds.canResample else {
            return comparison(margin: observed.margin, lowerBound: nil, upperBound: nil)
        }

        var generator = SplitMix64(seed: thresholds.bootstrapSeed)
        var resampledMargins: [Double] = []
        resampledMargins.reserveCapacity(thresholds.bootstrapResamples)
        for _ in 0 ..< thresholds.bootstrapResamples {
            var replicate = Totals()
            for _ in paired.indices {
                replicate.add(paired[generator.index(below: paired.count)])
            }
            resampledMargins.append(replicate.margin)
        }
        resampledMargins.sort()

        let alpha = (1 - thresholds.confidenceLevel) / 2
        let lower = TranscriptionQualityScoring.nearestRankIndex(
            percentile: alpha,
            count: resampledMargins.count
        )
        let upper = TranscriptionQualityScoring.nearestRankIndex(
            percentile: 1 - alpha,
            count: resampledMargins.count
        )
        return comparison(
            margin: observed.margin,
            lowerBound: resampledMargins[lower],
            upperBound: resampledMargins[upper]
        )
    }

    /// One utterance as both backends measured it: normalized word-error distance and the reference
    /// length it is over, at `rawASR`.
    ///
    /// The pair, not the rate, is the resampling unit — a replicate has to be a pooled figure, or
    /// the interval would be about a statistic nobody is ranked on.
    struct PairedCounts: Equatable, Sendable {
        let leaderErrors: Int
        let leaderReferenceWords: Int
        let challengerErrors: Int
        let challengerReferenceWords: Int
    }

    /// Running totals of one replicate, or of the observed sample.
    private struct Totals {
        private var leaderErrors = 0
        private var leaderReferenceWords = 0
        private var challengerErrors = 0
        private var challengerReferenceWords = 0

        mutating func add(_ pair: PairedCounts) {
            leaderErrors += pair.leaderErrors
            leaderReferenceWords += pair.leaderReferenceWords
            challengerErrors += pair.challengerErrors
            challengerReferenceWords += pair.challengerReferenceWords
        }

        /// Pooled challenger WER minus pooled leader WER: positive means the leader is ahead.
        var margin: Double {
            TranscriptionQualityScoring.errorRate(
                errors: challengerErrors,
                referenceLength: challengerReferenceWords
            ) - TranscriptionQualityScoring.errorRate(
                errors: leaderErrors,
                referenceLength: leaderReferenceWords
            )
        }
    }

    /// The utterances both backends measured, paired by `(corpusID, sampleID)`. Utterances only one
    /// of them produced are dropped rather than treated as a win: an unpaired sample carries no
    /// information about the difference.
    ///
    /// The corpus is part of the key because sample ids are each corpus's own — `TranscriptionCorpusStore`
    /// copies `entry.id` verbatim and flattens every corpus into one list, so two corpora that both
    /// number their rows `0001` collide. Keyed on the id alone, every leader utterance with that id
    /// paired against a single challenger row from the *other* corpus, and the interval then measured
    /// the difference between two different utterances — the exact variation the pairing exists to
    /// remove, reintroduced as if it were signal.
    static func pairedCounts(
        leader: [TranscriptionQualityReceipt.Utterance],
        challenger: [TranscriptionQualityReceipt.Utterance]
    ) -> [PairedCounts] {
        let challengerByKey = Dictionary(
            challenger.map { ($0.pairingKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return leader.compactMap { utterance in
            guard let other = challengerByKey[utterance.pairingKey] else { return nil }
            return PairedCounts(
                leaderErrors: utterance.rawASR.normalizedWordErrors,
                leaderReferenceWords: utterance.rawASR.normalizedReferenceWords,
                challengerErrors: other.rawASR.normalizedWordErrors,
                challengerReferenceWords: other.rawASR.normalizedReferenceWords
            )
        }
    }
}

/// SplitMix64, written out rather than taken from the standard library because the interval has to
/// reproduce from the recorded seed across Swift versions, and `SystemRandomNumberGenerator` and
/// `Int.random(in:using:)` both make no such promise.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Modulo rather than `Int.random(in:using:)`: the small bias over a few hundred utterances is
    /// irrelevant, and pinning the mapping is what keeps the interval reproducible.
    mutating func index(below count: Int) -> Int {
        Int(next() % UInt64(count))
    }
}
