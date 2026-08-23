import Foundation

// MARK: - Receipt

/// Schema v2 of the transcription quality run receipt: everything a later reader needs to know
/// what was measured, on what, and how it scored — and nothing else.
///
/// R2 draws the line: derived scores, identities, hashes and provenance are committed; audio and
/// transcript text never are. Nothing in this schema is a `String` that could hold a hypothesis or
/// a reference, which is why the type carries per-utterance *rates* rather than per-utterance
/// output. `TranscriptionQualityReceiptTests` asserts that property directly against the encoded
/// bytes — over keys *and* over values — so a field added here that carries text fails the suite
/// rather than leaking quietly.
///
/// The two ways a string reaches this schema are kept apart deliberately. Identities (`runID`,
/// `sampleID`, `corpusID`, backend and model names) are chosen by the maintainer or by the shipped
/// inventory and are never derived from what was said. Everything else is either a closed
/// vocabulary — `NotRunnable.Code`, `Cohort`, `Acquisition` — or passes through `ReceiptProse`,
/// which drops every non-ASCII scalar and caps the length, so no reference in Arabic script can
/// survive it at all and no English one can survive intact.
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

// MARK: - Prose

/// A short line of free-form prose on its way into a committed receipt.
///
/// R2's rule is about reference and hypothesis text, and the two fields that cannot be reduced to a
/// closed vocabulary — a thrown error's description, and a maintainer's run note — are the only
/// places arbitrary text can enter. They pass through here, which:
///
/// - drops every scalar outside printable ASCII, so Arabic, Chinese and every other non-Latin
///   reference in the corpora this harness targets cannot survive in any form;
/// - collapses runs of whitespace, so a pasted multi-line transcript becomes one line;
/// - caps the result at `maximumLength`, so what does survive is a fragment rather than a record.
///
/// It is a bound, not a proof: a short English sentence passes through it unchanged. That is why
/// every field which *is* derived from corpus content — the not-runnable reason, the cleanup
/// outcome, the cohort — is a code rather than prose, and why this type is reserved for the two
/// fields that are not.
public enum ReceiptProse {
    public static let maximumLength = 160

    public static func sanitized(_ text: String) -> String {
        let ascii = text.unicodeScalars.map { scalar -> Character in
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" { return " " }
            // Printable ASCII only. Everything else — every Arabic scalar included — becomes a space
            // rather than a substitution mark, so nothing reconstructible is left behind.
            return (0x21 ... 0x7E).contains(scalar.value) ? Character(scalar) : " "
        }
        let collapsed = String(ascii)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard collapsed.count > maximumLength else { return collapsed }
        return String(collapsed.prefix(maximumLength - 3)) + "..."
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

        /// Whether a paired bootstrap can produce an interval at all under these settings.
        ///
        /// Zero resamples is a decodable value — a receipt is data, not a constructor call — and it
        /// used to index into an empty array of margins and trap. A comparison made under it now
        /// reports no interval rather than crashing report generation.
        public var canResample: Bool { bootstrapResamples > 0 && confidenceLevel > 0 && confidenceLevel < 1 }
    }

    /// Why a backend produced no measurement, as a code rather than as rendered prose (R12).
    ///
    /// The reason used to be the sweep's own `description` string, and one of its cases joins the
    /// ids of every failed sample into that sentence. Sample ids are identities the schema already
    /// commits per utterance, but a rendered sentence is an open channel: whatever a future case
    /// interpolates lands in the committed artifact. Coding it closes the channel — the ids travel
    /// in `Backend.failedSampleIDs` where they are already allow-listed, and the prose is rendered
    /// by the report, at read time, from this code.
    struct NotRunnable: Codable, Sendable, Equatable {
        public enum Code: String, Codable, Sendable, CaseIterable {
            case requiresNewerMacOS = "requires-newer-macos"
            case modelNotDownloaded = "model-not-downloaded"
            case noSamples = "no-samples"
            case noMeasuredSamples = "no-measured-samples"
        }

        public let code: Code
        /// Only for `requiresNewerMacOS`.
        public let requiredMacOSMajorVersion: Int?
        /// Only for `requiresNewerMacOS`. Read off `ProcessInfo`, never off the corpus.
        public let hostOperatingSystemVersion: String?

