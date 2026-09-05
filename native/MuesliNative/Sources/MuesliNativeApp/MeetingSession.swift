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

/// Retains only bounded recognizer text for local diagnostics. Entries are
/// ordered by the audio timeline rather than completion order because mic and
/// system chunk transcription can finish concurrently.
final class MeetingRawTranscriptAccumulator {
    enum Source: Int, Sendable {
        case microphone
        case system
    }

    private struct Entry {
        let start: TimeInterval
        let end: TimeInterval
        let source: Source
        let text: String
        let isBatchRecognizerOutput: Bool
    }

    private struct State {
        var entries: [Entry] = []
        var remainingBytes = SessionTraceRetentionPolicy.default.maximumArtifactBytes
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func appendBatch(
        _ result: SpeechTranscriptionResult,
        start: TimeInterval,
        end: TimeInterval,
        source: Source
    ) {
        append(
            result.text,
            start: start,
            end: max(end, start + 0.1),
            source: source,
            isBatchRecognizerOutput: true
        )
    }

    func appendStreamingSegmentsOutsideBatchEvidence(
        _ segments: [SpeechSegment],
        source: Source
    ) {
        lock.withLock { state in
            for segment in segments {
                let segmentEnd = max(segment.end, segment.start + 0.1)
                let isCoveredByBatch = state.entries.contains { entry in
                    entry.source == source
                        && entry.isBatchRecognizerOutput
                        && entry.start < segmentEnd
                        && entry.end > segment.start
                }
                guard !isCoveredByBatch else { continue }
                Self.append(
                    segment.text,
                    start: segment.start,
                    end: segmentEnd,
                    source: source,
                    isBatchRecognizerOutput: false,
                    state: &state
                )
            }
        }
    }

    func transcript() -> String {
        lock.withLock { state in
            state.entries
                .sorted { lhs, rhs in
                    if lhs.start != rhs.start { return lhs.start < rhs.start }
                    if lhs.source.rawValue != rhs.source.rawValue {
                        return lhs.source.rawValue < rhs.source.rawValue
                    }
                    return lhs.text < rhs.text
                }
                .map(\.text)
                .joined(separator: "\n")
        }
    }

    private func append(
        _ text: String,
        start: TimeInterval,
        end: TimeInterval,
        source: Source,
        isBatchRecognizerOutput: Bool
    ) {
        lock.withLock { state in
            Self.append(
                text,
                start: start,
                end: end,
                source: source,
                isBatchRecognizerOutput: isBatchRecognizerOutput,
                state: &state
            )
        }
    }

    private static func append(
        _ text: String,
        start: TimeInterval,
        end: TimeInterval,
        source: Source,
        isBatchRecognizerOutput: Bool,
        state: inout State
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let separatorBytes = state.entries.isEmpty ? 0 : 1
        guard state.remainingBytes > separatorBytes else { return }
        let bounded = utf8Prefix(
            text,
            maximumBytes: state.remainingBytes - separatorBytes
        )
        guard !bounded.isEmpty else { return }

        state.entries.append(Entry(
            start: start,
            end: end,
            source: source,
            text: bounded,
            isBatchRecognizerOutput: isBatchRecognizerOutput
        ))
        state.remainingBytes -= separatorBytes + bounded.utf8.count
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var byteCount = 0
        var end = value.startIndex
        for character in value {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= maximumBytes else { break }
            byteCount += characterBytes
            end = value.index(after: end)
        }
        return String(value[..<end])
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

enum MeetingSessionFallbackReason: String, Hashable, Sendable {
    case systemSelectiveRepair = "system_selective_repair"
    case systemFullTranscription = "system_full_transcription"
    case titleGeneration = "title_generation"
    case summaryGeneration = "summary_generation"
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
    /// Recording retention is frozen with the rest of the meeting capture
    /// configuration. Finalization must not re-read a setting that may have
    /// changed while the meeting was running.
    var languageProfile: LanguageProfile = .automatic
    var recordingSavePolicy: MeetingRecordingSavePolicy = .never
    var recordingFileFormat: MeetingRecordingFileFormat = .wav
    /// Screen/OCR context this summary was built from.
    ///
    /// Carried out of the session rather than discarded, so a regeneration after
    /// transcript cleanup can reproduce the same call. Without it, regenerating
    /// would quietly drop screen-derived detail and produce a worse summary than
    /// the one it replaced.
    var visualContext: String = ""
    /// Predecessor notes this summary was built from, for the same reason.
    var previousMeetingNotes: String = ""
    var usedSummaryFallback = false
    var fallbackReasons: Set<MeetingSessionFallbackReason> = []

    var usedFallback: Bool { usedSummaryFallback || !fallbackReasons.isEmpty }
}

extension MeetingSessionResult {
    /// Returns a copy with transcript, notes, and optional timing overrides.
    /// Used by the resume-recording flow to persist the merged transcript while
    /// keeping the original meeting date and accumulating only recorded duration.
    func overriding(
        startTime newStartTime: Date? = nil,
        durationSeconds newDurationSeconds: Double? = nil,
        rawTranscript: String,
        formattedNotes: String,
        visualContext newVisualContext: String? = nil
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
            languageProfile: languageProfile,
            recordingSavePolicy: recordingSavePolicy,
            recordingFileFormat: recordingFileFormat,
            visualContext: newVisualContext ?? visualContext,
            previousMeetingNotes: previousMeetingNotes,
            usedSummaryFallback: usedSummaryFallback,
            fallbackReasons: fallbackReasons
        )
    }
}

enum MeetingProcessingStage {
    case transcribingAudio
    case cleaningAudio
    case generatingTitle
    case summarizingNotes

    var allowsDictation: Bool {
        switch self {
        case .transcribingAudio, .cleaningAudio:
            false
        case .generatingTitle, .summarizingNotes:
            true
        }
    }
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

/// Translates AEC arrival positions to recording-timeline positions.
///
/// Cleaned mic audio leaves the AEC in frame-sized batches that lag the raw
/// callbacks (and can be held waiting for reference), so the reverse-leak
/// reference cannot be registered at the delivering callback's own timeline
/// offset. One range is appended per raw mic callback and consumed as cleaned
/// output is released. Accessed only from MeetingSession's chunkRotationQueue.
struct MeetingMicArrivalTimelineMap {
    struct Span: Equatable {
        /// Offset of this span inside the released batch.
        let offset: Int
        let count: Int
        let timelineStart: Int
    }

    private struct Entry {
        let arrivalStart: Int
        let timelineStart: Int
        let count: Int
    }

    private var entries: [Entry] = []
    private var arrivalCount = 0
    private var releasedCount = 0

    var pendingEntryCount: Int { entries.count }

    mutating func noteMicCallback(sampleCount: Int, timelineStart: Int) {
        guard sampleCount > 0 else { return }
        entries.append(Entry(
            arrivalStart: arrivalCount,
            timelineStart: timelineStart,
            count: sampleCount
        ))
        arrivalCount += sampleCount
    }

