import AVFoundation
import Foundation
import MuesliCore
@testable import MuesliNativeApp

// This file is deliberately suite-free. `scripts/test_ci_test_shards.sh` discovers `@Suite`
// declarations with `Tests/MuesliTests/*.swift` — one level deep — so a suite parked in this
// subdirectory would evade shard registration instead of failing the guard.

// MARK: - Gate

/// R10's three-part gate, expressed over a plain environment dictionary rather than read from the
/// process. That is what lets the CI-denial branch be asserted without a test mutating the
/// environment of every other test in the target.
enum TranscriptionQualityHarnessGate {
    /// Deliberately distinct from the corpus path: possessing a corpus is not consent to spend an
    /// hour of Neural Engine time on it.
    static let optInVariable = "MUESLI_ASR_HARNESS"
    static let optInValue = "1"

    /// Presence alone denies, whatever the value. A runner that exports `CI=` empty is still a
    /// runner, and the cost of being wrong in that direction is only a skipped maintainer run.
    static let continuousIntegrationVariables = ["CI", "GITHUB_ACTIONS"]

    enum Denial: Equatable, CustomStringConvertible {
        case continuousIntegration(String)
        case corpusDirectoryUnset
        case optInUnset

        var description: String {
            switch self {
            case let .continuousIntegration(variable):
                return "\(variable) is set, so this is a build runner and the harness must not run"
            case .corpusDirectoryUnset:
                return "\(TranscriptionCorpusStore.environmentVariable) is not set to a corpus store"
            case .optInUnset:
                return "\(TranscriptionQualityHarnessGate.optInVariable) is not set to "
                    + "\(TranscriptionQualityHarnessGate.optInValue)"
            }
        }
    }

    /// `nil` when the full maintainer configuration is present.
    static func denial(environment: [String: String]) -> Denial? {
        // Evaluated first and unconditionally (R10): a CI runner that inherited a maintainer's
        // corpus path and opt-in must still skip, so the denial cannot be outvoted by the other two.
        if let variable = continuousIntegrationVariables.first(where: { environment[$0] != nil }) {
            return .continuousIntegration(variable)
        }
        let corpusPath = environment[TranscriptionCorpusStore.environmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let corpusPath, !corpusPath.isEmpty else { return .corpusDirectoryUnset }
        let optIn = environment[optInVariable]?.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unrecognised value is not consent, so only the documented value opts in.
        guard optIn == optInValue else { return .optInUnset }
        return nil
    }

    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        denial(environment: environment) == nil
    }
}

// MARK: - Host

/// The three version fields the macOS gate needs, as a value the sweep can be handed in a test.
/// `OperatingSystemVersion`'s own `Sendable` status varies by SDK, and this only ever needs
/// comparing and printing.
struct HarnessHostOperatingSystem: Sendable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static var current: HarnessHostOperatingSystem {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return HarnessHostOperatingSystem(
            major: version.majorVersion,
            minor: version.minorVersion,
            patch: version.patchVersion
        )
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

// MARK: - Eligibility

/// Whether a backend can be measured on this host at all, decided before anything is loaded.
///
/// Pure and coordinator-free on purpose: the ordering below is the part that must be provable, and
/// proving it must not require a machine with models on disk.
enum TranscriptionQualityEligibility {
    /// Backends whose route body sits behind `#available(macOS 15, *)` in `TranscriptionRuntime`
    /// and throws on anything older. Read off those checks directly rather than inferred from the
    /// model catalogue, because the throw is what the sweep would otherwise record as a failure.
    static let macOS15Backends: Set<String> = [
        "qwen", "cohere", "indicasr", "gemma4-litert", "nemotron35",
    ]

    static func minimumMacOSMajorVersion(for backend: BackendOption) -> Int? {
        macOS15Backends.contains(backend.backend) ? 15 : nil
    }

    /// The macOS gate is checked before availability so a host that cannot run the backend never
    /// probes its cache — and so the reported reason is the one the maintainer can act on.
    static func notRunnableReason(
        for backend: BackendOption,
        hostVersion: HarnessHostOperatingSystem,
        isModelAvailableLocally: (BackendOption) -> Bool
    ) -> TranscriptionQualityRun.NotRunnable? {
        if let minimum = minimumMacOSMajorVersion(for: backend), hostVersion.major < minimum {
            return .requiresNewerMacOS(required: minimum, host: hostVersion.description)
        }
        // KTD8: presence only. `ManagedASRModelDownloader.loadValidated` would pull gigabytes
        // mid-measurement and corrupt every latency figure that followed it.
        guard isModelAvailableLocally(backend) else { return .modelNotDownloaded }
        return nil
    }

    /// Weights that only ever decode one language, whatever is asked of them.
    ///
    /// R17 is about what the model was *able* to attempt, not about which argument the harness
    /// passed. An English-only checkpoint has no detection step to report, so calling it
    /// `automatic` would present it as a candidate for the Arabic cohorts and then charge its
    /// certain failure there to model quality instead of to the configuration.
    static func isEnglishOnly(_ backend: BackendOption) -> Bool {
        switch backend.backend {
        // `.en` WhisperKit checkpoints; the multilingual ones expose language selection.
        case "whisper": return !backend.supportsWhisperLanguageSelection
        // Parakeet v2 is the English-only member of the family; v3 covers 25 languages. The `v2`
        // test on the model identifier is the same one `BackendOption.isDownloaded` uses to pick
        // the download plan.
        case "fluidaudio": return backend.model.contains("v2")
        default: return false
        }
    }

