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
        /// `true` models a pipeline that reported no final-output artifact at all, which is not the
        /// same as a cleanup stage that produced the same text.
        var omitsFinalOutput = false
        /// What the pipeline says the cleanup stage did. Anything but `.applied` means the final
        /// text is not cleanup's product.
        var cleanupOutcome: DictationCleanupOutcome? = .applied
        var failingSampleIDs: Set<String> = []
        /// Samples the driver never returns from, so the sweep's own budget is what ends the wait.
        var hangingSampleIDs: Set<String> = []
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
    ) async throws -> TranscriptionQualityTrace {
        events.append(.transcribe(backend: backend.backend, sample: sample.id))
        let script = script(for: backend)
        guard !script.failingSampleIDs.contains(sample.id) else {
            throw ScriptedFailure(sampleID: sample.id)
        }
        if script.hangingSampleIDs.contains(sample.id) {
            // Long enough that only the sweep's budget can end this; the sleep is cancelled with
            // the task group, so the test does not actually wait.
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            try Task.checkCancellation()
        }
        let rawASR = script.rawASR ?? sample.reference
        return TranscriptionQualityTrace(
            rawASR: rawASR,
            finalOutput: script.omitsFinalOutput ? nil : (script.finalOutput ?? rawASR),
            cleanupOutcome: script.cleanupOutcome,
            stageMilliseconds: script.stageMilliseconds,
            elapsedSeconds: script.elapsedSeconds
        )
    }

    func unload(_ backend: BackendOption) {
        events.append(.unload(backend.backend))
    }
}

