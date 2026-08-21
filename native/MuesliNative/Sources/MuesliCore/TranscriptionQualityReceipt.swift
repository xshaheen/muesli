import Foundation

// MARK: - Receipt

/// Schema v2 of the transcription quality run receipt: everything a later reader needs to know
/// what was measured, on what, and how it scored — and nothing else.
///
/// R2 draws the line: derived scores, identities, hashes and provenance are committed; audio and
/// transcript text never are. Nothing in this schema is a `String` that could hold a hypothesis or
/// a reference, which is why the type carries per-utterance *rates* rather than per-utterance
/// output. `TranscriptionQualityReceiptTests` asserts that property directly against the encoded
/// bytes, so a field added here that carries text fails the suite rather than leaking quietly.
///
/// v2 is a separate schema in a separate fixture directory (KTD3, R15). The v1 baseline under
/// `Fixtures/TranscriptionQuality/` is frozen and its contract test asserts exact set equality over
/// its own directory; nothing here may be written beside it.
public struct TranscriptionQualityReceipt: Codable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    /// Distinguishes two receipts taken from the same host on the same corpora.
    public let runID: String
    /// ISO-8601, as text rather than a `Date`, so the committed JSON does not depend on whichever
    /// date encoding strategy the writer happened to configure.
    public let generatedAt: String
    public let host: Host
    public let corpora: [Corpus]
    public let thresholds: Thresholds
    public let disclosures: Disclosures
    public let backends: [Backend]

    public init(
        runID: String,
        generatedAt: String,
        host: Host,
        corpora: [Corpus],
        thresholds: Thresholds = Thresholds(),
        disclosures: Disclosures,
        backends: [Backend]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.generatedAt = generatedAt
        self.host = host
        self.corpora = corpora
        self.thresholds = thresholds
        self.disclosures = disclosures
        self.backends = backends
    }
}

public extension TranscriptionQualityReceipt {
    /// What the sweep ran on. Latency figures are meaningless without it: the same backend on a
    /// different chip is a different measurement, not a regression.
    struct Host: Codable, Sendable, Equatable {
        public let operatingSystemVersion: String
        public let machineModel: String
        public let architecture: String
        public let processorCount: Int
        public let physicalMemoryBytes: UInt64

        public init(
            operatingSystemVersion: String,
            machineModel: String,
            architecture: String,
            processorCount: Int,
            physicalMemoryBytes: UInt64
        ) {
            self.operatingSystemVersion = operatingSystemVersion
            self.machineModel = machineModel
            self.architecture = architecture
            self.processorCount = processorCount
            self.physicalMemoryBytes = physicalMemoryBytes
        }

        public static func current(
            processInfo: ProcessInfo = .processInfo
        ) -> Host {
            let version = processInfo.operatingSystemVersion
            return Host(
                operatingSystemVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                machineModel: sysctlString("hw.model") ?? "unknown",
                architecture: sysctlString("machdep.cpu.brand_string") ?? "unknown",
                processorCount: processInfo.processorCount,
                physicalMemoryBytes: processInfo.physicalMemory
            )
        }

