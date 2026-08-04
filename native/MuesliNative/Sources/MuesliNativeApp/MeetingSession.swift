import FluidAudio
import ApplicationServices
import CoreAudio
import Foundation
import MuesliCore
import os

final class MeetingChunkCollector {
    private struct PendingTask {
        let id: UUID
        let task: Task<[SpeechSegment], Never>
    }

    private struct State {
        // Only in-flight tasks live here. Completed tasks are retired into
        // completedSegments so Task objects and their captured state don't
        // accumulate for the full meeting duration.
        var pendingTasks: [PendingTask] = []
        var completedSegments: [SpeechSegment] = []
        var isClosed = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Register a transcription task. Returns the retire ID to pass to retire(id:segments:)
    /// once the task completes.
    func add(_ task: Task<[SpeechSegment], Never>) -> (registered: Bool, retireID: UUID) {
        let id = UUID()
        let registered = lock.withLock { state in
            guard !state.isClosed else { return false }
            state.pendingTasks.append(PendingTask(id: id, task: task))
            return true
        }
        return (registered, id)
    }

    /// Move a completed task's result into the collector and drop the Task reference.
    /// Must be called from the watcher Task after awaiting the transcription task's value.
    func retire(id: UUID, segments: [SpeechSegment]) -> Bool {
        lock.withLock { state in
            guard !state.isClosed else { return false }
            state.completedSegments.append(contentsOf: segments)
            state.pendingTasks.removeAll { $0.id == id }
            return true
        }
    }

    func closeAndDrainSortedSegments() async -> [SpeechSegment] {
        let (tasksToAwait, alreadyCompleted) = lock.withLock { state in
            state.isClosed = true
            let tasks = state.pendingTasks.map { $0.task }
            let completed = state.completedSegments
            state.pendingTasks.removeAll()
            state.completedSegments.removeAll()
            return (tasks, completed)
        }

        var segments = alreadyCompleted
        for task in tasksToAwait {
            segments.append(contentsOf: await task.value)
        }

        return segments.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }
    }

    func waitUntilRetired() async {
        while true {
            let tasks = lock.withLock { $0.pendingTasks.map(\.task) }
            guard !tasks.isEmpty else { return }
            for task in tasks {
                _ = await task.value
            }
            await Task.yield()
        }
    }

    func cancelAll() {
        let tasksToCancel = lock.withLock { state in
            state.isClosed = true
            let tasks = state.pendingTasks.map { $0.task }
            state.pendingTasks.removeAll()
            state.completedSegments.removeAll()
            return tasks
        }
        tasksToCancel.forEach { $0.cancel() }
    }
}

enum MeetingStreamingTranscriptResolver {
    static func resolve(
        durableSegments: [SpeechSegment],
        authoritativeStreamingText: String?,
        prefersStreamingTranscript: Bool,
        start: TimeInterval,
        end: TimeInterval
    ) -> [SpeechSegment] {
        guard (durableSegments.isEmpty || prefersStreamingTranscript),
              let authoritativeStreamingText else { return durableSegments }
        return [SpeechSegment(
            start: start,
            end: max(end, start + 0.1),
            text: authoritativeStreamingText
        )]
    }
}

struct MeetingSessionResult {
    let title: String
    let originalTitle: String
    let calendarEventID: String?
    let startTime: Date
    let endTime: Date
    let durationSeconds: Double
    let rawTranscript: String
    let formattedNotes: String
    let retainedRecordingURL: URL?
    let retainedRecordingError: Error?
    let systemRecordingURL: URL?
    let templateSnapshot: MeetingTemplateSnapshot
    /// Screen/OCR context this summary was built from.
    ///
    /// Carried out of the session rather than discarded, so a regeneration after
    /// transcript cleanup can reproduce the same call. Without it, regenerating
    /// would quietly drop screen-derived detail and produce a worse summary than
    /// the one it replaced.
    var visualContext: String = ""
    /// Predecessor notes this summary was built from, for the same reason.
    var previousMeetingNotes: String = ""
}

extension MeetingSessionResult {
    /// Returns a copy with transcript, notes, and optional timing overrides.
    /// Used by the resume-recording flow to persist the merged transcript while
    /// keeping the original meeting date and accumulating only recorded duration.
    func overriding(
        startTime newStartTime: Date? = nil,
        durationSeconds newDurationSeconds: Double? = nil,
        rawTranscript: String,
        formattedNotes: String
    ) -> MeetingSessionResult {
        let resolvedStart = newStartTime ?? startTime
        let resolvedDuration = newDurationSeconds ?? durationSeconds
        return MeetingSessionResult(
            title: title,
            originalTitle: originalTitle,
            calendarEventID: calendarEventID,
            startTime: resolvedStart,
            endTime: endTime,
            durationSeconds: resolvedDuration,
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: retainedRecordingError,
            systemRecordingURL: systemRecordingURL,
            templateSnapshot: templateSnapshot,
            visualContext: visualContext,
            previousMeetingNotes: previousMeetingNotes
        )
    }
}

enum MeetingProcessingStage {
    case transcribingAudio
    case cleaningAudio
    case generatingTitle
    case summarizingNotes
}

private enum MeetingTranscriptRecoveryResult {
    case none
    case append([SpeechSegment])
    case replace([SpeechSegment])
}

struct MeetingMicSessionRouteState {
    enum Reconciliation: Equatable {
        case keepSessionOverride(AudioObjectID)
        case applyConfigured(AudioObjectID?, resetFailoverEligibility: Bool)
    }

    private struct Signature: Equatable {
        let configuredDeviceID: AudioObjectID?
        let selectedInputDeviceUID: String?
        let selectedInputDeviceResolved: Bool
        let defaultInputDeviceID: AudioObjectID?
        let builtInInputDeviceID: AudioObjectID?
    }

    private(set) var configuredDeviceID: AudioObjectID?
    private(set) var sessionOverrideDeviceID: AudioObjectID?
    private var failoverRouteSignature: Signature?

    init(configuredDeviceID: AudioObjectID?) {
        self.configuredDeviceID = configuredDeviceID
    }

    mutating func beginFailover(
        to deviceID: AudioObjectID,
        route: MeetingMicRouteDiagnosticsSnapshot
    ) {
        sessionOverrideDeviceID = deviceID
        failoverRouteSignature = signature(configuredDeviceID: configuredDeviceID, route: route)
    }

    mutating func failoverDidFail(deviceID: AudioObjectID?) {
        guard sessionOverrideDeviceID == deviceID else { return }
        sessionOverrideDeviceID = nil
        failoverRouteSignature = nil
    }

    mutating func reconcileConfiguredRoute(
        deviceID: AudioObjectID?,
        route: MeetingMicRouteDiagnosticsSnapshot?,
        explicitUserSelection: Bool
    ) -> Reconciliation {
        let previousConfiguredDeviceID = configuredDeviceID
        configuredDeviceID = deviceID

        guard let overrideDeviceID = sessionOverrideDeviceID else {
            return .applyConfigured(
                deviceID,
                resetFailoverEligibility: explicitUserSelection || previousConfiguredDeviceID != deviceID
            )
        }

        let nextSignature = route.map { signature(configuredDeviceID: deviceID, route: $0) }
        let fallbackStillAvailable = route.map { route in
            overrideDeviceID == route.preferredInputDeviceID
                || overrideDeviceID == route.defaultInputDeviceID
                || overrideDeviceID == route.builtInInputDeviceID
        } ?? true
        let routeMateriallyChanged: Bool
        if let failoverRouteSignature, let nextSignature {
            routeMateriallyChanged = failoverRouteSignature != nextSignature
        } else {
            routeMateriallyChanged = false
        }

        guard !explicitUserSelection, fallbackStillAvailable, !routeMateriallyChanged else {
            sessionOverrideDeviceID = nil
            failoverRouteSignature = nil
            return .applyConfigured(deviceID, resetFailoverEligibility: true)
        }
        return .keepSessionOverride(overrideDeviceID)
    }