        public init(
            code: Code,
            requiredMacOSMajorVersion: Int? = nil,
            hostOperatingSystemVersion: String? = nil
        ) {
            self.code = code
            self.requiredMacOSMajorVersion = requiredMacOSMajorVersion
            self.hostOperatingSystemVersion = hostOperatingSystemVersion
        }

        /// The sentence the report prints. Rendered here rather than stored, so the receipt holds
        /// the fact and the document holds the wording.
        ///
        /// `failures` carries the reasons as well as the ids: a backend that scored nothing is the
        /// one case where "which samples" is the least useful half of the answer, and a maintainer
        /// four hours into a sweep needs to know whether the model was missing, unloaded, or wedged.
        public func description(failures: [SampleFailure] = []) -> String {
            switch code {
            case .requiresNewerMacOS:
                let required = requiredMacOSMajorVersion.map(String.init) ?? "a newer major version"
                return "requires macOS \(required) or later; host is "
                    + (hostOperatingSystemVersion ?? "older")
            case .modelNotDownloaded:
                return "model is not downloaded, and the harness never downloads one"
            case .noSamples:
                return "the corpus store yielded no usable samples"
            case .noMeasuredSamples:
                guard !failures.isEmpty else {
                    return "the corpus held no sample beyond the one the cold start consumed"
                }
                let sentence = "every sample failed, so nothing was scored: "
                    + failures.map(\.sampleID).joined(separator: ", ")
                // One cause usually explains the whole backend, so the distinct reasons are named
                // once rather than repeated beside every id.
                let reasons = SampleFailure.distinctReasons(in: failures)
                guard !reasons.isEmpty else { return sentence }
                return sentence + " — " + reasons.joined(separator: "; ")
            }
        }
    }

    /// One sample that threw, with why.
    ///
    /// The id alone was what the schema used to keep, and it made an entirely failed backend
    /// undiagnosable: a missing file, an unloaded model, an unsupported sample rate and a decoder
    /// error all arrived as the same empty result. The message is the second of the two fields a
    /// caller does not compose — a thrown error's description — so it is bounded by `ReceiptProse`
    /// rather than trusted: an error can in principle quote the transcript it failed on.
    struct SampleFailure: Codable, Sendable, Equatable {
        public let sampleID: String
        public let reason: String

        public init(sampleID: String, reason: String) {
            self.sampleID = sampleID
            self.reason = ReceiptProse.sanitized(reason)
        }

        /// The reasons present, deduplicated, in first-seen order.
        public static func distinctReasons(in failures: [SampleFailure]) -> [String] {
            var seen: Set<String> = []
            return failures.map(\.reason).filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }

    /// How often the cleanup stage declined to run, and why.
    ///
    /// `reason` is the pipeline's own outcome vocabulary (`DictationCleanupOutcome`) as the sweep
    /// rendered it, not free text — but it is sanitized on the way in so a future outcome case
    /// cannot widen the channel.
    struct CleanupSkip: Codable, Sendable, Equatable {
        public let reason: String
        public let utterances: Int

        public init(reason: String, utterances: Int) {
            self.reason = ReceiptProse.sanitized(reason)
            self.utterances = utterances
        }
    }

    /// Judgement calls the sweep makes that a reader would otherwise have to find in the code.
    /// They are stated rather than hidden because each one shifts a number the report presents.
    struct Disclosures: Codable, Sendable, Equatable {
        /// Whether the run *asked* for the cleanup stage. On its own this says nothing about whether
        /// cleanup happened: `TranscriptionRuntime` skips it silently for an unloadable cleanup
        /// model, for the Indic backend, and for an empty transcript, and still returns a final
        /// text. Read `cleanupApplied` for what actually ran.
        public let cleanupRequested: Bool
        /// Utterances whose final stage is genuinely the cleanup stage's product.
        public let cleanupAppliedUtterances: Int
        /// Utterances where it is not, and why. A receipt with `cleanupRequested: true`, zero
        /// applied, and one entry here is a run that measured nothing about cleanup — which is the
        /// opposite of, and used to be indistinguishable from, "cleanup changed nothing".
        public let cleanupNotPerformed: [CleanupSkip]
        /// The first sample of the sweep is transcribed once, as the cold start, and then not
        /// measured again. Every backend loses the same sample, so the comparison stays fair, but
        /// each cohort figure rests on one fewer utterance than the corpus holds.
        public let warmupSampleConsumed: Bool
        /// ASR weights are unloaded between backends (R11), but the cleanup LLM stays resident for
        /// the whole sweep. Latency figures therefore include a machine that is already holding one
        /// model, which is the steady state a user is in — but it is not a clean-machine number.
        public let cleanupModelResidentAcrossSweep: Bool
        /// Anything else the maintainer of this particular run needs to say, bounded by
        /// `ReceiptProse` because it is one of the two fields a caller writes freehand.
        public let notes: [String]

