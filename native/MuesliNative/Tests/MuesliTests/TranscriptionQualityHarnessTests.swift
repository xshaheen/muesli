import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

// MARK: - Fakes

/// A scripted stand-in for one backend. Everything the sweep guarantees — no probe on an
/// ineligible backend, unload before the next load, warmup excluded from the distribution — is an
/// ordering claim, and ordering is only assertable against a driver that records what it was asked.
private actor FakeQualityDriver: TranscriptionQualityDriver {
    enum Event: Equatable, CustomStringConvertible {
        case eligibility(String)
        case transcribe(backend: String, sample: String)
        case unload(String)

        var description: String {
            switch self {
            case let .eligibility(backend): return "eligibility:\(backend)"
            case let .transcribe(backend, sample): return "transcribe:\(backend):\(sample)"
            case let .unload(backend): return "unload:\(backend)"
            }
        }
    }

    struct Script: Sendable {
        var notRunnable: TranscriptionQualityRun.NotRunnable?
        /// `nil` echoes the sample's own reference — a perfect recognizer.
        var rawASR: String?
        /// `nil` echoes whatever `rawASR` produced — a cleanup stage that changed nothing.
        var finalOutput: String?
        var failingSampleIDs: Set<String> = []
        var elapsedSeconds: Double = 1
        var stageMilliseconds: [DictationTranscriptionStageEvent.Stage: Int] = [:]
    }

    struct ScriptedFailure: Error, LocalizedError {
        let sampleID: String
        var errorDescription: String? { "scripted failure for \(sampleID)" }
    }

    private let scripts: [String: Script]
    private let fallback: Script
    private(set) var events: [Event] = []

    init(scripts: [String: Script] = [:], fallback: Script = Script()) {
        self.scripts = scripts
        self.fallback = fallback
    }

    private func script(for backend: BackendOption) -> Script {
        scripts[backend.backend] ?? fallback
    }

    func notRunnableReason(for backend: BackendOption) -> TranscriptionQualityRun.NotRunnable? {
        events.append(.eligibility(backend.backend))
        return script(for: backend).notRunnable
    }

    func transcribe(
        _ sample: TranscriptionCorpus.Sample,
        backend: BackendOption
    ) throws -> TranscriptionQualityTrace {
        events.append(.transcribe(backend: backend.backend, sample: sample.id))
        let script = script(for: backend)
        guard !script.failingSampleIDs.contains(sample.id) else {
            throw ScriptedFailure(sampleID: sample.id)
        }
        let rawASR = script.rawASR ?? sample.reference
        return TranscriptionQualityTrace(
            rawASR: rawASR,
            finalOutput: script.finalOutput ?? rawASR,
            stageMilliseconds: script.stageMilliseconds,
            elapsedSeconds: script.elapsedSeconds
        )
    }

    func unload(_ backend: BackendOption) {
        events.append(.unload(backend.backend))
    }
}

private func harnessSample(
    _ id: String,
    cohort: TranscriptionQuality.Cohort = .english,
    reference: String = "the meeting is at nine"
) -> TranscriptionCorpus.Sample {
    TranscriptionCorpus.Sample(
        corpusID: "fake-corpus",
        id: id,
        cohort: cohort,
        // Never opened: the fake driver returns scripted text and durations are injected.
        audioURL: URL(fileURLWithPath: "/dev/null/\(id).wav"),
        reference: reference,
        durationSeconds: nil
    )
}

private func harnessRunner(
    driver: any TranscriptionQualityDriver,
    durationSeconds: Double? = 2
) -> TranscriptionQualityRunner {
    TranscriptionQualityRunner(
        driver: driver,
        audioDurationSeconds: { _ in durationSeconds }
    )
}

private func measurement(
    _ result: TranscriptionQualityRun.Result,
    backend: String
) throws -> TranscriptionQualityRun.Measurement {
    let run = try #require(result.backends.first { $0.backend == backend })
    guard case let .measured(measurement) = run.outcome else {
        Issue.record("\(backend) was not measured")
        throw ScriptedExpectationFailure()
    }
    return measurement
}