    /// What language the backend was actually decoding in.
    ///
    /// KTD5 asks that no backend be steered by the harness, so every one runs on its shipped
    /// default. For most that default *is* automatic detection; `CohereTranscribeLanguage` and
    /// `IndicASRLanguage` have no automatic case at all, so their default is a pinned language, and
    /// the English-only checkpoints have no language axis at all. Recording it per backend is what
    /// stops the report comparing a pinned model against an auto-detecting one without saying so.
    static func languageConfiguration(for backend: BackendOption) -> String {
        switch backend.backend {
        case "cohere": return "pinned:\(CohereTranscribeLanguage.defaultLanguage.rawValue)"
        case "indicasr": return "pinned:\(IndicASRLanguage.defaultLanguage.rawValue)"
        default:
            // `qwen`, `nemotron35`, `sensevoice` and `gemma4-litert` all detect the language
            // themselves on their shipped defaults; `whisper` and `fluidaudio` do only in their
            // multilingual checkpoints.
            return isEnglishOnly(backend) ? "pinned:en" : "automatic"
        }
    }
}

// MARK: - Scratch support directory

/// KTD9. The sweep must not be able to reach the maintainer's real database or config.
///
/// This used to `setenv` two variables and call the job done. It did not do the job: `MUESLI_SUPPORT_DIR`
/// and `MUESLI_DB_PATH` are read by exactly one place in the repository — `MuesliCLI.swift`, a
/// *separate executable target* — while everything the sweep drives resolves its paths through
/// `AppIdentity.supportDirectoryURL`, which reads `Info.plist` and the home directory and has never
/// consulted either variable. The override therefore isolated nothing in-process, and the `setenv`
/// itself was two further defects: it was never restored, so it leaked into every other suite in the
/// same `swift test` process, and it raced any concurrent `getenv` in a parallel test process.
///
/// So nothing here mutates the process environment any more. The directory is created and returned,
/// the overrides are kept for the one consumer they work for (a spawned `muesli-cli`), and the one
/// real write the in-process pipeline can still make into the maintainer's support directory is
/// named by `writeHazards` so a run can refuse rather than quietly leak.
enum TranscriptionQualityScratchSupportDirectory {
    static let supportDirectoryVariable = "MUESLI_SUPPORT_DIR"
    static let databasePathVariable = "MUESLI_DB_PATH"

