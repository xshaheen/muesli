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

    /// What language the backend was actually decoding in.
    ///
    /// KTD5 asks that no backend be steered by the harness, so every one runs on its shipped
    /// default. For most that default *is* automatic detection; `CohereTranscribeLanguage` and
    /// `IndicASRLanguage` have no automatic case at all, so their default is a pinned language.
    /// Recording it per backend is what stops the report comparing a pinned model against an
    /// auto-detecting one without saying so.
    static func languageConfiguration(for backend: BackendOption) -> String {
        switch backend.backend {
        case "cohere": return "pinned:\(CohereTranscribeLanguage.defaultLanguage.rawValue)"
        case "indicasr": return "pinned:\(IndicASRLanguage.defaultLanguage.rawValue)"
        default: return "automatic"
        }
    }
}

// MARK: - Scratch support directory

/// KTD9. The sweep must not be able to reach the maintainer's real database or config, so the
/// app-identity isolation variables are pointed at a throwaway directory for the run.
enum TranscriptionQualityScratchSupportDirectory {
    static let supportDirectoryVariable = "MUESLI_SUPPORT_DIR"
    static let databasePathVariable = "MUESLI_DB_PATH"

    /// Pure, so the layout is assertable without touching the process environment.
    static func url(root: URL, runID: String) -> URL {
        root
            .appendingPathComponent("muesli-asr-harness", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
    }

    static func environmentOverrides(at directory: URL) -> [String: String] {
        [
            supportDirectoryVariable: directory.path,
            databasePathVariable: directory.appendingPathComponent("muesli.db").path,
        ]
    }

    /// Mutates the process environment, so it is only ever called from the env-gated suite — which
    /// by construction never runs alongside anything but itself.
    @discardableResult
    static func activate(
        root: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        runID: String = UUID().uuidString,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = url(root: root, runID: runID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for (key, value) in environmentOverrides(at: directory) {
            setenv(key, value, 1)
        }
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

        var description: String {
            switch self {
            case let .requiresNewerMacOS(required, host):
                return "requires macOS \(required) or later; host is \(host)"
            case .modelNotDownloaded:
                return "model is not downloaded, and the harness never downloads one"
            case .noSamples:
                return "the corpus store yielded no usable samples"
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

    /// One sample measured at both stages (R7).
    struct SampleMeasurement: Sendable {
        let sampleID: String
        let corpusID: String
        let cohort: TranscriptionQuality.Cohort
        let rawASR: TranscriptionQuality.StageScore
        let finalOutput: TranscriptionQuality.StageScore
        let latency: Latency

        /// R8's signal: what the cleanup stage did to faithfulness, which is a different defect
        /// from a recognition error.
        var faithfulnessDelta: TranscriptionQuality.FaithfulnessDelta {
            TranscriptionQuality.FaithfulnessDelta(
                rawASR: rawASR.faithfulness,
                finalOutput: finalOutput.faithfulness
            )
        }

        subscript(stage: TranscriptionQuality.Stage) -> TranscriptionQuality.StageScore {
            switch stage {
            case .rawASR: rawASR
            case .finalOutput: finalOutput
            }
        }
    }

    /// One sample that threw. Named rather than dropped, so a backend with three bad files is
    /// distinguishable from a backend with three fewer samples.
    struct SampleFailure: Sendable, Equatable {
        let sampleID: String
        let message: String
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
                        + "\(measurement.failures.count) failed, \(warmup)"
                )
                for cohort in measurement.cohorts {
                    let scores = measurement.samples(in: cohort)
                    let faithfulness = scores.reduce(0.0) { $0 + $1.finalOutput.faithfulness }
                        / Double(scores.count)
                    let latency = measurement.endToEndDistribution(in: cohort)
                    let realTime = measurement.realTimeFactor(in: cohort)
                    lines.append(
                        "  \(cohort.rawValue): n=\(scores.count) "
                            + "faithfulness=\(String(format: "%.3f", faithfulness)) "
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
    var finalOutput: String
    var stageMilliseconds: [DictationTranscriptionStageEvent.Stage: Int]
    var elapsedSeconds: Double

    init(
        rawASR: String,
        finalOutput: String,
        stageMilliseconds: [DictationTranscriptionStageEvent.Stage: Int] = [:],
        elapsedSeconds: Double = 0
    ) {
        self.rawASR = rawASR
        self.finalOutput = finalOutput
        self.stageMilliseconds = stageMilliseconds
        self.elapsedSeconds = elapsedSeconds
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

    func transcribe(
        _ sample: TranscriptionCorpus.Sample,
        backend: BackendOption
    ) async throws -> TranscriptionQualityTrace {
        let collector = HarnessTraceCollector()
        let startedAt = Date()
        // Every language argument is left at its shipped default (KTD5): steering one competitor
        // and not another would compare a guided model against an unguided one.
        _ = try await coordinator.transcribeDictationWithCleanupOutcome(
            at: sample.audioURL,
            backend: backend,
            enablePostProcessor: cleanupEnabled,
            traceReporter: { event in await collector.record(event) }
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        let snapshot = await collector.snapshot()
        return TranscriptionQualityTrace(
            rawASR: snapshot.artifacts[.rawASR] ?? "",
            finalOutput: snapshot.artifacts[.finalOutput] ?? "",
            stageMilliseconds: snapshot.stages,
            elapsedSeconds: elapsed
        )
    }

    func unload(_ backend: BackendOption) async {
        await coordinator.unloadTranscriber(for: backend)
    }
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
    let driver: any TranscriptionQualityDriver
    /// `nil` for audio whose duration cannot be read, which only costs the real-time factor.
    let audioDurationSeconds: @Sendable (TranscriptionCorpus.Sample) -> Double?
    let cleanupEnabled: Bool

    init(
        driver: any TranscriptionQualityDriver,
        audioDurationSeconds: @escaping @Sendable (TranscriptionCorpus.Sample) -> Double? = {
            TranscriptionQualityRunner.measuredDuration(of: $0)
        },
        cleanupEnabled: Bool = true
    ) {
        self.driver = driver
        self.audioDurationSeconds = audioDurationSeconds
        self.cleanupEnabled = cleanupEnabled
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

            if let reason = await driver.notRunnableReason(for: backend) {
                // Nothing is loaded and nothing is fetched, so there is nothing to unload either.
                record(.notRunnable(reason))
                continue
            }
            guard let warmupSample = samples.first else {
                record(.notRunnable(.noSamples))
                continue
            }

            var warmup: TranscriptionQualityRun.Warmup
            do {
                let trace = try await driver.transcribe(warmupSample, backend: backend)
                warmup = TranscriptionQualityRun.Warmup(
                    sampleID: warmupSample.id,
                    endToEndSeconds: trace.elapsedSeconds,
                    failureMessage: nil
                )
            } catch {
                // A warmup that throws still loaded the model, and one bad file must not cost the
                // backend its whole run.
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
                    let trace = try await driver.transcribe(sample, backend: backend)
                    measurements.append(measurement(for: sample, trace: trace))
                    cohorts.insert(sample.cohort)
                } catch {
                    failures.append(TranscriptionQualityRun.SampleFailure(
                        sampleID: sample.id,
                        message: error.localizedDescription
                    ))
                }
            }

            // Before the next backend loads, never after the sweep: two resident models is exactly
            // the contention R11 forbids.
            await driver.unload(backend)
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
            finalOutput: TranscriptionQuality.StageScore(
                stage: .finalOutput,
                cohort: sample.cohort,
                reference: sample.reference,
                hypothesis: trace.finalOutput
            ),
            latency: TranscriptionQualityRun.Latency(
                endToEndSeconds: trace.elapsedSeconds,
                speechRecognitionSeconds: trace.speechRecognitionSeconds,
                postRecognitionSeconds: trace.postRecognitionSeconds,
                audioDurationSeconds: audioDurationSeconds(sample)
            )
        )
    }
}
