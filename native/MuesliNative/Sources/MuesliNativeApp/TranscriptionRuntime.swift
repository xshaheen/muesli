import FluidAudio
import Foundation
import MuesliCore

struct SpeechSegment: Sendable {
    let start: Double
    let end: Double
    let text: String
}

struct SpeechTranscriptionResult: Sendable {
    let text: String
    let segments: [SpeechSegment]
}

actor TranscriptionCoordinator {
    typealias DiarizerModelLoader = @Sendable (DiarizerRuntimePolicy) async throws -> DiarizerModels
    typealias VADLoader = @Sendable () async throws -> VadManager

    private enum DiarizerLoadWaitOutcome {
        case succeeded
        case failed
        case cancelled
        case timedOut
    }

    private struct DiarizerLoadWaiter {
        let continuation: CheckedContinuation<DiarizerLoadWaitOutcome, Never>
        let timeoutTask: Task<Void, Never>
    }

    // Product flows stop waiting after two minutes and continue without optional
    // diarization. The shared background load gets a longer cooperative deadline.
    private static let defaultDiarizerLoadWaitTimeout: Duration = .seconds(120)
    private static let defaultDiarizerLoadOperationTimeout: Duration = .seconds(300)

    static let explicitlyRoutedBackendIdentifiers: Set<String> = [
        "whisper", "nemotron35", "qwen", "cohere", "indicasr", "sensevoice", "gemma4-litert",
    ]

    private let fluidTranscriber = FluidAudioTranscriber()
    private let whisperTranscriber = WhisperKitTranscriber()
    private var _qwen3Transcriber: Any?
    private var _qwen3PostProcessor: Any?
    private var _cohereTranscriber: Any?
    private var _indicASRTranscriber: Any?
    private var _gemma4LiteRTTranscriber: Any?
    private let senseVoiceTranscriber = SenseVoiceTranscriber()
    private var vadManager: VadManager?
    private var diarizerManager: DiarizerManager?
    private var isDiarizerLoadInProgress = false
    private var activeDiarizerLoadID: UUID?
    private var diarizerLoadTask: Task<Void, Never>?
    private var diarizerLoadTimeoutTask: Task<Void, Never>?
    private var didDiarizerLoadTimeOut = false
    private var diarizerLoadWaiters: [UUID: DiarizerLoadWaiter] = [:]
    private let diarizerModelLoader: DiarizerModelLoader
    private let vadLoader: VADLoader
    private let diarizerLoadOperationTimeout: Duration
    private let diarizerDiagnostics: DiarizerPreloadDiagnostics
    private var activeBackend: String?

    /// Backends whose models are (or may be) resident. Every load path records
    /// itself here so `reconcileBackendResidency` knows what there is to free.
    private var loadedBackends: Set<String> = []
    /// Transcriptions and loads currently running, keyed by backend identifier.
    /// Guards against a reconcile interleaving with an awaited inference.
    private var backendsInFlight: [String: Int] = [:]
    private var backendDesignation = TranscriptionBackendResidencyPolicy.Designation()
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(
        diarizerModelLoader: @escaping DiarizerModelLoader = { policy in
            try await DiarizerModels.download(configuration: policy.modelConfiguration)
        },
        vadLoader: @escaping VADLoader = { try await VadManager() },
        diarizerLoadOperationTimeout: Duration = TranscriptionCoordinator.defaultDiarizerLoadOperationTimeout,
        diarizerDiagnostics: DiarizerPreloadDiagnostics = DiarizerPreloadDiagnostics()
    ) {
        self.diarizerModelLoader = diarizerModelLoader
        self.vadLoader = vadLoader
        self.diarizerLoadOperationTimeout = diarizerLoadOperationTimeout
        self.diarizerDiagnostics = diarizerDiagnostics
    }

    private var _nemotron35Transcriber: Any?
    /// Selected Nemotron 3.5 language prompt id (101 = auto). Stored so it survives
    /// lazy (re)creation of the transcriber and is applied whenever it loads.
    private var nemotron35PromptId: Int32 = 101

    @available(macOS 15, *)
    private var nemotron35Transcriber: Nemotron35StreamingTranscriber {
        if _nemotron35Transcriber == nil {
            _nemotron35Transcriber = Nemotron35StreamingTranscriber()
        }
        return _nemotron35Transcriber as! Nemotron35StreamingTranscriber
    }

    /// Loaded accessor for production dictation paths. Preload normally warms the
    /// model, but direct hold-to-talk or early double-tap after relaunch must not
    /// reach the actor while its CoreML models are still unloaded.
    @available(macOS 15, *)
    func getLoadedNemotron35Transcriber(
        progress: ((Double, String?) -> Void)? = nil
    ) async throws -> Nemotron35StreamingTranscriber {
        let transcriber = nemotron35Transcriber
        await transcriber.setPromptId(nemotron35PromptId)
        try await withBackendInFlight(BackendOption.nemotron35Multilingual.backend) {
            try await transcriber.loadModels(progress: progress)
        }
        return transcriber
    }

    /// Set the Nemotron 3.5 language prompt id (from app config). Applies to the
    /// live transcriber if it already exists.
    func setNemotron35PromptId(_ id: Int32) async {
        nemotron35PromptId = id
        if #available(macOS 15, *), let t = _nemotron35Transcriber as? Nemotron35StreamingTranscriber {
            await t.setPromptId(id)
        }
    }

    func unloadNemotron35Transcriber() async {
        loadedBackends.remove(BackendOption.nemotron35Multilingual.backend)
        if #available(macOS 15, *), let transcriber = _nemotron35Transcriber as? Nemotron35StreamingTranscriber {
            await transcriber.shutdown()
        }
    }

    func unloadGemma4LiteRTTranscriber() async {
        loadedBackends.remove(BackendOption.gemma4E2BLiteRT.backend)
        if #available(macOS 15, *), let transcriber = _gemma4LiteRTTranscriber as? Gemma4LiteRTTranscriber {
            await transcriber.shutdown()
            _gemma4LiteRTTranscriber = nil
        }
    }

    @available(macOS 15, *)
    private var qwen3Transcriber: Qwen3AsrTranscriber {
        if _qwen3Transcriber == nil {
            _qwen3Transcriber = Qwen3AsrTranscriber()
        }
        return _qwen3Transcriber as! Qwen3AsrTranscriber
    }

    private var postProcessorModelURL: URL = PostProcessorOption.defaultOption.modelURL
    private var postProcessorSystemPrompt: String = PostProcessorOption.defaultSystemPrompt
    private var postProcessorModelId: String = PostProcessorOption.defaultOption.id
    private var postProcessorBackend: TranscriptCleanupBackendOption = .local
    private var postProcessorConfig: AppConfig = AppConfig()

    private var postProcessorIdleUnloadMinutes = PostProcessorIdleUnloadPolicy.defaultIdleMinutes
    private var isMeetingActive = false
    private var postProcessorInvocationsInFlight = 0
    private var idleUnloadTask: Task<Void, Never>?

    private struct PostProcessorSnapshot {
        let backend: TranscriptCleanupBackendOption
        let systemPrompt: String
        let modelId: String
        let config: AppConfig
    }

    @available(macOS 15, *)
    private var qwen3PostProcessor: Qwen3PostProcessor {
        if _qwen3PostProcessor == nil {
            _qwen3PostProcessor = Qwen3PostProcessor(
                modelURL: postProcessorModelURL,
                systemPrompt: postProcessorSystemPrompt
            )
        }
        return _qwen3PostProcessor as! Qwen3PostProcessor
    }

    @available(macOS 15, *)
    func setActivePostProcessor(option: PostProcessorOption, systemPrompt: String) async {
        await configurePostProcessor(
            backend: .local,
            option: option,
            systemPrompt: systemPrompt,
            config: postProcessorConfig
        )
    }

    func configurePostProcessor(
        backend: TranscriptCleanupBackendOption,
        option: PostProcessorOption?,
        systemPrompt: String,
        config: AppConfig
    ) async {
        postProcessorBackend = backend
        postProcessorSystemPrompt = systemPrompt
        postProcessorConfig = config
        postProcessorIdleUnloadMinutes = PostProcessorIdleUnloadPolicy
            .resolvedIdleMinutes(config.postProcessorIdleUnloadMinutes)
        // A settings change restarts the countdown against the new value, and
        // re-arms it for a model still resident from a previously selected backend.
        scheduleIdleUnload()

        if backend == .gemma4LiteRT {
            postProcessorModelId = Gemma4LiteRTModelStore.repoID
        } else if let option {
            postProcessorModelURL = option.modelURL
            postProcessorModelId = option.id
            if #available(macOS 15, *), let existing = _qwen3PostProcessor as? Qwen3PostProcessor {
                await existing.reconfigure(modelURL: option.modelURL, systemPrompt: systemPrompt)
            }
        } else if backend.llmBackend != nil {
            postProcessorModelId = TranscriptCleanupClient.configuredModel(for: backend, config: config)
        }

        // Moving off Gemma cleanup drops the only claim on its engine when ASR uses
        // something else, so the switch itself is what releases those ~1.4 GB.
        await reconcileBackendResidency(reason: "cleanup backend changed")
    }

    private struct PostProcPairLogEntry: Encodable {
        let ts: String
        let raw: String
        let processed: String
        let model: String
        let asr: String
    }

    private func logPostProcPair(raw: String, processed: String, model: String, asr: String) {
        guard Qwen3PostProcessorLogging.isPairLoggingEnabled else { return }
        let logURL = AppIdentity.supportDirectoryURL.appendingPathComponent("postproc-pairs.jsonl")
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso8601.string(from: Date())
        let entry = PostProcPairLogEntry(
            ts: ts,
            raw: raw,
            processed: processed,
            model: model,
            asr: asr
        )
        guard var data = try? JSONEncoder().encode(entry) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let fh = try? FileHandle(forWritingTo: logURL) {
                defer { try? fh.close() }
                fh.seekToEndOfFile()
                fh.write(data)
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    @available(macOS 15, *)
    private var cohereTranscriber: CohereTranscribeTranscriber {
        if _cohereTranscriber == nil {
            _cohereTranscriber = CohereTranscribeTranscriber()
        }
        return _cohereTranscriber as! CohereTranscribeTranscriber
    }

    @available(macOS 15, *)
    private var indicASRTranscriber: IndicASRTranscriber {
        if _indicASRTranscriber == nil {
            _indicASRTranscriber = IndicASRTranscriber()
        }
        return _indicASRTranscriber as! IndicASRTranscriber
    }

    @available(macOS 15, *)
    private var gemma4LiteRTTranscriber: Gemma4LiteRTTranscriber {
        if _gemma4LiteRTTranscriber == nil {
            _gemma4LiteRTTranscriber = Gemma4LiteRTTranscriber()
        }
        return _gemma4LiteRTTranscriber as! Gemma4LiteRTTranscriber
    }

    func preload(
        backend: BackendOption,
        enablePostProcessor: Bool = false,
        includeMeetingHelpers: Bool = true,
        meetingHelperTrigger: DiarizerPreloadTrigger = .unspecified,
        progress: ((Double, String?) -> Void)? = nil
    ) async {
        do {
            try await preloadRequired(
                backend: backend,
                enablePostProcessor: enablePostProcessor,
                includeMeetingHelpers: includeMeetingHelpers,
                meetingHelperTrigger: meetingHelperTrigger,
                progress: progress
            )
        } catch {
            fputs("[muesli-native] preload failed for \(backend.backend)/\(backend.model): \(error)\n", stderr)
        }
    }

    func preloadRequired(
        backend: BackendOption,
        enablePostProcessor: Bool = false,
        includeMeetingHelpers: Bool = true,
        meetingHelperTrigger: DiarizerPreloadTrigger = .unspecified,
        progress: ((Double, String?) -> Void)? = nil
    ) async throws {
        activeBackend = backend.backend

        if includeMeetingHelpers {
            await preloadMeetingHelpers(trigger: meetingHelperTrigger)
        }
        try Task.checkCancellation()

        try await withBackendInFlight(Self.residencyIdentifier(for: backend)) {
            try await loadBackendModels(backend: backend, progress: progress)
        }

        await preloadPostProcessorIfNeeded(enabled: enablePostProcessor, transcriptionBackend: backend)
        await reconcileBackendResidency(reason: "after preloading \(backend.backend)")
    }

    private func loadBackendModels(
        backend: BackendOption,
        progress: ((Double, String?) -> Void)? = nil
    ) async throws {
        switch backend.backend {
        case "fluidaudio":
            let version: AsrModelVersion = backend.model.contains("v2") ? .v2 : .v3
            try await fluidTranscriber.loadModels(version: version, progress: progress)
        case "whisper":
            try await whisperTranscriber.loadModel(modelName: backend.model, progress: progress)
            // Warmup ANE/GPU so first dictation doesn't pay CoreML compilation cost
            fputs("[muesli-native] WhisperKit warmup: running silent audio for CoreML compilation...\n", stderr)
            progress?(0.9, "Warming up model...")
            try await whisperTranscriber.warmup()
            fputs("[muesli-native] WhisperKit warmup complete\n", stderr)
            progress?(1.0, nil)
        case "nemotron35":
            if #available(macOS 15, *) {
                let transcriber = try await getLoadedNemotron35Transcriber(progress: progress)
                // Warmup ANE so first dictation starts instantly
                fputs("[muesli-native] Nemotron 3.5 warmup: running silent chunk for ANE compilation...\n", stderr)
                var state = try await transcriber.makeStreamState()
                let silence = [Float](repeating: 0, count: transcriber.chunkSamples)
                _ = try await transcriber.transcribeChunk(samples: silence, state: &state)
                fputs("[muesli-native] Nemotron 3.5 warmup complete\n", stderr)
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Nemotron 3.5 requires macOS 15 or later.",
                ])
            }
        case "qwen":
            if #available(macOS 15, *) {
                try await qwen3Transcriber.loadModels(progress: progress)
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Qwen3 ASR requires macOS 15 or later.",
                ])
            }
        case "cohere":
            if #available(macOS 15, *) {
                try await cohereTranscriber.prepare(progress: progress)
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Cohere Transcribe requires macOS 15 or later.",
                ])
            }
        case "indicasr":
            if #available(macOS 15, *) {
                try await indicASRTranscriber.prepare(progress: progress)
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "Indic ASR requires macOS 15 or later.",
                ])
            }
        case "sensevoice":
            try await senseVoiceTranscriber.loadModels(progress: progress)
        case "gemma4-litert":
            if #available(macOS 15, *) {
                try await gemma4LiteRTTranscriber.prepare(progress: progress)
            } else {
                throw NSError(domain: "MuesliTranscriptionRuntime", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "Gemma 4 E2B requires macOS 15 or later.",
                ])
            }
        default:
            throw NSError(domain: "MuesliTranscriptionRuntime", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Unknown transcription backend: \(backend.backend)",
            ])
        }
    }

    func preloadMeetingHelpers(trigger: DiarizerPreloadTrigger = .unspecified) async {
        if vadManager == nil {
            do {
                vadManager = try await vadLoader()
                fputs("[muesli-native] Silero VAD loaded\n", stderr)
            } catch {
                fputs("[muesli-native] VAD load failed (non-critical): \(error)\n", stderr)
            }
        }

        await preloadDiarizer(trigger: trigger)
    }

    func preloadDiarizer(
        trigger: DiarizerPreloadTrigger = .unspecified,
        waitTimeout: Duration = TranscriptionCoordinator.defaultDiarizerLoadWaitTimeout
    ) async {
        let policy = DiarizerRuntimePolicy.resolve(for: .current())
        let context = DiarizerPreloadContext(
            trigger: trigger,
            policy: policy,
            cacheState: .resolve()
        )

        if diarizerManager != nil {
            diarizerDiagnostics.skipped(context, reason: "already_loaded")
            return
        }

        let startedLoad = !isDiarizerLoadInProgress
        if startedLoad {
            startDiarizerLoad(policy: policy, context: context)
        }

        let outcome = await waitForActiveDiarizerLoad(timeout: waitTimeout)
        let resolvedOutcome: DiarizerLoadWaitOutcome = Task.isCancelled ? .cancelled : outcome
        switch (startedLoad, resolvedOutcome) {
        case (true, .succeeded), (true, .failed):
            // The load lifecycle itself emits the terminal diagnostic.
            break
        case (false, .succeeded):
            diarizerDiagnostics.skipped(context, reason: "joined_load_succeeded")
        case (false, .failed):
            diarizerDiagnostics.skipped(context, reason: "joined_load_failed")
        case (true, .cancelled):
            diarizerDiagnostics.skipped(context, reason: "load_wait_cancelled")
        case (false, .cancelled):
            diarizerDiagnostics.skipped(context, reason: "joined_load_cancelled")
        case (true, .timedOut):
            diarizerDiagnostics.skipped(context, reason: "load_wait_timed_out")
        case (false, .timedOut):
            diarizerDiagnostics.skipped(context, reason: "joined_load_timed_out")
        }
    }

    private func startDiarizerLoad(
        policy: DiarizerRuntimePolicy,
        context: DiarizerPreloadContext
    ) {
        isDiarizerLoadInProgress = true
        didDiarizerLoadTimeOut = false
        let loadID = UUID()
        activeDiarizerLoadID = loadID
        let startedAt = diarizerDiagnostics.begin(context)

        let loader = diarizerModelLoader
        diarizerLoadTask = Task { [weak self] in
            do {
                let models = try await loader(policy)
                try Task.checkCancellation()
                await self?.finishDiarizerLoad(
                    id: loadID,
                    result: .success(models),
                    policy: policy,
                    context: context,
                    startedAt: startedAt
                )
            } catch {
                await self?.finishDiarizerLoad(
                    id: loadID,
                    result: .failure(error),
                    policy: policy,
                    context: context,
                    startedAt: startedAt
                )
            }
        }

        let operationTimeout = diarizerLoadOperationTimeout
        diarizerLoadTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: operationTimeout)
            } catch {
                return
            }
            await self?.timeoutDiarizerLoad(id: loadID)
        }
    }

    private func finishDiarizerLoad(
        id: UUID,
        result: Result<DiarizerModels, Error>,
        policy: DiarizerRuntimePolicy,
        context: DiarizerPreloadContext,
        startedAt: Date
    ) {
        guard activeDiarizerLoadID == id else { return }

        let didTimeOut = didDiarizerLoadTimeOut
        diarizerLoadTimeoutTask?.cancel()
        diarizerLoadTimeoutTask = nil
        diarizerLoadTask = nil
        activeDiarizerLoadID = nil
        isDiarizerLoadInProgress = false
        didDiarizerLoadTimeOut = false

        let outcome: DiarizerLoadWaitOutcome
        switch result {
        case .success(let models):
            let diarizer = DiarizerManager()
            diarizer.initialize(models: models)
            diarizerManager = diarizer
            diarizerDiagnostics.ready(context, startedAt: startedAt)
            fputs(
                "[muesli-native] Speaker diarization loaded (compute: \(policy.computePolicy.rawValue))\n",
                stderr
            )
            outcome = .succeeded
        case .failure(let error):
            let reportedError: Error = didTimeOut ? DiarizerPreloadFailure.operationTimedOut : error
            diarizerDiagnostics.failed(context, startedAt: startedAt, error: reportedError)
            fputs("[muesli-native] Diarization load failed (non-critical): \(reportedError)\n", stderr)
            outcome = .failed
        }

        resumeAllDiarizerLoadWaiters(with: outcome)
    }

    private func timeoutDiarizerLoad(id: UUID) {
        guard activeDiarizerLoadID == id else { return }
        didDiarizerLoadTimeOut = true
        diarizerLoadTask?.cancel()
        // A third-party model load may not observe cancellation while CoreML is
        // compiling. Release product callers immediately while retaining the
        // active-load guard so another expensive load cannot start in parallel.
        resumeAllDiarizerLoadWaiters(with: .timedOut)
    }

    private func waitForActiveDiarizerLoad(timeout: Duration) async -> DiarizerLoadWaitOutcome {
        if didDiarizerLoadTimeOut { return .timedOut }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }

                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.resumeDiarizerLoadWaiter(id: waiterID, with: .timedOut)
                }
                diarizerLoadWaiters[waiterID] = DiarizerLoadWaiter(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: { [weak self] in
            Task {
                await self?.resumeDiarizerLoadWaiter(id: waiterID, with: .cancelled)
            }
        }
    }

    private func resumeDiarizerLoadWaiter(id: UUID, with outcome: DiarizerLoadWaitOutcome) {
        guard let waiter = diarizerLoadWaiters.removeValue(forKey: id) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: outcome)
    }

    private func resumeAllDiarizerLoadWaiters(with outcome: DiarizerLoadWaitOutcome) {
        let waiters = diarizerLoadWaiters.values
        diarizerLoadWaiters.removeAll()
        for waiter in waiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: outcome)
        }
    }

    #if DEBUG
    func diarizerPreloadStateForTesting() -> (isActive: Bool, waiterCount: Int) {
        (isDiarizerLoadInProgress, diarizerLoadWaiters.count)
    }
    #endif

    func preloadPostProcessorIfNeeded(
        enabled: Bool,
        transcriptionBackend: BackendOption? = nil
    ) async {
        guard enabled,
              transcriptionBackend.map({ postProcessorBackend.isCompatible(with: $0) }) ?? true,
              #available(macOS 15, *) else { return }
        do {
            switch postProcessorBackend {
            case .local:
                try await qwen3PostProcessor.prepare()
            case .gemma4LiteRT:
                let transcriber = gemma4LiteRTTranscriber
                try await withBackendInFlight(BackendOption.gemma4E2BLiteRT.backend) {
                    try await transcriber.prepare()
                }
            default:
                return
            }
            // A preloaded model that never gets dictated into must still age out.
            scheduleIdleUnload()
        } catch {
            if postProcessorBackend == .local {
                Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor preload failed: \(error)")
            } else {
                Gemma4LiteRTLogging.log("Gemma cleanup preload failed: \(error)")
            }
        }
    }

    // MARK: - Backend residency

    /// Declares which backends the app still needs, then frees the rest.
    ///
    /// All three slots are pushed together so a startup that preloads a dictation
    /// model and a different meeting model does not unload one while designating
    /// the other. `meetingLiveCaption` is the identifier of the ASR backend behind
    /// the live-caption engine, or nil when live captions are off or served by a
    /// model the coordinator does not own (Parakeet EOU).
    func setDesignatedBackends(
        dictation: String?,
        meetingTranscription: String?,
        meetingLiveCaption: String?
    ) async {
        let updated = TranscriptionBackendResidencyPolicy.Designation(
            dictation: dictation,
            meetingTranscription: meetingTranscription,
            meetingLiveCaption: meetingLiveCaption,
            postProcessor: backendDesignation.postProcessor
        )
        guard updated != backendDesignation else { return }
        backendDesignation = updated
        await reconcileBackendResidency(reason: "selection changed")
    }

    /// Releases every loaded backend that no longer serves a designated slot.
    ///
    /// Returns the identifiers actually unloaded so callers, notably the memory
    /// pressure handler, can report what the reclaim bought.
    @discardableResult
    func reconcileBackendResidency(reason: String) async -> [String] {
        var designation = backendDesignation
        // The Gemma engine serves transcription and cleanup from one instance, so
        // a cleanup selection designates it even when ASR uses something else.
        designation.postProcessor = postProcessorBackend.isGemma4LiteRT
            ? BackendOption.gemma4E2BLiteRT.backend
            : nil
        backendDesignation.postProcessor = designation.postProcessor

        let unloadable = TranscriptionBackendResidencyPolicy.backendsToUnload(
            loaded: loadedBackends,
            designation: designation,
            inFlight: Set(backendsInFlight.keys)
        )
        for identifier in unloadable {
            await unloadBackend(identifier)
            fputs("[coordinator] unloading \(identifier): no longer designated (\(reason))\n", stderr)
        }
        return unloadable
    }

    /// Every wrapper here releases its models and reloads lazily, so the shared
    /// `let` transcribers are shut down in place rather than discarded.
    private func unloadBackend(_ identifier: String) async {
        loadedBackends.remove(identifier)
        switch identifier {
        case "fluidaudio":
            await fluidTranscriber.shutdown()
        case "whisper":
            await whisperTranscriber.shutdown()
        case "sensevoice":
            await senseVoiceTranscriber.shutdown()
        case "nemotron35":
            await unloadNemotron35Transcriber()
        case "gemma4-litert":
            await unloadGemma4LiteRTTranscriber()
        case "qwen":
            if #available(macOS 15, *), let transcriber = _qwen3Transcriber as? Qwen3AsrTranscriber {
                await transcriber.shutdown()
                _qwen3Transcriber = nil
            }
        case "cohere":
            if #available(macOS 15, *), let transcriber = _cohereTranscriber as? CohereTranscribeTranscriber {
                await transcriber.shutdown()
                _cohereTranscriber = nil
            }
        case "indicasr":
            if #available(macOS 15, *), let transcriber = _indicASRTranscriber as? IndicASRTranscriber {
                await transcriber.shutdown()
                _indicASRTranscriber = nil
            }
        default:
            break
        }
    }

    /// `route` falls through to FluidAudio for anything it does not recognise, so
    /// residency has to be booked against the backend that actually holds models.
    private static func residencyIdentifier(for backend: BackendOption) -> String {
        explicitlyRoutedBackendIdentifiers.contains(backend.backend) ? backend.backend : "fluidaudio"
    }

    /// Marks `identifier` busy for the duration of `body`, so a reconcile running
    /// in the window where this actor is suspended cannot unload it mid-flight.
    private func withBackendInFlight<T>(
        _ identifier: String,
        _ body: () async throws -> T
    ) async rethrows -> T {
        loadedBackends.insert(identifier)
        backendsInFlight[identifier, default: 0] += 1
        defer {
            let remaining = (backendsInFlight[identifier] ?? 1) - 1
            if remaining > 0 {
                backendsInFlight[identifier] = remaining
            } else {
                backendsInFlight.removeValue(forKey: identifier)
            }
        }
        return try await body()
    }

    // MARK: - Memory pressure

    /// Frees non-designated backends and idle cleanup models when macOS reports
    /// pressure. Deliberately minimal: no UI, no config, no new policy — it just
    /// runs the reclaim paths that already exist, earlier than they otherwise would.
    func startMemoryPressureMonitoring() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleMemoryPressureEvent() }
        }
        memoryPressureSource = source
        source.resume()
    }

    private func handleMemoryPressureEvent() async {
        guard let event = memoryPressureSource?.data else { return }
        let level = event.contains(.critical) ? "critical" : "warning"
        let unloadedBackends = await reconcileBackendResidency(reason: "memory pressure (\(level))")
        let unloadedCleanup = await unloadIdlePostProcessorModels(
            reason: "under memory pressure (\(level))"
        )
        let freed = unloadedBackends + unloadedCleanup
        if freed.isEmpty {
            fputs("[coordinator] memory pressure \(level): nothing releasable\n", stderr)
        } else {
            fputs("[coordinator] memory pressure \(level): freed \(freed.joined(separator: ", "))\n", stderr)
        }
    }

    // MARK: - Post-processor idle unload

    /// Pins the on-device cleanup model in memory for the duration of a meeting.
    ///
    /// A meeting is exactly when a reload hurts most: the user may dictate notes
    /// into another app while it records, and the machine is already busy with ASR
    /// and diarization. The countdown restarts once the meeting is finished.
    func setMeetingActive(_ active: Bool) {
        guard isMeetingActive != active else { return }
        isMeetingActive = active
        if active {
            cancelIdleUnload()
            fputs("[postproc] idle unload suspended while a meeting is active\n", stderr)
        } else {
            fputs("[postproc] meeting finished; idle unload countdown restarted\n", stderr)
            scheduleIdleUnload()
        }
    }

    private var isPostProcessorIdle: Bool {
        postProcessorInvocationsInFlight == 0 && !isMeetingActive
    }

    private func beginPostProcessorInvocation() {
        postProcessorInvocationsInFlight += 1
        cancelIdleUnload()
    }

    private func endPostProcessorInvocation() {
        postProcessorInvocationsInFlight = max(0, postProcessorInvocationsInFlight - 1)
        scheduleIdleUnload()
    }

    private func cancelIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    /// LSUIElement apps have their timers throttled by App Nap, so this may fire
    /// late. A late unload only means the memory is held longer than asked, which is
    /// the same state the app was already in, so no wakeup guarantee is needed.
    private func scheduleIdleUnload() {
        cancelIdleUnload()
        guard postProcessorInvocationsInFlight == 0 else { return }
        guard let delay = PostProcessorIdleUnloadPolicy.unloadDelaySeconds(
            idleMinutes: postProcessorIdleUnloadMinutes,
            isMeetingActive: isMeetingActive
        ) else { return }
        idleUnloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                // Cancelled by a new cleanup call, a meeting start, or a config change.
                return
            }
            await self?.unloadIdlePostProcessorModels()
        }
    }

    /// Releases whichever on-device cleanup model is still resident.
    ///
    /// Deliberately not keyed to the selected backend: switching from a local model
    /// to a hosted one leaves the old weights in memory with nothing else to free
    /// them. Both lazy-load again on the next cleanup call.
    /// - Parameter reason: Log suffix. Defaults to the idle-timer phrasing; the
    ///   memory pressure handler passes its own so the log does not claim a
    ///   countdown that never elapsed.
    @discardableResult
    private func unloadIdlePostProcessorModels(reason: String? = nil) async -> [String] {
        // `idleUnloadTask` is deliberately left alone: a reschedule can land between
        // this task waking and running, and clearing the handle here would orphan
        // that newer timer beyond the reach of cancelIdleUnload().
        guard isPostProcessorIdle, #available(macOS 15, *) else { return [] }
        let context = reason ?? "after \(postProcessorIdleUnloadMinutes) idle min"
        var unloaded: [String] = []

        // `isPostProcessorIdle` is re-read after each await: a dictation can start
        // while this is suspended, and unloading underneath it would cost that one
        // dictation its cleanup pass.
        if let postProcessor = _qwen3PostProcessor as? Qwen3PostProcessor,
           await postProcessor.isLoaded,
           isPostProcessorIdle {
            await postProcessor.shutdown()
            unloaded.append("local GGUF cleanup model")
            fputs("[postproc] unloaded local GGUF cleanup model \(context)\n", stderr)
        }

        if PostProcessorIdleUnloadPolicy.canUnloadGemma4Engine(activeTranscriptionBackend: activeBackend),
           let gemma4 = _gemma4LiteRTTranscriber as? Gemma4LiteRTTranscriber,
           await gemma4.isLoaded,
           isPostProcessorIdle {
            await gemma4.shutdown()
            _gemma4LiteRTTranscriber = nil
            loadedBackends.remove(BackendOption.gemma4E2BLiteRT.backend)
            unloaded.append("Gemma 4 cleanup engine")
            fputs("[postproc] unloaded Gemma 4 cleanup engine \(context)\n", stderr)
        }
        return unloaded
    }

    private func currentPostProcessorSnapshot() -> PostProcessorSnapshot {
        PostProcessorSnapshot(
            backend: postProcessorBackend,
            systemPrompt: postProcessorSystemPrompt,
            modelId: postProcessorModelId,
            config: postProcessorConfig
        )
    }

    func transcribeDictation(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage,
        indicASRLanguage: IndicASRLanguage = IndicASRLanguage.defaultLanguage,
        enablePostProcessor: Bool = false,
        customWords: [[String: Any]] = [],
        appContext: String? = nil
    ) async throws -> SpeechTranscriptionResult {
        let postProcessorSnapshot = currentPostProcessorSnapshot()
        // Qwen3 post-processing is intentionally dictation-only. Meeting transcription should keep raw backend/Parakeet output.
        // Cohere decodes hallucinated text from silence — skip if VAD detects no speech
        if backend.backend == "cohere", let vadManager {
            do {
                let vadResults = try await vadManager.process(url)
                let hasSpeech = vadResults.contains { $0.probability > 0.5 }
                if !hasSpeech {
                    fputs("[muesli-native] VAD: dictation is silent, skipping Cohere transcription\n", stderr)
                    return SpeechTranscriptionResult(text: "", segments: [])
                }
            } catch {
                fputs("[muesli-native] VAD check failed, transcribing anyway: \(error)\n", stderr)
            }
        }
        let dictionary = Self.decodeCustomWords(customWords)
        var result = try await route(
            url: url,
            backend: backend,
            cohereLanguage: cohereLanguage,
            indicASRLanguage: indicASRLanguage,
            vocabulary: AsrVocabularyPrompt.build(customWords: dictionary)
        )
        result = removeArtifacts(result)
        if !result.text.isEmpty {
            Qwen3PostProcessorLogging.logVerbose("Dictation raw transcript after artifact cleanup: \(result.text)")
        }
        result = await postProcessDictationIfNeeded(
            result,
            backend: backend,
            enabled: enablePostProcessor,
            postProcessorSnapshot: postProcessorSnapshot,
            appContext: appContext
        ) ?? removeFillersWithLogging(result)
        let final = applyCustomWords(result, customWords: dictionary)
        if !final.text.isEmpty {
            Qwen3PostProcessorLogging.logVerbose("Dictation final transcript: \(final.text)")
        }
        return final
    }

    func transcribeMeeting(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage,
        indicASRLanguage: IndicASRLanguage = IndicASRLanguage.defaultLanguage,
        customWords: [CustomWord] = []
    ) async throws -> SpeechTranscriptionResult {
        // Meetings intentionally skip Qwen/custom-word post-processing. Keep deterministic artifact/filler cleanup only.
        // ASR-stage vocabulary biasing is separate: it conditions the recognizer instead of rewriting its output.
        cleanMeetingTranscript(try await route(
            url: url,
            backend: backend,
            cohereLanguage: cohereLanguage,
            indicASRLanguage: indicASRLanguage,
            vocabulary: AsrVocabularyPrompt.build(customWords: customWords)
        ))
    }

    func transcribeMeetingChunk(
        at url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage,
        indicASRLanguage: IndicASRLanguage = IndicASRLanguage.defaultLanguage,
        customWords: [CustomWord] = []
    ) async throws -> SpeechTranscriptionResult {
        // Meeting chunks intentionally skip Qwen/custom-word post-processing for reconciliation.
        // Run VAD to skip silent chunks (prevents hallucinations)
        if let vadManager {
            do {
                let vadResults = try await vadManager.process(url)
                let hasSpeech = vadResults.contains { $0.probability > 0.5 }
                if !hasSpeech {
                    fputs("[muesli-native] VAD: chunk is silent, skipping transcription\n", stderr)
                    return SpeechTranscriptionResult(text: "", segments: [])
                }
            } catch {
                fputs("[muesli-native] VAD check failed, transcribing anyway: \(error)\n", stderr)
            }
        }
        return cleanMeetingTranscript(try await route(
            url: url,
            backend: backend,
            cohereLanguage: cohereLanguage,
            indicASRLanguage: indicASRLanguage,
            vocabulary: AsrVocabularyPrompt.build(customWords: customWords)
        ))
    }

    func diarizeSystemAudio(at url: URL) async throws -> DiarizationResult? {
        guard let diarizerManager, diarizerManager.isAvailable else {
            fputs("[muesli-native] diarization not available, skipping\n", stderr)
            return nil
        }
        fputs("[muesli-native] running speaker diarization on system audio...\n", stderr)
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(url)
        let result = try diarizerManager.performCompleteDiarization(samples, sampleRate: 16000)
        let speakerCount = Set(result.segments.map(\.speakerId)).count
        fputs("[muesli-native] diarization complete: \(result.segments.count) segments, \(speakerCount) speakers\n", stderr)
        return result
    }

    func getVadManager() -> VadManager? {
        vadManager
    }

    func getDiarizerManager() -> DiarizerManager? {
        diarizerManager
    }

    func shutdown() async {
        cancelIdleUnload()
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        loadedBackends.removeAll()
        await fluidTranscriber.shutdown()
        await whisperTranscriber.shutdown()
        await senseVoiceTranscriber.shutdown()
        if #available(macOS 15, *) {
            if let nemotron35 = _nemotron35Transcriber as? Nemotron35StreamingTranscriber {
                await nemotron35.shutdown()
            }
            await qwen3Transcriber.shutdown()
            if let postProcessor = _qwen3PostProcessor as? Qwen3PostProcessor {
                await postProcessor.shutdown()
            }
            await cohereTranscriber.shutdown()
            await indicASRTranscriber.shutdown()
            if let gemma4 = _gemma4LiteRTTranscriber as? Gemma4LiteRTTranscriber {
                await gemma4.shutdown()
            }
        }
    }

    private func removeFillers(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        let filtered = FillerWordFilter.apply(result.text)
        return SpeechTranscriptionResult(text: filtered, segments: result.segments)
    }

    private func removeFillersWithLogging(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        let start = CFAbsoluteTimeGetCurrent()
        let filtered = removeFillers(result)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if filtered.text != result.text {
            Qwen3PostProcessorLogging.logVerbose("FillerWordFilter applied in \(String(format: "%.1f", elapsedMs))ms -> \(filtered.text)")
        } else {
            Qwen3PostProcessorLogging.logVerbose("FillerWordFilter skipped effective changes (\(String(format: "%.1f", elapsedMs))ms)")
        }
        return filtered
    }

    private func cleanMeetingTranscript(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        removeFillers(removeArtifacts(result))
    }

    private func removeArtifacts(_ result: SpeechTranscriptionResult) -> SpeechTranscriptionResult {
        let filtered = TranscriptionEngineArtifactsFilter.apply(result.text)
        return SpeechTranscriptionResult(text: filtered, segments: filtered.isEmpty ? [] : result.segments)
    }

    private func postProcessDictationIfNeeded(
        _ result: SpeechTranscriptionResult,
        backend: BackendOption,
        enabled: Bool,
        postProcessorSnapshot: PostProcessorSnapshot,
        appContext: String? = nil
    ) async -> SpeechTranscriptionResult? {
        guard enabled else {
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor disabled for dictation")
            return nil
        }
        guard backend.backend != "indicasr" else {
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor skipped: Indic ASR output is not English post-processor safe")
            return nil
        }
        guard !result.text.isEmpty else {
            Qwen3PostProcessorLogging.logVerbose("Post-processor skipped: empty transcript")
            return nil
        }
        guard postProcessorSnapshot.backend.isCompatible(with: backend) else {
            Gemma4LiteRTLogging.log("Gemma cleanup skipped because Gemma is the transcription backend")
            return nil
        }
        // Hosted backends hold nothing on this machine, so they run outside the
        // residency window that the on-device models below need.
        if postProcessorSnapshot.backend.llmBackend != nil {
            return await postProcessDictationWithHostedBackend(
                result,
                backend: backend,
                postProcessorSnapshot: postProcessorSnapshot,
                appContext: appContext
            )
        }

        // Every on-device cleanup call passes through here, which makes this the one
        // place that knows the model is in use. Both paths lazy-load, so a call
        // arriving after an idle unload transparently reloads the weights.
        beginPostProcessorInvocation()
        defer { endPostProcessorInvocation() }

        if postProcessorSnapshot.backend.isGemma4LiteRT {
            return await postProcessDictationWithGemma4(
                result,
                backend: backend,
                postProcessorSnapshot: postProcessorSnapshot,
                appContext: appContext
            )
        }
        guard #available(macOS 15, *) else {
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor skipped: requires macOS 15+")
            return nil
        }

        do {
            // The explicit toggle means "always try cleanup" for dictation.
            // Trigger heuristics were removed; the only remaining heuristic here preserves deletion-cue empty output.
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor forced by toggle")
            let start = CFAbsoluteTimeGetCurrent()
            let processed = try await qwen3PostProcessor.process(result.text, appContext: appContext)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, !Qwen3DeletionCueDetector.containsDeletionCue(result.text) {
                Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor returned empty output in \(String(format: "%.1f", elapsedMs))ms; falling back")
                TranscriptCleanupDebugLogger.append(
                    status: "fallback_empty_output",
                    cleanupBackend: postProcessorSnapshot.backend,
                    cleanupModel: postProcessorSnapshot.modelId,
                    asrBackend: backend.backend,
                    appContextText: appContext,
                    rawASRText: result.text,
                    rawCleanupOutputText: processed,
                    cleanupOutputText: trimmed,
                    elapsedMs: elapsedMs
                )
                return nil
            }
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor applied to \(backend.label) in \(String(format: "%.1f", elapsedMs))ms (chars=\(trimmed.count))")
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor final output: \(trimmed)")
            logPostProcPair(raw: result.text, processed: trimmed, model: postProcessorSnapshot.modelId, asr: backend.backend)
            TranscriptCleanupDebugLogger.append(
                status: "applied",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                rawCleanupOutputText: processed,
                cleanupOutputText: trimmed,
                elapsedMs: elapsedMs
            )
            return SpeechTranscriptionResult(
                text: trimmed,
                // Original ASR segments describe pre-cleanup text. Keep them only for debug diagnostics.
                segments: Qwen3PostProcessorLogging.isVerboseEnabled && !trimmed.isEmpty ? result.segments : []
            )
        } catch {
            Qwen3PostProcessorLogging.logVerbose("Qwen3 post-processor failed, falling back: \(error)")
            TranscriptCleanupDebugLogger.append(
                status: "fallback_error",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                errorDescription: String(describing: error)
            )
            return nil
        }
    }

    private func postProcessDictationWithGemma4(
        _ result: SpeechTranscriptionResult,
        backend: BackendOption,
        postProcessorSnapshot: PostProcessorSnapshot,
        appContext: String?
    ) async -> SpeechTranscriptionResult? {
        guard #available(macOS 15, *) else {
            Gemma4LiteRTLogging.log("Gemma cleanup skipped: requires macOS 15+")
            return nil
        }
        do {
            let transcriber = gemma4LiteRTTranscriber
            let cleanup = try await withBackendInFlight(BackendOption.gemma4E2BLiteRT.backend) {
                try await transcriber.prepare()
                return try await transcriber.cleanTranscript(
                    result.text,
                    systemPrompt: postProcessorSnapshot.systemPrompt,
                    appContext: appContext
                )
            }
            let elapsedMs = cleanup.processingTime * 1000
            let trimmed = cleanup.text.trimmingCharacters(in: .whitespacesAndNewlines)
            Qwen3PostProcessorLogging.logVerbose(
                "Gemma 4 post-processor applied to \(backend.label) in \(String(format: "%.1f", elapsedMs))ms " +
                    "(chars=\(trimmed.count))"
            )
            logPostProcPair(
                raw: result.text,
                processed: trimmed,
                model: postProcessorSnapshot.modelId,
                asr: backend.backend
            )
            TranscriptCleanupDebugLogger.append(
                status: "applied",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                rawCleanupOutputText: cleanup.rawOutput,
                cleanupOutputText: trimmed,
                elapsedMs: elapsedMs
            )
            return SpeechTranscriptionResult(
                text: trimmed,
                segments: Qwen3PostProcessorLogging.isVerboseEnabled && !trimmed.isEmpty ? result.segments : []
            )
        } catch {
            Gemma4LiteRTLogging.log("Gemma cleanup failed, falling back: \(error)")
            TranscriptCleanupDebugLogger.append(
                status: "fallback_error",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                errorDescription: String(describing: error)
            )
            return nil
        }
    }

    private func postProcessDictationWithHostedBackend(
        _ result: SpeechTranscriptionResult,
        backend: BackendOption,
        postProcessorSnapshot: PostProcessorSnapshot,
        appContext: String?
    ) async -> SpeechTranscriptionResult? {
        do {
            let start = CFAbsoluteTimeGetCurrent()
            let cleanup = try await TranscriptCleanupClient.clean(
                text: result.text,
                systemPrompt: postProcessorSnapshot.systemPrompt,
                appContext: appContext,
                backend: postProcessorSnapshot.backend,
                config: postProcessorSnapshot.config
            )
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let trimmed = cleanup.cleanedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, !Qwen3DeletionCueDetector.containsDeletionCue(result.text) {
                Qwen3PostProcessorLogging.logVerbose("\(postProcessorSnapshot.backend.label) post-processor returned empty output in \(String(format: "%.1f", elapsedMs))ms; falling back")
                TranscriptCleanupDebugLogger.append(
                    status: "fallback_empty_output",
                    cleanupBackend: postProcessorSnapshot.backend,
                    cleanupModel: cleanup.model,
                    asrBackend: backend.backend,
                    appContextText: appContext,
                    rawASRText: result.text,
                    rawCleanupOutputText: cleanup.rawOutput,
                    cleanupOutputText: trimmed,
                    elapsedMs: elapsedMs
                )
                return nil
            }
            Qwen3PostProcessorLogging.logVerbose("\(postProcessorSnapshot.backend.label) post-processor applied to \(backend.label) in \(String(format: "%.1f", elapsedMs))ms (chars=\(trimmed.count))")
            logPostProcPair(raw: result.text, processed: trimmed, model: cleanup.model, asr: backend.backend)
            TranscriptCleanupDebugLogger.append(
                status: "applied",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: cleanup.model,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                rawCleanupOutputText: cleanup.rawOutput,
                cleanupOutputText: trimmed,
                elapsedMs: elapsedMs
            )
            return SpeechTranscriptionResult(
                text: trimmed,
                segments: Qwen3PostProcessorLogging.isVerboseEnabled && !trimmed.isEmpty ? result.segments : []
            )
        } catch TranscriptCleanupError.rejectedOutput {
            Qwen3PostProcessorLogging.logVerbose("\(postProcessorSnapshot.backend.label) post-processor output rejected, falling back")
            TranscriptCleanupDebugLogger.append(
                status: "fallback_rejected_output",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                errorDescription: TranscriptCleanupError.rejectedOutput.localizedDescription
            )
            return nil
        } catch {
            Qwen3PostProcessorLogging.logVerbose("\(postProcessorSnapshot.backend.label) post-processor failed, falling back: \(error)")
            TranscriptCleanupDebugLogger.append(
                status: "fallback_error",
                cleanupBackend: postProcessorSnapshot.backend,
                cleanupModel: postProcessorSnapshot.modelId,
                asrBackend: backend.backend,
                appContextText: appContext,
                rawASRText: result.text,
                errorDescription: String(describing: error)
            )
            return nil
        }
    }

    /// The dictation entry point receives the dictionary as plain dictionaries from the
    /// controller; decode once so ASR-stage biasing and post-hoc matching share the entries.
    private static func decodeCustomWords(_ customWords: [[String: Any]]) -> [CustomWord] {
        customWords.compactMap { dict -> CustomWord? in
            guard let word = dict["word"] as? String else { return nil }
            let threshold = dict["matchingThreshold"] as? Double ?? 0.85
            return CustomWord(word: word, replacement: dict["replacement"] as? String, matchingThreshold: threshold)
        }
    }

    private func applyCustomWords(_ result: SpeechTranscriptionResult, customWords: [CustomWord]) -> SpeechTranscriptionResult {
        guard !customWords.isEmpty, !result.text.isEmpty else { return result }
        let correctedText = CustomWordMatcher.apply(text: result.text, customWords: customWords)
        return SpeechTranscriptionResult(text: correctedText, segments: result.segments)
    }

    /// `vocabulary` is only honoured by backends that accept recognizer conditioning;
    /// the rest still rely on post-hoc `CustomWordMatcher` repair.
    private func route(
        url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        indicASRLanguage: IndicASRLanguage,
        vocabulary: AsrVocabularyPrompt? = nil
    ) async throws -> SpeechTranscriptionResult {
        try await withBackendInFlight(Self.residencyIdentifier(for: backend)) {
            try await routeToBackend(
                url: url,
                backend: backend,
                cohereLanguage: cohereLanguage,
                indicASRLanguage: indicASRLanguage,
                vocabulary: vocabulary
            )
        }
    }

    private func routeToBackend(
        url: URL,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        indicASRLanguage: IndicASRLanguage,
        vocabulary: AsrVocabularyPrompt?
    ) async throws -> SpeechTranscriptionResult {
        switch backend.backend {
        case "whisper":
            return try await transcribeWithWhisperKit(url: url, vocabulary: vocabulary)
        case "nemotron35":
            return try await transcribeWithNemotron35(url: url)
        case "qwen":
            return try await transcribeWithQwen3(url: url)
        case "cohere":
            return try await transcribeWithCohere(url: url, language: cohereLanguage)
        case "indicasr":
            return try await transcribeWithIndicASR(url: url, language: indicASRLanguage)
        case "sensevoice":
            return try await transcribeWithSenseVoice(url: url)
        case "gemma4-litert":
            return try await transcribeWithGemma4LiteRT(url: url)
        default:
            return try await transcribeWithFluidAudio(url: url)
        }
    }

    // MARK: - FluidAudio (Parakeet on ANE)

    private func transcribeWithFluidAudio(url: URL) async throws -> SpeechTranscriptionResult {
        fputs("[muesli-native] transcribing with FluidAudio: \(url.lastPathComponent)\n", stderr)
        let result = try await fluidTranscriber.transcribe(wavURL: url)
        fputs("[muesli-native] FluidAudio result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = (result.tokenTimings ?? []).map { timing in
            SpeechSegment(start: timing.startTime, end: timing.endTime, text: timing.token)
        }
        return SpeechTranscriptionResult(
            text: text,
            segments: segments.isEmpty && !text.isEmpty ? [SpeechSegment(start: 0, end: result.duration, text: text)] : segments
        )
    }

    // MARK: - WhisperKit (Whisper on ANE/GPU via CoreML)

    private func transcribeWithWhisperKit(url: URL, vocabulary: AsrVocabularyPrompt? = nil) async throws -> SpeechTranscriptionResult {
        fputs("[muesli-native] transcribing with WhisperKit: \(url.lastPathComponent)\n", stderr)
        let result = try await whisperTranscriber.transcribe(wavURL: url, vocabulary: vocabulary)
        fputs("[muesli-native] WhisperKit result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeechTranscriptionResult(
            text: text,
            segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
        )
    }

    // MARK: - Qwen3 ASR (Autoregressive CoreML on ANE)

    private func transcribeWithQwen3(url: URL) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[muesli-native] transcribing with Qwen3 ASR: \(url.lastPathComponent)\n", stderr)
            let result = try await qwen3Transcriber.transcribe(wavURL: url)
            fputs("[muesli-native] Qwen3 ASR result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Qwen3 ASR requires macOS 15 or later.",
            ])
        }
    }

    // MARK: - SenseVoiceSmall (FunASR via FluidAudio/CoreML)

    private func transcribeWithSenseVoice(url: URL) async throws -> SpeechTranscriptionResult {
        fputs("[muesli-native] transcribing with SenseVoice: \(url.lastPathComponent)\n", stderr)
        let result = try await senseVoiceTranscriber.transcribe(wavURL: url)
        fputs("[muesli-native] SenseVoice result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeechTranscriptionResult(
            text: text,
            // FluidAudio's SenseVoice API returns plain text only, so timestamped segments are not available here.
            segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
        )
    }

    // MARK: - Gemma 4 E2B (LiteRT-LM multimodal)

    private func transcribeWithGemma4LiteRT(url: URL) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            Gemma4LiteRTLogging.log("transcribing \(url.lastPathComponent)")
            let transcriber = gemma4LiteRTTranscriber
            try await transcriber.prepare()
            let result = try await transcriber.transcribe(wavURL: url)
            Gemma4LiteRTLogging.log("result chars=\(result.text.count), processingTime=\(String(format: "%.3f", result.processingTime))s")
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "MuesliTranscriptionRuntime", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Gemma 4 E2B requires macOS 15 or later.",
            ])
        }
    }

    // MARK: - Cohere Transcribe (CoreML)

    private func transcribeWithCohere(
        url: URL,
        language: CohereTranscribeLanguage
    ) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[muesli-native] transcribing with Cohere Transcribe: \(url.lastPathComponent)\n", stderr)
            let result = try await cohereTranscriber.transcribe(wavURL: url, language: language)
            fputs("[muesli-native] Cohere Transcribe result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cohere Transcribe requires macOS 15 or later.",
            ])
        }
    }

    // MARK: - Indic ASR (AI4Bharat IndicConformer RNNT CoreML)

    private func transcribeWithIndicASR(
        url: URL,
        language: IndicASRLanguage
    ) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            IndicASRLogging.logVerbose("transcribing with Indic ASR (\(language.rawValue)): \(url.lastPathComponent)")
            let result = try await indicASRTranscriber.transcribe(wavURL: url, language: language)
            IndicASRLogging.logVerbose("Indic ASR result chars=\(result.text.count), processingTime=\(String(format: "%.3f", result.processingTime))s")
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Indic ASR requires macOS 15 or later.",
            ])
        }
    }

    // MARK: - Nemotron 3.5 Streaming (RNNT CoreML on ANE)

    private func transcribeWithNemotron35(url: URL) async throws -> SpeechTranscriptionResult {
        if #available(macOS 15, *) {
            fputs("[muesli-native] transcribing with Nemotron 3.5: \(url.lastPathComponent)\n", stderr)
            let transcriber = try await getLoadedNemotron35Transcriber()
            let result = try await transcriber.transcribe(wavURL: url)
            fputs("[muesli-native] Nemotron 3.5 result: \(result.text.prefix(80)) (took \(String(format: "%.3f", result.processingTime))s)\n", stderr)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTranscriptionResult(
                text: text,
                segments: text.isEmpty ? [] : [SpeechSegment(start: 0, end: 0, text: text)]
            )
        } else {
            throw NSError(domain: "Muesli", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Nemotron 3.5 requires macOS 15 or later.",
            ])
        }
    }

}