        public init(
            cleanupRequested: Bool,
            cleanupAppliedUtterances: Int = 0,
            cleanupNotPerformed: [CleanupSkip] = [],
            warmupSampleConsumed: Bool = true,
            cleanupModelResidentAcrossSweep: Bool = true,
            notes: [String] = []
        ) {
            self.cleanupRequested = cleanupRequested
            self.cleanupAppliedUtterances = cleanupAppliedUtterances
            self.cleanupNotPerformed = cleanupNotPerformed
            self.warmupSampleConsumed = warmupSampleConsumed
            self.cleanupModelResidentAcrossSweep = cleanupModelResidentAcrossSweep
            self.notes = notes.map(ReceiptProse.sanitized)
        }

        /// Whether the cleanup stage produced any measurement at all in this run.
        public var cleanupApplied: Bool { cleanupAppliedUtterances > 0 }

        public var cleanupNotPerformedUtterances: Int {
            cleanupNotPerformed.reduce(0) { $0 + $1.utterances }
        }
    }

    /// One measured stage of one utterance. Rates and the integer counts behind them — the text that
    /// produced them is scored and discarded before it reaches this type (R2).
    ///
    /// The counts are what let a cohort figure be pooled from the receipt alone, and let a later
    /// reader recompute it (R5). A count of words or characters is derived from text, not text: it
    /// reconstructs nothing that was said. Raw and normalized carry separate denominators because
    /// Arabic folding can drop a diacritic-only token and always changes the character count.
    struct StageSummary: Codable, Sendable, Equatable {
        public let rawWER: Double
        public let rawCER: Double
        public let normalizedWER: Double
        public let normalizedCER: Double
        public let rawWordErrors: Int
        public let rawReferenceWords: Int
        public let rawCharacterErrors: Int
        public let rawReferenceCharacters: Int
        public let normalizedWordErrors: Int
        public let normalizedReferenceWords: Int
        public let normalizedCharacterErrors: Int
        public let normalizedReferenceCharacters: Int
        /// `nil` when the reference carries no script-bearing token, so the question of whether the
        /// spoken language was preserved was never asked. Not-applicable, never 1: a cohort of
        /// punctuation-only or digits-only references would otherwise average to a passing figure
        /// and clear the gate on nothing.
        public let faithfulness: Double?
        /// AE5b: the hypothesis changed script, so the error rate is an upper bound rather than a
        /// recognition result. Carried per utterance so the report can qualify the cohort figure.
        public let scriptChangeInflatesErrorRate: Bool

        public init(
            raw: TranscriptionQuality.ErrorRates,
            normalized: TranscriptionQuality.ErrorRates,
            faithfulness: Double?,
            scriptChangeInflatesErrorRate: Bool
        ) {
            rawWER = raw.wer
            rawCER = raw.cer
            normalizedWER = normalized.wer
            normalizedCER = normalized.cer
            rawWordErrors = raw.wordErrors
            rawReferenceWords = raw.referenceWords
            rawCharacterErrors = raw.characterErrors
            rawReferenceCharacters = raw.referenceCharacters
            normalizedWordErrors = normalized.wordErrors
            normalizedReferenceWords = normalized.referenceWords
            normalizedCharacterErrors = normalized.characterErrors
            normalizedReferenceCharacters = normalized.referenceCharacters
            self.faithfulness = faithfulness
            self.scriptChangeInflatesErrorRate = scriptChangeInflatesErrorRate
        }

        public init(_ score: TranscriptionQuality.StageScore) {
            self.init(
                raw: score.raw,
                normalized: score.normalized,
                faithfulness: score.faithfulness,
                scriptChangeInflatesErrorRate: score.scriptChangeInflatesErrorRate
            )
        }
    }