        private static func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(cString: buffer)
        }
    }

    /// R3's corpus identity, copied into the receipt so a score stays interpretable after the local
    /// store it came from has been re-downloaded, re-cut, or deleted.
    struct Corpus: Codable, Sendable, Equatable {
        public let id: String
        public let revision: String
        public let licenceIdentifier: String
        public let acquisition: String
        public let cohorts: [TranscriptionQuality.Cohort]
        public let sampleCount: Int
        /// Rows the store refused. A corpus that lost most of its index produces a real but very
        /// narrow number, and the reader has to be able to see that from the receipt alone.
        public let issueCount: Int

        public init(
            id: String,
            revision: String,
            licenceIdentifier: String,
            acquisition: String,
            cohorts: [TranscriptionQuality.Cohort],
            sampleCount: Int,
            issueCount: Int
        ) {
            self.id = id
            self.revision = revision
            self.licenceIdentifier = licenceIdentifier
            self.acquisition = acquisition
            self.cohorts = cohorts
            self.sampleCount = sampleCount
            self.issueCount = issueCount
        }
    }

    /// The policy constants the verdict was reached under, recorded so a later run scored against
    /// different ones is not silently compared against this one (R16).
    struct Thresholds: Codable, Sendable, Equatable {
        public let faithfulnessGate: Double
        public let confidenceLevel: Double
        public let bootstrapResamples: Int
        /// A paired bootstrap needs randomness; recording its seed is what makes the interval a
        /// function of the receipt rather than of the moment it was scored.
        public let bootstrapSeed: UInt64

        public static let defaultConfidenceLevel = 0.95
        public static let defaultResamples = 1_000
        public static let defaultSeed: UInt64 = 0x4D55_4553_4C49_0002

        public init(
            faithfulnessGate: Double = TranscriptionQuality.Threshold.faithfulnessGate,
            confidenceLevel: Double = Thresholds.defaultConfidenceLevel,
            bootstrapResamples: Int = Thresholds.defaultResamples,
            bootstrapSeed: UInt64 = Thresholds.defaultSeed
        ) {
            self.faithfulnessGate = faithfulnessGate
            self.confidenceLevel = confidenceLevel
            self.bootstrapResamples = bootstrapResamples
            self.bootstrapSeed = bootstrapSeed
        }
    }

    /// Judgement calls the sweep makes that a reader would otherwise have to find in the code.
    /// They are stated rather than hidden because each one shifts a number the report presents.
    struct Disclosures: Codable, Sendable, Equatable {
        /// Whether the cleanup stage ran. With it off, `finalOutput` is only artifact cleanup away
        /// from `rawASR` and the faithfulness delta this harness exists to catch cannot appear.
        public let cleanupEnabled: Bool
        /// The first sample of the sweep is transcribed once, as the cold start, and then not
        /// measured again. Every backend loses the same sample, so the comparison stays fair, but
        /// each cohort figure rests on one fewer utterance than the corpus holds.
        public let warmupSampleConsumed: Bool
        /// ASR weights are unloaded between backends (R11), but the cleanup LLM stays resident for
        /// the whole sweep. Latency figures therefore include a machine that is already holding one
        /// model, which is the steady state a user is in — but it is not a clean-machine number.
        public let cleanupModelResidentAcrossSweep: Bool
        /// The ranking statistic is the unweighted mean of per-utterance normalized WER, not a
        /// pooled error rate, because the receipt carries no transcript text and therefore no
        /// reference lengths to weight by. A one-word utterance counts as much as a long one.
        public let statisticIsMeanOfPerUtteranceRates: Bool
        /// Anything else the maintainer of this particular run needs to say.
        public let notes: [String]

        public init(
            cleanupEnabled: Bool,
            warmupSampleConsumed: Bool = true,
            cleanupModelResidentAcrossSweep: Bool = true,
            statisticIsMeanOfPerUtteranceRates: Bool = true,
            notes: [String] = []
        ) {
            self.cleanupEnabled = cleanupEnabled
            self.warmupSampleConsumed = warmupSampleConsumed
            self.cleanupModelResidentAcrossSweep = cleanupModelResidentAcrossSweep
            self.statisticIsMeanOfPerUtteranceRates = statisticIsMeanOfPerUtteranceRates
            self.notes = notes
        }
    }

    /// One measured stage of one utterance. Rates only — the text that produced them is scored and
    /// discarded before it reaches this type (R2).
    struct StageSummary: Codable, Sendable, Equatable {
        public let rawWER: Double
        public let rawCER: Double
        public let normalizedWER: Double
        public let normalizedCER: Double
        public let faithfulness: Double
        /// AE5b: the hypothesis changed script, so the error rate is an upper bound rather than a
        /// recognition result. Carried per utterance so the report can qualify the cohort figure.
        public let scriptChangeInflatesErrorRate: Bool

        public init(
            rawWER: Double,
            rawCER: Double,
            normalizedWER: Double,
            normalizedCER: Double,
            faithfulness: Double,
            scriptChangeInflatesErrorRate: Bool
        ) {
            self.rawWER = rawWER
            self.rawCER = rawCER
            self.normalizedWER = normalizedWER
            self.normalizedCER = normalizedCER
            self.faithfulness = faithfulness
            self.scriptChangeInflatesErrorRate = scriptChangeInflatesErrorRate
        }

        public init(_ score: TranscriptionQuality.StageScore) {
            self.init(
                rawWER: score.raw.wer,
                rawCER: score.raw.cer,
                normalizedWER: score.normalized.wer,
                normalizedCER: score.normalized.cer,
                faithfulness: score.faithfulness,
                scriptChangeInflatesErrorRate: score.scriptChangeInflatesErrorRate
            )
        }
    }

    /// One utterance measured at both stages (R7). `sampleID` is what pairs this measurement with
    /// the same utterance under another backend, which is what makes the bootstrap *paired*.
    struct Utterance: Codable, Sendable, Equatable {
        public let sampleID: String
        public let corpusID: String
        public let rawASR: StageSummary
        public let finalOutput: StageSummary
        public let endToEndSeconds: Double
        public let speechRecognitionSeconds: Double
        /// `nil` when the audio's duration could not be read, which only costs the real-time factor.
        public let audioDurationSeconds: Double?

        public init(
            sampleID: String,
            corpusID: String,
            rawASR: StageSummary,
            finalOutput: StageSummary,
            endToEndSeconds: Double,
            speechRecognitionSeconds: Double,
            audioDurationSeconds: Double?
        ) {
            self.sampleID = sampleID
            self.corpusID = corpusID
            self.rawASR = rawASR
            self.finalOutput = finalOutput
            self.endToEndSeconds = endToEndSeconds
            self.speechRecognitionSeconds = speechRecognitionSeconds
            self.audioDurationSeconds = audioDurationSeconds
        }

        public subscript(stage: TranscriptionQuality.Stage) -> StageSummary {
            switch stage {
            case .rawASR: rawASR
            case .finalOutput: finalOutput
            }
        }
    }

    /// What one backend produced on one cohort. Never averaged across cohorts: a single headline
    /// figure hides exactly the cohort the user complains about.
    struct CohortResult: Codable, Sendable, Equatable {
        public let cohort: TranscriptionQuality.Cohort
        public let utterances: [Utterance]

        public init(cohort: TranscriptionQuality.Cohort, utterances: [Utterance]) {
            self.cohort = cohort
            self.utterances = utterances
        }

        public var sampleCount: Int { utterances.count }

        /// `nil` for an empty cohort. A mean over nothing is not zero, and a zero WER would rank a
        /// backend that measured nothing first.
        public func meanNormalizedWER(at stage: TranscriptionQuality.Stage) -> Double? {
            mean(utterances.map { $0[stage].normalizedWER })
        }

        public func meanRawWER(at stage: TranscriptionQuality.Stage) -> Double? {
            mean(utterances.map { $0[stage].rawWER })
        }

        public func meanNormalizedCER(at stage: TranscriptionQuality.Stage) -> Double? {
            mean(utterances.map { $0[stage].normalizedCER })
        }

        public func meanFaithfulness(at stage: TranscriptionQuality.Stage) -> Double? {
            mean(utterances.map { $0[stage].faithfulness })
        }

        /// How many utterances the script-change caveat applies to, so a cohort figure resting on
        /// inflated rates can be read as the upper bound it is.
        public func scriptChangedUtteranceCount(at stage: TranscriptionQuality.Stage) -> Int {
            utterances.filter { $0[stage].scriptChangeInflatesErrorRate }.count
        }

        public var endToEndLatency: TranscriptionQualityScoring.Distribution? {
            distribution(utterances.map(\.endToEndSeconds))
        }

        public var speechRecognitionLatency: TranscriptionQualityScoring.Distribution? {
            distribution(utterances.map(\.speechRecognitionSeconds))
        }

        /// Pooled over the cohort's audio rather than averaged per utterance, so a handful of very
        /// short clips cannot dominate the figure.
        public var realTimeFactor: Double? {
            let timed = utterances.filter { $0.audioDurationSeconds != nil }
            let audio = timed.reduce(0.0) { $0 + ($1.audioDurationSeconds ?? 0) }
            guard audio > 0 else { return nil }
            return timed.reduce(0.0) { $0 + $1.endToEndSeconds } / audio
        }

        private func mean(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        private func distribution(_ values: [Double]) -> TranscriptionQualityScoring.Distribution? {
            values.isEmpty ? nil : TranscriptionQualityScoring.Distribution(values: values)
        }
    }

    /// R9's separately-reported cold start.
    struct Warmup: Codable, Sendable, Equatable {
        public let sampleID: String
        /// `nil` when the warmup threw — the model still loaded, but there is no honest time.
        public let endToEndSeconds: Double?
        public let failureMessage: String?

        public init(sampleID: String, endToEndSeconds: Double?, failureMessage: String?) {
            self.sampleID = sampleID
            self.endToEndSeconds = endToEndSeconds
            self.failureMessage = failureMessage
        }
    }

    /// One backend's whole run. A backend that could not run is this same value with a reason and
    /// no cohorts (R12) — never a row of zeros, which would rank it first.
    struct Backend: Codable, Sendable, Equatable {
        public let backend: String
        public let model: String
        public let label: String
        /// R17. `automatic` where the backend detects the language, `pinned:<code>` where it cannot.
        public let languageConfiguration: String
        /// `nil` when the backend was measured.
        public let notRunnableReason: String?
        public let warmup: Warmup?
        public let cohorts: [CohortResult]
        /// Samples that threw, named so a backend with three bad files is distinguishable from a
        /// backend with three fewer samples.
        public let failedSampleIDs: [String]

        public init(
            backend: String,
            model: String,
            label: String,
            languageConfiguration: String,
            notRunnableReason: String? = nil,
            warmup: Warmup? = nil,
            cohorts: [CohortResult] = [],
            failedSampleIDs: [String] = []
        ) {
            self.backend = backend
            self.model = model
            self.label = label
            self.languageConfiguration = languageConfiguration
            self.notRunnableReason = notRunnableReason
            self.warmup = warmup
            self.cohorts = cohorts
            self.failedSampleIDs = failedSampleIDs
        }

        public var isRunnable: Bool { notRunnableReason == nil }

        public func result(for cohort: TranscriptionQuality.Cohort) -> CohortResult? {
            cohorts.first { $0.cohort == cohort }
        }

        public var language: TranscriptionQualityLanguageConfiguration {
            TranscriptionQualityLanguageConfiguration(rawValue: languageConfiguration)
        }
    }

    /// Cohorts any backend produced data for, in canonical order.
    var measuredCohorts: [TranscriptionQuality.Cohort] {
        TranscriptionQuality.Cohort.allCases.filter { cohort in
            backends.contains { ($0.result(for: cohort)?.sampleCount ?? 0) > 0 }
        }
    }

    func backend(named backend: String) -> Backend? {
        backends.first { $0.backend == backend }
    }
}