    /// Splits `count` released cleaned samples into timeline-contiguous spans.
    /// Samples past the last registered callback are dropped rather than
    /// misregistered; the AEC flush trims its own zero padding, so that only
    /// happens if a reset raced a release.
    mutating func consume(_ count: Int) -> [Span] {
        guard count > 0 else { return [] }
        var spans: [Span] = []
        var offset = 0
        var remaining = count
        while remaining > 0 {
            while let first = entries.first, first.arrivalStart + first.count <= releasedCount {
                entries.removeFirst()
            }
            guard let first = entries.first, releasedCount >= first.arrivalStart else { break }
            let take = min(remaining, first.arrivalStart + first.count - releasedCount)
            spans.append(Span(
                offset: offset,
                count: take,
                timelineStart: first.timelineStart + (releasedCount - first.arrivalStart)
            ))
            releasedCount += take
            offset += take
            remaining -= take
        }
        return spans
    }

    mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        arrivalCount = 0
        releasedCount = 0
    }
}

final class MeetingSession {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingSession")

    private struct TranscriptionAuthorityState {
        var backend: BackendOption
        var usesUnifiedNemotronTranscript: Bool
    }

    private let title: String
    private let calendarEventID: String?
    private let transcriptionAuthorityLock = OSAllocatedUnfairLock(
        initialState: TranscriptionAuthorityState(
            backend: .whisper,
            usesUnifiedNemotronTranscript: false
        )
    )
    private let runtime: RuntimePaths
    private let config: AppConfig
    /// The meeting spoken-language selection frozen when this meeting started.
    /// A settings save during the recording applies to the next meeting; only
    /// the decision derived from it follows a mid-meeting backend swap.
    let frozenLanguageSelection: TranscriptionLanguageSelection
    /// The meeting-derived legacy profile handed to every transcribe call. The
    /// runtime reads it only on the nil-decision branch, where a dictation-derived
    /// profile would pin Cohere and Indic to the wrong language.
    let frozenMeetingProfile: LanguageProfile
    private let templateSnapshot: MeetingTemplateSnapshot
    private let transcriptionCoordinator: TranscriptionCoordinator
    private let systemAudioRecorder: SystemAudioCapturing
    private let neuralAec: MeetingNeuralAec

    /// The gate decides per completed VAD frame: a shorter block would shrink
    /// the cleaned-mic lookahead the reference feed already has (A1).
    private static let systemGateBlockLength = StreamingVadFrameAccumulator.frameLength
    /// KTD6: intra-block timeline gaps up to the gate tolerance are ignored; a
    /// larger one closes the pending block early.
    private static let systemBlockGapToleranceSamples =
        MeetingReverseLeakSuppressor.toleranceFrames * MeetingReverseLeakSuppressor.frameLength