private func notRunnableReason(
    _ result: TranscriptionQualityRun.Result,
    backend: String
) throws -> TranscriptionQualityRun.NotRunnable {
    let run = try #require(result.backends.first { $0.backend == backend })
    guard case let .notRunnable(reason) = run.outcome else {
        Issue.record("\(backend) was measured but should not have been runnable")
        throw ScriptedExpectationFailure()
    }
    return reason
}

private struct ScriptedExpectationFailure: Error {}

// MARK: - Runner contract

/// The sweep's contract, proved entirely against fakes so it holds on a machine with no models and
/// no corpus. The env-gated suite below points the same sweep at real backends.
@Suite("Transcription quality runner")
struct TranscriptionQualityRunnerTests {
    // MARK: Gate (AE2b, R10)

    @Test("the gate opens only for the full maintainer configuration")
    func gateOpensForMaintainer() {
        let environment = [
            TranscriptionCorpusStore.environmentVariable: "/Users/maintainer/corpora",
            TranscriptionQualityHarnessGate.optInVariable: "1",
        ]

        #expect(TranscriptionQualityHarnessGate.denial(environment: environment) == nil)
        #expect(TranscriptionQualityHarnessGate.isEnabled(environment: environment))
    }

    @Test("a CI indicator denies the gate even with the corpus path and the opt-in both set")
    func gateDeniesUnderContinuousIntegration() {
        let maintainer = [
            TranscriptionCorpusStore.environmentVariable: "/Users/maintainer/corpora",
            TranscriptionQualityHarnessGate.optInVariable: "1",
        ]

        for indicator in TranscriptionQualityHarnessGate.continuousIntegrationVariables {
            var environment = maintainer
            environment[indicator] = "true"

            #expect(
                TranscriptionQualityHarnessGate.denial(environment: environment)
                    == .continuousIntegration(indicator)
            )
            #expect(!TranscriptionQualityHarnessGate.isEnabled(environment: environment))
        }
    }

    @Test("a CI indicator present but empty still denies")
    func gateDeniesOnBlankContinuousIntegrationValue() {
        let environment = [
            TranscriptionCorpusStore.environmentVariable: "/Users/maintainer/corpora",
            TranscriptionQualityHarnessGate.optInVariable: "1",
            "CI": "",
        ]

        #expect(
            TranscriptionQualityHarnessGate.denial(environment: environment)
                == .continuousIntegration("CI")
        )
    }

    @Test("the corpus path alone does not open the gate")
    func gateRequiresExplicitOptIn() {
        let environment = [
            TranscriptionCorpusStore.environmentVariable: "/Users/maintainer/corpora",
        ]

        #expect(TranscriptionQualityHarnessGate.denial(environment: environment) == .optInUnset)
    }

    @Test("an unrecognised opt-in value is not consent")
    func gateRejectsUnrecognisedOptIn() {
        let environment = [
            TranscriptionCorpusStore.environmentVariable: "/Users/maintainer/corpora",
            TranscriptionQualityHarnessGate.optInVariable: "yes",
        ]

        #expect(TranscriptionQualityHarnessGate.denial(environment: environment) == .optInUnset)
    }

    @Test("the opt-in alone does not open the gate, and a blank corpus path counts as unset")
    func gateRequiresCorpusPath() {
        #expect(
            TranscriptionQualityHarnessGate.denial(
                environment: [TranscriptionQualityHarnessGate.optInVariable: "1"]
            ) == .corpusDirectoryUnset
        )
        #expect(
            TranscriptionQualityHarnessGate.denial(environment: [
                TranscriptionCorpusStore.environmentVariable: "   ",
                TranscriptionQualityHarnessGate.optInVariable: "1",
            ]) == .corpusDirectoryUnset
        )
        #expect(TranscriptionQualityHarnessGate.denial(environment: [:]) == .corpusDirectoryUnset)
    }

    // MARK: Eligibility (AE6, R12, KTD8)

    @Test("a backend behind a macOS gate the host does not meet is not runnable, without probing the cache")
    func macOSGateIsReportedAndSkipsTheCacheProbe() {
        let probed = Probe()
        let reason = TranscriptionQualityEligibility.notRunnableReason(
            for: .qwen3Asr,
            hostVersion: HarnessHostOperatingSystem(major: 14, minor: 2),
            isModelAvailableLocally: { _ in
                probed.record()
                return true
            }
        )

        #expect(reason == .requiresNewerMacOS(required: 15, host: "14.2.0"))
        #expect(probed.count == 0)
        #expect(reason?.description.contains("macOS 15") == true)
    }

    @Test("every backend whose route is behind macOS 15 is gated, and the rest are not")
    func macOSGateCoversEveryGatedRoute() {
        let gated = BackendOption.all.filter {
            TranscriptionQualityEligibility.minimumMacOSMajorVersion(for: $0) == 15
        }

        #expect(Set(gated.map(\.backend)) == TranscriptionQualityEligibility.macOS15Backends)
        #expect(TranscriptionQualityEligibility.minimumMacOSMajorVersion(for: .parakeetMultilingual) == nil)
        #expect(TranscriptionQualityEligibility.minimumMacOSMajorVersion(for: .whisperTiny) == nil)
        #expect(TranscriptionQualityEligibility.minimumMacOSMajorVersion(for: .senseVoiceSmall) == nil)
    }

    @Test("a backend whose model is absent locally is not runnable")
    func absentModelIsNotRunnable() {
        let reason = TranscriptionQualityEligibility.notRunnableReason(
            for: .parakeetMultilingual,
            hostVersion: HarnessHostOperatingSystem(major: 26),
            isModelAvailableLocally: { _ in false }
        )

        #expect(reason == .modelNotDownloaded)
        #expect(reason?.description.contains("never downloads") == true)
    }

    @Test("a backend the host can run with its model present is eligible")
    func eligibleBackendHasNoReason() {
        #expect(
            TranscriptionQualityEligibility.notRunnableReason(
                for: .qwen3Asr,
                hostVersion: HarnessHostOperatingSystem(major: 15),
                isModelAvailableLocally: { _ in true }
            ) == nil
        )
    }

    @Test("backends without an automatic language option are recorded as pinned")
    func languageConfigurationNamesPinnedBackends() {
        #expect(TranscriptionQualityEligibility.languageConfiguration(for: .cohereTranscribe) == "pinned:en")
        #expect(TranscriptionQualityEligibility.languageConfiguration(for: .indicASR) == "pinned:hi")
        #expect(TranscriptionQualityEligibility.languageConfiguration(for: .parakeetMultilingual) == "automatic")
        #expect(TranscriptionQualityEligibility.languageConfiguration(for: .whisperTiny) == "automatic")
        #expect(TranscriptionQualityEligibility.languageConfiguration(for: .nemotron35Multilingual) == "automatic")
    }

    // MARK: Sweep (AE6, AE7, R11)

    @Test("a not-runnable backend is recorded with its reason, is never transcribed, and the sweep continues")
    func notRunnableBackendDoesNotStopTheSweep() async throws {
        let driver = FakeQualityDriver(scripts: [
            "qwen": .init(notRunnable: .requiresNewerMacOS(required: 15, host: "14.2.0")),
            "whisper": .init(notRunnable: .modelNotDownloaded),
        ])
        let result = await harnessRunner(driver: driver).sweep(
            backends: [.qwen3Asr, .whisperTiny, .parakeetMultilingual],
            samples: [harnessSample("s1"), harnessSample("s2")]
        )

        let qwen = try notRunnableReason(result, backend: "qwen")
        let whisper = try notRunnableReason(result, backend: "whisper")
        let parakeet = try measurement(result, backend: "fluidaudio")
        #expect(qwen == .requiresNewerMacOS(required: 15, host: "14.2.0"))
        #expect(whisper == .modelNotDownloaded)
        #expect(parakeet.samples.count == 1)

        // No transcribe and no unload for either ineligible backend: nothing was loaded, and above
        // all nothing was downloaded.
        let events = await driver.events
        #expect(events == [
            .eligibility("qwen"),
            .eligibility("whisper"),
            .eligibility("fluidaudio"),
            .transcribe(backend: "fluidaudio", sample: "s1"),
            .transcribe(backend: "fluidaudio", sample: "s2"),
            .unload("fluidaudio"),
        ])
        #expect(result.notRunnableBackends.count == 2)
        #expect(result.measuredBackends.count == 1)
    }

    @Test("each backend unloads before the next one loads, and the warmup sample is absent from the distribution")
    func backendsUnloadBeforeTheNextLoadsAndWarmupIsExcluded() async throws {
        let driver = FakeQualityDriver()
        let samples = [harnessSample("s1"), harnessSample("s2"), harnessSample("s3")]
        let result = await harnessRunner(driver: driver).sweep(
            backends: [.parakeetMultilingual, .whisperTiny],
            samples: samples
        )

        let events = await driver.events
        #expect(events == [
            .eligibility("fluidaudio"),
            .transcribe(backend: "fluidaudio", sample: "s1"),
            .transcribe(backend: "fluidaudio", sample: "s2"),
            .transcribe(backend: "fluidaudio", sample: "s3"),
            .unload("fluidaudio"),
            .eligibility("whisper"),
            .transcribe(backend: "whisper", sample: "s1"),
            .transcribe(backend: "whisper", sample: "s2"),
            .transcribe(backend: "whisper", sample: "s3"),
            .unload("whisper"),
        ])

        for backend in ["fluidaudio", "whisper"] {
            let measured = try measurement(result, backend: backend)
            #expect(measured.samples.map(\.sampleID) == ["s2", "s3"])
            #expect(measured.warmup?.sampleID == "s1")
            #expect(measured.warmup?.failureMessage == nil)
        }
    }

    @Test("a warmup that throws is reported without costing the backend its measured samples")
    func warmupFailureIsReportedSeparately() async throws {
        let driver = FakeQualityDriver(fallback: .init(failingSampleIDs: ["s1"]))
        let result = await harnessRunner(driver: driver).sweep(
            backends: [.parakeetMultilingual],
            samples: [harnessSample("s1"), harnessSample("s2")]
        )

        let measured = try measurement(result, backend: "fluidaudio")
        #expect(measured.warmup?.endToEndSeconds == nil)
        #expect(measured.warmup?.failureMessage?.contains("s1") == true)
        #expect(measured.samples.map(\.sampleID) == ["s2"])
        #expect(measured.failures.isEmpty)
    }

    @Test("a sample that throws is named as a failure and the remaining samples still measure")
    func sampleFailureIsNamed() async throws {
        let driver = FakeQualityDriver(fallback: .init(failingSampleIDs: ["s3"]))
        let result = await harnessRunner(driver: driver).sweep(
            backends: [.parakeetMultilingual],
            samples: [harnessSample("s1"), harnessSample("s2"), harnessSample("s3"), harnessSample("s4")]
        )

        let measured = try measurement(result, backend: "fluidaudio")
        #expect(measured.samples.map(\.sampleID) == ["s2", "s4"])
        #expect(measured.failures.map(\.sampleID) == ["s3"])
        #expect(measured.failures.first?.message.contains("s3") == true)
    }

    @Test("an empty corpus makes every backend not runnable rather than failing the sweep")
    func emptyCorpusIsRecordedNotRunnable() async throws {
        let driver = FakeQualityDriver()
        let result = await harnessRunner(driver: driver).sweep(
            backends: [.parakeetMultilingual],
            samples: []
        )

        let reason = try notRunnableReason(result, backend: "fluidaudio")
        let events = await driver.events
        #expect(reason == .noSamples)
        #expect(events == [.eligibility("fluidaudio")])
        #expect(result.cohortsMeasured.isEmpty)
    }

    // MARK: Stages (R7, R8)

    @Test("both stages are captured for one transcription, and a translating cleanup shows as a faithfulness delta")
    func bothStagesAreCapturedAndCleanupRegressionIsVisible() async throws {
        let arabic = "الشغل خلص امبارح"
        let driver = FakeQualityDriver(fallback: .init(
            rawASR: arabic,
            finalOutput: "the work finished yesterday"
        ))
        let result = await harnessRunner(driver: driver).sweep(
            backends: [.parakeetMultilingual],
            samples: [
                harnessSample("warmup", cohort: .egyptianArabic, reference: arabic),
                harnessSample("s2", cohort: .egyptianArabic, reference: arabic),
            ]
        )

        let sample = try #require(try measurement(result, backend: "fluidaudio").samples.first)
        #expect(sample.rawASR.stage == .rawASR)
        #expect(sample.finalOutput.stage == .finalOutput)
        // The recognizer preserved the spoken language exactly; the cleanup stage replaced it.
        #expect(sample.rawASR.faithfulness == 1)
        #expect(sample.rawASR.normalized.wer == 0)
        #expect(sample.finalOutput.faithfulness == 0)
        #expect(sample[.rawASR].faithfulness == sample.rawASR.faithfulness)

        let delta = sample.faithfulnessDelta
        #expect(delta.change == -1)
        #expect(delta.recognizerWasFaithful)
        #expect(delta.isCleanupIntroducedRegression)
        #expect(result.cohortsMeasured == [.egyptianArabic])
        #expect(result.cleanupEnabled)
    }

    @Test("a cleanup stage that changes nothing leaves faithfulness unmoved")
    func unchangedCleanupHasNoDelta() async throws {
        let driver = FakeQualityDriver()
        let result = await harnessRunner(driver: driver).sweep(
            backends: [.parakeetMultilingual],
            samples: [harnessSample("warmup"), harnessSample("s2")]
        )

        let sample = try #require(try measurement(result, backend: "fluidaudio").samples.first)
        #expect(sample.faithfulnessDelta.change == 0)
        #expect(!sample.faithfulnessDelta.isCleanupIntroducedRegression)
    }

    // MARK: Latency (R9)

    @Test("per-stage timings come from the pipeline and latency is summarised per cohort as a distribution")
    func latencyIsRecordedPerStageAndSummarisedPerCohort() async throws {
        let driver = FakeQualityDriver(fallback: .init(
            elapsedSeconds: 3,
            stageMilliseconds: [
                .speechRecognition: 1_500,
                .artifactCleanup: 20,
                .transcriptCleanup: 900,
                .finalization: 80,
            ]
        ))
        let result = await harnessRunner(driver: driver, durationSeconds: 6).sweep(
            backends: [.parakeetMultilingual],
            samples: [
                harnessSample("warmup"),
                harnessSample("s2"),
                harnessSample("s3", cohort: .arabicEnglish, reference: "نراجع the roadmap بكرة"),
            ]
        )

        let measured = try measurement(result, backend: "fluidaudio")
        let english = try #require(measured.samples.first { $0.cohort == .english })
        #expect(english.latency.endToEndSeconds == 3)
        #expect(english.latency.speechRecognitionSeconds == 1.5)
        #expect(english.latency.postRecognitionSeconds == 1)
        #expect(english.latency.realTimeFactor == 0.5)

        let distribution = try #require(measured.endToEndDistribution(in: .english))
        #expect(distribution.count == 1)
        #expect(distribution.p50 == 3)
        #expect(distribution.p95 == 3)
        #expect(measured.speechRecognitionDistribution(in: .english)?.p50 == 1.5)
        #expect(measured.realTimeFactor(in: .english) == 0.5)
        #expect(measured.cohorts == [.english, .arabicEnglish])
        // A cohort with no measured sample has no distribution rather than a p50 of zero.
        #expect(measured.endToEndDistribution(in: .egyptianArabic) == nil)
        #expect(measured.realTimeFactor(in: .egyptianArabic) == nil)
    }

    @Test("a real-time factor with no audio duration is not-applicable rather than zero")
    func realTimeFactorWithoutDurationIsNil() async throws {
        let driver = FakeQualityDriver()
        let result = await harnessRunner(driver: driver, durationSeconds: nil).sweep(
            backends: [.parakeetMultilingual],
            samples: [harnessSample("warmup"), harnessSample("s2")]
        )

        let measured = try measurement(result, backend: "fluidaudio")
        #expect(measured.samples.first?.latency.audioDurationSeconds == nil)
        #expect(measured.samples.first?.latency.realTimeFactor == nil)
        #expect(measured.realTimeFactor(in: .english) == nil)
    }

    // MARK: Reporting and isolation (KTD9)

    @Test("the summary names every backend, its language configuration, and each not-runnable reason")
    func summaryNamesEveryBackend() async {
        let driver = FakeQualityDriver(scripts: [
            "cohere": .init(notRunnable: .modelNotDownloaded),
        ])
        let result = await harnessRunner(driver: driver).sweep(
            backends: [.parakeetMultilingual, .cohereTranscribe],
            samples: [harnessSample("warmup"), harnessSample("s2")]
        )
        let summary = result.summaryLines.joined(separator: "\n")

        #expect(summary.contains("Parakeet v3"))
        #expect(summary.contains("Cohere Transcribe"))
        #expect(summary.contains("pinned:en"))
        #expect(summary.contains("not runnable"))
        #expect(summary.contains("cleanup stage: enabled"))
        #expect(summary.contains("english"))
    }

    @Test("the scratch support directory redirects both app-identity variables inside itself")
    func scratchSupportDirectoryIsSelfContained() {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let directory = TranscriptionQualityScratchSupportDirectory.url(root: root, runID: "run-1")
        let overrides = TranscriptionQualityScratchSupportDirectory.environmentOverrides(at: directory)

        #expect(directory.path == "/tmp/muesli-asr-harness/run-1")
        #expect(overrides[TranscriptionQualityScratchSupportDirectory.supportDirectoryVariable] == directory.path)
        // The database must land inside the scratch directory, not merely beside the real one.
        #expect(
            overrides[TranscriptionQualityScratchSupportDirectory.databasePathVariable]
                == "/tmp/muesli-asr-harness/run-1/muesli.db"
        )
        #expect(overrides.count == 2)
    }
}