// MARK: - Language configuration

/// What language a backend was actually decoding in (R17, KTD5).
///
/// Parsed from the string the sweep recorded rather than re-derived, so the report can never
/// disagree with the receipt about what ran.
public enum TranscriptionQualityLanguageConfiguration: Sendable, Equatable {
    case automatic
    case pinned(String)

    public init(rawValue: String) {
        let prefix = "pinned:"
        guard rawValue.hasPrefix(prefix) else {
            self = .automatic
            return
        }
        self = .pinned(String(rawValue.dropFirst(prefix.count)))
    }

    public var description: String {
        switch self {
        case .automatic: "automatic"
        case let .pinned(code): "pinned \(code)"
        }
    }

    /// Whether this configuration can even attempt the cohort's language.
    ///
    /// A pinned single language cannot cover a code-switching cohort at all, and a model pinned to
    /// the wrong language was never given the chance to recognise the right one. Saying so is the
    /// whole point of R17: a pinned-English model must not be presented as having *failed* to
    /// recognise Arabic when it was never asked to.
    public func canTarget(_ cohort: TranscriptionQuality.Cohort) -> Bool {
        switch self {
        case .automatic:
            return true
        case let .pinned(code):
            switch cohort {
            case .english: return code.hasPrefix("en")
            case .egyptianArabic: return code.hasPrefix("ar")
            case .arabicEnglish: return false
            }
        }
    }
}