    /// Reverse-leak gate and its estimator. Accessed only from MeetingSession's
    /// chunkRotationQueue.
    private let reverseLeakSuppressor: MeetingReverseLeakSuppressor
    /// Re-blocks the gated system stream into whole VAD frames; the pending
    /// remainder belongs to the next chunk and never reaches the controller (R16).
    private var systemVadFrameAccumulator = StreamingVadFrameAccumulator()
    /// Raw system samples waiting to complete a gate block, with the timeline
    /// and arrival positions of their first sample.
    private var pendingSystemBlock: [Int16] = []
    private var pendingSystemBlockTimelineStart = 0
    private var pendingSystemBlockArrivalStart = 0
    /// Running count of every raw system sample the recorder delivered,
    /// advanced before the recording/paused guard so it stays equal to the raw
    /// system file's length across pauses (KTD7).
    private var systemArrivalSampleCount = 0
    /// Ordered arrival-to-timeline ranges, one per raw mic callback (KTD6).
    private var micArrivalTimeline = MeetingMicArrivalTimelineMap()

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
    private let rawTranscriptAccumulator = MeetingRawTranscriptAccumulator()
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
    private let micRecoveryCoordinator = MeetingMicRecoveryCoordinator()
    private let systemAudioWatchdog = MeetingSystemAudioWatchdog()
    private var systemAudioWatchdogTimer: DispatchSourceTimer?
    private let chunkRotationQueue = DispatchQueue(label: "MuesliNative.MeetingSession.chunkRotation")
    private let pausedDisplayLock = OSAllocatedUnfairLock(initialState: false)
    private var chunkTimingTracker = MeetingChunkTimingTracker()
    private var systemChunkTimingTracker = MeetingChunkTimingTracker()
    /// Set after a system-capture interruption so the first recovered callback
    /// preserves the wall-clock gap instead of compressing the transcript.
    private var systemChunkNeedsTimelineRealignment = false
    private var systemChunkRecorder: PCMChunkRecorder?
    var onProgress: ((MeetingProcessingStage) -> Void)?
    var onMicHealthChanged: ((MeetingMicHealthSnapshot) -> Void)?
    /// Live input-route facts for silent-mic failover. Read on the chunk
    /// rotation queue, so it must not block on CoreAudio.
    var meetingInputRouteProvider: (() -> MeetingMicRouteDiagnosticsSnapshot?)?
    /// System audio capture is interrupted and background recovery is taking
    /// longer than expected. Called on a background thread.
    var onSystemAudioCaptureFailure: ((Error) -> Void)?
    /// A reported system-audio interruption produced samples again.
    var onSystemAudioCaptureRecovered: (() -> Void)?
    /// Episode-level mic-health events: one degraded/recovered pair per actual
    /// degradation episode, or a single unrecovered event if the meeting ends
    /// while degraded. Feed telemetry here; keep per-snapshot UI updates on
    /// onMicHealthChanged.
    var onMicHealthEpisode: ((MeetingMicHealthEpisodeEvent) -> Void)?
    /// Fired at most once per meeting when confirmed degradation is classified
    /// as user-muted input (no recovery episode is opened in that case).
    var onMicHealthUserMuted: (() -> Void)?
    /// Episode-level system-audio (tap) health events: degraded when the IO
    /// heartbeat stalls or a rebuild fails terminally, recovered when capture
    /// resumes, unrecovered if the meeting ends dead.
    var onSystemAudioHealthEpisode: ((MeetingSystemAudioHealthEvent) -> Void)?
    var manualNotesProvider: (() async -> String?)?
    var liveTitleProvider: (() async -> String?)?
    /// Formatted notes of the predecessor meeting when this session records a
    /// follow-up; injected into the summary prompt for action-item carry-forward.
    var previousMeetingNotes: String?
    var onChunkTranscribed: (([SpeechSegment], String) -> Void)?
    /// Fires synchronously on `chunkRotationQueue` with a rotated system chunk
    /// and its timing, after the rotate and before the transcription task that
    /// deletes the file, and again in `stop` for the final chunk. Test seam.
    var onSystemChunkRotated: ((URL, MeetingChunkTimingSnapshot) -> Void)?
    /// The exact stream `appendProcessedSystemSamplesOnQueue` releases — what a
    /// system partial session consumes when caption models are downloaded. Test seam.
    var onProcessedSystemSamples: (([Float]) -> Void)?
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
    private let sessionTrace: SessionRunTrace?

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
        meetingMicRecorder: MeetingMicRecording = RouteAwareMeetingMicRecorder(),
        systemAudioRecorder injectedSystemAudioRecorder: SystemAudioCapturing? = nil,
        neuralAec injectedNeuralAec: MeetingNeuralAec? = nil,
        sessionTrace: SessionRunTrace? = nil
    ) {
        self.title = title
        self.calendarEventID = calendarEventID
        transcriptionAuthorityLock.withLock {
            $0.backend = backend
            $0.usesUnifiedNemotronTranscript = config.usesUnifiedNemotronMeetingTranscript
        }
        self.runtime = runtime
        self.config = config
        self.frozenLanguageSelection = config.meetingSpokenLanguage.selection
        self.frozenMeetingProfile = config.meetingLanguageProfile
        self.templateSnapshot = templateSnapshot
        self.transcriptionCoordinator = transcriptionCoordinator
        self.meetingMicRecorder = meetingMicRecorder
        self.neuralAec = injectedNeuralAec ?? MeetingNeuralAec()
        // KTD8: config and environment are resolved once, at meeting start.
        self.reverseLeakSuppressor = MeetingReverseLeakSuppressor(
            enabled: config.meetingReverseLeakSuppression
                && !MeetingReverseLeakSuppressor.isDisabledByEnvironment()
        )
        self.sessionTrace = sessionTrace
        self.micSessionRouteState = MeetingMicSessionRouteState(
            configuredDeviceID: meetingMicRecorder.preferredInputDeviceID
        )
        if let injectedSystemAudioRecorder {
            self.systemAudioRecorder = injectedSystemAudioRecorder
        } else if config.useCoreAudioTap {
            self.systemAudioRecorder = CoreAudioSystemRecorder()
        } else {
            self.systemAudioRecorder = SystemAudioRecorder()
        }
        micRecoveryCoordinator.recoveryRequest = { [weak meetingMicRecorder] reason in
            guard let meetingMicRecorder else { return .unavailable }
            return meetingMicRecorder.requestSameRouteRecovery(reason: reason)
        }
        // Recovery handoffs mid-transition reliably fail their first-buffer
        // window; defer them until the daemon settles (same signal the tap
        // watchdog uses — BT transitions move input and output together).
        micRecoveryCoordinator.isRouteSettling = { [weak systemAudioRecorder] in
            systemAudioRecorder?.isRouteSettling ?? false
        }
        micRecoveryCoordinator.onEpisodeEvent = { [weak self] event in
            self?.onMicHealthEpisode?(event)
        }
        micRecoveryCoordinator.isInputMuted = { [weak self] in
            self?.isCaptureInputMuted() ?? false
        }
        micRecoveryCoordinator.onUserMuted = { [weak self] in
            self?.onMicHealthUserMuted?()
        }
        micRecoveryCoordinator.contextProvider = { [weak meetingMicRecorder] in
            guard let snapshot = meetingMicRecorder?.diagnosticsSnapshot() else {
                return MeetingMicEpisodeContext()
            }
            return MeetingMicEpisodeContext(
                recorderKind: snapshot.recorderKind.rawValue,
                routeCategory: snapshot.route?.outputRouteKind,
                selectedInputResolved: snapshot.route?.selectedInputDeviceResolved
            )
        }
        meetingMicRecorder.onHandoffOutcome = { [weak micRecoveryCoordinator] outcome in
            micRecoveryCoordinator?.noteHandoffOutcome(outcome)
        }
        systemAudioWatchdog.captureHeartbeat = { [weak systemAudioRecorder] in
            systemAudioRecorder?.captureHeartbeat ?? 0
        }
        systemAudioWatchdog.isCaptureActive = { [weak systemAudioRecorder] in
            guard let recorder = systemAudioRecorder else { return false }
            return recorder.isRecording && !recorder.isPaused && !recorder.isRebuilding
        }
        systemAudioWatchdog.isPaused = { [weak systemAudioRecorder] in
            systemAudioRecorder?.isPaused ?? false
        }
        systemAudioWatchdog.isRouteSettling = { [weak systemAudioRecorder] in
            systemAudioRecorder?.isRouteSettling ?? false
        }
        systemAudioWatchdog.lastMicCallbackAt = { [weak self] in
            self?.micHealthTracker.snapshot().lastRawMicCallbackAt
        }
        systemAudioWatchdog.recoveryRequest = { [weak systemAudioRecorder] reason in
            systemAudioRecorder?.rebuildForHealthRecovery(reason: reason) ?? false
        }
        systemAudioWatchdog.onMicBlindnessDegradation = { [weak micRecoveryCoordinator] reason in
            micRecoveryCoordinator?.noteExternalDegradation(reason: reason)
        }
        systemAudioWatchdog.onEpisodeEvent = { [weak self] event in
            self?.onSystemAudioHealthEpisode?(event)
        }
        systemAudioRecorder.onCaptureFailure = { [weak systemAudioWatchdog] error in
            systemAudioWatchdog?.noteCaptureFailure(reason: "rebuild_exhausted: \(error.localizedDescription)")
        }
    }