/// Counts calls from a `@Sendable` closure without an actor hop, so an assertion can say a probe
/// never happened.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func record() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

// MARK: - The measurement run

/// The real sweep. Loads real ASR models and reads a real corpus, so it runs only for a maintainer
/// who has both and has asked for it — never in CI (R10). `WhisperBiasingManualReproTests` is the
/// precedent for the suite trait; the gate itself is a pure function so its CI-denial branch is
/// proved above rather than assumed here.
@Suite(
    "Transcription quality measurement harness",
    .serialized,
    .enabled(
        if: TranscriptionQualityHarnessGate.isEnabled(),
        """
        Requires MUESLI_ASR_CORPUS_DIR pointing at a local corpus store and MUESLI_ASR_HARNESS=1, \
        and refuses to run when CI or GITHUB_ACTIONS is present.
        """
    )
)
struct TranscriptionQualityHarnessTests {
    @Test("measures every eligible backend across every locally-stored corpus")
    func measureEveryEligibleBackend() async throws {
        // KTD9: the run must not be able to reach the maintainer's real database or config.
        let scratch = try TranscriptionQualityScratchSupportDirectory.activate()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let store = TranscriptionCorpusStore.discover()
        for refusal in store.refusals {
            print("[asr-harness] refused corpus — \(refusal.description)")
        }
        for corpus in store.corpora {
            print(
                "[asr-harness] corpus \(corpus.id) rev \(corpus.descriptor.revision): "
                    + "\(corpus.samples.count) usable, \(corpus.issues.count) unusable"
            )
        }
        // R4/AE3: an incomplete acquisition narrows the result, it does not invalidate it.
        if !store.uncoveredCohorts.isEmpty {
            print("[asr-harness] no data for: \(store.uncoveredCohorts.map(\.rawValue).joined(separator: ", "))")
        }
        try #require(!store.isEmpty, "the corpus store holds no evaluable corpus")
        try #require(!store.samples.isEmpty, "the corpus store holds no usable sample")

        let runner = TranscriptionQualityRunner(
            driver: LiveTranscriptionQualityDriver(coordinator: TranscriptionCoordinator())
        )
        let result = await runner.sweep(backends: BackendOption.all, samples: store.samples)

        for line in result.summaryLines {
            print("[asr-harness] \(line)")
        }
        #expect(!result.measuredBackends.isEmpty, "no backend on this host was runnable")
    }
}