// MARK: - Decision policy

/// R16's winner selection: a pure, deterministic function of a receipt (KTD10).
///
/// Nothing here consults the clock, the environment, or a system RNG. Given the same receipt it
/// returns the same verdict, which is what makes the report reproducible rather than an opinion.
public enum TranscriptionQualityDecision {
    /// A backend that is in the running for a cohort.
    public struct Entry: Sendable, Equatable {
        public let backend: String
        public let label: String
        public let languageConfiguration: String
        public let sampleCount: Int
        public let normalizedWER: Double
        public let finalOutputNormalizedWER: Double?
        public let faithfulness: Double
        public let finalOutputFaithfulness: Double?
        public let p50Seconds: Double?
        public let p95Seconds: Double?
        public let realTimeFactor: Double?
        /// R17's mark. `false` means the backend could not select this cohort's language, so its
        /// position is a statement about a configuration, not about the model's ability.
        public let canSelectCohortLanguage: Bool
    }

    /// A backend the faithfulness gate removed, kept in the report with its reason (AE10).
    public struct Exclusion: Sendable, Equatable {
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

    /// A backend with no data for this cohort. Listed apart from the ranking because R16.5 forbids
    /// ranking it last: not measured is not the same as measured badly.
    public struct Absent: Sendable, Equatable {
        public let backend: String
        public let label: String
        public let reason: String
    }

    /// The paired bootstrap's answer about two backends on one cohort.
    public struct Comparison: Sendable, Equatable {
        public let leader: String
        public let challenger: String
        /// Mean of (challenger − leader) normalized WER over the utterances both measured.
        /// Positive means the leader is ahead.
        public let margin: Double
        public let lowerBound: Double
        public let upperBound: Double
        public let pairedUtterances: Int

        /// The leader's advantage clears the interval, so the ordering is not resampling noise.
        public var isSignificant: Bool { lowerBound > 0 }
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
        /// Eligible backends, ascending normalized WER at `rawASR`.
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

        /// Backends that are first-equal: the outright winner, or every member of the tie.
        public var leaders: [String] {
            switch verdict {
            case let .winner(backend, _): [backend]
            case let .soleEligible(backend): [backend]
            case let .tie(backends): backends
            case .noEligibleBackend: []
            }
        }
    }

    /// R16.6's verdict on the backend this whole exercise was commissioned to settle.
    public struct Qwen3Verdict: Sendable, Equatable {
        public enum Decision: String, Sendable {
            case keep
            case drop
            /// Qwen3 produced no data on either Arabic cohort, so there is nothing to decide on.
            case undecided
        }