    mutating func endSession() {
        sessionOverrideDeviceID = nil
        failoverRouteSignature = nil
    }

    private func signature(
        configuredDeviceID: AudioObjectID?,
        route: MeetingMicRouteDiagnosticsSnapshot
    ) -> Signature {
        Signature(
            configuredDeviceID: configuredDeviceID,
            selectedInputDeviceUID: route.selectedInputDeviceUID,
            selectedInputDeviceResolved: route.selectedInputDeviceResolved,
            defaultInputDeviceID: route.defaultInputDeviceID,
            builtInInputDeviceID: route.builtInInputDeviceID
        )
    }
}

final class MeetingSession {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingSession")

    private let title: String
    private let calendarEventID: String?
    private let backendLock = OSAllocatedUnfairLock(initialState: BackendOption.whisper)
    private let runtime: RuntimePaths
    private let config: AppConfig
    private let templateSnapshot: MeetingTemplateSnapshot
    private let transcriptionCoordinator: TranscriptionCoordinator
    private let systemAudioRecorder: SystemAudioCapturing
    private let neuralAec = MeetingNeuralAec()

    /// Route-aware mic recorder with real-time 16 kHz mono PCM access.
    private var meetingMicRecorder: MeetingMicRecording
    private var rawMicChunkRecorder: PCMChunkRecorder?
    private var retainedRecordingWriter: MeetingRecordingWriter?
    private var retainedRecordingWriterError: Error?
    /// Converts callback delivery times to retained-recording sample offsets.
    /// Confined to `chunkRotationQueue` with the writer itself.
    private var retainedRecordingTimeline = MeetingRecordingTimeline()
    /// VAD controller for speech-boundary chunk rotation
    private var vadController: StreamingVadController?
    private var systemVadController: StreamingVadController?
    private let micChunkCollector = MeetingChunkCollector()
    private let systemChunkCollector = MeetingChunkCollector()
    private let micChunkHealthTracker = MeetingTranscriptChunkHealthTracker()
    private let systemChunkHealthTracker = MeetingTranscriptChunkHealthTracker()
    private let micHealthTracker = MeetingMicHealthTracker()
    /// Confined to `chunkRotationQueue`, which serialises every health callback.
    private var micFailoverPolicy = MeetingMicFailoverPolicy()
    private var micFailoverAttemptTracker = MeetingMicFailoverAttemptTracker()
    /// A fallback chosen for this recording must outlive unrelated CoreAudio
    /// inventory notifications, even though it is not the user's configured route.
    private var micSessionRouteState: MeetingMicSessionRouteState
    private var lastMicFailoverEvaluationAt: Date?
    private let chunkRotationQueue = DispatchQueue(label: "MuesliNative.MeetingSession.chunkRotation")
    private let pausedDisplayLock = OSAllocatedUnfairLock(initialState: false)
    private var chunkTimingTracker = MeetingChunkTimingTracker()
    private var systemChunkTimingTracker = MeetingChunkTimingTracker()
    private var systemChunkRecorder: PCMChunkRecorder?
    var onProgress: ((MeetingProcessingStage) -> Void)?
    var onMicHealthChanged: ((MeetingMicHealthSnapshot) -> Void)?
    /// Live input-route facts for silent-mic failover. Read on the chunk
    /// rotation queue, so it must not block on CoreAudio.
    var meetingInputRouteProvider: (() -> MeetingMicRouteDiagnosticsSnapshot?)?
    /// System audio capture died mid-meeting and could not be rebuilt. Called on
    /// a background thread; the owner is responsible for surfacing it.
    var onSystemAudioCaptureFailure: ((Error) -> Void)?
    var manualNotesProvider: (() async -> String?)?
    var liveTitleProvider: (() async -> String?)?
    /// Formatted notes of the predecessor meeting when this session records a
    /// follow-up; injected into the summary prompt for action-item carry-forward.
    var previousMeetingNotes: String?
    var onChunkTranscribed: (([SpeechSegment], String) -> Void)?
    /// Display-only streaming partial for a source ("You"/"Others", tail text).
    /// Empty text clears the source's tail. Called on a background thread.
    var onPartialTranscript: ((String, String) -> Void)?
    /// Lock-guarded because sessions are installed by an async model-loading
    /// task, fed on chunkRotationQueue, and committed by chunk-completion tasks.
    /// `isShutDown` closes the async-setup race with meeting teardown.
    private struct PartialSessionsStorage {
        var mic: MeetingStreamingPartialSession?
        var system: MeetingStreamingPartialSession?
        var isShutDown = false
    }
    private let partialSessionsStorage = OSAllocatedUnfairLock(initialState: PartialSessionsStorage())
    private let screenContextCollector = MeetingScreenContextCollector()
    private var diagnostics: MeetingSessionDiagnostics?

    /// Current mic power level for waveform visualization.
    func currentPower() -> Float {
        if pausedDisplayLock.withLock({ $0 }) {
            return -160
        }
        return meetingMicRecorder.currentPower()
    }

    private(set) var startTime: Date?
    private var captureRequestedStartTime: Date?
    private(set) var isRecording = false
    private(set) var isPaused = false

    private func setPausedStateOnQueue(_ paused: Bool) {
        isPaused = paused
        pausedDisplayLock.withLock { $0 = paused }
    }

    init(
        title: String,
        calendarEventID: String?,
        backend: BackendOption,
        runtime: RuntimePaths,
        config: AppConfig,
        templateSnapshot: MeetingTemplateSnapshot,
        transcriptionCoordinator: TranscriptionCoordinator,
        meetingMicRecorder: MeetingMicRecording = RouteAwareMeetingMicRecorder()
    ) {
        self.title = title
        self.calendarEventID = calendarEventID
        backendLock.withLock { $0 = backend }
        self.runtime = runtime
        self.config = config
        self.templateSnapshot = templateSnapshot
        self.transcriptionCoordinator = transcriptionCoordinator
        self.meetingMicRecorder = meetingMicRecorder
        self.micSessionRouteState = MeetingMicSessionRouteState(
            configuredDeviceID: meetingMicRecorder.preferredInputDeviceID
        )
        if config.useCoreAudioTap {
            self.systemAudioRecorder = CoreAudioSystemRecorder()
        } else {
            self.systemAudioRecorder = SystemAudioRecorder()
        }
    }

    func updateBackend(_ backend: BackendOption) {
        backendLock.withLock { $0 = backend }
    }

    func setPreferredMicrophoneInputDeviceID(
        _ deviceID: AudioObjectID?,
        explicitUserSelection: Bool = false
    ) {
        chunkRotationQueue.sync {
            let route = meetingInputRouteProvider?()
            switch micSessionRouteState.reconcileConfiguredRoute(
                deviceID: deviceID,
                route: route,
                explicitUserSelection: explicitUserSelection
            ) {
            case .keepSessionOverride:
                return
            case .applyConfigured(let configuredDeviceID, let resetFailoverEligibility):
                if resetFailoverEligibility {
                    micFailoverPolicy = MeetingMicFailoverPolicy()
                    micFailoverAttemptTracker = MeetingMicFailoverAttemptTracker()
                    lastMicFailoverEvaluationAt = nil
                }
                meetingMicRecorder.preferredInputDeviceID = configuredDeviceID
            }
        }
    }

    private func currentBackend() -> BackendOption {
        backendLock.withLock { $0 }
    }