    /// One utterance measured at both stages (R7). `sampleID` together with `corpusID` is what pairs
    /// this measurement with the same utterance under another backend, which is what makes the
    /// bootstrap *paired*.
    struct Utterance: Codable, Sendable, Equatable {
        public let sampleID: String
        public let corpusID: String
        public let rawASR: StageSummary
        /// `nil` when the cleanup stage did not run for this utterance — the pipeline still returned
        /// a text, but it is not that stage's product, and scoring it as one is how a sweep reports
        /// "cleanup changed nothing" for a run in which cleanup never ran.
        public let finalOutput: StageSummary?
        public let endToEndSeconds: Double
        public let speechRecognitionSeconds: Double
        /// `nil` when the audio's duration could not be read, which only costs the real-time factor.
        public let audioDurationSeconds: Double?

        public init(
            sampleID: String,
            corpusID: String,
            rawASR: StageSummary,
            finalOutput: StageSummary?,
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

        /// Identity across backends. Sample ids are the corpus's own and nothing enforces uniqueness
        /// across two corpora, so the corpus has to be part of the key or two unrelated utterances
        /// that happen to share a row number pair with each other.
        public var pairingKey: String { "\(corpusID)\u{1F}\(sampleID)" }

        public subscript(stage: TranscriptionQuality.Stage) -> StageSummary? {
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

        /// The corpora this cohort's utterances came from, in the order they first appear.
        ///
        /// More than one is the normal case: a cohort is a *language condition*, and the corpora
        /// that satisfy it are chosen separately. `egyptian-arabic` is read speech from FLEURS and
        /// spontaneous broadcast speech from MGB-3, which are not the same task.
        public var corpusIDs: [String] {
            var seen: Set<String> = []
            return utterances.map(\.corpusID).filter { seen.insert($0).inserted }
        }

        /// The same cohort narrowed to the utterances of one corpus.
        ///
        /// A `CohortResult` rather than a purpose-built summary, so every per-corpus figure is
        /// produced by the pooling above — literally the function that produced the cohort figure
        /// it will be printed under. A second summariser would be free to drift from the first, and
        /// the only claim a breakdown makes is that it is the same statistic over fewer rows.
        public func restricted(toCorpus corpusID: String) -> CohortResult {
            CohortResult(cohort: cohort, utterances: utterances.filter { $0.corpusID == corpusID })
        }

        /// Utterances that carry a measurement at this stage. Below the total at `.finalOutput`
        /// whenever cleanup was skipped for some of them.
        public func measuredCount(at stage: TranscriptionQuality.Stage) -> Int {
            utterances.filter { $0[stage] != nil }.count
        }

        /// Total edit distance over total reference length, micro-averaged exactly as the frozen v1
        /// `TranscriptionQualityScoring.Metric` does — which is also how published WER is computed,
        /// so the figure is comparable to one (R5). An unweighted mean of per-utterance rates is a
        /// different statistic: under it a one-word utterance counts as much as a thirty-word one.
        ///
        /// `nil` for an empty cohort, and for a stage no utterance measured. A rate over nothing is
        /// not zero, and a zero WER would rank a backend that measured nothing first.
        public func pooledNormalizedWER(at stage: TranscriptionQuality.Stage) -> Double? {
            pooled(at: stage, errors: \.normalizedWordErrors, referenceLength: \.normalizedReferenceWords)
        }

        public func pooledRawWER(at stage: TranscriptionQuality.Stage) -> Double? {
            pooled(at: stage, errors: \.rawWordErrors, referenceLength: \.rawReferenceWords)
        }

        public func pooledNormalizedCER(at stage: TranscriptionQuality.Stage) -> Double? {
            pooled(at: stage, errors: \.normalizedCharacterErrors, referenceLength: \.normalizedReferenceCharacters)
        }

        public func pooledRawCER(at stage: TranscriptionQuality.Stage) -> Double? {
            pooled(at: stage, errors: \.rawCharacterErrors, referenceLength: \.rawReferenceCharacters)
        }

        /// Mean over the utterances where faithfulness was measurable at all. `nil` when none were:
        /// a cohort of punctuation-only references has no language evidence in it, and averaging the
        /// not-applicable ones as agreement would clear the gate on nothing.
        public func meanFaithfulness(at stage: TranscriptionQuality.Stage) -> Double? {
            mean(utterances.compactMap { $0[stage]?.faithfulness })
        }

        /// How many utterances the cohort's faithfulness figure actually rests on.
        public func faithfulnessMeasuredCount(at stage: TranscriptionQuality.Stage) -> Int {
            utterances.filter { $0[stage]?.faithfulness != nil }.count
        }

        /// How many utterances the script-change caveat applies to, so a cohort figure resting on
        /// inflated rates can be read as the upper bound it is.
        public func scriptChangedUtteranceCount(at stage: TranscriptionQuality.Stage) -> Int {
            utterances.filter { $0[stage]?.scriptChangeInflatesErrorRate == true }.count
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

        private func pooled(
            at stage: TranscriptionQuality.Stage,
            errors: KeyPath<StageSummary, Int>,
            referenceLength: KeyPath<StageSummary, Int>
        ) -> Double? {
            let summaries = utterances.compactMap { $0[stage] }
            guard !summaries.isEmpty else { return nil }
            return TranscriptionQualityScoring.errorRate(
                errors: summaries.reduce(0) { $0 + $1[keyPath: errors] },
                referenceLength: summaries.reduce(0) { $0 + $1[keyPath: referenceLength] }
            )
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
            // A thrown error's description is one of the two fields a caller does not compose, so
            // it is bounded rather than trusted.
            self.failureMessage = failureMessage.map(ReceiptProse.sanitized)
        }

        public var didFail: Bool { failureMessage != nil }
    }

    /// One backend's whole run. A backend that could not run is this same value with a reason and
    /// no cohorts (R12) — never a row of zeros, which would rank it first.
    struct Backend: Codable, Sendable, Equatable {
        /// The backend *family*, as `BackendOption.backend` spells it. Six Whisper checkpoints and
        /// two Parakeet ones share a value here, so this is never an identity — see `identity`.
        public let backend: String
        public let model: String
        public let label: String
        /// R17. `automatic` where the backend detects the language, `pinned:<code>` where it cannot.
        public let languageConfiguration: String
        /// `nil` when the backend was measured.
        public let notRunnable: NotRunnable?
        public let warmup: Warmup?
        public let cohorts: [CohortResult]
        /// Samples that threw, named and explained, so a backend with three bad files is
        /// distinguishable from a backend with three fewer samples — and from a backend whose model
        /// never loaded. Also carries the failures behind a `noMeasuredSamples` reason, which is why
        /// that reason does not spell them out itself.
        public let failures: [SampleFailure]

        public init(
            backend: String,
            model: String,
            label: String,
            languageConfiguration: String,
            notRunnable: NotRunnable? = nil,
            warmup: Warmup? = nil,
            cohorts: [CohortResult] = [],
            failures: [SampleFailure] = []
        ) {
            self.backend = backend
            self.model = model
            self.label = label
            self.languageConfiguration = languageConfiguration
            self.notRunnable = notRunnable
            self.warmup = warmup
            self.cohorts = cohorts
            self.failures = failures
        }

        /// The ids alone, for readers that only pair measurements across backends.
        public var failedSampleIDs: [String] { failures.map(\.sampleID) }

        /// What the decision layer keys on.
        ///
        /// `backend` alone is a family name: `BackendOption.all` holds six options whose `backend`
        /// is `whisper` and two whose `backend` is `fluidaudio`, and the sweep runs exactly that
        /// inventory. Keyed on the family, every Whisper size collapsed into one dictionary slot —
        /// a comparison then ran against whichever checkpoint happened to be recorded last, and a
        /// tie between two Whisper sizes trapped on a duplicate dictionary key.
        public var identity: String { "\(backend)/\(model)" }

        public var isRunnable: Bool { notRunnable == nil }

        /// The rendered reason, with the failures the `noMeasuredSamples` case needs.
        public var notRunnableDescription: String? {
            notRunnable?.description(failures: failures)
        }

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

    /// Every entry of one backend family — plural because a family is not an identity.
    func backends(inFamily family: String) -> [Backend] {
        backends.filter { $0.backend == family }
    }

    func backend(identity: String) -> Backend? {
        backends.first { $0.identity == identity }
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