        public let decision: Decision
        /// The cohort that carried the decision, when one did.
        public let cohort: TranscriptionQuality.Cohort?
        /// KTD5: the verdict holds only for the configuration Qwen3 actually ran under.
        public let languageConfiguration: String?
        /// The backend it was measured against, named so "Qwen3 loses" is never an unattributed
        /// claim.
        public let comparedAgainst: String?
        public let rationale: String
    }

    public struct Report: Sendable, Equatable {
        public let cohorts: [CohortDecision]
        public let qwen3: Qwen3Verdict
    }

    /// The backend identifier the Qwen3 verdict is about, as `BackendOption.backend` spells it.
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
        var utterancesByBackend: [String: [TranscriptionQualityReceipt.Utterance]] = [:]

        for backend in receipt.backends {
            let canTarget = backend.language.canTarget(cohort)
            // R16.5, AE11: not-runnable and no-data are the same thing to a ranking — absent. A
            // backend that never produced a number must not be given the worst one.
            guard backend.isRunnable else {
                absent.append(Absent(
                    backend: backend.backend,
                    label: backend.label,
                    reason: backend.notRunnableReason ?? "not runnable"
                ))
                continue
            }
            guard let result = backend.result(for: cohort), result.sampleCount > 0,
                  let normalizedWER = result.meanNormalizedWER(at: .rawASR),
                  let faithfulness = result.meanFaithfulness(at: .rawASR)
            else {
                absent.append(Absent(
                    backend: backend.backend,
                    label: backend.label,
                    reason: "no measured samples in this cohort"
                ))
                continue
            }

            // R16.1, KTD10: the gate is applied before any error rate is compared, because the two
            // are not commensurable — no WER advantage buys back a language change.
            guard faithfulness >= receipt.thresholds.faithfulnessGate else {
                excluded.append(Exclusion(
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
            utterancesByBackend[backend.backend] = result.utterances
            ranking.append(Entry(
                backend: backend.backend,
                label: backend.label,
                languageConfiguration: backend.languageConfiguration,
                sampleCount: result.sampleCount,
                normalizedWER: normalizedWER,
                finalOutputNormalizedWER: result.meanNormalizedWER(at: .finalOutput),
                faithfulness: faithfulness,
                finalOutputFaithfulness: result.meanFaithfulness(at: .finalOutput),
                p50Seconds: latency?.p50,
                p95Seconds: latency?.p95,
                realTimeFactor: result.realTimeFactor,
                canSelectCohortLanguage: canTarget
            ))
        }

        // R16.2. The tiebreak on backend identifier is not a preference; it stops the order of the
        // inventory from deciding which of two identical scores is called the leader.
        ranking.sort {
            $0.normalizedWER == $1.normalizedWER
                ? $0.backend < $1.backend
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
                verdict: .soleEligible(backend: leader.backend),
                comparisons: []
            )
        }

        let comparisons = ranking.dropFirst().map { challenger in
            TranscriptionQualityBootstrap.compare(
                leader: leader.backend,
                leaderUtterances: utterancesByBackend[leader.backend] ?? [],
                challenger: challenger.backend,
                challengerUtterances: utterancesByBackend[challenger.backend] ?? [],
                thresholds: receipt.thresholds
            )
        }

        // R16.3, R16.4. Every challenger the leader cannot separate itself from joins the tie, not
        // only the runner-up: reporting a two-way tie while a third backend sits inside the same
        // interval would be a winner claim by omission.
        var tied = [leader.backend]
        for comparison in comparisons where !comparison.isSignificant {
            tied.append(comparison.challenger)
        }

        let verdict: Verdict
        if tied.count > 1 {
            // A backend with no latency figure sorts last rather than first: an unmeasured p50 is
            // not a fast one.
            let p50 = Dictionary(uniqueKeysWithValues: ranking.map {
                ($0.backend, $0.p50Seconds ?? .infinity)
            })
            // R16.4: fastest first among equals, since latency is the only thing left to separate
            // backends the accuracy interval could not.
            verdict = .tie(backends: tied.sorted {
                let left = p50[$0] ?? .infinity
                let right = p50[$1] ?? .infinity
                return left == right ? $0 < $1 : left < right
            })
        } else {
            verdict = .winner(backend: leader.backend, over: comparisons[0])
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

    static func qwen3Verdict(
        cohorts: [CohortDecision],
        receipt: TranscriptionQualityReceipt
    ) -> Qwen3Verdict {
        let language = receipt.backend(named: qwen3BackendIdentifier)?.languageConfiguration
        let deciding = cohorts.filter { qwen3DecidingCohorts.contains($0.cohort) }

        for decision in deciding where decision.leaders.contains(qwen3BackendIdentifier) {
            let alternative = bestAlternative(in: decision)
            let against = alternative.map { "\($0.label) [\($0.backend)]" } ?? "no other faithful backend"
            let outcome = decision.leaders.count > 1 ? "ties for first with" : "wins outright over"
            return Qwen3Verdict(
                decision: .keep,
                cohort: decision.cohort,
                languageConfiguration: language,
                comparedAgainst: alternative?.backend,
                rationale: "Qwen3 \(outcome) \(against) on the \(decision.cohort.rawValue) cohort, "
                    + "running \(TranscriptionQualityLanguageConfiguration(rawValue: language ?? "automatic").description)."
            )
        }

        // Ranked but never first, or gated out: either way it lost, and the report has to say to whom.
        for decision in deciding {
            let rankedOrExcluded = decision.ranking.contains { $0.backend == qwen3BackendIdentifier }
                || decision.excluded.contains { $0.backend == qwen3BackendIdentifier }
            guard rankedOrExcluded else { continue }
            let alternative = bestAlternative(in: decision)
            let against = alternative.map { "\($0.label) [\($0.backend)]" } ?? "no faithful backend"
            let gated = decision.excluded.first { $0.backend == qwen3BackendIdentifier }
            let why = gated.map { "it was excluded because \($0.reason)" }
                ?? "it did not lead the cohort"
            return Qwen3Verdict(
                decision: .drop,
                cohort: decision.cohort,
                languageConfiguration: language,
                comparedAgainst: alternative?.backend,
                rationale: "Qwen3 lost the \(decision.cohort.rawValue) cohort to \(against): \(why), "
                    + "running \(TranscriptionQualityLanguageConfiguration(rawValue: language ?? "automatic").description)."
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
    private static func bestAlternative(in decision: CohortDecision) -> Entry? {
        decision.ranking.first { $0.backend != qwen3BackendIdentifier }
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
        let deltas = pairedDeltas(leader: leaderUtterances, challenger: challengerUtterances)
        guard !deltas.isEmpty else {
            // Nothing was measured on both backends, so no advantage can be established. Returning
            // a zero-width interval around zero reads, correctly, as "not significant".
            return TranscriptionQualityDecision.Comparison(
                leader: leader,
                challenger: challenger,
                margin: 0,
                lowerBound: 0,
                upperBound: 0,
                pairedUtterances: 0
            )
        }

        var generator = SplitMix64(seed: thresholds.bootstrapSeed)
        var resampledMeans: [Double] = []
        resampledMeans.reserveCapacity(thresholds.bootstrapResamples)
        for _ in 0 ..< thresholds.bootstrapResamples {
            var total = 0.0
            for _ in deltas.indices {
                total += deltas[generator.index(below: deltas.count)]
            }
            resampledMeans.append(total / Double(deltas.count))
        }
        resampledMeans.sort()

        let alpha = (1 - thresholds.confidenceLevel) / 2
        let lower = TranscriptionQualityScoring.nearestRankIndex(
            percentile: alpha,
            count: resampledMeans.count
        )
        let upper = TranscriptionQualityScoring.nearestRankIndex(
            percentile: 1 - alpha,
            count: resampledMeans.count
        )
        return TranscriptionQualityDecision.Comparison(
            leader: leader,
            challenger: challenger,
            margin: deltas.reduce(0, +) / Double(deltas.count),
            lowerBound: resampledMeans[lower],
            upperBound: resampledMeans[upper],
            pairedUtterances: deltas.count
        )
    }

    /// Per-utterance (challenger − leader) normalized WER at `rawASR`, over utterances both
    /// backends measured. Utterances only one of them produced are dropped rather than treated as
    /// a win: an unpaired sample carries no information about the difference.
    static func pairedDeltas(
        leader: [TranscriptionQualityReceipt.Utterance],
        challenger: [TranscriptionQualityReceipt.Utterance]
    ) -> [Double] {
        let challengerByID = Dictionary(
            challenger.map { ($0.sampleID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return leader.compactMap { utterance in
            guard let other = challengerByID[utterance.sampleID] else { return nil }
            return other.rawASR.normalizedWER - utterance.rawASR.normalizedWER
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

// MARK: - Report

/// R13's comparison report, rendered from a receipt and its decisions.
///
/// Rendering rather than writing is the point: every number and every verdict in the output is
/// already in the receipt or is the deterministic output of `TranscriptionQualityDecision`, so the
/// document cannot drift from the measurement or quietly acquire a reviewer's opinion.
public enum TranscriptionQualityReport {
    public static func markdown(for receipt: TranscriptionQualityReceipt) -> String {
        markdown(for: receipt, decisions: TranscriptionQualityDecision.evaluate(receipt))
    }

    public static func markdown(
        for receipt: TranscriptionQualityReceipt,
        decisions: TranscriptionQualityDecision.Report
    ) -> String {
        var lines: [String] = ["# Transcription quality run \(receipt.runID)", ""]
        lines += provenance(receipt)
        lines += corpora(receipt)
        lines += policy(receipt)
        lines += disclosures(receipt)
        for cohort in decisions.cohorts {
            lines += cohortSection(cohort, receipt: receipt)
        }
        lines += notRunnableSection(receipt)
        lines += qwen3Section(decisions.qwen3)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Sections

    private static func provenance(_ receipt: TranscriptionQualityReceipt) -> [String] {
        [
            "Schema v\(receipt.schemaVersion), generated \(receipt.generatedAt).",
            "",
            "| Host | |",
            "| --- | --- |",
            "| macOS | \(receipt.host.operatingSystemVersion) |",
            "| Machine | \(receipt.host.machineModel) |",
            "| CPU | \(receipt.host.architecture) |",
            "| Cores | \(receipt.host.processorCount) |",
            "| Memory | \(gigabytes(receipt.host.physicalMemoryBytes)) |",
            "",
        ]
    }

    private static func corpora(_ receipt: TranscriptionQualityReceipt) -> [String] {
        var lines = ["## Corpora", ""]
        guard !receipt.corpora.isEmpty else {
            return lines + ["No corpus identity was recorded for this run.", ""]
        }
        lines += [
            "| Corpus | Revision | Licence | Acquired | Cohorts | Samples | Refused rows |",
            "| --- | --- | --- | --- | --- | ---: | ---: |",
        ]
        for corpus in receipt.corpora {
            let cohorts = corpus.cohorts.map(\.rawValue).joined(separator: ", ")
            lines.append(
                "| \(corpus.id) | \(corpus.revision) | \(corpus.licenceIdentifier) | "
                    + "\(corpus.acquisition) | \(cohorts) | \(corpus.sampleCount) | \(corpus.issueCount) |"
            )
        }
        return lines + [""]
    }

    private static func policy(_ receipt: TranscriptionQualityReceipt) -> [String] {
        let thresholds = receipt.thresholds
        return [
            "## Decision policy",
            "",
            "| Setting | Value |",
            "| --- | --- |",
            "| Faithfulness gate (raw ASR) | \(format(thresholds.faithfulnessGate)) |",
            "| Confidence level | \(percent(thresholds.confidenceLevel)) |",
            "| Paired bootstrap resamples | \(thresholds.bootstrapResamples) |",
            "| Bootstrap seed | \(thresholds.bootstrapSeed) |",
            "",
            "A run scored under different thresholds is not comparable to this one.",
            "",
        ]
    }

    private static func disclosures(_ receipt: TranscriptionQualityReceipt) -> [String] {
        let disclosures = receipt.disclosures
        var lines = ["## What this run did and did not control", ""]
        lines.append("- Cleanup stage: **\(disclosures.cleanupEnabled ? "enabled" : "disabled")**.")
        if disclosures.warmupSampleConsumed {
            lines.append(
                "- The first sample is spent on the cold start and is **not** re-measured, so every "
                    + "cohort figure rests on one fewer utterance than the corpus holds. Every backend "
                    + "loses the same sample."
            )
        }
        if disclosures.cleanupModelResidentAcrossSweep {
            lines.append(
                "- ASR weights are unloaded between backends, but the cleanup LLM stays resident for "
                    + "the whole sweep. Latency below is a machine already holding one model."
            )
        }
        if disclosures.statisticIsMeanOfPerUtteranceRates {
            lines.append(
                "- The ranking statistic is the unweighted mean of per-utterance normalized WER. "
                    + "A one-word utterance counts as much as a long one."
            )
        }
        lines += disclosures.notes.map { "- \($0)" }
        return lines + [""]
    }

    private static func cohortSection(
        _ decision: TranscriptionQualityDecision.CohortDecision,
        receipt: TranscriptionQualityReceipt
    ) -> [String] {
        var lines = ["## Cohort: \(decision.cohort.rawValue)", "", verdictLine(decision), ""]
        if !decision.ranking.isEmpty {
            lines += [
                "| # | Backend | Language | n | WER raw ASR | WER final | Faithfulness raw | "
                    + "Faithfulness final | p50 s | p95 s | RTF |",
                "| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
            ]
            for (index, entry) in decision.ranking.enumerated() {
                let language = TranscriptionQualityLanguageConfiguration(rawValue: entry.languageConfiguration)
                // R17: the mark travels with the row, so a pinned model's position is never read as
                // a statement about what it can recognise.
                let mark = entry.canSelectCohortLanguage ? "" : " ⚠︎"
                lines.append(
                    "| \(index + 1) | \(entry.label) | \(language.description)\(mark) | \(entry.sampleCount) "
                        + "| \(format(entry.normalizedWER)) | \(format(entry.finalOutputNormalizedWER)) "
                        + "| \(format(entry.faithfulness)) | \(format(entry.finalOutputFaithfulness)) "
                        + "| \(format(entry.p50Seconds, places: 2)) | \(format(entry.p95Seconds, places: 2)) "
                        + "| \(format(entry.realTimeFactor, places: 2)) |"
                )
            }
            lines.append("")
            if decision.ranking.contains(where: { !$0.canSelectCohortLanguage }) {
                lines += [
                    "⚠︎ This backend could not select this cohort's language. Its position reflects the "
                        + "language it was pinned to, not a failure to recognise the one that was spoken.",
                    "",
                ]
            }
        } else {
            lines += ["No backend passed the faithfulness gate on this cohort.", ""]
        }

        if !decision.excluded.isEmpty {
            lines += [
                "**Excluded by the faithfulness gate.** A backend below the gate did not keep the "
                    + "spoken language; no error rate buys that back.",
                "",
                "| Backend | WER raw ASR | Faithfulness raw | Reason |",
                "| --- | ---: | ---: | --- |",
            ]
            for exclusion in decision.excluded {
                lines.append(
                    "| \(exclusion.label) | \(format(exclusion.normalizedWER)) "
                        + "| \(format(exclusion.faithfulness)) | \(exclusion.reason) |"
                )
            }
            lines.append("")
        }

        if !decision.absent.isEmpty {
            lines += [
                "**Not ranked — no data on this cohort.** Absent from the ranking rather than last.",
                "",
            ]
            lines += decision.absent.map { "- \($0.label): \($0.reason)" }
            lines.append("")
        }

        if !decision.comparisons.isEmpty {
            lines += [
                "<details><summary>Paired bootstrap against the leader</summary>",
                "",
                "| Challenger | Margin | \(percent(receipt.thresholds.confidenceLevel)) interval | Paired n | Separated |",
                "| --- | ---: | --- | ---: | --- |",
            ]
            for comparison in decision.comparisons {
                lines.append(
                    "| \(comparison.challenger) | \(format(comparison.margin)) "
                        + "| [\(format(comparison.lowerBound)), \(format(comparison.upperBound))] "
                        + "| \(comparison.pairedUtterances) | \(comparison.isSignificant ? "yes" : "no") |"
                )
            }
            lines += ["", "</details>", ""]
        }
        return lines
    }

    private static func verdictLine(_ decision: TranscriptionQualityDecision.CohortDecision) -> String {
        switch decision.verdict {
        case let .winner(backend, comparison):
            let label = decision.ranking.first { $0.backend == backend }?.label ?? backend
            return "**Winner: \(label)** — ahead of `\(comparison.challenger)` by "
                + "\(format(comparison.margin)) normalized WER "
                + "(interval [\(format(comparison.lowerBound)), \(format(comparison.upperBound))], "
                + "\(comparison.pairedUtterances) paired utterances)."
        case let .soleEligible(backend):
            let label = decision.ranking.first { $0.backend == backend }?.label ?? backend
            return "**Sole eligible backend: \(label)** — it is the only one that passed the "
                + "faithfulness gate, so there was no contest to win."
        case let .tie(backends):
            let labels = backends.map { identifier in
                decision.ranking.first { $0.backend == identifier }?.label ?? identifier
            }
            return "**Tie: \(labels.joined(separator: ", "))** — the differences sit inside the "
                + "paired bootstrap interval, so no winner is claimed. Listed fastest first."
        case .noEligibleBackend:
            return "**No winner** — no backend passed the faithfulness gate on this cohort."
        }
    }

    private static func notRunnableSection(_ receipt: TranscriptionQualityReceipt) -> [String] {
        let unrunnable = receipt.backends.filter { !$0.isRunnable }
        guard !unrunnable.isEmpty else { return [] }
        var lines = [
            "## Not runnable on this host",
            "",
            "| Backend | Model | Reason |",
            "| --- | --- | --- |",
        ]
        for backend in unrunnable {
            lines.append(
                "| \(backend.label) | \(backend.model) | \(backend.notRunnableReason ?? "unknown") |"
            )
        }
        return lines + [""]
    }

    private static func qwen3Section(_ verdict: TranscriptionQualityDecision.Qwen3Verdict) -> [String] {
        [
            "## Qwen3 verdict: \(verdict.decision.rawValue)",
            "",
            verdict.rationale,
            "",
        ]
    }

    // MARK: Formatting

    /// `n/a` rather than `0` for an absent figure. A zero WER and an unmeasured WER read identically
    /// in a table, and only one of them is a result.
    private static func format(_ value: Double?, places: Int = 3) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.\(places)f", value)
    }

    private static func format(_ value: Double, places: Int = 3) -> String {
        String(format: "%.\(places)f", value)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.0f GB", Double(bytes) / 1_073_741_824)
    }
}