/// The Qwen3 catalogue entry as it stood for the 21-08-2026 run, kept only so these
/// tests can still describe a sweep that measured it. Qwen3 was removed from
/// `BackendOption.all`, but the committed receipt fixture carries its rows, so the
/// harness must go on being able to express a historical run that included it.
private let historicalQwen3Asr = BackendOption(
    backend: "qwen",
    model: "FluidInference/qwen3-asr-0.6b-coreml",
    label: "Qwen3 ASR",
    sizeLabel: "~1.3 GB",
    description: "Removed after the 21-08-2026 measurement run.",
    recommended: false
)

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
    durationSeconds: Double? = 2,
    sampleTimeoutSeconds: Double = TranscriptionQualityRunner.defaultSampleTimeoutSeconds,
    warmupTimeoutSeconds: Double = TranscriptionQualityRunner.defaultWarmupTimeoutSeconds
) -> TranscriptionQualityRunner {
    TranscriptionQualityRunner(
        driver: driver,
        audioDurationSeconds: { _ in durationSeconds },
        sampleTimeoutSeconds: sampleTimeoutSeconds,
        warmupTimeoutSeconds: warmupTimeoutSeconds,
        // These suites fail samples on purpose; a real sweep's live narration would be noise here.
        log: { _ in }
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

/// Pinned rather than `.current()` so the mapping assertions do not depend on the machine running
/// them. A real run records the real host; this only has to be a value the mapping copies through.
private let testReceiptHost = TranscriptionQualityReceipt.Host(
    operatingSystemVersion: "26.0.0",
    machineModel: "Mac16,10",
    architecture: "Apple M4",
    processorCount: 10,
    physicalMemoryBytes: 17_179_869_184
)

/// A corpus store built in memory. `TranscriptionCorpus.Descriptor` is `Decodable` only — it is the
/// on-disk record and has no memberwise init on purpose — so the descriptor is decoded from the same
/// JSON shape a real corpus directory holds.
private func harnessStore(
    corpusID: String = "fake-corpus",
    revision: String = "rev-1",
    licence: String? = "CC-BY-4.0",
    cohort: TranscriptionQuality.Cohort = .english,
    samples: [TranscriptionCorpus.Sample],
    issues: Int = 0
) throws -> TranscriptionCorpusStore {
    let licenceField = licence.map {
        """
        "licence": {"identifier": "\($0)", "sourceURL": "https://example.invalid/licence"},
        """
    } ?? ""
    let descriptorJSON = """
    {
      "schemaVersion": 1,
      "id": "\(corpusID)",
      "revision": "\(revision)",
      \(licenceField)
      "acquisition": "hugging-face",
      "cohort": "\(cohort.rawValue)",
      "sampleIndex": "samples.jsonl"
    }
    """
    let descriptor = try JSONDecoder().decode(
        TranscriptionCorpus.Descriptor.self,
        from: Data(descriptorJSON.utf8)
    )
    return TranscriptionCorpusStore(
        root: URL(fileURLWithPath: "/dev/null/corpora"),
        corpora: [TranscriptionCorpus(
            directoryName: corpusID,
            directory: URL(fileURLWithPath: "/dev/null/corpora/\(corpusID)"),
            descriptor: descriptor,
            samples: samples,
            issues: (0 ..< issues).map {
                TranscriptionCorpus.Issue(sampleID: "bad-\($0)", reason: .emptyReference)
            }
        )],
        refusals: []
    )
}

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
            for: .cohereTranscribe,
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
                for: .cohereTranscribe,
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

    /// A6/R17. An English-only checkpoint has no detection step, so `automatic` would present it as
    /// a candidate for the Arabic cohorts and then charge its certain failure there to the model.
    @Test("English-only checkpoints are recorded as pinned English, not as automatic")
    func englishOnlyBackendsAreReportedAsPinned() {
        for backend in [
            BackendOption.parakeetEnglish,
            .whisperTinyEnglish,
            .whisperSmallEnglish,
            .whisperMediumEnglish,
        ] {
            #expect(TranscriptionQualityEligibility.isEnglishOnly(backend), "\(backend.label)")
            #expect(
                TranscriptionQualityEligibility.languageConfiguration(for: backend) == "pinned:en",
                "\(backend.label)"
            )
            // The point of recording it: the receipt's targetability follows from this string.
            let language = TranscriptionQualityLanguageConfiguration(rawValue: "pinned:en")
            #expect(language.canTarget(.english))
            #expect(!language.canTarget(.egyptianArabic))
            #expect(!language.canTarget(.arabicEnglish))
        }
    }

    /// Every backend in the inventory gets a deliberate answer, so adding one to `BackendOption.all`
    /// without classifying it fails here rather than silently defaulting to `automatic`.
    @Test("every shipped backend has a reviewed language configuration")
    func everyBackendHasAReviewedLanguageConfiguration() throws {
        let expected: [String: String] = [
            "FluidInference/parakeet-tdt-0.6b-v3-coreml": "automatic",
            "FluidInference/parakeet-tdt-0.6b-v2-coreml": "pinned:en",
            "tiny": "automatic",
            "tiny.en": "pinned:en",
            "small": "automatic",
            "small.en": "pinned:en",
            "medium.en": "pinned:en",
            "large-v3-v20240930_626MB": "automatic",
            "phequals/cohere-transcribe-coreml-mixed-precision": "pinned:en",
            "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML": "automatic",
            "FluidInference/sensevoice-small-coreml": "automatic",
            "phequals/indic-conformer-600m-multilingual-coreml-rnnt": "pinned:hi",
        ]
        for backend in BackendOption.all {
            // Gemma is keyed off its store's repo id, which is resolved rather than literal.
            let want = backend.backend == "gemma4-litert"
                ? "automatic"
                : try #require(expected[backend.model], "unclassified backend \(backend.model)")
            #expect(
                TranscriptionQualityEligibility.languageConfiguration(for: backend) == want,
                "\(backend.label) [\(backend.model)]"
            )
        }
    }

    // MARK: Sweep (AE6, AE7, R11)

    @Test("a not-runnable backend is recorded with its reason, is never transcribed, and the sweep continues")
    func notRunnableBackendDoesNotStopTheSweep() async throws {
        let driver = FakeQualityDriver(scripts: [
            "qwen": .init(notRunnable: .requiresNewerMacOS(required: 15, host: "14.2.0")),
            "whisper": .init(notRunnable: .modelNotDownloaded),
        ])
        let result = await harnessRunner(driver: driver).sweep(
            backends: [historicalQwen3Asr, .whisperTiny, .parakeetMultilingual],
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
        #expect(sample.measuredFinalOutput?.stage == .finalOutput)
        // The recognizer preserved the spoken language exactly; the cleanup stage replaced it.
        #expect(sample.rawASR.faithfulness == 1)
        #expect(sample.rawASR.normalized.wer == 0)
        #expect(sample.measuredFinalOutput?.faithfulness == 0)
        #expect(sample[.rawASR]?.faithfulness == sample.rawASR.faithfulness)

        let delta = try #require(sample.faithfulnessDelta)
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
        let delta = try #require(sample.faithfulnessDelta)
        #expect(delta.change == 0)
        #expect(!delta.isCleanupIntroducedRegression)
    }

    // MARK: Cleanup execution (A4)

    /// The inversion this harness cannot afford: cleanup is configured on, the pipeline skips it,
    /// and the final stage — the raw text after artifact cleanup — scores identically to `rawASR`.
    /// Read as a cleanup measurement that is "cleanup changed nothing", which is the opposite of
    /// what happened.
    @Test("a sample whose cleanup did not run carries no faithfulness delta and no measured final stage")
    func skippedCleanupIsNotReportedAsAnUnchangedCleanup() async throws {
        let arabic = "الشغل خلص امبارح"
        let driver = FakeQualityDriver(fallback: .init(
            rawASR: arabic,
            cleanupOutcome: .skippedUnavailable
        ))
        let result = await harnessRunner(driver: driver).sweep(
            backends: [.parakeetMultilingual],
            samples: [
                harnessSample("warmup", cohort: .egyptianArabic, reference: arabic),
                harnessSample("s2", cohort: .egyptianArabic, reference: arabic),
            ]
        )

        let measured = try measurement(result, backend: "fluidaudio")
        let sample = try #require(measured.samples.first)
        #expect(sample.cleanup == .notPerformed(outcome: "skipped_unavailable"))
        #expect(!sample.cleanup.didRun)
        #expect(sample.measuredFinalOutput == nil)
        // Zero here would be the false reassurance; not-applicable is the honest answer.
        #expect(sample.faithfulnessDelta == nil)
        #expect(measured.cleanupAppliedCount == 0)
        #expect(measured.meanFaithfulness(in: .egyptianArabic, at: .finalOutput) == nil)
        #expect(measured.meanFaithfulness(in: .egyptianArabic, at: .rawASR) == 1)
        #expect(measured.cleanupNotPerformedCounts.map(\.count) == [1])
        // The maintainer watching the sweep is told, not left to infer it from a suspicious zero.
        #expect(result.summaryLines.joined(separator: "\n").contains("skipped_unavailable"))
    }

    @Test("an absent final-output artifact is scored as nothing produced, never mirrored from raw ASR")
    func absentFinalArtifactIsNotMirroredFromRawASR() async throws {
        let arabic = "الشغل خلص امبارح"
        let driver = FakeQualityDriver(fallback: .init(rawASR: arabic, omitsFinalOutput: true))
        let result = await harnessRunner(driver: driver).sweep(
            backends: [.parakeetMultilingual],
            samples: [
                harnessSample("warmup", cohort: .egyptianArabic, reference: arabic),
                harnessSample("s2", cohort: .egyptianArabic, reference: arabic),
            ]
        )

        let sample = try #require(try measurement(result, backend: "fluidaudio").samples.first)
        #expect(sample.cleanup == .notReported)
        #expect(sample.measuredFinalOutput == nil)
        #expect(sample.faithfulnessDelta == nil)
        // Mirroring would have made this a perfect Arabic transcription.
        #expect(sample.rawASR.normalized.wer == 0)
        #expect(sample.pipelineFinalOutput.normalized.wer == 1)
    }

    @Test("a cleanup that ran is still reported as measured with its delta")
    func appliedCleanupKeepsItsDelta() async throws {
        let driver = FakeQualityDriver(fallback: .init(cleanupOutcome: .applied))
        let result = await harnessRunner(driver: driver).sweep(
            backends: [.parakeetMultilingual],
            samples: [harnessSample("warmup"), harnessSample("s2")]
        )

        let measured = try measurement(result, backend: "fluidaudio")
        let sample = try #require(measured.samples.first)
        #expect(sample.cleanup == .applied)
        #expect(sample.measuredFinalOutput != nil)
        #expect(sample.faithfulnessDelta?.change == 0)
        #expect(measured.cleanupAppliedCount == 1)
    }

    // MARK: Empty measurement (A3)

    /// A corpus of one sample spends it on the cold start, so nothing is ever scored. Recorded as
    /// `.measured` this backend would enter the receipt looking like a result whose cohort figures
    /// merely happen to be absent.
    @Test("a backend that scored nothing is not runnable rather than measured")
    func backendWithNoScoredSamplesIsNotMeasured() async throws {
        let driver = FakeQualityDriver()
        let result = await harnessRunner(driver: driver).sweep(
            backends: [.parakeetMultilingual],
            samples: [harnessSample("only")]
        )

        let reason = try notRunnableReason(result, backend: "fluidaudio")
        #expect(reason == .noMeasuredSamples(failures: []))
        #expect(reason.description.contains("cold start"))
        #expect(result.measuredBackends.isEmpty)
        // The model was loaded by the warmup, so it still has to be unloaded before the next one.
        let events = await driver.events
        #expect(events.contains(.unload("fluidaudio")))
    }

    /// The reason has to travel with the ids. Naming the samples alone is what made a real sweep
    /// undiagnosable: four backends failed every sample and the artifact could not say whether the
    /// file was missing, the model unloaded, or the decoder wedged.
    @Test("a backend whose every sample failed is not runnable and names the failures and why")
    func backendWhoseSamplesAllFailedIsNotMeasured() async throws {
        let driver = FakeQualityDriver(fallback: .init(failingSampleIDs: ["s2", "s3"]))
        let result = await harnessRunner(driver: driver).sweep(
            backends: [.parakeetMultilingual],
            samples: [harnessSample("s1"), harnessSample("s2"), harnessSample("s3")]
        )

        let reason = try notRunnableReason(result, backend: "fluidaudio")
        #expect(reason == .noMeasuredSamples(failures: [
            TranscriptionQualityRun.SampleFailure(sampleID: "s2", message: "scripted failure for s2"),
            TranscriptionQualityRun.SampleFailure(sampleID: "s3", message: "scripted failure for s3"),
        ]))
        #expect(reason.description.contains("s2"))
        #expect(reason.description.contains("s3"))
        #expect(reason.description.contains("scripted failure"))
        #expect(result.measuredBackends.isEmpty)
    }

    /// The other half of the same defect: the sweep used to say nothing at all until it ended, so an
    /// hour-long run gave a maintainer no way to tell a broken backend from a slow one.
    @Test("each failure is narrated while the sweep runs, not only in the closing summary")
    func failuresAreNarratedLive() async throws {
        let recorded = LineRecorder()
        let driver = FakeQualityDriver(fallback: .init(failingSampleIDs: ["s2"]))
        let runner = TranscriptionQualityRunner(
            driver: driver,
            audioDurationSeconds: { _ in 2 },
            log: { recorded.record($0) }
        )

        let result = await runner.sweep(
            backends: [.parakeetMultilingual],
            samples: [harnessSample("s1"), harnessSample("s2"), harnessSample("s3")]
        )

        let live = recorded.lines.joined(separator: "\n")
        #expect(live.contains("s2 failed — scripted failure for s2"))
        #expect(live.contains("Parakeet v3"))
        // And the closing summary carries the reason too, not merely a count.
        #expect(result.summaryLines.joined(separator: "\n").contains("scripted failure for s2"))
    }

    // MARK: Timeout (A7)

    /// A hung model would otherwise hold an hour-long sweep open with nothing on stderr to say so.
    @Test("a transcription that outruns its budget is a named per-sample failure, not a stalled sweep")
    func hungSampleTimesOutAndTheSweepContinues() async throws {
        let driver = FakeQualityDriver(fallback: .init(hangingSampleIDs: ["s2"]))
        let result = await harnessRunner(
            driver: driver,
            sampleTimeoutSeconds: 0.05
        ).sweep(
            backends: [.parakeetMultilingual],
            samples: [harnessSample("s1"), harnessSample("s2"), harnessSample("s3")]
        )

        let measured = try measurement(result, backend: "fluidaudio")
        #expect(measured.failures.map(\.sampleID) == ["s2"])
        #expect(measured.failures.first?.message.contains("budget") == true)
        // The sample after the hung one still measures: the budget cost one sample, not the sweep.
        #expect(measured.samples.map(\.sampleID) == ["s3"])
    }

    @Test("a warmup that outruns its own budget costs the warmup, not the backend")
    func hungWarmupIsReportedWithoutLosingTheBackend() async throws {
        let driver = FakeQualityDriver(fallback: .init(hangingSampleIDs: ["s1"]))
        let result = await harnessRunner(
            driver: driver,
            warmupTimeoutSeconds: 0.05
        ).sweep(
            backends: [.parakeetMultilingual],
            samples: [harnessSample("s1"), harnessSample("s2")]
        )

        let measured = try measurement(result, backend: "fluidaudio")
        #expect(measured.warmup?.endToEndSeconds == nil)
        #expect(measured.warmup?.failureMessage?.contains("budget") == true)
        #expect(measured.samples.map(\.sampleID) == ["s2"])
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

    /// A5. The old `activate` wrote both variables into the process with `setenv` and never restored
    /// them, so every later suite in the same `swift test` process inherited a deleted temporary
    /// directory as its support path — and the write raced any concurrent `getenv`.
    @Test("preparing the scratch directory leaves the process environment untouched")
    func scratchDirectoryPreparationDoesNotMutateTheEnvironment() throws {
        let variables = [
            TranscriptionQualityScratchSupportDirectory.supportDirectoryVariable,
            TranscriptionQualityScratchSupportDirectory.databasePathVariable,
        ]
        let before = variables.map { ProcessInfo.processInfo.environment[$0] }

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = try TranscriptionQualityScratchSupportDirectory.prepare(
            root: root,
            runID: "environment-untouched-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(variables.map { ProcessInfo.processInfo.environment[$0] } == before)
    }

    /// The isolation claim has to be honest about what it cannot cover: the app target resolves its
    /// support directory through `AppIdentity`/`Info.plist`, never through these variables, so the
    /// one in-process write into the real support directory is reported instead of assumed away.
    @Test("run artifacts land outside the scratch directory, and an explicit path wins")
    func harnessOutputDirectoryIsDurable() throws {
        let root = URL(fileURLWithPath: "/tmp/root", isDirectory: true)
        let scratch = TranscriptionQualityScratchSupportDirectory.url(root: root, runID: "run-1")

        let fallback = TranscriptionQualityHarnessOutput.directory(defaultRoot: root, environment: [:])
        // The scratch directory is deleted when the run ends; the receipt must not be inside it.
        #expect(!fallback.path.hasPrefix(scratch.path))
        #expect(fallback.path == "/tmp/root/muesli-asr-harness-receipts")

        let configured = TranscriptionQualityHarnessOutput.directory(
            defaultRoot: root,
            environment: [TranscriptionQualityHarnessOutput.directoryVariable: "/tmp/keep"]
        )
        #expect(configured.path == "/tmp/keep")
        // A blank value is not a path.
        #expect(TranscriptionQualityHarnessOutput.directory(
            defaultRoot: root,
            environment: [TranscriptionQualityHarnessOutput.directoryVariable: "  "]
        ) == fallback)
    }

    // MARK: Receipt mapping (U6)

    /// The one bridge from a measured sweep to the committed artifact. Every well-tested piece
    /// downstream of it — the gate, the pooled ranking, the bootstrap, the Qwen3 verdict, the
    /// renderer — is fed hand-built receipts, so a mapping defect here would surface for the first
    /// time on the one real hour-long run this harness exists to produce.
    @Test("a completed sweep maps into the receipt it commits, field for field")
    func sweepMapsIntoTheCommittedReceipt() async throws {
        let arabic = "الشغل خلص امبارح"
        let driver = FakeQualityDriver(
            scripts: [
                "qwen": .init(notRunnable: .requiresNewerMacOS(required: 15, host: "14.2.0")),
                "fluidaudio": .init(failingSampleIDs: ["s3"], elapsedSeconds: 0.4),
            ],
            fallback: .init(notRunnable: .modelNotDownloaded)
        )
        let samples = [
            harnessSample("warmup", cohort: .egyptianArabic, reference: arabic),
            harnessSample("s2", cohort: .egyptianArabic, reference: arabic),
            harnessSample("s3", cohort: .egyptianArabic, reference: arabic),
            harnessSample("s4", cohort: .english),
        ]
        let store = try harnessStore(cohort: .egyptianArabic, samples: samples, issues: 2)

        let result = await harnessRunner(driver: driver, durationSeconds: 3).sweep(
            backends: [.parakeetMultilingual, historicalQwen3Asr],
            samples: samples
        )
        let receipt = result.receipt(
            runID: "mapping",
            generatedAt: Date(timeIntervalSince1970: 0),
            host: testReceiptHost,
            store: store,
            notes: ["mapped from a fake driver"]
        )

        // Corpus identity travels from the store, not from the sweep.
        let corpus = try #require(receipt.corpora.first)
        #expect(corpus.id == "fake-corpus")
        #expect(corpus.revision == "rev-1")
        #expect(corpus.licenceIdentifier == "CC-BY-4.0")
        #expect(corpus.acquisition == "hugging-face")
        #expect(corpus.sampleCount == 4)
        #expect(corpus.issueCount == 2)
        // Canonical order, not the order the samples happened to arrive in.
        #expect(corpus.cohorts == [.english, .egyptianArabic])

        let parakeet = try #require(receipt.backends.first { $0.backend == "fluidaudio" })
        #expect(parakeet.isRunnable)
        #expect(parakeet.identity == "fluidaudio/\(BackendOption.parakeetMultilingual.model)")
        #expect(parakeet.languageConfiguration == "automatic")
        // The cold start is recorded and is absent from every cohort figure.
        #expect(parakeet.warmup?.sampleID == "warmup")
        #expect(parakeet.warmup?.didFail == false)
        #expect(parakeet.failedSampleIDs == ["s3"])
        // And why, so a sweep with a failed sample is diagnosable from the artifact alone.
        #expect(parakeet.failures.first?.reason.contains("scripted failure for s3") == true)
        #expect(parakeet.cohorts.map(\.cohort) == [.english, .egyptianArabic])
        let arabicCohort = try #require(parakeet.result(for: .egyptianArabic))
        #expect(arabicCohort.utterances.map(\.sampleID) == ["s2"])
        #expect(arabicCohort.utterances.map(\.corpusID) == ["fake-corpus"])
        let utterance = try #require(arabicCohort.utterances.first)
        #expect(utterance.audioDurationSeconds == 3)
        #expect(abs(utterance.endToEndSeconds - 0.4) < 1e-12)
        // The fake echoes the reference, so this is a perfect transcription at both stages.
        #expect(utterance.rawASR.normalizedWER == 0)
        #expect(utterance.finalOutput?.normalizedWER == 0)

        // R12: the ineligible backend is a coded reason and no cohorts, never a row of zeros.
        let qwen = try #require(receipt.backends.first { $0.backend == "qwen" })
        #expect(!qwen.isRunnable)
        #expect(qwen.notRunnable == TranscriptionQualityReceipt.NotRunnable(
            code: .requiresNewerMacOS,
            requiredMacOSMajorVersion: 15,
            hostOperatingSystemVersion: "14.2.0"
        ))
        #expect(qwen.cohorts.isEmpty)
        #expect(qwen.notRunnableDescription?.contains("requires macOS 15") == true)

        #expect(receipt.disclosures.cleanupRequested)
        #expect(receipt.disclosures.cleanupAppliedUtterances == 2)
        #expect(receipt.disclosures.cleanupNotPerformed.isEmpty)
        #expect(receipt.disclosures.notes == ["mapped from a fake driver"])

        // R2, end to end: the reference the sweep scored against is nowhere in the artifact.
        let encoded = try JSONEncoder().encode(receipt)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains(arabic))
        #expect(!json.contains("the meeting is at nine"))
        // And the artifact the maintainer reads renders from it.
        #expect(TranscriptionQualityReport.markdown(for: receipt).contains("## Cohort: egyptian-arabic"))
    }

    /// A3's state, carried through the mapping: the reason is a code, and the ids and messages it
    /// used to spell out in prose land in the field that holds them.
    @Test("a backend that scored nothing maps to a coded reason carrying its failures and their reasons")
    func noMeasuredSamplesMapsToACodeAndItsIDs() async throws {
        let driver = FakeQualityDriver(fallback: .init(failingSampleIDs: ["s2", "s3"]))
        let samples = [harnessSample("s1"), harnessSample("s2"), harnessSample("s3")]
        let result = await harnessRunner(driver: driver).sweep(
            backends: [.parakeetMultilingual],
            samples: samples
        )

        let receipt = result.receipt(store: try harnessStore(samples: samples), notes: [])
        let backend = try #require(receipt.backends.first)

        #expect(backend.notRunnable?.code == .noMeasuredSamples)
        #expect(backend.failedSampleIDs == ["s2", "s3"])
        #expect(backend.notRunnableDescription?.contains("s2, s3") == true)
        // The reason a maintainer actually needs: not which samples, but why all of them.
        #expect(backend.failures.map(\.reason) == ["scripted failure for s2", "scripted failure for s3"])
        #expect(backend.notRunnableDescription?.contains("scripted failure for s2") == true)
        // The ids reach the reader through the rendered sentence, not through a stored one.
        let json = try #require(String(data: try JSONEncoder().encode(receipt), encoding: .utf8))
        #expect(!json.contains("every sample failed"))
        // And the document a maintainer reads says it, rather than only naming the samples.
        let report = TranscriptionQualityReport.markdown(for: receipt)
        #expect(report.contains("## Not runnable on this host"))
        #expect(report.contains("scripted failure for s2"))
    }

    /// A4's state, carried through the mapping: the pipeline returned a final text, cleanup did not
    /// produce it, and the receipt says so with an absent stage rather than with a figure that reads
    /// as an unchanged one.
    @Test("a cleanup the pipeline skipped maps to an absent final stage and a stated skip count")
    func skippedCleanupMapsToAnAbsentFinalStage() async throws {
        let arabic = "الشغل خلص امبارح"
        let driver = FakeQualityDriver(fallback: .init(
            rawASR: arabic,
            cleanupOutcome: .skippedUnavailable
        ))
        let samples = [
            harnessSample("warmup", cohort: .egyptianArabic, reference: arabic),
            harnessSample("s2", cohort: .egyptianArabic, reference: arabic),
        ]
        let result = await harnessRunner(driver: driver).sweep(
            backends: [.parakeetMultilingual],
            samples: samples
        )

        let receipt = result.receipt(store: try harnessStore(cohort: .egyptianArabic, samples: samples))
        let cohort = try #require(receipt.backends.first?.result(for: .egyptianArabic))

        #expect(cohort.sampleCount == 1)
        #expect(cohort.measuredCount(at: .finalOutput) == 0)
        #expect(cohort.utterances.first?.finalOutput == nil)
        // Mirrored or scored anyway, this would have read as a cleanup that changed nothing.
        #expect(cohort.pooledNormalizedWER(at: .finalOutput) == nil)
        #expect(cohort.pooledNormalizedWER(at: .rawASR) == 0)

        #expect(receipt.disclosures.cleanupRequested)
        #expect(!receipt.disclosures.cleanupApplied)
        #expect(receipt.disclosures.cleanupNotPerformed
            == [TranscriptionQualityReceipt.CleanupSkip(
                reason: "not performed (skipped_unavailable)",
                utterances: 1
            )])
        #expect(TranscriptionQualityReport.markdown(for: receipt)
            .contains("**requested, and never applied**"))
    }

    /// The not-applicable half of A2 through the mapping: a reference with nothing script-bearing in
    /// it carries no faithfulness, and the receipt records its absence rather than a passing 1.
    @Test("a reference with no script-bearing token maps to an absent faithfulness")
    func notApplicableFaithfulnessMapsToNil() async throws {
        let driver = FakeQualityDriver()
        let samples = [harnessSample("warmup", reference: "123"), harnessSample("s2", reference: "123")]
        let result = await harnessRunner(driver: driver).sweep(
            backends: [.parakeetMultilingual],
            samples: samples
        )

        let receipt = result.receipt(store: try harnessStore(samples: samples))
        let cohort = try #require(receipt.backends.first?.result(for: .english))

        #expect(cohort.utterances.first?.rawASR.faithfulness == nil)
        #expect(cohort.meanFaithfulness(at: .rawASR) == nil)
        // And the policy therefore has nothing to gate on.
        let decision = try #require(TranscriptionQualityDecision.evaluate(receipt).cohorts.first)
        #expect(decision.ranking.isEmpty)
        #expect(decision.absent.first?.reason.contains("not applicable") == true)
    }

    @Test("transcript-bearing pair logging is reported as a write the scratch directory cannot contain")
    func pairLoggingIsReportedAsAWriteHazard() {
        #expect(TranscriptionQualityScratchSupportDirectory.writeHazards(environment: [:]).isEmpty)
        #expect(
            TranscriptionQualityScratchSupportDirectory.writeHazards(environment: [
                "MUESLI_LOG_POSTPROC_PAIRS": "1",
            ]).isEmpty
        )
        let hazards = TranscriptionQualityScratchSupportDirectory.writeHazards(environment: [
            "MUESLI_DEBUG_POSTPROC_LOGS": "1",
            "MUESLI_LOG_POSTPROC_PAIRS": "1",
        ])
        #expect(hazards.count == 1)
        #expect(hazards[0].contains("postproc-pairs.jsonl"))
    }
}