    func updateTranscriptionAuthority(
        backend: BackendOption,
        usesUnifiedNemotronTranscript: Bool
    ) {
        transcriptionAuthorityLock.withLock {
            $0.backend = backend
            $0.usesUnifiedNemotronTranscript = usesUnifiedNemotronTranscript
        }
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

    /// True when the capture device is muted or zero-gain at the source (user
    /// intent), which presents the same all-zero signature as a broken route.
    /// Called by the coordinator at episode confirmation and at most 1Hz while
    /// a suppressed degradation continues — never per sample batch.
    private func isCaptureInputMuted() -> Bool {
        var deviceID = meetingMicRecorder.preferredInputDeviceID ?? kAudioObjectUnknown
        if deviceID == kAudioObjectUnknown {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
            ) == noErr, deviceID != kAudioObjectUnknown else { return false }
        }
        // Volume and mute controls may live on the main element (0) or on any
        // input channel. Enumerate the device's actual input channel count via
        // the stream configuration and probe every channel; a read failure
        // just means "no control there".
        var elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain]
        var configAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var configSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &configAddress, 0, nil, &configSize) == noErr, configSize > 0 {
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(configSize),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { raw.deallocate() }
            if AudioObjectGetPropertyData(deviceID, &configAddress, 0, nil, &configSize, raw) == noErr {
                let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                let channelCount = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
                if channelCount > 0 {
                    elements.append(contentsOf: (1...channelCount).map { AudioObjectPropertyElement($0) })
                }
            }
        }
        for element in elements {
            var volumeAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: element
            )
            var volume: Float32 = 1
            var volumeSize = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &volumeAddress, 0, nil, &volumeSize, &volume) == noErr,
               volume <= 0.0001 {
                return true
            }
            var muteAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: element
            )
            var muted: UInt32 = 0
            var muteSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &muteSize, &muted) == noErr,
               muted != 0 {
                return true
            }
        }
        return false
    }

    private func currentBackend() -> BackendOption {
        transcriptionAuthorityLock.withLock { $0.backend }
    }

    /// The decision a meeting transcription call hands the runtime: the frozen
    /// meeting selection resolved against the backend that call just read.
    /// Nil for every incompatibility, so the call keeps its legacy language
    /// arguments instead of receiving a value the runtime throws on. Callers
    /// pass `isAvailable: true` because an unavailable model still fails at
    /// load, exactly as it does today. Retranscription and file import resolve
    /// through here too, with their own workloads.
    nonisolated static func meetingLanguageDecision(
        selection: TranscriptionLanguageSelection,
        backend: BackendOption,
        workload: TranscriptionWorkload
    ) -> LanguageRoutingDecision? {
        TranscriptionLanguageRouter.runtimeDecision(
            selection: selection,
            capabilities: backend.languageCapabilities(isAvailable: true),
            workload: workload
        )
    }

    /// The live-caption `prompt_id`: the same selection resolved against
    /// Nemotron's own capabilities with `.meetingLive`, then mapped by the one
    /// decision-to-prompt-id owner, so the Settings footer and the engine agree
    /// by construction. `MeetingLiveCaptionBackend` is not a `BackendOption`,
    /// which is why the capabilities are named here.
    nonisolated static func liveCaptionNemotronPromptId(
        selection: TranscriptionLanguageSelection
    ) -> Int32 {
        let decision = meetingLanguageDecision(
            selection: selection,
            backend: .nemotron35Multilingual,
            workload: .meetingLive
        )
        return Nemotron35Language.promptId(for: decision ?? .automatic)
    }

    private func meetingFinalLanguageDecision(
        backend: BackendOption
    ) -> LanguageRoutingDecision? {
        Self.meetingLanguageDecision(
            selection: frozenLanguageSelection,
            backend: backend,
            workload: .meetingFinal
        )
    }

    func usesLiveNemotronTranscriptAsFinal() -> Bool {
        transcriptionAuthorityLock.withLock { $0.usesUnifiedNemotronTranscript }
    }

    func start() async throws {
        let vadManager = await transcriptionCoordinator.getVadManager()
        let requestedStart = Date()
        await sessionTrace?.recordStageStarted("meeting_capture")
        diagnostics = MeetingSessionDiagnostics(startedAt: requestedStart)

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
            systemChunkNeedsTimelineRealignment = false
            resetSystemGateBufferingOnQueue()
            systemArrivalSampleCount = 0
            // A new meeting is the only other place suppressed intervals go (KTD7).
            reverseLeakSuppressor.discard()
            isRecording = true
            setPausedStateOnQueue(false)
        }

        do {
            try prepareRealtimeAudioPipeline(vadManager: vadManager)
            try meetingMicRecorder.prepare()
            setupRetainedRecordingWriterIfNeeded()
            try await systemAudioRecorder.start()
            startSystemAudioWatchdog()
            try meetingMicRecorder.start()
        } catch {
            await sessionTrace?.recordStageFailed(
                "meeting_capture",
                elapsedMilliseconds: max(Int(Date().timeIntervalSince(requestedStart) * 1_000), 0)
            )
            stopSystemAudioWatchdog()
            vadController?.stop()
            vadController = nil
            systemVadController?.stop()
            systemVadController = nil
            meetingMicRecorder.onRawPCMSamples = nil
            (meetingMicRecorder as? MeetingMicHandoffReporting)?.onHandoffResult = nil
            systemAudioRecorder.onPCMSamples = nil
            systemAudioRecorder.onSystemAudioInterruption = nil
            systemAudioRecorder.onSystemAudioFailure = nil
            systemAudioRecorder.onSystemAudioRecovery = nil
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
                systemChunkNeedsTimelineRealignment = false
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
        await sessionTrace?.recordStageCompleted(
            "meeting_capture",
            elapsedMilliseconds: max(Int(Date().timeIntervalSince(requestedStart) * 1_000), 0)
        )
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
                        nemotronPromptId: Self.liveCaptionNemotronPromptId(
                            selection: self.frozenLanguageSelection
                        ),
                        sharedNemotron35: shared
                    )
                } else {
                    engines = try await MeetingLiveCaptionModelStore.makeEngines(
                        backend: backend,
                        nemotronPromptId: Self.liveCaptionNemotronPromptId(
                            selection: self.frozenLanguageSelection
                        )
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
        let prefersStreamingTranscript = usesLiveNemotronTranscriptAsFinal()
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
            flushPendingSystemBlockOnQueue()
            rotateChunkOnQueue()
            rotateSystemChunkOnQueue()
            retainedRecordingTimeline.pause(at: pauseUptime)
            retainedRecordingWriter?.markPauseBoundary()
            neuralAec.resetForStreaming()
            // AEC arrival positions restart at zero with the reset above.
            micArrivalTimeline.reset()
            reverseLeakSuppressor.reset()
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
            systemChunkNeedsTimelineRealignment = false
            resetSystemGateBufferingOnQueue()
            systemArrivalSampleCount = 0
            micArrivalTimeline.reset()
            // Only `discard` and a new `start` drop the suppressed intervals (KTD7).
            reverseLeakSuppressor.discard()
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
        // Same contract as stop(): the queue barrier above drains pending
        // sample callbacks; only then is episode state final.
        micRecoveryCoordinator.finishMeeting()
        stopSystemAudioWatchdog()
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
        systemAudioRecorder.onSystemAudioInterruption = nil
        systemAudioRecorder.onSystemAudioFailure = nil
        systemAudioRecorder.onSystemAudioRecovery = nil
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
        let finalizationStartedAt = Date()
        await sessionTrace?.recordStageStarted("meeting_finalization")
        await sessionTrace?.recordStageStarted("transcribing_audio")
        let endTime = Date()
        var micSegments: [SpeechSegment] = []
        var systemSegments: [SpeechSegment] = []
        var fallbackReasons: Set<MeetingSessionFallbackReason> = []
        let usesUnifiedNemotronTranscript = usesLiveNemotronTranscriptAsFinal()

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
        systemAudioRecorder.onSystemAudioInterruption = nil
        systemAudioRecorder.onSystemAudioFailure = nil
        systemAudioRecorder.onSystemAudioRecovery = nil
        let teardown = finishRealtimeCapture()
        let meetingStart = teardown.meetingStart
        let lastChunkTiming = teardown.micChunkTiming
        let lastRawMicURL = teardown.micChunkURL
        let lastSystemChunkTiming = teardown.systemChunkTiming
        let lastSystemChunkURL = teardown.systemChunkURL
        // The chunkRotationQueue barrier above guarantees every sample callback
        // enqueued before teardown has been processed and that later callbacks
        // bail on isRecording == false. Only now is the coordinator's episode
        // state final; close any open degradation episode as unrecovered.
        micRecoveryCoordinator.finishMeeting()
        // Cancel the watchdog before stopping the recorder so no late tick can
        // request a rebuild mid-teardown, then terminalize any open tap
        // episode.
        stopSystemAudioWatchdog()
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
                    let backend = currentBackend()
                    let evidence = try await transcriptionCoordinator.transcribeMeetingChunkWithEvidence(
                        at: lastSystemChunkURL,
                        backend: backend,
                        languageDecision: meetingFinalLanguageDecision(backend: backend),
                        profile: frozenMeetingProfile,
                        appleSpeechLanguage: config.resolvedAppleSpeechLanguage,
                        customWords: config.customWords
                    )
                    rawTranscriptAccumulator.appendBatch(
                        evidence.raw,
                        start: chunkOffset,
                        end: chunkOffset + max(chunkDuration, 0.1),
                        source: .system
                    )
                    let normalizedSegments = normalizeSystemTranscription(
                        result: evidence.cleaned,
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
                fallbackReasons.insert(.systemSelectiveRepair)
                systemSegments.append(contentsOf: repairedSystemSegments)
                systemSegments.sort { lhs, rhs in
                    if lhs.start == rhs.start {
                        return lhs.text < rhs.text
                    }
                    return lhs.start < rhs.start
                }
            case .replace(let fallbackSystemSegments):
                fallbackReasons.insert(.systemFullTranscription)
                systemSegments = fallbackSystemSegments.sorted { lhs, rhs in
                    if lhs.start == rhs.start {
                        return lhs.text < rhs.text
                    }
                    return lhs.start < rhs.start
                }
            }
        }

        rawTranscriptAccumulator.appendStreamingSegmentsOutsideBatchEvidence(
            micSegments,
            source: .microphone
        )
        rawTranscriptAccumulator.appendStreamingSegmentsOutsideBatchEvidence(
            systemSegments,
            source: .system
        )

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
        let recognizerTranscript = rawTranscriptAccumulator.transcript()
        let transcriptionElapsedMilliseconds = max(
            Int(Date().timeIntervalSince(finalizationStartedAt) * 1_000),
            0
        )
        for reason in fallbackReasons where
            reason == .systemSelectiveRepair || reason == .systemFullTranscription {
            await sessionTrace?.recordFallbackStarted(
                "transcribing_audio",
                metadata: ["reason": reason.rawValue]
            )
        }
        await sessionTrace?.recordStageCompleted(
            "transcribing_audio",
            elapsedMilliseconds: transcriptionElapsedMilliseconds,
            metadata: ["output_characters": String(rawTranscript.count)]
        )
        await sessionTrace?.storeArtifact(recognizerTranscript, kind: .rawASR)
        await sessionTrace?.storeArtifact(rawTranscript, kind: .cleanupResult)
        await sessionTrace?.storeArtifact(
            DictationDictionaryTrace.emptyContent,
            kind: .dictionaryChanges
        )
        await sessionTrace?.storeArtifact(rawTranscript, kind: .finalOutput)

        let titleManualNotes = await manualNotesProvider?()
        let generatedTitle: String
        var usedTitleFallback = false
        onProgress?(.generatingTitle)
        let titleStartedAt = Date()
        await sessionTrace?.recordStageStarted("title_generation")
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
            fallbackReasons.insert(.titleGeneration)
            usedTitleFallback = true
        }
        let titleElapsedMilliseconds = max(
            Int(Date().timeIntervalSince(titleStartedAt) * 1_000),
            0
        )
        if usedTitleFallback {
            await sessionTrace?.recordFallbackStarted(
                "title_generation",
                metadata: ["reason": MeetingSessionFallbackReason.titleGeneration.rawValue]
            )
        }
        await sessionTrace?.recordStageCompleted(
            "title_generation",
            elapsedMilliseconds: titleElapsedMilliseconds,
            metadata: usedTitleFallback ? ["outcome": "fallback"] : [:]
        )

        let visualContext = await screenContextCollector.stopAndDrain()
        Self.logger.info("visual context drained chars=\(visualContext.count) includedInPrompt=\(!visualContext.isEmpty) useOCR=\(self.config.useCoreAudioTap)")
        fputs("[meeting] visual context drained chars=\(visualContext.count) includedInPrompt=\(!visualContext.isEmpty) useOCR=\(config.useCoreAudioTap)\n", stderr)
        onProgress?(.summarizingNotes)
        let summaryStartedAt = Date()
        await sessionTrace?.recordStageStarted("summary_generation")
        let manualNotes = await manualNotesProvider?()
        let formattedNotes: String
        let usedSummaryFallback: Bool
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
            usedSummaryFallback = false
        } catch {
            usedSummaryFallback = true
            fallbackReasons.insert(.summaryGeneration)
            fputs("[meeting] summary generation failed: \(error.localizedDescription)\n", stderr)
            formattedNotes = MeetingSummaryClient.summaryFailureNotes(
                transcript: rawTranscript,
                meetingTitle: generatedTitle,
                error: error,
                manualNotes: manualNotes,
                languageProfile: frozenMeetingProfile
            )
        }
        let summaryElapsedMilliseconds = max(
            Int(Date().timeIntervalSince(summaryStartedAt) * 1_000),
            0
        )
        if usedSummaryFallback {
            await sessionTrace?.recordFallbackStarted(
                "summary_generation",
                metadata: ["reason": MeetingSessionFallbackReason.summaryGeneration.rawValue]
            )
        }
        await sessionTrace?.recordStageCompleted(
            "summary_generation",
            elapsedMilliseconds: summaryElapsedMilliseconds,
            metadata: usedSummaryFallback ? ["outcome": "fallback"] : [:]
        )
        await sessionTrace?.storeArtifact(visualContext, kind: .contextSources)
        await sessionTrace?.recordStageCompleted(
            "meeting_finalization",
            elapsedMilliseconds: max(Int(Date().timeIntervalSince(finalizationStartedAt) * 1_000), 0)
        )

        diagnostics?.writeFinalReport(
            startedAt: meetingStart,
            endedAt: endTime,
            systemCapture: (systemAudioRecorder as? SystemAudioDiagnosticsProviding)?.diagnosticsSnapshot,
            micRecorder: meetingMicRecorder.diagnosticsSnapshot(),
            micHealth: micHealthTracker.snapshot(),
            aec: neuralAec.diagnosticsSnapshot,
            micChunks: micChunkHealthTracker.snapshot(),
            systemChunks: systemChunkHealthTracker.snapshot(),
            diarizationSegments: protectedTranscriptInputs.diarizationSegments,
            protectedSystemSegmentCount: protectedTranscriptInputs.systemSegments.count,
            reverseLeak: reverseLeakDiagnosticsSnapshot()
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
            languageProfile: frozenMeetingProfile,
            recordingSavePolicy: config.meetingRecordingSavePolicy,
            recordingFileFormat: config.resolvedMeetingRecordingFileFormat,
            visualContext: visualContext,
            previousMeetingNotes: previousMeetingNotes ?? "",
            usedSummaryFallback: usedSummaryFallback,
            fallbackReasons: fallbackReasons
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

    struct RealtimeCaptureTeardown {
        let meetingStart: Date
        let micChunkTiming: MeetingChunkTimingSnapshot?
        let micChunkURL: URL?
        let systemChunkTiming: MeetingChunkTimingSnapshot?
        let systemChunkURL: URL?
    }

    /// Ends realtime capture: flushes both partial buffers, finalises the chunk
    /// files and freezes the timing trackers. `stop()` calls it before its
    /// transcription and summarisation tail; harnesses call it to reach the
    /// same final-chunk state without that tail.
    @discardableResult
    func finishRealtimeCapture() -> RealtimeCaptureTeardown {
        chunkRotationQueue.sync { finishRealtimeCaptureOnQueue() }
    }

    private func finishRealtimeCaptureOnQueue() -> RealtimeCaptureTeardown {
        isRecording = false
        setPausedStateOnQueue(false)

        // Flush partial AEC frame before stopping chunk recorder
        appendFlushedStreamingMicOnQueue()
        // The gate's pending block belongs to the final chunk, and the funnel
        // deliberately does not guard on the flag cleared just above.
        flushPendingSystemBlockOnQueue()

        let meetingStart = self.startTime ?? self.captureRequestedStartTime ?? Date()
        micSessionRouteState.endSession()
        let lastRawMicURL = rawMicChunkRecorder?.stop()
        let lastSystemChunkURL = systemChunkRecorder?.stop()
        rawMicChunkRecorder = nil
        systemChunkRecorder = nil
        let lastChunkTiming = chunkTimingTracker.finish()
        let lastSystemChunkTiming = systemChunkTimingTracker.finish()
        systemChunkNeedsTimelineRealignment = false
        if let lastSystemChunkURL, let lastSystemChunkTiming {
            onSystemChunkRotated?(lastSystemChunkURL, lastSystemChunkTiming)
        }
        return RealtimeCaptureTeardown(
            meetingStart: meetingStart,
            micChunkTiming: lastChunkTiming,
            micChunkURL: lastRawMicURL,
            systemChunkTiming: lastSystemChunkTiming,
            systemChunkURL: lastSystemChunkURL
        )
    }

    /// Live disable (R14): the gate opens for the running meeting while the
    /// estimator keeps running for diagnostics. Idempotent, and safe on a
    /// session that has not started capture yet.
    func forceOpenReverseLeakGate() {
        chunkRotationQueue.async { [weak self] in
            self?.reverseLeakSuppressor.forceOpen()
        }
    }

    /// Live enable (R14): gating resumes from the estimator's current lock
    /// state. Idempotent.
    func releaseReverseLeakGate() {
        chunkRotationQueue.async { [weak self] in
            self?.reverseLeakSuppressor.release()
        }
    }

    func reverseLeakDiagnosticsSnapshot() -> MeetingReverseLeakDiagnosticsSnapshot {
        chunkRotationQueue.sync { reverseLeakSuppressor.diagnosticsSnapshot }
    }

    /// Suppressed spans in the raw system file's frame (KTD7).
    /// Records how much offline speech fell inside suppressed spans, so the field data can
    /// bound the false-suppression rate before the gate's thresholds are tightened (KTD9).
    private func noteOfflineSpeechInsideSuppressedIntervals(_ seconds: Double) {
        chunkRotationQueue.sync {
            reverseLeakSuppressor.noteOfflineSpeechSecondsInsideSuppressedIntervals(seconds)
        }
    }

    func suppressedSystemIntervals() -> [MeetingSuppressedInterval] {
        chunkRotationQueue.sync { reverseLeakSuppressor.exportSuppressedIntervals() }
    }

    /// Test seam: the running count of raw system samples, which must stay
    /// equal to the raw system file's length across pauses (KTD7, A8).
    var systemArrivalSampleCountForTesting: Int {
        chunkRotationQueue.sync { systemArrivalSampleCount }
    }

    /// Test seam: the live failover path only reaches the handoff handler after
    /// seconds of confirmed silent mic, so harnesses prime the pending attempt
    /// and let the real handler resolve it.
    func applyMicHandoffResultForTesting(
        record: MeetingMicFailoverRecord,
        result: MeetingMicHandoffResult
    ) {
        chunkRotationQueue.sync {
            micFailoverAttemptTracker.begin(record)
            handleMicHandoffResultOnQueue(result)
        }
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

    /// The system VAD boundary closure's dispatch, reachable without a
    /// `VadManager` so harnesses can drive chunk rotation.
    func rotateSystemChunk() {
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

        onSystemChunkRotated?(chunkURL, chunkTiming)

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
                let evidence = try await self.transcriptionCoordinator.transcribeMeetingChunkWithEvidence(
                    at: chunkURL,
                    backend: backend,
                    languageDecision: self.meetingFinalLanguageDecision(backend: backend),
                    profile: self.frozenMeetingProfile,
                    appleSpeechLanguage: config.resolvedAppleSpeechLanguage,
                    customWords: config.customWords
                )
                self.rawTranscriptAccumulator.appendBatch(
                    evidence.raw,
                    start: chunkOffset,
                    end: chunkOffset + max(chunkDuration, 0.1),
                    source: .system
                )
                let result = evidence.cleaned
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

    private func startSystemAudioWatchdog() {
        // Only heartbeat-capable backends can be stall-monitored: the SCK
        // fallback reports heartbeat 0 permanently and would false-fire
        // degraded episodes every meeting.
        guard systemAudioRecorder.supportsHeartbeatMonitoring else { return }
        stopSystemAudioWatchdogTimer()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "MuesliNative.MeetingSession.systemAudioWatchdog"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak systemAudioWatchdog] in
            systemAudioWatchdog?.tick()
        }
        systemAudioWatchdogTimer = timer
        timer.resume()
    }

    /// Cancel the tick timer (no late rebuilds mid-teardown) and terminalize
    /// any open tap episode. Safe to call from stop() and discard().
    private func stopSystemAudioWatchdog() {
        stopSystemAudioWatchdogTimer()
        systemAudioWatchdog.finishMeeting()
    }

    private func stopSystemAudioWatchdogTimer() {
        systemAudioWatchdogTimer?.cancel()
        systemAudioWatchdogTimer = nil
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
        // AEC arrival positions restart at zero with the reset above.
        micArrivalTimeline.reset()
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
        systemAudioRecorder.onSystemAudioInterruption = { [weak self] in
            self?.handleSystemAudioCaptureInterruption()
        }
        systemAudioRecorder.onSystemAudioFailure = { [weak self] error in
            self?.handleSystemAudioCaptureFailure(error)
        }
        systemAudioRecorder.onSystemAudioRecovery = { [weak self] in
            self?.handleSystemAudioCaptureRecovery()
        }
    }

    /// The mic side continues while the recorder retries the system side. Rotate
    /// every interrupted chunk so resumed audio retains its real time gap, even
    /// when the first tap rebuild succeeds and no user warning is needed.
    private func handleSystemAudioCaptureInterruption() {
        chunkRotationQueue.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.flushPendingSystemBlockOnQueue()
            self.reverseLeakSuppressor.reset()
            self.rotateSystemChunkOnQueue()
            self.systemChunkNeedsTimelineRealignment = true
        }
    }

    private func handleSystemAudioCaptureFailure(_ error: Error) {
        fputs("[meeting] system audio capture interrupted; recovery continues: \(error.localizedDescription)\n", stderr)
        Self.logger.error("System audio capture interrupted mid-meeting; recovery continues: \(error.localizedDescription, privacy: .public)")
        onSystemAudioCaptureFailure?(error)
    }

    private func handleSystemAudioCaptureRecovery() {
        fputs("[meeting] system audio capture recovered\n", stderr)
        Self.logger.info("System audio capture recovered mid-meeting")
        onSystemAudioCaptureRecovered?()
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
            // A different input invalidates the registration offset (R7).
            reverseLeakSuppressor.reset()
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
            self.micRecoveryCoordinator.process(healthSnapshot)
            let recordingOffset = self.recordingOffsetOnQueue(
                for: .mic,
                sampleCount: rawSamples.count,
                callbackUptimeNanoseconds: callbackUptime,
                callbackDate: callbackDate
            )
            self.retainedRecordingWriter?.appendMic(rawSamples, atSampleOffset: recordingOffset)

            let floatSamples = rawSamples.map { Float($0) / 32767.0 }

            // The forward-residual exclusion compares raw against cleaned mic
            // energy at the same timeline position (KTD4); the cleaned side is
            // registered as the AEC releases it.
            self.reverseLeakSuppressor.feedRawMicSamples(floatSamples, timelineStartSample: recordingOffset)
            self.micArrivalTimeline.noteMicCallback(
                sampleCount: rawSamples.count,
                timelineStart: recordingOffset
            )

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
            guard let self else { return }
            // KTD7: the recorder wrote these samples to the raw file before
            // invoking the session, so the arrival counter advances even for
            // callbacks the guard below drops.
            let arrivalStart = self.systemArrivalSampleCount
            self.systemArrivalSampleCount += samples.count
            guard self.isRecording, !self.isPaused else { return }

            let now = callbackDate
            let healthSnapshot = self.micHealthTracker.noteSystemSamples(samples, now: now)
            let failoverSnapshot = self.applyMicFailoverIfNeededOnQueue(healthSnapshot, now: now)
            self.onMicHealthChanged?(failoverSnapshot ?? healthSnapshot)
            self.micRecoveryCoordinator.process(failoverSnapshot ?? healthSnapshot)
            let recordingOffset = self.recordingOffsetOnQueue(
                for: .system,
                sampleCount: samples.count,
                callbackUptimeNanoseconds: callbackUptime,
                callbackDate: callbackDate
            )
            if self.systemChunkNeedsTimelineRealignment {
                self.systemChunkTimingTracker.realign(atSampleIndex: Int64(recordingOffset))
                self.systemChunkNeedsTimelineRealignment = false
            }
            self.retainedRecordingWriter?.appendSystem(samples, atSampleOffset: recordingOffset)

            let floatSamples = samples.map { Float($0) / 32767.0 }
            self.neuralAec.feedSystemSamples(floatSamples)
            // Release whatever the fresh reference unblocks before gating, so
            // the block below sees the newest reference frames it can (A1).
            let cleanedFloat = self.neuralAec.processStreamingMic([])
            self.appendCleanedMicSamplesOnQueue(cleanedFloat)

            if let vadController = self.vadController, !cleanedFloat.isEmpty {
                vadController.processAudio(cleanedFloat)
            }

            // The chunk file, the chunk timing, the partial session and the
            // system VAD consume the gated stream instead (KTD5).
            self.appendRawSystemSamplesOnQueue(
                samples,
                timelineStart: recordingOffset,
                arrivalStart: arrivalStart
            )
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
        // Reached from both callbacks, so it is the only place the reverse
        // reference can be registered at its true timeline position (KTD6).
        for span in micArrivalTimeline.consume(cleanedFloat.count) {
            reverseLeakSuppressor.feedCleanedMicSamples(
                Array(cleanedFloat[span.offset..<(span.offset + span.count)]),
                timelineStartSample: span.timelineStart
            )
        }
        let cleanedInt16 = cleanedFloat.map { sample -> Int16 in
            Int16(max(-1.0, min(1.0, sample)) * 32767)
        }
        rawMicChunkRecorder?.append(cleanedInt16)
        chunkTimingTracker.append(sampleCount: cleanedInt16.count)
        diagnostics?.appendCleanedMicSamples(cleanedInt16)
    }

    /// Accumulates raw system callbacks into whole gate blocks (KTD5). A
    /// timeline gap larger than the gate tolerance closes the pending block
    /// early and it passes ungated, so a block never straddles a realign or a
    /// capture stall (KTD6).
    private func appendRawSystemSamplesOnQueue(
        _ samples: [Int16],
        timelineStart: Int,
        arrivalStart: Int
    ) {
        guard !samples.isEmpty else { return }
        if !pendingSystemBlock.isEmpty {
            let expectedTimelineStart = pendingSystemBlockTimelineStart + pendingSystemBlock.count
            if abs(timelineStart - expectedTimelineStart) > Self.systemBlockGapToleranceSamples {
                emitPendingSystemBlockOnQueue(gated: false)
            }
        }
        if pendingSystemBlock.isEmpty {
            pendingSystemBlockTimelineStart = timelineStart
            pendingSystemBlockArrivalStart = arrivalStart
        }
        pendingSystemBlock.append(contentsOf: samples)

        while pendingSystemBlock.count >= Self.systemGateBlockLength {
            let block = Array(pendingSystemBlock.prefix(Self.systemGateBlockLength))
            pendingSystemBlock.removeFirst(Self.systemGateBlockLength)
            let blockTimelineStart = pendingSystemBlockTimelineStart
            let blockArrivalStart = pendingSystemBlockArrivalStart
            pendingSystemBlockTimelineStart += Self.systemGateBlockLength
            pendingSystemBlockArrivalStart += Self.systemGateBlockLength
            gateSystemBlockOnQueue(
                block,
                timelineStart: blockTimelineStart,
                arrivalStart: blockArrivalStart,
                gated: true
            )
        }
    }

    /// Idempotent. Called on pause, stop and system-capture interruption only —
    /// VAD-driven rotation leaves the remainder for the next chunk (KTD5).
    private func flushPendingSystemBlockOnQueue() {
        emitPendingSystemBlockOnQueue(gated: true)
        // R16: a flushed remainder must never reach a VAD controller.
        _ = systemVadFrameAccumulator.flush()
    }

    private func emitPendingSystemBlockOnQueue(gated: Bool) {
        guard !pendingSystemBlock.isEmpty else { return }
        let block = pendingSystemBlock
        let blockTimelineStart = pendingSystemBlockTimelineStart
        let blockArrivalStart = pendingSystemBlockArrivalStart
        pendingSystemBlock.removeAll(keepingCapacity: true)
        pendingSystemBlockTimelineStart += block.count
        pendingSystemBlockArrivalStart += block.count
        gateSystemBlockOnQueue(
            block,
            timelineStart: blockTimelineStart,
            arrivalStart: blockArrivalStart,
            gated: gated
        )
    }

    private func resetSystemGateBufferingOnQueue() {
        pendingSystemBlock.removeAll(keepingCapacity: true)
        pendingSystemBlockTimelineStart = 0
        pendingSystemBlockArrivalStart = 0
        systemVadFrameAccumulator.reset()
    }

    private func gateSystemBlockOnQueue(
        _ block: [Int16],
        timelineStart: Int,
        arrivalStart: Int,
        gated: Bool
    ) {
        let floatSamples = block.map { Float($0) / 32767.0 }
        guard gated else {
            appendProcessedSystemSamplesOnQueue(floatSamples, original: block)
            return
        }
        let processed = reverseLeakSuppressor.processSystemBlock(
            floatSamples,
            timelineStartSample: timelineStart,
            arrivalStartSample: arrivalStart
        )
        appendProcessedSystemSamplesOnQueue(processed, original: block)
    }

    /// Single funnel for the system audio the transcript is built from: the
    /// chunk file, the chunk timing, the streaming partial tail and the system
    /// VAD must all consume exactly the gated stream (KTD5). Deliberately does
    /// not guard on `isRecording`/`isPaused`, mirroring
    /// `appendCleanedMicSamplesOnQueue`, because `stop` clears `isRecording`
    /// before it flushes the pending block.
    private func appendProcessedSystemSamplesOnQueue(_ processed: [Float], original: [Int16]) {
        guard !processed.isEmpty else { return }
        onProcessedSystemSamples?(processed)
        feedSystemPartialSession(processed)
        systemChunkRecorder?.append(Self.systemChunkSamples(processed: processed, original: original))
        systemChunkTimingTracker.append(sampleCount: processed.count)
        for frame in systemVadFrameAccumulator.push(processed) {
            systemVadController?.processAudio(frame)
        }
    }

    /// Ungated samples keep their original Int16 bytes: a float round trip
    /// clamps a full-scale negative (-32768 to -32767) and would cost byte
    /// parity with the raw capture whenever the gate never fires.
    private static func systemChunkSamples(processed: [Float], original: [Int16]) -> [Int16] {
        guard processed.count == original.count else {
            return processed.map { Int16(max(-1.0, min(1.0, $0)) * 32767) }
        }
        var samples = original
        for index in processed.indices where processed[index] != Float(original[index]) / 32767.0 {
            samples[index] = Int16(max(-1.0, min(1.0, processed[index])) * 32767)
        }
        return samples
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
            let backend = currentBackend()
            let evidence = try await transcriptionCoordinator.transcribeMeetingChunkWithEvidence(
                at: url,
                backend: backend,
                languageDecision: meetingFinalLanguageDecision(backend: backend),
                profile: frozenMeetingProfile,
                appleSpeechLanguage: config.resolvedAppleSpeechLanguage,
                customWords: config.customWords
            )
            rawTranscriptAccumulator.appendBatch(
                evidence.raw,
                start: chunkOffset,
                end: chunkOffset + max(chunkDuration, 0.1),
                source: .microphone
            )
            let result = evidence.cleaned
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
        // Arrival-frame spans, which is the raw file's own frame (KTD7).
        let suppressedIntervals = suppressedSystemIntervals()

        guard let vadManager = await transcriptionCoordinator.getVadManager() else {
            if existingSystemSegments.isEmpty {
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration,
                    suppressedIntervals: suppressedIntervals
                ))
            }
            return .none
        }

        do {
            let samples = try AudioConverter().resampleAudioFile(systemAudioURL)
            let rawSpeechSegments = try await vadManager.segmentSpeech(
                samples,
                config: VadSegmentationConfig(maxSpeechDuration: 10.0, speechPadding: 0.15)
            )
            // Speech the reverse-leak gate already removed from the live chunks is still in the
            // recorder's raw file. Subtract it before the health check so leaked spans neither
            // count as uncovered speech nor come back through repair (KTD7, R10).
            let speechSegments = MeetingReverseLeakMaskPlanner.filterSegments(
                rawSpeechSegments,
                excluding: suppressedIntervals,
                minimumDuration: MeetingTranscriptHealthMonitor.minimumEvaluatedSpeechDuration
            )
            noteOfflineSpeechInsideSuppressedIntervals(
                MeetingReverseLeakMaskPlanner.suppressedSpeechSeconds(
                    rawSpeechSegments,
                    intervals: suppressedIntervals
                )
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
                    meetingDuration: totalDuration,
                    suppressedIntervals: suppressedIntervals
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

                    let repairBackend = currentBackend()
                    let evidence = try await transcriptionCoordinator.transcribeMeetingWithEvidence(
                        at: segmentURL,
                        backend: repairBackend,
                        languageDecision: meetingFinalLanguageDecision(backend: repairBackend),
                        profile: frozenMeetingProfile,
                        appleSpeechLanguage: config.resolvedAppleSpeechLanguage,
                        customWords: config.customWords
                    )
                    repairedSegments.append(contentsOf: normalizeSystemTranscription(
                        result: evidence.cleaned,
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
                    meetingDuration: totalDuration,
                    suppressedIntervals: suppressedIntervals
                ))
            }
            return .none
        }
    }

    private func fallbackToFullSessionSystemTranscription(
        systemAudioURL: URL,
        meetingDuration: Double,
        suppressedIntervals: [MeetingSuppressedInterval]
    ) async -> [SpeechSegment] {
        fputs("[meeting] no system chunks survived, falling back to full-session system transcription\n", stderr)
        // The fallback transcribes the whole raw file, so without masking it would re-insert
        // every span the gate suppressed (KTD7). A load failure falls back to the raw URL
        // rather than losing the fallback entirely.
        var transcriptionURL = systemAudioURL
        var maskedURL: URL?
        if !suppressedIntervals.isEmpty {
            do {
                var samples = try AudioConverter().resampleAudioFile(systemAudioURL)
                MeetingReverseLeakMaskPlanner.maskSamples(
                    &samples,
                    intervals: suppressedIntervals,
                    sampleRate: VadManager.sampleRate
                )
                let url = try MeetingReverseLeakMaskPlanner.writeTemporaryWAV(samples: samples)
                maskedURL = url
                transcriptionURL = url
            } catch {
                fputs("[meeting] could not mask suppressed spans for the system fallback: \(error)\n", stderr)
            }
        }
        defer {
            if let maskedURL {
                try? FileManager.default.removeItem(at: maskedURL)
            }
        }
        do {
            let backend = currentBackend()
            let evidence = try await transcriptionCoordinator.transcribeMeetingWithEvidence(
                at: transcriptionURL,
                backend: backend,
                languageDecision: meetingFinalLanguageDecision(backend: backend),
                profile: frozenMeetingProfile,
                appleSpeechLanguage: config.resolvedAppleSpeechLanguage,
                customWords: config.customWords
            )
            return normalizeSystemTranscription(
                result: evidence.cleaned,
                startTime: 0,
                endTime: meetingDuration
            )
        } catch {
            fputs("[meeting] full-session system fallback transcription failed: \(error)\n", stderr)
            return []
        }
    }
}