    func start() async throws {
        let vadManager = await transcriptionCoordinator.getVadManager()
        let requestedStart = Date()
        diagnostics = MeetingSessionDiagnostics(title: title, startedAt: requestedStart)

        // AEC must be loaded before audio pipeline starts (streaming mode)
        await neuralAec.preload()

        chunkRotationQueue.sync {
            // The persisted clock is established by the first accepted PCM
            // callback. Capture startup and permission latency are not audio.
            startTime = nil
            captureRequestedStartTime = requestedStart
            retainedRecordingTimeline.reset()
            chunkTimingTracker.discard()
            systemChunkTimingTracker.discard()
            isRecording = true
            setPausedStateOnQueue(false)
        }

        do {
            try prepareRealtimeAudioPipeline(vadManager: vadManager)
            try meetingMicRecorder.prepare()
            setupRetainedRecordingWriterIfNeeded()
            try await systemAudioRecorder.start()
            try meetingMicRecorder.start()
        } catch {
            vadController?.stop()
            vadController = nil
            systemVadController?.stop()
            systemVadController = nil
            meetingMicRecorder.onRawPCMSamples = nil
            (meetingMicRecorder as? MeetingMicHandoffReporting)?.onHandoffResult = nil
            systemAudioRecorder.onPCMSamples = nil
            systemAudioRecorder.onSystemAudioFailure = nil
            retainedRecordingWriter?.cancel()
            retainedRecordingWriter = nil
            rawMicChunkRecorder?.cancel()
            rawMicChunkRecorder = nil
            systemChunkRecorder?.cancel()
            systemChunkRecorder = nil
            chunkRotationQueue.sync {
                isRecording = false
                setPausedStateOnQueue(false)
                startTime = nil
                captureRequestedStartTime = nil
                retainedRecordingTimeline.reset()
                chunkTimingTracker.discard()
                systemChunkTimingTracker.discard()
                micSessionRouteState.endSession()
            }
            meetingMicRecorder.cancel()
            if let url = await systemAudioRecorder.stop() {
                try? FileManager.default.removeItem(at: url)
            }
            systemChunkCollector.cancelAll()
            throw error
        }
        if vadController != nil {
            fputs("[meeting] started with VAD-driven chunk rotation\n", stderr)
        } else {
            fputs("[meeting] VAD not available, using max-duration fallback only\n", stderr)
        }
        if config.enableScreenContext && CGPreflightScreenCaptureAccess() {
            // OCR screenshots are safe when using CoreAudio tap (no SCStream conflict)
            await screenContextCollector.startPeriodicCapture(useOCR: config.useCoreAudioTap)
        }
        setupStreamingPartialsIfAvailable()
    }