    /// Pure, so the layout is assertable without touching the file system.
    static func url(root: URL, runID: String) -> URL {
        root
            .appendingPathComponent("muesli-asr-harness", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
    }

    /// The environment a *child* `muesli-cli` process would need to share this directory. Applying
    /// these to the current process would change nothing, because nothing in this process reads them.
    static func environmentOverrides(at directory: URL) -> [String: String] {
        [
            supportDirectoryVariable: directory.path,
            databasePathVariable: directory.appendingPathComponent("muesli.db").path,
        ]
    }

    /// Writes into the real support directory that the sweep can still perform, given `environment`.
    ///
    /// Only one exists: `TranscriptionRuntime.logPostProcPair` appends raw and cleaned transcript
    /// text to `postproc-pairs.jsonl` under `AppIdentity.supportDirectoryURL`, gated on the two
    /// verbose-logging variables below. That is transcript text landing outside the scratch
    /// directory, which is the isolation claim this type makes — so it is reported rather than
    /// assumed away.
    static func writeHazards(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        func isEnabled(_ variable: String) -> Bool {
            let raw = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return raw == "1" || raw == "true" || raw == "yes"
        }
        guard isEnabled("MUESLI_DEBUG_POSTPROC_LOGS"), isEnabled("MUESLI_LOG_POSTPROC_PAIRS") else {
            return []
        }
        return [
            "MUESLI_LOG_POSTPROC_PAIRS appends transcript text to postproc-pairs.jsonl in the real "
                + "app support directory, which no scratch directory can redirect",
        ]
    }

    /// Creates the scratch directory. Deliberately leaves the process environment alone.
    @discardableResult
    static func prepare(
        root: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        runID: String = UUID().uuidString,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = url(root: root, runID: runID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

// MARK: - Run model

/// What one sweep of the corpus across the backend inventory produced.
enum TranscriptionQualityRun {
    /// R12: a backend that could not run is a value with a reason, never a zero and never a
    /// thrown failure. Zeros would rank an unrunnable backend first.
    enum NotRunnable: Equatable, CustomStringConvertible {
        case requiresNewerMacOS(required: Int, host: String)
        case modelNotDownloaded
        /// The store held nothing to measure. Recorded per backend so the matrix stays complete
        /// rather than silently short.
        case noSamples
        /// The backend loaded and ran, and came out of it with nothing scored: either the corpus
        /// held only the sample the cold start consumed, or every remaining sample threw.
        ///
        /// This is *not* a measured outcome. A `.measured` entry with an empty sample list looks
        /// like a result to everything downstream — it can be ranked, and with no utterances its
        /// pooled figures are absent rather than bad — so an entirely failed backend could present
        /// as a real one. The failures travel in the reason so neither the ids nor *why* they failed
        /// is lost with the outcome: an id list alone cannot distinguish a missing file from a model
        /// that never loaded, and this is exactly the case where that is the only question.
        case noMeasuredSamples(failures: [SampleFailure])

        var description: String {
            switch self {
            case let .requiresNewerMacOS(required, host):
                return "requires macOS \(required) or later; host is \(host)"
            case .modelNotDownloaded:
                return "model is not downloaded, and the harness never downloads one"
            case .noSamples:
                return "the corpus store yielded no usable samples"
            case let .noMeasuredSamples(failures):
                guard !failures.isEmpty else {
                    return "the corpus held no sample beyond the one the cold start consumed"
                }
                let sentence = "every sample failed, so nothing was scored: "
                    + failures.map(\.sampleID).joined(separator: ", ")
                let reasons = SampleFailure.distinctMessages(in: failures)
                guard !reasons.isEmpty else { return sentence }
                return sentence + " — " + reasons.joined(separator: "; ")
            }
        }
    }

    /// Timings for one measured transcription. Every field is seconds; the pipeline reports
    /// milliseconds and the conversion happens once, here.
    struct Latency: Sendable, Equatable {
        /// Wall clock across the whole call — what a user would wait for.
        let endToEndSeconds: Double
        /// The recognizer's own stage, as the pipeline reported it.
        let speechRecognitionSeconds: Double
        /// Artifact cleanup, transcript cleanup and finalization together: everything the cleanup
        /// stage costs on top of recognition.
        let postRecognitionSeconds: Double
        /// `nil` when the audio's duration could not be read.
        let audioDurationSeconds: Double?

        /// `nil` when there is no duration to divide by. A real-time factor with no denominator is
        /// not-applicable; reporting zero would read as infinitely fast.
        var realTimeFactor: Double? {
            guard let audioDurationSeconds, audioDurationSeconds > 0 else { return nil }
            return endToEndSeconds / audioDurationSeconds
        }
    }

    /// Whether the cleanup stage actually ran for one sample, and what came out of it.
    ///
    /// Asking for cleanup is not the same as getting it. `TranscriptionRuntime` reports
    /// `.skippedUnavailable` when the cleanup model is not loadable and skips it outright for the
    /// Indic backend, and the run still returns a `finalOutput` — the raw text after artifact
    /// cleanup and filler removal. Scoring that as the cleanup stage's product is how a sweep
    /// reports "cleanup changed nothing" for a sweep in which cleanup never ran, which inverts the
    /// entire reason two stages are measured (R7/R8: catching the Arabic-to-English translation the
    /// cleanup stage introduces).
    enum CleanupExecution: Sendable, Equatable, CustomStringConvertible {
        /// Cleanup ran and its output is what `finalOutput` scores.
        case applied
        /// Cleanup did not run. The stage is still an honest measurement of what the pipeline
        /// finally produced, but it is not evidence about cleanup and carries no faithfulness delta.
        case notPerformed(outcome: String)
        /// The pipeline reported no final-output artifact at all, so there is nothing to score.
        case notReported

        var description: String {
            switch self {
            case .applied: return "applied"
            case let .notPerformed(outcome): return "not performed (\(outcome))"
            case .notReported: return "no final-output artifact"
            }
        }

        var didRun: Bool { self == .applied }
    }

    /// One sample measured at both stages (R7).
    struct SampleMeasurement: Sendable {
        let sampleID: String
        let corpusID: String
        let cohort: TranscriptionQuality.Cohort
        let rawASR: TranscriptionQuality.StageScore
        /// Scored from whatever text the pipeline finally produced — never mirrored from `rawASR`,
        /// and scored against the empty string when the pipeline reported no final output at all.
        ///
        /// Named for the pipeline rather than for the stage because it is *not* a measurement of the
        /// cleanup stage unless `cleanup == .applied`. Read `measuredFinalOutput` for that question;
        /// this one only answers "what did the pipeline hand back".
        let pipelineFinalOutput: TranscriptionQuality.StageScore
        let cleanup: CleanupExecution
        let latency: Latency

        /// The final stage as a measurement of the cleanup stage: `nil` when cleanup did not run,
        /// or when the pipeline reported no final-output artifact for this sample.
        var measuredFinalOutput: TranscriptionQuality.StageScore? {
            cleanup.didRun ? pipelineFinalOutput : nil
        }

        /// R8's signal: what the cleanup stage did to faithfulness, which is a different defect
        /// from a recognition error.
        ///
        /// `nil` when cleanup did not run, or when either stage's faithfulness is not-applicable. A
        /// zero here would read as "cleanup left the language alone", which is a claim no
        /// unperformed cleanup can support.
        var faithfulnessDelta: TranscriptionQuality.FaithfulnessDelta? {
            guard let finalOutput = measuredFinalOutput?.faithfulness,
                  let rawASR = rawASR.faithfulness
            else { return nil }
            return TranscriptionQuality.FaithfulnessDelta(
                rawASR: rawASR,
                finalOutput: finalOutput
            )
        }

        /// `nil` at `.finalOutput` when the cleanup stage did not run: there is a text, but it is
        /// not that stage's measurement, and every aggregate has to skip it rather than pool it.
        subscript(stage: TranscriptionQuality.Stage) -> TranscriptionQuality.StageScore? {
            switch stage {
            case .rawASR: rawASR
            case .finalOutput: measuredFinalOutput
            }
        }
    }

    /// One sample that threw. Named *and explained* rather than dropped: a backend with three bad
    /// files, a backend with three fewer samples and a backend whose model never loaded are three
    /// different facts, and only the message separates the last one from the first.
    struct SampleFailure: Sendable, Equatable {
        let sampleID: String
        let message: String

        /// The messages present, deduplicated, in first-seen order. One cause usually explains a
        /// whole backend, so a reason is worth stating once rather than once per sample.
        static func distinctMessages(in failures: [SampleFailure]) -> [String] {
            var seen: Set<String> = []
            return failures.map(\.message).filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }

    /// R9's separately-reported cold start. The first call pays model load and, for CoreML
    /// backends, first-run compilation; pooling it into the distribution would move the p95 by
    /// tens of seconds and describe a latency no steady-state user ever sees.
    struct Warmup: Sendable, Equatable {
        let sampleID: String
        /// `nil` when the warmup threw — the load still happened, but there is no honest time.
        let endToEndSeconds: Double?
        let failureMessage: String?
    }

    struct Measurement: Sendable {
        let warmup: Warmup?
        /// The recorded distribution. The warmup sample is absent from it by construction.
        let samples: [SampleMeasurement]
        let failures: [SampleFailure]
    }

    enum Outcome: Sendable {
        case notRunnable(NotRunnable)
        case measured(Measurement)
    }

    struct BackendRun: Sendable {
        let backend: String
        let model: String
        let label: String
        /// What the backend was decoding in, per `TranscriptionQualityEligibility`.
        let languageConfiguration: String
        let outcome: Outcome
    }

    struct Result: Sendable {
        let backends: [BackendRun]
        /// Whether the cleanup stage ran at all. Without it `finalOutput` is only artifact cleanup
        /// away from `rawASR`, and the faithfulness delta this harness exists to catch cannot
        /// appear — so a receipt that omits this flag is unreadable.
        let cleanupEnabled: Bool
        let cohortsMeasured: [TranscriptionQuality.Cohort]
    }
}

// MARK: - Aggregation

extension TranscriptionQualityRun.Measurement {
    func samples(in cohort: TranscriptionQuality.Cohort) -> [TranscriptionQualityRun.SampleMeasurement] {
        samples.filter { $0.cohort == cohort }
    }

    var cohorts: [TranscriptionQuality.Cohort] {
        TranscriptionQuality.Cohort.allCases.filter { cohort in
            samples.contains { $0.cohort == cohort }
        }
    }

    /// Samples whose final stage is genuinely the cleanup stage's product. A run configured with
    /// cleanup enabled but with none of these measured nothing about cleanup, which the receipt has
    /// to be able to say (A4).
    var cleanupAppliedCount: Int {
        samples.filter { $0.cleanup.didRun }.count
    }

    /// Why cleanup did not run, and on how many samples, in a stable order.
    var cleanupNotPerformedCounts: [(reason: String, count: Int)] {
        var counts: [String: Int] = [:]
        for sample in samples where !sample.cleanup.didRun {
            counts[sample.cleanup.description, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { (reason: $0.key, count: $0.value) }
    }

    /// Mean faithfulness over the samples where the question applies. `nil` when none do: a mean
    /// over no measurement is not zero (A2).
    func meanFaithfulness(
        in cohort: TranscriptionQuality.Cohort,
        at stage: TranscriptionQuality.Stage
    ) -> Double? {
        let measured = samples(in: cohort).compactMap { $0[stage]?.faithfulness }
        guard !measured.isEmpty else { return nil }
        return measured.reduce(0, +) / Double(measured.count)
    }

    /// R9's per-cohort latency distribution, nearest-rank through the existing scoring code.
    /// `nil` when the cohort produced no measured sample: a distribution over nothing would report
    /// a p50 of zero.
    func endToEndDistribution(
        in cohort: TranscriptionQuality.Cohort
    ) -> TranscriptionQualityScoring.Distribution? {
        distribution(samples(in: cohort).map(\.latency.endToEndSeconds))
    }

    func speechRecognitionDistribution(
        in cohort: TranscriptionQuality.Cohort
    ) -> TranscriptionQualityScoring.Distribution? {
        distribution(samples(in: cohort).map(\.latency.speechRecognitionSeconds))
    }

    /// Pooled across the cohort rather than averaged per sample, so a handful of very short clips
    /// cannot dominate the figure.
    func realTimeFactor(in cohort: TranscriptionQuality.Cohort) -> Double? {
        let measured = samples(in: cohort).filter { $0.latency.audioDurationSeconds != nil }
        let audio = measured.reduce(0.0) { $0 + ($1.latency.audioDurationSeconds ?? 0) }
        guard audio > 0 else { return nil }
        return measured.reduce(0.0) { $0 + $1.latency.endToEndSeconds } / audio
    }

    private func distribution(_ values: [Double]) -> TranscriptionQualityScoring.Distribution? {
        values.isEmpty ? nil : TranscriptionQualityScoring.Distribution(values: values)
    }
}

extension TranscriptionQualityRun.Result {
    var measuredBackends: [TranscriptionQualityRun.BackendRun] {
        backends.filter { if case .measured = $0.outcome { true } else { false } }
    }

    var notRunnableBackends: [TranscriptionQualityRun.BackendRun] {
        backends.filter { if case .notRunnable = $0.outcome { true } else { false } }
    }

    /// A plain-text summary for a maintainer watching the sweep. The committed run receipt is U5's
    /// job; this exists so an hour-long run is not silent.
    var summaryLines: [String] {
        var lines = ["cleanup stage: \(cleanupEnabled ? "enabled" : "disabled")"]
        for run in backends {
            let header = "\(run.label) [\(run.backend)/\(run.model)] (\(run.languageConfiguration))"
            switch run.outcome {
            case let .notRunnable(reason):
                lines.append("\(header): not runnable — \(reason.description)")
            case let .measured(measurement):
                let warmup = measurement.warmup.map { warmup -> String in
                    guard let seconds = warmup.endToEndSeconds else {
                        return "warmup \(warmup.sampleID) failed"
                    }
                    return "warmup \(String(format: "%.2f", seconds))s"
                } ?? "no warmup"
                lines.append(
                    "\(header): \(measurement.samples.count) measured, "
                        + "\(measurement.failures.count) failed, \(warmup), "
                        + "cleanup applied on \(measurement.cleanupAppliedCount)"
                )
                // Counting the failures without saying why is what made a real sweep undiagnosable.
                for reason in TranscriptionQualityRun.SampleFailure.distinctMessages(in: measurement.failures) {
                    let count = measurement.failures.filter { $0.message == reason }.count
                    lines.append("  failed on \(count) sample(s): \(reason)")
                }
                for (reason, count) in measurement.cleanupNotPerformedCounts {
                    lines.append("  cleanup \(reason) on \(count) sample(s)")
                }
                for cohort in measurement.cohorts {
                    let scores = measurement.samples(in: cohort)
                    // Not-applicable faithfulness is skipped rather than counted as agreement, and
                    // the final stage only counts where cleanup actually ran.
                    let faithfulness = measurement.meanFaithfulness(in: cohort, at: .finalOutput)
                    let latency = measurement.endToEndDistribution(in: cohort)
                    let realTime = measurement.realTimeFactor(in: cohort)
                    lines.append(
                        "  \(cohort.rawValue): n=\(scores.count) "
                            + "faithfulness=\(faithfulness.map { String(format: "%.3f", $0) } ?? "n/a") "
                            + "p50=\(latency.map { String(format: "%.2f", $0.p50) } ?? "n/a")s "
                            + "p95=\(latency.map { String(format: "%.2f", $0.p95) } ?? "n/a")s "
                            + "rtf=\(realTime.map { String(format: "%.2f", $0) } ?? "n/a")"
                    )
                }
            }
        }
        return lines
    }
}

// MARK: - Driver seam

/// One transcription as the sweep needs it: both stages, and the timings the pipeline itself
/// reported rather than the ones the harness guessed.
struct TranscriptionQualityTrace: Sendable, Equatable {
    var rawASR: String
    /// `nil` when the pipeline reported no final-output artifact — nothing to score, as opposed to
    /// an empty final output, which is a recognition failure.
    var finalOutput: String?
    /// What the pipeline said the cleanup stage did, so the sweep can tell a cleanup that changed
    /// nothing from a cleanup that never ran.
    var cleanupOutcome: DictationCleanupOutcome?
    var stageMilliseconds: [DictationTranscriptionStageEvent.Stage: Int]
    var elapsedSeconds: Double

    init(
        rawASR: String,
        finalOutput: String?,
        cleanupOutcome: DictationCleanupOutcome? = .applied,
        stageMilliseconds: [DictationTranscriptionStageEvent.Stage: Int] = [:],
        elapsedSeconds: Double = 0
    ) {
        self.rawASR = rawASR
        self.finalOutput = finalOutput
        self.cleanupOutcome = cleanupOutcome
        self.stageMilliseconds = stageMilliseconds
        self.elapsedSeconds = elapsedSeconds
    }

    /// How the final stage should be read, given what the pipeline reported.
    var cleanupExecution: TranscriptionQualityRun.CleanupExecution {
        guard finalOutput != nil else { return .notReported }
        switch cleanupOutcome {
        case .applied: return .applied
        case let .some(outcome): return .notPerformed(outcome: outcome.rawValue)
        // No outcome reported at all is not evidence that cleanup ran.
        case .none: return .notPerformed(outcome: "unreported")
        }
    }

    var speechRecognitionSeconds: Double {
        Double(stageMilliseconds[.speechRecognition] ?? 0) / 1_000
    }

    /// Everything after recognition: what enabling the cleanup stage costs.
    var postRecognitionSeconds: Double {
        let stages: [DictationTranscriptionStageEvent.Stage] = [
            .artifactCleanup, .transcriptCleanup, .finalization,
        ]
        return Double(stages.reduce(0) { $0 + (stageMilliseconds[$1] ?? 0) }) / 1_000
    }
}

/// Everything the sweep does to a backend, behind a seam. The sweep's ordering guarantees — no
/// download on an ineligible backend, unload before the next load, warmup excluded — are the part
/// worth proving, and proving them must not need a model on disk.
protocol TranscriptionQualityDriver: Sendable {
    /// `nil` when the backend can run here with what is already downloaded.
    func notRunnableReason(for backend: BackendOption) async -> TranscriptionQualityRun.NotRunnable?
    func transcribe(
        _ sample: TranscriptionCorpus.Sample,
        backend: BackendOption
    ) async throws -> TranscriptionQualityTrace
    /// Must leave no weights resident: R11 forbids two ASR models resident at once, because a
    /// second one turns every latency figure into a memory-pressure measurement.
    func unload(_ backend: BackendOption) async
}

// MARK: - Live driver

/// Drives the real app pipeline: `TranscriptionCoordinator` with a `traceReporter` attached, which
/// is the only seam that yields both stages from a single transcription (KTD1, R7).
struct LiveTranscriptionQualityDriver: TranscriptionQualityDriver {
    let coordinator: TranscriptionCoordinator
    let hostVersion: HarnessHostOperatingSystem
    /// Injected so eligibility is decidable in a test; production passes `BackendOption.isDownloaded`,
    /// which is a file-presence check and never a fetch.
    let isModelAvailableLocally: @Sendable (BackendOption) -> Bool
    /// Cleanup is where the reported Arabic-to-English translation happens, so measuring with it
    /// off would hide the defect this harness exists to find.
    let cleanupEnabled: Bool
    /// Which backends this driver has already selected and loaded. See `prepare`.
    private let loaded = LoadedBackends()

    init(
        coordinator: TranscriptionCoordinator,
        hostVersion: HarnessHostOperatingSystem = .current,
        isModelAvailableLocally: @escaping @Sendable (BackendOption) -> Bool = { $0.isDownloaded },
        cleanupEnabled: Bool = true
    ) {
        self.coordinator = coordinator
        self.hostVersion = hostVersion
        self.isModelAvailableLocally = isModelAvailableLocally
        self.cleanupEnabled = cleanupEnabled
    }

    func notRunnableReason(for backend: BackendOption) async -> TranscriptionQualityRun.NotRunnable? {
        TranscriptionQualityEligibility.notRunnableReason(
            for: backend,
            hostVersion: hostVersion,
            isModelAvailableLocally: isModelAvailableLocally
        )
    }

    /// Selects the backend and loads its weights, exactly as choosing the model in the app does.
    ///
    /// Not optional, and not something `transcribeDictationWithCleanupOutcome` does for itself.
    /// `TranscriptionCoordinator.route` calls straight into each transcriber, and only Nemotron and
    /// Cohere load on demand inside their own `transcribe`; FluidAudio, WhisperKit, Qwen3, SenseVoice
    /// and Indic all throw `notLoaded` unless something has already called `preloadRequired`. In the
    /// app that something is `MuesliController` reacting to the model selection — which no test
    /// process has. Without this the sweep measured the two self-loading backends and recorded every
    /// other one as a total failure.
    ///
    /// The designation is as load-bearing as the load itself: `preloadRequired` ends by reconciling
    /// residency, and a backend that stands behind no designated slot is unloaded there — so a
    /// preload without a selection would hand the next call an unloaded model again.
    ///
    /// Called from `transcribe` rather than from the sweep so the cold start pays the model load,
    /// which is what R9 reports it as.
    private func prepare(_ backend: BackendOption) async throws {
        guard await loaded.claim("\(backend.backend)/\(backend.model)") else { return }
        do {
            await coordinator.setDesignatedBackends(
                dictation: Self.residencyIdentifier(for: backend),
                meetingTranscription: nil,
                meetingLiveCaption: nil
            )
            try await coordinator.preloadRequired(
                backend: backend,
                enablePostProcessor: cleanupEnabled,
                // The sweep measures dictation. Loading the diarizer and the meeting VAD would put a
                // second set of weights on the machine every latency figure is read off.
                includeMeetingHelpers: false
            )
        } catch {
            // A failed load must be retried by the next sample rather than silently downgraded into
            // "already loaded", or one bad first call would fail the backend for the whole sweep with
            // a different reason than the real one.
            await loaded.release("\(backend.backend)/\(backend.model)")
            throw error
        }
    }

    /// `TranscriptionCoordinator.residencyIdentifier` is private, and mirroring it off the same
    /// published set is what keeps the designation this driver writes equal to the one the
    /// coordinator reconciles against. A mismatch does not fail loudly — it unloads the model.
    private static func residencyIdentifier(for backend: BackendOption) -> String {
        TranscriptionCoordinator.explicitlyRoutedBackendIdentifiers.contains(backend.backend)
            ? backend.backend
            : "fluidaudio"
    }

    func transcribe(
        _ sample: TranscriptionCorpus.Sample,
        backend: BackendOption
    ) async throws -> TranscriptionQualityTrace {
        let collector = HarnessTraceCollector()
        let startedAt = Date()
        try await prepare(backend)
        // Every language argument is left at its shipped default (KTD5): steering one competitor
        // and not another would compare a guided model against an unguided one.
        let outcome = try await coordinator.transcribeDictationWithCleanupOutcome(
            at: sample.audioURL,
            backend: backend,
            enablePostProcessor: cleanupEnabled,
            traceReporter: { event in await collector.record(event) }
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        let snapshot = await collector.snapshot()
        return TranscriptionQualityTrace(
            rawASR: snapshot.artifacts[.rawASR] ?? "",
            // No `?? ""`: an absent artifact is nothing to score, and scoring the empty string
            // against the reference would report a total cleanup failure that was never observed.
            finalOutput: snapshot.artifacts[.finalOutput],
            // The pipeline's own verdict on the cleanup stage. `.skippedUnavailable` and the
            // fallbacks all mean the final text is not cleanup's product, however the run was
            // configured.
            cleanupOutcome: outcome.cleanupOutcome,
            stageMilliseconds: snapshot.stages,
            elapsedSeconds: elapsed
        )
    }

    func unload(_ backend: BackendOption) async {
        await coordinator.unloadTranscriber(for: backend)
        // The weights are gone, so the next call has to load them again rather than trust a claim
        // made before the unload.
        await loaded.release("\(backend.backend)/\(backend.model)")
    }
}

/// Which backends the live driver has already selected and loaded, so the model load lands on the
/// cold start once rather than on every sample. An actor because `TranscriptionQualityDriver` is
/// `Sendable` and the driver itself is a value.
private actor LoadedBackends {
    private var identities: Set<String> = []

    /// `true` when this call is the one that must perform the load.
    func claim(_ identity: String) -> Bool { identities.insert(identity).inserted }

    func release(_ identity: String) { identities.remove(identity) }
}

/// Collects the pipeline's trace events for one transcription. An actor because the reporter is
/// called from whatever context the coordinator happens to be on.
private actor HarnessTraceCollector {
    private var artifacts: [SessionTraceArtifactKind: String] = [:]
    private var stages: [DictationTranscriptionStageEvent.Stage: Int] = [:]

    func record(_ event: DictationRuntimeTraceEvent) {
        switch event {
        case let .artifact(kind, content):
            artifacts[kind] = content
        case let .stage(stageEvent):
            stages[stageEvent.stage] = stageEvent.elapsedMilliseconds
        }
    }

    func snapshot() -> (
        artifacts: [SessionTraceArtifactKind: String],
        stages: [DictationTranscriptionStageEvent.Stage: Int]
    ) {
        (artifacts, stages)
    }
}

// MARK: - Sweep

/// Drives every backend over every sample, serially, recording a value for each.
///
/// Nothing here throws: a backend that cannot run and a sample that fails are both outcomes the
/// matrix records, because an hour-long sweep that aborts on the eleventh backend has measured
/// nothing (R4, R12).
struct TranscriptionQualityRunner: Sendable {
    /// A sample whose transcription outran its budget. Recorded as a per-sample failure like any
    /// other throw, because a hung model must cost one sample, not the sweep.
    struct SampleTimedOut: Error, LocalizedError {
        let sampleID: String
        let seconds: Double
        var errorDescription: String? {
            "transcribing \(sampleID) exceeded the \(String(format: "%.0f", seconds))s budget"
        }
    }

    /// Generous enough that no honest transcription reaches it — the slowest backend here is a
    /// 2-3 second autoregressive decoder, so five minutes on one utterance is a hang, not slowness.
    static let defaultSampleTimeoutSeconds: Double = 300
    /// The cold start pays model load and, for CoreML backends, first-run compilation, which is
    /// tens of seconds by design (R9). It gets its own, larger budget rather than a shared one that
    /// would have to be loose enough to hide a hang in the measured samples.
    static let defaultWarmupTimeoutSeconds: Double = 1_800

    /// Where the sweep narrates itself. An hour-long run that only speaks in its closing summary is
    /// a run a maintainer cannot follow, and a failure that is only visible after every backend has
    /// finished is a failure diagnosed an hour late.
    static let liveLog: @Sendable (String) -> Void = { line in
        fputs("[asr-harness] \(line)\n", stderr)
    }

    let driver: any TranscriptionQualityDriver
    /// `nil` for audio whose duration cannot be read, which only costs the real-time factor.
    let audioDurationSeconds: @Sendable (TranscriptionCorpus.Sample) -> Double?
    let cleanupEnabled: Bool
    /// A hung model would otherwise stall an hour-long sweep with no signal at all. Injectable so
    /// the expiry path is provable in a test in milliseconds.
    let sampleTimeoutSeconds: Double
    let warmupTimeoutSeconds: Double
    /// Injectable so the fake-driven contract tests, which fail samples deliberately, do not print
    /// scripted failures into every unrelated run of the suite.
    let log: @Sendable (String) -> Void

    init(
        driver: any TranscriptionQualityDriver,
        audioDurationSeconds: @escaping @Sendable (TranscriptionCorpus.Sample) -> Double? = {
            TranscriptionQualityRunner.measuredDuration(of: $0)
        },
        cleanupEnabled: Bool = true,
        sampleTimeoutSeconds: Double = TranscriptionQualityRunner.defaultSampleTimeoutSeconds,
        warmupTimeoutSeconds: Double = TranscriptionQualityRunner.defaultWarmupTimeoutSeconds,
        log: @escaping @Sendable (String) -> Void = TranscriptionQualityRunner.liveLog
    ) {
        self.driver = driver
        self.audioDurationSeconds = audioDurationSeconds
        self.cleanupEnabled = cleanupEnabled
        self.sampleTimeoutSeconds = sampleTimeoutSeconds
        self.warmupTimeoutSeconds = warmupTimeoutSeconds
        self.log = log
    }

    /// Prefers the corpus index's own figure and falls back to reading the file, so a corpus that
    /// records durations is not re-decoded once per backend.
    static func measuredDuration(of sample: TranscriptionCorpus.Sample) -> Double? {
        if let recorded = sample.durationSeconds, recorded > 0 { return recorded }
        guard let file = try? AVAudioFile(forReading: sample.audioURL) else { return nil }
        let rate = file.fileFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    func sweep(
        backends: [BackendOption],
        samples: [TranscriptionCorpus.Sample]
    ) async -> TranscriptionQualityRun.Result {
        var runs: [TranscriptionQualityRun.BackendRun] = []
        var cohorts: Set<TranscriptionQuality.Cohort> = []

        // R11: one backend at a time, start to finish, with the unload between them.
        for backend in backends {
            let language = TranscriptionQualityEligibility.languageConfiguration(for: backend)
            func record(_ outcome: TranscriptionQualityRun.Outcome) {
                runs.append(TranscriptionQualityRun.BackendRun(
                    backend: backend.backend,
                    model: backend.model,
                    label: backend.label,
                    languageConfiguration: language,
                    outcome: outcome
                ))
            }

            let header = "\(backend.label) [\(backend.backend)/\(backend.model)]"
            if let reason = await driver.notRunnableReason(for: backend) {
                // Nothing is loaded and nothing is fetched, so there is nothing to unload either.
                log("\(header): not runnable — \(reason.description)")
                record(.notRunnable(reason))
                continue
            }
            guard let warmupSample = samples.first else {
                log("\(header): not runnable — \(TranscriptionQualityRun.NotRunnable.noSamples)")
                record(.notRunnable(.noSamples))
                continue
            }
            log("\(header): starting on \(samples.count) sample(s)")

            var warmup: TranscriptionQualityRun.Warmup
            do {
                let trace = try await transcribe(
                    warmupSample,
                    backend: backend,
                    timeoutSeconds: warmupTimeoutSeconds
                )
                warmup = TranscriptionQualityRun.Warmup(
                    sampleID: warmupSample.id,
                    endToEndSeconds: trace.elapsedSeconds,
                    failureMessage: nil
                )
            } catch {
                // A warmup that throws still loaded the model, and one bad file must not cost the
                // backend its whole run. It is also the first place a broken backend shows itself,
                // so the reason goes out live rather than waiting for the summary.
                log("\(header): cold start on \(warmupSample.id) failed — \(error.localizedDescription)")
                warmup = TranscriptionQualityRun.Warmup(
                    sampleID: warmupSample.id,
                    endToEndSeconds: nil,
                    failureMessage: error.localizedDescription
                )
            }

            var measurements: [TranscriptionQualityRun.SampleMeasurement] = []
            var failures: [TranscriptionQualityRun.SampleFailure] = []
            // The warmup sample is consumed, not re-measured: transcribing it twice would give it
            // double weight in every cohort figure. Dropping the same first sample for every
            // backend keeps the comparison fair.
            for sample in samples.dropFirst() {
                do {
                    let trace = try await transcribe(
                        sample,
                        backend: backend,
                        timeoutSeconds: sampleTimeoutSeconds
                    )
                    measurements.append(measurement(for: sample, trace: trace))
                    cohorts.insert(sample.cohort)
                } catch {
                    log("\(header): \(sample.id) failed — \(error.localizedDescription)")
                    failures.append(TranscriptionQualityRun.SampleFailure(
                        sampleID: sample.id,
                        message: error.localizedDescription
                    ))
                }
            }

            // Before the next backend loads, never after the sweep: two resident models is exactly
            // the contention R11 forbids. The warmup already loaded this one, so it runs on both
            // paths below.
            await driver.unload(backend)

            // R12/A3: a backend that scored nothing is not a measured backend. Recorded as measured
            // it would carry an empty distribution into the ranking, where absent figures read as
            // "no worse than anyone" rather than as no result at all.
            guard !measurements.isEmpty else {
                let reason = TranscriptionQualityRun.NotRunnable.noMeasuredSamples(failures: failures)
                log("\(header): \(reason.description)")
                record(.notRunnable(reason))
                continue
            }
            log("\(header): \(measurements.count) measured, \(failures.count) failed")
            record(.measured(TranscriptionQualityRun.Measurement(
                warmup: warmup,
                samples: measurements,
                failures: failures
            )))
        }

        return TranscriptionQualityRun.Result(
            backends: runs,
            cleanupEnabled: cleanupEnabled,
            cohortsMeasured: TranscriptionQuality.Cohort.allCases.filter { cohorts.contains($0) }
        )
    }

    /// One transcription under a wall-clock budget.
    ///
    /// Expiry is a per-sample failure, not a crash and not an abort: the sweep records it beside the
    /// other failures and moves on, which is the same contract every other throw here has. The
    /// losing task is cancelled, though a backend already inside a synchronous CoreML call will not
    /// notice — the point is that the *sweep* stops waiting on it, and that the receipt names the
    /// sample instead of the run ending in silence.
    private func transcribe(
        _ sample: TranscriptionCorpus.Sample,
        backend: BackendOption,
        timeoutSeconds: Double
    ) async throws -> TranscriptionQualityTrace {
        let driver = driver
        let sampleID = sample.id
        return try await withThrowingTaskGroup(of: TranscriptionQualityTrace?.self) { group in
            group.addTask {
                try await driver.transcribe(sample, backend: backend)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeoutSeconds) * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            while let finished = try await group.next() {
                guard let trace = finished else {
                    throw SampleTimedOut(sampleID: sampleID, seconds: timeoutSeconds)
                }
                return trace
            }
            throw SampleTimedOut(sampleID: sampleID, seconds: timeoutSeconds)
        }
    }

    private func measurement(
        for sample: TranscriptionCorpus.Sample,
        trace: TranscriptionQualityTrace
    ) -> TranscriptionQualityRun.SampleMeasurement {
        TranscriptionQualityRun.SampleMeasurement(
            sampleID: sample.id,
            corpusID: sample.corpusID,
            cohort: sample.cohort,
            rawASR: TranscriptionQuality.StageScore(
                stage: .rawASR,
                cohort: sample.cohort,
                reference: sample.reference,
                hypothesis: trace.rawASR
            ),
            // An absent final artifact scores against the empty string — nothing was produced —
            // and is flagged `.notReported` so no reader mistakes it for a cleanup result. It is
            // never filled in from `rawASR`, which would report a cleanup that changed nothing.
            pipelineFinalOutput: TranscriptionQuality.StageScore(
                stage: .finalOutput,
                cohort: sample.cohort,
                reference: sample.reference,
                hypothesis: trace.finalOutput ?? ""
            ),
            cleanup: trace.cleanupExecution,
            latency: TranscriptionQualityRun.Latency(
                endToEndSeconds: trace.elapsedSeconds,
                speechRecognitionSeconds: trace.speechRecognitionSeconds,
                postRecognitionSeconds: trace.postRecognitionSeconds,
                audioDurationSeconds: audioDurationSeconds(sample)
            )
        )
    }
}