/// Collects the sweep's live narration from a `@Sendable` closure, so an assertion can say what a
/// maintainer would have seen while the run was still going.
private final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ line: String) {
        lock.lock()
        recorded.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
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
        // KTD9: the run must not be able to reach the maintainer's real database or config. The
        // sweep constructs only a `TranscriptionCoordinator`, which opens no store — the one write
        // into the real support directory it can still make is the opt-in pair log, and that is a
        // hard refusal rather than a silent leak of transcript text.
        let hazards = TranscriptionQualityScratchSupportDirectory.writeHazards()
        try #require(hazards.isEmpty, "\(hazards.joined(separator: "; "))")
        let scratch = try TranscriptionQualityScratchSupportDirectory.prepare()
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

        // U6 needs an artifact, not scrollback. Building it here means the sweep that produces the
        // numbers is the same run that exercises the mapping, the decision policy and the renderer —
        // rather than leaving the serialization step to be written afterwards, under time pressure,
        // with the models already unloaded.
        let receipt = result.receipt(store: store)
        let decisions = TranscriptionQualityDecision.evaluate(receipt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Deliberately outside the scratch directory, which is deleted when this test ends: an
        // hour-long run whose only artifact is removed on the way out has produced scrollback again.
        let outputDirectory = TranscriptionQualityHarnessOutput.directory()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let receiptURL = outputDirectory.appendingPathComponent("run-\(receipt.runID).json")
        let reportURL = outputDirectory.appendingPathComponent("run-\(receipt.runID).md")
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        try Data(TranscriptionQualityReport.markdown(for: receipt, decisions: decisions).utf8)
            .write(to: reportURL, options: .atomic)

        print("[asr-harness] receipt: \(receiptURL.path)")
        print("[asr-harness] report:  \(reportURL.path)")
        for cohort in decisions.cohorts {
            let leaders = cohort.leaders.isEmpty ? "no eligible backend" : cohort.leaders.joined(separator: ", ")
            print("[asr-harness] \(cohort.cohort.rawValue): \(leaders)")
        }
        print("[asr-harness] qwen3: \(decisions.qwen3.decision.rawValue) — \(decisions.qwen3.rationale)")

        // The mapping ran on real measurements, so the receipt has to carry them: a backend the
        // sweep measured must arrive with at least one cohort of utterances.
        #expect(receipt.backends.count == result.backends.count)
        #expect(receipt.backends.contains { !$0.cohorts.isEmpty })
    }
}

/// Where a real run leaves its receipt and report.
///
/// Never the run's scratch support directory: that one is deleted when the test ends, and an artifact
/// deleted on the way out is scrollback with extra steps. Pure, so the resolution is assertable
/// without a run.
enum TranscriptionQualityHarnessOutput {
    static let directoryVariable = "MUESLI_ASR_HARNESS_OUT"

    static func directory(
        defaultRoot: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let configured = environment[directoryVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configured, !configured.isEmpty else {
            return defaultRoot
                .appendingPathComponent("muesli-asr-harness-receipts", isDirectory: true)
        }
        return URL(fileURLWithPath: configured, isDirectory: true)
    }
}