    /// Display-only streaming partials (#99). The selected live-caption model
    /// consumes the same cleaned mic and raw system streams as the VAD pipeline;
    /// VAD chunk transcription remains the durable source of truth.
    private func setupStreamingPartialsIfAvailable() {
        guard config.enableLiveStreamingPartials else { return }
        let backend = config.resolvedMeetingLiveCaptionBackend
        guard backend.isDownloaded else {
            fputs("[meeting-partials] \(backend.label) not downloaded; using committed live captions only\n", stderr)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let engines: (mic: MeetingStreamingPartialEngine, system: MeetingStreamingPartialEngine)
                if backend == .nemotron35, #available(macOS 15, *) {
                    // Borrow the coordinator's transcriber rather than loading a
                    // second copy of the same weights for the meeting's lifetime.
                    // A failed borrow falls back to a private instance.
                    let shared = try? await self.transcriptionCoordinator.getLoadedNemotron35Transcriber()
                    engines = try await MeetingLiveCaptionModelStore.makeEngines(
                        backend: backend,
                        nemotronPromptId: self.config.resolvedNemotron35Language.promptId,
                        sharedNemotron35: shared
                    )
                } else {
                    engines = try await MeetingLiveCaptionModelStore.makeEngines(
                        backend: backend,
                        nemotronPromptId: self.config.resolvedNemotron35Language.promptId
                    )
                }
                guard self.chunkRotationQueue.sync(execute: { self.isRecording }),
                      self.partialSessionsStorage.withLock({ !$0.isShutDown }) else {
                    await engines.mic.shutdown()
                    await engines.system.shutdown()
                    return
                }

                let mic = MeetingStreamingPartialSession(engine: engines.mic, label: "You")
                mic.onPartialUpdate = { [weak self] text in self?.onPartialTranscript?("You", text) }
                await mic.connect()
                let system = MeetingStreamingPartialSession(engine: engines.system, label: "Others")
                system.onPartialUpdate = { [weak self] text in self?.onPartialTranscript?("Others", text) }
                await system.connect()

                let stillRecording = self.chunkRotationQueue.sync { self.isRecording }
                guard stillRecording else {
                    mic.stop()
                    system.stop()
                    return
                }
                let installed = self.partialSessionsStorage.withLock { s -> Bool in
                    guard !s.isShutDown else { return false }
                    s.mic = mic
                    s.system = system
                    return true
                }
                guard installed else {
                    mic.stop()
                    system.stop()
                    return
                }
                fputs("[meeting-partials] \(backend.label) active for mic and system audio\n", stderr)
            } catch {
                fputs("[meeting-partials] \(backend.label) setup failed: \(error)\n", stderr)
            }
        }
    }

    private func micPartialSession() -> MeetingStreamingPartialSession? {
        partialSessionsStorage.withLock { $0.mic }
    }

    private func systemPartialSession() -> MeetingStreamingPartialSession? {
        partialSessionsStorage.withLock { $0.system }
    }

    private func feedMicPartialSession(_ samples: [Float]) {
        micPartialSession()?.enqueue(samples)
    }

    private func feedSystemPartialSession(_ samples: [Float]) {
        systemPartialSession()?.enqueue(samples)
    }

    private func markMicPartialBoundary(id: UUID) {
        micPartialSession()?.markSegmentBoundary(id: id)
    }

    private func markSystemPartialBoundary(id: UUID) {
        systemPartialSession()?.markSegmentBoundary(id: id)
    }

    private func commitMicPartialSegment(id: UUID) {
        micPartialSession()?.commitSegment(id: id)
    }

    private func commitSystemPartialSegment(id: UUID) {
        systemPartialSession()?.commitSegment(id: id)
    }

    private func segmentsUsingStreamingTranscript(
        _ segments: [SpeechSegment],
        partialSession: MeetingStreamingPartialSession?,
        segmentID: UUID,
        start: TimeInterval,
        end: TimeInterval
    ) -> [SpeechSegment] {
        let prefersStreamingTranscript = config.enableLiveStreamingPartials
            && config.resolvedMeetingLiveCaptionBackend == .nemotron35
        return MeetingStreamingTranscriptResolver.resolve(
            durableSegments: segments,
            authoritativeStreamingText: partialSession?.pendingSegmentText(id: segmentID),
            prefersStreamingTranscript: prefersStreamingTranscript,
            start: start,
            end: end
        )
    }

    private func suspendPartialSessions() {
        micPartialSession()?.suspend()
        systemPartialSession()?.suspend()
    }

    private func resumePartialSessions() {
        micPartialSession()?.resume()
        systemPartialSession()?.resume()
    }

    private func stopPartialSessions() {
        let sessions = partialSessionsStorage.withLock { s -> (MeetingStreamingPartialSession?, MeetingStreamingPartialSession?) in
            let taken = (s.mic, s.system)
            s.mic = nil
            s.system = nil
            s.isShutDown = true
            return taken
        }
        sessions.0?.stop()
        sessions.1?.stop()
    }

    func stopStreamingPartials() {
        stopPartialSessions()
    }

    func pause() {
        let pauseUptime = DispatchTime.now().uptimeNanoseconds
        let shouldPause = chunkRotationQueue.sync { () -> Bool in
            guard isRecording, !isPaused else { return false }
            appendFlushedStreamingMicOnQueue()
            rotateChunkOnQueue()
            rotateSystemChunkOnQueue()
            retainedRecordingTimeline.pause(at: pauseUptime)
            retainedRecordingWriter?.markPauseBoundary()
            neuralAec.resetForStreaming()
            setPausedStateOnQueue(true)
            suspendPartialSessions()
            return true
        }
        guard shouldPause else { return }

        meetingMicRecorder.pause()
        systemAudioRecorder.pause()
        Task { await screenContextCollector.setPaused(true) }
        fputs("[meeting] recording paused\n", stderr)
    }

    func resume() {
        let resumeUptime = DispatchTime.now().uptimeNanoseconds
        let shouldResume = chunkRotationQueue.sync { () -> Bool in
            guard isRecording, isPaused else { return false }
            retainedRecordingTimeline.resume(at: resumeUptime)
            setPausedStateOnQueue(false)
            resumePartialSessions()
            return true
        }
        guard shouldResume else { return }

        meetingMicRecorder.resume()
        systemAudioRecorder.resume()
        Task { await screenContextCollector.setPaused(false) }
        fputs("[meeting] recording resumed\n", stderr)
    }

    /// Abandon the recording — stop everything, delete temp files, don't transcribe.
    func discard() {
        Task { await screenContextCollector.stopAndDrain() }
        let (rawRecorder, systemRecorder) = chunkRotationQueue.sync { () -> (PCMChunkRecorder?, PCMChunkRecorder?) in
            isRecording = false
            setPausedStateOnQueue(false)
            chunkTimingTracker.discard()
            systemChunkTimingTracker.discard()
            micSessionRouteState.endSession()
            retainedRecordingTimeline.reset()
            startTime = nil
            captureRequestedStartTime = nil
            let rawRecorder = rawMicChunkRecorder
            let systemRecorder = systemChunkRecorder
            rawMicChunkRecorder = nil
            systemChunkRecorder = nil
            return (rawRecorder, systemRecorder)
        }
        stopPartialSessions()
        vadController?.stop()
        vadController = nil
        systemVadController?.stop()
        systemVadController = nil
        retainedRecordingWriter?.cancel()
        retainedRecordingWriter = nil
        retainedRecordingWriterError = nil
        rawRecorder?.cancel()
        systemRecorder?.cancel()
        meetingMicRecorder.onRawPCMSamples = nil
        (meetingMicRecorder as? MeetingMicHandoffReporting)?.onHandoffResult = nil
        meetingMicRecorder.cancel()
        systemAudioRecorder.onPCMSamples = nil
        systemAudioRecorder.onSystemAudioFailure = nil
        // `discard()` is called from synchronous UI paths, so the system-audio
        // teardown runs detached; its callbacks are already unhooked above and
        // the only remaining work is deleting the abandoned temp file.
        let audioRecorderToStop = systemAudioRecorder
        Task {
            if let url = await audioRecorderToStop.stop() {
                try? FileManager.default.removeItem(at: url)
            }
        }
        micChunkCollector.cancelAll()
        systemChunkCollector.cancelAll()
        fputs("[meeting] recording discarded\n", stderr)
    }

    func stop() async throws -> MeetingSessionResult {
        onProgress?(.transcribingAudio)
        let endTime = Date()
        var micSegments: [SpeechSegment] = []
        var systemSegments: [SpeechSegment] = []
        let usesUnifiedNemotronTranscript = config.enableLiveStreamingPartials
            && config.resolvedMeetingLiveCaptionBackend == .nemotron35

        // Stop VAD controller
        if !usesUnifiedNemotronTranscript {
            stopPartialSessions()
        }
        vadController?.stop()
        vadController = nil
        systemVadController?.stop()
        systemVadController = nil
        meetingMicRecorder.onRawPCMSamples = nil
        systemAudioRecorder.onPCMSamples = nil
        systemAudioRecorder.onSystemAudioFailure = nil
        let (meetingStart, lastChunkTiming, lastRawMicURL, lastSystemChunkTiming, lastSystemChunkURL) = chunkRotationQueue.sync { () -> (Date, MeetingChunkTimingSnapshot?, URL?, MeetingChunkTimingSnapshot?, URL?) in
            isRecording = false
            setPausedStateOnQueue(false)

            // Flush partial AEC frame before stopping chunk recorder
            appendFlushedStreamingMicOnQueue()

            let meetingStart = self.startTime ?? self.captureRequestedStartTime ?? Date()
            micSessionRouteState.endSession()
            let lastRawMicURL = rawMicChunkRecorder?.stop()
            let lastSystemChunkURL = systemChunkRecorder?.stop()
            rawMicChunkRecorder = nil
            systemChunkRecorder = nil
            let lastChunkTiming = chunkTimingTracker.finish()
            let lastSystemChunkTiming = systemChunkTimingTracker.finish()
            return (meetingStart, lastChunkTiming, lastRawMicURL, lastSystemChunkTiming, lastSystemChunkURL)
        }
        let rawStreamingMicURL = meetingMicRecorder.stop()
        // The recorder reports a still-pending mic handoff as failed during
        // stop(); the handler hops through the chunk queue, so drain it before
        // tearing the callback down or a failover decided moments before the
        // meeting ended would be missing from the persisted diagnostics.
        chunkRotationQueue.sync {}
        (meetingMicRecorder as? MeetingMicHandoffReporting)?.onHandoffResult = nil
        let retainedRecordingURL = retainedRecordingWriter?.stop()
        retainedRecordingWriter = nil
        defer {
            if let rawStreamingMicURL {
                try? FileManager.default.removeItem(at: rawStreamingMicURL)
            }
        }

        // Stop system audio
        let systemAudioURL = await systemAudioRecorder.stop()

        if usesUnifiedNemotronTranscript {
            async let micRetirement: Void = micChunkCollector.waitUntilRetired()
            async let systemRetirement: Void = systemChunkCollector.waitUntilRetired()
            _ = await (micRetirement, systemRetirement)

            async let micTail = micPartialSession()?.finish()
            async let systemTail = systemPartialSession()?.finish()
            let (finalMicText, finalSystemText) = await (micTail, systemTail)
            if let finalMicText, let timing = lastChunkTiming {
                micSegments.append(SpeechSegment(
                    start: timing.startTimeSeconds,
                    end: timing.startTimeSeconds + max(timing.durationSeconds, 0.1),
                    text: finalMicText
                ))
            }
            if let finalSystemText, let timing = lastSystemChunkTiming {
                systemSegments.append(SpeechSegment(
                    start: timing.startTimeSeconds,
                    end: timing.startTimeSeconds + max(timing.durationSeconds, 0.1),
                    text: finalSystemText
                ))
            }
            stopPartialSessions()
        }

        // The configured meeting model fills only a tail Nemotron could not finalize.
        if !usesUnifiedNemotronTranscript || micSegments.isEmpty {
            let finalMicSegments = await transcribeMicChunk(
                rawURL: lastRawMicURL,
                chunkTiming: lastChunkTiming,
                isFinalChunk: true
            )
            micSegments.append(contentsOf: finalMicSegments)
        } else if let lastRawMicURL {
            try? FileManager.default.removeItem(at: lastRawMicURL)
        }

        if let lastSystemChunkURL {
            let chunkOffset = lastSystemChunkTiming?.startTimeSeconds ?? 0
            let chunkDuration = lastSystemChunkTiming?.durationSeconds ?? 0
            if !usesUnifiedNemotronTranscript || systemSegments.isEmpty {
                fputs("[meeting] transcribing final system chunk (offset=\(String(format: "%.0f", chunkOffset))s)\n", stderr)
                do {
                    let result = try await transcriptionCoordinator.transcribeMeetingChunk(
                        at: lastSystemChunkURL,
                        backend: currentBackend(),
                        cohereLanguage: config.resolvedCohereLanguage,
                        indicASRLanguage: config.resolvedIndicASRLanguage,
                        customWords: config.customWords
                    )
                    let normalizedSegments = normalizeSystemTranscription(
                        result: result,
                        startTime: chunkOffset,
                        endTime: chunkOffset + max(chunkDuration, 0.1)
                    )
                    if normalizedSegments.isEmpty {
                        systemChunkHealthTracker.noteEmptyChunk()
                    } else {
                        systemChunkHealthTracker.noteSuccessfulChunk()
                    }
                    systemSegments.append(contentsOf: normalizedSegments)
                } catch {
                    systemChunkHealthTracker.noteFailedChunk()
                    fputs("[meeting] final system chunk transcription failed: \(error)\n", stderr)
                }
            }
            try? FileManager.default.removeItem(at: lastSystemChunkURL)
        }

        var diarizationSegments: [TimedSpeakerSegment]?
        if let systemAudioURL {
            // Run speaker diarization on system audio (batch post-processing)
            if let diarizationResult = try? await transcriptionCoordinator.diarizeSystemAudio(at: systemAudioURL) {
                diarizationSegments = diarizationResult.segments
            }
        }

        micSegments.append(contentsOf: await micChunkCollector.closeAndDrainSortedSegments())
        micSegments.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }

        systemSegments.append(contentsOf: await systemChunkCollector.closeAndDrainSortedSegments())
        systemSegments.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }

        if let systemAudioURL,
           Self.shouldAttemptSystemRecovery(
               usesUnifiedNemotronTranscript: usesUnifiedNemotronTranscript,
               hasSystemSegments: !systemSegments.isEmpty
           ) {
            let systemRecovery = await repairSystemSegmentsIfNeeded(
                existingSystemSegments: systemSegments,
                systemAudioURL: systemAudioURL,
                meetingStart: meetingStart,
                endTime: endTime
            )
            switch systemRecovery {
            case .none:
                break
            case .append(let repairedSystemSegments):
                systemSegments.append(contentsOf: repairedSystemSegments)
                systemSegments.sort { lhs, rhs in
                    if lhs.start == rhs.start {
                        return lhs.text < rhs.text
                    }
                    return lhs.start < rhs.start
                }
            case .replace(let fallbackSystemSegments):
                systemSegments = fallbackSystemSegments.sorted { lhs, rhs in
                    if lhs.start == rhs.start {
                        return lhs.text < rhs.text
                    }
                    return lhs.start < rhs.start
                }
            }
        }

        fputs("[meeting] \(micSegments.count) mic chunks transcribed during meeting\n", stderr)
        fputs("[meeting] \(systemSegments.count) system chunks transcribed during meeting\n", stderr)

        let reconciledTranscriptInputs = TranscriptReconciler.reconcile(
            micTurns: micSegments,
            systemSegments: systemSegments,
            diarizationSegments: diarizationSegments
        )
        let protectedTranscriptInputs = reconciledTranscriptInputs

        let rawTranscript = TranscriptFormatter.merge(
            micSegments: protectedTranscriptInputs.micSegments,
            systemSegments: protectedTranscriptInputs.systemSegments,
            diarizationSegments: protectedTranscriptInputs.diarizationSegments,
            meetingStart: meetingStart
        )

        let titleManualNotes = await manualNotesProvider?()
        let generatedTitle: String
        onProgress?(.generatingTitle)
        if let liveTitle = await userEditedLiveTitle() {
            generatedTitle = liveTitle
        } else if let calendarTitle = Self.calendarTitleCandidate(
            originalTitle: title,
            calendarEventID: calendarEventID
        ) {
            generatedTitle = calendarTitle
        } else if let autoTitle = await MeetingSummaryClient.generateTitle(
            transcript: rawTranscript,
            manualNotes: titleManualNotes,
            config: config
        ),
           !autoTitle.isEmpty {
            generatedTitle = autoTitle
            fputs("[meeting] auto-generated title: \(generatedTitle)\n", stderr)
        } else {
            generatedTitle = title
        }

        let visualContext = await screenContextCollector.stopAndDrain()
        Self.logger.info("visual context drained chars=\(visualContext.count) includedInPrompt=\(!visualContext.isEmpty) useOCR=\(self.config.useCoreAudioTap)")
        fputs("[meeting] visual context drained chars=\(visualContext.count) includedInPrompt=\(!visualContext.isEmpty) useOCR=\(config.useCoreAudioTap)\n", stderr)
        onProgress?(.summarizingNotes)
        let manualNotes = await manualNotesProvider?()
        let formattedNotes: String
        do {
            formattedNotes = try await MeetingSummaryClient.summarize(
                transcript: rawTranscript,
                meetingTitle: generatedTitle,
                config: config,
                template: templateSnapshot,
                existingNotes: nil,
                manualNotesToRetain: manualNotes,
                visualContext: visualContext.isEmpty ? nil : visualContext,
                previousMeetingNotes: previousMeetingNotes
            )
        } catch {
            fputs("[meeting] summary generation failed: \(error.localizedDescription)\n", stderr)
            formattedNotes = MeetingSummaryClient.summaryFailureNotes(
                transcript: rawTranscript,
                meetingTitle: generatedTitle,
                error: error,
                manualNotes: manualNotes
            )
        }

        diagnostics?.writeFinalReport(
            title: generatedTitle,
            startedAt: meetingStart,
            endedAt: endTime,
            rawTranscript: rawTranscript,
            rawMicURL: rawStreamingMicURL,
            systemAudioURL: systemAudioURL,
            systemCapture: (systemAudioRecorder as? SystemAudioDiagnosticsProviding)?.diagnosticsSnapshot,
            micRecorder: meetingMicRecorder.diagnosticsSnapshot(),
            micHealth: micHealthTracker.snapshot(),
            aec: neuralAec.diagnosticsSnapshot,
            micChunks: micChunkHealthTracker.snapshot(),
            systemChunks: systemChunkHealthTracker.snapshot(),
            diarizationSegments: protectedTranscriptInputs.diarizationSegments,
            protectedSystemSegmentCount: protectedTranscriptInputs.systemSegments.count
        )

        return MeetingSessionResult(
            title: generatedTitle,
            originalTitle: title,
            calendarEventID: calendarEventID,
            startTime: meetingStart,
            endTime: endTime,
            durationSeconds: max(endTime.timeIntervalSince(meetingStart), 0),
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: retainedRecordingWriterError,
            systemRecordingURL: systemAudioURL,
            templateSnapshot: templateSnapshot,
            visualContext: visualContext,
            previousMeetingNotes: previousMeetingNotes ?? ""
        )
    }

    static func calendarTitleCandidate(originalTitle: String, calendarEventID: String?) -> String? {
        guard calendarEventID != nil else { return nil }
        guard !originalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return originalTitle
    }

    static func shouldAttemptSystemRecovery(
        usesUnifiedNemotronTranscript: Bool,
        hasSystemSegments: Bool
    ) -> Bool {
        !usesUnifiedNemotronTranscript || !hasSystemSegments
    }

    private func userEditedLiveTitle() async -> String? {
        guard let candidate = await liveTitleProvider?() else { return nil }
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOriginal = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidate.isEmpty else { return nil }
        guard trimmedCandidate != trimmedOriginal else { return nil }
        return trimmedCandidate
    }

    private func appendFlushedStreamingMicOnQueue() {
        let flushed = neuralAec.flushStreamingMic()
        appendCleanedMicSamplesOnQueue(flushed)
    }

    /// Called by VAD on speech boundaries or max-duration fallback.
    /// Rotates the streaming mic file and sends the completed chunk for transcription.
    private func rotateChunk() {
        chunkRotationQueue.async { [weak self] in
            self?.rotateChunkOnQueue()
        }
    }

    private func rotateChunkOnQueue() {
        guard isRecording, !isPaused else { return }
        appendFlushedStreamingMicOnQueue()
        guard let chunkTiming = chunkTimingTracker.rotate() else {
            return
        }
        let rawChunkURL = rawMicChunkRecorder?.rotateFile()

        guard rawChunkURL != nil else {
            return
        }

        // Transcribe the completed chunk async
        let chunkOffset = chunkTiming.startTimeSeconds

        fputs("[meeting] rotating raw mic chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)
        let task = Task { [weak self] () -> [SpeechSegment] in
            guard let self else { return [] }
            if Task.isCancelled {
                self.cleanupTemporaryChunkURLs(rawChunkURL)
                return []
            }
            let segments = await self.transcribeMicChunk(
                rawURL: rawChunkURL,
                chunkTiming: chunkTiming,
                isFinalChunk: false
            )
            return segments
        }
        let (registered, retireID) = micChunkCollector.add(task)
        if registered {
            // Bind this frozen prefix to the collector ID because chunk tasks
            // may finish out of submission order.
            markMicPartialBoundary(id: retireID)
            Task { [weak self] in
                let segments = await task.value
                guard let self else { return }
                let resolvedSegments = self.segmentsUsingStreamingTranscript(
                    segments,
                    partialSession: self.micPartialSession(),
                    segmentID: retireID,
                    start: chunkOffset,
                    end: chunkOffset + max(chunkTiming.durationSeconds, 0.1)
                )
                guard self.micChunkCollector.retire(id: retireID, segments: resolvedSegments) else { return }
                self.commitMicPartialSegment(id: retireID)
                guard !resolvedSegments.isEmpty else { return }
                self.onChunkTranscribed?(resolvedSegments, "You")
            }
        } else {
            task.cancel()
            cleanupTemporaryChunkURLs(rawChunkURL)
        }
    }

    private func rotateSystemChunk() {
        chunkRotationQueue.async { [weak self] in
            self?.rotateSystemChunkOnQueue()
        }
    }

    private func rotateSystemChunkOnQueue() {
        guard isRecording, !isPaused else { return }
        guard let chunkURL = systemChunkRecorder?.rotateFile(),
              let chunkTiming = systemChunkTimingTracker.rotate() else {
            return
        }

        let chunkOffset = chunkTiming.startTimeSeconds
        let chunkDuration = chunkTiming.durationSeconds
        fputs("[meeting] rotating system chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)
        let task = Task { [weak self] () -> [SpeechSegment] in
            defer {
                try? FileManager.default.removeItem(at: chunkURL)
            }
            guard let self else { return [] }
            do {
                if Task.isCancelled {
                    return []
                }
                let backend = self.currentBackend()
                let result = try await self.transcriptionCoordinator.transcribeMeetingChunk(
                    at: chunkURL,
                    backend: backend,
                    cohereLanguage: config.resolvedCohereLanguage,
                    indicASRLanguage: config.resolvedIndicASRLanguage,
                    customWords: config.customWords
                )
                if !result.text.isEmpty {
                    fputs("[meeting] system chunk transcribed: \"\(String(result.text.prefix(60)))...\"\n", stderr)
                    let normalizedSegments = self.normalizeSystemTranscription(
                        result: result,
                        startTime: chunkOffset,
                        endTime: chunkOffset + max(chunkDuration, 0.1)
                    )
                    if normalizedSegments.isEmpty {
                        self.systemChunkHealthTracker.noteEmptyChunk()
                    } else {
                        self.systemChunkHealthTracker.noteSuccessfulChunk()
                    }
                    return normalizedSegments
                }
                self.systemChunkHealthTracker.noteEmptyChunk()
            } catch {
                self.systemChunkHealthTracker.noteFailedChunk()
                fputs("[meeting] system chunk transcription failed: \(error)\n", stderr)
            }
            return []
        }
        let (registered, retireID) = systemChunkCollector.add(task)
        if registered {
            markSystemPartialBoundary(id: retireID)
            Task { [weak self] in
                let segments = await task.value
                guard let self else { return }
                let resolvedSegments = self.segmentsUsingStreamingTranscript(
                    segments,
                    partialSession: self.systemPartialSession(),
                    segmentID: retireID,
                    start: chunkOffset,
                    end: chunkOffset + max(chunkDuration, 0.1)
                )
                guard self.systemChunkCollector.retire(id: retireID, segments: resolvedSegments) else { return }
                self.commitSystemPartialSegment(id: retireID)
                guard !resolvedSegments.isEmpty else { return }
                self.onChunkTranscribed?(resolvedSegments, "Others")
            }
        } else {
            task.cancel()
        }
    }

    private func setupRetainedRecordingWriterIfNeeded() {
        retainedRecordingWriter = nil
        retainedRecordingWriterError = nil

        guard config.meetingRecordingSavePolicy != .never else { return }

        do {
            retainedRecordingWriter = try MeetingRecordingWriter()
        } catch {
            retainedRecordingWriterError = error
            fputs("[meeting] failed to prepare retained recording writer: \(error)\n", stderr)
        }
    }

    private func prepareRealtimeAudioPipeline(vadManager: VadManager?) throws {
        rawMicChunkRecorder = try PCMChunkRecorder(directoryName: "muesli-meeting-mic-chunks")
        systemChunkRecorder = try PCMChunkRecorder(directoryName: "muesli-meeting-system-chunks")
        configureRealtimeAudioCallbacks(vadManager: vadManager)
    }

    private func configureRealtimeAudioCallbacks(vadManager: VadManager?) {
        if let vadManager {
            let controller = StreamingVadController(vadManager: vadManager)
            controller.onChunkBoundary = { [weak self] in
                // Streaming VAD callbacks can arrive off-main; serialize chunk rotation explicitly.
                self?.chunkRotationQueue.async { [weak self] in
                    self?.rotateChunkOnQueue()
                }
            }
            controller.start()
            vadController = controller

            let systemController = StreamingVadController(vadManager: vadManager)
            systemController.onChunkBoundary = { [weak self] in
                // Streaming VAD callbacks can arrive off-main; serialize chunk rotation explicitly.
                self?.chunkRotationQueue.async { [weak self] in
                    self?.rotateSystemChunkOnQueue()
                }
            }
            systemController.start()
            systemVadController = systemController
        } else {
            vadController = nil
            systemVadController = nil
        }
        neuralAec.resetForStreaming()
        meetingMicRecorder.onRawPCMSamples = { [weak self] samples in
            self?.enqueueRealtimeMicSamples(samples)
        }
        (meetingMicRecorder as? MeetingMicHandoffReporting)?.onHandoffResult = { [weak self] result in
            self?.chunkRotationQueue.async { [weak self] in
                self?.handleMicHandoffResultOnQueue(result)
            }
        }
        systemAudioRecorder.onPCMSamples = { [weak self] samples in
            self?.enqueueRealtimeSystemSamples(samples)
        }
        systemAudioRecorder.onSystemAudioFailure = { [weak self] error in
            self?.handleSystemAudioCaptureFailure(error)
        }
    }

    /// The meeting keeps recording the mic side, so the failure has to be
    /// surfaced rather than silently ending the "Others" track.
    private func handleSystemAudioCaptureFailure(_ error: Error) {
        fputs("[meeting] system audio capture stopped: \(error.localizedDescription)\n", stderr)
        Self.logger.error("System audio capture stopped mid-meeting: \(error.localizedDescription, privacy: .public)")
        onSystemAudioCaptureFailure?(error)
    }

    /// A microphone that delivers pure digital silence while the meeting is
    /// clearly audible (idle Bluetooth headset, lid-closed built-in, another app
    /// holding the device) loses the whole "You" track. One automatic handoff to
    /// a different input is worth more than a banner nobody reads mid-meeting.
    ///
    /// Runs on `chunkRotationQueue`, which owns `micFailoverPolicy`. Returns a
    /// refreshed snapshot only when a decision was recorded.
    private func applyMicFailoverIfNeededOnQueue(
        _ health: MeetingMicHealthSnapshot,
        now: Date
    ) -> MeetingMicHealthSnapshot? {
        guard health.sustainedZeroMicWhileSystemActive, !micFailoverPolicy.hasAttemptedFailover else { return nil }
        // System audio callbacks arrive continuously; re-deciding on each one
        // would query the route cache dozens of times a second for nothing.
        if let lastMicFailoverEvaluationAt, now.timeIntervalSince(lastMicFailoverEvaluationAt) < 1 { return nil }
        lastMicFailoverEvaluationAt = now
        guard let routeSnapshot = meetingInputRouteProvider?() else { return nil }

        let route = MeetingMicFailoverRoute(
            routeSnapshot: routeSnapshot,
            currentDeviceID: meetingMicRecorder.preferredInputDeviceID
        )
        switch micFailoverPolicy.evaluate(sustainedZeroMic: true, route: route, now: now) {
        case .wait:
            return nil
        case .noFallback(let record):
            let silent = Self.failoverDeviceDescription(id: record.silentDeviceID, name: record.silentDeviceName)
            fputs("[meeting] mic silent on \(silent); no distinct fallback input available\n", stderr)
            Self.logger.warning("Meeting mic silent with no fallback input available")
            return micHealthTracker.recordFailover(record, now: now)
        case .switchInput(let record):
            guard let fallbackDeviceID = record.fallbackDeviceID else { return nil }
            let silent = Self.failoverDeviceDescription(id: record.silentDeviceID, name: record.silentDeviceName)
            let fallback = Self.failoverDeviceDescription(id: fallbackDeviceID, name: record.fallbackDeviceName)
            fputs("[meeting] mic silent on \(silent); attempting capture switch to \(fallback)\n", stderr)
            Self.logger.warning("Meeting mic failover attempting capture switch to a fallback input")
            // The route-aware recorder treats a new preferred device as a
            // mid-recording handoff: it starts the candidate, waits for real
            // samples, and only then retires the silent one.
            micFailoverAttemptTracker.begin(record)
            micSessionRouteState.beginFailover(to: fallbackDeviceID, route: routeSnapshot)
            meetingMicRecorder.preferredInputDeviceID = fallbackDeviceID
            return nil
        }
    }

    private func handleMicHandoffResultOnQueue(_ result: MeetingMicHandoffResult) {
        guard let record = micFailoverAttemptTracker.resolve(result) else { return }
        let snapshot = micHealthTracker.recordFailover(record)
        if record.didSwitchInput {
            fputs("[meeting] microphone handoff completed after replacement produced audio\n", stderr)
            Self.logger.info("Meeting mic failover completed")
        } else {
            micSessionRouteState.failoverDidFail(deviceID: record.fallbackDeviceID)
            fputs("[meeting] microphone handoff failed: \(record.handoffErrorDescription ?? "unknown error")\n", stderr)
            Self.logger.error("Meeting mic failover failed")
        }
        // A handoff resolved during stop() still belongs in the diagnostics
        // above, but the meeting UI is tearing down — no banner.
        guard isRecording else { return }
        onMicHealthChanged?(snapshot)
    }

    private static func failoverDeviceDescription(id: AudioObjectID?, name: String?) -> String {
        let identifier = id.map(String.init) ?? "system-default"
        guard let name else { return identifier }
        return "\(identifier) (\(name))"
    }

    private func enqueueRealtimeMicSamples(_ rawSamples: [Int16]) {
        guard !rawSamples.isEmpty else { return }
        let callbackUptime = DispatchTime.now().uptimeNanoseconds
        let callbackDate = Date()

        chunkRotationQueue.async { [weak self] in
            guard let self, self.isRecording, !self.isPaused else { return }

            let healthSnapshot = self.micHealthTracker.noteRawMicSamples(rawSamples)
            self.onMicHealthChanged?(healthSnapshot)
            let recordingOffset = self.recordingOffsetOnQueue(
                for: .mic,
                sampleCount: rawSamples.count,
                callbackUptimeNanoseconds: callbackUptime,
                callbackDate: callbackDate
            )
            self.retainedRecordingWriter?.appendMic(rawSamples, atSampleOffset: recordingOffset)

            let floatSamples = rawSamples.map { Float($0) / 32767.0 }

            // AEC: clean mic using position-aligned system reference
            let cleanedFloat = self.neuralAec.processStreamingMic(floatSamples)
            self.appendCleanedMicSamplesOnQueue(cleanedFloat)

            // Meeting mic chunks must be driven by the cleaned mic stream. Raw
            // mic VAD sees speaker playback bleed and can create false `You`
            // chunks even when AEC removed that speech from the final mic audio.
            if let vadController = self.vadController, !cleanedFloat.isEmpty {
                vadController.processAudio(cleanedFloat)
            }
        }
    }

    private func enqueueRealtimeSystemSamples(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        let callbackUptime = DispatchTime.now().uptimeNanoseconds
        let callbackDate = Date()

        chunkRotationQueue.async { [weak self] in
            guard let self, self.isRecording, !self.isPaused else { return }

            let now = callbackDate
            let healthSnapshot = self.micHealthTracker.noteSystemSamples(samples, now: now)
            let failoverSnapshot = self.applyMicFailoverIfNeededOnQueue(healthSnapshot, now: now)
            self.onMicHealthChanged?(failoverSnapshot ?? healthSnapshot)
            let recordingOffset = self.recordingOffsetOnQueue(
                for: .system,
                sampleCount: samples.count,
                callbackUptimeNanoseconds: callbackUptime,
                callbackDate: callbackDate
            )
            self.retainedRecordingWriter?.appendSystem(samples, atSampleOffset: recordingOffset)
            self.systemChunkRecorder?.append(samples)
            self.systemChunkTimingTracker.append(sampleCount: samples.count)

            let floatSamples = samples.map { Float($0) / 32767.0 }
            self.feedSystemPartialSession(floatSamples)
            self.neuralAec.feedSystemSamples(floatSamples)
            let cleanedFloat = self.neuralAec.processStreamingMic([])
            self.appendCleanedMicSamplesOnQueue(cleanedFloat)

            if let vadController = self.vadController, !cleanedFloat.isEmpty {
                vadController.processAudio(cleanedFloat)
            }

            if let systemVadController = self.systemVadController {
                systemVadController.processAudio(floatSamples)
            }
        }
    }

    private func recordingOffsetOnQueue(
        for source: MeetingRecordingTimeline.Source,
        sampleCount: Int,
        callbackUptimeNanoseconds: UInt64,
        callbackDate: Date
    ) -> Int {
        let origin = MeetingCaptureOrigin(
            callbackEndUptimeNanoseconds: callbackUptimeNanoseconds,
            callbackEndDate: callbackDate,
            sampleCount: sampleCount
        )
        if retainedRecordingTimeline.startIfNeeded(at: origin.uptimeNanoseconds) {
            startTime = origin.wallClockDate
        }
        let sampleOffset = retainedRecordingTimeline.sampleStartOffset(
            for: source,
            sampleCount: sampleCount,
            callbackUptimeNanoseconds: callbackUptimeNanoseconds
        )
        switch source {
        case .mic:
            chunkTimingTracker.start(atSampleIndex: Int64(sampleOffset))
        case .system:
            systemChunkTimingTracker.start(atSampleIndex: Int64(sampleOffset))
        }
        return sampleOffset
    }

    private func appendCleanedMicSamplesOnQueue(_ cleanedFloat: [Float]) {
        guard !cleanedFloat.isEmpty else { return }
        // Single funnel for all AEC'd mic audio — the streaming partial tail
        // must consume exactly the stream the mic chunks record.
        feedMicPartialSession(cleanedFloat)
        let cleanedInt16 = cleanedFloat.map { sample -> Int16 in
            Int16(max(-1.0, min(1.0, sample)) * 32767)
        }
        rawMicChunkRecorder?.append(cleanedInt16)
        chunkTimingTracker.append(sampleCount: cleanedInt16.count)
        diagnostics?.appendCleanedMicSamples(cleanedInt16)
    }

    private func transcribeMicChunk(
        rawURL: URL?,
        chunkTiming: MeetingChunkTimingSnapshot?,
        isFinalChunk: Bool
    ) async -> [SpeechSegment] {
        defer {
            cleanupTemporaryChunkURLs(rawURL)
        }

        guard let chunkTiming, let rawURL else { return [] }

        let chunkOffset = chunkTiming.startTimeSeconds
        let chunkDuration = chunkTiming.durationSeconds
        let logPrefix = isFinalChunk ? "[meeting] transcribing final mic chunk" : "[meeting] transcribing mic chunk"

        return await transcribeMicChunk(
            at: rawURL,
            chunkOffset: chunkOffset,
            chunkDuration: chunkDuration,
            logPrefix: logPrefix
        ) ?? []
    }

    private func transcribeMicChunk(
        at url: URL,
        chunkOffset: TimeInterval,
        chunkDuration: TimeInterval,
        logPrefix: String
    ) async -> [SpeechSegment]? {
        fputs("\(logPrefix) (offset=\(String(format: "%.0f", chunkOffset))s, source=raw)\n", stderr)
        do {
            let result = try await transcriptionCoordinator.transcribeMeetingChunk(
                at: url,
                backend: currentBackend(),
                cohereLanguage: config.resolvedCohereLanguage,
                indicASRLanguage: config.resolvedIndicASRLanguage,
                customWords: config.customWords
            )
            if !result.text.isEmpty {
                fputs("[meeting] mic chunk transcribed (raw): \"\(String(result.text.prefix(60)))...\"\n", stderr)
                let normalizedSegments = MicTurnNormalizer.normalize(
                    result: result,
                    startTime: chunkOffset,
                    endTime: chunkOffset + max(chunkDuration, 0.1)
                )
                if normalizedSegments.isEmpty {
                    micChunkHealthTracker.noteEmptyChunk()
                } else {
                    micChunkHealthTracker.noteSuccessfulChunk()
                }
                return normalizedSegments
            }
            micChunkHealthTracker.noteEmptyChunk()
            return []
        } catch {
            micChunkHealthTracker.noteFailedChunk()
            fputs("[meeting] mic chunk transcription failed (raw): \(error)\n", stderr)
            return nil
        }
    }

    private func cleanupTemporaryChunkURLs(_ urls: URL?...) {
        urls.compactMap { $0 }.forEach { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func normalizeSystemTranscription(
        result: SpeechTranscriptionResult,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> [SpeechSegment] {
        SystemTurnNormalizer.normalize(
            result: result,
            startTime: startTime,
            endTime: endTime
        )
    }

    private func durationSeconds(from start: Date, to end: Date) -> Double {
        max(end.timeIntervalSince(start), 0)
    }

    private func repairSystemSegmentsIfNeeded(
        existingSystemSegments: [SpeechSegment],
        systemAudioURL: URL,
        meetingStart: Date,
        endTime: Date
    ) async -> MeetingTranscriptRecoveryResult {
        let totalDuration = durationSeconds(from: meetingStart, to: endTime)

        guard let vadManager = await transcriptionCoordinator.getVadManager() else {
            if existingSystemSegments.isEmpty {
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration
                ))
            }
            return .none
        }

        do {
            let samples = try AudioConverter().resampleAudioFile(systemAudioURL)
            let speechSegments = try await vadManager.segmentSpeech(
                samples,
                config: VadSegmentationConfig(maxSpeechDuration: 10.0, speechPadding: 0.15)
            )
            let health = MeetingTranscriptHealthMonitor.evaluate(
                existingSegments: existingSystemSegments,
                offlineSpeechSegments: speechSegments,
                chunkHealth: systemChunkHealthTracker.snapshot()
            )
            fputs("[meeting] system \(health.summaryLine.dropFirst("[meeting] ".count))\n", stderr)

            switch health.action {
            case .accept:
                return .none
            case .fullFallback(let reason):
                fputs("[meeting] transcript health triggered full system fallback: \(reason)\n", stderr)
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration
                ))
            case .selectiveRepair(let repairSegments):
                guard !repairSegments.isEmpty else { return .none }

                fputs("[meeting] repairing \(repairSegments.count) uncovered system speech regions\n", stderr)

                var repairedSegments: [SpeechSegment] = []
                for speechSegment in repairSegments {
                    let startSample = max(0, speechSegment.startSample(sampleRate: VadManager.sampleRate))
                    let endSample = min(samples.count, speechSegment.endSample(sampleRate: VadManager.sampleRate))
                    guard endSample > startSample else { continue }

                    let segmentURL = try MeetingMicRepairPlanner.writeTemporaryWAV(
                        samples: Array(samples[startSample..<endSample])
                    )
                    defer { try? FileManager.default.removeItem(at: segmentURL) }

                    let result = try await transcriptionCoordinator.transcribeMeeting(
                        at: segmentURL,
                        backend: currentBackend(),
                        cohereLanguage: config.resolvedCohereLanguage,
                        indicASRLanguage: config.resolvedIndicASRLanguage,
                        customWords: config.customWords
                    )
                    repairedSegments.append(contentsOf: normalizeSystemTranscription(
                        result: result,
                        startTime: speechSegment.startTime,
                        endTime: speechSegment.endTime
                    ))
                }
                return repairedSegments.isEmpty ? .none : .append(repairedSegments)
            }
        } catch {
            fputs("[meeting] system repair pass failed: \(error)\n", stderr)
            if existingSystemSegments.isEmpty {
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration
                ))
            }
            return .none
        }
    }

    private func fallbackToFullSessionSystemTranscription(
        systemAudioURL: URL,
        meetingDuration: Double
    ) async -> [SpeechSegment] {
        fputs("[meeting] no system chunks survived, falling back to full-session system transcription\n", stderr)
        do {
            let result = try await transcriptionCoordinator.transcribeMeeting(
                at: systemAudioURL,
                backend: currentBackend(),
                cohereLanguage: config.resolvedCohereLanguage,
                indicASRLanguage: config.resolvedIndicASRLanguage,
                customWords: config.customWords
            )
            return normalizeSystemTranscription(
                result: result,
                startTime: 0,
                endTime: meetingDuration
            )
        } catch {
            fputs("[meeting] full-session system fallback transcription failed: \(error)\n", stderr)
            return []
        }
    }
}
