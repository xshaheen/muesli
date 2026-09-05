import AppKit
import AVFoundation
import CloudKit
import CoreAudio
import Foundation
import Sparkle
import TelemetryDeck
import MuesliCore
import os

private enum DictationOutputMode {
    case paste
    case voiceNote

    var pasteMethod: String {
        switch self {
        case .paste:
            return "clipboard_restore"
        case .voiceNote:
            return "voice_note"
        }
    }
}

private extension DictationRecordingSavePolicy {
    var artifactPolicySnapshot: RecordingSavePolicySnapshot? {
        switch self {
        case .never: nil
        case .prompt: .prompt
        case .always: .always
        }
    }
}

private struct DictationLatencyTraceSnapshot {
    let id: UUID
    let startedAt: Date
    let profile: String
    let routeDescription: String
}

struct FrozenDictationTranscriptionSelection: Equatable {
    let backend: BackendOption
    let languageProfile: LanguageProfile
}

private struct PendingStandardDictationStop {
    let id: UUID
    let sequence: UInt64
    let startedAt: Date
    let isTestMode: Bool
    let outputMode: DictationOutputMode
    let backend: BackendOption
    let languageProfile: LanguageProfile
    let promptContext: String?
    let storageContext: String
    let correctionTargetApp: DictationSessionTarget?
    let customWords: [[String: Any]]
    let cleanupRequest: DictationCleanupRequestSnapshot
    let detectedSpeech: Bool
    let recordingSavePolicy: DictationRecordingSavePolicy
    let latencyTrace: DictationLatencyTraceSnapshot?
    let sessionTrace: SessionRunTrace
}

private enum CompletedStandardDictationStop {
    case job(StandardDictationJob)
    case discarded
}

private struct StandardDictationJob: Identifiable {
    let id: UUID
    let wavURL: URL
    let startedAt: Date
    let duration: TimeInterval
    let isTestMode: Bool
    let outputMode: DictationOutputMode
    let backend: BackendOption
    let languageProfile: LanguageProfile
    let promptContext: String?
    let storageContext: String
    let correctionTargetApp: DictationSessionTarget?
    let customWords: [[String: Any]]
    let cleanupRequest: DictationCleanupRequestSnapshot
    let detectedSpeech: Bool
    let recordingSavePolicy: DictationRecordingSavePolicy
    let latencyTrace: DictationLatencyTraceSnapshot?
    let sessionTrace: SessionRunTrace
}

private struct DictationLatencyTraceToken: Sendable {
    let id: UUID
    let startedAt: Date
}

enum DictationBackendReadiness: Equatable {
    case preparing
    case ready
    case failed

    var allowsDictation: Bool {
        self == .ready
    }

    func blockingMessage(backendLabel: String) -> String? {
        switch self {
        case .preparing:
            return "Warming up \(backendLabel)..."
        case .ready:
            return nil
        case .failed:
            return "\(backendLabel) unavailable"
        }
    }
}

enum DictionaryCorrectionPromptsToggleResult {
    case updated
    case needsAccessibilityPermission
}

private enum DictationAudioRouteTiming {
    static let stabilizationDelay: TimeInterval = 1.0
}

enum InteractiveAudioSessionOwner {
    case dictation
    case computerUse
    case quil
}

struct InteractiveAudioSessionOwnership: Equatable {
    let dictationIsActive: Bool
    let computerUseIsActive: Bool
    var quilIsActive: Bool = false

    func canStart(_ owner: InteractiveAudioSessionOwner) -> Bool {
        switch owner {
        case .dictation:
            return !computerUseIsActive && !quilIsActive
        case .computerUse:
            return !dictationIsActive && !quilIsActive
        case .quil:
            return !dictationIsActive && !computerUseIsActive
        }
    }

    func shouldIgnoreCleanup(for owner: InteractiveAudioSessionOwner) -> Bool {
        switch owner {
        case .dictation:
            return !dictationIsActive && (computerUseIsActive || quilIsActive)
        case .computerUse:
            return !computerUseIsActive && (dictationIsActive || quilIsActive)
        case .quil:
            return !quilIsActive && (dictationIsActive || computerUseIsActive)
        }
    }
}

enum DictationStartAdmissionPolicy {
    static func allowsStart(
        dictationState: DictationState,
        isMeetingAudioProcessing: Bool
    ) -> Bool {
        dictationState != .transcribing
            && !isMeetingAudioProcessing
    }

    static func shouldIgnoreCleanupAfterBlockedStart(
        hasStartedRecording: Bool,
        isStreaming: Bool,
        dictationState: DictationState,
        isMeetingAudioProcessing: Bool
    ) -> Bool {
        !hasStartedRecording
            && !isStreaming
            && !allowsStart(
                dictationState: dictationState,
                isMeetingAudioProcessing: isMeetingAudioProcessing
            )
    }
}

enum MeetingProcessingAdmissionPolicy {
    static func blocksDictation(stages: [MeetingProcessingStage]) -> Bool {
        stages.contains { !$0.allowsDictation }
    }
}

struct MeetingResummarizationPlan: Equatable {
    let promptTitle: String
    let persistedTitle: String
}

enum MeetingResummarizationPolicy {
    static func plan(for meeting: MeetingRecord) -> MeetingResummarizationPlan {
        let trimmed = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptTitle = trimmed.isEmpty ? "Meeting" : trimmed
        return MeetingResummarizationPlan(
            promptTitle: promptTitle,
            persistedTitle: meeting.title
        )
    }
}

enum MeetingSummaryPersistenceError: Error, LocalizedError {
    case failedToSaveSummary(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .failedToSaveSummary(let underlying):
            let detail = underlying.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "The updated meeting notes could not be saved."
            }
            return "The updated meeting notes could not be saved. \(detail)"
        }
    }
}

enum MeetingTemplateSelectionError: Error, LocalizedError {
    case templateNoLongerExists

    var errorDescription: String? {
        switch self {
        case .templateNoLongerExists:
            return "That template no longer exists. Choose another template and try again."
        }
    }
}

enum MeetingCompletionNotificationPolicy {
    static func shouldShow(
        hasPresentedMeetingCandidate: Bool,
        isShowingCalendarNotification: Bool,
        isMeetingNotificationVisible: Bool
    ) -> Bool {
        !hasPresentedMeetingCandidate
            && !isShowingCalendarNotification
            && !isMeetingNotificationVisible
    }
}

enum MuesliBridgeDeviceRefreshPolicy {
    static func shouldForceRefresh(
        userInitiated: Bool,
        bridgeActivationPending: Bool,
        bridgeDiscoveryTriggered: Bool,
        hasKnownCompanionDevice: Bool
    ) -> Bool {
        userInitiated
            || bridgeActivationPending
            || (bridgeDiscoveryTriggered && !hasKnownCompanionDevice)
    }
}

struct PendingMeetingCompletionNotification {
    let meetingID: Int64?
    let title: String
}

private struct CalendarParticipantReconciliationSnapshot: Sendable {
    let occurrence: CalendarOccurrenceReference
    let startDate: Date
    let participants: [MeetingParticipantDraft]
}

private enum CalendarAttendeePersistenceMode: Sendable, Equatable {
    case attach
    case reconcile
}

enum MeetingRetranscriptionError: Error, LocalizedError {
    case controllerUnavailable
    case recordingUnavailable
    case noDownloadedTranscriptionModel
    case emptyTranscript
    case failedToSave(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .controllerUnavailable:
            return "Meeting re-transcription could not continue because Muesli is no longer available."
        case .recordingUnavailable:
            return "The saved meeting recording is no longer available on disk."
        case .noDownloadedTranscriptionModel:
            return "Download a transcription model before re-transcribing this meeting."
        case .emptyTranscript:
            return "Re-transcription finished, but no speech was detected in the saved recording."
        case .failedToSave(let underlying):
            return "The re-transcribed meeting could not be saved. \(underlying.localizedDescription)"
        }
    }
}

enum MeetingLifecycleError: Error, LocalizedError {
    case failedToSaveRecording(underlying: Error)
    case failedToDeleteRecording(underlying: Error)
    case failedToDeleteMeeting(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .failedToSaveRecording(let underlying):
            return "The meeting finished transcribing, but the recording could not be saved. \(underlying.localizedDescription)"
        case .failedToDeleteRecording(let underlying):
            return "The saved meeting recording could not be deleted, so the meeting was left in place. \(underlying.localizedDescription)"
        case .failedToDeleteMeeting(let underlying):
            return "The meeting could not be deleted. \(underlying.localizedDescription)"
        }
    }
}

struct CompletedMeetingPersistenceResult {
    let meetingID: Int64
    let recordingSaveError: MeetingLifecycleError?
}

struct MeetingRecordingSaveRequest: Sendable {
    let tempURL: URL
    let meetingTitle: String
    let startedAt: Date
    let supportDirectory: URL
    let fileFormat: MeetingRecordingFileFormat
}

enum MeetingRecordingSavePlan {
    case none
    case discard(tempURL: URL)
    case save(MeetingRecordingSaveRequest)
    case failed(MeetingLifecycleError)
}

struct PreparedMeetingRecordingSave {
    let path: String?
    let error: MeetingLifecycleError?
    let recording: RecordingArtifactReference?

    init(
        path: String?,
        error: MeetingLifecycleError?,
        recording: RecordingArtifactReference? = nil
    ) {
        self.path = path
        self.error = error
        self.recording = recording
    }

    static let none = PreparedMeetingRecordingSave(path: nil, error: nil, recording: nil)
}

private final class DictationLatencyLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.muesli.dictation-latency-log")
    private let url: URL
    private var hasCreatedDirectory = false

    init(url: URL) {
        self.url = url
    }

    func append(_ line: String) {
        queue.async { [self] in
            do {
                if !hasCreatedDirectory {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    hasCreatedDirectory = true
                }
                try Self.trimIfNeeded(at: url)
                let data = Data((line + "\n").utf8)
                do {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {
                    try data.write(to: url, options: .atomic)
                }
            } catch {
                fputs("[dictation-latency] failed to append log: \(error)\n", stderr)
            }
        }
    }

    private static func trimIfNeeded(at url: URL) throws {
        let maxBytes: UInt64 = 2 * 1024 * 1024
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes?[.size] as? UInt64,
              fileSize > maxBytes else { return }

        let keepCount = Int(maxBytes / 2)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: fileSize - UInt64(keepCount))
        let tail = try handle.read(upToCount: keepCount) ?? Data()
        let newlineIndex = tail.firstIndex(of: UInt8(ascii: "\n"))
        let trimmed = newlineIndex.map { tail[tail.index(after: $0)...] } ?? tail[...]
        try Data(trimmed).write(to: url, options: .atomic)
    }
}

@MainActor
public final class MuesliController: NSObject {
    /// Weak backreference to the running controller for AppIntents, which are
    /// instantiated fresh by the system per invocation and have no other way
    /// to reach in-process state. Set in `start()`, cleared implicitly on dealloc.
    /// Public (and the handful of members below it) because App Intents live
    /// in the separate MuesliNativeAppShell executable module, not this library.
    public static weak var current: MuesliController?

    private static let maxDismissedDictionarySuggestionKeys = 200
    private static let maxDictionarySuggestions = 50
    private static let maxDictionarySuggestionPromptQueue = 10
    private static let dictionarySuggestionLogger = Logger(subsystem: "com.muesli.native", category: "DictionarySuggestion")
    private static let meetingCleanupLogger = Logger(subsystem: "com.muesli.native", category: "meeting-cleanup")
    private static let pendingDictionaryCorrectionAccessibilityEnableKey = "dictionaryCorrectionPrompts.pendingAccessibilityEnable"
    private static let pendingDictionaryCorrectionAccessibilityRequestedAtKey = "dictionaryCorrectionPrompts.pendingAccessibilityRequestedAt"
    private static let pendingDictionaryCorrectionAccessibilityRequestProcessIDKey = "dictionaryCorrectionPrompts.pendingAccessibilityRequestProcessID"
    private static let dictionaryCorrectionAccessibilityIntentTimeout: TimeInterval = 24 * 60 * 60
    private let runtime: RuntimePaths
    private let configStore: ConfigStore
    private let dictationStore: DictationStore
    private let sessionTraceStore: SessionTraceStore?
    private let recordingArtifactStore: RecordingArtifactStore?
    lazy var localDiagnosticsService = LocalDiagnosticsService(
        store: sessionTraceStore,
        flushActiveWriters: { [weak self] in
            await self?.flushActiveSessionTraces()
        },
        clearRecordingAssociations: { [weak self] in
            try self?.recordingArtifactStore?.clearDiagnosticAssociations()
        },
        loadIncidentHistory: { [weak self] in
            self?.diagnosticIncidentReporter.recentIncidents() ?? []
        },
        clearIncidentHistory: { [weak self] in
            self?.diagnosticIncidentReporter.clearHistory()
        }
    )
    private let meetingHookDispatcher: MeetingHookDispatching
    private let meetingMarkdownAutoExporter: MeetingMarkdownAutoExporting
    private let launchAtLoginCoordinator: LaunchAtLoginCoordinator
    let transcriptionCoordinator = TranscriptionCoordinator()
    private let hotkeyMonitor = HotkeyMonitor()
    private let computerUseHotkeyMonitor = HotkeyMonitor()
    private let quilHotkeyMonitor = HotkeyMonitor()
    private let meetingRecordingHotkeyMonitor = HotkeyMonitor()
    private let computerUseRecorder = RouteAwareDictationRecorder()
    private let quilRecorder = RouteAwareDictationRecorder()
    private let dictationRecorder = RouteAwareDictationRecorder()
    private let dictationCorrectionMonitor = DictationCorrectionMonitor()
    private let dictionarySuggestionPrompt = DictionarySuggestionPromptController()
    private var activeDictionarySuggestionPromptKey: String?
    private var queuedDictionarySuggestionPromptKeys: [String] = []
    private var dictionarySuggestionPromptAdvanceTask: Task<Void, Never>?
    private let audioDuckingController: AudioDuckingManaging
    private let dictationAudioRoutingController: DictationAudioRouting
    private lazy var dictationAudioSessionManager = DictationAudioSessionManager(
        recorder: dictationRecorder,
        duckingController: audioDuckingController,
        routingController: dictationAudioRoutingController
    )
    private lazy var standardDictationJobQueue = OrderedDictationJobQueue<StandardDictationJob>(
        handler: { [weak self] job in
            await self?.processStandardDictationJob(job)
        },
        onCurrentCancellationRequested: { job in
            await job.sessionTrace.recordCancellationRequested(stage: "dictation_queue")
        },
        onCancel: { [weak self] job in
            self?.dictationTestJobIDs.remove(job.id)
            self?.dictationSessionTraces.removeValue(forKey: job.id)
            let didWin = await job.sessionTrace.cancel(stage: "dictation_queue")
            if didWin, let self {
                self.applyDictationLifecycleActions(self.dictationLifecycleFeedback.finish(
                    sessionID: job.id,
                    outcome: .neutral,
                    soundAllowed: self.shouldPlayDictationLifecycleSounds
                ))
            }
            if didWin, job.recordingSavePolicy != .never, let self {
                await self.persistAudioOnlyDictationRecording(
                    capture: DictationAudioTerminalCapture(
                        sessionID: job.id,
                        outcome: .cancelled,
                        recordingSavePolicy: job.recordingSavePolicy,
                        wavURL: job.wavURL
                    ),
                    startedAt: job.startedAt,
                    durationSeconds: job.duration
                )
            } else {
                try? FileManager.default.removeItem(at: job.wavURL)
            }
        },
        onCountChanged: { [weak self] count in
            self?.standardDictationJobCountChanged(count)
        }
    )
    private lazy var computerUseAudioSessionManager = DictationAudioSessionManager(
        recorder: computerUseRecorder,
        duckingController: audioDuckingController,
        routingController: dictationAudioRoutingController
    )
    private lazy var quilAudioSessionManager = DictationAudioSessionManager(
        recorder: quilRecorder,
        duckingController: audioDuckingController,
        routingController: dictationAudioRoutingController
    )
    private let dictationLatencyLogWriter = DictationLatencyLogWriter(
        url: AppIdentity.supportDirectoryURL.appendingPathComponent("dictation-latency.log")
    )
    private lazy var diagnosticIncidentReporter = DiagnosticIncidentReporter(
        appState: appState,
        automaticPromptEnabled: { [weak self] in
            self?.config.enableAutomaticDiagnosticIssuePrompts ?? false
        },
        onPrompt: { [weak self] _ in
            self?.presentHistoryWindow(tab: .about)
        }
    )
    private let dictationLatencyTimestampFormatter = ISO8601DateFormatter()
    private let dictationMiniIndicator: DictationMiniIndicatorController
    private let dictationTextContextMonitor = DictationTextContextMonitor()
    private let meetingRecordingPanel: MeetingRecordingPanelController
    private let meetingRecordButton = MeetingRecordButtonController()
    private var dismissedMeetingRecordButtonCandidateID: String?
    private let calendarMonitor = CalendarMonitor()
    private let meetingMonitor = MeetingMonitor()
    private let meetingNotification = MeetingNotificationController()
    private let meetingSourceWindowLocator = MeetingSourceWindowLocator()

    private let chatGPTAuth = ChatGPTAuthManager.shared
    private let googleCalAuth = GoogleCalendarAuthManager.shared
    private let googleCalClient = GoogleCalendarClient()
    private var calendarCheckTimer: Timer?
    private var calendarMonitoringStarted = false
    private var meetingStartingNowTimers = [String: Timer]()
    private var notifiedUpcomingEventIDs = Set<String>()
    private var autoRecordedCalendarEventIDs = Set<String>()
    private var meetingFeatureMonitorsAllowed = false
    private var meetingDetectionMonitorStarted = false
    /// Bumped every time meeting detection starts; a cached activity candidate is only
    /// actionable for the Record pill when it was observed during the current run.
    private var meetingDetectionRunID = 0
    private var latestMeetingActivityCandidateRunID: Int?

    private var searchTask: Task<Void, Never>?
    private var onboardingModelPreparationTask: Task<Void, Never>?
    private var maraudersMapCountdown: MaraudersMapCountdownController?

    private var statusBarController: StatusBarController?
    private var historyWindowController: RecentHistoryWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private let featureTourStore = FeatureTourStore()
    private var isFeatureTourPresentationQueued = false
    var updaterController: SPUStandardUpdaterController?
    private var busyStatusGeneration = 0

    let appState = AppState()

    private(set) var config: AppConfig
    private(set) var selectedBackend: BackendOption
    private(set) var selectedMeetingTranscriptionBackend: BackendOption
    private(set) var selectedMeetingSummaryBackend: MeetingSummaryBackendOption
    private(set) var selectedPostProcessorBackend: TranscriptCleanupBackendOption
    private var activeMeetingSession: MeetingSession?
    private var activeMeetingPanelOwnerID: UUID?
    private weak var preparingMeetingSession: MeetingSession?
    private var activeMeetingID: Int64?
    private var meetingSessionTraces: [Int64: SessionRunTrace] = [:]
    private var importSessionTrace: SessionRunTrace?
    private var sessionTraceRegistry: [UUID: SessionRunTrace] = [:]
    /// Set when a meeting stops, so telemetry events legitimately emitted by
    /// the stopping session (after activeMeetingID is cleared) still pass the
    /// session-identity gate. Replaced on the next meeting start.
    private var micEpisodeTelemetryGate = RecentMeetingIdentityGate()
    private var liveMeetingTranscriptGeneration: UUID?
    private var activeMeetingAudioWarning: ActiveMeetingAudioWarning?
    private var activeMeetingAudioWarningState = ActiveMeetingAudioWarningState()
    private var liveMeetingTitleCache: [Int64: String] = [:]
    private var liveManualNotesCache: [Int64: String] = [:]
    private var liveManualNotesLastPersistedAt: [Int64: Date] = [:]
    private var liveManualNotesLastPersistedValue: [Int64: String] = [:]
    private var liveManualNotesPersistWorkItems: [Int64: DispatchWorkItem] = [:]
    private var calendarAttendeePersistenceTasks: [
        Int64: (generation: UUID, task: Task<Bool, Never>)
    ] = [:]
    private let liveManualNotesPersistInterval: TimeInterval = 0.75
    private var staleLiveMeetingRecoveryFailures = Set<Int64>()
    private var dictationState: DictationState = .idle
    private var dictationBackendReadiness: DictationBackendReadiness = .preparing
    private var dictationStartedAt: Date?
    private var dictationLatencyTraceID: UUID?
    private var dictationLatencyTraceStartedAt: Date?
    private var currentDictationOutputMode: DictationOutputMode = .paste
    private var pendingStandardDictationStops: [UUID: PendingStandardDictationStop] = [:]
    private var dictationSessionTraces: [UUID: SessionRunTrace] = [:]
    private var frozenDictationTranscriptionSelections: [UUID: FrozenDictationTranscriptionSelection] = [:]
    private var completedStandardDictationStops = OrderedCompletionBuffer<CompletedStandardDictationStop>()
    private var nextStandardDictationStopSequence: UInt64 = 0
    private var dictationLifecycleFeedback = DictationLifecycleFeedback()
    private var dictationMiniGeneration: DictationMiniIndicatorController.Generation?
    private var activeComputerUseAudioSessionID: UUID?
    private var computerUseCommandStartedAt: Date?
    private var pendingComputerUseStopStartedAt: Date?
    private var pendingComputerUseStopSessionID: UUID?
    private var computerUseCommandTask: Task<Void, Never>?
    private var computerUseCommandTaskID: UUID?
    private var activeQuilAudioSessionID: UUID?
    private var quilStartedAt: Date?
    private var pendingQuilStopStartedAt: Date?
    private var pendingQuilStopSessionID: UUID?
    private var quilTask: Task<Void, Never>?
    private var quilTaskID: UUID?
    private var quilSelectionSnapshot: QuilSelectionSnapshot?
    private var quilTargetCaptureError: Error?
    private var quilContextCaptureTask: Task<DictationContext?, Never>?
    private var computerUseFloatingStatusWorkItem: DispatchWorkItem?
    private var computerUseLastFloatingStatusAt = Date.distantPast
    private var computerUseLastFloatingStatus = ""
    private var computerUseTranscriptVisible = false
    private let computerUseFloatingStatusMinimumDwell: TimeInterval = 0.85
    private var _streamingDictationController: Any?  // StreamingDictationController (macOS 15+)
    private var isNemotron35Streaming = false
    private var nemotron35StreamingSessionID: UUID?
    private var nemotron35StreamingRecordingSavePolicy: DictationRecordingSavePolicy = .never
    private var previousStreamText = ""
    private var openWindowCount = 0
    private var lastExternalApp: NSRunningApplication?
    private var activeDictationStyleSession: DictationStyleSessionSnapshot?
    private var activeDictationContextResult: DictationSessionContextResult?
    private var stoppedDictationStyleSession: DictationStyleSessionSnapshot?
    private var stoppedDictationContextResult: DictationSessionContextResult?
    private var workspaceObserver: NSObjectProtocol?
    private var dataDidChangeObserver: NSObjectProtocol?
    private var iCloudAppActiveObserver: NSObjectProtocol?
    private var iCloudWakeObserver: NSObjectProtocol?
    private var isStartingMeetingRecording = false {
        didSet {
            // The Record pill only holds the spot for the start it launched; any exit from the
            // starting state retires the flag so a later start never renders as "Starting…".
            if !isStartingMeetingRecording { meetingStartOriginatedFromRecordButton = false }
        }
    }
    /// Set while a start launched from the Record pill is in flight, so the pill can hold its
    /// spot as "Starting…" instead of leaving it empty until capture is live.
    private var meetingStartOriginatedFromRecordButton = false
    private var meetingStartStatus: String?
    private var isShowingCalendarNotification = false
    private var presentedMeetingCandidate: MeetingCandidate?
    private var meetingEndTimer: Timer?
    private var meetingDurationWarningTimer: Timer?
    private var meetingDurationStopTimer: Timer?
    private var activeMeetingCalendarEndDate: Date?
    private var latestMeetingActivityCandidate: MeetingCandidate?
    /// The detector's most recent emission, tracked even while a start is in flight. The cache
    /// above freezes during a start, so a start that fails needs an unfrozen view of what the
    /// detector reports right now to decide whether the Record pill may come straight back.
    private var observedMeetingActivityCandidate: MeetingCandidate?
    private var observedMeetingActivityCandidateObservedAt: Date?
    private var observedMeetingActivityCandidateRunID: Int?
    private var dictationIdleDotAllowed = false
    /// When the dictation hotkey went down; gates the start cue so a discarded tap never tinks.
    private var dictationHotkeyPressedAt: Date?
    private var pendingStartCueToken: UUID?
    /// Audio sessions whose cancel has been requested but whose terminal event has not yet
    /// arrived. A first-buffer callback queued before the cancel can still emit `.streamActive`
    /// afterwards; those late events must not flash recording or play the start cue.
    private var cancelledDictationAudioSessionIDs: Set<UUID> = []
    private var latestMeetingActivityCandidateObservedAt: Date?
    private var activeMeetingAutoStop = MeetingAutoStopTracker()
    private var activeMeetingSignalLossResponse: MeetingSignalLossResponse = .none
    private var meetingSignalLossPromptState = MeetingSignalLossPromptState()
    private let meetingAutoStopGracePeriod: TimeInterval = 20
    private var meetingActivity: NSObjectProtocol?
    private var isStoppingMeetingRecording = false
    private var isPresentingMeetingTerminationConfirmation = false
    private var isTerminatingAfterMeetingConfirmation = false
    private var backgroundMeetingProcessingCount = 0
    /// Last meeting-residency value pushed to the coordinator, so the frequent
    /// `syncAppState()` calls only cross the actor boundary when it actually flips.
    private var isPostProcessorHeldForMeeting = false
    private var meetingProcessingStages: [UUID: MeetingProcessingStage] = [:]
    private var pendingMeetingCompletionNotification: PendingMeetingCompletionNotification?
    private var contributionMilestonePromptDismissedThisLaunch = false
    private var contributionMilestonePromptSeenIDsThisLaunch: Set<String> = []
    private var meetingStartTask: Task<Void, Never>?
    private var meetingStartMeetingID: Int64?
    private var importTask: Task<Void, Never>?
    private var importSessionID: UUID?
    private var meetingFinalizationTasks: [UUID: Task<Void, Never>] = [:]
    private var recordingStartupRecoveryTask: Task<Void, Never>?
    private var recordingMaintenanceTask: Task<Void, Never>?
    private var canceledMeetingStartIDs = Set<Int64>()
    /// Prior transcript captured when resuming a finished meeting, keyed by meeting id.
    /// Present only while a resume is in flight; consumed at stop to merge old + new
    /// transcript, and cleared on success or restored-on-failure.
    private var pendingResumePriorTranscript: [Int64: String] = [:]
    private var meetingTranscriptCleanupTasks: [Int64: (id: UUID, task: Task<Void, Never>)] = [:]
    private var iCloudSyncTask: Task<Void, Never>?
    private var ckSyncEngine: MuesliCKSyncEngine?
    private var ckSyncEngineLifecycleID = UUID()
    private var ckSyncEngineCancellationTask: Task<Void, Never>?
    private var ckSyncEngineCancellationGeneration = 0
    private var iCloudSyncGeneration = 0
    private var iCloudSyncDebounceTask: Task<Void, Never>?
    private var pendingICloudSyncRequests = MuesliCKSyncRequestQueue()
    private var iCloudSubscriptionTask: Task<Void, Never>?
    private var hasEnsuredICloudSubscription = false
    private var bridgeActivationPending = false
    private var bridgeDiscoveryPending = false
    private var bridgeDiscoveryFollowUpPending = false
    private var hasStarted = false

    var inFlightMeetingTranscriptCleanupCount: Int {
        meetingTranscriptCleanupTasks.count
    }

    private let meetingTranscriptCleanupSenderFactory:
        (TranscriptCleanupBackendOption, AppConfig) -> (String) async throws -> TranscriptCleanupResult

    init(
        runtime: RuntimePaths,
        dictationStore: DictationStore? = nil,
        sessionTraceStore: SessionTraceStore? = nil,
        recordingArtifactStore: RecordingArtifactStore? = nil,
        configStore: ConfigStore = ConfigStore(),
        meetingHookDispatcher: MeetingHookDispatching = MeetingHookRunner(),
        meetingMarkdownAutoExporter: MeetingMarkdownAutoExporting = MeetingMarkdownAutoExporter(),
        launchAtLoginManager: LaunchAtLoginManaging = SystemLaunchAtLoginManager(),
        audioDuckingController: AudioDuckingManaging = AudioDuckingController(),
        dictationAudioRoutingController: DictationAudioRouting = DictationAudioRouteController(),
        meetingTranscriptCleanupSenderFactory: @escaping
            (TranscriptCleanupBackendOption, AppConfig) -> (String) async throws -> TranscriptCleanupResult =
            MeetingTranscriptCleanup.liveSender
    ) {
        self.configStore = configStore
        var loadedConfig = configStore.load()
        let loadedBackend = BackendOption.all.first(where: {
            $0.backend == loadedConfig.sttBackend && $0.model == loadedConfig.sttModel
        }) ?? .whisper
        var loadedPostProcessorBackend = TranscriptCleanupBackendOption.resolved(loadedConfig.postProcessorBackend)
        var repairedCleanupConfiguration = false
        if loadedPostProcessorBackend == .local,
           !PostProcessorOption.resolve(id: loadedConfig.activePostProcessorId).isCompatible(with: loadedBackend) {
            loadedConfig.enablePostProcessor = false
            repairedCleanupConfiguration = true
        }
        if !loadedPostProcessorBackend.isCompatible(with: loadedBackend) {
            loadedPostProcessorBackend = .local
            loadedConfig.postProcessorBackend = loadedPostProcessorBackend.backend
            loadedConfig.enablePostProcessor = false
            repairedCleanupConfiguration = true
        }
        if repairedCleanupConfiguration {
            configStore.save(loadedConfig)
        }
        self.runtime = runtime
        let resolvedDictationStore = dictationStore ?? DictationStore(
            databaseURL: MuesliPaths.defaultDatabaseURL(appName: AppIdentity.supportDirectoryName)
        )
        self.dictationStore = resolvedDictationStore
        let databaseMigrated: Bool
        do {
            try resolvedDictationStore.migrateIfNeeded()
            databaseMigrated = true
        } catch {
            fputs("[muesli-native] startup migration failed: \(error)\n", stderr)
            databaseMigrated = false
        }
        self.sessionTraceStore = sessionTraceStore ?? (databaseMigrated
            ? try? SessionTraceStore(
                databaseURL: resolvedDictationStore.resolvedDatabaseURL,
                migrateDatabase: false
            )
            : nil)
        let supportDirectory = configStore.supportDirectory()
        self.recordingArtifactStore = recordingArtifactStore ?? (databaseMigrated
            ? try? RecordingArtifactStore(
                databaseURL: resolvedDictationStore.resolvedDatabaseURL,
                recordingsRootURL: supportDirectory.appendingPathComponent("recordings", isDirectory: true),
                legacyMeetingRootURL: supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true),
                migrateDatabase: false
            )
            : nil)
        self.meetingHookDispatcher = meetingHookDispatcher
        self.meetingMarkdownAutoExporter = meetingMarkdownAutoExporter
        self.launchAtLoginCoordinator = LaunchAtLoginCoordinator(manager: launchAtLoginManager)
        self.audioDuckingController = audioDuckingController
        self.dictationAudioRoutingController = dictationAudioRoutingController
        self.meetingTranscriptCleanupSenderFactory = meetingTranscriptCleanupSenderFactory
        self.dictationAudioRoutingController.selectedInputDeviceUID = loadedConfig.dictationInputDeviceUID
        self.dictationAudioRoutingController.selectedMeetingInputDeviceUID = loadedConfig.meetingInputDeviceUID
        self.config = loadedConfig
        MuesliTheme.accentOverrideHex = loadedConfig.accentOverrideHex
        self.selectedBackend = loadedBackend
        let configuredMeetingBackend = BackendOption.resolve(
            backend: loadedConfig.meetingTranscriptionBackend,
            model: loadedConfig.meetingTranscriptionModel
        )
        self.selectedMeetingTranscriptionBackend = Self.availableMeetingTranscriptionBackend(
            config: loadedConfig,
            dictationBackend: self.selectedBackend,
            downloadedOptions: BackendOption.downloaded
        ) ?? Self.fallbackMeetingTranscriptionBackend(
            configured: configuredMeetingBackend,
            dictationBackend: self.selectedBackend
        )
        self.selectedMeetingSummaryBackend = MeetingSummaryBackendOption.all.first(where: {
            $0.backend == loadedConfig.meetingSummaryBackend
        }) ?? .chatGPT
        self.selectedPostProcessorBackend = loadedPostProcessorBackend
        self.dictationMiniIndicator = DictationMiniIndicatorController()
        self.meetingRecordingPanel = MeetingRecordingPanelController(
            configStore: configStore,
            configuration: loadedConfig
        )
        super.init()
        dictationAudioSessionManager.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleDictationAudioSessionEvent(event)
            }
        }
        computerUseAudioSessionManager.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleComputerUseAudioSessionEvent(event)
            }
        }
        quilAudioSessionManager.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleQuilAudioSessionEvent(event)
            }
        }
        dictationAudioRoutingController.onPreferredInputDeviceChanged = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncDictationRecorderWarmup(
                    intent: .idlePrewarm(.routeChange),
                    delay: DictationAudioRouteTiming.stabilizationDelay
                )
            }
        }
        dictationAudioRoutingController.onMeetingPreferredInputDeviceChanged = { [weak self] deviceID in
            Task { @MainActor [weak self] in
                self?.applyMeetingInputDevice(deviceID, explicitUserSelection: false)
            }
        }
    }

    func start() {
        hasStarted = true
        Task.detached(priority: .utility) {
            MeetingSessionDiagnostics.prepareStore()
        }
        configureRecordingArtifactPlayback()
        if let recordingArtifactStore {
            let historyStore = dictationStore
            recordingStartupRecoveryTask?.cancel()
            recordingStartupRecoveryTask = Task { [weak self] in
                do {
                    try await Task.detached(priority: .utility) {
                        try Self.migrateLegacyMeetingRecordings(
                            historyStore: historyStore,
                            artifactStore: recordingArtifactStore
                        )
                        try recordingArtifactStore.discardPendingArtifacts()
                        try recordingArtifactStore.recoverAndPrune()
                    }.value
                } catch {
                    fputs("[recordings] startup recovery failed: \(error)\n", stderr)
                }
                guard !Task.isCancelled, let self else { return }
                await RecordingArtifactPlaybackCoordinator.shared.refreshAllCachedOwners()
                self.historyWindowController?.reload()
                self.syncAppState()
                self.recordingMaintenanceTask?.cancel()
                self.recordingMaintenanceTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        guard !Task.isCancelled, let self else { return }
                        try? await Task.detached(priority: .utility) {
                            try recordingArtifactStore.recoverAndPrune()
                        }.value
                        await RecordingArtifactPlaybackCoordinator.shared.refreshAllCachedOwners()
                        self.historyWindowController?.reload()
                    }
                }
            }
        }
        MuesliController.current = self
        do {
            try dictationStore.migrateIfNeeded()
        } catch {
            fputs("[muesli-native] startup error: \(error)\n", stderr)
        }
        recoverStaleLiveMeetings()
        resumePendingMeetingNotesRegeneration()
        normalizeMeetingTranscriptionSelectionForAvailability()
        SoundController.prewarmLifecycleSounds()

        // Clean up phantom aggregate devices left by a previous crash
        CoreAudioSystemRecorder.cleanupStaleDevices()

        syncLaunchAtLoginConfigWithSystem()
        reconcilePendingDictionaryCorrectionAccessibilityEnable()

        // Clean up leftover audio temp files from previous sessions.
        cleanupTemporaryDirectory(
            named: "muesli-system-audio",
            logDescription: "leftover temp audio files"
        )
        cleanupTemporaryDirectory(
            named: "muesli-meeting-recordings",
            logDescription: "leftover temp meeting recording files"
        )
        cleanupHistoricalMeetingWaveformCacheFilesIfNeeded()

        // Recording starts at key-down (taps are discarded on release), like the reference app.
        hotkeyMonitor.eagerStart = true
        hotkeyMonitor.onArm = { [weak self] in self?.handleArm() }
        hotkeyMonitor.onPrepare = { [weak self] in self?.handlePrepare() }
        hotkeyMonitor.onStart = { [weak self] in self?.handleStart() }
        hotkeyMonitor.onStop = { [weak self] in self?.handleStop() }
        hotkeyMonitor.onCancel = { [weak self] in self?.handleCancel() }
        hotkeyMonitor.onTapDiscard = { [weak self] in self?.handleTapDiscard() }
        hotkeyMonitor.onToggleStart = { [weak self] in self?.handleToggleStart() }
        hotkeyMonitor.onToggleStop = { [weak self] in self?.handleToggleStop() }
        hotkeyMonitor.doubleTapEnabled = config.enableDoubleTapDictation
        configureHotkeyMonitorTiming()
        computerUseHotkeyMonitor.onPrepare = { [weak self] in self?.handleComputerUsePrepare() }
        computerUseHotkeyMonitor.onStart = { [weak self] in self?.handleComputerUseStart() }
        computerUseHotkeyMonitor.onStop = { [weak self] in self?.handleComputerUseStop() }
        computerUseHotkeyMonitor.onCancel = { [weak self] in self?.handleComputerUseCancel() }
        computerUseHotkeyMonitor.onToggleStart = { [weak self] in self?.handleComputerUseToggleStart() }
        computerUseHotkeyMonitor.onToggleStop = { [weak self] in self?.handleComputerUseToggleStop() }
        computerUseHotkeyMonitor.doubleTapEnabled = config.enableDoubleTapDictation

        quilHotkeyMonitor.onPrepare = { [weak self] in self?.handleQuilPrepare() }
        quilHotkeyMonitor.onStart = { [weak self] in self?.handleQuilStart() }
        quilHotkeyMonitor.onStop = { [weak self] in self?.handleQuilStop() }
        quilHotkeyMonitor.onCancel = { [weak self] in self?.handleQuilCancel() }
        quilHotkeyMonitor.onToggleStart = { [weak self] in self?.handleQuilToggleStart() }
        quilHotkeyMonitor.onToggleStop = { [weak self] in self?.handleQuilToggleStop() }
        quilHotkeyMonitor.doubleTapEnabled = config.enableDoubleTapDictation
        quilHotkeyMonitor.combinationActivation = .pushToTalk
        quilHotkeyMonitor.registersCombinationGlobally = true

        meetingRecordingHotkeyMonitor.onStart = { [weak self] in
            DispatchQueue.main.async { self?.toggleMeetingRecording() }
        }
        meetingRecordingHotkeyMonitor.onToggleStart = { [weak self] in
            DispatchQueue.main.async { self?.toggleMeetingRecording() }
        }
        meetingRecordingHotkeyMonitor.onToggleStop = { [weak self] in
            DispatchQueue.main.async { self?.toggleMeetingRecording() }
        }
        // Deliberately no onCancel: a sub-threshold press never toggled anything, so
        // stopping here would end a recording the press did not start.

        let canRunMainApp = config.hasCompletedOnboarding
            && hasRequiredStartupPermissions(for: config.resolvedOnboardingUseCase)
        meetingFeatureMonitorsAllowed = canRunMainApp

        // Defer permission-triggering monitors until after onboarding
        if canRunMainApp && config.resolvedOnboardingUseCase.includesPushToTalk {
            hotkeyMonitor.configure(config.dictationHotkey)
            hotkeyMonitor.start()
            startComputerUseHotkeyMonitorIfNeeded()
            startQuilHotkeyMonitorIfNeeded()
        }
        if canRunMainApp {
            startMeetingRecordingHotkeyMonitorIfNeeded()
        }
        dictationTextContextMonitor.onSample = { [weak self] sample in
            self?.dictationMiniIndicator.updateIdleContext(sample)
        }
        dictationTextContextMonitor.onActivityChanged = { [weak self] activity in
            self?.dictationMiniIndicator.setIdleActivity(activity)
        }
        dictationTextContextMonitor.onFocusChanged = { [weak self] in
            self?.dictationMiniIndicator.idleFocusDidChange()
        }
        dictationTextContextMonitor.onEscape = { [weak self] in
            self?.dictationMiniIndicator.hideIdleDotUntilFocusChanges()
        }
        dictationTextContextMonitor.onContextCleared = { [weak self] in
            self?.dictationMiniIndicator.clearIdleContext()
        }
        dictationMiniIndicator.hotkeyLabelProvider = { [weak self] in
            self?.config.dictationHotkey.label ?? "the hotkey"
        }
        dictationMiniIndicator.onIdleMenuAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .turnOff:
                self.updateConfig { $0.showDictationIdleDot = false }
            case .openSettings:
                self.openSettingsTab()
            case .hideUntilFieldChanges, .hideForHour:
                break
            }
        }
        dictationIdleDotAllowed = canRunMainApp
        syncDictationIdleDot()
        syncDictationRecorderWarmup(intent: .idlePrewarm(.startup))
        meetingRecordingPanel.onStop = { [weak self] in self?.stopMeetingRecording() }
        meetingRecordingPanel.onDiscard = { [weak self] ownerID in
            self?.confirmDiscardMeeting(ownerID: ownerID)
        }
        meetingRecordingPanel.onTogglePause = { [weak self] in self?.toggleMeetingRecordingPause() }
        meetingRecordingPanel.onOpenNotes = { [weak self] in self?.openActiveMeetingNotes() }
        ComputerUseCursorOverlay.shared.onStop = { [weak self] in
            guard let self else { return }
            if self.computerUseHotkeyMonitor.isToggleRecording {
                self.computerUseHotkeyMonitor.stopToggleMode()
            } else if self.quilHotkeyMonitor.isToggleRecording {
                self.quilHotkeyMonitor.stopToggleMode()
            } else if self.quilStartedAt != nil {
                self.handleQuilStop()
            } else {
                self.handleComputerUseStop()
            }
        }
        ComputerUseCursorOverlay.shared.onCancel = { [weak self] in
            guard let self else { return }
            if self.quilHotkeyMonitor.isToggleRecording
                || self.quilStartedAt != nil
                || self.quilSelectionSnapshot != nil {
                self.handleQuilCancel()
                self.quilHotkeyMonitor.cancelToggleMode()
            } else {
                self.handleComputerUseCancel()
                self.computerUseHotkeyMonitor.cancelToggleMode()
            }
        }
        meetingRecordingPanel.onControlCenterSaved = { [weak self] center in
            self?.updateConfig {
                $0.meetingRecordingPanelCenter = CGPointCodable(x: center.x, y: center.y)
            }
        }
        // The Record pill and the Meeting Recording Panel share one saved position so the
        // pill hands off in place when recording starts.
        meetingRecordButton.onRecord = { [weak self] in self?.recordFromMeetingRecordButton() }
        meetingRecordButton.onDismiss = { [weak self] in
            guard let self else { return }
            self.dismissedMeetingRecordButtonCandidateID = self.currentRunMeetingActivityCandidate?.id
            self.syncMeetingRecordButton()
        }
        meetingRecordButton.onCenterSaved = { [weak self] center in
            self?.updateConfig {
                $0.meetingRecordingPanelCenter = CGPointCodable(x: center.x, y: center.y)
            }
        }
        meetingRecordingPanel.onPanelOpenSaved = { [weak self] isOpen in
            self?.updateConfig { $0.meetingPanelOpen = isOpen }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app != NSRunningApplication.current
            else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastExternalApp = app
            }
        }
        dataDidChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: MuesliNotifications.dataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.historyWindowController?.reload()
                self.syncAppState()
            }
        }
        installICloudPersistentSyncObservers()

        statusBarController = StatusBarController(controller: self, runtime: runtime)
        preferencesWindowController = PreferencesWindowController(controller: self)
        historyWindowController = RecentHistoryWindowController(store: dictationStore, controller: self)
        let latestFeatureTour = latestFeatureTour()
        let automaticFeatureTour = featureTourStore.automaticTour(
            currentVersion: AppIdentity.marketingVersion,
            hasCompletedOnboarding: config.hasCompletedOnboarding,
            canPresent: canRunMainApp,
            tour: latestFeatureTour
        )
        refreshUI()
        if config.iCloudSyncEnabled {
            if MuesliICloudSyncEngine.hasRequiredEntitlement {
                enableICloudPersistentSync()
                scheduleICloudSync(intent: .manual, delay: 0.5, userInitiated: false)
            } else {
                disableICloudSyncForUnavailableEntitlement()
            }
        }

        meetingMonitor.calendarEventProvider = { [weak self] in
            self?.currentOrNearbyCachedCalendarEvent()
        }
        meetingMonitor.detectionEnabledProvider = { [weak self] in
            self?.shouldDetectMeetingActivity ?? false
        }
        meetingMonitor.mutedDetectionBundleIDsProvider = { [weak self] in
            Set(self?.config.mutedMeetingDetectionAppBundleIDs ?? [])
        }
        meetingMonitor.isRecordingProvider = { [weak self] in
            guard let self else { return false }
            return self.isMeetingRecording()
        }
        meetingMonitor.isStartingRecordingProvider = { [weak self] in
            self?.isStartingMeetingRecording ?? false
        }
        meetingMonitor.isCalendarNotificationVisibleProvider = { [weak self] in
            self?.isShowingCalendarNotification ?? false
        }
        meetingMonitor.promptVisibilityProvider = { [weak self] in
            guard let self else {
                return MeetingPromptVisibility(isVisible: false, currentPromptID: nil, shownAt: nil)
            }
            return MeetingPromptVisibility(
                isVisible: self.meetingNotification.isVisible,
                currentPromptID: self.meetingNotification.currentPromptID,
                shownAt: self.meetingNotification.shownAt
            )
        }
        meetingMonitor.onActivityCandidateChanged = { [weak self] candidate in
            self?.handleMeetingActivityCandidate(candidate)
        }
        meetingMonitor.onPromptCandidateChanged = { [weak self] candidate in
            guard let self else { return }
            if let candidate {
                self.presentMeetingDetection(candidate)
            } else {
                self.dismissPresentedMeetingDetection()
            }
        }

        // Calendar monitor populates the "Coming Up" section even when
        // meeting detection is turned off for meeting use cases. Also keep it
        // running for existing users who enabled meeting feature settings before
        // onboarding use cases existed.
        syncCalendarMonitor()

        // Defer permission-triggering monitors until after onboarding
        if canRunMainApp && shouldRunMeetingFeatureMonitors {
            startMeetingFeatureMonitors(includeMaraudersMap: true)
        }

        if canRunMainApp {
            Task { [weak self] in
                guard let self else { return }
                let includesMeetings = self.config.resolvedOnboardingUseCase.includesMeetings
                let ppOption = self.runtimePostProcessorOption()
                if #available(macOS 15, *) {
                    await self.configureTranscriptCleanupForRuntime(option: ppOption)
                    await self.transcriptionCoordinator.setNemotron35PromptId(
                        self.config.resolvedNemotron35Language.promptId
                    )
                }
                // Designate before preloading so a startup that warms a dictation
                // model and a different meeting model does not unload one of them.
                await self.applyDesignatedTranscriptionBackends()
                await self.transcriptionCoordinator.startMemoryPressureMonitoring()
                let dictationBackend = self.selectedBackend
                guard await self.prepareDictationBackend(dictationBackend) else { return }
                await self.preloadOptionalTranscriptionResources(
                    for: dictationBackend,
                    enablePostProcessor: self.canRunTranscriptCleanup(option: ppOption),
                    includeMeetingHelpers: includesMeetings,
                    meetingHelperTrigger: .appLaunch
                )
                if includesMeetings, self.selectedMeetingTranscriptionBackend != self.selectedBackend {
                    await self.transcriptionCoordinator.preload(
                        backend: self.selectedMeetingTranscriptionBackend,
                        enablePostProcessor: false,
                        includeMeetingHelpers: false,
                        appleSpeechLanguage: self.config.resolvedAppleSpeechLanguage
                    )
                }
                await MainActor.run {
                    self.refreshUI()
                }
            }
        }

        if !canRunMainApp {
            if let progress = OnboardingProgress.load() {
                showOnboarding(resumeFrom: progress)
            } else if config.hasCompletedOnboarding {
                showOnboarding(resumeFrom: onboardingProgressForPermissionRepair())
            } else {
                showOnboarding()
            }
        } else if config.openDashboardOnLaunch {
            openHistoryWindow()
        }

        if canRunMainApp {
            PostInstallChecker.check()
            if let automaticFeatureTour {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.offerFeatureTour(automaticFeatureTour) else { return }
                    self.featureTourStore.markOffered(automaticFeatureTour)
                }
            }
        }

        // Last, so the whole startup wiring is in place before this can turn the
        // post-processor on. Covers the user who was already bilingual before this
        // build shipped; the latch keeps it to one attempt (R7).
        applyBilingualRepairAutoEnableIfNeeded()
    }

    func shutdown() async {
        await recordingStartupRecoveryTask?.value
        recordingStartupRecoveryTask = nil
        recordingMaintenanceTask?.cancel()
        recordingMaintenanceTask = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        if let dataDidChangeObserver {
            DistributedNotificationCenter.default().removeObserver(dataDidChangeObserver)
            self.dataDidChangeObserver = nil
        }
        if let iCloudAppActiveObserver {
            NotificationCenter.default.removeObserver(iCloudAppActiveObserver)
            self.iCloudAppActiveObserver = nil
        }
        if let iCloudWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(iCloudWakeObserver)
            self.iCloudWakeObserver = nil
        }
        cancelActiveICloudSyncTask()
        iCloudSyncDebounceTask?.cancel()
        iCloudSyncDebounceTask = nil
        iCloudSubscriptionTask?.cancel()
        iCloudSubscriptionTask = nil
        let syncEngineCancellationTask = retireCKSyncEngine()
        hotkeyMonitor.stop()
        computerUseHotkeyMonitor.stop()
        quilHotkeyMonitor.stop()
        meetingRecordingHotkeyMonitor.stop()
        computerUseCommandTask?.cancel()
        computerUseCommandTask = nil
        computerUseCommandTaskID = nil
        clearQuilSession(cancelAudioReason: "shutdown")
        activeComputerUseAudioSessionID = nil
        pendingComputerUseStopSessionID = nil
        pendingComputerUseStopStartedAt = nil
        let attendeePersistenceTasks = calendarAttendeePersistenceTasks.values.map(\.task)
        calendarAttendeePersistenceTasks.removeAll()
        for task in attendeePersistenceTasks {
            _ = await task.value
        }
        calendarMonitor.stop()
        calendarCheckTimer?.invalidate()
        calendarCheckTimer = nil
        calendarMonitoringStarted = false
        meetingStartingNowTimers.values.forEach { $0.invalidate() }
        meetingStartingNowTimers.removeAll()
        notifiedUpcomingEventIDs.removeAll()
        autoRecordedCalendarEventIDs.removeAll()
        meetingFeatureMonitorsAllowed = false
        dictationIdleDotAllowed = false
        syncDictationIdleDot()
        disarmMeetingAutoStop()
        cancelMeetingDurationLimit()
        stopMeetingDetectionMonitor()
        dismissPresentedMeetingDetection()
        meetingNotification.close()
        meetingRecordingPanel.close()
        activeMeetingPanelOwnerID = nil
        dictationCorrectionMonitor.cancel()
        activeMeetingSession?.discard()
        activeMeetingSession = nil
        if let activeMeetingID {
            resolveLiveMeetingAfterStopFailure(id: activeMeetingID)
            self.activeMeetingID = nil
        }
        activeMeetingAudioWarning = nil
        endMeetingActivity()
        await finalizeActiveDictationCaptureForShutdown()
        computerUseAudioSessionManager.cancel(reason: "shutdown")
        await standardDictationJobQueue.cancelAllAndWait()
        let importTaskToAwait = importTask
        let meetingFinalizationTasksToAwait = Array(meetingFinalizationTasks.values)
        let traces = activeSessionTraces()
        for trace in traces {
            await trace.cancel(stage: "shutdown")
        }
        importSessionID = nil
        importTaskToAwait?.cancel()
        meetingFinalizationTasksToAwait.forEach { $0.cancel() }
        await importTaskToAwait?.value
        for task in meetingFinalizationTasksToAwait {
            await task.value
        }
        for trace in traces {
            await trace.flush()
        }
        if let recordingArtifactStore {
            try? await Task.detached(priority: .utility) {
                try recordingArtifactStore.discardPendingArtifacts()
            }.value
        }
        await syncEngineCancellationTask?.value
        await transcriptionCoordinator.shutdown()
        ComputerUseCursorOverlay.shared.close()
        dictationTextContextMonitor.stop()
        meetingRecordButton.close()
        dictationMiniIndicator.close()
        CoreAudioSystemRecorder.cleanupStaleDevices()
    }

    private func finalizeActiveDictationCaptureForShutdown() async {
        let startedAt = dictationStartedAt ?? Date()
        if let capture = await dictationAudioSessionManager.finalizeCaptureForShutdown(reason: "shutdown") {
            await resolveShutdownDictationCapture(capture, startedAt: startedAt)
        }

        if isNemotron35Streaming {
            let sessionID = nemotron35StreamingSessionID
            let frozenPolicy = nemotron35StreamingRecordingSavePolicy
            let capture: StreamingDictationShutdownCapture?
            if #available(macOS 15, *),
               let controller = _streamingDictationController as? StreamingDictationController {
                capture = await controller.finalizeCaptureForShutdown()
            } else {
                capture = nil
            }
            if let sessionID {
                await resolveShutdownDictationCapture(
                    DictationAudioTerminalCapture(
                        sessionID: sessionID,
                        outcome: .cancelled,
                        recordingSavePolicy: capture?.recordingSavePolicy ?? frozenPolicy,
                        wavURL: capture?.captureURL
                    ),
                    startedAt: startedAt
                )
            } else if let captureURL = capture?.captureURL {
                try? FileManager.default.removeItem(at: captureURL)
            }
        }

        isNemotron35Streaming = false
        _streamingDictationController = nil
        nemotron35StreamingSessionID = nil
        nemotron35StreamingRecordingSavePolicy = .never
        previousStreamText = ""
        dictationStartedAt = nil
        pendingStandardDictationStops.removeAll()
        frozenDictationTranscriptionSelections.removeAll()
        dictationMiniGeneration = nil
        clearCapturedDictationSessionContext()
        resetDictationOutputMode()
        setState(.idle)
        standardDictationWorkChanged()
    }

    func resolveShutdownDictationCapture(
        _ capture: DictationAudioTerminalCapture,
        startedAt: Date
    ) async {
        guard let sessionID = capture.sessionID else {
            if let wavURL = capture.wavURL { try? FileManager.default.removeItem(at: wavURL) }
            return
        }
        let trace = dictationSessionTraces.removeValue(forKey: sessionID)
        frozenDictationTranscriptionSelections.removeValue(forKey: sessionID)
        let didWin = await trace?.cancel(stage: "shutdown") ?? true
        guard didWin else {
            if let wavURL = capture.wavURL { try? FileManager.default.removeItem(at: wavURL) }
            return
        }
        let duration = max(Date().timeIntervalSince(startedAt), 0)
        switch capture.recordingSavePolicy {
        case .always:
            await persistAudioOnlyDictationRecording(
                capture: capture,
                startedAt: startedAt,
                durationSeconds: duration
            )
        case .prompt:
            if let wavURL = capture.wavURL { try? FileManager.default.removeItem(at: wavURL) }
            await persistUnavailableAudioOnlyDictation(
                sessionID: sessionID,
                startedAt: startedAt,
                durationSeconds: duration,
                outcome: .cancelled,
                availability: .deleted
            )
        case .never:
            if let wavURL = capture.wavURL { try? FileManager.default.removeItem(at: wavURL) }
        }
    }

    /// Ensures every trace wrapper already exposed by the controller has entered
    /// the store before a diagnostics clear advances the writer generation.
    func flushActiveSessionTraces() async {
        for trace in activeSessionTraces() {
            await trace.flush()
        }
    }

    private func configureRecordingArtifactPlayback() {
        guard let store = recordingArtifactStore else {
            RecordingArtifactPlaybackCoordinator.shared.configure(client: .unavailable)
            return
        }
        let supportDirectory = configStore.supportDirectory()
        RecordingArtifactPlaybackCoordinator.shared.configure(client: RecordingArtifactPlaybackClient(
            resolve: { owner in
                let reference: RecordingArtifactReference?
                switch owner {
                case .dictation(let id):
                    reference = try store.recordingForDictation(id: id)
                case .meeting(let id):
                    reference = try store.recordingForMeeting(id: id)
                case .session(let sessionID):
                    reference = try store.recordingForDiagnostic(sessionID: sessionID)
                        ?? store.recordingForAudioOnlyDictation(sessionID: sessionID)
                }
                guard let reference else {
                    return .unavailable(.notRetained)
                }
                let artifact = try reference.artifactID.map { try store.artifact(id: $0) }
                return RecordingArtifactResolution(
                    artifactID: reference.artifactID,
                    availability: RecordingArtifactAvailability(
                        reference.availability,
                        pendingExpiresAt: artifact?.pendingExpiresAt
                    )
                )
            },
            playbackURL: { artifactID in
                try store.playableURL(id: artifactID)
            },
            reveal: { artifactID in
                let url = try store.playableURL(id: artifactID)
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            },
            delete: { artifactID in
                let url = try? store.playableURL(id: artifactID)
                if let url {
                    try? RecordingWaveformCacheFiles.removeCachedWaveform(
                        for: url,
                        supportDirectory: supportDirectory
                    )
                }
                try store.deleteArtifact(id: artifactID)
            }
        ))
    }

    /// The one place a dictation profile becomes a routing decision. All three
    /// dictation paths — the standard stop, Nemotron double-tap streaming, and
    /// computer-use — resolve through here so they agree on what a selection
    /// means for a backend. The router degrades rather than throwing, so an
    /// unpinnable selection detects instead of failing the dictation (KD2).
    /// The local summary config a resumed meeting is regenerated with. It is a
    /// copy: the frozen profile reaches the MEETING authority only, so resuming
    /// never rewrites the live dictation languages, the legacy pins, or the
    /// confirmation flag. Pure and internal so the isolation is testable without
    /// a session or a summarizer (R22).
    nonisolated static func resumeSummaryConfig(
        base: AppConfig,
        result: MeetingSessionResult
    ) -> AppConfig {
        var summaryConfig = base
        summaryConfig.applyFrozenMeetingLanguageProfile(result.languageProfile)
        return summaryConfig
    }

    nonisolated static func dictationLanguageDecision(
        profile: LanguageProfile,
        backend: BackendOption
    ) -> LanguageRoutingDecision {
        let selection = (try? TranscriptionLanguageSelection(
            selectedLanguages: profile.selectedLanguages,
            dominantLanguage: profile.dominantLanguage
        )) ?? .automatic
        return TranscriptionLanguageRouter.resolve(
            selection: selection,
            capabilities: backend.languageCapabilities(isAvailable: true),
            workload: .dictation
        )
    }

    nonisolated static func migrateLegacyMeetingRecordings(
        historyStore: DictationStore,
        artifactStore: RecordingArtifactStore
    ) throws {
        let groupedReferences = Dictionary(
            grouping: try historyStore.meetingRecordingReferences(),
            by: { URL(fileURLWithPath: $0.savedRecordingPath).standardizedFileURL.path }
        )
        for path in groupedReferences.keys.sorted() {
            guard let references = groupedReferences[path]?.sorted(by: { $0.id < $1.id }),
                  let first = references.first else { continue }
            let sessionID = legacyMeetingRecordingSessionID(meetingID: first.id)
            do {
                let artifact = try artifactStore.migrateLegacyMeetingRecording(
                    meetingID: first.id,
                    legacyURL: URL(fileURLWithPath: path),
                    sessionID: sessionID,
                    savePolicy: .always
                )
                for reference in references.dropFirst() {
                    try artifactStore.attachExistingLegacyMeetingRecording(
                        meetingID: reference.id,
                        artifactID: artifact.id
                    )
                }
            } catch RecordingArtifactStoreError.unsafeSource,
                    RecordingArtifactStoreError.unsupportedFileExtension {
                for reference in references {
                    try artifactStore.markLegacyMeetingRecordingInvalid(meetingID: reference.id)
                }
            } catch {
                // Leave transient failures in the legacy column so the next launch can retry.
                fputs("[recordings] legacy meeting migration retry deferred: \(error)\n", stderr)
            }
        }
    }

    private nonisolated static func legacyMeetingRecordingSessionID(meetingID: Int64) -> UUID {
        let suffix = String(format: "%012llX", UInt64(bitPattern: meetingID)).suffix(12)
        return UUID(uuidString: "4D554553-4C49-4D47-0000-\(suffix)")!
    }

    private func activeSessionTraces() -> [SessionRunTrace] {
        Array(sessionTraceRegistry.values)
    }

    func recentDictations() -> [DictationRecord] {
        (try? dictationStore.recentDictations(limit: 10)) ?? []
    }

    func audioOnlyDictationHistory() async -> [DictationAudioHistoryRecord] {
        guard let recordingArtifactStore else { return [] }
        return await Task.detached(priority: .utility) {
            (try? recordingArtifactStore.audioOnlyDictationHistory()) ?? []
        }.value
    }

    func deleteAudioOnlyDictationHistory(sessionID: UUID) {
        guard let recordingArtifactStore else { return }
        var reference: RecordingArtifactReference?
        var beganDeletion = false
        do {
            reference = try recordingArtifactStore.recordingForAudioOnlyDictation(sessionID: sessionID)
            if let artifactID = reference?.artifactID,
               try recordingArtifactStore.isLastOwningHistoryReference(artifactID: artifactID) {
                RecordingArtifactPlaybackCoordinator.shared.beginExternalDeletion(artifactID: artifactID)
                beganDeletion = true
            }
            if let artifactID = try recordingArtifactStore.deleteAudioOnlyDictationHistory(sessionID: sessionID) {
                finishDurableRecordingDeletion(artifactID)
            } else if let artifactID = reference?.artifactID {
                Task {
                    await RecordingArtifactPlaybackCoordinator.shared
                        .restoreAfterSharedOwnerRemoval(artifactID: artifactID)
                }
            }
            historyWindowController?.reload()
        } catch {
            if beganDeletion, let artifactID = reference?.artifactID {
                Task {
                    await RecordingArtifactPlaybackCoordinator.shared
                        .restoreAfterSharedOwnerRemoval(artifactID: artifactID)
                }
            }
            fputs("[dictation-recording] failed to delete audio-only history: \(error)\n", stderr)
        }
    }

    func recentMeetings() -> [MeetingRecord] {
        (try? dictationStore.recentMeetings(limit: 10)) ?? []
    }

    func meeting(id: Int64) -> MeetingRecord? {
        return try? dictationStore.meeting(id: id)
    }

    func dictationStats() -> DictationStats {
        (try? dictationStore.dictationStats()) ?? DictationStats(
            totalWords: 0,
            totalSessions: 0,
            averageWordsPerSession: 0,
            averageWPM: 0,
            currentStreakDays: 0,
            longestStreakDays: 0
        )
    }

    private func filteredDictationStats() -> DictationStats {
        (try? dictationStore.dictationStats(
            fromDate: appState.dictationFromDate,
            toDate: appState.dictationToDate,
            origin: appState.dictationOriginFilter,
            targetApplication: appState.dictationApplicationFilter
        )) ?? DictationStats(
            totalWords: 0,
            totalSessions: 0,
            averageWordsPerSession: 0,
            averageWPM: 0,
            currentStreakDays: 0,
            longestStreakDays: 0
        )
    }

    func meetingStats() -> MeetingStats {
        (try? dictationStore.meetingStats()) ?? MeetingStats(totalWords: 0, totalMeetings: 0, averageWPM: 0)
    }

    func openInsights(section: InsightsSection) {
        if appState.selectedTab == .timeline || appState.selectedTab == .dictations {
            appState.insightsReturnTab = appState.selectedTab
        }
        appState.insightsInitialSection = section
        appState.selectedTab = .insights
    }

    func showModels(category: ModelsCategory) {
        if appState.isSearchActive {
            clearSearch()
        }
        appState.selectedModelsCategory = category
        appState.selectedTab = .models
    }

    @objc func showWhatsNew() {
        let tour = latestFeatureTour()
        guard beginFeatureTour(tour, source: "manual") else { return }
        featureTourStore.markOffered(tour)
    }

    private func latestFeatureTour() -> FeatureTour {
        let targetApplications = (try? dictationStore.dictationTargetApplications()) ?? []
        let latestMeetingID = (try? dictationStore.recentMeetings(limit: 1))?.first?.id
        return FeatureTourCatalog.latest(
            includeApplicationFilter: !targetApplications.isEmpty,
            includeAppleSpeech: Self.includesAppleSpeechInFeatureTour,
            includeMeetingPeople: latestMeetingID != nil
        )
    }

    private static var includesAppleSpeechInFeatureTour: Bool {
        if #available(macOS 26.0, *) {
            return AppleSpeechAnalyzerTranscriber.isSupportedOnCurrentSystem
        }
        return false
    }

    @discardableResult
    private func offerFeatureTour(_ tour: FeatureTour) -> Bool {
        guard !tour.steps.isEmpty,
              !isFeatureTourPresentationQueued,
              appState.pendingFeatureTourInvitation == nil,
              appState.activeFeatureTour == nil,
              ensureBasicDictationPermissionsBeforeDashboard() else { return false }

        isFeatureTourPresentationQueued = true
        presentHistoryWindow(whenReady: { [weak self] in
            guard let self else { return }
            self.isFeatureTourPresentationQueued = false
            guard self.appState.pendingFeatureTourInvitation == nil,
                  self.appState.activeFeatureTour == nil else { return }

            self.appState.pendingFeatureTourInvitation = tour
            TelemetryDeck.signal("feature_walkthrough.invitation_shown", parameters: [
                "version": tour.version,
                "step_count": "\(tour.steps.count)",
                "includes_apple_speech": "\(tour.steps.contains { $0.target == .appleSpeechCard })",
            ])
        })
        // The normal startup preload task continues while this invitation and
        // the walkthrough are on screen, so no second backend load is started.
        return true
    }

    func acceptFeatureTourInvitation() {
        guard let tour = appState.pendingFeatureTourInvitation else { return }
        appState.pendingFeatureTourInvitation = nil
        TelemetryDeck.signal("feature_walkthrough.decision", parameters: [
            "version": tour.version,
            "decision": "accepted",
            "step_count": "\(tour.steps.count)",
        ])
        beginFeatureTour(tour, source: "automatic")
    }

    func skipFeatureTourInvitation() {
        guard let tour = appState.pendingFeatureTourInvitation else { return }
        appState.pendingFeatureTourInvitation = nil
        TelemetryDeck.signal("feature_walkthrough.decision", parameters: [
            "version": tour.version,
            "decision": "skipped",
            "step_count": "\(tour.steps.count)",
        ])
    }

    @discardableResult
    private func beginFeatureTour(_ tour: FeatureTour, source: String) -> Bool {
        guard !tour.steps.isEmpty,
              !isFeatureTourPresentationQueued,
              ensureBasicDictationPermissionsBeforeDashboard() else { return false }

        appState.pendingFeatureTourInvitation = nil
        isFeatureTourPresentationQueued = true
        presentHistoryWindow(whenReady: { [weak self] in
            guard let self else { return }
            self.isFeatureTourPresentationQueued = false
            self.appState.activeFeatureTour = tour
            self.appState.featureTourStepIndex = 0
            self.navigateToFeatureTourStep(tour.steps[0])
            TelemetryDeck.signal("feature_walkthrough.started", parameters: [
                "version": tour.version,
                "source": source,
                "step_count": "\(tour.steps.count)",
            ])
        })
        return true
    }

    func showPreviousFeatureTourStep() {
        guard let tour = appState.activeFeatureTour else { return }
        let index = max(0, appState.featureTourStepIndex - 1)
        showFeatureTourStep(index, in: tour)
    }

    func showNextFeatureTourStep() {
        guard let tour = appState.activeFeatureTour else { return }
        let nextIndex = appState.featureTourStepIndex + 1
        guard tour.steps.indices.contains(nextIndex) else {
            completeFeatureTour()
            return
        }
        showFeatureTourStep(nextIndex, in: tour)
    }

    func dismissFeatureTour() {
        if let tour = appState.activeFeatureTour,
           tour.steps.indices.contains(appState.featureTourStepIndex) {
            TelemetryDeck.signal("feature_walkthrough.dismissed", parameters: [
                "version": tour.version,
                "step": tour.steps[appState.featureTourStepIndex].id,
                "step_index": "\(appState.featureTourStepIndex + 1)",
            ])
        }
        appState.activeFeatureTour = nil
        appState.featureTourStepIndex = 0
    }

    private func completeFeatureTour() {
        if let tour = appState.activeFeatureTour {
            TelemetryDeck.signal("feature_walkthrough.completed", parameters: [
                "version": tour.version,
                "step_count": "\(tour.steps.count)",
            ])
        }
        appState.activeFeatureTour = nil
        appState.featureTourStepIndex = 0
        appState.selectedTab = .timeline
    }

    private func showFeatureTourStep(_ index: Int, in tour: FeatureTour) {
        guard tour.steps.indices.contains(index) else { return }
        appState.featureTourStepIndex = index
        navigateToFeatureTourStep(tour.steps[index])
    }

    private func navigateToFeatureTourStep(_ step: FeatureTourStep) {
        if appState.isSearchActive {
            clearSearch()
        }
        switch step.target {
        case .timelineSidebar, .timelineFilters:
            appState.selectedTab = .timeline
        case .timelineApplications:
            guard (try? dictationStore.dictationTargetApplications().isEmpty) == false else {
                completeFeatureTour()
                return
            }
            appState.selectedTab = .timeline
        case .appleSpeechCard, .modelLibrary:
            showModels(category: .dictation)
        case .insightsEntry:
            appState.selectedTab = .timeline
        case .dictionarySuggestions:
            appState.selectedTab = .dictionary
        case .meetingsSidebar:
            appState.selectedTab = .meetings
            appState.meetingsNavigationState = .browser
            appState.selectedMeetingID = nil
            appState.selectedMeetingRecord = nil
        case .meetingPeople:
            guard let meetingID = (try? dictationStore.recentMeetings(limit: 1))?.first?.id else {
                completeFeatureTour()
                return
            }
            showMeetingDocument(id: meetingID)
        case .liveCaptionsSetting:
            appState.selectedSettingsPane = .meetings
            appState.selectedTab = .settings
        case .cloudCleanupSetting:
            appState.selectedSettingsPane = .dictation
            appState.selectedTab = .settings
        case .streamingModels, .experimentalModels:
            if let category = step.target.modelsCategory {
                showModels(category: category)
            }
        }
    }

    func closeInsights() {
        appState.selectedTab = appState.insightsReturnTab
    }

    func insightsSnapshot(range: InsightsRange) async throws -> InsightsSnapshot {
        let databaseURL = dictationStore.resolvedDatabaseURL
        return try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try DictationStore(databaseURL: databaseURL).insightsSnapshot(range: range)
        }.value
    }

    func truncate(_ text: String, limit: Int) -> String {
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit - 3)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    func refreshUI() {
        statusBarController?.setStatus("Idle")
        statusBarController?.refresh()
        historyWindowController?.updateBackendLabel()
        historyWindowController?.applyThemeAppearance()
        historyWindowController?.reload()
        preferencesWindowController?.refresh()
        syncAppState()
    }

    private func refreshICloudBridgeDeviceState() {
        appState.iCloudBridgeRemoteDeviceName = MuesliBridgeDeviceIdentity.remoteDeviceDisplayName
        appState.iCloudBridgeRemoteDevicePlatform = MuesliBridgeDeviceIdentity.remoteDevicePlatform
    }

    func syncAppState() {
        let timelineRows = (try? dictationStore.timelineEntries(
            limit: appState.timelinePageSize,
            offset: 0,
            fromDate: appState.timelineFromDate,
            toDate: appState.timelineToDate,
            origin: appState.timelineOriginFilter,
            targetApplication: appState.timelineApplicationFilter
        )) ?? []
        appState.timelineRows = timelineRows
        appState.hasMoreTimelineEntries = timelineRows.count >= appState.timelinePageSize
        let rows = (try? dictationStore.recentDictations(
            limit: appState.dictationPageSize,
            offset: 0,
            fromDate: appState.dictationFromDate,
            toDate: appState.dictationToDate,
            origin: appState.dictationOriginFilter,
            targetApplication: appState.dictationApplicationFilter
        )) ?? []
        appState.dictationRows = rows
        appState.hasMoreDictations = rows.count >= appState.dictationPageSize
        appState.dictationTargetApplications = (try? dictationStore.dictationTargetApplications()) ?? []
        appState.meetingRows = (try? dictationStore.recentMeetingList(
            limit: 200,
            folderID: appState.selectedFolderID,
            origin: appState.meetingOriginFilter
        )) ?? []
        let counts = (try? dictationStore.meetingCounts(origin: appState.meetingOriginFilter))
            ?? (total: 0, byFolder: [:], directByFolder: [:])
        appState.totalMeetingCount = counts.total
        appState.meetingCountsByFolder = counts.byFolder
        appState.directMeetingCountsByFolder = counts.directByFolder
        if let selectedMeetingID = appState.selectedMeetingID {
            appState.selectedMeetingRecord = meeting(id: selectedMeetingID)
        } else {
            appState.selectedMeetingRecord = nil
        }
        let allFolders = (try? dictationStore.listFolders()) ?? []
        if config.folderOrder.isEmpty && !allFolders.isEmpty {
            updateConfig { $0.folderOrder = allFolders.map(\.id) }
        }
        let order = config.folderOrder
        // Sort folders into a depth-first tree order so children appear beneath parents.
        appState.folders = Self.treeOrderedFolders(allFolders, order: order)
        appState.dictationStats = dictationStats()
        appState.filteredDictationStats = filteredDictationStats()
        appState.meetingStats = meetingStats()
        refreshContributionMilestonePrompt(
            totalWords: appState.dictationStats.totalWords,
            totalMeetings: appState.meetingStats.totalMeetings
        )
        appState.selectedBackend = selectedBackend
        appState.selectedMeetingTranscriptionBackend = selectedMeetingTranscriptionBackend
        appState.selectedMeetingSummaryBackend = selectedMeetingSummaryBackend
        appState.selectedPostProcessorBackend = selectedPostProcessorBackend
        appState.activePostProcessor = PostProcessorOption.resolve(id: config.activePostProcessorId)
        appState.config = config
        appState.isMeetingRecording = isMeetingRecording()
        updatePostProcessorMeetingResidency()
        appState.isMeetingRecordingPaused = isMeetingRecordingPaused()
        appState.isMeetingStarting = isStartingMeetingRecording
        appState.meetingStartStatus = meetingStartStatus
        appState.activeMeetingAudioWarning = activeMeetingAudioWarning
        appState.isChatGPTAuthenticated = chatGPTAuth.isAuthenticated
        appState.isGoogleCalendarAvailable = googleCalAuth.isAvailable
        appState.isGoogleCalendarVerified = googleCalAuth.isVerified
        appState.isGoogleCalendarAuthenticated = googleCalAuth.isAuthenticated
        refreshICloudBridgeDeviceState()
        refreshICloudBridgeStateForConfig()
        // Keep appState in sync with persisted hidden event IDs
        let persisted = Set(config.hiddenCalendarEventIDs)
        if appState.hiddenCalendarEventIDs != persisted {
            appState.hiddenCalendarEventIDs = persisted
        }
    }

    func recoverStaleLiveMeetings() {
        guard !isMeetingRecording(),
              !isStartingMeetingRecording else { return }
        let meetings: [MeetingRecord]
        do {
            meetings = try dictationStore.staleLiveMeetings()
        } catch {
            fputs("[muesli-native] failed to load stale live meetings: \(error)\n", stderr)
            return
        }

        for meeting in meetings {
            do {
                let recovered = try dictationStore.recoverLiveMeetingFromTranscriptCheckpoints(id: meeting.id)
                if recovered {
                    scheduleICloudSyncAfterLocalChange()
                } else {
                    try updateMeetingStatusAndScheduleSyncThrowing(id: meeting.id, status: .failed)
                }
                staleLiveMeetingRecoveryFailures.remove(meeting.id)
            } catch {
                staleLiveMeetingRecoveryFailures.insert(meeting.id)
                fputs("[muesli-native] failed to recover stale meeting \(meeting.id): \(error)\n", stderr)
            }
        }

        if !meetings.isEmpty {
            syncAppState()
        }
    }

    func performSearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.searchQuery = trimmed
        guard !trimmed.isEmpty else {
            appState.searchResultDictations = []
            appState.searchResultMeetings = []
            return
        }
        let store = self.dictationStore
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let (dictations, meetings) = await Task.detached(priority: .userInitiated) {
                let d = (try? store.searchDictations(query: trimmed)) ?? []
                let m = (try? store.searchMeetings(query: trimmed)) ?? []
                return (d, m)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.appState.searchResultDictations = dictations
            self.appState.searchResultMeetings = meetings
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        appState.searchQuery = ""
        appState.searchResultDictations = []
        appState.searchResultMeetings = []
    }

    /// Internal rather than private so the download-gating below can be tested directly;
    /// its result is persisted, so a wrong answer here rewrites the user's stored model.
    static func availableMeetingTranscriptionBackend(
        config: AppConfig,
        dictationBackend: BackendOption,
        downloadedOptions: [BackendOption] = BackendOption.downloaded
    ) -> BackendOption? {
        let meetingOptions = downloadedOptions.filter(\.supportsMeetingTranscription)
        let fallback = dictationBackend.supportsMeetingTranscription ? dictationBackend : nil
        // `resolveDownloaded` deliberately keeps a persisted selection that is merely not
        // downloaded yet: availability is a runtime state, and rewriting the user's choice
        // over it would lose their model the moment a cache was cleared. Meeting support is
        // a different kind of fact — a streaming-only backend appends words and never
        // revises them, so it cannot produce a final meeting transcript however complete
        // its download is. Passing such a selection through would have it survive the
        // `meetingOptions` filter it was just excluded from.
        let configured = BackendOption.resolve(
            backend: config.meetingTranscriptionBackend,
            model: config.meetingTranscriptionModel
        )
        if let configured, !configured.supportsMeetingTranscription {
            // Prefer the dictation backend only when it is actually on disk. Returning it
            // unconditionally would hand back a model the user has not downloaded while a
            // downloaded, meeting-capable one sat unconsidered in `meetingOptions` — and
            // because this result is persisted, that guess would overwrite their stored
            // selection with something that cannot run. `resolveDownloaded` gates its own
            // fallback the same way; this branch has to match it, not bypass it.
            let downloadedFallback = fallback.flatMap { candidate in
                meetingOptions.contains(candidate) ? candidate : nil
            }
            return downloadedFallback ?? meetingOptions.first ?? fallback
        }
        return BackendOption.resolveDownloaded(
            backend: config.meetingTranscriptionBackend,
            model: config.meetingTranscriptionModel,
            fallback: fallback,
            downloadedOptions: meetingOptions
        )
    }

    private static func fallbackMeetingTranscriptionBackend(
        configured: BackendOption?,
        dictationBackend: BackendOption
    ) -> BackendOption {
        if let configured, configured.supportsMeetingTranscription {
            return configured
        }
        if dictationBackend.supportsMeetingTranscription {
            return dictationBackend
        }
        return BackendOption.all.first(where: \.supportsMeetingTranscription) ?? .whisper
    }

    @discardableResult
    private func normalizeMeetingTranscriptionSelectionForAvailability(
        downloadedOptions: [BackendOption] = BackendOption.downloaded
    ) -> BackendOption? {
        let dictationBackend = BackendOption.resolve(
            backend: config.sttBackend,
            model: config.sttModel
        ) ?? selectedBackend
        guard let resolved = Self.availableMeetingTranscriptionBackend(
            config: config,
            dictationBackend: dictationBackend,
            downloadedOptions: downloadedOptions
        ) else {
            selectedMeetingTranscriptionBackend = Self.fallbackMeetingTranscriptionBackend(
                configured: BackendOption.resolve(
                    backend: config.meetingTranscriptionBackend,
                    model: config.meetingTranscriptionModel
                ),
                dictationBackend: dictationBackend
            )
            appState.selectedMeetingTranscriptionBackend = selectedMeetingTranscriptionBackend
            appState.config = config
            return nil
        }

        selectedMeetingTranscriptionBackend = resolved
        if config.meetingTranscriptionBackend != resolved.backend ||
            config.meetingTranscriptionModel != resolved.model {
            config.meetingTranscriptionBackend = resolved.backend
            config.meetingTranscriptionModel = resolved.model
            configStore.save(config)
            fputs("[muesli-native] meeting transcription model unavailable; switched to \(resolved.label)\n", stderr)
        }
        appState.selectedMeetingTranscriptionBackend = resolved
        appState.config = config
        updateActiveMeetingTranscriptionAuthority()
        return resolved
    }

    @discardableResult
    func refreshMeetingTranscriptionSelectionForAvailability() -> BackendOption? {
        normalizeMeetingTranscriptionSelectionForAvailability()
    }

    func refreshMeetingTranscriptionSelectionAfterDeleting(_ option: BackendOption) {
        if selectedMeetingTranscriptionBackend == option,
           config.usesNemotronLiveMeetingTranscript,
           !config.useLiveMeetingTranscriptAsFinal {
            selectLiveMeetingTranscriptAsFinal()
        } else {
            normalizeMeetingTranscriptionSelectionForAvailability()
        }
    }

    func updateConfig(_ mutate: (inout AppConfig) -> Void) {
        let previousMeetingCleanupIdentity = meetingCleanupIdentity(config)
        let wasICloudSyncEnabled = config.iCloudSyncEnabled
        let wasUsingAppleSpeech = selectedBackend.backend == "apple-speech"
            || selectedMeetingTranscriptionBackend.backend == "apple-speech"
        let previousMeetingInputDeviceUID = config.meetingInputDeviceUID
        let previousHotkeyTriggerThresholdMS = config.hotkeyTriggerThresholdMS
        let previousQuilHotkeyTriggerThresholdMS = config.quilHotkeyTriggerThresholdMS
        let previousComputerUseHotkeyTriggerThresholdMS = config.computerUseHotkeyTriggerThresholdMS
        let previousMeetingRecordingHotkeyTriggerThresholdMS = config.meetingRecordingHotkeyTriggerThresholdMS
        let previousEnableDictionaryCorrectionPrompts = config.enableDictionaryCorrectionPrompts
        let previousEnableLiveStreamingPartials = config.enableLiveStreamingPartials
        let previousMeetingReverseLeakSuppression = config.meetingReverseLeakSuppression
        mutate(&config)
        if previousMeetingReverseLeakSuppression != config.meetingReverseLeakSuppression {
            // R14: turning it off opens the gate for the meeting in progress; turning it back
            // on resumes gating from the estimator's current lock state.
            if config.meetingReverseLeakSuppression {
                preparingMeetingSession?.releaseReverseLeakGate()
                activeMeetingSession?.releaseReverseLeakGate()
            } else {
                preparingMeetingSession?.forceOpenReverseLeakGate()
                activeMeetingSession?.forceOpenReverseLeakGate()
            }
        }
        if previousEnableLiveStreamingPartials, !config.enableLiveStreamingPartials {
            preparingMeetingSession?.stopStreamingPartials()
            activeMeetingSession?.stopStreamingPartials()
            clearLiveMeetingPartialTails()
        }
        if previousEnableDictionaryCorrectionPrompts, !config.enableDictionaryCorrectionPrompts {
            dictationCorrectionMonitor.cancel()
            queuedDictionarySuggestionPromptKeys.removeAll()
            dictionarySuggestionPromptAdvanceTask?.cancel()
            dictionarySuggestionPromptAdvanceTask = nil
            activeDictionarySuggestionPromptKey = nil
            dictionarySuggestionPrompt.dismissWithoutNotification()
        }
        config.hotkeyTriggerThresholdMS = HotkeyTriggerTiming.clampedMilliseconds(config.hotkeyTriggerThresholdMS)
        config.quilHotkeyTriggerThresholdMS = HotkeyTriggerTiming.clampedMilliseconds(config.quilHotkeyTriggerThresholdMS)
        config.computerUseHotkeyTriggerThresholdMS = HotkeyTriggerTiming.clampedMilliseconds(config.computerUseHotkeyTriggerThresholdMS)
        config.meetingRecordingHotkeyTriggerThresholdMS = HotkeyTriggerTiming.clampedMilliseconds(config.meetingRecordingHotkeyTriggerThresholdMS)
        let hotkeyTriggerThresholdChanged = config.hotkeyTriggerThresholdMS != previousHotkeyTriggerThresholdMS
            || config.quilHotkeyTriggerThresholdMS != previousQuilHotkeyTriggerThresholdMS
            || config.computerUseHotkeyTriggerThresholdMS != previousComputerUseHotkeyTriggerThresholdMS
            || config.meetingRecordingHotkeyTriggerThresholdMS != previousMeetingRecordingHotkeyTriggerThresholdMS
        MuesliTheme.accentOverrideHex = config.accentOverrideHex
        selectedBackend = BackendOption.all.first(where: {
            $0.backend == config.sttBackend && $0.model == config.sttModel
        }) ?? .whisper
        let configuredPostProcessorBackend = TranscriptCleanupBackendOption.resolved(config.postProcessorBackend)
        let activePostProcessor = PostProcessorOption.resolve(id: config.activePostProcessorId)
        if configuredPostProcessorBackend == .local,
           !activePostProcessor.isCompatible(with: selectedBackend) {
            // Keep the selected model for a later compatible ASR choice, but
            // require an explicit re-enable after switching to Indic ASR.
            config.enablePostProcessor = false
        }
        if !configuredPostProcessorBackend.isCompatible(with: selectedBackend) {
            config.postProcessorBackend = TranscriptCleanupBackendOption.local.backend
            config.enablePostProcessor = false
        }
        if meetingCleanupIdentity(config) != previousMeetingCleanupIdentity {
            cancelMeetingTranscriptCleanupTasks()
        }
        let configuredMeetingTranscriptionBackend = BackendOption.all.first(where: {
            $0.backend == config.meetingTranscriptionBackend && $0.model == config.meetingTranscriptionModel
        })
        selectedMeetingTranscriptionBackend = Self.availableMeetingTranscriptionBackend(
            config: config,
            dictationBackend: selectedBackend
        ) ?? Self.fallbackMeetingTranscriptionBackend(
            configured: configuredMeetingTranscriptionBackend,
            dictationBackend: selectedBackend
        )
        if config.meetingTranscriptionBackend != selectedMeetingTranscriptionBackend.backend ||
            config.meetingTranscriptionModel != selectedMeetingTranscriptionBackend.model {
            config.meetingTranscriptionBackend = selectedMeetingTranscriptionBackend.backend
            config.meetingTranscriptionModel = selectedMeetingTranscriptionBackend.model
        }
        let isUsingAppleSpeech = selectedBackend.backend == "apple-speech"
            || selectedMeetingTranscriptionBackend.backend == "apple-speech"
        if wasUsingAppleSpeech && !isUsingAppleSpeech {
            Task { [weak self] in
                await self?.transcriptionCoordinator.unloadAppleSpeechTranscriber()
            }
        }
        configStore.save(config)
        meetingRecordingPanel.applyConfiguration(config)
        selectedMeetingSummaryBackend = MeetingSummaryBackendOption.all.first(where: {
            $0.backend == config.meetingSummaryBackend
        }) ?? .chatGPT
        selectedPostProcessorBackend = TranscriptCleanupBackendOption.resolved(config.postProcessorBackend)
        applyConfigRuntimeSideEffects(
            wasICloudSyncEnabled: wasICloudSyncEnabled,
            hotkeyTriggerThresholdChanged: hotkeyTriggerThresholdChanged
        )
        if previousMeetingInputDeviceUID != config.meetingInputDeviceUID {
            dictationAudioRoutingController.selectedMeetingInputDeviceUID = config.meetingInputDeviceUID
            applyMeetingInputDevice(
                dictationAudioRoutingController.preferredInputDeviceIDForMeeting(),
                explicitUserSelection: true
            )
        }
    }

    /// Persists all style definitions and assignments as one candidate before
    /// publishing them to the live runtime. A thrown error leaves both unchanged.
    func updateDictationStyleConfiguration(_ mutate: (inout AppConfig) -> Void) throws {
        let persisted = try DictationStyleSettingsModel.committing(
            current: config,
            mutate: mutate,
            persist: configStore.saveDictationStyleConfiguration
        )
        config = persisted
        appState.config = persisted
        statusBarController?.refresh()
    }

    /// Commits the language authority as one persisted transaction. Existing
    /// recordings keep their frozen profile snapshots; only future sessions see
    /// the newly published value.
    @discardableResult
    func saveLanguageProfile(_ profile: SpokenLanguageProfile) throws -> AppConfig {
        var candidate = config
        candidate.dictationLanguageProfile = profile
        let persisted = try configStore.saveLanguageProfileConfiguration(candidate)
        config = persisted
        appState.config = persisted
        statusBarController?.refresh()
        applyBilingualRepairAutoEnableIfNeeded()
        return config
    }

    /// Commits the meeting language authority. A meeting save never touches the
    /// dictation profile, the legacy pins, or the migration flag (R3).
    @discardableResult
    func saveMeetingLanguageProfile(_ profile: SpokenLanguageProfile) throws -> AppConfig {
        var candidate = config
        candidate.meetingSpokenLanguage = profile
        let persisted = try configStore.saveMeetingLanguageProfileConfiguration(candidate)
        config = persisted
        appState.config = persisted
        statusBarController?.refresh()
        return persisted
    }

    /// The notes language saves through the throwing canonical seam rather than
    /// `updateConfig`, whose save is a silent no-op while the dictation-style
    /// ruleset is quarantined; a failure has to be visible in the card (R6).
    @discardableResult
    func saveMeetingArtifactLanguagePolicy(_ policy: MeetingArtifactLanguagePolicy) throws -> AppConfig {
        var candidate = config
        candidate.meetingArtifactLanguagePolicy = policy
        let persisted = try configStore.saveMeetingLanguageProfileConfiguration(candidate)
        config = persisted
        appState.config = persisted
        statusBarController?.refresh()
        return persisted
    }

    func meetingLanguageProfileClient() -> LanguageProfileClient {
        LanguageProfileClient(
            load: { [weak self] in self?.config.meetingSpokenLanguage ?? .automatic },
            save: { [weak self] profile in
                guard let self else { throw LanguageProfileClient.Error.controllerUnavailable }
                return try self.saveMeetingLanguageProfile(profile).meetingSpokenLanguage
            },
            presentation: { profile, backend in
                // Nemotron is the sole streaming backend and carries `.meetingLive`
                // but not `.meetingFinal`; every other meeting backend is the
                // reverse. This mirrors `languageCapabilities` exactly.
                profile.presentation(
                    for: backend,
                    workload: backend.isStreamingDictationBackend ? .meetingLive : .meetingFinal
                )
            }
        )
    }

    func languageProfileClient() -> LanguageProfileClient {
        LanguageProfileClient(
            load: { [weak self] in self?.config.dictationLanguageProfile ?? .automatic },
            save: { [weak self] profile in
                guard let self else { throw LanguageProfileClient.Error.controllerUnavailable }
                return try self.saveLanguageProfile(profile).dictationLanguageProfile
            }
        )
    }

    /// Applies a previously reviewed portable replacement in the same
    /// validate-write-publish transaction used by local Writing Styles edits.
    /// Cancellation never calls this method and therefore has no side effects.
    func replaceDictationStyleRuleset(_ preview: DictationStyleRulesetPreview) throws {
        let candidate = try DictationStyleSettingsModel.replacementCandidate(
            for: preview,
            replacing: config
        )
        let expected = try DictationStyleRulesetCodec.ruleset(from: candidate)
        guard expected == preview.ruleset else {
            throw DictationStyleRulesetCodec.Error.fidelityMismatch
        }
        let persisted = try configStore.saveDictationStyleRulesetConfiguration(
            candidate,
            expectedRuleset: expected
        )
        config = persisted
        appState.config = persisted
        statusBarController?.refresh()
    }

    /// Applies the configured theme to app-level chrome. The fullscreen
    /// titlebar, menus, and panels resolve against `NSApp.appearance` rather
    /// than any individual window's appearance, so syncing only the window
    /// leaves fullscreen chrome following the OS theme instead of the app's.
    /// Also refreshes the dashboard window's own appearance.
    func applyAppThemeAppearance() {
        // NSApp is an implicitly unwrapped optional and is nil under `swift test`, where no
        // NSApplication is ever created. Touching it there traps and takes the whole test
        // bundle down, so bind it rather than forcing it.
        if let app = NSApp {
            app.appearance = NSAppearance(
                named: RecentHistoryWindowController.appearanceName(for: config.darkMode)
            )
        }
        historyWindowController?.applyThemeAppearance()
    }

    private func applyConfigRuntimeSideEffects(
        wasICloudSyncEnabled: Bool,
        hotkeyTriggerThresholdChanged: Bool
    ) {
        statusBarController?.refresh()
        statusBarController?.refreshIcon()
        hotkeyMonitor.doubleTapEnabled = config.enableDoubleTapDictation
        computerUseHotkeyMonitor.doubleTapEnabled = config.enableDoubleTapDictation
        quilHotkeyMonitor.doubleTapEnabled = config.enableDoubleTapDictation
        if hotkeyTriggerThresholdChanged {
            configureHotkeyMonitorTiming()
        }
        dictationAudioRoutingController.selectedInputDeviceUID = config.dictationInputDeviceUID
        historyWindowController?.updateBackendLabel()
        applyAppThemeAppearance()
        appState.selectedBackend = selectedBackend
        appState.selectedMeetingTranscriptionBackend = selectedMeetingTranscriptionBackend
        appState.selectedMeetingSummaryBackend = selectedMeetingSummaryBackend
        appState.selectedPostProcessorBackend = selectedPostProcessorBackend
        appState.config = config
        updateActiveMeetingTranscriptionAuthority()
        appState.isChatGPTAuthenticated = chatGPTAuth.isAuthenticated
        syncCalendarMonitor()
        syncMeetingDetectionMonitor()
        syncDictationIdleDot()
        updateDesignatedTranscriptionBackends()
        updateMeetingNotificationVisibility()
        syncDictationRecorderWarmup(intent: .idlePrewarm(.configChange))
        if !wasICloudSyncEnabled && config.iCloudSyncEnabled {
            enableICloudPersistentSync()
            scheduleICloudSync(intent: .manual, delay: 0.2, userInitiated: false)
        } else if wasICloudSyncEnabled && !config.iCloudSyncEnabled {
            disableICloudSyncRuntimeState()
        }
    }

    private func clearLiveMeetingPartialTails() {
        appState.liveMeetingPartialYou = ""
        appState.liveMeetingPartialOthers = ""
        meetingRecordingPanel.updateMeetingTranscript(
            transcript: appState.liveMeetingTranscript,
            partialYou: "",
            partialOthers: ""
        )
    }

    private func clearLiveMeetingTranscript(ownerID: Int64? = nil, generation: UUID? = nil) {
        if let ownerID, appState.liveMeetingTranscriptOwnerID != ownerID { return }
        if let generation, liveMeetingTranscriptGeneration != generation { return }
        appState.liveMeetingTranscript = ""
        appState.liveMeetingPartialYou = ""
        appState.liveMeetingPartialOthers = ""
        appState.liveMeetingTranscriptOwnerID = nil
        liveMeetingTranscriptGeneration = nil
        meetingRecordingPanel.updateMeetingTranscript(transcript: "", partialYou: "", partialOthers: "")
        // No live meeting means no panel chat, and no reason for the panel to hold focus.
        meetingRecordingPanel.setMeetingChatContext(nil)
    }

    private func isCurrentLiveMeetingTranscriptSession(ownerID: Int64, generation: UUID) -> Bool {
        appState.liveMeetingTranscriptOwnerID == ownerID
            && liveMeetingTranscriptGeneration == generation
    }

    private func refreshContributionMilestonePrompt(totalWords: Int, totalMeetings: Int) {
        let resolvedNextWordMilestone = ContributionMilestonePolicy.resolvedNextMilestone(
            storedNextMilestone: config.contributionPromptNextWordCount,
            total: totalWords,
            intervalKind: .dictationWords,
            githubStarClicked: config.contributionGitHubStarClicked,
            buyMeCoffeeClicked: config.contributionBuyMeCoffeeClicked,
            tweetClicked: config.contributionTweetClicked,
            linkedInClicked: config.contributionLinkedInClicked
        )
        let resolvedNextMeetingMilestone = ContributionMilestonePolicy.resolvedNextMilestone(
            storedNextMilestone: config.contributionPromptNextMeetingCount,
            total: totalMeetings,
            intervalKind: .meetings,
            githubStarClicked: config.contributionGitHubStarClicked,
            buyMeCoffeeClicked: config.contributionBuyMeCoffeeClicked
        )

        if config.contributionPromptNextWordCount != resolvedNextWordMilestone ||
            config.contributionPromptNextMeetingCount != resolvedNextMeetingMilestone {
            config.contributionPromptNextWordCount = resolvedNextWordMilestone
            config.contributionPromptNextMeetingCount = resolvedNextMeetingMilestone
            configStore.save(config)
        }

        appState.config = config
        appState.contributionMilestonePrompt = ContributionMilestonePolicy.prompt(
            kind: .dictationWords,
            total: totalWords,
            nextMilestone: resolvedNextWordMilestone,
            githubStarClicked: config.contributionGitHubStarClicked,
            buyMeCoffeeClicked: config.contributionBuyMeCoffeeClicked,
            tweetClicked: config.contributionTweetClicked,
            linkedInClicked: config.contributionLinkedInClicked,
            dismissedThisLaunch: contributionMilestonePromptDismissedThisLaunch
        ) ?? ContributionMilestonePolicy.prompt(
            kind: .meetings,
            total: totalMeetings,
            nextMilestone: resolvedNextMeetingMilestone,
            githubStarClicked: config.contributionGitHubStarClicked,
            buyMeCoffeeClicked: config.contributionBuyMeCoffeeClicked,
            dismissedThisLaunch: contributionMilestonePromptDismissedThisLaunch
        )
    }

    func recordContributionMilestonePromptSeen() {
        guard let prompt = appState.contributionMilestonePrompt,
              contributionMilestonePromptSeenIDsThisLaunch.insert(prompt.id).inserted else { return }
        TelemetryDeck.signal("contribution_prompt_seen", parameters: [
            "kind": prompt.kind.rawValue,
            "count": "\(prompt.count)",
            "github_star_clicked": "\(config.contributionGitHubStarClicked)",
            "buy_me_coffee_clicked": "\(config.contributionBuyMeCoffeeClicked)",
            "tweet_clicked": "\(config.contributionTweetClicked)",
            "linkedin_clicked": "\(config.contributionLinkedInClicked)",
        ])
    }

    func dismissContributionMilestonePrompt() {
        guard let prompt = appState.contributionMilestonePrompt else { return }
        contributionMilestonePromptDismissedThisLaunch = true
        appState.contributionMilestonePrompt = nil
        let nextMilestone = ContributionMilestonePolicy.nextMilestone(
            after: prompt.kind == .dictationWords ? appState.dictationStats.totalWords : appState.meetingStats.totalMeetings,
            kind: prompt.kind
        )
        switch prompt.kind {
        case .dictationWords:
            config.contributionPromptNextWordCount = nextMilestone
        case .meetings:
            config.contributionPromptNextMeetingCount = nextMilestone
        }
        configStore.save(config)
        appState.config = config
        TelemetryDeck.signal("contribution_prompt_dismissed", parameters: [
            "kind": prompt.kind.rawValue,
            "count": "\(prompt.count)",
        ])
    }

    func openContributionMilestoneAction(_ action: ContributionMilestoneAction) {
        guard let prompt = appState.contributionMilestonePrompt else { return }
        if action == .tweetAboutMuesli || action == .postOnLinkedIn {
            openContributionSocialAction(action, wordCount: prompt.count)
        } else if let supportURL = action.supportURL {
            NSWorkspace.shared.open(supportURL)
        }
        // CTA clicks intentionally dismiss for this launch; any remaining CTA can reappear next launch.
        contributionMilestonePromptDismissedThisLaunch = true
        TelemetryDeck.signal("contribution_prompt_action_clicked", parameters: [
            "action": action.rawValue,
            "kind": prompt.kind.rawValue,
            "count": "\(prompt.count)",
        ])

        updateConfig { config in
            switch action {
            case .githubStar:
                config.contributionGitHubStarClicked = true
            case .buyMeCoffee:
                config.contributionBuyMeCoffeeClicked = true
            case .tweetAboutMuesli:
                config.contributionTweetClicked = true
            case .postOnLinkedIn:
                config.contributionLinkedInClicked = true
            }
            if config.contributionGitHubStarClicked && config.contributionBuyMeCoffeeClicked {
                config.contributionPromptNextMeetingCount = nil
            }
            if config.contributionGitHubStarClicked && config.contributionBuyMeCoffeeClicked &&
                config.contributionTweetClicked && config.contributionLinkedInClicked {
                config.contributionPromptNextWordCount = nil
            }
        }
        refreshContributionMilestonePrompt(
            totalWords: appState.dictationStats.totalWords,
            totalMeetings: appState.meetingStats.totalMeetings
        )
    }

    private func openContributionSocialAction(_ action: ContributionMilestoneAction, wordCount: Int) {
        switch action {
        case .tweetAboutMuesli:
            NSWorkspace.shared.open(ContributionSocialShare.tweetURL(wordCount: wordCount))
        case .postOnLinkedIn:
            let message = ContributionSocialShare.message(wordCount: wordCount)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message, forType: .string)
            NSWorkspace.shared.open(ContributionSocialShare.linkedInURL(wordCount: wordCount))
        case .githubStar, .buyMeCoffee:
            assertionFailure("Support contribution actions should open through supportURL.")
        }
    }

    func performICloudSync() {
        scheduleICloudSync(intent: .manual, delay: 0, userInitiated: true)
    }

    func setICloudSyncEnabledFromSettings(_ enabled: Bool) {
        if enabled {
            guard MuesliICloudSyncEngine.hasRequiredEntitlement else {
                disableICloudSyncForUnavailableEntitlement()
                return
            }
            enableIPhoneBridgeSync()
        } else if config.iCloudSyncEnabled {
            updateConfig { $0.iCloudSyncEnabled = false }
        } else {
            disableICloudSyncRuntimeState()
        }
    }

    func enableIPhoneBridgeSync() {
        guard MuesliICloudSyncEngine.hasRequiredEntitlement else {
            disableICloudSyncForUnavailableEntitlement()
            return
        }
        if config.iCloudSyncEnabled {
            performICloudSync()
            return
        }

        bridgeActivationPending = true
        appState.isICloudBridgeActivationPending = true
        appState.iCloudSyncStatus = "Checking iCloud..."
        appState.iCloudBridgeState = .checkingICloud
        appState.iCloudBridgeMessage = nil
        TelemetryDeck.signal("bridge_enable_started", parameters: ["platform": "macos"])

        iCloudSyncGeneration += 1
        let generation = iCloudSyncGeneration
        let syncEngine = resolvedCKSyncEngine()
        iCloudSubscriptionTask?.cancel()
        iCloudSubscriptionTask = Task { [weak self] in
            do {
                try await syncEngine.prepare()
                await MainActor.run {
                    guard let self, self.iCloudSyncGeneration == generation else { return }
                    self.iCloudSubscriptionTask = nil
                    self.hasEnsuredICloudSubscription = true
                    self.appState.iCloudSyncStatus = "Setting up private iCloud sync..."
                    self.appState.iCloudBridgeState = .syncing
                    self.appState.iCloudBridgeMessage = nil
                    self.updateConfig { $0.iCloudSyncEnabled = true }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self, self.iCloudSyncGeneration == generation else { return }
                    self.iCloudSubscriptionTask = nil
                    self.bridgeActivationPending = false
                    self.appState.isICloudBridgeActivationPending = false
                    self.refreshICloudBridgeStateForConfig()
                }
            } catch {
                await MainActor.run {
                    guard let self, self.iCloudSyncGeneration == generation else { return }
                    self.iCloudSubscriptionTask = nil
                    self.bridgeActivationPending = false
                    self.appState.isICloudBridgeActivationPending = false
                    let message = error.localizedDescription
                    self.appState.iCloudSyncStatus = "Sync needs iCloud: \(message)"
                    if MuesliICloudSyncEngine.isICloudAccountAvailabilityError(error) {
                        self.appState.iCloudBridgeState = .needsICloud
                    } else {
                        self.appState.iCloudBridgeState = .error
                    }
                    self.appState.iCloudBridgeMessage = message
                    TelemetryDeck.signal(
                        "bridge_enable_failed",
                        parameters: ["platform": "macos", "reason": String(describing: type(of: error))]
                    )
                }
            }
        }
    }

    func handleICloudRemoteNotification(userInfo: [AnyHashable: Any]) {
        guard config.iCloudSyncEnabled,
              (MuesliICloudSyncEngine.isTextRecordSubscriptionNotification(userInfo)
                  || MuesliCKSyncEngine.isSyncNotification(userInfo)) else {
            return
        }
        scheduleICloudSync(intent: .incoming, delay: 0.2, userInitiated: false)
    }

    private func installICloudPersistentSyncObservers() {
        guard iCloudAppActiveObserver == nil else { return }
        iCloudAppActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleICloudSync(
                    intent: .incoming,
                    delay: 0.5,
                    userInitiated: false,
                    bridgeDiscoveryTriggered: true
                )
            }
        }
        iCloudWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleICloudSync(
                    intent: .incoming,
                    delay: 0.5,
                    userInitiated: false,
                    bridgeDiscoveryTriggered: true
                )
            }
        }
    }

    private func enableICloudPersistentSync() {
        guard config.iCloudSyncEnabled else { return }
        ensureICloudSubscription()
    }

    private func ensureICloudSubscription() {
        guard !hasEnsuredICloudSubscription,
              iCloudSubscriptionTask == nil else {
            return
        }
        let syncEngine = resolvedCKSyncEngine()
        iCloudSubscriptionTask = Task { [weak self] in
            do {
                try await syncEngine.prepare()
                await MainActor.run {
                    self?.hasEnsuredICloudSubscription = true
                    self?.iCloudSubscriptionTask = nil
                }
            } catch {
                fputs(
                    "[muesli-native] failed to prepare CKSyncEngine: \(String(describing: type(of: error)))\n",
                    stderr
                )
                await MainActor.run {
                    self?.iCloudSubscriptionTask = nil
                }
            }
        }
    }

    private func scheduleICloudSyncAfterLocalChange() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.scheduleICloudSyncAfterLocalChange()
            }
            return
        }
        scheduleICloudSync(intent: .outgoing, delay: 0, userInitiated: false)
    }

    private func scheduleICloudSync(
        intent: MuesliCKSyncIntent,
        delay: TimeInterval,
        userInitiated: Bool,
        bridgeDiscoveryTriggered: Bool = false
    ) {
        guard config.iCloudSyncEnabled else { return }
        guard MuesliICloudSyncEngine.hasRequiredEntitlement else {
            disableICloudSyncForUnavailableEntitlement()
            return
        }
        enableICloudPersistentSync()
        if bridgeDiscoveryTriggered {
            bridgeDiscoveryPending = true
        }
        pendingICloudSyncRequests.enqueue(intent: intent, userInitiated: userInitiated)
        guard iCloudSyncTask == nil else {
            if bridgeDiscoveryTriggered {
                bridgeDiscoveryFollowUpPending = true
            }
            return
        }
        iCloudSyncDebounceTask?.cancel()
        let milliseconds = max(Int(delay * 1_000), 0)
        iCloudSyncDebounceTask = Task { [weak self] in
            if milliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(milliseconds))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.iCloudSyncDebounceTask = nil
                self?.startICloudSync()
            }
        }
    }

    private func startICloudSync() {
        let userInitiated = pendingICloudSyncRequests.isUserInitiated
        guard config.iCloudSyncEnabled else {
            if userInitiated {
                appState.iCloudSyncStatus = "Turn on iCloud sync first."
            }
            appState.iCloudBridgeState = .notConfigured
            appState.iCloudBridgeMessage = nil
            return
        }
        guard MuesliICloudSyncEngine.hasRequiredEntitlement else {
            disableICloudSyncForUnavailableEntitlement()
            return
        }
        guard iCloudSyncTask == nil else {
            appState.isICloudSyncInProgress = true
            appState.iCloudBridgeState = .syncing
            appState.iCloudBridgeMessage = nil
            if userInitiated {
                appState.iCloudSyncStatus = "Sync already in progress."
            }
            if bridgeDiscoveryPending {
                bridgeDiscoveryFollowUpPending = true
            }
            return
        }
        guard let request = pendingICloudSyncRequests.consume() else { return }
        let intent = request.intent
        if userInitiated {
            iCloudSyncDebounceTask?.cancel()
            iCloudSyncDebounceTask = nil
        }
        enableICloudPersistentSync()
        appState.isICloudSyncInProgress = true
        appState.iCloudSyncStatus = "Syncing with private iCloud..."
        appState.iCloudBridgeState = .syncing
        appState.iCloudBridgeMessage = nil
        let store = dictationStore
        iCloudSyncGeneration += 1
        let generation = iCloudSyncGeneration
        let syncEngine = resolvedCKSyncEngine()
        let bridgeActivationPendingAtStart = bridgeActivationPending
        let bridgeDiscoveryTriggeredAtStart = bridgeDiscoveryPending
        bridgeDiscoveryPending = false
        let hasKnownCompanionDeviceAtStart = MuesliBridgeDeviceIdentity.hasCompanionRemoteDevice()
        iCloudSyncTask = Task { [weak self] in
            do {
                let forceBridgeDeviceRefresh = MuesliBridgeDeviceRefreshPolicy.shouldForceRefresh(
                    userInitiated: userInitiated,
                    bridgeActivationPending: bridgeActivationPendingAtStart,
                    bridgeDiscoveryTriggered: bridgeDiscoveryTriggeredAtStart,
                    hasKnownCompanionDevice: hasKnownCompanionDeviceAtStart
                )
                let result: ICloudSyncResult
                if intent == .manual {
                    result = try await syncEngine.syncManually(
                        forceBridgeDeviceRefresh: forceBridgeDeviceRefresh
                    )
                } else if intent == .outgoing {
                    result = try await syncEngine.sendLocalChanges(
                        forceBridgeDeviceRefresh: forceBridgeDeviceRefresh
                    )
                } else {
                    result = try await syncEngine.fetchRemoteChanges(
                        forceBridgeDeviceRefresh: forceBridgeDeviceRefresh
                    )
                }
                do {
                    _ = try store.purgeSoftDeletedTextRecords()
                } catch {
                    fputs(
                        "[muesli-native] failed to purge old iCloud tombstones: \(String(describing: type(of: error)))\n",
                        stderr
                    )
                }
                await MainActor.run {
                    guard let self, self.iCloudSyncGeneration == generation else { return }
                    self.iCloudSyncTask = nil
                    self.appState.isICloudSyncInProgress = false
                    let summary = self.formatICloudSyncSummary(result)
                    self.refreshICloudBridgeDeviceState()
                    let remoteDeviceName = MuesliBridgeDeviceIdentity.remoteDeviceDisplayName ?? "iPhone"
                    self.appState.iCloudSyncStatus = result.downloaded.total > 0
                        ? "Synced with \(remoteDeviceName)."
                        : "All text is up to date."
                    self.appState.iCloudBridgeState = .active
                    self.appState.iCloudBridgeMessage = nil
                    self.appState.iCloudLastSyncSummary = summary
                    self.appState.iCloudLastSyncedAt = result.syncedAt
                    if result.downloaded.total > 0 {
                        TelemetryDeck.signal(
                            "bridge_remote_records_seen",
                            parameters: ["platform": "macos", "count": "\(result.downloaded.total)"]
                        )
                    }
                    if self.bridgeActivationPending {
                        self.bridgeActivationPending = false
                        self.appState.isICloudBridgeActivationPending = false
                        TelemetryDeck.signal("bridge_enable_completed", parameters: ["platform": "macos"])
                    }
                    self.refreshUI()
                    let shouldRunBridgeDiscoveryFollowUp = self.bridgeDiscoveryFollowUpPending
                    self.bridgeDiscoveryFollowUpPending = false
                    if result.hasPendingUploads && intent.contains(.outgoing) {
                        self.pendingICloudSyncRequests.enqueue(
                            intent: .outgoing,
                            userInitiated: false
                        )
                    }
                    if shouldRunBridgeDiscoveryFollowUp {
                        self.pendingICloudSyncRequests.enqueue(
                            intent: .incoming,
                            userInitiated: false
                        )
                    }
                    if let followUp = self.pendingICloudSyncRequests.consume() {
                        self.scheduleICloudSync(
                            intent: followUp.intent,
                            delay: 0.2,
                            userInitiated: followUp.userInitiated,
                            bridgeDiscoveryTriggered: shouldRunBridgeDiscoveryFollowUp
                        )
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self, self.iCloudSyncGeneration == generation else { return }
                    self.iCloudSyncTask = nil
                    self.appState.isICloudSyncInProgress = false
                    let shouldRunBridgeDiscoveryFollowUp = self.bridgeDiscoveryFollowUpPending
                    self.bridgeDiscoveryFollowUpPending = false
                    if self.bridgeActivationPending {
                        self.bridgeActivationPending = false
                        self.appState.isICloudBridgeActivationPending = false
                    }
                    self.refreshICloudBridgeStateForConfig()
                    if let followUp = self.pendingICloudSyncRequests.consume() {
                        self.scheduleICloudSync(
                            intent: followUp.intent,
                            delay: 0.2,
                            userInitiated: followUp.userInitiated,
                            bridgeDiscoveryTriggered: shouldRunBridgeDiscoveryFollowUp
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.iCloudSyncGeneration == generation else { return }
                    self.iCloudSyncTask = nil
                    self.appState.isICloudSyncInProgress = false
                    let shouldRunBridgeDiscoveryFollowUp = self.bridgeDiscoveryFollowUpPending
                    self.bridgeDiscoveryFollowUpPending = false
                    let message = error.localizedDescription
                    self.appState.iCloudSyncStatus = "Sync failed: \(message)"
                    if MuesliICloudSyncEngine.isICloudAccountAvailabilityError(error) {
                        self.appState.iCloudBridgeState = .needsICloud
                    } else {
                        self.appState.iCloudBridgeState = .error
                    }
                    self.appState.iCloudBridgeMessage = message
                    if self.bridgeActivationPending {
                        self.bridgeActivationPending = false
                        self.appState.isICloudBridgeActivationPending = false
                        TelemetryDeck.signal(
                            "bridge_enable_failed",
                            parameters: ["platform": "macos", "reason": String(describing: type(of: error))]
                        )
                    }
                    // The request that failed was consumed before the cycle began.
                    // Only drain intent that arrived while it was running, so a
                    // transient failure cannot create a hot self-retry loop.
                    if let followUp = self.pendingICloudSyncRequests.consume() {
                        self.scheduleICloudSync(
                            intent: followUp.intent,
                            delay: 0.2,
                            userInitiated: followUp.userInitiated,
                            bridgeDiscoveryTriggered: shouldRunBridgeDiscoveryFollowUp
                        )
                    }
                }
            }
        }
    }

    private func cancelActiveICloudSyncTask() {
        iCloudSyncGeneration += 1
        iCloudSyncTask?.cancel()
        iCloudSyncTask = nil
        pendingICloudSyncRequests.reset()
        appState.isICloudSyncInProgress = false
        resetBridgeDiscoveryRuntimeState()
        refreshICloudBridgeStateForConfig()
    }

    private func resolvedCKSyncEngine() -> MuesliCKSyncEngine {
        if let ckSyncEngine { return ckSyncEngine }
        let lifecycleID = UUID()
        ckSyncEngineLifecycleID = lifecycleID
        let created = MuesliCKSyncEngine(
            store: dictationStore,
            bridgeRefreshDidFinish: { [weak self, lifecycleID] in
                guard let self, self.ckSyncEngineLifecycleID == lifecycleID else { return }
                self.refreshICloudBridgeDeviceState()
                self.refreshICloudBridgeStateForConfig()
            }
        )
        ckSyncEngine = created
        return created
    }

    private func retireCKSyncEngine() -> Task<Void, Never>? {
        guard let retiredEngine = ckSyncEngine else {
            return ckSyncEngineCancellationTask
        }
        ckSyncEngineLifecycleID = UUID()
        ckSyncEngine = nil
        let previousCancellationTask = ckSyncEngineCancellationTask
        ckSyncEngineCancellationGeneration += 1
        let cancellationGeneration = ckSyncEngineCancellationGeneration
        let cancellationTask = Task { [weak self] in
            await previousCancellationTask?.value
            await retiredEngine.cancel()
            guard let self,
                  self.ckSyncEngineCancellationGeneration == cancellationGeneration else { return }
            self.ckSyncEngineCancellationTask = nil
        }
        ckSyncEngineCancellationTask = cancellationTask
        return cancellationTask
    }

    private func disableICloudSyncRuntimeState() {
        cancelActiveICloudSyncTask()
        iCloudSyncDebounceTask?.cancel()
        iCloudSyncDebounceTask = nil
        iCloudSubscriptionTask?.cancel()
        iCloudSubscriptionTask = nil
        let generation = iCloudSyncGeneration
        let cancellationTask = retireCKSyncEngine()
        resetICloudSubscriptionState()
        resetBridgeDiscoveryRuntimeState()
        appState.iCloudSyncStatus = "Turning off iCloud sync..."
        appState.iCloudBridgeState = .syncing
        appState.iCloudBridgeMessage = nil
        Task { [weak self] in
            await cancellationTask?.value
            guard let self,
                  self.iCloudSyncGeneration == generation,
                  self.ckSyncEngine == nil else { return }
            self.appState.iCloudSyncStatus = "iCloud sync is off."
            self.appState.iCloudBridgeState = .notConfigured
        }
    }

    private func disableICloudSyncForUnavailableEntitlement() {
        cancelActiveICloudSyncTask()
        iCloudSyncDebounceTask?.cancel()
        iCloudSyncDebounceTask = nil
        iCloudSubscriptionTask?.cancel()
        iCloudSubscriptionTask = nil
        let generation = iCloudSyncGeneration
        let cancellationTask = retireCKSyncEngine()
        resetICloudSubscriptionState()
        resetBridgeDiscoveryRuntimeState()
        appState.iCloudSyncStatus = "Stopping unavailable iCloud sync..."
        appState.iCloudBridgeState = .syncing
        appState.iCloudBridgeMessage = nil
        Task { [weak self] in
            await cancellationTask?.value
            guard let self,
                  self.iCloudSyncGeneration == generation,
                  self.ckSyncEngine == nil else { return }
            self.appState.iCloudSyncStatus = "iCloud sync is unavailable in this local-only build."
            self.appState.iCloudBridgeState = .notConfigured
        }
    }

    private func resetBridgeDiscoveryRuntimeState() {
        bridgeActivationPending = false
        bridgeDiscoveryPending = false
        bridgeDiscoveryFollowUpPending = false
        appState.isICloudBridgeActivationPending = false
    }

    private func resetICloudSubscriptionState() {
        iCloudSubscriptionTask?.cancel()
        iCloudSubscriptionTask = nil
        hasEnsuredICloudSubscription = false
    }

    private func refreshICloudBridgeStateForConfig() {
        if appState.isICloudBridgeActivationPending {
            appState.iCloudBridgeState = .checkingICloud
            return
        }
        if appState.isICloudSyncInProgress {
            appState.iCloudBridgeState = .syncing
            return
        }
        if !config.iCloudSyncEnabled {
            appState.iCloudBridgeState = .notConfigured
            appState.iCloudBridgeMessage = nil
            return
        }
        if !MuesliICloudSyncEngine.hasRequiredEntitlement {
            appState.iCloudBridgeState = .notConfigured
            appState.iCloudBridgeMessage = nil
            return
        }
        switch appState.iCloudBridgeState {
        case .needsICloud, .error:
            return
        case .notConfigured, .checkingICloud, .syncing, .active:
            appState.iCloudBridgeState = .active
            appState.iCloudBridgeMessage = nil
        }
    }

    private func formatICloudSyncSummary(_ result: ICloudSyncResult) -> String {
        "\(formatICloudSyncCounts(result.uploaded)) up, \(formatICloudSyncCounts(result.downloaded)) down"
    }

    private func formatICloudSyncCounts(_ counts: ICloudSyncKindCounts) -> String {
        guard counts.total > 0 else { return "0" }
        var parts: [String] = []
        if counts.dictations > 0 {
            parts.append("\(counts.dictations) \(counts.dictations == 1 ? "dictation" : "dictations")")
        }
        if counts.meetings > 0 {
            parts.append("\(counts.meetings) \(counts.meetings == 1 ? "meeting" : "meetings")")
        }
        return "\(counts.total) (\(parts.joined(separator: ", ")))"
    }

    func availableDictationInputDevices() -> [AudioInputDeviceInfo] {
        dictationAudioRoutingController.availableInputDevices()
    }

    func selectDictationInputDeviceUID(_ uid: String?) {
        updateConfig { $0.dictationInputDeviceUID = uid }
    }

    func selectMeetingInputDeviceUID(_ uid: String?) {
        updateConfig { $0.meetingInputDeviceUID = uid }
    }

    private func applyMeetingInputDevice(
        _ deviceID: AudioObjectID?,
        explicitUserSelection: Bool = false
    ) {
        preparingMeetingSession?.setPreferredMicrophoneInputDeviceID(
            deviceID,
            explicitUserSelection: explicitUserSelection
        )
        if activeMeetingSession !== preparingMeetingSession {
            activeMeetingSession?.setPreferredMicrophoneInputDeviceID(
                deviceID,
                explicitUserSelection: explicitUserSelection
            )
        }
    }

    func updateUpcomingMeetingsWindow(dayCount: Int) {
        let resolvedDayCount = UpcomingMeetingsWindow.resolve(dayCount: dayCount).dayCount
        guard config.upcomingMeetingsDayCount != resolvedDayCount else { return }

        updateConfig { $0.upcomingMeetingsDayCount = resolvedDayCount }
        Task {
            let refreshed = await refreshUpcomingCalendarEvents()
            guard refreshed else { return }
            checkUpcomingCalendarNotifications()
            meetingMonitor.refreshState(trigger: .calendarChanged)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let result = launchAtLoginCoordinator.setEnabled(enabled, config: config)
        if let error = result.error {
            fputs("[launch-at-login] failed to set enabled=\(enabled): \(error)\n", stderr)
        }
        appState.launchAtLoginRegistrationState = result.registrationState
        updateConfig { $0.launchAtLogin = result.config.launchAtLogin }
        if enabled, result.registrationState == .requiresApproval {
            launchAtLoginCoordinator.openSystemSettingsLoginItems()
        }
    }

    func openLaunchAtLoginSettings() {
        launchAtLoginCoordinator.openSystemSettingsLoginItems()
    }

    func refreshLaunchAtLoginState() {
        let result = launchAtLoginCoordinator.refreshStatus(config: config)
        appState.launchAtLoginRegistrationState = result.registrationState
        let refreshed = result.config
        guard refreshed.launchAtLogin != config.launchAtLogin else { return }
        updateConfig { $0.launchAtLogin = refreshed.launchAtLogin }
    }

    private func syncLaunchAtLoginConfigWithSystem() {
        let result = launchAtLoginCoordinator.reconcileOnStartup(config: config)
        if let error = result.error {
            fputs("[launch-at-login] failed to apply saved launch-at-login setting: \(error)\n", stderr)
        }
        appState.launchAtLoginRegistrationState = result.registrationState
        let reconciled = result.config
        guard reconciled.launchAtLogin != config.launchAtLogin else { return }
        updateConfig { $0.launchAtLogin = reconciled.launchAtLogin }
    }

    func selectBackend(_ option: BackendOption) {
        let replacesGemmaCleanup = !selectedPostProcessorBackend.isCompatible(with: option)
        let hasLocalCleanupModel = PostProcessorOption.runtimeOption(id: config.activePostProcessorId) != nil
        updateConfig {
            $0.sttBackend = option.backend
            $0.sttModel = option.model
            if replacesGemmaCleanup {
                $0.postProcessorBackend = TranscriptCleanupBackendOption.local.backend
                if !hasLocalCleanupModel {
                    $0.enablePostProcessor = false
                }
            }
        }
        dictationBackendReadiness = .preparing
        Task { [weak self] in
            guard let self else { return }
            // Push the selected Nemotron 3.5 language before preload so the loaded
            // transcriber is conditioned on the right prompt_id.
            await self.transcriptionCoordinator.setNemotron35PromptId(self.config.resolvedNemotron35Language.promptId)
            let ppOption = self.runtimePostProcessorOption()
            await self.configureTranscriptCleanupForRuntime(option: ppOption)
            let prepared = await self.prepareDictationBackend(option)
            if prepared {
                await self.preloadOptionalTranscriptionResources(
                    for: option,
                    enablePostProcessor: self.canRunTranscriptCleanup(option: ppOption),
                    includeMeetingHelpers: self.config.resolvedOnboardingUseCase.includesMeetings,
                    meetingHelperTrigger: .backendChange
                )
            }
            await MainActor.run {
                self.statusBarController?.refresh()
                self.historyWindowController?.updateBackendLabel()
            }
        }
    }

    private func prepareDictationBackend(_ backend: BackendOption) async -> Bool {
        do {
            try await transcriptionCoordinator.preloadRequired(
                backend: backend,
                enablePostProcessor: false,
                includeMeetingHelpers: false,
                appleSpeechLanguage: config.resolvedAppleSpeechLanguage
            )
            guard selectedBackend == backend else { return false }
            dictationBackendReadiness = .ready
            return true
        } catch {
            fputs("[muesli-native] dictation backend preparation failed for \(backend.backend)/\(backend.model): \(error)\n", stderr)
            guard selectedBackend == backend else { return false }
            dictationBackendReadiness = .failed
            return false
        }
    }

    /// Tells the coordinator which backends are still spoken for, so it can release
    /// the models behind selections the user has moved on from.
    ///
    /// Routed through every config change rather than the individual selection
    /// handlers: the dictation model, the meeting model, the live-caption model and
    /// the meetings-enabled switch all land here, and an unchanged designation is a
    /// no-op on the coordinator side.
    private func updateDesignatedTranscriptionBackends() {
        Task { [weak self] in
            await self?.applyDesignatedTranscriptionBackends()
        }
    }

    private func applyDesignatedTranscriptionBackends() async {
        let includesMeetings = config.resolvedOnboardingUseCase.includesMeetings
        // Parakeet EOU live captions load their own model outside the coordinator,
        // so only a Nemotron selection designates a coordinator-held backend.
        let usesSharedLiveCaptionModel = includesMeetings
            && config.enableLiveStreamingPartials
            && config.resolvedMeetingLiveCaptionBackend == .nemotron35
        await transcriptionCoordinator.setDesignatedBackends(
            dictation: selectedBackend.backend,
            meetingTranscription: includesMeetings ? selectedMeetingTranscriptionBackend.backend : nil,
            meetingLiveCaption: usesSharedLiveCaptionModel
                ? BackendOption.nemotron35Multilingual.backend
                : nil
        )
    }

    private func preloadOptionalTranscriptionResources(
        for backend: BackendOption,
        enablePostProcessor: Bool,
        includeMeetingHelpers: Bool,
        meetingHelperTrigger: DiarizerPreloadTrigger
    ) async {
        await transcriptionCoordinator.preloadPostProcessorIfNeeded(
            enabled: enablePostProcessor,
            transcriptionBackend: backend
        )
        if includeMeetingHelpers {
            await transcriptionCoordinator.preloadMeetingHelpers(trigger: meetingHelperTrigger)
        }
    }

    func selectMeetingTranscriptionBackend(_ option: BackendOption, requireDownloaded: Bool = true) {
        applyMeetingTranscriptionBackend(option, requireDownloaded: requireDownloaded)
    }

    func selectMeetingFinalTranscriptBackend(
        _ option: BackendOption,
        requireDownloaded: Bool = true
    ) {
        applyMeetingTranscriptionBackend(option, requireDownloaded: requireDownloaded) {
            $0.useLiveMeetingTranscriptAsFinal = false
        }
    }

    func selectLiveMeetingTranscriptAsFinal() {
        updateConfig { $0.useLiveMeetingTranscriptAsFinal = true }
    }

    private func applyMeetingTranscriptionBackend(
        _ option: BackendOption,
        requireDownloaded: Bool = true,
        additionalConfigMutation: ((inout AppConfig) -> Void)? = nil
    ) {
        guard option.supportsMeetingTranscription else {
            presentErrorAlert(
                title: "Meeting model unavailable",
                message: "\(option.label) is optimized for dictation and cannot be used for meeting transcription."
            )
            normalizeMeetingTranscriptionSelectionForAvailability()
            return
        }
        guard !requireDownloaded || option.isDownloaded else {
            presentErrorAlert(
                title: "Meeting model unavailable",
                message: "Download \(option.label) before using it for meeting transcription."
            )
            normalizeMeetingTranscriptionSelectionForAvailability()
            return
        }
        if !requireDownloaded {
            let wasICloudSyncEnabled = config.iCloudSyncEnabled
            config.meetingTranscriptionBackend = option.backend
            config.meetingTranscriptionModel = option.model
            additionalConfigMutation?(&config)
            configStore.save(config)
            selectedMeetingTranscriptionBackend = option
            appState.selectedMeetingTranscriptionBackend = option
            appState.config = config
            applyConfigRuntimeSideEffects(
                wasICloudSyncEnabled: wasICloudSyncEnabled,
                hotkeyTriggerThresholdChanged: false
            )
            return
        }
        updateConfig { config in
            config.meetingTranscriptionBackend = option.backend
            config.meetingTranscriptionModel = option.model
            additionalConfigMutation?(&config)
        }
        Task { [weak self] in
            guard let self else { return }
            await self.transcriptionCoordinator.preload(
                backend: option,
                enablePostProcessor: false,
                includeMeetingHelpers: true,
                appleSpeechLanguage: self.config.resolvedAppleSpeechLanguage
            )
            await MainActor.run {
                self.statusBarController?.refresh()
            }
        }
    }

    private func updateActiveMeetingTranscriptionAuthority() {
        activeMeetingSession?.updateTranscriptionAuthority(
            backend: selectedMeetingTranscriptionBackend,
            usesUnifiedNemotronTranscript: config.usesUnifiedNemotronMeetingTranscript
        )
    }

    func selectCohereLanguage(_ language: CohereTranscribeLanguage) {
        updateConfig {
            $0.cohereLanguage = language.rawValue
        }
    }

    func selectIndicASRLanguage(_ language: IndicASRLanguage) {
        updateConfig {
            $0.indicASRLanguage = language.rawValue
        }
    }

    func selectWhisperLanguage(_ language: WhisperKitLanguage) {
        updateConfig {
            $0.whisperLanguage = language.rawValue
        }
    }

    func selectAppleSpeechLanguage(_ identifier: String) {
        let normalized = AppleSpeechLanguageOption.normalize(identifier)
        guard normalized != config.resolvedAppleSpeechLanguage else { return }
        updateConfig { $0.appleSpeechLanguage = normalized }

        Task { [weak self] in
            guard let self else { return }
            await self.transcriptionCoordinator.unloadAppleSpeechTranscriber()
            let usesAppleSpeech = self.selectedBackend.backend == "apple-speech"
                || self.selectedMeetingTranscriptionBackend.backend == "apple-speech"
            guard usesAppleSpeech else { return }
            await self.transcriptionCoordinator.preload(
                backend: .appleSpeechAnalyzer,
                enablePostProcessor: false,
                includeMeetingHelpers: false,
                appleSpeechLanguage: normalized
            )
        }
    }

    var isPostProcessorReady: Bool {
        canRunTranscriptCleanup(option: runtimePostProcessorOption())
    }

    @discardableResult
    private func normalizePostProcessorSelectionForAvailability() -> PostProcessorOption? {
        guard let option = runtimePostProcessorOption() else {
            appState.activePostProcessor = PostProcessorOption.resolve(id: config.activePostProcessorId)
            return nil
        }
        if config.activePostProcessorId != option.id {
            updateConfig { $0.activePostProcessorId = option.id }
        }
        appState.activePostProcessor = option
        return option
    }

    private func runtimePostProcessorOption(
        config runtimeConfig: AppConfig? = nil,
        backend: TranscriptCleanupBackendOption? = nil
    ) -> PostProcessorOption? {
        let runtimeConfig = runtimeConfig ?? config
        guard (backend ?? selectedPostProcessorBackend) == .local else { return nil }
        return PostProcessorOption.runtimeOption(id: runtimeConfig.activePostProcessorId)
    }

    private func canRunTranscriptCleanup(
        option: PostProcessorOption?,
        config runtimeConfig: AppConfig? = nil,
        transcriptionBackend: BackendOption? = nil,
        cleanupBackend: TranscriptCleanupBackendOption? = nil
    ) -> Bool {
        transcriptCleanupReadiness(
            option: option,
            config: runtimeConfig,
            transcriptionBackend: transcriptionBackend,
            cleanupBackend: cleanupBackend
        ) == .ready
    }

    private func transcriptCleanupReadiness(
        option: PostProcessorOption?,
        config runtimeConfig: AppConfig? = nil,
        transcriptionBackend: BackendOption? = nil,
        cleanupBackend: TranscriptCleanupBackendOption? = nil
    ) -> DictationCleanupReadiness {
        let runtimeConfig = runtimeConfig ?? config
        let transcriptionBackend = transcriptionBackend ?? selectedBackend
        let cleanupBackend = cleanupBackend ?? selectedPostProcessorBackend
        guard runtimeConfig.enablePostProcessor else { return .disabled }
        guard cleanupBackend.isCompatible(with: transcriptionBackend) else { return .unavailable }
        let isAvailable: Bool
        if cleanupBackend == .local {
            isAvailable = option != nil
        } else if cleanupBackend == .gemma4LiteRT {
            isAvailable = Gemma4LiteRTModelStore.isAvailableLocally()
        } else {
            isAvailable = TranscriptCleanupClient.hasRequiredSettings(
                for: cleanupBackend,
                config: runtimeConfig,
                isChatGPTAuthenticated: chatGPTAuth.isAuthenticated
            )
        }
        return .resolve(isEnabled: true, isAvailable: isAvailable)
    }

    private func configureTranscriptCleanupForRuntime(
        option: PostProcessorOption? = nil,
        config runtimeConfig: AppConfig? = nil,
        backend: TranscriptCleanupBackendOption? = nil
    ) async {
        let runtimeConfig = runtimeConfig ?? config
        let backend = backend ?? selectedPostProcessorBackend
        await transcriptionCoordinator.configurePostProcessor(
            backend: backend,
            option: option ?? runtimePostProcessorOption(config: runtimeConfig, backend: backend),
            systemPrompt: DictationCleanupPromptComposer.systemPrompt(
                config: runtimeConfig,
                selection: nil,
                cleanupBackend: backend
            ),
            config: runtimeConfig
        )
    }

    func setPostProcessorEnabled(_ enabled: Bool) {
        guard !enabled || selectedPostProcessorBackend.isCompatible(with: selectedBackend) else {
            updateConfig { $0.enablePostProcessor = false }
            return
        }
        if enabled, selectedPostProcessorBackend == .local {
            guard let option = normalizePostProcessorSelectionForAvailability(),
                  option.isCompatible(with: selectedBackend) else {
                updateConfig { $0.enablePostProcessor = false }
                return
            }
        }
        if enabled, selectedPostProcessorBackend == .gemma4LiteRT,
           !Gemma4LiteRTModelStore.isAvailableLocally(
               model: Gemma4LiteRTModel.resolved(config.postProcessorGemmaModel)
           ) {
            updateConfig { $0.enablePostProcessor = false }
            showModels(category: .postProcessing)
            return
        }
        updateConfig { $0.enablePostProcessor = enabled }
        preloadExperimentalTranscriptionFeatures()
    }

    /// Turns dictation cleanup on once for a bilingual profile (KTD6, R7).
    ///
    /// Records the attempt before enabling, so a readiness refusal does not leave
    /// the latch open for a retry on every launch.
    func applyBilingualRepairAutoEnableIfNeeded() {
        let decision = BilingualRepairAutoEnable.decide(config: config)
        guard decision.recordsAttempt else { return }
        updateConfig { $0.bilingualRepairAutoEnableApplied = true }
        guard decision.enablesPostProcessor else { return }
        setPostProcessorEnabled(true)
    }

    func preloadExperimentalTranscriptionFeatures() {
        let ppOption = runtimePostProcessorOption()
        let enabled = canRunTranscriptCleanup(option: ppOption)
        Task { [weak self] in
            guard let self else { return }
            await self.configureTranscriptCleanupForRuntime(option: ppOption)
            await self.transcriptionCoordinator.preloadPostProcessorIfNeeded(
                enabled: enabled,
                transcriptionBackend: self.selectedBackend
            )
        }
    }

    /// Keeps the on-device cleanup model loaded for as long as a meeting is
    /// recording, starting, or still being processed in the background.
    private func updatePostProcessorMeetingResidency() {
        let held = isMeetingRecording()
            || isStartingMeetingRecording
            || backgroundMeetingProcessingCount > 0
        guard held != isPostProcessorHeldForMeeting else { return }
        isPostProcessorHeldForMeeting = held
        Task { [weak self] in
            guard let self else { return }
            await self.transcriptionCoordinator.setMeetingActive(held)
        }
    }

    func selectPostProcessor(_ option: PostProcessorOption) {
        guard option.isCompatible(with: selectedBackend) else {
            presentErrorAlert(
                title: "Cleanup model unavailable",
                message: "S1-mini cleans English transcripts and cannot be used with Indic ASR."
            )
            return
        }
        updateConfig {
            $0.postProcessorBackend = TranscriptCleanupBackendOption.local.backend
            $0.activePostProcessorId = option.id
        }
        selectedPostProcessorBackend = .local
        appState.selectedPostProcessorBackend = .local
        appState.activePostProcessor = option
        guard config.enablePostProcessor else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.configureTranscriptCleanupForRuntime(option: option)
        }
    }

    func selectPostProcessorBackend(_ option: TranscriptCleanupBackendOption) {
        guard option.isCompatible(with: selectedBackend) else {
            presentErrorAlert(
                title: "Cleanup model unavailable",
                message: "Gemma 4 cannot clean up a transcription produced by the same Gemma 4 backend."
            )
            return
        }
        updateConfig { $0.postProcessorBackend = option.backend }
        selectedPostProcessorBackend = option
        appState.selectedPostProcessorBackend = option
        if option == .local, config.enablePostProcessor {
            guard normalizePostProcessorSelectionForAvailability() != nil else {
                updateConfig { $0.enablePostProcessor = false }
                showModels(category: .postProcessing)
                return
            }
        }
        if option == .gemma4LiteRT, config.enablePostProcessor,
           !Gemma4LiteRTModelStore.isAvailableLocally(
               model: Gemma4LiteRTModel.resolved(config.postProcessorGemmaModel)
           ) {
            updateConfig { $0.enablePostProcessor = false }
            showModels(category: .postProcessing)
            return
        }
        preloadExperimentalTranscriptionFeatures()
    }

    func selectGemma4PostProcessor(_ model: Gemma4LiteRTModel) {
        guard TranscriptCleanupBackendOption.gemma4LiteRT.isCompatible(with: selectedBackend) else {
            presentErrorAlert(
                title: "Cleanup model unavailable",
                message: "Gemma 4 cannot clean up a transcription produced by another Gemma 4 model."
            )
            return
        }
        updateConfig {
            $0.postProcessorBackend = TranscriptCleanupBackendOption.gemma4LiteRT.backend
            $0.postProcessorGemmaModel = model.repoID
        }
        selectedPostProcessorBackend = .gemma4LiteRT
        appState.selectedPostProcessorBackend = .gemma4LiteRT
        if config.enablePostProcessor,
           !Gemma4LiteRTModelStore.isAvailableLocally(model: model) {
            updateConfig { $0.enablePostProcessor = false }
            showModels(category: .postProcessing)
            return
        }
        preloadExperimentalTranscriptionFeatures()
    }

    func updatePostProcessorModel(_ model: String, for backend: TranscriptCleanupBackendOption) {
        updateConfig { config in
            switch backend.llmBackend {
            case .some(.chatGPT):
                config.postProcessorChatGPTModel = model
            case .some(.openAI):
                config.postProcessorOpenAIModel = model
            case .some(.openRouter):
                config.postProcessorOpenRouterModel = model
            case .some(.ollama):
                config.postProcessorOllamaModel = model
            case .some(.lmStudio):
                config.postProcessorLMStudioModel = model
            case .some(.customLLM):
                config.postProcessorCustomLLMModel = model
            default:
                break
            }
        }
        guard config.enablePostProcessor else { return }
        preloadExperimentalTranscriptionFeatures()
    }

    func selectTranscriptCleanupPrompt(id: String) throws {
        let preset = TranscriptCleanupPrompts.resolve(id: id, custom: config.customTranscriptCleanupPrompts)
        try updateDictationStyleConfiguration {
            $0.activeTranscriptCleanupPromptId = preset.id
            $0.postProcessorSystemPrompt = preset.prompt
        }
        preloadExperimentalTranscriptionFeatures()
    }

    func createTranscriptCleanupPrompt(name: String, prompt: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }
        let preset = CustomTranscriptCleanupPrompt(name: trimmedName, prompt: trimmedPrompt)
        try updateDictationStyleConfiguration {
            $0.customTranscriptCleanupPrompts.append(preset)
            $0.activeTranscriptCleanupPromptId = preset.id
            $0.postProcessorSystemPrompt = preset.prompt
        }
        preloadExperimentalTranscriptionFeatures()
    }

    func updateTranscriptCleanupPrompt(id: String, name: String, prompt: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }
        try updateDictationStyleConfiguration {
            guard let index = $0.customTranscriptCleanupPrompts.firstIndex(where: { $0.id == id }) else { return }
            $0.customTranscriptCleanupPrompts[index].name = trimmedName
            $0.customTranscriptCleanupPrompts[index].prompt = trimmedPrompt
            if $0.activeTranscriptCleanupPromptId == id {
                $0.postProcessorSystemPrompt = trimmedPrompt
            }
        }
        preloadExperimentalTranscriptionFeatures()
    }

    func deleteTranscriptCleanupPrompt(id: String) throws {
        let repaired = DictationStyleSettingsModel.deletingStyle(id: id, from: config)
        try updateDictationStyleConfiguration { $0 = repaired }
        preloadExperimentalTranscriptionFeatures()
    }

    func selectMeetingSummaryBackend(_ option: MeetingSummaryBackendOption) {
        updateConfig {
            $0.meetingSummaryBackend = option.backend
        }
    }

    func availableMeetingTemplates() -> [MeetingTemplateDefinition] {
        MeetingTemplates.allDefinitions(customTemplates: config.customMeetingTemplates)
    }

    func builtInMeetingTemplates() -> [MeetingTemplateDefinition] {
        MeetingTemplates.builtIns
    }

    func customMeetingTemplates() -> [CustomMeetingTemplate] {
        config.customMeetingTemplates
    }

    func defaultMeetingTemplate() -> MeetingTemplateSnapshot {
        MeetingTemplates.resolveSnapshot(
            id: config.defaultMeetingTemplateID,
            customTemplates: config.customMeetingTemplates
        )
    }

    func meetingTemplateSnapshot(for meeting: MeetingRecord) -> MeetingTemplateSnapshot {
        MeetingTemplates.snapshot(
            for: meeting,
            customTemplates: config.customMeetingTemplates,
            defaultTemplateID: config.defaultMeetingTemplateID
        )
    }

    func updateDefaultMeetingTemplate(id: String) {
        let resolved = MeetingTemplates.resolveSnapshot(id: id, customTemplates: config.customMeetingTemplates)
        updateConfig {
            $0.defaultMeetingTemplateID = resolved.id
        }
    }

    func createCustomMeetingTemplate(name: String, prompt: String, icon: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }
        updateConfig {
            $0.customMeetingTemplates.append(
                CustomMeetingTemplate(
                    name: trimmedName,
                    prompt: trimmedPrompt,
                    icon: MeetingTemplates.normalizedCustomIcon(named: icon)
                )
            )
        }
    }

    func updateCustomMeetingTemplate(id: String, name: String, prompt: String, icon: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }
        updateConfig {
            guard let index = $0.customMeetingTemplates.firstIndex(where: { $0.id == id }) else { return }
            $0.customMeetingTemplates[index].name = trimmedName
            $0.customMeetingTemplates[index].prompt = trimmedPrompt
            $0.customMeetingTemplates[index].icon = MeetingTemplates.normalizedCustomIcon(named: icon)
        }
    }

    func deleteCustomMeetingTemplate(id: String) {
        updateConfig {
            $0.customMeetingTemplates.removeAll { $0.id == id }
            if $0.defaultMeetingTemplateID == id {
                $0.defaultMeetingTemplateID = MeetingTemplates.autoID
            }
        }
    }

    /// Returns nil on success, or an error message on failure.
    func signInWithChatGPT(selectMeetingSummaryBackend shouldSelectMeetingSummaryBackend: Bool = true) async -> String? {
        do {
            try await chatGPTAuth.signIn()
            if shouldSelectMeetingSummaryBackend {
                selectMeetingSummaryBackend(.chatGPT)
            }
            syncAppState()
            preloadExperimentalTranscriptionFeatures()
            return nil
        } catch {
            fputs("[muesli-native] ChatGPT sign-in failed: \(error)\n", stderr)
            return error.localizedDescription
        }
    }

    func signOutChatGPT() {
        chatGPTAuth.signOut()
        if selectedMeetingSummaryBackend == .chatGPT {
            selectMeetingSummaryBackend(.openAI)
        }
        syncAppState()
    }

    // MARK: - Google Calendar

    func signInWithGoogleCalendar() async -> String? {
        do {
            try await googleCalAuth.signIn()
            syncAppState()
            Task {
                await refreshUpcomingCalendarEvents()
                await refreshGoogleCalendarList()
            }
            return nil
        } catch {
            fputs("[muesli-native] Google Calendar sign-in failed: \(error)\n", stderr)
            return error.localizedDescription
        }
    }

    func signOutGoogleCalendar() {
        invalidateGoogleCalendarAuth()
        Task { await refreshUpcomingCalendarEvents() }
    }

    private func invalidateGoogleCalendarAuth() {
        googleCalAuth.signOut()
        googleCalClient.resetSync()
        appState.availableGoogleCalendars = []
        appState.googleCalendarListLoadState = .idle
        syncAppState()
    }

    /// Refresh the EventKit-available calendars list. Cheap (no network), safe
    /// to call frequently — driven by Settings panel onAppear and by the
    /// EKEventStoreChangedNotification handler.
    func refreshAvailableEventKitCalendars() {
        appState.availableEventKitCalendars = calendarMonitor.availableCalendars()
    }

    /// Refresh the Google calendar list via the Calendar API. No-op when OAuth
    /// is not available or the user is not authenticated.
    func refreshGoogleCalendarList() async {
        guard googleCalAuth.isAuthenticated else {
            appState.availableGoogleCalendars = []
            appState.googleCalendarListLoadState = .idle
            return
        }
        appState.googleCalendarListLoadState = .loading
        do {
            let list = try await googleCalClient.fetchCalendarList()
            appState.availableGoogleCalendars = list
            appState.googleCalendarListLoadState = .loaded
        } catch GoogleCalendarAuthError.notAuthenticated {
            invalidateGoogleCalendarAuth()
            fputs("[muesli-native] Google Calendar token invalid while loading calendar list, signed out\n", stderr)
        } catch GoogleCalendarAuthError.refreshFailed(let message) {
            fputs("[muesli-native] Google Calendar token refresh failed while loading calendar list: \(message)\n", stderr)
            appState.googleCalendarListLoadState = .failed("Token refresh failed: \(message)")
        } catch {
            fputs("[muesli-native] Google calendarList fetch failed: \(error)\n", stderr)
            appState.googleCalendarListLoadState = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func refreshUpcomingCalendarEvents() async -> Bool {
        let refreshNow = Date()
        let refreshStartOfDay = Calendar.current.startOfDay(for: refreshNow)
        let disabledIDs = Set(config.disabledCalendarIDs)
        let dayCount = UpcomingMeetingsWindow.resolve(dayCount: config.upcomingMeetingsDayCount).dayCount
        var ekEvents = calendarMonitor.upcomingEvents(
            daysAhead: dayCount,
            disabledCalendarIDs: disabledIDs,
            now: refreshNow
        )
        var observedEventIDs = Set(ekEvents.map(\.id))
        var canConfirmMissingGoogleEvents = false

        if googleCalAuth.isAuthenticated {
            do {
                let googleResult = try await googleCalClient.fetchUpcomingEvents(
                    daysAhead: dayCount,
                    disabledCalendarIDs: disabledIDs,
                    now: refreshNow
                )
                canConfirmMissingGoogleEvents = googleResult.wasComplete
                observedEventIDs.formUnion(googleResult.events.map(\.id))
                ekEvents = GoogleCalendarClient.mergeEvents(eventKit: ekEvents, google: googleResult.events)
            } catch GoogleCalendarAuthError.notAuthenticated {
                invalidateGoogleCalendarAuth()
                fputs("[muesli-native] Google Calendar token invalid, signed out\n", stderr)
            } catch GoogleCalendarAuthError.refreshFailed(let message) {
                fputs("[muesli-native] Google Calendar token refresh failed: \(message)\n", stderr)
            } catch GoogleCalendarClientError.staleRequest {
                return false
            } catch {
                fputs("[muesli-native] Google Calendar fetch failed: \(error)\n", stderr)
            }
        }

        let currentDisabledIDs = Set(config.disabledCalendarIDs)
        let currentDayCount = UpcomingMeetingsWindow.resolve(dayCount: config.upcomingMeetingsDayCount).dayCount
        let currentStartOfDay = Calendar.current.startOfDay(for: Date())
        guard dayCount == currentDayCount,
              disabledIDs == currentDisabledIDs,
              refreshStartOfDay == currentStartOfDay else {
            return false
        }

        appState.upcomingCalendarEvents = ekEvents

        // Prune hidden IDs only when the widest supported window still cannot see the event.
        observedEventIDs.formUnion(ekEvents.map(\.id))
        let sourceHints = config.hiddenCalendarEventSourceHints
        let canConfirmMissingEventKitEvents = calendarMonitor.canConfirmMissingEvents
        let canPruneHiddenEvents = disabledIDs.isEmpty
        let staleIDs = UpcomingMeetingsWindow.staleHiddenEventIDs(
            hiddenIDs: appState.hiddenCalendarEventIDs,
            visibleEventIDs: observedEventIDs,
            dayCount: dayCount,
            canConfirmMissingEvents: canPruneHiddenEvents,
            canConfirmMissingEventID: { eventID in
                guard canPruneHiddenEvents else { return false }
                switch sourceHints[eventID].flatMap(UnifiedCalendarEvent.CalendarSource.init(rawValue:)) {
                case .some(.eventKit):
                    return canConfirmMissingEventKitEvents
                case .some(.googleCalendar):
                    return canConfirmMissingGoogleEvents
                case .none:
                    return false
                }
            }
        )
        if !staleIDs.isEmpty {
            appState.hiddenCalendarEventIDs.subtract(staleIDs)
            updateConfig {
                $0.hiddenCalendarEventIDs = self.appState.hiddenCalendarEventIDs.sorted()
                $0.hiddenCalendarEventSourceHints = $0.hiddenCalendarEventSourceHints.filter {
                    !staleIDs.contains($0.key)
                }
            }
        }

        statusBarController?.updateMenuBarTitle()
        return true
    }

    /// Reconciles only EventKit-backed meetings that have not started. This is
    /// called from EKEventStoreChangedNotification, never from the Google
    /// Calendar fallback timer, so participant freshness remains event-driven.
    func reconcilePendingEventKitCalendarAttendees(
        events: [UnifiedCalendarEvent],
        now: Date = Date()
    ) async {
        let snapshots = events.compactMap { event -> CalendarParticipantReconciliationSnapshot? in
            guard event.source == .eventKit, event.startDate > now else { return nil }
            return CalendarParticipantReconciliationSnapshot(
                occurrence: event.resolvedCalendarOccurrence,
                startDate: event.startDate,
                participants: event.attendees.map(\.participantDraft)
            )
        }
        guard !snapshots.isEmpty else { return }

        let databaseURL = dictationStore.resolvedDatabaseURL
        let matches = await Task.detached(priority: .utility) {
            let store = DictationStore(databaseURL: databaseURL)
            return snapshots.compactMap { snapshot -> (Int64, [MeetingParticipantDraft])? in
                guard snapshot.startDate > now,
                      let meeting = try? store.meetingByCalendarOccurrence(snapshot.occurrence),
                      meeting.status != .recording,
                      meeting.status != .processing else {
                    return nil
                }
                return (meeting.id, snapshot.participants)
            }
        }.value

        let activeMeetingIDs = Set([activeMeetingID, meetingStartMeetingID].compactMap { $0 })
        for (meetingID, participants) in matches where !activeMeetingIDs.contains(meetingID) {
            persistCalendarParticipants(participants, meetingID: meetingID, mode: .reconcile)
        }
    }

    func startCalendarMonitoring() {
        // Event-driven: refresh when macOS reports calendar changes.
        // EKEventStoreChangedNotification is delivered via NotificationCenter,
        // which is immune to App Nap timer suspension in LSUIElement apps.
        calendarMonitor.onCalendarChanged = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.refreshAvailableEventKitCalendars()
                let refreshed = await self.refreshUpcomingCalendarEvents()
                guard refreshed else { return }
                await self.reconcilePendingEventKitCalendarAttendees(
                    events: self.appState.upcomingCalendarEvents
                )
                self.checkUpcomingCalendarNotifications()
                self.meetingMonitor.refreshState(trigger: .calendarChanged)
            }
        }

        // 60s fallback timer: polls Google Calendar API (sync token makes this
        // efficient) and checks the notification window for time-based triggers.
        // EKEventStoreChangedNotification handles EventKit reactively, but Google
        // Calendar OAuth has no push mechanism — this timer is the only way to
        // pick up new/moved events from the API. May be suspended by App Nap on
        // macOS 26, but combined with the EventKit push path, most cases are covered.
        calendarCheckTimer?.invalidate()
        calendarCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.calendarMonitor.start()
                self.refreshAvailableEventKitCalendars()
                let refreshed = await self.refreshUpcomingCalendarEvents()
                guard refreshed else { return }
                self.checkUpcomingCalendarNotifications()
                self.meetingMonitor.refreshState(trigger: .calendarChanged)
            }
        }

        // Run one initial reconciliation so changes made while Muesli was not
        // running are reflected without waiting for another EventKit change.
        Task { @MainActor in
            self.refreshAvailableEventKitCalendars()
            let refreshed = await self.refreshUpcomingCalendarEvents()
            guard refreshed else { return }
            await self.reconcilePendingEventKitCalendarAttendees(
                events: self.appState.upcomingCalendarEvents
            )
            self.checkUpcomingCalendarNotifications()
            self.meetingMonitor.refreshState(trigger: .calendarChanged)
        }
    }

    private func syncCalendarMonitor() {
        let shouldRun = meetingFeatureMonitorsAllowed && shouldRunCalendarMonitor
        if shouldRun && !calendarMonitoringStarted {
            calendarMonitor.start()
            startCalendarMonitoring()
            calendarMonitoringStarted = true
        } else if !shouldRun && calendarMonitoringStarted {
            calendarMonitor.stop()
            calendarCheckTimer?.invalidate()
            calendarCheckTimer = nil
            calendarMonitoringStarted = false
        }
    }

    private func currentOrNearbyCachedCalendarEvent() -> CalendarEventContext? {
        selectCurrentOrNearbyCachedCalendarEvent(from: appState.upcomingCalendarEvents)
    }

    private func startMeetingFeatureMonitors(includeMaraudersMap: Bool) {
        if includeMaraudersMap, config.maraudersMapUnlocked {
            startMaraudersMapMonitoring()
        }
        syncMeetingDetectionMonitor()
    }

    private var shouldRunMeetingFeatureMonitors: Bool {
        config.showMeetingDetectionNotification
            || config.showScheduledMeetingNotifications
            || config.autoRecordMeetings
    }

    private var shouldRunCalendarMonitor: Bool {
        config.resolvedOnboardingUseCase.includesMeetings || shouldRunMeetingFeatureMonitors
    }

    private var shouldDetectMeetingActivity: Bool {
        MeetingActivityDetectionPolicy.shouldRun(
            showDetectionNotification: config.showMeetingDetectionNotification,
            isAutoStopArmed: activeMeetingAutoStop.isArmed,
            isStartingRecording: isStartingMeetingRecording,
            isRecording: isMeetingRecording()
        )
    }

    /// The idle dot needs Accessibility and a completed onboarding; it never runs inside
    /// onboarding where the focused field belongs to Muesli's own flow, and it stays away
    /// while a meeting recording is starting or running.
    private func syncDictationIdleDot() {
        let idleAllowed = dictationIdleDotAllowed
            && config.resolvedOnboardingUseCase.includesPushToTalk
            && config.showDictationIdleDot
            && !isMeetingRecording()
            && !isStartingMeetingRecording
        dictationMiniIndicator.isIdleDotAllowed = idleAllowed
        if idleAllowed {
            dictationTextContextMonitor.start()
        } else {
            // Nothing consumes samples while the dot is disallowed; stop polling to stay cheap.
            dictationTextContextMonitor.stop()
        }
    }

    private func syncMeetingDetectionMonitor() {
        let shouldRun = meetingFeatureMonitorsAllowed && shouldDetectMeetingActivity
        if shouldRun && !meetingDetectionMonitorStarted {
            meetingDetectionRunID &+= 1
            meetingMonitor.start()
            meetingDetectionMonitorStarted = true
        } else if !shouldRun && meetingDetectionMonitorStarted {
            stopMeetingDetectionMonitor()
            dismissPresentedMeetingDetection()
        }
        syncMeetingRecordButton()
        syncDictationIdleDot()
    }

    /// Stops detection and drops the cached candidate synchronously. The detector stops
    /// asynchronously and never emits a nil candidate on stop, so without this a restart
    /// would surface (and record) the previous run's meeting.
    private func stopMeetingDetectionMonitor() {
        meetingMonitor.stop()
        meetingDetectionMonitorStarted = false
        latestMeetingActivityCandidate = nil
        latestMeetingActivityCandidateObservedAt = nil
        latestMeetingActivityCandidateRunID = nil
        observedMeetingActivityCandidate = nil
        observedMeetingActivityCandidateObservedAt = nil
        observedMeetingActivityCandidateRunID = nil
        dismissedMeetingRecordButtonCandidateID = nil
    }

    /// The activity candidate observed by the current detection run; anything cached from an
    /// earlier run must never drive the Record pill.
    private var currentRunMeetingActivityCandidate: MeetingCandidate? {
        guard meetingDetectionMonitorStarted,
              latestMeetingActivityCandidateRunID == meetingDetectionRunID else { return nil }
        return latestMeetingActivityCandidate
    }

    private func syncMeetingRecordButton() {
        let candidate = currentRunMeetingActivityCandidate
        let hasCandidate = candidate.map { !isMutedMeetingDetectionCandidate($0) } ?? false
        let presentation = MeetingRecordButtonPolicy.presentation(
            enabled: config.showMeetingRecordButton,
            monitorsAllowed: meetingFeatureMonitorsAllowed,
            hasActivityCandidate: hasCandidate,
            candidateDismissed: candidate?.id == dismissedMeetingRecordButtonCandidateID,
            isRecording: isMeetingRecording(),
            isStartingRecording: isStartingMeetingRecording,
            startOriginatedFromPill: meetingStartOriginatedFromRecordButton,
            isRecordingPanelVisible: meetingRecordingPanel.isVisible
        )
        if presentation != .hidden {
            meetingRecordButton.applySavedCenter(
                config.meetingRecordingPanelCenter.map { CGPoint(x: $0.x, y: $0.y) }
            )
        }
        meetingRecordButton.apply(presentation, platformName: candidate?.platform.displayName)
    }

    /// The recording object owns the shared spot while it is on screen, so the Record pill has to
    /// re-evaluate the moment the object goes away rather than waiting for the next detection tick.
    private func closeMeetingRecordingPanel(ownerID: UUID) {
        meetingRecordingPanel.close(ownerID: ownerID)
        syncMeetingRecordButton()
    }

    private func recordFromMeetingRecordButton() {
        guard !isMeetingRecording(), !isStartingMeetingRecording else { return }
        let candidate = currentRunMeetingActivityCandidate
        let title = candidate?.subtitle ?? "Meeting"
        // Set before the start so every sync it triggers already knows the pill is holding the spot.
        meetingStartOriginatedFromRecordButton = true
        let didStart = startMeetingRecordingFromEntryPoint(
            title: title,
            autoStopSource: candidate.map { MeetingAutoStopSource(candidate: $0) },
            presentation: .compactControl,
            startOrigin: .detectedPrompt
        )
        if didStart, let candidate {
            meetingMonitor.markRecordingStarted(candidate)
            presentedMeetingCandidate = nil
            dismissPresentedMeetingDetection()
        } else if !didStart {
            // A start refused outright never entered the starting state, so nothing else clears it.
            meetingStartOriginatedFromRecordButton = false
        }
        syncMeetingRecordButton()
    }

    /// Check all upcoming calendar events (EventKit + Google) for events entering the configured prompt window.
    /// With a pre-start lead time, shows a notification when the event enters that window and schedules a second
    /// "Meeting starting now" notification at event start time. With the default start-time policy, waits until
    /// the event has started so calendar prompts do not fire before the user is expected to join.
    /// This is the single notification path for all calendar sources.
    /// Composite dedup key: same event rescheduled to a new time gets a fresh notification.
    private func notificationKey(id: String, startDate: Date) -> String {
        "\(id)|\(Int(startDate.timeIntervalSince1970))"
    }

    private func checkUpcomingCalendarNotifications() {
        guard !isMeetingRecording(),
              !isStartingMeetingRecording else { return }

        let now = Date()
        let leadTime = config.scheduledMeetingNotificationLeadTime.seconds

        // Prune stale entries (events that started more than 1 hour ago)
        let cutoff = now.addingTimeInterval(-3600)
        notifiedUpcomingEventIDs = notifiedUpcomingEventIDs.filter { key in
            guard let tsString = key.split(separator: "|").last,
                  let ts = TimeInterval(tsString) else { return false }
            return Date(timeIntervalSince1970: ts) > cutoff
        }
        autoRecordedCalendarEventIDs = autoRecordedCalendarEventIDs.filter { key in
            guard let tsString = key.split(separator: "|").last,
                  let ts = TimeInterval(tsString) else { return false }
            return Date(timeIntervalSince1970: ts) > cutoff
        }

        if config.autoRecordMeetings {
            let autoRecordCandidates = ScheduledMeetingNotificationPolicy.autoRecordCandidates(
                from: appState.upcomingCalendarEvents,
                now: now,
                hiddenEventIDs: appState.hiddenCalendarEventIDs
            )
            for event in autoRecordCandidates {
                let key = notificationKey(id: event.id, startDate: event.startDate)
                guard !autoRecordedCalendarEventIDs.contains(key) else { continue }
                autoRecordedCalendarEventIDs.insert(key)

                startMeetingRecording(
                    title: event.title,
                    calendarOccurrence: event.resolvedCalendarOccurrence,
                    openDocument: false,
                    presentation: .backgroundPill,
                    endDate: event.endDate,
                    autoStopSource: event.meetingURL.flatMap { MeetingAutoStopSource(meetingURL: $0) },
                    startOrigin: .calendarAutoRecord
                )
                return
            }
        }

        guard config.showScheduledMeetingNotifications else { return }

        let notificationCandidates = ScheduledMeetingNotificationPolicy.upcomingCandidates(
            from: appState.upcomingCalendarEvents,
            now: now,
            hiddenEventIDs: appState.hiddenCalendarEventIDs,
            leadTime: leadTime
        )
        for event in notificationCandidates {
            let key = notificationKey(id: event.id, startDate: event.startDate)
            guard !notifiedUpcomingEventIDs.contains(key) else { continue }

            notifiedUpcomingEventIDs.insert(key)

            let upcomingEvent = UpcomingMeetingEvent(
                id: event.id,
                title: event.title,
                startDate: event.startDate,
                calendarOccurrence: event.resolvedCalendarOccurrence,
                meetingURL: event.meetingURL
            )

            // Show "starts in X min" notification now
            handleUpcomingMeeting(upcomingEvent)

            // Schedule a second "Meeting starting now" notification at event start time for pre-start prompts.
            let delay = event.startDate.timeIntervalSinceNow
            if leadTime > 0, delay > 15 { // Only if there's enough gap after the first notification auto-dismisses
                let eventID = event.id
                let startDate = event.startDate
                meetingStartingNowTimers[key]?.invalidate()
                meetingStartingNowTimers[key] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.meetingStartingNowTimers.removeValue(forKey: key)
                        guard !self.isMeetingRecording(),
                              let event = ScheduledMeetingNotificationPolicy.startingNowCandidate(
                                from: self.appState.upcomingCalendarEvents,
                                eventID: eventID,
                                startDate: startDate,
                                hiddenEventIDs: self.appState.hiddenCalendarEventIDs
                              ) else { return }
                        self.showMeetingStartingNowNotification(
                            title: event.title,
                            calendarOccurrence: event.resolvedCalendarOccurrence,
                            meetingURL: event.meetingURL,
                            endDate: event.endDate
                        )
                    }
                }
            }

            return // Show one notification at a time
        }
    }

    /// Show a "Meeting starting now" notification — independent of Marauder's Map.
    private func showMeetingStartingNowNotification(
        title: String,
        calendarOccurrence: CalendarOccurrenceReference?,
        meetingURL: URL?,
        endDate: Date?
    ) {
        guard ScheduledMeetingNotificationPolicy.shouldShowStartingNowPrompt(meetingURL: meetingURL),
              config.showScheduledMeetingNotifications,
              !isMeetingRecording(),
              !isStartingMeetingRecording else { return }
        isShowingCalendarNotification = true

        meetingNotification.show(
            title: "Meeting starting now",
            subtitle: title,
            meetingURL: meetingURL,
            dismissAfter: 30,
            defaultAction: config.meetingJoinDefaultAction,
            onStartRecording: { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.recordOnly(
                    title: title,
                    meetingURL: meetingURL,
                    endDate: endDate,
                    calendarOccurrence: calendarOccurrence,
                    presentation: .backgroundPill
                )
            },
            onJoinAndRecord: meetingURL != nil ? { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.joinAndRecord(
                    title: title,
                    meetingURL: meetingURL!,
                    endDate: endDate,
                    calendarOccurrence: calendarOccurrence,
                    presentation: .backgroundPill
                )
            } : nil,
            onJoinOnly: meetingURL != nil ? { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.joinOnly(meetingURL: meetingURL!, endDate: endDate)
            } : nil,
            onDismiss: { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                let remaining = endDate.map { max($0.timeIntervalSinceNow, 120) } ?? 120
                self.meetingMonitor.suppress(for: remaining)
                self.meetingMonitor.refreshState()
            },
            onClose: { [weak self] in
                self?.isShowingCalendarNotification = false
                self?.showPendingMeetingCompletionNotificationIfPossible()
            }
        )
    }

    func addCustomWord(_ word: CustomWord) {
        updateConfig { $0.customWords.append(word) }
        refreshPostProcessorPromptAfterDictionaryChange()
    }

    func replaceCustomWords(_ words: [CustomWord]) {
        updateConfig { $0.customWords = words }
        refreshPostProcessorPromptAfterDictionaryChange()
    }

    func addDictionarySuggestion(_ suggestion: DictionarySuggestion) {
        guard config.enableDictionaryCorrectionPrompts else {
            logDictionarySuggestion("skip reason=disabled \(dictionarySuggestionLogMetadata(suggestion))")
            return
        }
        let trimmedObserved = suggestion.observed.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReplacement = suggestion.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedObserved.isEmpty, !trimmedReplacement.isEmpty else {
            logDictionarySuggestion("skip reason=empty")
            return
        }
        guard trimmedObserved != trimmedReplacement else {
            logDictionarySuggestion("skip reason=sameText")
            return
        }

        let key = DictionarySuggestion.key(observed: trimmedObserved, replacement: trimmedReplacement)
        let metadata = dictionarySuggestionLogMetadata(observed: trimmedObserved, replacement: trimmedReplacement)
        guard !config.dismissedDictionarySuggestionKeys.contains(key) else {
            logDictionarySuggestion("skip reason=dismissed \(metadata)")
            return
        }
        guard !config.customWords.contains(where: {
            DictionarySuggestion.key(observed: $0.word, replacement: $0.targetWord) == key
        }) else {
            logDictionarySuggestion("skip reason=customWordExists \(metadata)")
            return
        }

        var promptSuggestion = suggestion
        var persistenceAction = "insert"
        updateConfig { config in
            if let index = config.dictionarySuggestions.firstIndex(where: { $0.key == key }) {
                var existing = config.dictionarySuggestions[index]
                existing.occurrenceCount += 1
                existing.lastSeenAt = DictionarySuggestion.timestamp()
                if existing.appContext.isEmpty {
                    existing.appContext = suggestion.appContext
                }
                config.dictionarySuggestions.remove(at: index)
                config.dictionarySuggestions.insert(existing, at: 0)
                promptSuggestion = existing
                persistenceAction = "update"
            } else {
                promptSuggestion = DictionarySuggestion(
                    observed: trimmedObserved,
                    replacement: trimmedReplacement,
                    appContext: suggestion.appContext
                )
                config.dictionarySuggestions.insert(promptSuggestion, at: 0)
            }
            if config.dictionarySuggestions.count > Self.maxDictionarySuggestions {
                config.dictionarySuggestions = Array(config.dictionarySuggestions.prefix(Self.maxDictionarySuggestions))
            }
        }

        logDictionarySuggestion("persist action=\(persistenceAction) \(metadata)")
        enqueueDictionarySuggestionPrompt(promptSuggestion)
    }

    func acceptDictionarySuggestion(id: UUID) {
        guard let suggestion = config.dictionarySuggestions.first(where: { $0.id == id }) else { return }
        acceptDictionarySuggestion(suggestion)
    }

    func dismissDictionarySuggestion(id: UUID) {
        guard let suggestion = config.dictionarySuggestions.first(where: { $0.id == id }) else { return }
        dismissDictionarySuggestion(suggestion)
    }

    private func acceptDictionarySuggestion(_ suggestion: DictionarySuggestion) {
        let key = suggestion.key
        updateConfig { config in
            if !config.customWords.contains(where: {
                DictionarySuggestion.key(observed: $0.word, replacement: $0.targetWord) == key
            }) {
                config.customWords.append(suggestion.customWord)
            }
            config.dictionarySuggestions.removeAll { $0.key == key }
            config.dismissedDictionarySuggestionKeys.removeAll { $0 == key }
        }
        refreshPostProcessorPromptAfterDictionaryChange()
        logDictionarySuggestion("accept \(dictionarySuggestionLogMetadata(suggestion))")
    }

    private func dismissDictionarySuggestion(_ suggestion: DictionarySuggestion) {
        let key = suggestion.key
        updateConfig { config in
            config.dictionarySuggestions.removeAll { $0.key == key }
            if !config.dismissedDictionarySuggestionKeys.contains(key) {
                config.dismissedDictionarySuggestionKeys.append(key)
            }
            if config.dismissedDictionarySuggestionKeys.count > Self.maxDismissedDictionarySuggestionKeys {
                config.dismissedDictionarySuggestionKeys = Array(config.dismissedDictionarySuggestionKeys.suffix(Self.maxDismissedDictionarySuggestionKeys))
            }
        }
        logDictionarySuggestion("ignore \(dictionarySuggestionLogMetadata(suggestion))")
    }

    private func presentDictionarySuggestionPrompt(_ suggestion: DictionarySuggestion) {
        let key = suggestion.key
        activeDictionarySuggestionPromptKey = key
        logDictionarySuggestion("present \(dictionarySuggestionLogMetadata(suggestion))")
        dictionarySuggestionPrompt.show(
            suggestion: suggestion,
            anchorFrame: nil,
            onAdd: { [weak self] in
                guard let self else { return }
                self.acceptDictionarySuggestion(suggestion)
                self.completeDictionarySuggestionPrompt(key: key, action: "add")
            },
            onIgnore: { [weak self] in
                guard let self else { return }
                self.dismissDictionarySuggestion(suggestion)
                self.completeDictionarySuggestionPrompt(key: key, action: "ignore")
            },
            onDismiss: { [weak self] in
                self?.completeDictionarySuggestionPrompt(key: key, action: "dismiss")
            }
        )
    }

    private func enqueueDictionarySuggestionPrompt(_ suggestion: DictionarySuggestion) {
        let key = suggestion.key
        guard config.enableDictionaryCorrectionPrompts else { return }
        guard activeDictionarySuggestionPromptKey != key else { return }
        guard !queuedDictionarySuggestionPromptKeys.contains(key) else { return }
        // Showing or timing out a prompt is not a final answer. Only Add or
        // Ignore suppresses future prompts for this correction pair.
        queuedDictionarySuggestionPromptKeys.append(key)
        if queuedDictionarySuggestionPromptKeys.count > Self.maxDictionarySuggestionPromptQueue {
            queuedDictionarySuggestionPromptKeys.removeFirst(queuedDictionarySuggestionPromptKeys.count - Self.maxDictionarySuggestionPromptQueue)
        }
        logDictionarySuggestion("queue depth=\(queuedDictionarySuggestionPromptKeys.count) \(dictionarySuggestionLogMetadata(suggestion))")
        presentNextDictionarySuggestionPromptIfPossible()
    }

    private func completeDictionarySuggestionPrompt(key: String, action: String) {
        guard activeDictionarySuggestionPromptKey == key else { return }
        activeDictionarySuggestionPromptKey = nil
        logDictionarySuggestion("complete action=\(action) queued=\(queuedDictionarySuggestionPromptKeys.count)")
        scheduleNextDictionarySuggestionPrompt()
    }

    private func scheduleNextDictionarySuggestionPrompt() {
        dictionarySuggestionPromptAdvanceTask?.cancel()
        dictionarySuggestionPromptAdvanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.dictionarySuggestionPromptAdvanceTask = nil
            self?.presentNextDictionarySuggestionPromptIfPossible()
        }
    }

    private func presentNextDictionarySuggestionPromptIfPossible() {
        guard config.enableDictionaryCorrectionPrompts else { return }
        guard activeDictionarySuggestionPromptKey == nil else { return }
        // While the advance task is sleeping, it owns the next drain attempt.
        // Newly queued suggestions remain in queuedDictionarySuggestionPromptKeys.
        guard dictionarySuggestionPromptAdvanceTask == nil else { return }
        guard !dictionarySuggestionPrompt.isShowing else {
            scheduleNextDictionarySuggestionPrompt()
            return
        }

        while !queuedDictionarySuggestionPromptKeys.isEmpty {
            let key = queuedDictionarySuggestionPromptKeys.removeFirst()
            guard !config.dismissedDictionarySuggestionKeys.contains(key) else { continue }
            guard let suggestion = config.dictionarySuggestions.first(where: { $0.key == key }) else { continue }
            let hasCustomWord = config.customWords.contains {
                DictionarySuggestion.key(observed: $0.word, replacement: $0.targetWord) == key
            }
            guard !hasCustomWord else { continue }
            presentDictionarySuggestionPrompt(suggestion)
            return
        }
    }

    private func dictionarySuggestionLogMetadata(_ suggestion: DictionarySuggestion) -> String {
        dictionarySuggestionLogMetadata(observed: suggestion.observed, replacement: suggestion.replacement)
    }

    private func dictionarySuggestionLogMetadata(observed: String, replacement: String) -> String {
        "observedChars=\(observed.count) replacementChars=\(replacement.count)"
    }

    private func logDictionarySuggestion(_ message: String) {
        Self.dictionarySuggestionLogger.debug("\(message, privacy: .public)")
        fputs("[dictionary-suggestion] \(message)\n", stderr)
    }

    func updateCustomWord(_ word: CustomWord) {
        updateConfig { config in
            guard let index = config.customWords.firstIndex(where: { $0.id == word.id }) else { return }
            config.customWords[index] = word
        }
        refreshPostProcessorPromptAfterDictionaryChange()
    }

    func removeCustomWord(id: UUID) {
        updateConfig { $0.customWords.removeAll { $0.id == id } }
        refreshPostProcessorPromptAfterDictionaryChange()
    }

    /// Persists the user's standing preferences and re-arms the preloaded cleanup
    /// runtime the way a dictionary edit does, so the next dictation sees them.
    func setCustomInstructions(_ text: String) {
        let normalized = CustomInstructions.normalized(text)
        guard normalized != config.customInstructions else { return }
        updateConfig { $0.customInstructions = normalized }
        refreshPostProcessorPromptAfterDictionaryChange()
    }

    /// The dictionary rides inside the cleanup prompt as restoration vocabulary, so
    /// editing it must reconfigure the post-processor the same way a preset change does.
    private func refreshPostProcessorPromptAfterDictionaryChange() {
        Task { await configureTranscriptCleanupForRuntime() }
    }

    @discardableResult
    func setDictionaryCorrectionPromptsFromToggle(_ enabled: Bool) -> DictionaryCorrectionPromptsToggleResult {
        guard enabled else {
            setDictionaryCorrectionPromptsEnabled(false)
            return .updated
        }
        guard AXIsProcessTrusted() else {
            return .needsAccessibilityPermission
        }
        setDictionaryCorrectionPromptsEnabled(true)
        return .updated
    }

    func setDictionaryCorrectionPromptsEnabled(_ enabled: Bool) {
        if !enabled {
            clearPendingDictionaryCorrectionAccessibilityEnable()
            dictationCorrectionMonitor.cancel()
            updateConfig { $0.enableDictionaryCorrectionPrompts = false }
            return
        }
        guard AXIsProcessTrusted() else {
            dictationCorrectionMonitor.cancel()
            updateConfig { $0.enableDictionaryCorrectionPrompts = false }
            return
        }
        updateConfig { $0.enableDictionaryCorrectionPrompts = true }
    }

    @discardableResult
    func requestDictionaryCorrectionAccessibilityEnable() -> Bool {
        guard !AXIsProcessTrusted() else {
            clearPendingDictionaryCorrectionAccessibilityEnable()
            setDictionaryCorrectionPromptsEnabled(true)
            return true
        }
        markPendingDictionaryCorrectionAccessibilityEnable()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        return false
    }

    func cancelDictionaryCorrectionAccessibilityEnableRequest() {
        clearPendingDictionaryCorrectionAccessibilityEnable()
    }

    @discardableResult
    func reconcilePendingDictionaryCorrectionAccessibilityEnable(now: Date = Date()) -> Bool {
        guard isPendingDictionaryCorrectionAccessibilityEnable else { return false }
        guard !isPendingDictionaryCorrectionAccessibilityEnableExpired(now: now) else {
            clearPendingDictionaryCorrectionAccessibilityEnable()
            return false
        }
        guard let isPendingFromPreviousProcess = isPendingDictionaryCorrectionAccessibilityEnableFromPreviousProcess else {
            clearPendingDictionaryCorrectionAccessibilityEnable()
            return false
        }
        guard isPendingFromPreviousProcess else { return false }
        guard AXIsProcessTrusted() else { return false }
        clearPendingDictionaryCorrectionAccessibilityEnable()
        setDictionaryCorrectionPromptsEnabled(true)
        return true
    }

    private var isPendingDictionaryCorrectionAccessibilityEnable: Bool {
        UserDefaults.standard.bool(forKey: Self.pendingDictionaryCorrectionAccessibilityEnableKey)
    }

    private func markPendingDictionaryCorrectionAccessibilityEnable(now: Date = Date()) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Self.pendingDictionaryCorrectionAccessibilityEnableKey)
        defaults.set(now.timeIntervalSince1970, forKey: Self.pendingDictionaryCorrectionAccessibilityRequestedAtKey)
        defaults.set(
            Int(ProcessInfo.processInfo.processIdentifier),
            forKey: Self.pendingDictionaryCorrectionAccessibilityRequestProcessIDKey
        )
    }

    private func clearPendingDictionaryCorrectionAccessibilityEnable() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.pendingDictionaryCorrectionAccessibilityEnableKey)
        defaults.removeObject(forKey: Self.pendingDictionaryCorrectionAccessibilityRequestedAtKey)
        defaults.removeObject(forKey: Self.pendingDictionaryCorrectionAccessibilityRequestProcessIDKey)
    }

    private func isPendingDictionaryCorrectionAccessibilityEnableExpired(now: Date) -> Bool {
        let requestedAt = UserDefaults.standard.double(forKey: Self.pendingDictionaryCorrectionAccessibilityRequestedAtKey)
        guard requestedAt > 0 else { return true }
        return now.timeIntervalSince1970 - requestedAt > Self.dictionaryCorrectionAccessibilityIntentTimeout
    }

    private var isPendingDictionaryCorrectionAccessibilityEnableFromPreviousProcess: Bool? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.pendingDictionaryCorrectionAccessibilityRequestProcessIDKey) != nil else {
            return nil
        }
        return defaults.integer(forKey: Self.pendingDictionaryCorrectionAccessibilityRequestProcessIDKey)
            != Int(ProcessInfo.processInfo.processIdentifier)
    }

    @discardableResult
    func requestScreenContextEnable() -> Bool {
        guard AXIsProcessTrusted() else {
            updateConfig { $0.enableScreenContext = false }
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            return false
        }

        updateConfig { $0.enableScreenContext = true }
        return true
    }

    @discardableResult
    func updateDictationHotkey(_ hotkey: HotkeyConfig) -> ShortcutHotkeyUpdateResult {
        if config.enableQuilMode, ShortcutHotkeyPolicy.hotkeysConflict(hotkey, config.quilHotkey) {
            return .conflict(message: ShortcutHotkeyPolicy.conflictMessage)
        }
        let result = ShortcutHotkeyPolicy.validateDictationHotkey(
            hotkey,
            computerUseHotkey: config.computerUseHotkey,
            isComputerUseEnabled: config.enableComputerUseHotkey,
            meetingRecordingHotkey: config.meetingRecordingHotkey,
            isMeetingRecordingEnabled: config.enableMeetingRecordingHotkey
        )
        guard result.didUpdate else {
            fputs("[hotkeys] rejected dictation hotkey because it matches computer use hotkey\n", stderr)
            return result
        }
        updateConfig { $0.dictationHotkey = hotkey }
        hotkeyMonitor.configure(hotkey)
        configureComputerUseHotkeyMonitor()
        return result
    }

    @discardableResult
    func updateComputerUseHotkey(_ hotkey: HotkeyConfig) -> ShortcutHotkeyUpdateResult {
        if config.enableQuilMode, ShortcutHotkeyPolicy.hotkeysConflict(hotkey, config.quilHotkey) {
            return .conflict(message: ShortcutHotkeyPolicy.conflictMessage)
        }
        let result = ShortcutHotkeyPolicy.validateComputerUseHotkey(
            hotkey,
            dictationHotkey: config.dictationHotkey,
            isComputerUseEnabled: config.enableComputerUseHotkey,
            meetingRecordingHotkey: config.meetingRecordingHotkey,
            isMeetingRecordingEnabled: config.enableMeetingRecordingHotkey
        )
        guard result.didUpdate else {
            fputs("[hotkeys] rejected computer use hotkey because it matches dictation hotkey\n", stderr)
            return result
        }
        updateConfig { $0.computerUseHotkey = hotkey }
        configureComputerUseHotkeyMonitor()
        return result
    }

    @discardableResult
    func updateComputerUseHotkeyEnabled(_ enabled: Bool) -> ShortcutHotkeyUpdateResult {
        if enabled {
            if config.enableQuilMode,
               ShortcutHotkeyPolicy.hotkeysConflict(config.computerUseHotkey, config.quilHotkey) {
                return .conflict(message: ShortcutHotkeyPolicy.conflictMessage)
            }
            let resolution = ShortcutHotkeyPolicy.resolvedComputerUseHotkeyWhenEnabling(
                currentHotkey: config.computerUseHotkey,
                dictationHotkey: config.dictationHotkey,
                meetingRecordingHotkey: config.meetingRecordingHotkey,
                isMeetingRecordingEnabled: config.enableMeetingRecordingHotkey
            )
            guard resolution.result.didUpdate else {
                fputs("[hotkeys] rejected computer use enable because fallback conflicts with another shortcut\n", stderr)
                configureComputerUseHotkeyMonitor()
                return resolution.result
            }
            updateConfig { config in
                config.computerUseHotkey = resolution.hotkey
                config.enableComputerUseHotkey = true
            }
            configureComputerUseHotkeyMonitor()
            return resolution.result
        }
        updateConfig { $0.enableComputerUseHotkey = enabled }
        configureComputerUseHotkeyMonitor()
        return .updated
    }

    @discardableResult
    func updateMeetingRecordingHotkey(_ hotkey: HotkeyConfig) -> ShortcutHotkeyUpdateResult {
        if config.enableQuilMode, ShortcutHotkeyPolicy.hotkeysConflict(hotkey, config.quilHotkey) {
            return .conflict(message: ShortcutHotkeyPolicy.conflictMessage)
        }
        let result = ShortcutHotkeyPolicy.validateMeetingRecordingHotkey(
            hotkey,
            dictationHotkey: config.dictationHotkey,
            computerUseHotkey: config.computerUseHotkey,
            isComputerUseEnabled: config.enableComputerUseHotkey
        )
        guard result.didUpdate else {
            fputs("[hotkeys] rejected meeting recording hotkey due to conflict\n", stderr)
            return result
        }
        updateConfig { $0.meetingRecordingHotkey = hotkey }
        meetingRecordingHotkeyMonitor.configure(hotkey)
        return result
    }

    @discardableResult
    func updateMeetingRecordingHotkeyEnabled(_ enabled: Bool) -> ShortcutHotkeyUpdateResult {
        if enabled {
            if config.enableQuilMode,
               ShortcutHotkeyPolicy.hotkeysConflict(config.meetingRecordingHotkey, config.quilHotkey) {
                return .conflict(message: ShortcutHotkeyPolicy.conflictMessage)
            }
            let result = ShortcutHotkeyPolicy.validateMeetingRecordingHotkey(
                config.meetingRecordingHotkey,
                dictationHotkey: config.dictationHotkey,
                computerUseHotkey: config.computerUseHotkey,
                isComputerUseEnabled: config.enableComputerUseHotkey
            )
            guard result.didUpdate else { return result }
            updateConfig { $0.enableMeetingRecordingHotkey = true }
            startMeetingRecordingHotkeyMonitorIfNeeded()
            return result
        } else {
            updateConfig { $0.enableMeetingRecordingHotkey = false }
            meetingRecordingHotkeyMonitor.stop()
            return .updated
        }
    }

    @discardableResult
    func updateQuilHotkey(_ hotkey: HotkeyConfig) -> ShortcutHotkeyUpdateResult {
        let result = ShortcutHotkeyPolicy.validateQuilHotkey(
            hotkey,
            dictationHotkey: config.dictationHotkey,
            computerUseHotkey: config.computerUseHotkey,
            isComputerUseEnabled: config.enableComputerUseHotkey,
            meetingRecordingHotkey: config.meetingRecordingHotkey,
            isMeetingRecordingEnabled: config.enableMeetingRecordingHotkey
        )
        guard result.didUpdate else { return result }
        updateConfig { $0.quilHotkey = hotkey }
        configureQuilHotkeyMonitor()
        return result
    }

    @discardableResult
    func updateQuilModeEnabled(_ enabled: Bool) -> ShortcutHotkeyUpdateResult {
        if enabled {
            let result = ShortcutHotkeyPolicy.validateQuilHotkey(
                config.quilHotkey,
                dictationHotkey: config.dictationHotkey,
                computerUseHotkey: config.computerUseHotkey,
                isComputerUseEnabled: config.enableComputerUseHotkey,
                meetingRecordingHotkey: config.meetingRecordingHotkey,
                isMeetingRecordingEnabled: config.enableMeetingRecordingHotkey
            )
            guard result.didUpdate else { return result }
        }
        updateConfig { $0.enableQuilMode = enabled }
        configureQuilHotkeyMonitor()
        return .updated
    }

    func resetShortcutDefaults() {
        updateConfig { config in
            config.dictationHotkey = .default
            config.quilHotkey = .quilDefault
            config.enableQuilMode = false
            config.computerUseHotkey = .computerUseDefault
            config.enableComputerUseHotkey = false
            config.meetingRecordingHotkey = .meetingRecordingDefault
            config.enableMeetingRecordingHotkey = false
            config.hotkeyTriggerThresholdMS = HotkeyTriggerTiming.defaultThresholdMilliseconds
            config.quilHotkeyTriggerThresholdMS = HotkeyTriggerTiming.defaultThresholdMilliseconds
            config.computerUseHotkeyTriggerThresholdMS = HotkeyTriggerTiming.defaultThresholdMilliseconds
            config.meetingRecordingHotkeyTriggerThresholdMS = HotkeyTriggerTiming.defaultMeetingThresholdMilliseconds
        }
        hotkeyMonitor.configure(.default)
        quilHotkeyMonitor.stop()
        configureComputerUseHotkeyMonitor()
        meetingRecordingHotkeyMonitor.stop()
    }

    // MARK: - Onboarding

    func showOnboarding(resumeFrom progress: OnboardingProgress? = nil) {
        // The window survives losing its controller (isReleasedWhenClosed is false), so
        // re-entry from a permission failure would stack a second onboarding window.
        onboardingWindowController?.close()
        let wc = OnboardingWindowController(controller: self, resumeProgress: progress)
        self.onboardingWindowController = wc
        wc.show()
    }

    @MainActor
    func bringOnboardingToFront() {
        onboardingWindowController?.bringToFront()
    }

    @MainActor
    func yieldOnboardingFocusToSystemSettings() {
        onboardingWindowController?.yieldFocusToSystemSettings()
    }

    @MainActor
    func prepareOnboardingForNativePermissionPrompt() {
        onboardingWindowController?.prepareForNativePermissionPrompt()
    }

    @MainActor
    func notifyOnboardingModelReady() {
        guard onboardingWindowController != nil else { return }
        SoundController.playModelReady(enabled: config.soundEnabled)
        bringOnboardingToFront()
    }

    func continueModelPreparationAfterOnboarding(
        _ backend: BackendOption,
        onboardingUseCase: OnboardingUseCase,
        initialProgress: Double?,
        initialStatus: String?,
        isPreparing: Bool
    ) {
        onboardingModelPreparationTask?.cancel()
        updateModelPreparationStatus(
            title: "Preparing \(backend.label)",
            detail: initialStatus ?? "Preparing \(backend.label)...",
            progress: initialProgress,
            isPreparing: isPreparing,
            isComplete: false
        )

        onboardingModelPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.downloadModelForOnboarding(
                    backend,
                    onboardingUseCase: onboardingUseCase
                ) { progress, status in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.applyModelPreparationProgress(
                            progress,
                            status: status,
                            backend: backend
                        )
                    }
                }
                await MainActor.run {
                    self.onboardingModelPreparationTask = nil
                    self.updateModelPreparationStatus(
                        title: "\(backend.label) ready",
                        detail: "Ready for transcription",
                        progress: 1.0,
                        isPreparing: false,
                        isComplete: true
                    )
                    SoundController.playModelReady(enabled: self.config.soundEnabled)
                    self.statusBarController?.refresh()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.onboardingModelPreparationTask = nil
                }
            } catch {
                await MainActor.run {
                    self.onboardingModelPreparationTask = nil
                    self.updateModelPreparationStatus(
                        title: backend.isDownloaded ? "Model setup paused" : "Download paused",
                        detail: self.modelPreparationFailureMessage(for: backend),
                        progress: nil,
                        isPreparing: false,
                        isComplete: false
                    )
                }
                fputs("[muesli-native] post-onboarding model preparation failed: \(error)\n", stderr)
            }
        }
    }

    func relaunchApp() {
        let bundlePath = Bundle.main.bundleURL.path
        // Defer to next run-loop to escape any SwiftUI animation context
        DispatchQueue.main.async {
            // Launch a detached process that waits for us to die, then reopens the app.
            // Uses /bin/sh only for the sleep; the path is passed as a positional arg
            // to avoid shell interpolation of special characters.
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", "sleep 1; open -- \"$1\"", "--", bundlePath]
            do {
                try shell.run()
            } catch {
                fputs("[muesli-native] relaunch failed: \(error)\n", stderr)
            }
            // Use exit(0) instead of NSApp.terminate(nil) — terminate can be
            // blocked by SwiftUI animation contexts or applicationShouldTerminate,
            // leaving the old process alive with stale floating indicator and
            // status bar icon.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                exit(0)
            }
        }
    }

    // MARK: - Dictation Test Mode (onboarding)

    /// When set, handleStop routes transcribed text to this callback instead of pasting.
    /// The floating indicator and sounds are suppressed during test mode.
    var dictationTestCallback: ((String) -> Void)?
    var dictationTestFailureCallback: ((String) -> Void)?
    var dictationTestRecordingStarted: (() -> Void)?
    var dictationTestBackend: BackendOption?
    var dictationTestCohereLanguage: CohereTranscribeLanguage?
    private var dictationTestJobIDs: Set<UUID> = []

    var isDictationTestMode: Bool { dictationTestCallback != nil }

    func cancelTestDictation() async {
        for jobID in Array(dictationTestJobIDs) {
            await standardDictationJobQueue.cancel(id: jobID)
        }
        dictationTestJobIDs.removeAll()
        let pendingTestStops = pendingStandardDictationStops.values.filter(\.isTestMode)
        for pendingStop in pendingTestStops {
            pendingStandardDictationStops.removeValue(forKey: pendingStop.id)
            dictationSessionTraces.removeValue(forKey: pendingStop.id)
            if let trace = pendingStop.latencyTrace {
                markDictationLatency("pipeline_cancelled", trace: trace)
            }
            Task {
                await pendingStop.sessionTrace.cancel(stage: "dictation_test")
            }
            completeStandardDictationStop(.discarded, sequence: pendingStop.sequence)
        }
        dictationAudioSessionManager.cancel(reason: "test-cancel")
        resetDictationOutputMode()
        clearCapturedDictationSessionContext()
        dictationStartedAt = nil
        finishDictationLatencyTrace("test_cancelled")
        standardDictationWorkChanged()
    }

    func startHotkeyMonitor(keyCode: UInt16? = nil) {
        if let keyCode {
            hotkeyMonitor.configure(keyCode: keyCode)
        }
        hotkeyMonitor.start()
        startComputerUseHotkeyMonitorIfNeeded()
    }

    func stopHotkeyMonitor() {
        hotkeyMonitor.stop()
        computerUseHotkeyMonitor.stop()
        meetingRecordingHotkeyMonitor.stop()
    }

    func downloadModelForOnboarding(
        _ backend: BackendOption,
        onboardingUseCase: OnboardingUseCase,
        progress: @escaping (Double, String?) -> Void,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        let wasDownloaded = backend.isDownloaded
        progress(
            wasDownloaded ? 0.75 : 0.0,
            wasDownloaded ? "Warming up \(backend.label)..." : "Downloading \(backend.label)..."
        )
        try await transcriptionCoordinator.preloadRequired(
            backend: backend,
            enablePostProcessor: isPostProcessorReady,
            includeMeetingHelpers: onboardingUseCase.includesMeetings,
            meetingHelperTrigger: .onboarding,
            appleSpeechLanguage: config.resolvedAppleSpeechLanguage,
            progress: { value, status in
                if wasDownloaded,
                   value < 0.85,
                   status?.localizedCaseInsensitiveContains("preparing") == true {
                    return
                }
                if status?.localizedCaseInsensitiveContains("download") == true {
                    progress(value, "\(status ?? "Downloading \(backend.label)...")")
                } else if value >= 0.9 {
                    progress(value, status ?? "Warming up \(backend.label)...")
                } else {
                    progress(value, status ?? "Preparing \(backend.label)...")
                }
            },
            progressSnapshot: progressSnapshot
        )
        guard backend.isDownloaded else {
            throw NSError(
                domain: "MuesliOnboardingModelDownload",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(backend.label) was not downloaded successfully."]
            )
        }
        progress(1.0, "\(backend.label) ready")
    }

    private func applyModelPreparationProgress(_ progress: Double, status: String?, backend: BackendOption) {
        let detail = status ?? "Preparing \(backend.label)..."
        let lowercasedDetail = detail.lowercased()
        let isPreparing = lowercasedDetail.contains("compiling")
            || lowercasedDetail.contains("warming")
            || lowercasedDetail.contains("readying")

        if isPreparing {
            updateModelPreparationStatus(
                title: "Preparing \(backend.label)",
                detail: "Optimizing \(backend.label) for this Mac...",
                progress: nil,
                isPreparing: true,
                isComplete: false
            )
            return
        }

        updateModelPreparationStatus(
            title: "Preparing \(backend.label)",
            detail: detail,
            progress: progress,
            isPreparing: false,
            isComplete: false
        )
    }

    private func updateModelPreparationStatus(
        title: String,
        detail: String?,
        progress: Double?,
        isPreparing: Bool,
        isComplete: Bool
    ) {
        appState.modelPreparationTitle = title
        appState.modelPreparationDetail = detail
        appState.modelPreparationProgress = progress.map { min(max($0, 0), 1) }
        appState.isModelPreparingAfterDownload = isPreparing
        appState.modelPreparationIsComplete = isComplete
        if isComplete {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard appState.modelPreparationTitle == title,
                      appState.modelPreparationIsComplete else { return }
                appState.modelPreparationTitle = nil
                appState.modelPreparationDetail = nil
                appState.modelPreparationProgress = nil
                appState.isModelPreparingAfterDownload = false
                appState.modelPreparationIsComplete = false
            }
        } else if !isPreparing && progress == nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                guard appState.modelPreparationTitle == title,
                      appState.modelPreparationProgress == nil,
                      !appState.isModelPreparingAfterDownload,
                      !appState.modelPreparationIsComplete else { return }
                appState.modelPreparationTitle = nil
                appState.modelPreparationDetail = nil
            }
        }
    }

    private func modelPreparationFailureMessage(for backend: BackendOption) -> String {
        backend.isDownloaded
            ? "Model setup failed. Restart Muesli or retry from Models."
            : "Download failed. Check your connection and retry."
    }

    func completeOnboarding(
        userName: String,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        hotkey: HotkeyConfig,
        onboardingUseCase: OnboardingUseCase,
        summaryBackend: MeetingSummaryBackendOption?,
        apiKey: String?
    ) {
        updateConfig { config in
            config.hasCompletedOnboarding = true
            config.userName = userName
            config.sttBackend = backend.backend
            config.sttModel = backend.model
            config.applyLegacyLanguageProfile(LanguageProfile.onboarding(
                backend: backend,
                cohereLanguage: cohereLanguage
            ))
            config.mirrorLanguageProfileToLegacyPins()
            config.meetingTranscriptionBackend = backend.backend
            config.meetingTranscriptionModel = backend.model
            config.dictationHotkey = hotkey
            config.computerUseHotkey = HotkeyConfig.computerUseDefault(avoiding: hotkey)
            config.enableComputerUseHotkey = false
            config.enableComputerUsePlanner = true
            config.onboardingUseCase = onboardingUseCase.rawValue
            if let summaryBackend {
                config.meetingSummaryBackend = summaryBackend.backend
            }
            if let apiKey, !apiKey.isEmpty {
                if summaryBackend == .openAI {
                    config.openAIAPIKey = apiKey
                } else if summaryBackend == .openRouter {
                    config.openRouterAPIKey = apiKey
                }
                // ChatGPT backend uses OAuth tokens stored in app support dir, not an API key
            }
        }
        selectBackend(backend)
        hotkeyMonitor.configure(keyCode: hotkey.keyCode)
        configureComputerUseHotkeyMonitor()
        dictationTestCallback = nil
        dictationTestFailureCallback = nil
        dictationTestRecordingStarted = nil
        dictationTestBackend = nil
        dictationTestCohereLanguage = nil

        onboardingWindowController?.close()
        onboardingWindowController = nil
        if hasRequiredStartupPermissions(for: onboardingUseCase) {
            meetingFeatureMonitorsAllowed = true
            if onboardingUseCase.includesPushToTalk {
                hotkeyMonitor.start()
                startComputerUseHotkeyMonitorIfNeeded()
            }
            dictationIdleDotAllowed = true
            syncDictationIdleDot()
            syncCalendarMonitor()
            // Start monitors that were deferred during onboarding
            if shouldRunMeetingFeatureMonitors {
                startMeetingFeatureMonitors(includeMaraudersMap: false)
            }
            TelemetryDeck.signal("onboarding.completed", parameters: [
                "use_case": onboardingUseCase.rawValue,
                "voice_notes_selected": onboardingUseCase.includesVoiceNotes ? "true" : "false",
                "dictation_selected": onboardingUseCase.includesDictation ? "true" : "false",
                "meetings_selected": onboardingUseCase.includesMeetings ? "true" : "false",
                "microphone_granted": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "true" : "false",
                "accessibility_granted": AXIsProcessTrusted() ? "true" : "false",
                "input_monitoring_granted": CGPreflightListenEventAccess() ? "true" : "false",
            ])
            let completionTab = OnboardingFlow.completionTab(for: onboardingUseCase)
            openHistoryWindow(tab: completionTab)
        } else {
            showOnboarding(resumeFrom: onboardingProgressForPermissionRepair())
        }
    }

    @objc func openHistoryWindow() {
        guard ensureBasicDictationPermissionsBeforeDashboard() else { return }
        showActiveMeetingDocumentIfNeeded()
        presentHistoryWindow()
    }

    private func presentHistoryWindow(whenReady readyAction: (() -> Void)? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.historyWindowController?.show(whenReady: readyAction)
        }
    }

    func openHistoryWindow(tab: DashboardTab) {
        guard ensureBasicDictationPermissionsBeforeDashboard() else { return }
        presentHistoryWindow(tab: tab)
    }

    private func presentHistoryWindow(tab: DashboardTab) {
        appState.selectedTab = tab
        syncAppState()
        DispatchQueue.main.async { [weak self] in
            self?.historyWindowController?.show()
        }
    }

    private func hasRequiredStartupPermissions(for useCase: OnboardingUseCase) -> Bool {
        OnboardingPermissionGate.hasRequiredPermissions(
            OnboardingPermissionSnapshot(
                microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                accessibility: AXIsProcessTrusted(),
                inputMonitoring: CGPreflightListenEventAccess(),
                systemAudio: false,
                screenRecording: false
            ),
            for: useCase
        )
    }

    func reclassifyVoiceNotesAsDictationIfReady(
        microphoneGranted: Bool,
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool
    ) {
        guard config.resolvedOnboardingUseCase == .voiceNotes else { return }
        guard OnboardingPermissionGate.hasRequiredDictationPermissions(
            OnboardingPermissionSnapshot(
                microphone: microphoneGranted,
                accessibility: accessibilityGranted,
                inputMonitoring: inputMonitoringGranted,
                systemAudio: false,
                screenRecording: false
            )
        ) else { return }

        updateConfig { $0.onboardingUseCase = OnboardingUseCase.dictation.rawValue }
        hotkeyMonitor.configure(keyCode: config.dictationHotkey.keyCode)
        hotkeyMonitor.start()
        startComputerUseHotkeyMonitorIfNeeded()
        syncDictationRecorderWarmup(intent: .idlePrewarm(.permissionsReady))
        TelemetryDeck.signal("onboarding.use_case_reclassified", parameters: [
            "from_use_case": OnboardingUseCase.voiceNotes.rawValue,
            "to_use_case": OnboardingUseCase.dictation.rawValue,
            "reason": "dictation_permissions_granted",
        ])
    }

    private func ensureBasicDictationPermissionsBeforeDashboard() -> Bool {
        guard hasRequiredStartupPermissions(for: config.resolvedOnboardingUseCase) else {
            historyWindowController?.close()
            if let progress = OnboardingProgress.load() {
                showOnboarding(resumeFrom: progress)
            } else {
                showOnboarding(resumeFrom: onboardingProgressForPermissionRepair())
            }
            return false
        }
        return true
    }

    private func onboardingProgressForPermissionRepair() -> OnboardingProgress {
        OnboardingProgress(
            currentStep: OnboardingView.permissionsStep,
            userName: config.userName,
            selectedBackendKey: config.sttBackend,
            selectedModelKey: config.sttModel,
            selectedCohereLanguageCode: config.cohereLanguage,
            hotkeyKeyCode: config.dictationHotkey.keyCode,
            hotkeyLabel: config.dictationHotkey.label,
            systemAudioRequested: false,
            onboardingUseCaseRawValue: config.onboardingUseCase
        )
    }

    func showMeetingsHome(folderID: Int64? = nil) {
        appState.selectedTab = .meetings
        appState.selectedFolderID = folderID
        appState.meetingsNavigationState = .browser
        syncAppState()
    }

    func showTimelineHome() {
        appState.selectedTab = .timeline
        appState.meetingsNavigationState = .browser
        appState.selectedMeetingID = nil
        appState.selectedMeetingRecord = nil
    }

    func showMeetingDocument(id: Int64) {
        appState.selectedTab = .meetings
        appState.meetingDetailReturnDestination = .meetings
        appState.selectedMeetingID = id
        appState.selectedMeetingRecord = meeting(id: id)
        appState.meetingsNavigationState = .document(id)
    }

    func showTimelineMeetingDocument(id: Int64) {
        appState.selectedTab = .timeline
        appState.meetingDetailReturnDestination = .timeline
        appState.selectedMeetingID = id
        appState.selectedMeetingRecord = meeting(id: id)
        appState.meetingsNavigationState = .document(id)
    }

    private func showActiveMeetingDocumentIfNeeded() {
        guard let activeMeetingID,
              isMeetingRecording() || isStartingMeetingRecording else {
            return
        }
        showMeetingDocument(id: activeMeetingID)
    }

    func openActiveMeetingNotes() {
        guard ensureBasicDictationPermissionsBeforeDashboard() else { return }
        guard let activeMeetingID,
              isMeetingRecording() || isStartingMeetingRecording else { return }
        showMeetingDocument(id: activeMeetingID)
        appState.meetingNotesFocusRequest &+= 1
        presentHistoryWindow()
    }

    func showMeetingTemplatesManager() {
        appState.selectedTab = .meetings
        appState.isMeetingTemplatesManagerPresented = true
    }

    @objc func openPreferences() {
        openHistoryWindow(tab: .settings)
    }

    @objc func openSettingsTab() {
        openHistoryWindow(tab: .settings)
    }

    @objc func focusSearchField() {
        guard ensureBasicDictationPermissionsBeforeDashboard() else { return }
        presentHistoryWindow()
        DispatchQueue.main.async { [weak self] in
            self?.appState.focusSearchField = true
        }
    }

    @objc func checkForUpdates() {
        presentStandardUpdateCheck()
    }

    private func presentStandardUpdateCheck() {
        guard let updaterController else {
            appState.sparkleUpdateStatus = .disabled(message: "Update checks are disabled for this build.")
            return
        }
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        activateApplicationForSparkle()
        // Always enter Sparkle's standard path. Sparkle uses this same call to
        // refocus existing updater UI, so local availability gates would make
        // in-app buttons less reliable than the status-bar action.
        updaterController.checkForUpdates(nil)
        focusUpdaterWindowsCreatedAfterUpdateAction(excluding: existingWindows)
    }

    private func focusUpdaterWindowsCreatedAfterUpdateAction(excluding existingWindows: Set<ObjectIdentifier>) {
        for delay in [80_000_000, 240_000_000, 600_000_000, 1_200_000_000, 2_500_000_000] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay))
                self?.focusUpdaterWindows(excluding: existingWindows)
            }
        }
    }

    private func focusUpdaterWindows(excluding existingWindows: Set<ObjectIdentifier>) {
        let updaterWindows = NSApplication.shared.windows.filter { window in
            guard window.isVisible else { return false }
            return !existingWindows.contains(ObjectIdentifier(window)) && isLikelyUpdaterWindow(window)
        }
        guard !updaterWindows.isEmpty else { return }

        activateApplicationForSparkle()
        for window in updaterWindows {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func isLikelyUpdaterWindow(_ window: NSWindow) -> Bool {
        let className = String(describing: type(of: window))
        if className.localizedCaseInsensitiveContains("SPU") ||
            className.localizedCaseInsensitiveContains("SU") ||
            className.localizedCaseInsensitiveContains("Sparkle") {
            return true
        }

        // Sparkle's standard UI can present through AppKit alert/window
        // classes. Keep this semantic fallback narrow and only apply it to
        // windows created after the update action.
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        if title.localizedCaseInsensitiveContains("update") ||
            title.localizedCaseInsensitiveContains("updater") ||
            title.localizedCaseInsensitiveContains("new version") ||
            title.localizedCaseInsensitiveContains("available") {
            return true
        }
        return false
    }

    private func showBusyStatus(_ message: String, restoring previousStatus: SparkleUpdateStatus) {
        busyStatusGeneration += 1
        let generation = busyStatusGeneration
        let restoreStatus = nonBusyStatus(previousStatus)
        appState.sparkleUpdateStatus = .busy(message: message)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.busyStatusGeneration == generation else { return }
            guard case .busy = self.appState.sparkleUpdateStatus else { return }
            self.appState.sparkleUpdateStatus = restoreStatus
        }
    }

    private func nonBusyStatus(_ status: SparkleUpdateStatus) -> SparkleUpdateStatus {
        if case .busy = status {
            return .idle
        }
        return status
    }

    @MainActor
    private func activateApplicationForSparkle() {
        // Sparkle UI is opened from an LSUIElement menu-bar app. This is a
        // user-initiated update action, so use strong activation even though
        // AppKit deprecated the argumented API on macOS 14.
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func copyRecentDictation(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String {
            copyToClipboard(text)
        }
    }

    @objc func copyRecentMeeting(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String {
            copyToClipboard(text)
        }
    }

    @objc func selectBackendFromMenu(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String,
              let option = BackendOption.all.first(where: { $0.label == label }) else { return }
        selectBackend(option)
    }

    @objc func selectMeetingSummaryBackendFromMenu(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String,
              let option = MeetingSummaryBackendOption.all.first(where: { $0.label == label }) else { return }
        if option == .chatGPT, !chatGPTAuth.isAuthenticated {
            Task { await signInWithChatGPT() }
            return
        }
        selectMeetingSummaryBackend(option)
    }

    func resummarize(meeting: MeetingRecord, completion: @escaping (Result<Void, Error>) -> Void) {
        let templateSnapshot = meetingTemplateSnapshot(for: meeting)
        resummarize(meeting: meeting, using: templateSnapshot, completion: completion)
    }

    func applyMeetingTemplate(id: String, to meeting: MeetingRecord, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let templateSnapshot = MeetingTemplates.resolveExactSnapshot(
            id: id,
            customTemplates: config.customMeetingTemplates
        ) else {
            completion(.failure(MeetingTemplateSelectionError.templateNoLongerExists))
            return
        }
        resummarize(meeting: meeting, using: templateSnapshot, completion: completion)
    }

    private func resummarize(
        meeting: MeetingRecord,
        using templateSnapshot: MeetingTemplateSnapshot,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        Task { [weak self] in
            guard let self else { return }
            let plan = MeetingResummarizationPolicy.plan(for: meeting)
            do {
                let notes = try await MeetingSummaryClient.summarize(
                    // Re-summarizing reads the repaired transcript when there is
                    // one; before cleanup finishes this is still raw, which is
                    // correct rather than a bug.
                    transcript: meeting.displayTranscript,
                    meetingTitle: plan.promptTitle,
                    config: self.config,
                    template: templateSnapshot,
                    existingNotes: self.notesContextForResummary(meeting),
                    manualNotesToRetain: meeting.manualNotes
                )
                try self.dictationStore.updateMeetingSummary(
                    id: meeting.id,
                    title: plan.persistedTitle,
                    formattedNotes: notes,
                    selectedTemplateID: templateSnapshot.id,
                    selectedTemplateName: templateSnapshot.name,
                    selectedTemplateKind: templateSnapshot.kind,
                    selectedTemplatePrompt: templateSnapshot.prompt
                )
                await MainActor.run {
                    self.scheduleICloudSyncAfterLocalChange()
                    self.syncAppState()
                    self.historyWindowController?.reload()
                    completion(.success(()))
                }
            } catch {
                fputs("[muesli-native] failed to generate or persist meeting summary: \(error)\n", stderr)
                await MainActor.run {
                    if error is MeetingSummaryError {
                        completion(.failure(error))
                    } else {
                        completion(.failure(MeetingSummaryPersistenceError.failedToSaveSummary(underlying: error)))
                    }
                }
            }
        }
    }

    func retranscribe(meeting: MeetingRecord, completion: @escaping (Result<Void, Error>) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else {
                completion(.failure(MeetingRetranscriptionError.controllerUnavailable))
                return
            }
            var didSetProcessing = false
            var sessionTrace: SessionRunTrace?
            do {
                guard let recordingArtifactStore,
                      let reference = try recordingArtifactStore.recordingForMeeting(id: meeting.id),
                      let artifactID = reference.artifactID else {
                    throw MeetingRetranscriptionError.recordingUnavailable
                }
                let recordingURL = try recordingArtifactStore.playableURL(id: artifactID)
                guard let backend = self.normalizeMeetingTranscriptionSelectionForAvailability() else {
                    throw MeetingRetranscriptionError.noDownloadedTranscriptionModel
                }
                let retranscriptionConfig = self.config
                let retranscriptionStartedAt = Date()
                // Retranscription is an action taken now, so it follows the
                // meeting selection current at the time of the action.
                let retranscriptionSelection = retranscriptionConfig.meetingSpokenLanguage.selection
                let trace = self.makeMeetingSessionTrace(
                    backend: backend,
                    startedAt: retranscriptionStartedAt,
                    selection: retranscriptionSelection,
                    workload: .retranscription,
                    meetingOutputPolicy: retranscriptionConfig.meetingArtifactLanguagePolicy.outputPolicy
                )
                sessionTrace = trace
                await trace.associate(meetingID: meeting.id)
                await trace.recordStageStarted("meeting_retranscription")

                try self.updateMeetingStatusAndScheduleSyncThrowing(id: meeting.id, status: .processing)
                didSetProcessing = true
                self.syncAppState()
                self.historyWindowController?.reload()

                try await self.transcriptionCoordinator.preloadRequired(
                    backend: backend,
                    enablePostProcessor: false,
                    includeMeetingHelpers: true,
                    meetingHelperTrigger: .retranscription,
                    appleSpeechLanguage: self.config.resolvedAppleSpeechLanguage
                )
                let transcription = try await self.transcriptionCoordinator.transcribeMeetingWithEvidence(
                    at: recordingURL,
                    backend: backend,
                    languageDecision: MeetingSession.meetingLanguageDecision(
                        selection: retranscriptionSelection,
                        backend: backend,
                        workload: .retranscription
                    ),
                    profile: retranscriptionConfig.meetingLanguageProfile,
                    appleSpeechLanguage: self.config.resolvedAppleSpeechLanguage,
                    customWords: retranscriptionConfig.customWords
                )
                await trace.storeArtifact(transcription.raw.text, kind: .rawASR)
                await trace.storeArtifact(transcription.cleaned.text, kind: .cleanupResult)
                let rawTranscript = transcription.cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawTranscript.isEmpty else {
                    throw MeetingRetranscriptionError.emptyTranscript
                }
                await trace.storeArtifact(rawTranscript, kind: .finalOutput)

                let templateSnapshot = self.meetingTemplateSnapshot(for: meeting)
                let formattedNotes: String
                do {
                    formattedNotes = try await MeetingSummaryClient.summarize(
                        transcript: rawTranscript,
                        meetingTitle: meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Meeting" : meeting.title,
                        config: retranscriptionConfig,
                        template: templateSnapshot,
                        existingNotes: self.notesContextForResummary(meeting),
                        manualNotesToRetain: meeting.manualNotes
                    )
                } catch {
                    fputs("[muesli-native] re-transcription summary generation failed: \(error)\n", stderr)
                    formattedNotes = MeetingSummaryClient.summaryFailureNotes(
                        transcript: rawTranscript,
                        meetingTitle: meeting.title,
                        error: error,
                        manualNotes: meeting.manualNotes,
                        languageProfile: retranscriptionConfig.meetingLanguageProfile
                    )
                }

                do {
                    try self.dictationStore.updateMeetingTranscriptAndSummary(
                        id: meeting.id,
                        rawTranscript: rawTranscript,
                        formattedNotes: formattedNotes,
                        selectedTemplateID: templateSnapshot.id,
                        selectedTemplateName: templateSnapshot.name,
                        selectedTemplateKind: templateSnapshot.kind,
                        selectedTemplatePrompt: templateSnapshot.prompt
                    )
                } catch {
                    throw MeetingRetranscriptionError.failedToSave(underlying: error)
                }

                _ = await Self.completeMeetingRetranscriptionTrace(
                    trace,
                    elapsedMilliseconds: max(
                        Int(Date().timeIntervalSince(retranscriptionStartedAt) * 1_000),
                        0
                    ),
                    hadExistingNotes: !meeting.formattedNotes
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    hadManualNotes: !meeting.manualNotes
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                self.scheduleICloudSyncAfterLocalChange()
                self.syncAppState()
                self.historyWindowController?.reload()
                completion(.success(()))
            } catch is CancellationError {
                _ = await sessionTrace?.cancel(stage: "meeting_retranscription")
                if didSetProcessing {
                    self.updateMeetingStatusAndScheduleSync(id: meeting.id, status: meeting.status)
                }
                self.syncAppState()
                self.historyWindowController?.reload()
                completion(.failure(CancellationError()))
            } catch {
                _ = await sessionTrace?.fail(stage: "meeting_retranscription")
                fputs("[muesli-native] failed to re-transcribe meeting \(meeting.id): \(error)\n", stderr)
                if let status = Self.retranscriptionFailureStatus(
                    originalStatus: meeting.status,
                    didSetProcessing: didSetProcessing,
                    error: error
                ) {
                    self.updateMeetingStatusAndScheduleSync(id: meeting.id, status: status)
                }
                self.syncAppState()
                self.historyWindowController?.reload()
                completion(.failure(error))
            }
        }
    }

    static func retranscriptionFailureStatus(
        originalStatus: MeetingStatus,
        didSetProcessing: Bool,
        error: Error
    ) -> MeetingStatus? {
        guard didSetProcessing else { return nil }
        if let retranscriptionError = error as? MeetingRetranscriptionError {
            switch retranscriptionError {
            case .emptyTranscript, .failedToSave:
                return originalStatus
            case .controllerUnavailable, .recordingUnavailable, .noDownloadedTranscriptionModel:
                break
            }
        }
        return .failed
    }

    nonisolated static func completeMeetingRetranscriptionTrace(
        _ trace: SessionRunTrace,
        elapsedMilliseconds: Int,
        hadExistingNotes: Bool,
        hadManualNotes: Bool
    ) async -> Bool {
        await trace.storeArtifact(
            DictationDictionaryTrace.emptyContent,
            kind: .dictionaryChanges
        )
        await trace.storeArtifact(
            SessionTraceSnapshot.retranscriptionContext(
                hadExistingNotes: hadExistingNotes,
                hadManualNotes: hadManualNotes
            ),
            kind: .contextSources
        )
        await trace.recordStageCompleted(
            "meeting_retranscription",
            elapsedMilliseconds: elapsedMilliseconds
        )
        return await trace.claimTerminal(.success, metadata: [
            "stage": "meeting_retranscription",
            "history_created": "true",
        ])
    }

    // MARK: - Meeting Editing

    func meetingParticipants(meetingID: Int64) async throws -> [MeetingParticipant] {
        await waitForCalendarAttendeePersistence(meetingID: meetingID)
        let databaseURL = dictationStore.resolvedDatabaseURL
        return try await Task.detached(priority: .userInitiated) {
            try DictationStore(databaseURL: databaseURL).listMeetingParticipants(meetingID: meetingID)
        }.value
    }

    func attachMeetingParticipant(
        meetingID: Int64,
        participant: MeetingParticipantDraft
    ) async throws {
        let databaseURL = dictationStore.resolvedDatabaseURL
        try await Task.detached(priority: .userInitiated) {
            try DictationStore(databaseURL: databaseURL).attachMeetingParticipant(
                meetingID: meetingID,
                participant: participant
            )
        }.value
    }

    func removeMeetingParticipant(
        meetingID: Int64,
        participantIdentifier: String
    ) async throws {
        let databaseURL = dictationStore.resolvedDatabaseURL
        try await Task.detached(priority: .userInitiated) {
            try DictationStore(databaseURL: databaseURL).removeMeetingParticipant(
                meetingID: meetingID,
                participantIdentifier: participantIdentifier
            )
        }.value
    }

    private func persistCalendarAttendees(
        _ attendees: [CalendarAttendee],
        meetingID: Int64,
        mode: CalendarAttendeePersistenceMode = .attach
    ) {
        persistCalendarParticipants(
            attendees.map(\.participantDraft),
            meetingID: meetingID,
            mode: mode
        )
    }

    private func persistCalendarAttendees(
        for occurrence: CalendarOccurrenceReference?,
        meetingID: Int64
    ) {
        guard let occurrence, occurrence.provider == .eventKit else { return }

        if let cached = appState.upcomingCalendarEvents.first(where: {
            $0.source == .eventKit && $0.resolvedCalendarOccurrence.identityKey == occurrence.identityKey
        }) {
            persistCalendarAttendees(cached.attendees, meetingID: meetingID)
            return
        }

        Task { [weak self] in
            let attendees = await Task.detached(priority: .utility) {
                CalendarMonitor.attendees(for: occurrence)
            }.value
            self?.persistCalendarAttendees(attendees, meetingID: meetingID)
        }
    }

    private func persistCalendarParticipants(
        _ participants: [MeetingParticipantDraft],
        meetingID: Int64,
        mode: CalendarAttendeePersistenceMode
    ) {
        guard mode == .reconcile || !participants.isEmpty else { return }

        let databaseURL = dictationStore.resolvedDatabaseURL
        let previousTask = calendarAttendeePersistenceTasks[meetingID]?.task
        let generation = UUID()
        let task = Task.detached(priority: .utility) {
            _ = await previousTask?.value
            do {
                let store = DictationStore(databaseURL: databaseURL)
                switch mode {
                case .attach:
                    try store.attachCalendarMeetingParticipants(
                        meetingID: meetingID,
                        participants: participants
                    )
                case .reconcile:
                    try store.reconcileCalendarMeetingParticipants(
                        meetingID: meetingID,
                        participants: participants
                    )
                }
                return true
            } catch {
                fputs(
                    "[calendar] failed to save attendees for meeting \(meetingID): \(error)\n",
                    stderr
                )
                return false
            }
        }
        calendarAttendeePersistenceTasks[meetingID] = (generation, task)

        Task { [weak self] in
            let didPersist = await task.value
            guard let self,
                  self.calendarAttendeePersistenceTasks[meetingID]?.generation == generation else {
                return
            }
            self.calendarAttendeePersistenceTasks.removeValue(forKey: meetingID)
            if didPersist {
                NotificationCenter.default.post(
                    name: .meetingParticipantsDidChange,
                    object: meetingID
                )
            }
        }
    }

    private func waitForCalendarAttendeePersistence(meetingID: Int64) async {
        while let pending = calendarAttendeePersistenceTasks[meetingID] {
            _ = await pending.task.value
            guard let current = calendarAttendeePersistenceTasks[meetingID],
                  current.generation != pending.generation else {
                return
            }
        }
    }

    private func notesContextForResummary(_ meeting: MeetingRecord) -> String? {
        Self.notesContextForResummary(meeting)
    }

    static func notesContextForResummary(_ meeting: MeetingRecord) -> String? {
        guard meeting.notesState == .structuredNotes else { return nil }
        let trimmed = stripManualNotesSection(from: meeting.formattedNotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func stripManualNotesSection(from notes: String) -> String {
        let markers = [
            "\n\n### Written notes\n\n",
            "\n### Written notes\n\n",
            "### Written notes\n\n",
            "\n\n## Manual Notes\n\n",
            "\n## Manual Notes\n\n",
            "## Manual Notes\n\n"
        ]
        for marker in markers {
            if let range = notes.range(of: marker, options: [.backwards]) {
                return String(notes[..<range.lowerBound])
            }
        }
        return notes
    }

    func updateMeetingTitle(id: Int64, title: String) {
        liveMeetingTitleCache[id] = title
        do {
            try dictationStore.updateMeetingTitle(id: id, title: title)
            liveMeetingTitleCache[id] = nil
            scheduleICloudSyncAfterLocalChange()
        } catch {
            fputs("[muesli-native] failed to update meeting title \(id): \(error)\n", stderr)
        }
        syncAppState()
    }

    func cacheMeetingTitle(id: Int64, title: String) {
        liveMeetingTitleCache[id] = title
    }

    func updateMeetingNotes(id: Int64, notes: String) {
        try? dictationStore.updateMeetingNotes(id: id, formattedNotes: notes)
        scheduleICloudSyncAfterLocalChange()
        syncAppState()
    }

    func updateMeetingTranscript(id: Int64, transcript: String) {
        do {
            try dictationStore.updateMeetingTranscript(id: id, rawTranscript: transcript)
            scheduleICloudSyncAfterLocalChange()
        } catch {
            fputs("[muesli-native] failed to update meeting transcript \(id): \(error)\n", stderr)
        }
        syncAppState()
    }

    func updateMeetingManualNotes(id: Int64, notes: String) {
        liveManualNotesPersistWorkItems[id]?.cancel()
        liveManualNotesPersistWorkItems[id] = nil
        liveManualNotesCache[id] = notes
        do {
            try dictationStore.updateMeetingManualNotes(id: id, manualNotes: notes)
            markMeetingManualNotesPersisted(id: id, notes: notes)
            scheduleICloudSyncAfterLocalChange()
        } catch {
            fputs("[muesli-native] failed to update manual notes for \(id): \(error)\n", stderr)
        }
        syncAppState()
    }

    func cacheMeetingManualNotes(id: Int64, notes: String) {
        liveManualNotesCache[id] = notes
        scheduleCachedMeetingManualNotesPersistence(id: id)
    }

    func flushCachedMeetingManualNotes(id: Int64, sync: Bool = true) {
        liveManualNotesPersistWorkItems[id]?.cancel()
        liveManualNotesPersistWorkItems[id] = nil
        guard let notes = liveManualNotesCache[id] else { return }
        persistCachedMeetingManualNotes(id: id, notes: notes, sync: sync)
    }

    func hasPersistedMeetingManualNotes(id: Int64, notes: String) -> Bool {
        if liveManualNotesLastPersistedValue[id] == notes {
            return true
        }
        return (try? dictationStore.meeting(id: id)?.manualNotes) == notes
    }

    private func scheduleCachedMeetingManualNotesPersistence(id: Int64) {
        guard let notes = liveManualNotesCache[id] else { return }
        if shouldPersistCachedMeetingManualNotesImmediately(id: id, notes: notes) {
            flushCachedMeetingManualNotes(id: id, sync: false)
            return
        }

        let lastPersistedAt = liveManualNotesLastPersistedAt[id] ?? .distantPast
        let delay = max(liveManualNotesPersistInterval - Date().timeIntervalSince(lastPersistedAt), 0)
        liveManualNotesPersistWorkItems[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flushCachedMeetingManualNotes(id: id, sync: false)
        }
        liveManualNotesPersistWorkItems[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func shouldPersistCachedMeetingManualNotesImmediately(id: Int64, notes: String) -> Bool {
        if liveManualNotesLastPersistedValue[id] == nil { return true }
        if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let lastPersistedAt = liveManualNotesLastPersistedAt[id] ?? .distantPast
        return Date().timeIntervalSince(lastPersistedAt) >= liveManualNotesPersistInterval
    }

    private func persistCachedMeetingManualNotes(id: Int64, notes: String, sync: Bool) {
        if liveManualNotesLastPersistedValue[id] == notes {
            if sync {
                syncAppState()
            }
            return
        }
        do {
            try dictationStore.updateMeetingManualNotes(id: id, manualNotes: notes)
            markMeetingManualNotesPersisted(id: id, notes: notes)
            scheduleICloudSyncAfterLocalChange()
        } catch {
            fputs("[muesli-native] failed to persist manual notes for \(id): \(error)\n", stderr)
        }
        if sync {
            syncAppState()
        }
    }

    private func markMeetingManualNotesPersisted(id: Int64, notes: String) {
        liveManualNotesLastPersistedAt[id] = Date()
        liveManualNotesLastPersistedValue[id] = notes
    }

    private func clearCachedMeetingManualNotes(id: Int64) {
        liveManualNotesPersistWorkItems[id]?.cancel()
        liveManualNotesPersistWorkItems[id] = nil
        liveManualNotesCache[id] = nil
        liveManualNotesLastPersistedAt[id] = nil
        liveManualNotesLastPersistedValue[id] = nil
    }

    private func clearCachedMeetingTitle(id: Int64) {
        liveMeetingTitleCache[id] = nil
    }

    private func flushCachedMeetingTitle(id: Int64) {
        guard let title = liveMeetingTitleCache[id] else { return }
        do {
            try dictationStore.updateMeetingTitle(id: id, title: title)
            liveMeetingTitleCache[id] = nil
            scheduleICloudSyncAfterLocalChange()
        } catch {
            fputs("[muesli-native] failed to flush cached meeting title \(id): \(error)\n", stderr)
        }
    }

    private func clearAllCachedMeetingManualNotes() {
        liveManualNotesPersistWorkItems.values.forEach { $0.cancel() }
        liveManualNotesPersistWorkItems.removeAll()
        liveManualNotesCache.removeAll()
        liveManualNotesLastPersistedAt.removeAll()
        liveManualNotesLastPersistedValue.removeAll()
    }

    private func clearAllCachedMeetingTitles() {
        liveMeetingTitleCache.removeAll()
    }

    private func manualNotesForLiveMeeting(id: Int64) -> String {
        if let cached = liveManualNotesCache[id] {
            return cached
        }
        return (try? dictationStore.meeting(id: id)?.manualNotes) ?? ""
    }

    // MARK: - Folder Management

    nonisolated static func treeOrderedFolders(_ folders: [MeetingFolder], order: [Int64]) -> [MeetingFolder] {
        let orderedFolders = folders.sorted { a, b in
            let ai = order.firstIndex(of: a.id) ?? Int.max
            let bi = order.firstIndex(of: b.id) ?? Int.max
            if ai != bi { return ai < bi }
            return a.id < b.id
        }
        var childrenMap: [Int64?: [MeetingFolder]] = [:]
        for folder in folders {
            childrenMap[folder.parentID, default: []].append(folder)
        }
        // Sort siblings by folderOrder index, then by id as fallback.
        for key in childrenMap.keys {
            childrenMap[key]?.sort { a, b in
                let ai = order.firstIndex(of: a.id) ?? Int.max
                let bi = order.firstIndex(of: b.id) ?? Int.max
                if ai != bi { return ai < bi }
                return a.id < b.id
            }
        }
        var result: [MeetingFolder] = []
        var visited: Set<Int64> = []
        func visit(_ parentID: Int64?) {
            for folder in childrenMap[parentID] ?? [] {
                guard visited.insert(folder.id).inserted else { continue }
                result.append(folder)
                visit(folder.id)
            }
        }
        visit(nil)
        // Include orphaned folders and closed cycles so corrupt hierarchy data never hides folders.
        for folder in orderedFolders where !visited.contains(folder.id) {
            visited.insert(folder.id)
            result.append(folder)
            visit(folder.id)
        }
        return result
    }

    @discardableResult
    func createFolder(name: String) -> Int64? {
        let id = try? dictationStore.createFolder(name: name)
        syncAppState()
        return id
    }

    func renameFolder(id: Int64, name: String) {
        try? dictationStore.renameFolder(id: id, name: name)
        syncAppState()
    }

    func reorderFolders(ids: [Int64]) {
        updateConfig { $0.folderOrder = ids }
        syncAppState()
    }

    @discardableResult
    func createSubfolder(name: String, parentID: Int64) -> Int64? {
        let id = try? dictationStore.createFolder(name: name, parentID: parentID)
        syncAppState()
        return id
    }

    func moveFolder(id: Int64, toParent newParentID: Int64?) {
        try? dictationStore.moveFolder(id: id, toParent: newParentID)
        syncAppState()
    }

    func createFolderAndMoveMeeting(name: String, meetingID: Int64) {
        guard let folderID = try? dictationStore.createFolder(name: name) else { return }
        try? dictationStore.moveMeeting(id: meetingID, toFolder: folderID)
        syncAppState()
    }

    func deleteFolder(id: Int64) {
        try? dictationStore.deleteFolder(id: id)
        if appState.selectedFolderID == id {
            appState.selectedFolderID = nil
        }
        syncAppState()
    }

    func hideCalendarEvent(_ event: UnifiedCalendarEvent) {
        appState.hiddenCalendarEventIDs.insert(event.id)
        updateConfig {
            $0.hiddenCalendarEventIDs = self.appState.hiddenCalendarEventIDs.sorted()
            $0.hiddenCalendarEventSourceHints[event.id] = event.source.rawValue
        }
        statusBarController?.refresh()
    }

    func createMeetingFromCalendarEvent(_ event: UnifiedCalendarEvent, folderID: Int64?) {
        let occurrence = event.resolvedCalendarOccurrence
        // Calendar placeholders are idempotent per occurrence. Recordings are
        // intentionally not: users may record the same occurrence more than once.
        if let existing = try? dictationStore.meetingByCalendarOccurrence(occurrence) {
            if let folderID {
                try? dictationStore.moveMeeting(id: existing.id, toFolder: folderID)
            }
            syncAppState()
            fputs("[muesli-native] calendar event already exists as meeting \(existing.id), moved to folder\n", stderr)
            return
        }

        do {
            let meetingID = try dictationStore.insertMeeting(
                title: event.title,
                calendarEventID: event.id,
                startTime: event.startDate,
                endTime: event.endDate,
                rawTranscript: "",
                formattedNotes: "",
                micAudioPath: nil,
                systemAudioPath: nil,
                calendarOccurrence: occurrence
            )
            persistCalendarAttendees(event.attendees, meetingID: meetingID)
            if let folderID {
                try? dictationStore.moveMeeting(id: meetingID, toFolder: folderID)
            }
            scheduleICloudSyncAfterLocalChange()
            syncAppState()
            fputs("[muesli-native] created meeting from calendar event: \(event.title) (folder=\(folderID.map(String.init) ?? "none"))\n", stderr)
        } catch {
            fputs("[muesli-native] failed to create meeting from calendar event: \(error)\n", stderr)
        }
    }

    func moveMeeting(id: Int64, toFolder folderID: Int64?) {
        try? dictationStore.moveMeeting(id: id, toFolder: folderID)
        syncAppState()
    }

    func loadMoreDictations() {
        guard appState.hasMoreDictations else { return }
        let offset = appState.dictationRows.count
        let more = (try? dictationStore.recentDictations(
            limit: appState.dictationPageSize,
            offset: offset,
            fromDate: appState.dictationFromDate,
            toDate: appState.dictationToDate,
            origin: appState.dictationOriginFilter,
            targetApplication: appState.dictationApplicationFilter
        )) ?? []
        appState.dictationRows.append(contentsOf: more)
        appState.hasMoreDictations = more.count >= appState.dictationPageSize
    }

    func loadMoreTimelineEntries() {
        guard appState.hasMoreTimelineEntries else { return }
        let offset = appState.timelineRows.count
        let more = (try? dictationStore.timelineEntries(
            limit: appState.timelinePageSize,
            offset: offset,
            fromDate: appState.timelineFromDate,
            toDate: appState.timelineToDate,
            origin: appState.timelineOriginFilter,
            targetApplication: appState.timelineApplicationFilter
        )) ?? []
        appState.timelineRows.append(contentsOf: more)
        appState.hasMoreTimelineEntries = more.count >= appState.timelinePageSize
    }

    func filterTimeline(dateFilter: HistoryDateFilter) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        appState.timelineDateFilter = dateFilter
        appState.timelineFromDate = dateFilter.fromDate().map { formatter.string(from: $0) }
        appState.timelineToDate = nil
        appState.timelineScrollAnchor = nil
        syncAppState()
        appState.timelineScrollAnchor = appState.timelineRows.first?.id
    }

    func filterTimeline(origin: RecordOriginFilter) {
        appState.timelineOriginFilter = origin
        appState.timelineScrollAnchor = nil
        syncAppState()
        appState.timelineScrollAnchor = appState.timelineRows.first?.id
    }

    func filterTimeline(application: DictationTargetApplication?) {
        appState.timelineApplicationFilter = application
        appState.timelineScrollAnchor = nil
        syncAppState()
        appState.timelineScrollAnchor = appState.timelineRows.first?.id
    }

    func filterDictations(from: Date?, to: Date?) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        appState.dictationFromDate = from.map { formatter.string(from: $0) }
        appState.dictationToDate = to.map { formatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: $0)!) }
        syncAppState()
    }

    func clearDictationFilter() {
        appState.dictationFromDate = nil
        appState.dictationToDate = nil
        syncAppState()
    }

    func filterDictations(origin: RecordOriginFilter) {
        appState.dictationOriginFilter = origin
        syncAppState()
    }

    func filterDictations(application: DictationTargetApplication?) {
        appState.dictationApplicationFilter = application
        syncAppState()
    }

    func filterMeetings(origin: RecordOriginFilter) {
        appState.meetingOriginFilter = origin
        syncAppState()
    }

    func deleteDictation(id: Int64) {
        var preparedArtifactID: RecordingArtifactID?
        var beganRecordingDeletion = false
        do {
            if let recordingArtifactStore {
                preparedArtifactID = try recordingArtifactStore.recordingForDictation(id: id)?.artifactID
                if let preparedArtifactID,
                   try recordingArtifactStore.isLastOwningHistoryReference(artifactID: preparedArtifactID) {
                    RecordingArtifactPlaybackCoordinator.shared.beginExternalDeletion(artifactID: preparedArtifactID)
                    beganRecordingDeletion = true
                }
            }
            if let artifactID = try dictationStore.deleteDictation(id: id) {
                finishDurableRecordingDeletion(artifactID)
            } else if let preparedArtifactID {
                Task {
                    await RecordingArtifactPlaybackCoordinator.shared
                        .restoreAfterSharedOwnerRemoval(artifactID: preparedArtifactID)
                }
            }
        } catch {
            if beganRecordingDeletion, let preparedArtifactID {
                Task {
                    await RecordingArtifactPlaybackCoordinator.shared
                        .restoreAfterSharedOwnerRemoval(artifactID: preparedArtifactID)
                }
            }
            presentErrorAlert(title: "Couldn't Delete Dictation", message: error.localizedDescription)
            return
        }
        scheduleICloudSyncAfterLocalChange()
        syncAppState()
    }

    private func finishDurableRecordingDeletion(_ artifactID: RecordingArtifactID) {
        guard let recordingArtifactStore else { return }
        Task { @MainActor in
            let succeeded = await Task.detached(priority: .utility) {
                do {
                    try recordingArtifactStore.finishDurableDeletion(id: artifactID)
                    return true
                } catch {
                    return false
                }
            }.value
            RecordingArtifactPlaybackCoordinator.shared.finishExternalDeletion(
                artifactID: artifactID,
                succeeded: succeeded
            )
        }
    }

    private func restorePlaybackAfterBulkDeletion(
        candidates: [RecordingArtifactID],
        deleted: [RecordingArtifactID]
    ) {
        let deletedSet = Set(deleted)
        for artifactID in candidates where !deletedSet.contains(artifactID) {
            Task {
                await RecordingArtifactPlaybackCoordinator.shared
                    .restoreAfterSharedOwnerRemoval(artifactID: artifactID)
            }
        }
    }

    private func migrateLegacyRecordingForDeletionIfNeeded(_ meeting: MeetingRecord) throws {
        guard let path = meeting.savedRecordingPath else { return }
        guard let recordingArtifactStore else {
            throw RecordingArtifactStoreError.unsafeRecordingRoot
        }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let matchingMeetingIDs = try dictationStore.meetingRecordingReferences().compactMap { reference in
            URL(fileURLWithPath: reference.savedRecordingPath).standardizedFileURL.path == standardizedPath
                ? reference.id
                : nil
        }
        do {
            let artifact = try recordingArtifactStore.migrateLegacyMeetingRecording(
                meetingID: meeting.id,
                legacyURL: URL(fileURLWithPath: path),
                sessionID: Self.legacyMeetingRecordingSessionID(meetingID: meeting.id),
                savePolicy: .always
            )
            for meetingID in matchingMeetingIDs where meetingID != meeting.id {
                try recordingArtifactStore.attachExistingLegacyMeetingRecording(
                    meetingID: meetingID,
                    artifactID: artifact.id
                )
            }
        } catch RecordingArtifactStoreError.unsafeSource,
                RecordingArtifactStoreError.unsupportedFileExtension {
            for meetingID in matchingMeetingIDs {
                try recordingArtifactStore.markLegacyMeetingRecordingInvalid(meetingID: meetingID)
            }
        }
    }

    /// Whether the selected summary backend can actually answer. Mirrors the detail view's
    /// gate so the floating panel never offers chat the detail view is hiding.
    var isMeetingChatReady: Bool {
        switch MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend).backend {
        case MeetingSummaryBackendOption.chatGPT.backend:
            return appState.isChatGPTAuthenticated
        case MeetingSummaryBackendOption.openAI.backend:
            return !config.openAIAPIKey.isEmpty
                || ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil
        case MeetingSummaryBackendOption.openRouter.backend:
            return !config.openRouterAPIKey.isEmpty
                || ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil
        case MeetingSummaryBackendOption.ollama.backend:
            return true
        case MeetingSummaryBackendOption.lmStudio.backend:
            return MeetingSummaryClient.lmStudioHasRequiredSettings(config: config)
        case MeetingSummaryBackendOption.customLLM.backend:
            return MeetingSummaryClient.customLLMHasRequiredSettings(config: config)
        default:
            return false
        }
    }

    func deleteMeeting(id: Int64) {
        guard let meeting = meeting(id: id) else { return }
        guard canDeleteMeeting(meeting) else { return }

        var preparedArtifactID: RecordingArtifactID?
        var beganRecordingDeletion = false
        do {
            try migrateLegacyRecordingForDeletionIfNeeded(meeting)
            let recordingReference = try recordingArtifactStore?.recordingForMeeting(id: id)
            preparedArtifactID = recordingReference?.artifactID
            if let preparedArtifactID,
               try recordingArtifactStore?.isLastOwningHistoryReference(artifactID: preparedArtifactID) == true {
                RecordingArtifactPlaybackCoordinator.shared.beginExternalDeletion(artifactID: preparedArtifactID)
                beganRecordingDeletion = true
            }
            let artifactID = try dictationStore.deleteMeeting(id: id)
            if let artifactID {
                finishDurableRecordingDeletion(artifactID)
            } else if let preparedArtifactID {
                Task {
                    await RecordingArtifactPlaybackCoordinator.shared
                        .restoreAfterSharedOwnerRemoval(artifactID: preparedArtifactID)
                }
            }
            // Chat history is held in memory keyed by meeting. Without this, deleting a
            // meeting would remove its row and recording while leaving the questions and
            // answers about it resident until the app quits.
            MeetingChatConversations.shared.forget(meetingID: id)
            cleanupOrphanedMeetingWaveformCacheFiles()
            scheduleICloudSyncAfterLocalChange()
        } catch let error as MeetingLifecycleError {
            if beganRecordingDeletion, let preparedArtifactID {
                Task {
                    await RecordingArtifactPlaybackCoordinator.shared
                        .restoreAfterSharedOwnerRemoval(artifactID: preparedArtifactID)
                }
            }
            presentErrorAlert(title: "Couldn't Delete Meeting", message: error.localizedDescription)
            return
        } catch {
            if beganRecordingDeletion, let preparedArtifactID {
                Task {
                    await RecordingArtifactPlaybackCoordinator.shared
                        .restoreAfterSharedOwnerRemoval(artifactID: preparedArtifactID)
                }
            }
            presentErrorAlert(
                title: "Couldn't Delete Meeting",
                message: MeetingLifecycleError.failedToDeleteMeeting(underlying: error).localizedDescription
            )
            return
        }

        if appState.selectedMeetingID == id {
            appState.selectedMeetingID = nil
            appState.selectedMeetingRecord = nil
            if case .document(let selectedID) = appState.meetingsNavigationState, selectedID == id {
                appState.meetingsNavigationState = .browser
            }
        }
        clearCachedMeetingManualNotes(id: id)
        clearCachedMeetingTitle(id: id)
        staleLiveMeetingRecoveryFailures.remove(id)

        historyWindowController?.reload()
        statusBarController?.refresh()
        syncAppState()
    }

    func clearDictationHistory() {
        var candidates: [RecordingArtifactID] = []
        do {
            candidates = try dictationStore.recordingArtifactsRemovedByClearingDictations()
            candidates.forEach {
                RecordingArtifactPlaybackCoordinator.shared.beginExternalDeletion(artifactID: $0)
            }
            let artifactIDs = try dictationStore.clearDictations()
            artifactIDs.forEach(finishDurableRecordingDeletion)
            restorePlaybackAfterBulkDeletion(candidates: candidates, deleted: artifactIDs)
        } catch {
            restorePlaybackAfterBulkDeletion(candidates: candidates, deleted: [])
            presentErrorAlert(title: "Couldn't Clear Dictation History", message: error.localizedDescription)
            return
        }
        scheduleICloudSyncAfterLocalChange()
        statusBarController?.refresh()
        historyWindowController?.reload()
        syncAppState()
    }

    func canDeleteMeeting(_ meeting: MeetingRecord) -> Bool {
        canDeleteMeeting(id: meeting.id, status: meeting.status)
    }

    func canDeleteMeeting(_ meeting: MeetingListRecord) -> Bool {
        canDeleteMeeting(id: meeting.id, status: meeting.status)
    }

    private func canDeleteMeeting(id: Int64, status: MeetingStatus) -> Bool {
        guard id != activeMeetingID else { return false }
        if staleLiveMeetingRecoveryFailures.contains(id) {
            return true
        }
        switch status {
        case .recording, .processing:
            return false
        case .completed, .noteOnly, .failed:
            return true
        }
    }

    func activeLiveMeetingRecord() -> MeetingListRecord? {
        guard let activeMeetingID,
              isMeetingRecording() || isStartingMeetingRecording else {
            return nil
        }
        // Projected, not `meeting(id:)`: the browser re-reads this on every body
        // evaluation while recording, and the full row grows with the live
        // transcript.
        return try? dictationStore.meetingListRecord(id: activeMeetingID)
    }

    func clearMeetingHistory() {
        guard !isMeetingRecording(), !isStartingMeetingRecording, backgroundMeetingProcessingCount == 0 else {
            presentErrorAlert(
                title: "Couldn't Clear Meeting History",
                message: "A meeting is recording or still being processed. Please wait before clearing saved meetings."
            )
            return
        }

        do {
            for reference in try dictationStore.meetingRecordingReferences() {
                guard let meeting = try dictationStore.meeting(id: reference.id) else { continue }
                try migrateLegacyRecordingForDeletionIfNeeded(meeting)
            }
        } catch {
            presentErrorAlert(
                title: "Couldn't Clear Meeting History",
                message: "Saved meeting audio could not be prepared safely, so meeting history was left in place. \(error.localizedDescription)"
            )
            return
        }

        var candidates: [RecordingArtifactID] = []
        do {
            candidates = try dictationStore.recordingArtifactsRemovedByClearingMeetings()
            candidates.forEach {
                RecordingArtifactPlaybackCoordinator.shared.beginExternalDeletion(artifactID: $0)
            }
            let artifactIDs = try dictationStore.clearMeetings()
            artifactIDs.forEach(finishDurableRecordingDeletion)
            restorePlaybackAfterBulkDeletion(candidates: candidates, deleted: artifactIDs)
        } catch {
            restorePlaybackAfterBulkDeletion(candidates: candidates, deleted: [])
            presentErrorAlert(title: "Couldn't Clear Meeting History", message: error.localizedDescription)
            return
        }
        try? clearSavedMeetingWaveformCache()
        scheduleICloudSyncAfterLocalChange()
        // Clearing every meeting must clear the questions and answers about them too.
        MeetingChatConversations.shared.forgetAll()
        clearAllCachedMeetingManualNotes()
        clearAllCachedMeetingTitles()
        appState.selectedMeetingID = nil
        appState.selectedMeetingRecord = nil
        appState.meetingsNavigationState = .browser
        statusBarController?.refresh()
        historyWindowController?.reload()
        syncAppState()
    }

    public func isMeetingRecording() -> Bool {
        activeMeetingSession?.isRecording == true || isStoppingMeetingRecording
    }

    func isMeetingRecordingPaused() -> Bool {
        activeMeetingSession?.isPaused == true
    }

    func isMeetingPanelOpen() -> Bool {
        meetingRecordingPanel.isPanelOpen
    }

    private var meetingTerminationState: MeetingTerminationState {
        MeetingTerminationPolicy.state(
            isStarting: isStartingMeetingRecording,
            hasActiveSession: activeMeetingSession != nil,
            isRecording: activeMeetingSession?.isRecording == true,
            isStopping: isStoppingMeetingRecording || backgroundMeetingProcessingCount > 0
        )
    }

    @MainActor
    func shouldTerminateApplication() -> Bool {
        let state = meetingTerminationState
        let messageText: String
        let informativeText: String

        if isTerminatingAfterMeetingConfirmation {
            isTerminatingAfterMeetingConfirmation = false
            return true
        }

        switch state {
        case .none:
            return true
        case .starting:
            messageText = "Meeting recording is starting"
            informativeText = "Quitting now will cancel the meeting recording before it has been saved."
        case .recording:
            messageText = "Meeting recording in progress"
            informativeText = "Quitting now will stop the meeting recording and the current transcript may be lost. Stop the recording first if you want Muesli to save notes."
        case .processing:
            messageText = "Meeting transcription in progress"
            informativeText = "Quitting now will interrupt transcription and the meeting notes may not be saved."
        }

        guard !isPresentingMeetingTerminationConfirmation else {
            return false
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Keep Muesli Running")
        alert.addButton(withTitle: "Quit Anyway")

        isPresentingMeetingTerminationConfirmation = true
        let didPresent = presentAlert(alert, fallbackLogContext: "meeting termination confirmation") { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPresentingMeetingTerminationConfirmation = false
                guard response == .alertSecondButtonReturn else { return }
                self.discardMeetingStateForTermination()
                self.isTerminatingAfterMeetingConfirmation = true
                NSApp.terminate(nil)
            }
        }
        if !didPresent {
            isPresentingMeetingTerminationConfirmation = false
        }

        return false
    }

    private func discardMeetingStateForTermination() {
        meetingRecordingPanel.close()
        activeMeetingPanelOwnerID = nil
        activeMeetingSession?.discard()
        activeMeetingSession = nil
        preparingMeetingSession?.discard()
        preparingMeetingSession = nil
        clearLiveMeetingTranscript()
        disarmMeetingAutoStop()
        cancelMeetingDurationLimit()
        if let meetingStartMeetingID {
            canceledMeetingStartIDs.insert(meetingStartMeetingID)
            resolveLiveMeetingAfterStartFailure(id: meetingStartMeetingID)
        }
        meetingStartTask?.cancel()
        meetingStartTask = nil
        meetingStartMeetingID = nil
        isStartingMeetingRecording = false
        isStoppingMeetingRecording = false
        syncMeetingDetectionMonitor()
        updateMeetingStartStatus(nil)
        updateMeetingNotificationVisibility()
        endMeetingActivity()
        syncAppState()
    }

    @objc func toggleMeetingRecording() {
        if isMeetingRecording() {
            stopMeetingRecording()
        } else {
            let wasMeetingRecording = isMeetingRecording()
            startMeetingRecordingFromEntryPoint(presentation: .compactControl)
            if !isMeetingRecording() && !isStartingMeetingRecording && !wasMeetingRecording {
                meetingRecordingHotkeyMonitor.cancelToggleMode()
            }
        }
    }

    @objc func toggleMeetingTranscriptPanel() {
        meetingRecordingPanel.toggleTranscriptPanel()
    }

    @objc func toggleMeetingRecordingPause() {
        if isMeetingRecordingPaused() {
            resumeMeetingRecording()
        } else {
            pauseMeetingRecording()
        }
    }

    func pauseMeetingRecording() {
        guard let activeMeetingSession,
              activeMeetingSession.isRecording,
              !activeMeetingSession.isPaused,
              !isStoppingMeetingRecording else { return }
        activeMeetingSession.pause()
        if let activeMeetingPanelOwnerID {
            meetingRecordingPanel.setPaused(true, ownerID: activeMeetingPanelOwnerID)
        }
        statusBarController?.setStatus("Meeting paused")
        statusBarController?.refresh()
        syncAppState()
    }

    func resumeMeetingRecording() {
        guard let activeMeetingSession,
              activeMeetingSession.isRecording,
              activeMeetingSession.isPaused,
              !isStoppingMeetingRecording else { return }
        activeMeetingSession.resume()
        if let activeMeetingPanelOwnerID {
            meetingRecordingPanel.setPaused(false, ownerID: activeMeetingPanelOwnerID)
        }
        statusBarController?.setStatus("Meeting: \(activeMeetingDisplayTitle())")
        statusBarController?.refresh()
        syncAppState()
    }

    @objc func startMeetingFromCalendarMenuItem(_ sender: NSMenuItem) {
        if let payload = sender.representedObject as? CalendarMenuMeetingPayload {
            startMeetingRecordingFromEntryPoint(
                title: payload.title,
                calendarOccurrence: payload.calendarOccurrence,
                endDate: payload.endDate,
                autoStopSource: payload.autoStopSource,
                startOrigin: .scheduledMeetingPrompt
            )
            return
        }

        guard let title = sender.representedObject as? String else { return }
        startMeetingRecordingFromEntryPoint(title: title)
    }

    @discardableResult
    func startMeetingRecordingFromEntryPoint(
        title: String = "Meeting",
        calendarEventID: String? = nil,
        calendarOccurrence: CalendarOccurrenceReference? = nil,
        endDate: Date? = nil,
        autoStopSource: MeetingAutoStopSource? = nil,
        presentation: MeetingStartPresentation = .foregroundNotes,
        startOrigin: MeetingRecordingStartOrigin = .manual
    ) -> Bool {
        guard ensureBasicDictationPermissionsBeforeDashboard() else { return false }
        if isMeetingRecording() {
            if presentation.presentsHistoryWindow {
                presentHistoryWindow(tab: .meetings)
            }
            return false
        }
        guard !isStartingMeetingRecording else { return false }
        let didStart = startMeetingRecording(
            title: title,
            calendarEventID: calendarEventID,
            calendarOccurrence: calendarOccurrence,
            openDocument: presentation.opensMeetingDocument,
            presentation: presentation,
            endDate: endDate,
            autoStopSource: autoStopSource,
            startOrigin: startOrigin
        )
        guard didStart else { return false }
        if presentation.presentsHistoryWindow {
            presentHistoryWindow(tab: .meetings)
        }
        return true
    }

    @discardableResult
    func startMeetingRecording(
        title: String = "Meeting",
        calendarEventID: String? = nil,
        calendarOccurrence: CalendarOccurrenceReference? = nil,
        openDocument: Bool = false,
        presentation: MeetingStartPresentation = .backgroundPill,
        endDate: Date? = nil,
        autoStopSource: MeetingAutoStopSource? = nil,
        startOrigin: MeetingRecordingStartOrigin = .manual,
        followUpToID: Int64? = nil,
        inheritedFolderID: Int64? = nil,
        previousMeetingNotes: String? = nil
    ) -> Bool {
        guard !isMeetingRecording(), !isStartingMeetingRecording else { return false }
        guard let meetingBackend = normalizeMeetingTranscriptionSelectionForAvailability() else {
            presentErrorAlert(
                title: "Meeting failed to start",
                message: "Download a transcription model before recording a meeting."
            )
            return false
        }
        let meetingConfig = config
        let meetingStartedAt = Date()
        let sessionTrace = makeMeetingSessionTrace(
            backend: meetingBackend,
            startedAt: meetingStartedAt,
            selection: meetingConfig.meetingSpokenLanguage.selection,
            workload: .meetingFinal,
            meetingOutputPolicy: meetingConfig.meetingArtifactLanguagePolicy.outputPolicy
        )
        let templateSnapshot = defaultMeetingTemplate()
        let resolvedCalendarEventID = calendarOccurrence?.eventID ?? calendarEventID
        let meetingID: Int64
        do {
            meetingID = try dictationStore.createLiveMeeting(
                title: title,
                calendarEventID: resolvedCalendarEventID,
                startTime: meetingStartedAt,
                selectedTemplateID: templateSnapshot.id,
                selectedTemplateName: templateSnapshot.name,
                selectedTemplateKind: templateSnapshot.kind,
                selectedTemplatePrompt: templateSnapshot.prompt,
                folderID: inheritedFolderID,
                followUpToID: followUpToID,
                calendarOccurrence: calendarOccurrence
            )
            persistCalendarAttendees(for: calendarOccurrence, meetingID: meetingID)
            activeMeetingID = meetingID
            meetingSessionTraces[meetingID] = sessionTrace
            Task { await sessionTrace.associate(meetingID: meetingID) }
            activeMeetingAudioWarning = nil
            activeMeetingAudioWarningState.reset()
            syncAppState()
            if openDocument {
                showMeetingDocument(id: meetingID)
            }
        } catch {
            Task {
                await sessionTrace.fail(stage: "create_live_meeting")
            }
            fputs("[muesli-native] failed to create live meeting: \(error)\n", stderr)
            recordDiagnosticIncident(
                kind: .meetingStartFailed,
                stage: .createLiveMeeting,
                backend: meetingBackend,
                error: error
            )
            presentErrorAlert(title: "Meeting failed to start", message: error.localizedDescription)
            return false
        }
        armMeetingAutoStop(
            source: startOrigin.signalLossSource(
                explicitSource: autoStopSource,
                recentSource: recentMeetingAutoStopSource()
            ),
            response: startOrigin.signalLossResponse
        )
        isStartingMeetingRecording = true
        syncMeetingDetectionMonitor()
        // Keep this after backend normalization and live-meeting creation so
        // a failed meeting start does not silently cancel an active dictation.
        cancelDictationAudioSessionForMeetingRecordingIfNeeded()
        syncDictationRecorderWarmup(intent: .idlePrewarm(.meetingStateChanged))
        meetingStartMeetingID = meetingID
        updateMeetingStartStatus("Meeting transcription will start shortly.")
        beginMeetingActivity(reason: "Recording and transcribing a meeting")
        meetingMonitor.suppressWhileActive()
        meetingMonitor.refreshState()
        updateMeetingNotificationVisibility()

        meetingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await self.startMeetingRecordingWithSystemAudioRecovery(
                    title: title,
                    calendarEventID: resolvedCalendarEventID,
                    meetingID: meetingID,
                    backend: meetingBackend,
                    config: meetingConfig,
                    templateSnapshot: templateSnapshot,
                    presentation: presentation,
                    endDate: endDate,
                    previousMeetingNotes: previousMeetingNotes
                )
            } catch is CancellationError {
                if self.meetingStartMeetingID == meetingID {
                    let trace = self.meetingSessionTraces.removeValue(forKey: meetingID)
                    Task {
                        await trace?.cancel(stage: "meeting_start")
                    }
                    self.disarmMeetingAutoStopAfterFailedStart()
                    self.resolveLiveMeetingAfterStartFailure(id: meetingID)
                    self.cancelMeetingRecordingHotkeyToggleAfterFailedStart(meetingID: meetingID)
                    self.meetingMonitor.resumeAfterCooldown()
                    self.meetingMonitor.refreshState()
                    self.statusBarController?.refresh()
                    self.endMeetingActivity()
                    self.syncDictationRecorderWarmup(intent: .idlePrewarm(.meetingStateChanged))
                }
            } catch {
                if self.meetingStartMeetingID == meetingID {
                    let trace = self.meetingSessionTraces.removeValue(forKey: meetingID)
                    Task {
                        await trace?.fail(stage: "meeting_start")
                    }
                    fputs("[muesli-native] failed to start meeting: \(error)\n", stderr)
                    _ = self.recordDiagnosticIncident(
                        kind: .meetingStartFailed,
                        stage: .startMeetingRecording,
                        backend: meetingBackend,
                        error: error
                    )
                    self.disarmMeetingAutoStopAfterFailedStart()
                    self.resolveLiveMeetingAfterStartFailure(id: meetingID)
                    self.cancelMeetingRecordingHotkeyToggleAfterFailedStart(meetingID: meetingID)
                    self.meetingMonitor.resumeAfterCooldown()
                    self.meetingMonitor.refreshState()
                    self.statusBarController?.refresh()
                    self.endMeetingActivity()
                    self.syncDictationRecorderWarmup(intent: .idlePrewarm(.meetingStateChanged))

                    self.presentMeetingStartFailureAlert(error: error)
                }
            }
            self.finishMeetingStartAttempt(meetingID: meetingID)
        }
        return true
    }

    func startQuickNoteMeeting() {
        startMeetingRecordingFromEntryPoint(title: "Meeting")
    }

    /// Whether a finished meeting can be resumed right now (used to gate the UI control too).
    func canResumeFinishedMeeting(_ meeting: MeetingRecord) -> Bool {
        MeetingResumePolicy.canResume(status: meeting.status)
    }

    /// Whether `meeting` can spawn a follow-up meeting right now (also gates the UI control).
    func canStartFollowUpMeeting(_ meeting: MeetingRecord) -> Bool {
        MeetingFollowUpPolicy.canStartFollowUp(status: meeting.status)
    }

    /// Starts a *new* meeting linked into `meetingID`'s thread (vs. resume, which
    /// reopens the same row). Follow-ups attach to the selected meeting, so a
    /// meeting can have more than one follow-up. The new meeting inherits the
    /// predecessor's folder and carries its notes into the summary prompt so
    /// open action items follow the thread.
    func startFollowUpMeeting(fromMeetingID meetingID: Int64) {
        guard !isMeetingRecording(), !isStartingMeetingRecording else { return }
        guard let predecessor = meeting(id: meetingID),
              canStartFollowUpMeeting(predecessor) else { return }
        startMeetingRecording(
            title: MeetingFollowUpPolicy.followUpTitle(from: predecessor.title),
            openDocument: true,
            presentation: .foregroundNotes,
            followUpToID: predecessor.id,
            inheritedFolderID: predecessor.folderID,
            previousMeetingNotes: MeetingFollowUpPolicy.carriedContext(from: predecessor)
        )
    }

    /// Thread parent, direct child follow-ups, and total size for the
    /// detail-view breadcrumb/list.
    /// Returns nil for meetings that are not part of a follow-up thread.
    func meetingThreadContext(for meetingID: Int64) -> MeetingThreadContext? {
        do {
            guard let navigation = try dictationStore.meetingThreadNavigation(containing: meetingID) else { return nil }
            return MeetingThreadContext(
                predecessor: navigation.predecessorID.flatMap { meeting(id: $0) },
                successors: navigation.successorIDs.compactMap { meeting(id: $0) },
                count: navigation.count
            )
        } catch {
            fputs("[muesli-native] failed to resolve meeting thread for \(meetingID): \(error)\n", stderr)
            return nil
        }
    }

    /// Reopens a finished meeting and appends more recording onto the *same* row
    /// (vs. `startMeetingRecording`, which creates a new row). Mirrors the start
    /// scaffolding but skips `createLiveMeeting` and reuses the existing meeting id.
    /// Named distinctly from `MeetingSession.resume()` (the in-session un-pause).
    func resumeFinishedMeeting(meetingID: Int64) {
        guard !isMeetingRecording(), !isStartingMeetingRecording else { return }
        guard let meeting = meeting(id: meetingID), canResumeFinishedMeeting(meeting) else { return }
        guard let meetingBackend = normalizeMeetingTranscriptionSelectionForAvailability() else {
            presentErrorAlert(
                title: "Resume failed",
                message: "Download a transcription model before recording."
            )
            return
        }
        let meetingConfig = config
        let sessionTrace = makeMeetingSessionTrace(
            backend: meetingBackend,
            startedAt: Date(),
            selection: meetingConfig.meetingSpokenLanguage.selection,
            workload: .meetingFinal,
            meetingOutputPolicy: meetingConfig.meetingArtifactLanguagePolicy.outputPolicy
        )
        meetingSessionTraces[meetingID] = sessionTrace
        Task {
            await sessionTrace.associate(meetingID: meetingID)
        }

        let priorTranscript: String
        do {
            priorTranscript = try dictationStore.prepareMeetingForResume(id: meetingID)
        } catch {
            meetingSessionTraces.removeValue(forKey: meetingID)
            Task {
                await sessionTrace.fail(stage: "prepare_meeting_resume")
            }
            fputs("[muesli-native] failed to prepare meeting resume \(meetingID): \(error)\n", stderr)
            presentErrorAlert(title: "Resume failed", message: error.localizedDescription)
            return
        }
        pendingResumePriorTranscript[meetingID] = priorTranscript
        let previousMeetingNotes = meeting.followUpToID
            .flatMap { self.meeting(id: $0) }
            .flatMap { MeetingFollowUpPolicy.carriedContext(from: $0) }

        // REUSE the existing row — do NOT call createLiveMeeting.
        activeMeetingID = meetingID
        activeMeetingAudioWarning = nil
        activeMeetingAudioWarningState.reset()
        syncAppState()

        armMeetingAutoStop(
            source: MeetingRecordingStartOrigin.manual.signalLossSource(
                explicitSource: nil,
                recentSource: recentMeetingAutoStopSource()
            ),
            response: MeetingRecordingStartOrigin.manual.signalLossResponse
        )
        isStartingMeetingRecording = true
        syncMeetingDetectionMonitor()
        cancelDictationAudioSessionForMeetingRecordingIfNeeded()
        syncDictationRecorderWarmup(intent: .idlePrewarm(.meetingStateChanged))
        meetingStartMeetingID = meetingID
        updateMeetingStartStatus("Resuming meeting recording…")
        beginMeetingActivity(reason: "Recording and transcribing a meeting")
        meetingMonitor.suppressWhileActive()
        meetingMonitor.refreshState()
        updateMeetingNotificationVisibility()

        meetingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await self.startMeetingRecordingWithSystemAudioRecovery(
                    title: meeting.title,
                    calendarEventID: meeting.calendarEventID,
                    meetingID: meetingID,
                    backend: meetingBackend,
                    config: meetingConfig,
                    templateSnapshot: self.meetingTemplateSnapshot(for: meeting),
                    endDate: nil,
                    previousMeetingNotes: previousMeetingNotes
                )
            } catch is CancellationError {
                if self.meetingStartMeetingID == meetingID {
                    let trace = self.meetingSessionTraces.removeValue(forKey: meetingID)
                    Task {
                        await trace?.cancel(stage: "meeting_resume_start")
                    }
                    self.disarmMeetingAutoStopAfterFailedStart()
                    self.resolveLiveMeetingAfterStartFailure(id: meetingID)
                    self.cancelMeetingRecordingHotkeyToggleAfterFailedStart(meetingID: meetingID)
                    self.meetingMonitor.resumeAfterCooldown()
                    self.meetingMonitor.refreshState()
                    self.statusBarController?.refresh()
                    self.endMeetingActivity()
                    self.syncDictationRecorderWarmup(intent: .idlePrewarm(.meetingStateChanged))
                }
            } catch {
                if self.meetingStartMeetingID == meetingID {
                    let trace = self.meetingSessionTraces.removeValue(forKey: meetingID)
                    Task {
                        await trace?.fail(stage: "meeting_resume_start")
                    }
                    fputs("[muesli-native] failed to resume meeting: \(error)\n", stderr)
                    self.disarmMeetingAutoStopAfterFailedStart()
                    self.resolveLiveMeetingAfterStartFailure(id: meetingID)
                    self.cancelMeetingRecordingHotkeyToggleAfterFailedStart(meetingID: meetingID)
                    self.meetingMonitor.resumeAfterCooldown()
                    self.meetingMonitor.refreshState()
                    self.statusBarController?.refresh()
                    self.endMeetingActivity()
                    self.syncDictationRecorderWarmup(intent: .idlePrewarm(.meetingStateChanged))
                    self.presentMeetingStartFailureAlert(error: error)
                }
            }
            self.finishMeetingStartAttempt(meetingID: meetingID)
        }
    }

    // MARK: - Audio File Import

    /// Presents a file picker and imports an audio file for offline transcription.
    func importAudioFile() {
        guard !isMeetingRecording(), !isStartingMeetingRecording else { return }
        guard normalizeMeetingTranscriptionSelectionForAvailability() != nil else {
            presentErrorAlert(
                title: "Import Failed",
                message: "Download a transcription model before importing audio files."
            )
            return
        }

        isStartingMeetingRecording = true
        let sessionID = UUID()
        importSessionID = sessionID

        importTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let sourceURL = await AudioFileImportController.selectFile() else {
                self.isStartingMeetingRecording = false
                self.importTask = nil
                self.importSessionID = nil
                self.syncAppState()
                return
            }
            await self.importAudioFile(from: sourceURL, sessionID: sessionID)
        }
    }

    /// Imports an audio file from a URL (drag-and-drop or file picker).
    func importAudioFileFromURL(_ url: URL) {
        guard !isMeetingRecording(), !isStartingMeetingRecording else { return }
        guard AudioFileImportController.isSupportedFileURL(url) else {
            presentErrorAlert(
                title: "Import Failed",
                message: "This audio file format is not supported."
            )
            return
        }
        guard normalizeMeetingTranscriptionSelectionForAvailability() != nil else {
            presentErrorAlert(
                title: "Import Failed",
                message: "Download a transcription model before importing audio files."
            )
            return
        }

        isStartingMeetingRecording = true
        let sessionID = UUID()
        importSessionID = sessionID

        importTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.importAudioFile(from: url, sessionID: sessionID)
        }
    }

    private func importAudioFile(from sourceURL: URL, sessionID: UUID) async {
        let filename = sourceURL.deletingPathExtension().lastPathComponent
        let title = filename.isEmpty ? "Imported Recording" : filename
        let importContext = audioFileImportContext()
        let sessionTrace = makeMeetingSessionTrace(
            id: sessionID,
            backend: importContext.backend,
            startedAt: Date(),
            selection: importContext.config.meetingSpokenLanguage.selection,
            workload: .fileImport,
            meetingOutputPolicy: importContext.config.meetingArtifactLanguagePolicy.outputPolicy
        )
        importSessionTrace = sessionTrace
        await sessionTrace.storeArtifact("", kind: .contextSources)

        self.updateImportProgressStatus("Importing audio file...", sessionID: sessionID)
        self.beginMeetingActivity(reason: "Importing audio file for transcription")

        do {
            let result = try await AudioFileImportController.importAudioFile(
                sourceURL: sourceURL,
                title: title,
                controller: self,
                context: importContext,
                sessionTrace: sessionTrace,
                progress: { [weak self] status in
                    Task { @MainActor in
                        guard let self,
                              self.importSessionID == sessionID else { return }
                        self.updateImportProgressStatus(status, sessionID: sessionID)
                    }
                }
            )

            guard importSessionID == sessionID, !Task.isCancelled else {
                await sessionTrace.cancel(stage: "audio_import")
                discardProvisionalImportedMeeting(id: result.meetingID)
                if importSessionID == sessionID {
                    finishAudioImportUI(refreshStatus: false)
                }
                return
            }

            await sessionTrace.associate(meetingID: result.meetingID)
            let didWin = await sessionTrace.claimTerminal(
                result.usedFallback ? .fallbackSuccess : .success,
                metadata: [
                    "history_created": "true",
                    "fallback_reasons": result.fallbackSummary.reasons
                        .map(\.rawValue)
                        .sorted()
                        .joined(separator: ","),
                    "output_characters": String(result.rawTranscript.count),
                    "source": "audio_import",
                ]
            )
            guard didWin else {
                discardProvisionalImportedMeeting(id: result.meetingID)
                finishAudioImportUI(refreshStatus: false)
                return
            }

            finishAudioImportUI()
            historyWindowController?.reload()
            publishImportedAudioMeeting(
                meetingID: result.meetingID,
                completedAt: result.completedAt
            )
            showMeetingDocument(id: result.meetingID)
            TelemetryDeck.signal("meeting.imported")
        } catch is CancellationError {
            await sessionTrace.cancel(stage: "audio_import")
            finishAudioImportUI()
        } catch {
            await sessionTrace.fail(stage: "audio_import")
            finishAudioImportUI()
            presentErrorAlert(
                title: "Import Failed",
                message: error.localizedDescription
            )
        }
    }

    private func finishAudioImportUI(refreshStatus: Bool = true) {
        importSessionTrace = nil
        importTask = nil
        importSessionID = nil
        isStartingMeetingRecording = false
        updateMeetingStartStatus(nil)
        endMeetingActivity()
        if refreshStatus {
            statusBarController?.refresh()
        }
        syncAppState()
        reconcileTranscriptionActivityUI()
    }

    func audioFileImportContext() -> AudioFileImportController.ImportContext {
        AudioFileImportController.ImportContext(
            config: config,
            backend: selectedMeetingTranscriptionBackend,
            transcriptionCoordinator: transcriptionCoordinator,
            templateSnapshot: defaultMeetingTemplate()
        )
    }

    func persistImportedAudioMeeting(
        title: String,
        calendarEventID: String?,
        startTime: Date,
        endTime: Date,
        rawTranscript: String,
        formattedNotes: String,
        micAudioPath: String?,
        systemAudioPath: String?,
        savedRecordingPath: String?,
        sessionID: UUID? = nil,
        selectedTemplateID: String?,
        selectedTemplateName: String?,
        selectedTemplateKind: MeetingTemplateKind?,
        selectedTemplatePrompt: String?
    ) throws -> Int64 {
        let meetingID = try persistImportedAudioMeetingWithoutPublishing(
            title: title,
            calendarEventID: calendarEventID,
            startTime: startTime,
            endTime: endTime,
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            micAudioPath: micAudioPath,
            systemAudioPath: systemAudioPath,
            savedRecordingPath: savedRecordingPath,
            sessionID: sessionID,
            selectedTemplateID: selectedTemplateID,
            selectedTemplateName: selectedTemplateName,
            selectedTemplateKind: selectedTemplateKind,
            selectedTemplatePrompt: selectedTemplatePrompt
        )
        publishImportedAudioMeeting(meetingID: meetingID, completedAt: endTime)
        return meetingID
    }

    func persistImportedAudioMeetingWithoutPublishing(
        title: String,
        calendarEventID: String?,
        startTime: Date,
        endTime: Date,
        rawTranscript: String,
        formattedNotes: String,
        micAudioPath: String?,
        systemAudioPath: String?,
        savedRecordingPath: String?,
        sessionID: UUID? = nil,
        selectedTemplateID: String?,
        selectedTemplateName: String?,
        selectedTemplateKind: MeetingTemplateKind?,
        selectedTemplatePrompt: String?
    ) throws -> Int64 {
        var adoptedArtifactID: RecordingArtifactID?
        let recording: RecordingArtifactReference?
        if let savedRecordingPath {
            guard let recordingArtifactStore else {
                throw RecordingArtifactStoreError.unsafeRecordingRoot
            }
            let artifact = try recordingArtifactStore.adoptCapture(
                at: URL(fileURLWithPath: savedRecordingPath),
                sessionID: sessionID ?? UUID(),
                captureKind: .meeting,
                savePolicy: .always,
                terminalAt: endTime
            )
            adoptedArtifactID = artifact.id
            if let sessionID {
                try recordingArtifactStore.attachDiagnostic(
                    sessionID: sessionID,
                    artifactID: artifact.id,
                    availability: .available
                )
            }
            recording = RecordingArtifactReference(
                artifactID: artifact.id,
                availability: .available
            )
        } else {
            recording = nil
        }
        do {
            return try dictationStore.insertMeeting(
            title: title,
            calendarEventID: calendarEventID,
            startTime: startTime,
            endTime: endTime,
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            micAudioPath: micAudioPath,
            systemAudioPath: systemAudioPath,
            savedRecordingPath: nil,
            selectedTemplateID: selectedTemplateID,
            selectedTemplateName: selectedTemplateName,
            selectedTemplateKind: selectedTemplateKind,
            selectedTemplatePrompt: selectedTemplatePrompt,
            source: .audioImport,
            recording: recording
            )
        } catch {
            if let adoptedArtifactID {
                try? recordingArtifactStore?.deleteArtifact(id: adoptedArtifactID)
            }
            throw error
        }
    }

    private func publishImportedAudioMeeting(meetingID: Int64, completedAt: Date) {
        scheduleICloudSyncAfterLocalChange()
        scheduleMeetingTranscriptCleanup(meetingID: meetingID)
        meetingHookDispatcher.dispatchCompletedMeetingHook(
            meetingID: meetingID,
            completedAt: completedAt,
            config: config
        )
    }

    /// Removes only the unpublished row and copied recording created by the
    /// current import when cancellation wins terminal arbitration.
    func discardProvisionalImportedMeeting(id: Int64) {
        guard let meeting = meeting(id: id), meeting.source == .audioImport else { return }
        do {
            try migrateLegacyRecordingForDeletionIfNeeded(meeting)
            if let artifactID = try dictationStore.deleteMeeting(id: id) {
                RecordingArtifactPlaybackCoordinator.shared.beginExternalDeletion(artifactID: artifactID)
                finishDurableRecordingDeletion(artifactID)
            }
        } catch {
            fputs("[import] failed to discard provisional meeting \(id): \(error)\n", stderr)
        }
    }

    func cancelMeetingPreparation() {
        guard isStartingMeetingRecording, activeMeetingSession == nil else { return }

        if let meetingID = meetingStartMeetingID {
            // Live meeting start cancellation
            canceledMeetingStartIDs.insert(meetingID)
            let trace = meetingSessionTraces.removeValue(forKey: meetingID)
            Task {
                await trace?.cancel(stage: "meeting_preparation")
            }
            meetingStartTask?.cancel()
            preparingMeetingSession?.stopStreamingPartials()
            clearLiveMeetingTranscript(ownerID: meetingID)
            resolveLiveMeetingAfterStartFailure(id: meetingID)
            cancelMeetingRecordingHotkeyToggleAfterFailedStart(meetingID: meetingID)
            meetingMonitor.resumeAfterCooldown()
            meetingMonitor.refreshState()
            meetingStartTask = nil
            meetingStartMeetingID = nil
            syncDictationRecorderWarmup(intent: .idlePrewarm(.meetingStateChanged))
        } else {
            // Audio import cancellation
            let trace = importSessionTrace
            importSessionTrace = nil
            Task {
                await trace?.cancel(stage: "audio_import")
            }
            importTask?.cancel()
            importTask = nil
            importSessionID = nil
        }

        statusBarController?.refresh()
        endMeetingActivity()
        disarmMeetingAutoStopAfterFailedStart()
        meetingStartTask = nil
        meetingStartMeetingID = nil
        isStartingMeetingRecording = false
        reconcileTranscriptionActivityUI()
        syncMeetingDetectionMonitor()
        updateMeetingStartStatus(nil)
        updateMeetingNotificationVisibility()
        syncAppState()
    }

    private func finishMeetingStartAttempt(meetingID: Int64) {
        guard meetingStartMeetingID == meetingID else { return }
        let didStartActiveSession = activeMeetingID == meetingID && activeMeetingSession != nil
        canceledMeetingStartIDs.remove(meetingID)
        meetingStartTask = nil
        meetingStartMeetingID = nil
        isStartingMeetingRecording = false
        syncMeetingDetectionMonitor()
        updateMeetingStartStatus(nil)
        updateMeetingNotificationVisibility()
        if !didStartActiveSession {
            meetingRecordingHotkeyMonitor.cancelToggleMode()
        }
        syncAppState()
        syncDictationRecorderWarmup(intent: .idlePrewarm(.meetingStateChanged))
        reconcileTranscriptionActivityUI()
    }

    private func cancelMeetingRecordingHotkeyToggleAfterFailedStart(meetingID: Int64) {
        guard meetingStartMeetingID == meetingID else { return }
        guard activeMeetingID != meetingID || activeMeetingSession == nil else { return }
        meetingRecordingHotkeyMonitor.cancelToggleMode()
    }

    private func startMeetingRecordingWithSystemAudioRecovery(
        title: String,
        calendarEventID: String?,
        meetingID: Int64,
        backend: BackendOption,
        config meetingConfig: AppConfig,
        templateSnapshot: MeetingTemplateSnapshot,
        presentation: MeetingStartPresentation = .backgroundPill,
        endDate: Date?,
        previousMeetingNotes: String? = nil
    ) async throws {
        var shouldRetryAfterPermissionRequest = meetingConfig.useCoreAudioTap
        statusBarController?.setStatus("Meeting transcription will start shortly.")
        statusBarController?.refresh()
        try Task.checkCancellation()
        try await transcriptionCoordinator.preloadRequired(
            backend: backend,
            enablePostProcessor: false,
            includeMeetingHelpers: true,
            meetingHelperTrigger: .meetingStart,
            appleSpeechLanguage: config.resolvedAppleSpeechLanguage
        )
        try Task.checkCancellation()
        try checkMeetingStartStillCurrent(meetingID)

        while true {
            try Task.checkCancellation()
            try checkMeetingStartStillCurrent(meetingID)
            let routeSnapshot = dictationAudioRoutingController.meetingInputRouteSnapshot()
            let meetingMicRecorder = RouteAwareMeetingMicRecorder(
                routeSnapshotProvider: { routeSnapshot }
            )
            meetingMicRecorder.preferredInputDeviceID = routeSnapshot.preferredInputDeviceID
            let meetingSession = MeetingSession(
                title: title,
                calendarEventID: calendarEventID,
                backend: backend,
                runtime: runtime,
                config: meetingConfig,
                templateSnapshot: templateSnapshot,
                transcriptionCoordinator: transcriptionCoordinator,
                meetingMicRecorder: meetingMicRecorder,
                sessionTrace: meetingSessionTraces[meetingID]
            )
            let transcriptGeneration = UUID()
            meetingSession.previousMeetingNotes = previousMeetingNotes
            // Silent-mic failover needs current device names and IDs, not the
            // snapshot taken at meeting start. Reading the routing controller's
            // cache is lock-only work, so it is safe off the main actor.
            meetingSession.meetingInputRouteProvider = { [routeController = dictationAudioRoutingController] in
                routeController.meetingInputRouteSnapshot()
            }

            do {
                preparingMeetingSession = meetingSession
                defer {
                    if preparingMeetingSession === meetingSession {
                        preparingMeetingSession = nil
                    }
                }
                meetingSession.manualNotesProvider = { [weak self] in
                    await MainActor.run {
                        guard let self else { return nil }
                        return self.manualNotesForLiveMeeting(id: meetingID)
                    }
                }
                meetingSession.liveTitleProvider = { [weak self] in
                    await MainActor.run {
                        guard let self else { return nil }
                        return self.liveMeetingTitle(id: meetingID)
                    }
                }
                meetingSession.onChunkTranscribed = { [weak self, weak meetingSession] segments, speaker in
                    Task { @MainActor [weak self, weak meetingSession] in
                        guard let self else { return }
                        guard self.isCurrentLiveMeetingTranscriptSession(
                            ownerID: meetingID,
                            generation: transcriptGeneration
                        ) else { return }
                        let liveTranscriptStart = meetingSession?.startTime ?? Date()
                        let liveTranscriptCalendar = Calendar(identifier: .gregorian)
                        let entries = segments.compactMap { segment -> LiveTranscriptCheckpointEntry? in
                            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return nil }
                            let timestampDate = liveTranscriptStart.addingTimeInterval(segment.start)
                            let components = liveTranscriptCalendar.dateComponents([.hour, .minute, .second], from: timestampDate)
                            let timestamp = String(
                                format: "%02d:%02d:%02d",
                                components.hour ?? 0,
                                components.minute ?? 0,
                                components.second ?? 0
                            )
                            return LiveTranscriptCheckpointEntry(
                                timestampLabel: timestamp,
                                speaker: speaker,
                                startSeconds: segment.start,
                                endSeconds: segment.end,
                                text: text
                            )
                        }
                        guard !entries.isEmpty else { return }
                        do {
                            try self.dictationStore.appendLiveTranscriptCheckpoints(meetingID: meetingID, entries: entries)
                        } catch {
                            fputs("[muesli-native] failed to checkpoint live transcript for meeting \(meetingID): \(error)\n", stderr)
                        }
                        // Live view is arrival-order closed captions. Recovery reads checkpoints sorted
                        // by segment timestamps, so the durable fallback stays temporally ordered.
                        let lines = entries.map { "[\($0.timestampLabel)] \($0.speaker): \($0.text)" }
                        self.appState.liveMeetingTranscript += lines.joined(separator: "\n") + "\n"
                        self.meetingRecordingPanel.updateMeetingTranscript(
                            transcript: self.appState.liveMeetingTranscript,
                            partialYou: self.appState.liveMeetingPartialYou,
                            partialOthers: self.appState.liveMeetingPartialOthers
                        )
                    }
                }
                meetingSession.onPartialTranscript = { [weak self] speaker, tail in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.isCurrentLiveMeetingTranscriptSession(
                            ownerID: meetingID,
                            generation: transcriptGeneration
                        ) else { return }
                        if speaker == "You" {
                            guard self.appState.liveMeetingPartialYou != tail else { return }
                            self.appState.liveMeetingPartialYou = tail
                        } else {
                            guard self.appState.liveMeetingPartialOthers != tail else { return }
                            self.appState.liveMeetingPartialOthers = tail
                        }
                        self.meetingRecordingPanel.updateMeetingTranscript(
                            transcript: self.appState.liveMeetingTranscript,
                            partialYou: self.appState.liveMeetingPartialYou,
                            partialOthers: self.appState.liveMeetingPartialOthers
                        )
                    }
                }
                appState.liveMeetingTranscriptOwnerID = meetingID
                liveMeetingTranscriptGeneration = transcriptGeneration
                appState.liveMeetingTranscript = ""
                appState.liveMeetingPartialYou = ""
                appState.liveMeetingPartialOthers = ""
                meetingRecordingPanel.updateMeetingTranscript(
                    transcript: "",
                    partialYou: "",
                    partialOthers: ""
                )
                // Carry the pre-resume transcript so panel chat sees the whole meeting, not
                // just what this session recorded. Empty for a fresh meeting.
                let priorTranscriptForChat = (try? dictationStore.meeting(id: meetingID))?.displayTranscript ?? ""
                let meetingChatContext = FloatingMeetingChatContext(
                    meetingID: meetingID,
                    priorTranscript: priorTranscriptForChat,
                    currentConfig: { [weak self] in self?.config ?? AppConfig() },
                    isReady: { [weak self] in self?.isMeetingChatReady ?? false },
                    // Through the live cache, not the row: while the meeting runs the
                    // cache is the freshest copy (persistence is debounced) and it
                    // avoids hydrating the growing row on every read.
                    manualNotes: { [weak self] in
                        self?.manualNotesForLiveMeeting(id: meetingID) ?? ""
                    },
                    saveManualNotes: { [weak self] notes in
                        self?.cacheMeetingManualNotes(id: meetingID, notes: notes)
                    }
                )
                let micHealthWarningLock = NSLock()
                var lastForwardedMicHealthWarning: String?
                // Authorize this session's episode telemetry for its whole
                // lifetime, including the terminal event emitted after the
                // active-meeting identity has moved on during stop/discard.
                micEpisodeTelemetryGate.authorize(meetingID)
                meetingSession.onMicHealthChanged = { [weak self] snapshot in
                    let warningMessage = snapshot.warningMessage
                    micHealthWarningLock.lock()
                    let shouldForward = warningMessage != lastForwardedMicHealthWarning
                    lastForwardedMicHealthWarning = warningMessage
                    micHealthWarningLock.unlock()
                    guard shouldForward else { return }
                    Task { @MainActor in
                        guard let self,
                              self.activeMeetingID == meetingID || self.meetingStartMeetingID == meetingID else { return }
                        self.updateActiveMeetingAudioWarning(meetingID: meetingID, health: snapshot)
                    }
                }
                // Episode-level telemetry replaces per-flap error events:
                // exactly one degraded/recovered signal pair per degradation
                // episode, and an error only when the meeting ends unrecovered.
                meetingSession.onMicHealthUserMuted = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.micEpisodeTelemetryGate.allows(meetingID) else { return }
                        TelemetryDeck.signal(MeetingMicHealthEpisodeKind.userMuted.rawValue, parameters: [:])
                    }
                }
                meetingSession.onSystemAudioHealthEpisode = { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.micEpisodeTelemetryGate.allows(meetingID) else { return }
                        let parameters: [String: String] = [
                            "reason": event.reason,
                            "duration_ms": String(Int(event.durationSeconds * 1000)),
                            "recovery_attempts": String(event.recoveryAttempts),
                        ]
                        switch event.kind {
                        case .degraded, .recovered:
                            TelemetryDeck.signal(event.kind.rawValue, parameters: parameters)
                        case .unrecovered:
                            TelemetryDeck.signal(event.kind.rawValue, parameters: parameters)
                            self.recordDiagnosticIncident(
                                kind: .meetingSystemAudioCaptureFailed,
                                severity: .warning,
                                stage: .meetingSystemAudioCapture,
                                promptUser: false
                            )
                        }
                    }
                }
                meetingSession.onMicHealthEpisode = { [weak self] event in
                    Task { @MainActor in
                        guard let self else { return }
                        // Terminal events legitimately arrive while the meeting
                        // is stopping: stopMeetingRecording clears
                        // activeMeetingID before MeetingSession.stop() runs, so
                        // also accept the most recently stopped meeting.
                        guard self.micEpisodeTelemetryGate.allows(meetingID) else { return }
                        var parameters: [String: String] = [
                            "episode_id": event.episodeID.uuidString,
                            "reason": event.reason,
                            "state": event.state,
                            "duration_ms": String(Int(event.durationSeconds * 1000)),
                            "flap_count": String(event.flapCount),
                            "recovery_attempts": String(event.recoveryAttempts),
                            "handoff_promotions": String(event.handoffPromotions),
                            "recovery_credited": String(event.recoveryCredited),
                        ]
                        if let outcome = event.lastHandoffOutcome {
                            parameters["last_handoff_outcome"] = outcome.rawValue
                        }
                        if let recorderKind = event.context.recorderKind {
                            parameters["recorder_kind"] = recorderKind
                        }
                        if let routeCategory = event.context.routeCategory {
                            parameters["route_category"] = routeCategory
                        }
                        if let resolved = event.context.selectedInputResolved {
                            parameters["selected_input_resolved"] = String(resolved)
                        }
                        switch event.kind {
                        case .degraded, .recovered:
                            TelemetryDeck.signal(event.kind.rawValue, parameters: parameters)
                        case .unrecovered:
                            // Rich episode signal with full classification, plus
                            // the legacy error incident for dashboard continuity.
                            TelemetryDeck.signal(event.kind.rawValue, parameters: parameters)
                            self.recordDiagnosticIncident(
                                kind: .meetingMicrophoneCaptureFailed,
                                severity: .warning,
                                stage: .meetingMicrophoneCapture,
                                promptUser: false
                            )
                        case .userMuted:
                            // Emitted via onMicHealthUserMuted, not the episode
                            // stream; nothing to do here.
                            break
                        }
                    }
                }
                meetingSession.onSystemAudioCaptureFailure = { [weak self] error in
                    Task { @MainActor in
                        guard let self,
                              self.activeMeetingID == meetingID || self.meetingStartMeetingID == meetingID else { return }
                        self.updateActiveMeetingSystemAudioFailure(meetingID: meetingID)
                        self.recordDiagnosticIncident(
                            kind: .meetingSystemAudioCaptureFailed,
                            severity: .warning,
                            stage: .meetingSystemAudioCapture,
                            error: error,
                            promptUser: false
                        )
                    }
                }
                meetingSession.onSystemAudioCaptureRecovered = { [weak self] in
                    Task { @MainActor in
                        guard let self,
                              self.activeMeetingID == meetingID || self.meetingStartMeetingID == meetingID else { return }
                        self.updateActiveMeetingSystemAudioRecovery(meetingID: meetingID)
                    }
                }
                try await meetingSession.start()
                if Task.isCancelled || canceledMeetingStartIDs.contains(meetingID) {
                    throw CancellationError()
                }
                activeMeetingSession = meetingSession
                activeMeetingID = meetingID
                let meetingStartedAt = meetingSession.startTime ?? Date()
                armMeetingDurationLimit(meetingID: meetingID, startedAt: meetingStartedAt)
                activeMeetingAutoStop.markRecordingStarted(now: Date())
                meetingMonitor.suppressWhileActive()
                meetingMonitor.refreshState()
                statusBarController?.setStatus("Meeting: \(title)")
                let panelOwnerID = UUID()
                activeMeetingPanelOwnerID = panelOwnerID
                // The compact controller becomes visible only after capture is live, so
                // asynchronous start failures can never strand an empty recording panel.
                meetingRecordingPanel.showRecording(
                    ownerID: panelOwnerID,
                    startedAt: meetingStartedAt,
                    powerProvider: { [weak meetingSession] in
                        meetingSession?.currentPower() ?? -160
                    },
                    chatContext: meetingChatContext,
                    presentation: presentation
                )
                statusBarController?.refresh()
                syncAppState()
                scheduleMeetingEndNotification(endDate: endDate, title: title)
                return
            } catch {
                clearLiveMeetingTranscript(ownerID: meetingID, generation: transcriptGeneration)
                meetingSession.discard()
                guard shouldRetryAfterPermissionRequest,
                      case .tapCreationFailed = error as? CoreAudioSystemRecorder.RecorderError else {
                    throw error
                }

                shouldRetryAfterPermissionRequest = false
                try Task.checkCancellation()
                try checkMeetingStartStillCurrent(meetingID)
                updateMeetingStartStatus("Requesting system audio permission...")
                statusBarController?.setStatus("Requesting system audio permission...")
                statusBarController?.refresh()
                let granted = await CoreAudioSystemRecorder.requestSystemAudioAccess()
                try Task.checkCancellation()
                try checkMeetingStartStillCurrent(meetingID)
                if granted {
                    updateMeetingStartStatus("Retrying meeting start...")
                    statusBarController?.setStatus("Retrying meeting start...")
                    statusBarController?.refresh()
                    continue
                }
                throw error
            }
        }
    }

    private func checkMeetingStartStillCurrent(_ meetingID: Int64) throws {
        if canceledMeetingStartIDs.contains(meetingID) || meetingStartMeetingID != meetingID {
            throw CancellationError()
        }
    }

    /// Open meeting URL, start transcription, schedule end notification, and suppress detection.
    /// Single entry point for "Join & Transcribe" from both notification panel and Coming Up section.
    func joinAndRecord(
        title: String,
        meetingURL: URL,
        endDate: Date?,
        calendarOccurrence: CalendarOccurrenceReference? = nil,
        presentation: MeetingStartPresentation = .foregroundNotes
    ) {
        NSWorkspace.shared.open(meetingURL)
        startMeetingRecordingFromEntryPoint(
            title: title,
            calendarOccurrence: calendarOccurrence,
            endDate: endDate,
            autoStopSource: MeetingAutoStopSource(meetingURL: meetingURL),
            presentation: presentation,
            startOrigin: .joinAndRecord
        )
    }

    /// Start transcription without opening the meeting URL — for people who join calls in
    /// a separate browser or client.
    /// Single entry point for "Transcribe Only" from both notification panel and Coming Up section.
    func recordOnly(
        title: String,
        meetingURL: URL?,
        endDate: Date?,
        calendarOccurrence: CalendarOccurrenceReference? = nil,
        presentation: MeetingStartPresentation = .foregroundNotes
    ) {
        startMeetingRecordingFromEntryPoint(
            title: title,
            calendarOccurrence: calendarOccurrence,
            endDate: endDate,
            autoStopSource: meetingURL.flatMap { MeetingAutoStopSource(meetingURL: $0) },
            presentation: presentation,
            startOrigin: .scheduledMeetingPrompt
        )
    }

    /// Open meeting URL and suppress detection for the event duration.
    /// Single entry point for "Join Only" from both notification panel and Coming Up section.
    func joinOnly(meetingURL: URL, endDate: Date?) {
        let remaining = endDate.map { max($0.timeIntervalSinceNow, 120) } ?? 120
        meetingMonitor.suppress(for: remaining)
        meetingMonitor.refreshState()
        NSWorkspace.shared.open(meetingURL)
    }

    enum MeetingDiscardResolution: Equatable {
        case discardRecording
        case keepManualNotes
        case deleteDraft
    }

    private struct MeetingDiscardAccessory {
        let view: NSView
        let manualNotesCheckbox: NSButton
    }

    private final class MeetingDiscardAccessoryView: NSView {
        var titleUpdater: AnyObject?
    }

    private final class MeetingDiscardButtonTitleUpdater: NSObject {
        weak var discardButton: NSButton?

        init(discardButton: NSButton?) {
            self.discardButton = discardButton
        }

        @MainActor @objc func manualNotesCheckboxChanged(_ sender: NSButton) {
            discardButton?.title = sender.state == .on ? "Discard" : "Discard Recording"
        }
    }

    @objc func discardMeetingWithConfirmation() {
        confirmDiscardMeeting(ownerID: activeMeetingPanelOwnerID)
    }

    /// The floating object passes the owner it was showing: a confirmation the user leaves open
    /// while that meeting stops must never discard the recording that replaced it.
    func confirmDiscardMeeting(ownerID: UUID?) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        let hasManualNotes = activeMeetingID.map { id in
            !manualNotesForLiveMeeting(id: id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        alert.messageText = "Discard recording?"
        alert.alertStyle = .warning
        var manualNotesCheckbox: NSButton?
        if hasManualNotes {
            alert.informativeText = "This will stop the meeting. Choose whether to delete the written notes too."
            let accessory = Self.makeDiscardMeetingAccessoryView()
            manualNotesCheckbox = accessory.manualNotesCheckbox
            alert.accessoryView = accessory.view
            alert.addButton(withTitle: "Discard Recording")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            let titleUpdater = MeetingDiscardButtonTitleUpdater(discardButton: alert.buttons.first)
            manualNotesCheckbox?.target = titleUpdater
            manualNotesCheckbox?.action = #selector(MeetingDiscardButtonTitleUpdater.manualNotesCheckboxChanged(_:))
            (accessory.view as? MeetingDiscardAccessoryView)?.titleUpdater = titleUpdater
        } else {
            alert.informativeText = "This will stop the meeting recording and delete all captured audio. This cannot be undone."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
        }
        presentDiscardMeetingAlert(alert, manualNotesCheckbox: manualNotesCheckbox, ownerID: ownerID)
    }

    private static func makeDiscardMeetingAccessoryView() -> MeetingDiscardAccessory {
        let label = NSTextField(labelWithString: "Will delete:")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor

        let recordingCheckbox = NSButton(checkboxWithTitle: "Recording audio", target: nil, action: nil)
        recordingCheckbox.state = .on
        recordingCheckbox.isEnabled = false

        let notesCheckbox = NSButton(checkboxWithTitle: "Manual notes", target: nil, action: nil)
        notesCheckbox.state = .off

        let container = MeetingDiscardAccessoryView(frame: NSRect(x: 0, y: 0, width: 230, height: 76))
        let stack = NSStackView(views: [label, recordingCheckbox, notesCheckbox])
        stack.frame = container.bounds
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.autoresizingMask = [.width, .height]
        container.addSubview(stack)
        return MeetingDiscardAccessory(view: container, manualNotesCheckbox: notesCheckbox)
    }

    private func presentDiscardMeetingAlert(
        _ alert: NSAlert,
        manualNotesCheckbox: NSButton?,
        ownerID: UUID?,
        attempt: Int = 0
    ) {
        if let window = confirmationAnchorWindow() {
            beginDiscardMeetingAlert(alert, for: window, manualNotesCheckbox: manualNotesCheckbox, ownerID: ownerID)
            return
        }

        showActiveMeetingDocumentIfNeeded()
        historyWindowController?.show()
        if let window = confirmationAnchorWindow() {
            beginDiscardMeetingAlert(alert, for: window, manualNotesCheckbox: manualNotesCheckbox, ownerID: ownerID)
            return
        }

        guard attempt < 20 else {
            NSLog("Unable to present discard meeting confirmation: no anchor window became available")
            NSSound.beep()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, alert] in
            self?.presentDiscardMeetingAlert(
                alert,
                manualNotesCheckbox: manualNotesCheckbox,
                ownerID: ownerID,
                attempt: attempt + 1
            )
        }
    }

    private func beginDiscardMeetingAlert(
        _ alert: NSAlert,
        for window: NSWindow,
        manualNotesCheckbox: NSButton?,
        ownerID: UUID?
    ) {
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let resolution = Self.discardResolution(
                for: response,
                deleteManualNotes: manualNotesCheckbox.map { $0.state == .on }
            ) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Self.shouldApplyDiscard(
                    alertOwnerID: ownerID,
                    activeOwnerID: self.activeMeetingPanelOwnerID
                ) else { return }
                self.discardMeetingRecording(resolution: resolution)
            }
        }
    }

    /// Whether a discard the user confirmed still applies to the recording it was raised for.
    ///
    /// A confirmation left open while its meeting ends would otherwise discard whatever
    /// recording replaced it. An alert raised without an owner (the menu path, which has no
    /// panel behind it) is not owner-scoped and always applies.
    static func shouldApplyDiscard(alertOwnerID: UUID?, activeOwnerID: UUID?) -> Bool {
        guard let alertOwnerID else { return true }
        return alertOwnerID == activeOwnerID
    }

    static func discardResolution(for response: NSApplication.ModalResponse, deleteManualNotes: Bool?) -> MeetingDiscardResolution? {
        guard response == .alertFirstButtonReturn else { return nil }
        if let deleteManualNotes {
            return deleteManualNotes ? .deleteDraft : .keepManualNotes
        }
        return .discardRecording
    }

    private func confirmationAnchorWindow() -> NSWindow? {
        NSApp.windows.first { window in
            isUsableSheetHost(window, allowPanel: false)
        } ?? NSApp.windows.first { window in
            isUsableSheetHost(window, allowPanel: true)
        }
    }

    private func isUsableSheetHost(_ window: NSWindow, allowPanel: Bool) -> Bool {
        window.isVisible &&
            !window.isMiniaturized &&
            window.canBecomeKey &&
            (allowPanel || !(window is NSPanel))
    }

    private func discardMeetingRecording(resolution: MeetingDiscardResolution = .discardRecording) {
        meetingRecordingHotkeyMonitor.cancelToggleMode()
        clearLiveMeetingTranscript()
        guard let sessionToDiscard = activeMeetingSession else {
            // Fallback recovery: reset the matching meeting controller if session is nil.
            guard !isStartingMeetingRecording else { return }
            disarmMeetingAutoStop()
            cancelMeetingDurationLimit()
            if let activeMeetingPanelOwnerID {
                closeMeetingRecordingPanel(ownerID: activeMeetingPanelOwnerID)
                self.activeMeetingPanelOwnerID = nil
            }
            if let meetingID = activeMeetingID {
                micEpisodeTelemetryGate.authorize(meetingID)
                activeMeetingID = nil
                if activeMeetingAudioWarning?.meetingID == meetingID {
                    activeMeetingAudioWarning = nil
                }
                resolveLiveMeetingAfterDiscard(id: meetingID, resolution: resolution)
            } else {
                finishDiscardMeetingRecording()
            }
            return
        }
        sessionToDiscard.discard()
        disarmMeetingAutoStop()
        cancelMeetingDurationLimit()
        self.activeMeetingSession = nil
        if let activeMeetingPanelOwnerID {
            closeMeetingRecordingPanel(ownerID: activeMeetingPanelOwnerID)
            self.activeMeetingPanelOwnerID = nil
        }
        if let meetingID = activeMeetingID {
            // Preserve identity for episode terminal telemetry emitted by the
            // discarding session (it hops to the main actor asynchronously).
            micEpisodeTelemetryGate.authorize(meetingID)
            activeMeetingID = nil
            if activeMeetingAudioWarning?.meetingID == meetingID {
                activeMeetingAudioWarning = nil
            }
            resolveLiveMeetingAfterDiscard(id: meetingID, resolution: resolution)
        } else {
            finishDiscardMeetingRecording()
        }
    }

    private func finishDiscardMeetingRecording() {
        isStoppingMeetingRecording = false
        syncMeetingDetectionMonitor()
        endMeetingActivity()
        meetingMonitor.resumeAfterCooldown()
        meetingMonitor.refreshState()
        setState(.idle)
        statusBarController?.refresh()
        syncAppState()
        updateMeetingNotificationVisibility()
        syncDictationRecorderWarmup(intent: .idlePrewarm(.meetingStateChanged))
    }

    private func resolveLiveMeetingAfterDiscard(id: Int64, resolution: MeetingDiscardResolution) {
        if restoreResumedMeetingIfNeeded(id: id) {
            finishDiscardMeetingRecording()
            return
        }

        switch resolution {
        case .keepManualNotes:
            keepManualNotesAfterDiscard(id: id)
        case .deleteDraft:
            deleteManualNotesDraftAfterDiscard(id: id)
        case .discardRecording:
            let manualNotes = manualNotesForLiveMeeting(id: id)
            if manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                deleteManualNotesDraftAfterDiscard(id: id)
            } else {
                // Defensive fallback: the UI routes manual-note meetings through
                // explicit Keep Notes/Delete Draft choices. If notes appear after
                // the simpler discard alert was built, preserve user-written text.
                keepManualNotesAfterDiscard(id: id)
            }
        }
        finishDiscardMeetingRecording()
    }

    private func deleteManualNotesDraftAfterDiscard(id: Int64) {
        deleteMeetingDraftAndScheduleSync(id: id)
        clearCachedMeetingManualNotes(id: id)
        clearCachedMeetingTitle(id: id)
        if appState.selectedMeetingID == id {
            appState.selectedMeetingID = nil
            appState.selectedMeetingRecord = nil
            appState.meetingsNavigationState = .browser
        }
    }

    private func keepManualNotesAfterDiscard(id: Int64) {
        flushCachedMeetingTitle(id: id)
        flushCachedMeetingManualNotes(id: id, sync: false)
        updateMeetingStatusAndScheduleSync(id: id, status: .noteOnly)
        clearCachedMeetingManualNotes(id: id)
        clearCachedMeetingTitle(id: id)
    }

    /// If `id` is a resume in flight, restore it to its prior `.completed` state
    /// instead of deleting/failing it — the meeting pre-existed and must not be lost.
    /// Returns true when it handled the meeting.
    @discardableResult
    private func restoreResumedMeetingIfNeeded(id: Int64) -> Bool {
        let hadPendingResume = pendingResumePriorTranscript[id] != nil
        do {
            let restored = try dictationStore.restoreResumedMeetingIfNeeded(id: id)
            guard restored || hadPendingResume else { return false }
            if restored {
                scheduleICloudSyncAfterLocalChange()
            } else {
                updateMeetingStatusAndScheduleSync(id: id, status: .completed)
            }
        } catch {
            fputs("[muesli-native] failed to restore resumed meeting \(id): \(error)\n", stderr)
            guard hadPendingResume else { return false }
            updateMeetingStatusAndScheduleSync(id: id, status: .completed)
        }
        pendingResumePriorTranscript[id] = nil
        if activeMeetingID == id {
            activeMeetingID = nil
        }
        if activeMeetingAudioWarning?.meetingID == id {
            activeMeetingAudioWarning = nil
        }
        syncAppState()
        return true
    }

    private func resolveLiveMeetingAfterStartFailure(id: Int64) {
        if restoreResumedMeetingIfNeeded(id: id) { return }
        let manualNotes = manualNotesForLiveMeeting(id: id)
        if manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deleteMeetingDraftAndScheduleSync(id: id)
            clearCachedMeetingManualNotes(id: id)
            clearCachedMeetingTitle(id: id)
            if appState.selectedMeetingID == id {
                appState.selectedMeetingID = nil
                appState.selectedMeetingRecord = nil
                appState.meetingsNavigationState = .browser
            }
        } else {
            flushCachedMeetingTitle(id: id)
            flushCachedMeetingManualNotes(id: id, sync: false)
            updateMeetingStatusAndScheduleSync(id: id, status: .failed)
            clearCachedMeetingManualNotes(id: id)
            clearCachedMeetingTitle(id: id)
        }
        if activeMeetingID == id {
            activeMeetingID = nil
        }
        if activeMeetingAudioWarning?.meetingID == id {
            activeMeetingAudioWarning = nil
        }
        syncAppState()
    }

    private func resolveLiveMeetingAfterStopFailure(id: Int64) {
        if restoreResumedMeetingIfNeeded(id: id) { return }
        let manualNotes = manualNotesForLiveMeeting(id: id)
        if manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deleteMeetingDraftAndScheduleSync(id: id)
            clearCachedMeetingManualNotes(id: id)
            clearCachedMeetingTitle(id: id)
            if appState.selectedMeetingID == id {
                appState.selectedMeetingID = nil
                appState.selectedMeetingRecord = nil
                appState.meetingsNavigationState = .browser
            }
        } else {
            flushCachedMeetingTitle(id: id)
            flushCachedMeetingManualNotes(id: id, sync: false)
            updateMeetingStatusAndScheduleSync(id: id, status: .failed)
            clearCachedMeetingManualNotes(id: id)
            clearCachedMeetingTitle(id: id)
        }
        if activeMeetingAudioWarning?.meetingID == id {
            activeMeetingAudioWarning = nil
        }
        syncAppState()
    }

    private func deleteMeetingDraftAndScheduleSync(id: Int64) {
        do {
            try dictationStore.deleteMeeting(id: id)
            scheduleICloudSyncAfterLocalChange()
        } catch {
            fputs("[muesli-native] failed to delete meeting draft \(id): \(error)\n", stderr)
        }
    }

    private func updateMeetingStatusAndScheduleSync(id: Int64, status: MeetingStatus) {
        do {
            try updateMeetingStatusAndScheduleSyncThrowing(id: id, status: status)
        } catch {
            fputs("[muesli-native] failed to update meeting \(id) status to \(status.rawValue): \(error)\n", stderr)
        }
    }

    private func updateMeetingStatusAndScheduleSyncThrowing(id: Int64, status: MeetingStatus) throws {
        try dictationStore.updateMeetingStatus(id: id, status: status)
        scheduleICloudSyncAfterLocalChange()
    }

    func openManualDiagnosticReport() {
        diagnosticIncidentReporter.recordManualReport()
    }

    func setAutomaticDiagnosticIssuePrompts(_ enabled: Bool) {
        updateConfig { $0.enableAutomaticDiagnosticIssuePrompts = enabled }
        if !enabled,
           let pending = appState.pendingDiagnosticIncident,
           pending.kind != .manualReport {
            diagnosticIncidentReporter.dismissCurrentPrompt()
        }
    }

    func dismissDiagnosticIncidentPrompt() {
        diagnosticIncidentReporter.dismissCurrentPrompt()
    }

    func openDiagnosticIncidentIssue(_ incident: DiagnosticIncident) {
        let url = incident.githubIssueURL ?? DiagnosticIncident.githubIssueFallbackURL
        diagnosticIncidentReporter.dismissCurrentPrompt()
        DispatchQueue.main.async {
            guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
                NSWorkspace.shared.open(url)
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration) { _, error in
                if let error {
                    fputs("[muesli-native] failed to open diagnostic issue URL with activation: \(error)\n", stderr)
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @discardableResult
    private func recordDiagnosticIncident(
        kind: DiagnosticIncidentKind,
        severity: DiagnosticIncidentSeverity = .error,
        stage: DiagnosticIncidentStage,
        backend: BackendOption? = nil,
        error: Error? = nil,
        promptUser: Bool = true
    ) -> DiagnosticIncident {
        diagnosticIncidentReporter.record(
            kind: kind,
            severity: severity,
            stage: stage,
            backend: backend,
            error: error,
            promptUser: promptUser
        )
    }

    private func updateActiveMeetingAudioWarning(meetingID: Int64, health: MeetingMicHealthSnapshot) {
        activeMeetingAudioWarningState.updateMicrophone(message: health.warningMessage)
        let nextWarning = activeMeetingAudioWarningState.resolvedWarning(meetingID: meetingID)
        guard activeMeetingAudioWarning != nextWarning else { return }
        activeMeetingAudioWarning = nextWarning
        syncAppState()
    }

    private func updateActiveMeetingSystemAudioFailure(meetingID: Int64) {
        activeMeetingAudioWarningState.recordSystemAudioFailure(
            message: "System audio was interrupted. Muesli is retrying automatically; other participants may be missing until capture resumes."
        )
        let nextWarning = activeMeetingAudioWarningState.resolvedWarning(meetingID: meetingID)
        guard activeMeetingAudioWarning != nextWarning else { return }
        activeMeetingAudioWarning = nextWarning
        syncAppState()
    }

    private func updateActiveMeetingSystemAudioRecovery(meetingID: Int64) {
        activeMeetingAudioWarningState.clearSystemAudioFailure()
        let nextWarning = activeMeetingAudioWarningState.resolvedWarning(meetingID: meetingID)
        guard activeMeetingAudioWarning != nextWarning else { return }
        activeMeetingAudioWarning = nextWarning
        syncAppState()
    }

    func stopMeetingRecording() {
        meetingRecordingHotkeyMonitor.cancelToggleMode()
        guard !isStoppingMeetingRecording else { return }
        guard let sessionToStop = activeMeetingSession else {
            // Fallback recovery: reset the matching meeting controller if session is nil.
            guard !isStartingMeetingRecording else { return }
            disarmMeetingAutoStop()
            cancelMeetingDurationLimit()
            if let activeMeetingID {
                let trace = meetingSessionTraces.removeValue(forKey: activeMeetingID)
                Task {
                    await trace?.fail(
                        stage: "meeting_finalization",
                        metadata: ["reason": "missing_active_session"]
                    )
                }
                resolveLiveMeetingAfterStopFailure(id: activeMeetingID)
                if activeMeetingAudioWarning?.meetingID == activeMeetingID {
                    activeMeetingAudioWarning = nil
                }
                self.activeMeetingID = nil
            }
            if let activeMeetingPanelOwnerID {
                closeMeetingRecordingPanel(ownerID: activeMeetingPanelOwnerID)
                self.activeMeetingPanelOwnerID = nil
            }
            isStoppingMeetingRecording = false
            syncMeetingDetectionMonitor()
            endMeetingActivity()
            reconcileTranscriptionActivityUI()
            return
        }
        isStoppingMeetingRecording = true
        disarmMeetingAutoStop()
        cancelMeetingDurationLimit()
        meetingEndTimer?.invalidate()
        meetingEndTimer = nil
        meetingNotification.close()
        let meetingPanelOwnerID = activeMeetingPanelOwnerID
        if let meetingPanelOwnerID {
            meetingRecordingPanel.beginFinalizing(ownerID: meetingPanelOwnerID)
        }
        let liveMeetingID = activeMeetingID
        if let liveMeetingID {
            flushCachedMeetingManualNotes(id: liveMeetingID, sync: false)
            flushCachedMeetingTitle(id: liveMeetingID)
            updateMeetingStatusAndScheduleSync(id: liveMeetingID, status: .processing)
            syncAppState()
        }
        let processingGeneration = backgroundMeetingProcessingCount + 1
        let processingID = UUID()
        setMeetingProcessingStage(
            .transcribingAudio,
            processingID: processingID,
            panelOwnerID: meetingPanelOwnerID
        )
        sessionToStop.onProgress = { [weak self] stage in
            Task { @MainActor [weak self] in
                guard let self, self.meetingProcessingStages[processingID] != nil else { return }
                self.setMeetingProcessingStage(
                    stage,
                    processingID: processingID,
                    panelOwnerID: meetingPanelOwnerID,
                    updatePresentation: !self.isMeetingRecording()
                        && !self.isStartingMeetingRecording
                        && self.backgroundMeetingProcessingCount == processingGeneration
                )
            }
        }

        // Unblock new recordings immediately — transcription runs in the background
        activeMeetingSession = nil
        if let activeMeetingID {
            micEpisodeTelemetryGate.authorize(activeMeetingID)
        }
        activeMeetingID = nil
        if let liveMeetingID, activeMeetingAudioWarning?.meetingID == liveMeetingID {
            activeMeetingAudioWarning = nil
        }
        isStoppingMeetingRecording = false
        syncMeetingDetectionMonitor()
        backgroundMeetingProcessingCount += 1
        reconcileTranscriptionActivityUI()
        meetingMonitor.resumeAfterCooldown()
        meetingMonitor.refreshState()
        syncDictationRecorderWarmup(intent: .idlePrewarm(.meetingStateChanged))

        let finalizationTaskID = UUID()
        let finalizationTask = Task { [weak self] in
            guard let self else { return }
            let sessionTrace = liveMeetingID.flatMap { self.meetingSessionTraces[$0] }
            var meetingTitle = "Meeting"
            var completedMeetingID: Int64?
            var meetingResult: MeetingSessionResult?
            var failedLiveMeetingID: Int64?
            var provisionalPersistenceResult: CompletedMeetingPersistenceResult?
            var provisionalRecordingSave: PreparedMeetingRecordingSave?
            var provisionalPriorMeetingRecord: MeetingRecord?
            var provisionalPriorMeetingRecording: RecordingArtifactReference?
            var didWinTerminal = sessionTrace == nil
            var didComplete = false
            do {
                let stopped = try await sessionToStop.stop()
                let result = await self.mergedResumeResult(for: stopped, meetingID: liveMeetingID)
                meetingResult = result
                meetingTitle = result.title
                await MainActor.run {
                    self.setMeetingProcessingStatus("Finalizing", panelOwnerID: meetingPanelOwnerID)
                }
                let recordingSaveDecision = await self.recordingSaveDecision(for: result)
                let preparedRecordingSave = await self.prepareMeetingRecordingSave(
                    for: result,
                    saveDecision: recordingSaveDecision,
                    sessionID: sessionTrace?.sessionID ?? UUID()
                )
                provisionalRecordingSave = preparedRecordingSave
                if let liveMeetingID {
                    provisionalPriorMeetingRecord = try self.dictationStore.meeting(id: liveMeetingID)
                    provisionalPriorMeetingRecording = try self.recordingArtifactStore?
                        .recordingForMeeting(id: liveMeetingID)
                }
                let persistenceResult = try await MainActor.run {
                    try self.persistCompletedMeetingResult(
                        result,
                        existingMeetingID: liveMeetingID,
                        preparedRecordingSave: preparedRecordingSave,
                        preserveRecoveryMetadata: true
                    )
                }
                provisionalPersistenceResult = persistenceResult
                await sessionTrace?.associate(meetingID: persistenceResult.meetingID)
                didWinTerminal = await sessionTrace?.claimTerminal(
                    result.usedFallback ? .fallbackSuccess : .success,
                    metadata: [
                        "history_created": "true",
                        "output_characters": String(result.rawTranscript.count),
                        "fallback_reasons": result.fallbackReasons
                            .map(\.rawValue)
                            .sorted()
                            .joined(separator: ","),
                        "summary_fallback": String(result.usedSummaryFallback),
                    ]
                ) ?? true
                if didWinTerminal {
                    await MainActor.run {
                        self.finalizeCompletedMeetingRecoveryMetadataBestEffort(
                            meetingID: persistenceResult.meetingID
                        )
                    }
                    provisionalPersistenceResult = nil
                    provisionalRecordingSave = nil
                    provisionalPriorMeetingRecord = nil
                    provisionalPriorMeetingRecording = nil
                    completedMeetingID = persistenceResult.meetingID
                    didComplete = true
                    await MainActor.run {
                        self.publishCompletedMeetingResult(
                            result,
                            persistenceResult: persistenceResult
                        )
                    }
                    if let recordingSaveError = persistenceResult.recordingSaveError {
                        await MainActor.run {
                            self.recordDiagnosticIncident(
                                kind: .meetingRecordingSaveFailed,
                                stage: .saveMeetingRecording,
                                backend: self.selectedMeetingTranscriptionBackend,
                                error: recordingSaveError
                            )
                            self.presentErrorAlert(
                                title: "Meeting Recording",
                                message: recordingSaveError.localizedDescription
                            )
                        }
                    }
                } else {
                    let didRollbackProvisionalPersistence = await MainActor.run {
                        self.rollbackProvisionalCompletedMeeting(
                            persistenceResult: persistenceResult,
                            originalMeetingID: liveMeetingID,
                            priorMeetingRecord: provisionalPriorMeetingRecord,
                            priorMeetingRecording: provisionalPriorMeetingRecording,
                            preparedRecordingSave: preparedRecordingSave
                        )
                    }
                    if !didRollbackProvisionalPersistence {
                        failedLiveMeetingID = liveMeetingID
                    }
                    provisionalPersistenceResult = nil
                    provisionalRecordingSave = nil
                }
            } catch {
                var didRollbackProvisionalPersistence = false
                if let provisionalPersistenceResult,
                   let provisionalRecordingSave {
                    didRollbackProvisionalPersistence = await MainActor.run {
                        self.rollbackProvisionalCompletedMeeting(
                            persistenceResult: provisionalPersistenceResult,
                            originalMeetingID: liveMeetingID,
                            priorMeetingRecord: provisionalPriorMeetingRecord,
                            priorMeetingRecording: provisionalPriorMeetingRecording,
                            preparedRecordingSave: provisionalRecordingSave
                        )
                    }
                }
                fputs("[muesli-native] meeting transcription failed: \(error)\n", stderr)
                await sessionTrace?.recordStageFailed("meeting_finalization")
                didWinTerminal = await sessionTrace?.claimTerminal(
                    .failed,
                    metadata: ["stage": "meeting_finalization"]
                ) ?? true
                await MainActor.run {
                    _ = self.recordDiagnosticIncident(
                        kind: .meetingProcessingFailed,
                        stage: .meetingStopProcessing,
                        backend: self.selectedMeetingTranscriptionBackend,
                        error: error
                    )
                }
                let message: String
                if let lifecycleError = error as? MeetingLifecycleError {
                    message = lifecycleError.localizedDescription
                } else {
                    message = error.localizedDescription
                }
                failedLiveMeetingID = didRollbackProvisionalPersistence ? nil : liveMeetingID
                if didWinTerminal {
                    await MainActor.run {
                        self.presentErrorAlert(title: "Meeting Recording", message: message)
                    }
                }
            }
            await MainActor.run {
                if let meetingPanelOwnerID {
                    self.closeMeetingRecordingPanel(ownerID: meetingPanelOwnerID)
                    if self.activeMeetingPanelOwnerID == meetingPanelOwnerID {
                        self.activeMeetingPanelOwnerID = nil
                    }
                }
                self.meetingFinalizationTasks.removeValue(forKey: finalizationTaskID)
                if let liveMeetingID {
                    self.meetingSessionTraces.removeValue(forKey: liveMeetingID)
                }
                self.removeMeetingProcessing(processingID: processingID)
                self.backgroundMeetingProcessingCount -= 1
                if let failedLiveMeetingID {
                    self.resolveLiveMeetingAfterStopFailure(id: failedLiveMeetingID)
                } else if let liveMeetingID {
                    // Resume merged + persisted successfully — drop the prior-transcript marker.
                    self.pendingResumePriorTranscript[liveMeetingID] = nil
                }
                self.reconcileTranscriptionActivityUI()
                self.endMeetingActivity()
                self.historyWindowController?.reload()
                self.syncAppState()
                self.clearLiveMeetingTranscript(ownerID: liveMeetingID)
                if let meetingResult {
                    self.cleanupTemporaryMeetingAudioFiles(for: meetingResult)
                }
                if didComplete {
                    TelemetryDeck.signal("meeting.completed")
                    self.enqueueOrShowMeetingCompletionNotification(
                        meetingID: completedMeetingID,
                        title: meetingTitle
                    )
                }
                self.updateMeetingNotificationVisibility()
            }
        }
        meetingFinalizationTasks[finalizationTaskID] = finalizationTask
    }

    func persistCompletedMeetingResult(
        _ result: MeetingSessionResult,
        existingMeetingID: Int64? = nil,
        preparedRecordingSave: PreparedMeetingRecordingSave,
        preserveRecoveryMetadata: Bool = false
    ) throws -> CompletedMeetingPersistenceResult {
        let meetingID: Int64
        let savedRecordingPath = preparedRecordingSave.path
        let recordingSaveError = preparedRecordingSave.error

        if let existingMeetingID {
            let persistedTitle = completedLiveMeetingTitle(for: result, existingMeetingID: existingMeetingID)
            let durationOverride = pendingResumePriorTranscript[existingMeetingID] == nil
                ? nil
                : result.durationSeconds
            try dictationStore.completeLiveMeeting(
                id: existingMeetingID,
                title: persistedTitle,
                calendarEventID: result.calendarEventID,
                startTime: result.startTime,
                endTime: result.endTime,
                durationSeconds: durationOverride,
                rawTranscript: result.rawTranscript,
                formattedNotes: result.formattedNotes,
                micAudioPath: nil,
                systemAudioPath: nil,
                savedRecordingPath: savedRecordingPath,
                selectedTemplateID: result.templateSnapshot.id,
                selectedTemplateName: result.templateSnapshot.name,
                selectedTemplateKind: result.templateSnapshot.kind,
                selectedTemplatePrompt: result.templateSnapshot.prompt,
                preserveRecoveryMetadata: preserveRecoveryMetadata,
                recording: preparedRecordingSave.recording,
                visualContext: result.visualContext
            )
            meetingID = existingMeetingID
            clearCachedMeetingManualNotes(id: existingMeetingID)
            clearCachedMeetingTitle(id: existingMeetingID)
        } else {
            meetingID = try dictationStore.insertMeeting(
                title: result.title,
                calendarEventID: result.calendarEventID,
                startTime: result.startTime,
                endTime: result.endTime,
                rawTranscript: result.rawTranscript,
                formattedNotes: result.formattedNotes,
                micAudioPath: nil,
                systemAudioPath: nil,
                savedRecordingPath: savedRecordingPath,
                selectedTemplateID: result.templateSnapshot.id,
                selectedTemplateName: result.templateSnapshot.name,
                selectedTemplateKind: result.templateSnapshot.kind,
                selectedTemplatePrompt: result.templateSnapshot.prompt,
                recording: preparedRecordingSave.recording,
                visualContext: result.visualContext
            )
        }
        return CompletedMeetingPersistenceResult(meetingID: meetingID, recordingSaveError: recordingSaveError)
    }

    /// Reverses a completed row that was persisted only to make the transcript
    /// durable before the session terminal arbiter selected its winner.
    @discardableResult
    func rollbackProvisionalCompletedMeeting(
        persistenceResult: CompletedMeetingPersistenceResult,
        originalMeetingID: Int64?,
        priorMeetingRecord: MeetingRecord?,
        priorMeetingRecording: RecordingArtifactReference? = nil,
        preparedRecordingSave: PreparedMeetingRecordingSave
    ) -> Bool {
        let meetingID = persistenceResult.meetingID
        let provisionalArtifactID = preparedRecordingSave.recording?.artifactID
        let removesProvisionalArtifact = provisionalArtifactID != nil
            && provisionalArtifactID != priorMeetingRecording?.artifactID
        if removesProvisionalArtifact, let provisionalArtifactID {
            RecordingArtifactPlaybackCoordinator.shared.beginExternalDeletion(
                artifactID: provisionalArtifactID
            )
        }
        do {
            if originalMeetingID == nil {
                _ = try dictationStore.deleteMeeting(id: meetingID)
            } else if let priorMeetingRecord {
                let restoredResume = try dictationStore.rollbackProvisionalLiveMeeting(
                    id: meetingID,
                    priorRecord: priorMeetingRecord,
                    priorRecording: priorMeetingRecording
                )
                if !restoredResume {
                    resolveLiveMeetingAfterStopFailure(id: meetingID)
                }
            } else {
                resolveLiveMeetingAfterStopFailure(id: meetingID)
            }

        } catch {
            if removesProvisionalArtifact, let provisionalArtifactID {
                Task {
                    await RecordingArtifactPlaybackCoordinator.shared
                        .restoreAfterSharedOwnerRemoval(artifactID: provisionalArtifactID)
                }
            }
            fputs("[muesli-native] failed to roll back provisional meeting \(meetingID): \(error)\n", stderr)
            return false
        }

        if removesProvisionalArtifact, let provisionalArtifactID {
            finishDurableRecordingDeletion(provisionalArtifactID)
        }
        clearCachedMeetingManualNotes(id: meetingID)
        clearCachedMeetingTitle(id: meetingID)
        return true
    }

    private func finalizeCompletedMeetingRecoveryMetadataBestEffort(meetingID: Int64) {
        do {
            try dictationStore.finalizeCompletedMeetingRecoveryMetadata(id: meetingID)
        } catch {
            fputs(
                "[muesli-native] completed meeting \(meetingID) retained retryable recovery metadata: \(error)\n",
                stderr
            )
        }
    }

    private func liveMeetingTitle(id: Int64) -> String? {
        if let cached = liveMeetingTitleCache[id] {
            return cached
        }
        return try? dictationStore.meeting(id: id)?.title
    }

    private func activeMeetingDisplayTitle() -> String {
        guard let activeMeetingID,
              let title = liveMeetingTitle(id: activeMeetingID)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return "Meeting"
        }
        return title
    }

    private func completedLiveMeetingTitle(for result: MeetingSessionResult, existingMeetingID: Int64) -> String {
        guard let liveTitle = liveMeetingTitle(id: existingMeetingID)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !liveTitle.isEmpty,
              liveTitle != result.originalTitle.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return result.title
        }
        return liveTitle
    }

    func persistCompletedMeetingResultAndDispatchHook(
        _ result: MeetingSessionResult,
        existingMeetingID: Int64? = nil,
        preparedRecordingSave: PreparedMeetingRecordingSave
    ) throws -> CompletedMeetingPersistenceResult {
        let persistenceResult = try persistCompletedMeetingResult(
            result,
            existingMeetingID: existingMeetingID,
            preparedRecordingSave: preparedRecordingSave
        )
        publishCompletedMeetingResult(result, persistenceResult: persistenceResult)
        return persistenceResult
    }

    private func publishCompletedMeetingResult(
        _ result: MeetingSessionResult,
        persistenceResult: CompletedMeetingPersistenceResult
    ) {
        scheduleICloudSyncAfterLocalChange()
        meetingHookDispatcher.dispatchCompletedMeetingHook(
            meetingID: persistenceResult.meetingID,
            completedAt: result.endTime,
            config: config
        )
        if config.autoExportMarkdownEnabled {
            do {
                if let record = try dictationStore.meeting(id: persistenceResult.meetingID) {
                    meetingMarkdownAutoExporter.exportIfConfigured(meeting: record, config: config)
                } else {
                    meetingMarkdownAutoExporter.recordMeetingLookupFailure(
                        meetingID: persistenceResult.meetingID,
                        error: nil
                    )
                }
            } catch {
                meetingMarkdownAutoExporter.recordMeetingLookupFailure(
                    meetingID: persistenceResult.meetingID,
                    error: error
                )
            }
        }
        try? dictationStore.storeMeetingSummaryInputs(
            id: persistenceResult.meetingID,
            visualContext: result.visualContext,
            previousMeetingNotes: result.previousMeetingNotes
        )
        scheduleMeetingTranscriptCleanup(meetingID: persistenceResult.meetingID)
    }

    /// Kicks off AI cleanup for a meeting whose transcript is already durable.
    ///
    /// Deliberately fire-and-forget and deliberately *after* persistence. The
    /// transcript is the only copy of what was said -- with a recording save policy
    /// of `never` there is no audio to re-derive it from -- so a model call must
    /// never sit between the meeting ending and that text reaching disk.
    ///
    /// Both finalization paths funnel through here: recorded meetings via
    /// `persistCompletedMeetingResultAndDispatchHook`, imports via
    /// `persistImportedAudioMeeting`. An imported Arabic recording has exactly the
    /// same cross-language damage as a recorded one.
    func scheduleMeetingTranscriptCleanup(meetingID: Int64) {
        let backend = MeetingCleanupTransport.backend(for: config)
        guard MeetingTranscriptCleanup.isEnabled(
            config: config,
            backend: backend,
            isChatGPTAuthenticated: appState.isChatGPTAuthenticated
        ) else {
            // Every component, because a silent skip here is indistinguishable from
            // a cleanup that ran and failed — the exact hole this line plugs.
            fputs(
                "[meeting-cleanup] skipped for meeting \(meetingID): "
                    + "bilingual=\(config.meetingSpokenLanguage.isBilingual) "
                    + "eligible=\(MeetingTranscriptCleanupPolicy.isEligible(backend)) "
                    + "configured=\(MeetingCleanupTransport.isConfigured(config: config, isChatGPTAuthenticated: appState.isChatGPTAuthenticated)) "
                    + "chatgptAuthFlag=\(appState.isChatGPTAuthenticated)\n",
                stderr
            )
            return
        }
        fputs("[meeting-cleanup] scheduled for meeting \(meetingID) via \(backend.backend)\n", stderr)

        let config = self.config
        let sender = meetingTranscriptCleanupSenderFactory(backend, config)
        let taskID = UUID()
        meetingTranscriptCleanupTasks[meetingID]?.task.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishMeetingTranscriptCleanup(meetingID: meetingID, taskID: taskID) }
            guard let meeting = try? self.dictationStore.meeting(id: meetingID) else { return }
            let raw = meeting.rawTranscript
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            let cleaned = await MeetingTranscriptCleanup.clean(
                transcript: raw,
                isAuthorized: { [weak self] in
                    guard let self else { return false }
                    return self.isMeetingTranscriptCleanupAuthorized(backend: backend)
                },
                send: sender
            )
            guard let cleaned else { return }

            // The guarded write drops the result if the user edited the transcript
            // while cleanup was running, which for a long meeting is minutes.
            let stored = (try? self.dictationStore.storeCleanedMeetingTranscript(
                id: meetingID,
                cleanedTranscript: cleaned,
                expectedRawTranscript: raw
            )) ?? false
            guard stored else { return }

            await MainActor.run {
                // Completion already ran its reload by now, so without this the open
                // meeting keeps showing raw text until some unrelated refresh fires.
                self.historyWindowController?.reload()
                self.syncAppState()
            }

            await self.regenerateNotesFromCleanedTranscript(meetingID: meetingID)
        }
        meetingTranscriptCleanupTasks[meetingID] = (taskID, task)
    }

    /// Rechecked before every chunk leaves the process (R12).
    ///
    /// The meeting language selection and the summary backend are both mutable
    /// while a long transcript is being processed, so authorization at scheduling
    /// time is not enough.
    private func isMeetingTranscriptCleanupAuthorized(
        backend: TranscriptCleanupBackendOption
    ) -> Bool {
        MeetingCleanupTransport.backend(for: config) == backend
            && MeetingTranscriptCleanup.isEnabled(
                config: config,
                backend: backend,
                isChatGPTAuthenticated: appState.isChatGPTAuthenticated
            )
    }

    /// What a running cleanup depends on. A change here cancels it.
    private func meetingCleanupIdentity(_ config: AppConfig) -> String? {
        guard config.meetingSpokenLanguage.isBilingual else { return nil }
        return "\(config.meetingSummaryBackend)|\(MeetingCleanupTransport.model(for: config))"
    }

    private func cancelMeetingTranscriptCleanupTasks() {
        let tasks = meetingTranscriptCleanupTasks.values.map(\.task)
        meetingTranscriptCleanupTasks.removeAll()
        tasks.forEach { $0.cancel() }
    }

    private func finishMeetingTranscriptCleanup(meetingID: Int64, taskID: UUID) {
        guard meetingTranscriptCleanupTasks[meetingID]?.id == taskID else { return }
        meetingTranscriptCleanupTasks.removeValue(forKey: meetingID)
    }

    /// Rebuilds a meeting's notes from its cleaned transcript.
    ///
    /// Reproduces the original `summarize` call argument-for-argument, substituting
    /// only the transcript. The retained visual context and predecessor notes are
    /// the point: regenerating without them would drop screen-derived detail and
    /// follow-up continuity, replacing a good summary with a worse one and showing
    /// nothing to say it happened.
    func regenerateNotesFromCleanedTranscript(meetingID: Int64) async {
        guard let meeting = try? dictationStore.meeting(id: meetingID) else { return }
        guard meeting.notesSource == .raw else { return }
        let cleaned = meeting.cleanedTranscript
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Without a usable backend the key-based paths return a raw-transcript stub as a
        // successful summary, which would replace real notes and mark them cleaned. Bailing
        // leaves notes_source at raw so the launch sweep retries once it is configured.
        guard MeetingSummaryClient.isBackendConfigured(
            config: config,
            isChatGPTAuthenticated: chatGPTAuth.isAuthenticated
        ) else { return }

        let plan = MeetingResummarizationPolicy.plan(for: meeting)
        let notes: String
        do {
            notes = try await MeetingSummaryClient.summarize(
                transcript: cleaned,
                meetingTitle: plan.promptTitle,
                config: config,
                template: meetingTemplateSnapshot(for: meeting),
                existingNotes: nil,
                manualNotesToRetain: meeting.manualNotes,
                visualContext: meeting.visualContext.flatMap { $0.isEmpty ? nil : $0 },
                previousMeetingNotes: meeting.previousMeetingNotes.isEmpty
                    ? nil
                    : meeting.previousMeetingNotes
            )
        } catch {
            // Leaves notes_source at raw, so the next launch sweep tries again.
            // Cleanup itself runs once, so without that retry a single failure would
            // strand the meeting with raw-derived notes forever.
            Self.meetingCleanupLogger.error(
                "Notes regeneration failed for meeting \(meetingID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        // Conditional on everything the summary was built from. Regeneration takes
        // seconds while the user is already reading, so all three races are live.
        let wrote = (try? dictationStore.storeRegeneratedMeetingNotes(
            id: meetingID,
            formattedNotes: notes,
            expectedCleanedTranscript: cleaned,
            expectedManualNotes: meeting.manualNotes
        )) ?? false
        guard wrote else { return }

        await MainActor.run {
            self.historyWindowController?.reload()
            self.syncAppState()
            self.scheduleICloudSyncAfterLocalChange()
        }
    }

    /// Finishes regenerations that never completed.
    ///
    /// A meeting holding a cleaned transcript whose notes are still raw-derived is
    /// a regeneration that failed or was interrupted -- the app quit between the two
    /// writes, or the summary call errored. Bounded per launch so a persistently
    /// failing meeting cannot spin.
    ///
    /// Deliberately not gated on `enableMeetingTranscriptCleanup`: the sweep sends
    /// nothing to the cleanup destination — it summarizes an already-stored cleaned
    /// transcript through the same summary backend every meeting uses, restoring
    /// notes/transcript consistency. Gating it here meant an auto-revoked consent
    /// (backend switch) stranded half-finished regenerations forever.
    func resumePendingMeetingNotesRegeneration(limit: Int = 5) {
        guard let pending = try? dictationStore.meetingsAwaitingNotesRegeneration(limit: limit),
              !pending.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            for meeting in pending {
                await self.regenerateNotesFromCleanedTranscript(meetingID: meeting.id)
            }
        }
    }

    /// For a resumed meeting, concatenates the prior transcript with the newly
    /// recorded one and regenerates the summary when new transcript content exists.
    /// Returns the stop result unchanged when this meeting is not a resume. Does not
    /// clear the pending-transcript marker — that happens on successful persist or
    /// failure restore.
    private func mergedResumeResult(
        for result: MeetingSessionResult,
        meetingID: Int64?
    ) async -> MeetingSessionResult {
        guard let meetingID,
              let prior = pendingResumePriorTranscript[meetingID] else {
            return result
        }
        let manualNotes = manualNotesForLiveMeeting(id: meetingID)
        let combined = MeetingResumePolicy.combinedResumeTranscript(
            prior: prior,
            new: result.rawTranscript
        )
        let originalMeeting = meeting(id: meetingID)
        let originalStart = originalMeeting
            .flatMap { ISO8601DateFormatter().date(from: $0.startTime) }
        let accumulatedDuration = (originalMeeting?.durationSeconds ?? 0) + result.durationSeconds
        // Persisting the resumed session's context alone would overwrite what
        // earlier sessions of this meeting captured.
        let mergedVisualContext = MeetingResumePolicy.combinedResumeVisualContext(
            prior: originalMeeting?.visualContext,
            new: result.visualContext
        )

        guard MeetingResumePolicy.hasNewTranscriptContent(prior: prior, new: result.rawTranscript) else {
            return result.overriding(
                startTime: originalStart,
                durationSeconds: accumulatedDuration,
                rawTranscript: combined,
                formattedNotes: originalMeeting?.formattedNotes ?? result.formattedNotes,
                visualContext: mergedVisualContext
            )
        }

        let regeneratedNotes: String
        let summaryConfig = Self.resumeSummaryConfig(base: config, result: result)
        do {
            regeneratedNotes = try await MeetingSummaryClient.summarize(
                transcript: combined,
                meetingTitle: result.title,
                config: summaryConfig,
                template: result.templateSnapshot,
                existingNotes: nil,
                manualNotesToRetain: manualNotes,
                visualContext: mergedVisualContext
            )
        } catch {
            fputs("[muesli-native] resume summary regeneration failed: \(error.localizedDescription)\n", stderr)
            regeneratedNotes = MeetingSummaryClient.summaryFailureNotes(
                transcript: combined,
                meetingTitle: result.title,
                error: error,
                manualNotes: manualNotes,
                languageProfile: result.languageProfile
            )
        }
        return result.overriding(
            startTime: originalStart,
            durationSeconds: accumulatedDuration,
            rawTranscript: combined,
            formattedNotes: regeneratedNotes,
            visualContext: mergedVisualContext
        )
    }

    private func meetingRecordingSavePlan(
        for result: MeetingSessionResult,
        saveDecision: Bool? = nil
    ) -> MeetingRecordingSavePlan {
        let shouldSave: Bool
        if let saveDecision {
            shouldSave = saveDecision
        } else {
            switch result.recordingSavePolicy {
            case .never:
                shouldSave = false
            case .always:
                shouldSave = true
            case .prompt:
                shouldSave = result.retainedRecordingError != nil
            }
        }

        guard shouldSave else {
            if let retainedRecordingURL = result.retainedRecordingURL {
                return .discard(tempURL: retainedRecordingURL)
            }
            return .none
        }

        if let retainedRecordingError = result.retainedRecordingError {
            return .failed(.failedToSaveRecording(underlying: retainedRecordingError))
        }

        guard let retainedRecordingURL = result.retainedRecordingURL else {
            return .none
        }

        return .save(MeetingRecordingSaveRequest(
            tempURL: retainedRecordingURL,
            meetingTitle: result.title,
            startedAt: result.startTime,
            supportDirectory: configStore.supportDirectory(),
            fileFormat: result.recordingFileFormat
        ))
    }

    func prepareMeetingRecordingSave(
        for result: MeetingSessionResult,
        saveDecision: Bool? = nil,
        sessionID: UUID = UUID()
    ) async -> PreparedMeetingRecordingSave {
        let plan = meetingRecordingSavePlan(for: result, saveDecision: saveDecision)
        let prepared = await Self.prepareMeetingRecordingSave(plan)
        guard let path = prepared.path,
              let store = recordingArtifactStore else { return prepared }
        let frozenSavePolicy: RecordingSavePolicySnapshot = switch result.recordingSavePolicy {
        case .prompt: .prompt
        case .always, .never: .always
        }
        do {
            let artifact = try await Task.detached(priority: .utility) {
                try store.adoptCapture(
                    at: URL(fileURLWithPath: path),
                    sessionID: sessionID,
                    captureKind: .meeting,
                    savePolicy: frozenSavePolicy,
                    terminalAt: result.endTime
                )
            }.value
            try? await Task.detached(priority: .utility) {
                try store.attachDiagnostic(
                    sessionID: sessionID,
                    artifactID: artifact.id,
                    availability: .available
                )
            }.value
            return PreparedMeetingRecordingSave(
                path: nil,
                error: prepared.error,
                recording: RecordingArtifactReference(
                    artifactID: artifact.id,
                    availability: .available
                )
            )
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            return PreparedMeetingRecordingSave(
                path: nil,
                error: .failedToSaveRecording(underlying: error),
                recording: RecordingArtifactReference(artifactID: nil, availability: .saveFailed)
            )
        }
    }

    private nonisolated static func prepareMeetingRecordingSave(
        _ plan: MeetingRecordingSavePlan
    ) async -> PreparedMeetingRecordingSave {
        switch plan {
        case .none:
            return PreparedMeetingRecordingSave(path: nil, error: nil)
        case .discard(let tempURL):
            try? FileManager.default.removeItem(at: tempURL)
            return PreparedMeetingRecordingSave(path: nil, error: nil)
        case .failed(let error):
            return PreparedMeetingRecordingSave(path: nil, error: error)
        case .save(let request):
            do {
                let outputURL = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
                    from: request.tempURL,
                    meetingTitle: request.meetingTitle,
                    startedAt: request.startedAt,
                    supportDirectory: request.supportDirectory,
                    fileFormat: request.fileFormat
                )
                return PreparedMeetingRecordingSave(path: outputURL.path, error: nil)
            } catch {
                return PreparedMeetingRecordingSave(
                    path: nil,
                    error: .failedToSaveRecording(underlying: error)
                )
            }
        }
    }

    private func cleanupTemporaryMeetingAudioFiles(for result: MeetingSessionResult) {
        if let retainedRecordingURL = result.retainedRecordingURL {
            try? FileManager.default.removeItem(at: retainedRecordingURL)
        }
        if let systemRecordingURL = result.systemRecordingURL {
            try? FileManager.default.removeItem(at: systemRecordingURL)
        }
    }

    private func cleanupTemporaryDirectory(named directoryName: String, logDescription: String) {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for file in files {
            try? FileManager.default.removeItem(at: file)
        }

        if !files.isEmpty {
            fputs("[muesli-native] cleaned up \(files.count) \(logDescription)\n", stderr)
        }
    }

    func cleanupHistoricalMeetingWaveformCacheFilesIfNeeded() {
        guard !config.waveformCacheOrphanCleanupMigrationApplied else { return }
        guard cleanupOrphanedMeetingWaveformCacheFiles() else { return }
        guard cleanupLegacyJSONMeetingWaveformCacheFiles() else { return }
        config.waveformCacheOrphanCleanupMigrationApplied = true
        appState.config = config
        configStore.save(config)
    }

    @discardableResult
    private func cleanupOrphanedMeetingWaveformCacheFiles() -> Bool {
        let references: [MeetingRecordingReference]
        do {
            references = try dictationStore.meetingRecordingReferences()
        } catch {
            return false
        }
        let recordingURLs = references.compactMap { savedRecordingURL(from: $0.savedRecordingPath) }
        let result = RecordingWaveformCacheFiles.sweepOrphanedCachedWaveforms(
            retainedRecordingURLs: recordingURLs,
            supportDirectory: configStore.supportDirectory()
        )
        if case .skipped = result {
            return false
        }
        return true
    }

    private func cleanupLegacyJSONMeetingWaveformCacheFiles() -> Bool {
        let result = RecordingWaveformCacheFiles.removeLegacyJSONWaveformCaches(
            supportDirectory: configStore.supportDirectory()
        )
        if case .skipped = result {
            return false
        }
        return true
    }

    private func clearSavedMeetingWaveformCache() throws {
        try RecordingWaveformCacheFiles.removeAllCachedWaveforms(
            supportDirectory: configStore.supportDirectory()
        )
    }

    private func savedRecordingURL(from path: String?) -> URL? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    @MainActor
    private func recordingSaveDecision(for result: MeetingSessionResult) async -> Bool? {
        guard result.recordingSavePolicy == .prompt else { return nil }
        guard result.retainedRecordingURL != nil, result.retainedRecordingError == nil else { return nil }
        return await promptToSaveMeetingRecording(for: result.title)
    }

    @MainActor
    private func promptToSaveMeetingRecording(for title: String) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Save meeting recording?"
        alert.informativeText = "Keep a merged audio file for \"\(title)\" so you can inspect it later in Finder."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save Recording")
        alert.addButton(withTitle: "Don't Save")
        guard let window = alertPresentationWindow(showHistoryIfNeeded: true) else {
            fputs("[muesli-native] no window available for recording save prompt; saving recording by default\n", stderr)
            return true
        }

        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    @MainActor
    private func alertPresentationWindow(showHistoryIfNeeded: Bool = true) -> NSWindow? {
        if let window = historyWindowController?.presentationWindow,
           isUsableSheetHost(window, allowPanel: false) {
            return window
        }

        if showHistoryIfNeeded {
            historyWindowController?.show()
        }

        if let window = historyWindowController?.presentationWindow,
           isUsableSheetHost(window, allowPanel: false) {
            return window
        }

        return NSApp.windows.first { window in
            isUsableSheetHost(window, allowPanel: false)
        } ?? NSApp.windows.first { window in
            isUsableSheetHost(window, allowPanel: true)
        }
    }

    @discardableResult
    private func presentAlert(
        _ alert: NSAlert,
        fallbackLogContext: String,
        completion: ((NSApplication.ModalResponse) -> Void)? = nil
    ) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = alertPresentationWindow(showHistoryIfNeeded: true) else {
            fputs(
                "[muesli-native] unable to present \(fallbackLogContext) alert: \(alert.messageText) - \(alert.informativeText)\n",
                stderr
            )
            statusBarController?.setStatus(alert.messageText)
            statusBarController?.refresh()
            NSSound.beep()
            return false
        }

        alert.beginSheetModal(for: window) { response in
            completion?(response)
        }
        return true
    }

    private func presentMeetingStartFailureAlert(error: Error) {
        let isSystemAudioError = error is CoreAudioSystemRecorder.RecorderError
        let alert = NSAlert()
        alert.alertStyle = .warning
        if isSystemAudioError {
            alert.messageText = "System audio capture failed"
            alert.informativeText = "Could not start system audio recording. Open System Settings > Privacy & Security > Screen & System Audio Recording and enable \(AppIdentity.displayName) under \"System Audio Recording Only\".\n\nError: \(error.localizedDescription)"
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "OK")
        } else {
            alert.messageText = "Meeting failed to start"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
        }

        presentAlert(alert, fallbackLogContext: "meeting start failure") { response in
            guard isSystemAudioError, response == .alertFirstButtonReturn else { return }
            CoreAudioSystemRecorder.openSystemAudioSettings()
        }
    }

    private func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        presentAlert(alert, fallbackLogContext: title)
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func noteWindowOpened() {
        openWindowCount += 1
        if NSApplication.shared.activationPolicy() != .regular {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func noteWindowClosed() {
        openWindowCount = max(0, openWindowCount - 1)
        if openWindowCount == 0 {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    private func setState(_ state: DictationState) {
        dictationState = state
        appState.dictationState = state
        let status: String
        switch state {
        case .idle: status = "Idle"
        case .preparing: status = "Preparing"
        case .recording: status = "Recording"
        case .transcribing: status = "Transcribing"
        }
        statusBarController?.setStatus(status)
    }

    /// With eager start the stream can be live before the tap/hold decision; hold the start
    /// cue until the press has outlived the tap guard so a discarded tap stays silent.
    private func playGatedDictationStartCue() {
        let guardDelay = HotkeyTriggerTiming.doubleTapTapGuardDelay
        guard let pressedAt = dictationHotkeyPressedAt else {
            // No press bookkeeping: only a session that is still live (hands-free toggle,
            // Nemotron streaming) may cue immediately. A stream that went active after the
            // hold was cancelled or stopped has nothing left to announce.
            guard dictationAudioSessionManager.hasActiveSession || isNemotron35Streaming else { return }
            SoundController.playDictationStart(enabled: true)
            return
        }
        let remaining = guardDelay - Date().timeIntervalSince(pressedAt)
        guard remaining > 0 else {
            SoundController.playDictationStart(enabled: true)
            return
        }
        let token = UUID()
        pendingStartCueToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self, self.pendingStartCueToken == token else { return }
            self.pendingStartCueToken = nil
            SoundController.playDictationStart(enabled: true)
        }
    }

    private func applyDictationLifecycleActions(_ actions: [DictationLifecycleFeedback.Action]) {
        for action in actions {
            switch action {
            case let .cue(cue):
                switch cue {
                case .start: playGatedDictationStartCue()
                case .stop: SoundController.playDictationStop(enabled: true)
                case .success: SoundController.playDictationSuccess(enabled: true)
                case .failure: SoundController.playDictationFailure(enabled: true)
                }
            case let .mini(_, presentation):
                switch presentation {
                case .preparing:
                    dictationMiniGeneration = dictationMiniIndicator.beginPreparing()
                case .recording:
                    guard let generation = dictationMiniGeneration else { continue }
                    dictationMiniIndicator.showRecording(generation: generation) { [weak self] in
                        self?.dictationAudioSessionManager.currentPower() ?? -160
                    }
                case .processing:
                    guard let generation = dictationMiniGeneration else { continue }
                    dictationMiniIndicator.showProcessing(generation: generation)
                case .success:
                    guard let generation = dictationMiniGeneration else { continue }
                    dictationMiniIndicator.showSuccess(generation: generation)
                    dictationMiniGeneration = nil
                case .failure:
                    guard let generation = dictationMiniGeneration else { continue }
                    dictationMiniIndicator.showFailure(generation: generation)
                    dictationMiniGeneration = nil
                case .hidden:
                    guard let generation = dictationMiniGeneration else { continue }
                    dictationMiniIndicator.dismiss(generation: generation)
                    dictationMiniGeneration = nil
                }
            case .showTargetChangedWithRetainedHistoryRecovery:
                dictationMiniIndicator.showRecoveryWarningAfterFailure(
                    "Saved in Recent Dictations — target changed"
                )
            }
        }
    }

    private var isDictationActivityInProgress: Bool {
        dictationState != .idle || dictationStartedAt != nil || computerUseCommandStartedAt != nil
            || quilStartedAt != nil || quilTask != nil || isNemotron35Streaming
    }

    private var isMeetingAudioProcessing: Bool {
        MeetingProcessingAdmissionPolicy.blocksDictation(
            stages: Array(meetingProcessingStages.values)
        )
    }

    private var canBeginDictationInteraction: Bool {
        DictationStartAdmissionPolicy.allowsStart(
            dictationState: dictationState,
            isMeetingAudioProcessing: isMeetingAudioProcessing
        )
    }

    private var shouldIgnoreCleanupAfterBlockedDictationStart: Bool {
        DictationStartAdmissionPolicy.shouldIgnoreCleanupAfterBlockedStart(
            hasStartedRecording: dictationStartedAt != nil,
            isStreaming: isNemotron35Streaming,
            dictationState: dictationState,
            isMeetingAudioProcessing: isMeetingAudioProcessing
        )
    }

    private func configureComputerUseHotkeyMonitor() {
        guard config.enableComputerUseHotkey else {
            computerUseHotkeyMonitor.stop()
            return
        }
        computerUseHotkeyMonitor.configure(config.computerUseHotkey)
        startComputerUseHotkeyMonitorIfNeeded()
    }

    private func configureQuilHotkeyMonitor() {
        guard config.enableQuilMode else {
            quilHotkeyMonitor.stop()
            return
        }
        quilHotkeyMonitor.configure(config.quilHotkey)
        startQuilHotkeyMonitorIfNeeded()
    }

    private func configureHotkeyMonitorTiming() {
        hotkeyMonitor.configureTriggerThreshold(milliseconds: config.hotkeyTriggerThresholdMS)
        computerUseHotkeyMonitor.configureTriggerThreshold(milliseconds: config.computerUseHotkeyTriggerThresholdMS)
        quilHotkeyMonitor.configureTriggerThreshold(milliseconds: config.quilHotkeyTriggerThresholdMS)
        meetingRecordingHotkeyMonitor.configureTriggerThreshold(milliseconds: config.meetingRecordingHotkeyTriggerThresholdMS)
    }

    private func startComputerUseHotkeyMonitorIfNeeded() {
        guard config.enableComputerUseHotkey else {
            computerUseHotkeyMonitor.stop()
            return
        }
        guard config.resolvedOnboardingUseCase.includesDictation else {
            computerUseHotkeyMonitor.stop()
            return
        }
        guard !ShortcutHotkeyPolicy.hotkeysConflict(config.computerUseHotkey, config.dictationHotkey) else {
            computerUseHotkeyMonitor.stop()
            fputs("[cua] computer use hotkey disabled because it matches dictation hotkey\n", stderr)
            return
        }
        guard !config.enableMeetingRecordingHotkey
            || !ShortcutHotkeyPolicy.hotkeysConflict(config.computerUseHotkey, config.meetingRecordingHotkey) else {
            computerUseHotkeyMonitor.stop()
            fputs("[cua] computer use hotkey disabled because it matches meeting recording hotkey\n", stderr)
            return
        }
        computerUseHotkeyMonitor.doubleTapEnabled = config.enableDoubleTapDictation
        computerUseHotkeyMonitor.configure(config.computerUseHotkey)
        computerUseHotkeyMonitor.start()
    }

    private func startQuilHotkeyMonitorIfNeeded() {
        guard config.enableQuilMode,
              config.resolvedOnboardingUseCase.includesDictation else {
            quilHotkeyMonitor.stop()
            return
        }
        let conflicts = ShortcutHotkeyPolicy.hotkeysConflict(config.quilHotkey, config.dictationHotkey)
            || (config.enableComputerUseHotkey && ShortcutHotkeyPolicy.hotkeysConflict(config.quilHotkey, config.computerUseHotkey))
            || (config.enableMeetingRecordingHotkey && ShortcutHotkeyPolicy.hotkeysConflict(config.quilHotkey, config.meetingRecordingHotkey))
        guard !conflicts else {
            quilHotkeyMonitor.stop()
            fputs("[quil] shortcut disabled because it conflicts with another shortcut\n", stderr)
            return
        }
        quilHotkeyMonitor.configure(config.quilHotkey)
        quilHotkeyMonitor.doubleTapEnabled = config.enableDoubleTapDictation
        quilHotkeyMonitor.start()
    }

    private func startMeetingRecordingHotkeyMonitorIfNeeded() {
        guard config.enableMeetingRecordingHotkey else {
            meetingRecordingHotkeyMonitor.stop()
            return
        }
        let validation = ShortcutHotkeyPolicy.validateMeetingRecordingHotkey(
            config.meetingRecordingHotkey,
            dictationHotkey: config.dictationHotkey,
            computerUseHotkey: config.computerUseHotkey,
            isComputerUseEnabled: config.enableComputerUseHotkey
        )
        guard validation.didUpdate else {
            meetingRecordingHotkeyMonitor.stop()
            fputs("[meetings] meeting recording hotkey disabled because it conflicts with another active shortcut\n", stderr)
            return
        }
        meetingRecordingHotkeyMonitor.doubleTapEnabled = false
        meetingRecordingHotkeyMonitor.configure(config.meetingRecordingHotkey)
        meetingRecordingHotkeyMonitor.start()
    }

    private func beginMeetingActivity(reason: String) {
        updatePostProcessorMeetingResidency()
        guard meetingActivity == nil else { return }
        meetingActivity = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiatedAllowingIdleSystemSleep,
                .suddenTerminationDisabled,
                .automaticTerminationDisabled,
            ],
            reason: reason
        )
    }

    private func updateMeetingStartStatus(_ status: String?) {
        meetingStartStatus = status
        appState.isMeetingStarting = isStartingMeetingRecording
        appState.meetingStartStatus = status
    }

    private func updateImportProgressStatus(_ status: String, sessionID: UUID) {
        guard importTask != nil,
              importSessionID == sessionID,
              isStartingMeetingRecording else { return }
        updateMeetingStartStatus(status)
        statusBarController?.setStatus(status)
        statusBarController?.refresh()
    }

    private func blockDictationForMeetingActivityIfNeeded() -> Bool {
        guard isStartingMeetingRecording else { return false }
        // Status bar only. A loading pill here is sticky — nothing on the meeting-start
        // path hides it, and while it is up the pill cannot hover, drag, or show the
        // transcript for the rest of the meeting. The pill is already in its preparing
        // state (meeting start) or showing import progress, which is the same news.
        let status = meetingStartStatus ?? "Preparing meeting..."
        statusBarController?.setStatus(status)
        statusBarController?.refresh()
        return true
    }

    private func endMeetingActivity() {
        updatePostProcessorMeetingResidency()
        guard backgroundMeetingProcessingCount == 0,
              activeMeetingSession?.isRecording != true else { return }
        guard let activity = meetingActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        meetingActivity = nil
    }

    private func dismissPresentedMeetingDetection() {
        guard let candidate = presentedMeetingCandidate else { return }
        presentedMeetingCandidate = nil
        meetingMonitor.markPromptClosed(candidate)
        if !isShowingCalendarNotification,
           meetingNotification.currentPromptID == candidate.id {
            meetingNotification.close()
        }
        showPendingMeetingCompletionNotificationIfPossible()
    }

    private func updateMeetingNotificationVisibility() {
        meetingMonitor.refreshState()
        showPendingMeetingCompletionNotificationIfPossible()
    }

    private func enqueueOrShowMeetingCompletionNotification(meetingID: Int64?, title: String) {
        let notification = PendingMeetingCompletionNotification(meetingID: meetingID, title: title)
        guard canShowMeetingCompletionNotification else {
            pendingMeetingCompletionNotification = notification
            return
        }
        showMeetingCompletionNotification(notification)
    }

    private func showPendingMeetingCompletionNotificationIfPossible() {
        guard let notification = pendingMeetingCompletionNotification,
              canShowMeetingCompletionNotification else { return }
        pendingMeetingCompletionNotification = nil
        showMeetingCompletionNotification(notification)
    }

    private var canShowMeetingCompletionNotification: Bool {
        MeetingCompletionNotificationPolicy.shouldShow(
            hasPresentedMeetingCandidate: presentedMeetingCandidate != nil,
            isShowingCalendarNotification: isShowingCalendarNotification,
            isMeetingNotificationVisible: meetingNotification.isVisible
        )
    }

    private func showMeetingCompletionNotification(_ notification: PendingMeetingCompletionNotification) {
        meetingNotification.show(
            title: "Transcription complete",
            subtitle: notification.title,
            actionLabel: "View Notes",
            onStartRecording: { [weak self] in
                guard let self else { return }
                if let meetingID = notification.meetingID {
                    self.showMeetingDocument(id: meetingID)
                }
                self.syncAppState()
                self.historyWindowController?.show()
            },
            onClose: { [weak self] in
                self?.showPendingMeetingCompletionNotificationIfPossible()
            }
        )
    }

    private func armMeetingAutoStop(
        source: MeetingAutoStopSource?,
        response: MeetingSignalLossResponse = .autoStopAfterWarning
    ) {
        let lateArmDeadline = source == nil && response == .warnOnly
            ? Date().addingTimeInterval(15)
            : nil
        activeMeetingAutoStop.arm(source: source, allowLateArmingUntil: lateArmDeadline)
        activeMeetingSignalLossResponse = source == nil ? .none : response
        meetingSignalLossPromptState.resetForRecording()
        syncMeetingDetectionMonitor()
    }

    private func recentMeetingAutoStopSource() -> MeetingAutoStopSource? {
        guard let candidate = latestMeetingActivityCandidate,
              let observedAt = latestMeetingActivityCandidateObservedAt,
              Date().timeIntervalSince(observedAt) <= 15 else {
            return nil
        }
        guard !isMutedMeetingDetectionCandidate(candidate) else {
            latestMeetingActivityCandidate = nil
            latestMeetingActivityCandidateObservedAt = nil
            latestMeetingActivityCandidateRunID = nil
            return nil
        }
        return MeetingAutoStopSource(candidate: candidate)
    }

    private func isMutedMeetingDetectionCandidate(_ candidate: MeetingCandidate) -> Bool {
        guard let sourceBundleID = candidate.sourceBundleID else { return false }
        return isMutedMeetingDetectionBundleID(sourceBundleID)
    }

    private func isMutedMeetingDetectionBundleID(_ bundleID: String) -> Bool {
        config.mutedMeetingDetectionAppBundleIDs.contains(bundleID)
    }

    /// The part every disarm shares: stop the auto-stop machinery and reset the signal-loss
    /// prompt. What happens to the activity candidate is what the two callers disagree about.
    private func resetMeetingAutoStopState() {
        activeMeetingAutoStop.disarm()
        activeMeetingSignalLossResponse = .none
        meetingSignalLossPromptState.resetForRecording()
    }

    private func clearLatestMeetingActivityCandidate() {
        latestMeetingActivityCandidate = nil
        latestMeetingActivityCandidateObservedAt = nil
        latestMeetingActivityCandidateRunID = nil
    }

    private func disarmMeetingAutoStop() {
        resetMeetingAutoStopState()
        clearLatestMeetingActivityCandidate()
        syncMeetingDetectionMonitor()
    }

    /// Disarm after a start that never produced a session. Clearing the activity candidate here
    /// would hide the Record pill until the detector re-emits, so the pill would vanish from a
    /// meeting that is still on screen. Re-evaluate the detector's current candidate instead and
    /// keep it only while it is still the meeting the start was launched from.
    private func disarmMeetingAutoStopAfterFailedStart() {
        resetMeetingAutoStopState()

        let detected = observedMeetingActivityCandidateRunID == meetingDetectionRunID
            ? observedMeetingActivityCandidate
            : nil
        let restores = MeetingRecordButtonPolicy.restoresCandidateAfterFailedStart(
            startedCandidateID: latestMeetingActivityCandidate?.id,
            detectorCandidateID: detected?.id
        )
        if restores, let detected, !isMutedMeetingDetectionCandidate(detected) {
            latestMeetingActivityCandidate = detected
            latestMeetingActivityCandidateObservedAt = observedMeetingActivityCandidateObservedAt
            latestMeetingActivityCandidateRunID = meetingDetectionRunID
        } else {
            clearLatestMeetingActivityCandidate()
        }
        syncMeetingDetectionMonitor()
    }

    private func handleMeetingActivityCandidate(_ candidate: MeetingCandidate?) {
        observedMeetingActivityCandidate = candidate
        observedMeetingActivityCandidateObservedAt = candidate == nil ? nil : Date()
        observedMeetingActivityCandidateRunID = candidate == nil ? nil : meetingDetectionRunID
        if !activeMeetingAutoStop.isArmed,
           !isMeetingRecording(),
           !isStartingMeetingRecording {
            if let candidate {
                latestMeetingActivityCandidate = candidate
                latestMeetingActivityCandidateObservedAt = Date()
                latestMeetingActivityCandidateRunID = meetingDetectionRunID
            } else {
                latestMeetingActivityCandidate = nil
                latestMeetingActivityCandidateObservedAt = nil
                latestMeetingActivityCandidateRunID = nil
                dismissedMeetingRecordButtonCandidateID = nil
            }
        }
        syncMeetingRecordButton()

        if activeMeetingAutoStop.isArmed,
           isStartingMeetingRecording,
           !isStoppingMeetingRecording {
            activeMeetingAutoStop.observeBeforeRecordingStarted(candidate: candidate)
            return
        }

        let now = Date()
        if !activeMeetingAutoStop.isArmed,
           activeMeetingSession?.isRecording == true,
           !isStoppingMeetingRecording,
           let candidate,
           !isMutedMeetingDetectionCandidate(candidate),
           activeMeetingAutoStop.armFromObservedCandidateIfNeeded(candidate, now: now) {
            activeMeetingSignalLossResponse = .warnOnly
            meetingSignalLossPromptState.resetForRecording()
            syncMeetingDetectionMonitor()
        }

        guard activeMeetingAutoStop.isArmed,
              activeMeetingSession?.isRecording == true,
              !isStoppingMeetingRecording else {
            return
        }
        if let sourceBundleID = activeMeetingAutoStop.source?.sourceBundleID,
           isMutedMeetingDetectionBundleID(sourceBundleID) {
            return
        }

        let matchedSource = candidate.flatMap { candidate in
            activeMeetingAutoStop.source.map { source in
                MeetingAutoStopPolicy.matches(candidate: candidate, source: source)
            }
        } ?? false
        if matchedSource {
            meetingSignalLossPromptState.markSourceRecovered()
            dismissMeetingSignalLossPromptIfVisible(for: activeMeetingID)
        }
        if activeMeetingAutoStop.observe(
            candidate: candidate,
            now: now,
            gracePeriod: meetingAutoStopGracePeriod
        ) {
            presentMeetingSignalLossPromptIfNeeded()
        }
    }

    private func meetingSignalLossPromptID(for meetingID: Int64?) -> String {
        meetingID.map { "meeting-signal-lost:\($0)" } ?? "meeting-signal-lost"
    }

    private func dismissMeetingSignalLossPromptIfVisible(for meetingID: Int64?) {
        guard meetingNotification.isVisible,
              meetingNotification.currentPromptID == meetingSignalLossPromptID(for: meetingID) else {
            return
        }
        meetingNotification.close()
    }

    private func presentMeetingSignalLossPromptIfNeeded() {
        guard activeMeetingSignalLossResponse != .none,
              meetingSignalLossPromptState.canPresentPrompt,
              activeMeetingSession?.isRecording == true,
              !isStoppingMeetingRecording else { return }

        let meetingID = activeMeetingID
        let promptID = meetingSignalLossPromptID(for: meetingID)
        guard meetingNotification.currentPromptID != promptID || !meetingNotification.isVisible else { return }

        meetingSignalLossPromptState.markPromptPresented()
        let response = activeMeetingSignalLossResponse
        let didShow = meetingNotification.show(
            promptID: promptID,
            title: "Meeting signal lost",
            subtitle: "Still transcribing. Stop if the meeting ended.",
            actionLabel: "Stop Transcribing",
            dismissAfter: 30,
            // MeetingNotificationController uses onStartRecording as its generic
            // primary-action slot; here the primary action is stopping transcription.
            onStartRecording: { [weak self] in
                guard let self, self.activeMeetingID == meetingID else { return }
                self.stopMeetingRecording()
            },
            onDismiss: { [weak self] in
                guard let self, self.activeMeetingID == meetingID else { return }
                self.meetingSignalLossPromptState.markDismissedByUser()
            },
            onAutoDismiss: { [weak self] in
                guard let self else { return }
                guard self.activeMeetingID == meetingID else { return }
                self.meetingSignalLossPromptState.markAutoDismissed()
                guard response == .autoStopAfterWarning else { return }
                fputs("[meeting] auto-stopping recording after meeting source disappeared and warning timed out\n", stderr)
                self.stopMeetingRecording()
            }
        )

        if !didShow, response == .autoStopAfterWarning {
            fputs("[meeting] auto-stopping recording after meeting source disappeared; warning unavailable\n", stderr)
            stopMeetingRecording()
        }
    }

    private func presentMeetingDetection(_ candidate: MeetingCandidate) {
        guard config.showMeetingDetectionNotification,
              !isShowingCalendarNotification,
              !isMeetingRecording(),
              !isStartingMeetingRecording else { return }

        guard meetingNotification.currentPromptID != candidate.id || !meetingNotification.isVisible else {
            presentedMeetingCandidate = candidate
            return
        }

        let title = candidate.subtitle
        presentedMeetingCandidate = candidate
        let preferredScreen = meetingSourceWindowLocator.screen(for: candidate)
        let didShow = meetingNotification.show(
            promptID: candidate.id,
            title: "Meeting detected",
            subtitle: title,
            preferredScreen: preferredScreen,
            platform: MeetingPlatform(candidate.platform),
            onStartRecording: { [weak self] in
                guard let self else { return }
                let calendarEvent = candidate.evidence.contains(.calendarEvent)
                    ? self.currentOrNearbyCachedCalendarEvent()
                    : nil
                if self.startMeetingRecordingFromEntryPoint(
                    title: title,
                    calendarOccurrence: calendarEvent?.calendarOccurrence,
                    autoStopSource: MeetingAutoStopSource(candidate: candidate),
                    presentation: .backgroundPill,
                    startOrigin: .detectedPrompt
                ) {
                    self.meetingMonitor.markRecordingStarted(candidate)
                    self.presentedMeetingCandidate = nil
                    self.showPendingMeetingCompletionNotificationIfPossible()
                } else {
                    self.meetingMonitor.refreshState()
                }
            },
            onDismiss: { [weak self] in
                guard let self else { return }
                self.presentedMeetingCandidate = nil
                self.meetingMonitor.markPromptUserDismissed(candidate)
                self.meetingMonitor.refreshState()
                self.showPendingMeetingCompletionNotificationIfPossible()
            },
            onAutoDismiss: { [weak self] in
                guard let self else { return }
                self.meetingMonitor.markPromptAutoDismissed(candidate)
                if self.presentedMeetingCandidate == candidate {
                    self.presentedMeetingCandidate = nil
                }
                self.meetingMonitor.refreshState()
                self.showPendingMeetingCompletionNotificationIfPossible()
            },
            onClose: { [weak self] in
                guard let self, self.presentedMeetingCandidate == candidate else { return }
                self.presentedMeetingCandidate = nil
                self.meetingMonitor.markPromptClosed(candidate)
                self.showPendingMeetingCompletionNotificationIfPossible()
            }
        )
        if didShow {
            meetingMonitor.markPromptShown(candidate)
        } else if presentedMeetingCandidate == candidate {
            presentedMeetingCandidate = nil
        }
    }

    @MainActor
    private func setMeetingProcessingStage(
        _ stage: MeetingProcessingStage,
        processingID: UUID,
        panelOwnerID: UUID?,
        updatePresentation: Bool = true
    ) {
        let wasBlockingDictation = isMeetingAudioProcessing
        meetingProcessingStages[processingID] = stage

        if wasBlockingDictation, !isMeetingAudioProcessing {
            syncDictationRecorderWarmup(intent: .idlePrewarm(.meetingStateChanged))
        }
        guard updatePresentation else { return }
        let presentationStage = meetingProcessingStages.values.first(where: { !$0.allowsDictation }) ?? stage
        presentMeetingProcessingStage(presentationStage, panelOwnerID: panelOwnerID)
    }

    @MainActor
    private func removeMeetingProcessing(processingID: UUID) {
        let wasBlockingDictation = isMeetingAudioProcessing
        meetingProcessingStages[processingID] = nil
        if wasBlockingDictation, !isMeetingAudioProcessing {
            syncDictationRecorderWarmup(intent: .idlePrewarm(.meetingStateChanged))
        }
    }

    @MainActor
    private func presentMeetingProcessingStage(
        _ stage: MeetingProcessingStage,
        panelOwnerID: UUID?
    ) {
        if stage.allowsDictation, isDictationActivityInProgress { return }

        switch stage {
        case .transcribingAudio:
            setMeetingProcessingStatus("Transcribing", panelOwnerID: panelOwnerID)
        case .cleaningAudio:
            setMeetingProcessingStatus("Cleaning", panelOwnerID: panelOwnerID)
        case .generatingTitle:
            setMeetingProcessingStatus("Titling", panelOwnerID: panelOwnerID)
        case .summarizingNotes:
            setMeetingProcessingStatus("Summarizing", panelOwnerID: panelOwnerID)
        }
    }

    @MainActor
    private func setMeetingProcessingStatus(_ status: String, panelOwnerID: UUID?) {
        guard !isDictationActivityInProgress else { return }
        statusBarController?.setStatus(status)
        statusBarController?.refresh()
        if let panelOwnerID {
            meetingRecordingPanel.updateFinalizingStatus(status, ownerID: panelOwnerID)
        }
    }

    private func handleComputerUsePrepare() {
        guard canPrepareComputerUseCommand else { return }
        fputs("[cua] prepare\n", stderr)
        meetingMonitor.suppressWhileActive()
        meetingMonitor.refreshState()
        ComputerUseCursorOverlay.shared.showAcquiring()
        computerUseAudioSessionManager.arm(source: "computer_use_hotkey_prepare")
        activeComputerUseAudioSessionID = computerUseAudioSessionManager.currentSessionID
    }

    private func handleQuilPrepare() {
        guard canPrepareQuil else { return }
        quilSelectionSnapshot = nil
        quilTargetCaptureError = nil
        meetingMonitor.suppressWhileActive()
        meetingMonitor.refreshState()
        setState(.preparing)
        quilAudioSessionManager.arm(source: "quil_hotkey_prepare")
        activeQuilAudioSessionID = quilAudioSessionManager.currentSessionID
    }

    private func handleQuilStart() {
        guard canStartQuil else { return }
        quilStartedAt = Date()
        setState(.preparing)
        quilAudioSessionManager.beginRecording(
            mode: "quil",
            duckingEnabled: false,
            mediaPauseEnabled: false
        )
        activeQuilAudioSessionID = quilAudioSessionManager.currentSessionID
    }

    private func captureQuilTargetIfNeeded() {
        if quilSelectionSnapshot == nil {
            do {
                let snapshot = try QuilSelectionSnapshot.capture()
                quilSelectionSnapshot = snapshot
                quilTargetCaptureError = nil
                startQuilContextCapture(for: snapshot)
            } catch {
                quilTargetCaptureError = error
                fputs("[quil] target capture deferred failure: \(error)\n", stderr)
            }
        }
    }

    private func handleQuilToggleStart() {
        guard canStartQuil else {
            quilHotkeyMonitor.cancelToggleMode()
            return
        }
        handleQuilStart()
    }

    private func handleQuilToggleStop() {
        handleQuilStop()
    }

    private func handleQuilCancel() {
        guard !interactiveAudioSessionOwnership.shouldIgnoreCleanup(for: .quil) else { return }
        clearQuilSession(cancelAudioReason: "quil_cancel")
        resumeAfterQuil()
    }

    private func handleQuilStop() {
        guard pendingQuilStopSessionID == nil,
              let sessionID = activeQuilAudioSessionID,
              quilAudioSessionManager.currentSessionID == sessionID else { return }
        SoundController.playQuillRelease(
            enabled: shouldPlayQuilLifecycleSounds && !isDictationTestMode
        )
        let startedAt = quilStartedAt ?? Date()
        quilStartedAt = nil
        activeQuilAudioSessionID = nil
        pendingQuilStopSessionID = sessionID
        pendingQuilStopStartedAt = startedAt
        quilAudioSessionManager.stop()
    }

    private func finishQuilAudioStop(wavURL: URL?, startedAt: Date) {
        guard let wavURL else {
            handleQuilCancel()
            return
        }
        let duration = max(Date().timeIntervalSince(startedAt), 0)
        guard duration >= 0.3 else {
            try? FileManager.default.removeItem(at: wavURL)
            presentQuilFailure(QuilTransformationError.emptyInstruction)
            return
        }
        guard let snapshot = quilSelectionSnapshot else {
            try? FileManager.default.removeItem(at: wavURL)
            presentQuilFailure(quilTargetCaptureError ?? QuilTransformationError.noTextTarget)
            return
        }
        guard snapshot.isStillCurrent() else {
            try? FileManager.default.removeItem(at: wavURL)
            presentQuilFailure(QuilTransformationError.selectionChanged)
            return
        }
        statusBarController?.setStatus("Parsing instruction")
        setState(.transcribing)
        let taskID = UUID()
        quilTaskID = taskID
        let backend = TranscriptCleanupBackendOption.resolved(config.quilBackend)
        let configuredModel = config.quilModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuredModel.isEmpty
            ? (backend == .local
                ? PostProcessorOption.defaultQuilOption.id
                : TranscriptCleanupClient.defaultModel(for: backend))
            : configuredModel
        let configSnapshot = config
        let contextCaptureTask = quilContextCaptureTask
        quilTask = Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: wavURL) }
            do {
                let result = try await self.transcriptionCoordinator.transcribeDictation(
                    at: wavURL,
                    backend: self.selectedBackend,
                    cohereLanguage: configSnapshot.resolvedCohereLanguage,
                    indicASRLanguage: configSnapshot.resolvedIndicASRLanguage,
                    whisperLanguage: configSnapshot.resolvedWhisperLanguage,
                    appleSpeechLanguage: configSnapshot.resolvedAppleSpeechLanguage,
                    enablePostProcessor: false,
                    customWords: self.serializedCustomWords(),
                    appContext: nil
                )
                try Task.checkCancellation()
                let instruction = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !instruction.isEmpty else { throw QuilTransformationError.emptyInstruction }
                await MainActor.run {
                    guard self.quilTaskID == taskID else { return }
                    self.statusBarController?.setStatus("Rewriting selection")
                    self.dictationMiniIndicator.showToast(instruction)
                }
                let capturedContext: DictationContext?
                if let contextCaptureTask {
                    capturedContext = await contextCaptureTask.value
                } else {
                    capturedContext = nil
                }
                try Task.checkCancellation()
                let contextStillBelongsToSelection = await MainActor.run {
                    snapshot.isStillCurrent() && snapshot.matches(context: capturedContext)
                }
                guard contextStillBelongsToSelection else {
                    throw QuilTransformationError.selectionChanged
                }
                let promptContext = capturedContext.map { DictationContextCapture.formatForPrompt($0) }
                let replacement = try await self.transcriptionCoordinator.transformSelectedTextForQuil(
                    selectedText: snapshot.text,
                    instruction: instruction,
                    appContext: promptContext,
                    backend: backend,
                    model: model,
                    config: configSnapshot
                )
                try Task.checkCancellation()
                let selectionStillCurrent = await MainActor.run {
                    snapshot.isStillCurrentForReplacement()
                }
                guard selectionStillCurrent else {
                    throw QuilTransformationError.selectionChanged
                }
                await MainActor.run {
                    guard self.quilTaskID == taskID else { return }
                    guard replacement != snapshot.text else {
                        let saved = self.persistQuilTransformation(
                            outputText: replacement,
                            originalText: snapshot.text,
                            instruction: instruction,
                            backend: backend,
                            model: model,
                            duration: duration,
                            startedAt: startedAt,
                            application: snapshot.application
                        )
                        self.finishQuilTask(
                            taskID: taskID,
                            message: saved ? "No changes needed" : "No changes needed; Quill history was not saved"
                        )
                        return
                    }
                    var pasteLifecycleEvents: [PasteController.LifecycleEvent] = []
                    PasteController.paste(
                        text: replacement,
                        requireStagedClipboardOwnership: true,
                        targetApplicationProvider: { snapshot.application },
                        shouldDispatchPaste: { snapshot.isTargetStillFocused() },
                        dispatchStrategy: DictationContextCapture.isBrowserApplication(snapshot.application)
                            ? .targetApplicationPasteCommand
                            : .keyboardShortcut,
                        retainStagedTextOnFailure: true,
                        onPasteDispatched: {
                            // The post-dictation correction monitor cannot distinguish a
                            // user edit from Quill's deliberate rewrite. Once Quill actually
                            // replaces the selection, the original dictation is no longer a
                            // valid correction baseline, so end that monitoring session.
                            self.dictationCorrectionMonitor.cancel()
                        },
                        onPasteFinished: { target in
                            guard self.quilTaskID == taskID else { return }
                            let usedTargetPasteCommand = pasteLifecycleEvents.contains(
                                .targetPasteCommandDispatched
                            )
                            let retainedForManualPaste = pasteLifecycleEvents.contains(
                                .clipboardRetainedForManualPaste
                            )
                            let deliveryStatus: String
                            let deliveryMessage: String?
                            let deliveryTraceBody: String
                            let userMessage: String?
                            if target != nil {
                                deliveryStatus = "done"
                                deliveryMessage = nil
                                deliveryTraceBody = usedTargetPasteCommand
                                    ? "Pasted through the target application's standard Paste command"
                                    : "Paste keyboard command dispatched to the target application"
                                userMessage = nil
                            } else if retainedForManualPaste {
                                deliveryStatus = "needs_attention"
                                deliveryMessage = "Generated text is ready for manual paste"
                                deliveryTraceBody = "Automatic paste was not accepted; generated text was retained on the clipboard"
                                userMessage = "Generated — press ⌘V to paste"
                            } else {
                                deliveryStatus = "needs_attention"
                                deliveryMessage = "Automatic paste could not be completed"
                                deliveryTraceBody = "Automatic paste was not completed and the clipboard changed before fallback could be retained"
                                userMessage = "Generated, but automatic paste failed; output saved in history"
                            }
                            let saved = self.persistQuilTransformation(
                                outputText: replacement,
                                originalText: snapshot.text,
                                instruction: instruction,
                                backend: backend,
                                model: model,
                                duration: duration,
                                startedAt: startedAt,
                                application: snapshot.application,
                                deliveryStatus: deliveryStatus,
                                deliveryMessage: deliveryMessage,
                                deliveryTraceBody: deliveryTraceBody
                            )
                            if target != nil {
                                TelemetryDeck.signal("quil.completed", parameters: [
                                    "backend": backend.backend,
                                    "input_chars": String(snapshot.text.count),
                                    "output_chars": String(replacement.count),
                                ])
                                self.finishQuilTask(
                                    taskID: taskID,
                                    message: saved ? nil : "Reformatted, but could not save Quill history"
                                )
                            } else {
                                TelemetryDeck.signal("quil.paste_fallback", parameters: [
                                    "backend": backend.backend,
                                    "clipboard_retained": String(retainedForManualPaste),
                                ])
                                let message = saved
                                    ? userMessage
                                    : "Generated, but paste and Quill history both failed"
                                self.finishQuilTask(taskID: taskID, message: message)
                            }
                        },
                        onLifecycleEvent: { event in
                            pasteLifecycleEvents.append(event)
                        }
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard self.quilTaskID == taskID else { return }
                    self.presentQuilFailure(error)
                }
            }
        }
    }

    private func startQuilContextCapture(for snapshot: QuilSelectionSnapshot) {
        quilContextCaptureTask?.cancel()
        quilContextCaptureTask = nil
        guard config.enableScreenContext,
              let expectedDocumentIdentifier = snapshot.contextDocumentIdentifier else { return }

        let expectedBundleID = snapshot.application.bundleIdentifier ?? ""
        let includeScreenOCR = config.enableDictationOCRContext
            && !isMeetingRecording()
            && CGPreflightScreenCaptureAccess()
        quilContextCaptureTask = Task.detached(priority: .utility) {
            guard AXIsProcessTrusted(), !Task.isCancelled else { return nil }
            let context = await DictationContextCapture.capture(
                includeScreenOCR: includeScreenOCR,
                shouldCaptureScreenOCR: { !Task.isCancelled },
                allowTitleFallback: false
            )
            guard !Task.isCancelled,
                  DictationContextCapture.matchesQuilSelection(
                    context,
                    bundleID: expectedBundleID,
                    documentIdentifier: expectedDocumentIdentifier
                  ) else { return nil }
            return context
        }
    }

    @MainActor
    @discardableResult
    private func persistQuilTransformation(
        outputText: String,
        originalText: String,
        instruction: String,
        backend: TranscriptCleanupBackendOption,
        model: String,
        duration: TimeInterval,
        startedAt: Date,
        application: NSRunningApplication,
        deliveryStatus: String = "done",
        deliveryMessage: String? = nil,
        deliveryTraceBody: String? = nil
    ) -> Bool {
        do {
            let additionalTraceEvents = deliveryTraceBody.map {
                [ComputerUseTraceEvent(
                    kind: "quil_delivery",
                    title: "Delivery",
                    body: $0
                )]
            } ?? []
            _ = try dictationStore.insertQuilDictation(
                outputText: outputText,
                originalText: originalText,
                instruction: instruction,
                backend: backend.backend,
                model: model,
                durationSeconds: duration,
                targetAppName: application.localizedName,
                targetAppBundleID: application.bundleIdentifier,
                finalStatus: deliveryStatus,
                finalMessage: deliveryMessage,
                additionalTraceEvents: additionalTraceEvents,
                startedAt: startedAt,
                endedAt: Date()
            )
            scheduleICloudSyncAfterLocalChange()
            statusBarController?.refresh()
            if let historyWindowController {
                historyWindowController.reload()
            } else {
                syncAppState()
            }
            return true
        } catch {
            fputs("[quil] failed to persist transformation: \(error)\n", stderr)
            return false
        }
    }

    @MainActor
    private func finishQuilTask(taskID: UUID, message: String?) {
        guard quilTaskID == taskID else { return }
        clearQuilSession()
        if let message { _ = dictationMiniIndicator.showWarning(message, duration: 2.0) }
        resumeAfterQuil()
    }

    @MainActor
    private func presentQuilFailure(_ error: Error) {
        clearQuilSession(cancelAudioReason: "quil_failure")
        resumeAfterQuil()
        let message = error.localizedDescription
        statusBarController?.setStatus(message)
        _ = dictationMiniIndicator.showWarning(message, duration: 3.0)
    }

    private func clearQuilSession(cancelAudioReason: String? = nil) {
        quilTask?.cancel()
        quilTask = nil
        quilTaskID = nil
        if let cancelAudioReason { quilAudioSessionManager.cancel(reason: cancelAudioReason) }
        activeQuilAudioSessionID = nil
        quilStartedAt = nil
        pendingQuilStopSessionID = nil
        pendingQuilStopStartedAt = nil
        quilSelectionSnapshot = nil
        quilTargetCaptureError = nil
        quilContextCaptureTask?.cancel()
        quilContextCaptureTask = nil
        quilHotkeyMonitor.cancelToggleMode()
    }

    private func resumeAfterQuil() {
        setState(.idle)
        meetingMonitor.resumeAfterCooldown()
        meetingMonitor.refreshState()
    }

    private func handleComputerUseStart() {
        guard canStartComputerUseCommand else { return }
        fputs("[cua] recording start\n", stderr)
        meetingMonitor.suppressWhileActive()
        computerUseCommandStartedAt = Date()
        ComputerUseCursorOverlay.shared.showAcquiring()
        computerUseAudioSessionManager.beginRecording(
            mode: "computer_use",
            duckingEnabled: false,
            mediaPauseEnabled: false
        )
        activeComputerUseAudioSessionID = computerUseAudioSessionManager.currentSessionID
    }

    private func handleComputerUseToggleStart() {
        guard canStartComputerUseCommand else {
            computerUseHotkeyMonitor.cancelToggleMode()
            return
        }
        fputs("[cua] toggle command start\n", stderr)
        handleComputerUseStart()
    }

    private func handleComputerUseToggleStop() {
        fputs("[cua] toggle command stop\n", stderr)
        handleComputerUseStop()
    }

    private func handleComputerUseCancel() {
        fputs("[cua] cancel\n", stderr)
        guard !interactiveAudioSessionOwnership.shouldIgnoreCleanup(for: .computerUse) else {
            fputs("[cua] ignoring cleanup while dictation owns interactive audio\n", stderr)
            computerUseHotkeyMonitor.cancelToggleMode()
            return
        }
        computerUseCommandTask?.cancel()
        computerUseCommandTask = nil
        computerUseCommandTaskID = nil
        computerUseAudioSessionManager.cancel(reason: "computer_use_cancel")
        activeComputerUseAudioSessionID = nil
        computerUseCommandStartedAt = nil
        pendingComputerUseStopSessionID = nil
        pendingComputerUseStopStartedAt = nil
        computerUseHotkeyMonitor.cancelToggleMode()
        ComputerUseCursorOverlay.shared.hideTarget()
        resetComputerUseFloatingStatus()
        ComputerUseCursorOverlay.shared.hide()
        meetingMonitor.resumeAfterCooldown()
        meetingMonitor.refreshState()
    }

    private func handleComputerUseStop() {
        fputs("[cua] stop\n", stderr)
        guard pendingComputerUseStopSessionID == nil else {
            fputs("[cua] stop already pending\n", stderr)
            return
        }
        guard let sessionID = activeComputerUseAudioSessionID,
              computerUseAudioSessionManager.currentSessionID == sessionID else {
            fputs("[cua] stop without owned audio session\n", stderr)
            return
        }
        let startedAt = computerUseCommandStartedAt ?? Date()
        computerUseCommandStartedAt = nil
        activeComputerUseAudioSessionID = nil
        pendingComputerUseStopSessionID = sessionID
        pendingComputerUseStopStartedAt = startedAt
        computerUseAudioSessionManager.stop()
    }

    private func finishComputerUseAudioStop(wavURL: URL?, startedAt: Date) {
        guard let wavURL else {
            fputs("[cua] stop without wav\n", stderr)
            ComputerUseCursorOverlay.shared.hide()
            meetingMonitor.resumeAfterCooldown()
            meetingMonitor.refreshState()
            return
        }
        let duration = max(Date().timeIntervalSince(startedAt), 0)
        if duration < 0.3 {
            fputs("[cua] discarded short recording\n", stderr)
            try? FileManager.default.removeItem(at: wavURL)
            ComputerUseCursorOverlay.shared.hide()
            meetingMonitor.resumeAfterCooldown()
            meetingMonitor.refreshState()
            return
        }

        ComputerUseCursorOverlay.shared.showProcessing("Parsing command")
        computerUseCommandTask?.cancel()
        let taskID = UUID()
        let backend = selectedBackend
        let languageProfile = config.languageProfile
        let customWords = serializedCustomWords()
        computerUseCommandTaskID = taskID
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: wavURL)
            }

            do {
                let result = try await self.transcriptionCoordinator.transcribeDictation(
                    at: wavURL,
                    backend: backend,
                    languageDecision: Self.dictationLanguageDecision(
                        profile: languageProfile,
                        backend: backend
                    ),
                    cohereLanguage: languageProfile.resolvedCohereLanguage,
                    indicASRLanguage: languageProfile.resolvedIndicASRLanguage,
                    nemotron35Language: languageProfile.resolvedNemotron35Language,
                    whisperLanguage: languageProfile.resolvedWhisperLanguage,
                    appleSpeechLanguage: self.config.resolvedAppleSpeechLanguage,
                    enablePostProcessor: false,
                    customWords: customWords,
                    appContext: nil
                )
                try Task.checkCancellation()
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    guard self.computerUseCommandTaskID == taskID else { return }
                    TelemetryDeck.signal("computer_use.command_parsed", parameters: [
                        "planner_enabled": self.config.enableComputerUsePlanner ? "true" : "false",
                    ])
                }
                guard !text.isEmpty else {
                    fputs("[cua] empty transcript, skipping planner\n", stderr)
                    await MainActor.run {
                        guard self.computerUseCommandTaskID == taskID else { return }
                        self.computerUseCommandTask = nil
                        self.computerUseCommandTaskID = nil
                        ComputerUseCursorOverlay.shared.hide()
                        self.meetingMonitor.resumeAfterCooldown()
                        self.meetingMonitor.refreshState()
                    }
                    return
                }
                guard await MainActor.run(body: {
                    self.computerUseCommandTaskID == taskID
                }) else { return }
                try Task.checkCancellation()
                let commandEndedAt = Date()
                let dictationID = try? self.dictationStore.insertDictation(
                    text: text,
                    durationSeconds: duration,
                    source: "cua",
                    startedAt: startedAt,
                    endedAt: commandEndedAt
                )
                guard await MainActor.run(body: {
                    self.computerUseCommandTaskID == taskID
                }) else { return }
                await MainActor.run {
                    self.scheduleICloudSyncAfterLocalChange()
                }
                await self.handleComputerUseCommand(
                    transcript: text,
                    dictationID: dictationID,
                    taskID: taskID
                )
            } catch is CancellationError {
                fputs("[cua] command parsing cancelled\n", stderr)
                await MainActor.run {
                    guard self.computerUseCommandTaskID == taskID else { return }
                    self.computerUseCommandTask = nil
                    self.computerUseCommandTaskID = nil
                    ComputerUseCursorOverlay.shared.hide()
                    self.meetingMonitor.resumeAfterCooldown()
                    self.meetingMonitor.refreshState()
                }
            } catch {
                fputs("[cua] transcription failed: \(error)\n", stderr)
                await MainActor.run {
                    guard self.computerUseCommandTaskID == taskID else { return }
                    self.computerUseCommandTask = nil
                    self.computerUseCommandTaskID = nil
                    ComputerUseCursorOverlay.shared.showTerminal("CUA command failed", kind: .failure)
                    self.meetingMonitor.resumeAfterCooldown()
                    self.meetingMonitor.refreshState()
                }
            }
        }
        computerUseCommandTask = task
    }

    private var canPrepareComputerUseCommand: Bool {
        !isMeetingRecording()
            && !isDictationTestMode
            && !isMeetingAudioProcessing
            && dictationStartedAt == nil
            && computerUseCommandStartedAt == nil
            && pendingComputerUseStopSessionID == nil
            && computerUseCommandTask == nil
            && !isNemotron35Streaming
            && interactiveAudioSessionOwnership.canStart(.computerUse)
            && dictationState == .idle
    }

    private var canStartComputerUseCommand: Bool {
        !isMeetingRecording()
            && !isDictationTestMode
            && !isMeetingAudioProcessing
            && dictationStartedAt == nil
            && computerUseCommandStartedAt == nil
            && pendingComputerUseStopSessionID == nil
            && computerUseCommandTask == nil
            && !isNemotron35Streaming
            && interactiveAudioSessionOwnership.canStart(.computerUse)
            && (dictationState == .idle || dictationState == .preparing)
    }

    private var interactiveAudioSessionOwnership: InteractiveAudioSessionOwnership {
        let quilIsActive = quilAudioSessionManager.hasActiveSession
            || quilStartedAt != nil
            || pendingQuilStopSessionID != nil
            || quilTask != nil
        let computerUseIsActive = computerUseAudioSessionManager.hasActiveSession
            || computerUseCommandStartedAt != nil
            || pendingComputerUseStopSessionID != nil
            || computerUseCommandTask != nil
        let dictationIsActive = dictationAudioSessionManager.hasActiveSession
            || dictationStartedAt != nil
            || !pendingStandardDictationStops.isEmpty
            || isNemotron35Streaming
            || (!computerUseIsActive && !quilIsActive && dictationState != .idle)
        return InteractiveAudioSessionOwnership(
            dictationIsActive: dictationIsActive,
            computerUseIsActive: computerUseIsActive,
            quilIsActive: quilIsActive
        )
    }

    private var canPrepareQuil: Bool {
        config.enableQuilMode
            && !isMeetingRecording()
            && !isDictationTestMode
            && !isMeetingAudioProcessing
            && pendingQuilStopSessionID == nil
            && quilTask == nil
            && interactiveAudioSessionOwnership.canStart(.quil)
            && dictationState == .idle
    }

    private var canStartQuil: Bool {
        config.enableQuilMode
            && !isMeetingRecording()
            && !isDictationTestMode
            && !isMeetingAudioProcessing
            && pendingQuilStopSessionID == nil
            && quilTask == nil
            && interactiveAudioSessionOwnership.canStart(.quil)
            && (dictationState == .idle || dictationState == .preparing)
    }

    private func shouldRejectDictationForComputerUseActivity() -> Bool {
        guard !interactiveAudioSessionOwnership.canStart(.dictation) else { return false }
        fputs("[muesli-native] ignoring dictation start while computer use owns interactive audio\n", stderr)
        hotkeyMonitor.cancelToggleMode()
        return true
    }

    private func shouldIgnoreDictationCleanupForComputerUseActivity() -> Bool {
        guard interactiveAudioSessionOwnership.shouldIgnoreCleanup(for: .dictation) else { return false }
        fputs("[muesli-native] ignoring dictation cleanup while computer use owns interactive audio\n", stderr)
        hotkeyMonitor.cancelToggleMode()
        return true
    }

    @MainActor
    private func handleComputerUseCommand(
        transcript: String,
        dictationID: Int64?,
        taskID: UUID
    ) async {
        guard computerUseCommandTaskID == taskID else { return }
        resetComputerUseFloatingStatus()
        presentComputerUseTranscript(transcript)
        let runtime = ComputerUsePlannerRuntime(config: config) { [weak self] status in
            guard let self, self.computerUseCommandTaskID == taskID else { return }
            self.presentComputerUseFloatingStatus(status)
        }

        let result = await runtime.run(command: transcript)
        guard computerUseCommandTaskID == taskID else { return }
        ComputerUseCursorOverlay.shared.hideTarget()
        if result.status == .cancelled {
            computerUseCommandTask = nil
            computerUseCommandTaskID = nil
            ComputerUseCursorOverlay.shared.hide()
            meetingMonitor.resumeAfterCooldown()
            meetingMonitor.refreshState()
            TelemetryDeck.signal("computer_use.command_finished", parameters: [
                "status": "\(result.status)",
            ])
            return
        }
        persistComputerUseTrace(result, dictationID: dictationID)
        await waitForComputerUseFloatingStatusDwell()
        guard computerUseCommandTaskID == taskID else { return }
        computerUseCommandTask = nil
        computerUseCommandTaskID = nil
        presentComputerUseRuntimeResult(result)
        meetingMonitor.resumeAfterCooldown()
        meetingMonitor.refreshState()
        TelemetryDeck.signal("computer_use.command_finished", parameters: [
            "status": "\(result.status)",
        ])
    }

    @MainActor
    private func resetComputerUseFloatingStatus() {
        computerUseFloatingStatusWorkItem?.cancel()
        computerUseFloatingStatusWorkItem = nil
        computerUseLastFloatingStatusAt = .distantPast
        computerUseLastFloatingStatus = ""
        computerUseTranscriptVisible = false
    }

    @MainActor
    private func presentComputerUseTranscript(_ transcript: String) {
        computerUseTranscriptVisible = true
        computerUseLastFloatingStatusAt = .distantPast
        computerUseLastFloatingStatus = ""
        ComputerUseCursorOverlay.shared.showTranscript(transcript)
    }

    @MainActor
    private func presentComputerUseFloatingStatus(_ status: String) {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        statusBarController?.setStatus(trimmed)
        guard computerUseCommandTask != nil else { return }
        guard let floatingStatus = computerUseFloatingStatusLabel(for: trimmed) else { return }
        if computerUseTranscriptVisible && !shouldReplaceComputerUseTranscript(with: floatingStatus) {
            return
        }
        guard floatingStatus != computerUseLastFloatingStatus else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(computerUseLastFloatingStatusAt)
        if shouldShowComputerUseStatusImmediately(floatingStatus, elapsed: elapsed) {
            computerUseFloatingStatusWorkItem?.cancel()
            computerUseFloatingStatusWorkItem = nil
            applyComputerUseFloatingStatus(floatingStatus, at: now)
            return
        }

        let delay = max(0.08, computerUseFloatingStatusMinimumDwell - elapsed)
        computerUseFloatingStatusWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.computerUseCommandTask != nil else { return }
                self.applyComputerUseFloatingStatus(floatingStatus, at: Date())
                self.computerUseFloatingStatusWorkItem = nil
            }
        }
        computerUseFloatingStatusWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    @MainActor
    private func computerUseFloatingStatusLabel(for status: String) -> String? {
        if status.hasPrefix("Planning step") {
            return computerUseLastFloatingStatus.isEmpty ? "Thinking..." : nil
        }
        if status == "Observing screen" {
            return "Reading screen"
        }
        if status == "Screen fallback" {
            return "Using screen"
        }
        if status == "Retrying planner" {
            return "Retrying"
        }
        return status
    }

    @MainActor
    private func shouldShowComputerUseStatusImmediately(_ status: String, elapsed: TimeInterval) -> Bool {
        guard !computerUseLastFloatingStatus.isEmpty else { return true }
        if elapsed >= computerUseFloatingStatusMinimumDwell { return true }
        if status == "Done" || status == "Failed" || status == "Confirm" { return true }
        if computerUseLastFloatingStatus == "Thinking...", elapsed >= 0.25 {
            return true
        }
        if isConcreteComputerUseFloatingStatus(status) {
            return elapsed >= 0.2
        }
        return false
    }

    @MainActor
    private func shouldReplaceComputerUseTranscript(with status: String) -> Bool {
        if status == "Thinking..." || status == "Reading screen" {
            return false
        }
        return true
    }

    @MainActor
    private func isConcreteComputerUseFloatingStatus(_ status: String) -> Bool {
        status.hasPrefix("Opening")
            || status.hasPrefix("Opened")
            || status.hasPrefix("Clicked")
            || status.hasPrefix("Typed")
            || status.hasPrefix("Navigated")
            || status == "Navigating"
            || status == "Typing"
            || status == "Moving cursor"
            || status.hasPrefix("Moving to")
            || status == "Clicking"
            || status == "Scrolling"
            || status == "Pressing key"
            || status == "Using screen"
    }

    @MainActor
    private func applyComputerUseFloatingStatus(_ status: String, at date: Date) {
        computerUseTranscriptVisible = false
        computerUseLastFloatingStatus = status
        computerUseLastFloatingStatusAt = date
        ComputerUseCursorOverlay.shared.showStatus(status)
    }

    @MainActor
    private func waitForComputerUseFloatingStatusDwell() async {
        computerUseFloatingStatusWorkItem?.cancel()
        computerUseFloatingStatusWorkItem = nil
        let elapsed = Date().timeIntervalSince(computerUseLastFloatingStatusAt)
        let remaining = computerUseLastFloatingStatus.isEmpty
            ? 0
            : computerUseFloatingStatusMinimumDwell - elapsed
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }

    private func persistComputerUseTrace(_ result: ComputerUsePlannerRuntimeResult, dictationID: Int64?) {
        guard let dictationID else { return }
        try? dictationStore.insertComputerUseTrace(
            dictationID: dictationID,
            finalStatus: computerUseTraceStatus(result.status),
            finalMessage: result.message,
            events: result.traceEvents
        )
        statusBarController?.refresh()
        historyWindowController?.reload()
        syncAppState()
    }

    private func computerUseTraceStatus(_ status: ComputerUsePlannerRuntimeResult.Status) -> String {
        switch status {
        case .done:
            return "done"
        case .timedOut:
            return "timed_out"
        case .needsConfirmation:
            return "confirm"
        case .failed:
            return "failed"
        case .cancelled:
            return "cancelled"
        }
    }

    private func presentComputerUseRuntimeResult(_ result: ComputerUsePlannerRuntimeResult) {
        let message: String
        let floatingMessage: String
        switch result.status {
        case .done:
            message = result.message.hasPrefix("Done") ? result.message : "Done: \(result.message)"
            floatingMessage = "Done"
        case .timedOut:
            message = result.message
            floatingMessage = "Timed out"
        case .needsConfirmation:
            message = result.message.hasPrefix("Confirm") ? result.message : "Confirm: \(result.message)"
            floatingMessage = "Confirm"
        case .failed:
            message = result.message
            floatingMessage = "Failed"
        case .cancelled:
            message = result.message
            floatingMessage = "Cancelled"
        }
        statusBarController?.setStatus(message)
        let terminalKind: ComputerUseCursorOverlay.TerminalKind
        switch result.status {
        case .done:
            terminalKind = .success
        case .timedOut, .needsConfirmation:
            terminalKind = .warning
        case .failed:
            terminalKind = .failure
        case .cancelled:
            terminalKind = .warning
        }
        ComputerUseCursorOverlay.shared.showTerminal(floatingMessage, kind: terminalKind)
    }

    /// Streaming RNNT dictation backend (handsfree live text at cursor).
    private var isStreamingDictationBackend: Bool {
        selectedBackend.isStreamingDictationBackend
    }

    private func ensureDictationBackendReady() -> Bool {
        guard !isDictationTestMode else { return true }
        guard !dictationBackendReadiness.allowsDictation else { return true }
        guard let message = dictationBackendReadiness.blockingMessage(
            backendLabel: selectedBackend.label
        ) else { return true }

        statusBarController?.setStatus(message)
        statusBarController?.refresh()
        dictationMiniIndicator.showWarning(message)
        return false
    }

    private func handlePrepare() {
        if shouldRejectDictationForComputerUseActivity() { return }
        // Meeting activity wins over backend readiness: the press is rejected either way,
        // and asking about readiness first puts a warmup pill on the meeting's own pill.
        guard canBeginDictationInteraction else { return }
        if isMeetingRecording() { return }
        if blockDictationForMeetingActivityIfNeeded() { return }
        guard ensureDictationBackendReady() else { return }
        fputs("[muesli-native] prepare\n", stderr)
        if dictationLatencyTraceID == nil {
            beginDictationLatencyTrace(reason: "prepare")
        }
        markDictationLatency("prepare_requested")
        guard !isStreamingDictationBackend else {
            return
        }
        if !dictationAudioSessionManager.hasActiveSession {
            meetingMonitor.suppressWhileActive()
            meetingMonitor.refreshState()
            setState(.preparing)
            dictationAudioSessionManager.arm(source: "hotkey_prepare")
        }
    }

    private func handleArm() {
        dictationHotkeyPressedAt = Date()
        if shouldRejectDictationForComputerUseActivity() { return }
        guard canBeginDictationInteraction else { return }
        if isMeetingRecording() { return }
        if blockDictationForMeetingActivityIfNeeded() { return }
        guard ensureDictationBackendReady() else { return }
        if dictationLatencyTraceID == nil {
            beginDictationLatencyTrace(reason: "hotkey")
        }
        if !isStreamingDictationBackend {
            setState(.preparing)
            meetingMonitor.suppressWhileActive()
            meetingMonitor.refreshState()
            if !dictationAudioSessionManager.hasActiveSession {
                dictationAudioSessionManager.arm(source: "hotkey_arm")
            }
        }
    }

    private var defaultDictationOutputMode: DictationOutputMode {
        config.resolvedOnboardingUseCase.includesVoiceNotes ? .voiceNote : .paste
    }

    private func beginDictationOutput(mode: DictationOutputMode? = nil) {
        currentDictationOutputMode = mode ?? defaultDictationOutputMode
        appState.isVoiceNoteRecording = currentDictationOutputMode == .voiceNote
    }

    private func resetDictationOutputMode() {
        currentDictationOutputMode = .paste
        appState.isVoiceNoteRecording = false
    }

    private var canPrimeDictationRecorder: Bool {
        config.hasCompletedOnboarding
            && hasStarted
            && config.resolvedOnboardingUseCase.includesPushToTalk
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && dictationState == .idle
            && !isMeetingAudioProcessing
            && computerUseCommandStartedAt == nil
            && !isMeetingRecording()
            && !isStartingMeetingRecording
            && !isStoppingMeetingRecording
    }

    private func coolDownDictationRecorder(reason: String) {
        dictationAudioSessionManager.coolDown(reason: reason)
    }

    private func syncDictationRecorderWarmup(intent: DictationWarmupIntent, delay: TimeInterval = 0) {
        dictationAudioSessionManager.refreshRoute(
            intent: intent,
            delay: delay,
            canWarmUp: canPrimeDictationRecorder && !isStreamingDictationBackend
        )
    }

    private func beginDictationLatencyTrace(reason: String) {
        dictationLatencyTraceID = UUID()
        dictationLatencyTraceStartedAt = Date()
        markDictationLatency("trace_begin:\(reason)")
    }

    private func markDictationLatency(_ event: String) {
        markDictationLatency(event, at: Date())
    }

    private func markDictationLatency(_ event: String, at date: Date) {
        guard let trace = currentDictationLatencyTrace else { return }
        markDictationLatency(event, at: date, trace: trace)
    }

    private var currentDictationLatencyTrace: DictationLatencyTraceToken? {
        guard let id = dictationLatencyTraceID,
              let startedAt = dictationLatencyTraceStartedAt else { return nil }
        return DictationLatencyTraceToken(id: id, startedAt: startedAt)
    }

    private func markDictationLatency(
        _ event: String,
        at date: Date = Date(),
        trace: DictationLatencyTraceToken?
    ) {
        guard let trace else { return }
        let elapsedMS = max(Int(date.timeIntervalSince(trace.startedAt) * 1000), 0)
        let timestamp = dictationLatencyTimestampFormatter.string(from: date)
        let routeKind = dictationAudioRoutingController.currentOutputRouteKindForDebug()
        // Keep the timing suffix content-free: never persist transcript, clipboard,
        // application, account, or route-device identity. New completion events are
        // represented by fixed PasteController.LifecycleEvent categories.
        let line = "[dictation-latency] ts=\(timestamp) id=\(trace.id.uuidString) event=\(event) elapsed_ms=\(elapsedMS) profile=\(dictationLatencyProfile(routeKind: routeKind))"
        fputs("\(line)\n", stderr)
        appendDictationLatencyLog(line)
    }

    private func dictationLatencyProfile(routeKind: AudioOutputRouteKind) -> String {
        switch routeKind {
        case .speakerLike:
            return "speaker"
        case .headphoneLike:
            return "headphone"
        case .unknown:
            return "unknown"
        }
    }

    private func appendDictationLatencyLog(_ line: String) {
        dictationLatencyLogWriter.append(line)
    }

    private func finishDictationLatencyTrace(_ event: String) {
        finishDictationLatencyTrace(event, trace: currentDictationLatencyTrace)
    }

    private func finishDictationLatencyTrace(
        _ event: String,
        trace: DictationLatencyTraceToken?
    ) {
        markDictationLatency(event, trace: trace)
        guard dictationLatencyTraceID == trace?.id else { return }
        dictationLatencyTraceID = nil
        dictationLatencyTraceStartedAt = nil
    }

    private func detachDictationLatencyTrace(_ event: String) -> DictationLatencyTraceSnapshot? {
        markDictationLatency(event)
        guard let id = dictationLatencyTraceID,
              let startedAt = dictationLatencyTraceStartedAt else { return nil }
        let routeKind = dictationAudioRoutingController.currentOutputRouteKindForDebug()
        let snapshot = DictationLatencyTraceSnapshot(
            id: id,
            startedAt: startedAt,
            profile: dictationLatencyProfile(routeKind: routeKind),
            routeDescription: dictationAudioRoutingController.currentRouteDebugDescription()
        )
        dictationLatencyTraceID = nil
        dictationLatencyTraceStartedAt = nil
        return snapshot
    }

    private func markDictationLatency(
        _ event: String,
        trace: DictationLatencyTraceSnapshot,
        at date: Date = Date()
    ) {
        let elapsedMS = max(Int(date.timeIntervalSince(trace.startedAt) * 1_000), 0)
        let timestamp = dictationLatencyTimestampFormatter.string(from: date)
        let line = "[dictation-latency] ts=\(timestamp) id=\(trace.id.uuidString) "
            + "event=\(event) elapsed_ms=\(elapsedMS) profile=\(trace.profile) \(trace.routeDescription)"
        fputs("\(line)\n", stderr)
        appendDictationLatencyLog(line)
    }

    private func cachedPreferredDictationInputDeviceID() -> AudioObjectID? {
        dictationAudioRoutingController.cachedPreferredInputDeviceIDForDictation()
    }

    private var shouldPlayDictationLifecycleSounds: Bool {
        DictationLifecycleFeedback.soundAllowed(preferenceEnabled: config.soundEnabled)
    }

    private var shouldPlayQuilLifecycleSounds: Bool {
        DictationLifecycleFeedback.soundAllowed(preferenceEnabled: config.quilSoundEnabled)
    }

    private func handleComputerUseAudioSessionEvent(_ event: DictationAudioSessionEvent) {
        switch event {
        case .armed(let sessionID, _):
            guard activeComputerUseAudioSessionID == sessionID else { break }
            break
        case .acquiringAudio(let sessionID):
            guard activeComputerUseAudioSessionID == sessionID else { break }
            ComputerUseCursorOverlay.shared.showAcquiring()
        case .streamActive(let sessionID, _):
            guard activeComputerUseAudioSessionID == sessionID,
                  computerUseCommandStartedAt != nil else { break }
            ComputerUseCursorOverlay.shared.showRecording { [weak self] in
                self?.computerUseAudioSessionManager.currentPower() ?? -160
            }
            SoundController.playDictationStart(
                enabled: shouldPlayDictationLifecycleSounds && !isDictationTestMode
            )
        case .speechDetected(let sessionID, _):
            guard activeComputerUseAudioSessionID == sessionID else { break }
            break
        case .noAudioTimeout(let sessionID, _):
            guard activeComputerUseAudioSessionID == sessionID else { break }
            statusBarController?.setStatus("Mic waiting for speech")
        case .stopped(let eventSessionID, let wavURL):
            guard pendingComputerUseStopSessionID == eventSessionID else {
                fputs("[cua] ignoring stale stopped event\n", stderr)
                if let wavURL {
                    try? FileManager.default.removeItem(at: wavURL)
                }
                if let eventSessionID {
                    dictationAudioSessionManager.acknowledgeTerminalCapture(sessionID: eventSessionID)
                }
                break
            }
            guard computerUseAudioSessionManager.currentSessionID == nil else {
                fputs("[cua] ignoring stopped event while a new session is active\n", stderr)
                if let wavURL {
                    try? FileManager.default.removeItem(at: wavURL)
                }
                break
            }
            let startedAt = pendingComputerUseStopStartedAt ?? Date()
            pendingComputerUseStopSessionID = nil
            pendingComputerUseStopStartedAt = nil
            finishComputerUseAudioStop(wavURL: wavURL, startedAt: startedAt)
        case .audioRestored, .cancelled:
            break
        case .failed(let sessionID, let error, _):
            guard let sessionID,
                  activeComputerUseAudioSessionID == sessionID
                    || pendingComputerUseStopSessionID == sessionID else { break }
            fputs("[cua] recorder start failed: \(error)\n", stderr)
            activeComputerUseAudioSessionID = nil
            computerUseCommandStartedAt = nil
            pendingComputerUseStopSessionID = nil
            pendingComputerUseStopStartedAt = nil
            computerUseHotkeyMonitor.cancelToggleMode()
            ComputerUseCursorOverlay.shared.showTerminal("CUA recording failed", kind: .failure)
            meetingMonitor.resumeAfterCooldown()
            meetingMonitor.refreshState()
        case .latency(_, let event, _):
            fputs("[cua-audio] \(event)\n", stderr)
        }
    }

    private func handleQuilAudioSessionEvent(_ event: DictationAudioSessionEvent) {
        switch event {
        case .armed(let sessionID, _):
            guard activeQuilAudioSessionID == sessionID else { break }
        case .acquiringAudio(let sessionID):
            guard activeQuilAudioSessionID == sessionID else { break }
            setState(.preparing)
        case .streamActive(let sessionID, _):
            guard activeQuilAudioSessionID == sessionID, quilStartedAt != nil else { break }
            setState(.recording)
            SoundController.playQuillStart(
                enabled: shouldPlayQuilLifecycleSounds && !isDictationTestMode
            )
            // Mic activation is the primary Quill interaction. Discover the
            // selection/insertion target only after the stream and activation cue
            // are live, so AX or Google Docs clipboard fallback work cannot delay
            // or suppress recording. A missing target is reported after release.
            captureQuilTargetIfNeeded()
        case .speechDetected(let sessionID, _):
            guard activeQuilAudioSessionID == sessionID else { break }
        case .noAudioTimeout(let sessionID, _):
            guard activeQuilAudioSessionID == sessionID else { break }
            statusBarController?.setStatus("Mic waiting for instruction")
        case .stopped(let sessionID, let wavURL):
            guard pendingQuilStopSessionID == sessionID else {
                if let wavURL { try? FileManager.default.removeItem(at: wavURL) }
                break
            }
            guard quilAudioSessionManager.currentSessionID == nil else {
                if let wavURL { try? FileManager.default.removeItem(at: wavURL) }
                break
            }
            let startedAt = pendingQuilStopStartedAt ?? Date()
            pendingQuilStopSessionID = nil
            pendingQuilStopStartedAt = nil
            finishQuilAudioStop(wavURL: wavURL, startedAt: startedAt)
        case .audioRestored, .cancelled:
            break
        case .failed(let sessionID, let error, _):
            guard let sessionID,
                  activeQuilAudioSessionID == sessionID || pendingQuilStopSessionID == sessionID else { break }
            presentQuilFailure(error)
        case .latency(_, let event, _):
            fputs("[quil-audio] \(event)\n", stderr)
        }
    }

    private func handleDictationAudioSessionEvent(_ event: DictationAudioSessionEvent) {
        switch event {
        case .armed(let sessionID, _):
            applyDictationLifecycleActions(dictationLifecycleFeedback.begin(
                sessionID: sessionID,
                isTestMode: isDictationTestMode
            ))
            let sessionConfig = activeDictationStyleSession?.config ?? config
            let selection = frozenDictationTranscriptionSelection(sessionConfig: sessionConfig)
            frozenDictationTranscriptionSelections[sessionID] = selection
            _ = ensureDictationSessionTrace(
                id: sessionID,
                backend: selection.backend,
                cleanupBackend: TranscriptCleanupBackendOption.resolved(
                    sessionConfig.postProcessorBackend
                ),
                languageProfile: selection.languageProfile,
                contextSources: ""
            )
        case .acquiringAudio(let sessionID):
            if dictationLifecycleFeedback.foregroundSessionID != sessionID {
                applyDictationLifecycleActions(dictationLifecycleFeedback.begin(
                    sessionID: sessionID,
                    isTestMode: isDictationTestMode
                ))
            }
            let sessionConfig = activeDictationStyleSession?.config ?? config
            let selection = frozenDictationTranscriptionSelections[sessionID]
                ?? frozenDictationTranscriptionSelection(sessionConfig: sessionConfig)
            if frozenDictationTranscriptionSelections[sessionID] == nil {
                frozenDictationTranscriptionSelections[sessionID] = selection
            }
            _ = ensureDictationSessionTrace(
                id: sessionID,
                backend: selection.backend,
                cleanupBackend: TranscriptCleanupBackendOption.resolved(
                    sessionConfig.postProcessorBackend
                ),
                languageProfile: selection.languageProfile,
                contextSources: ""
            )
            markDictationLatency("acquiring_audio")
            activateDictationPreparingIndicator()
        case .streamActive(let sessionID, let capturedAt):
            guard !cancelledDictationAudioSessionIDs.contains(sessionID) else {
                fputs("[muesli-native] ignoring stream-active for cancelled session\n", stderr)
                break
            }
            handleDictationStreamActive(sessionID: sessionID, capturedAt: capturedAt)
        case .speechDetected(_, let capturedAt):
            handleDictationSpeechDetected(capturedAt: capturedAt)
        case .noAudioTimeout:
            statusBarController?.setStatus("Mic waiting for speech")
        case .stopped(let eventSessionID, let wavURL):
            if let eventSessionID {
                cancelledDictationAudioSessionIDs.remove(eventSessionID)
            }
            guard let eventSessionID,
                  let pendingStop = pendingStandardDictationStops.removeValue(forKey: eventSessionID) else {
                fputs("[muesli-native] ignoring stale stopped event\n", stderr)
                if let wavURL {
                    try? FileManager.default.removeItem(at: wavURL)
                }
                break
            }
            finishStandardDictationStop(wavURL: wavURL, pendingStop: pendingStop)
            dictationAudioSessionManager.acknowledgeTerminalCapture(sessionID: eventSessionID)
        case .audioRestored:
            break
        case .cancelled(let sessionID, let reason, let terminalCapture):
            guard let sessionID else { break }
            cancelledDictationAudioSessionIDs.remove(sessionID)
            frozenDictationTranscriptionSelections.removeValue(forKey: sessionID)
            let startedAt = pendingStandardDictationStops[sessionID]?.startedAt
                ?? dictationStartedAt
                ?? Date()
            let trace = dictationSessionTraces.removeValue(forKey: sessionID)
                ?? ensureDictationSessionTrace(id: sessionID)
            Task { @MainActor [weak self] in
                defer { self?.dictationAudioSessionManager.acknowledgeTerminalCapture(sessionID: sessionID) }
                let didWin = await trace.cancel(
                    stage: "dictation_audio_session",
                    metadata: ["reason": reason]
                )
                guard didWin, let self else {
                    if let wavURL = terminalCapture?.wavURL {
                        try? FileManager.default.removeItem(at: wavURL)
                    }
                    return
                }
                self.applyDictationLifecycleActions(self.dictationLifecycleFeedback.finish(
                    sessionID: sessionID,
                    outcome: .neutral,
                    soundAllowed: self.shouldPlayDictationLifecycleSounds
                ))
                guard let terminalCapture else { return }
                await self.persistAudioOnlyDictationRecording(
                    capture: terminalCapture,
                    startedAt: startedAt,
                    durationSeconds: max(Date().timeIntervalSince(startedAt), 0)
                )
            }
        case .failed(let sessionID, let error, let terminalCapture):
            fputs("[muesli-native] recorder start failed: \(error)\n", stderr)
            if let sessionID {
                cancelledDictationAudioSessionIDs.remove(sessionID)
            }
            let terminalStartedAt = sessionID.flatMap { pendingStandardDictationStops[$0]?.startedAt }
                ?? dictationStartedAt
                ?? Date()
            if let sessionID {
                frozenDictationTranscriptionSelections.removeValue(forKey: sessionID)
                let trace = dictationSessionTraces.removeValue(forKey: sessionID)
                    ?? ensureDictationSessionTrace(id: sessionID)
                Task { @MainActor [weak self] in
                    defer { self?.dictationAudioSessionManager.acknowledgeTerminalCapture(sessionID: sessionID) }
                    let didWin: Bool
                    if terminalCapture?.outcome == .timedOut {
                        didWin = await trace.claimTerminal(
                            .timedOut,
                            metadata: ["stage": "dictation_audio_session"]
                        )
                    } else {
                        didWin = await trace.fail(stage: "dictation_audio_session")
                    }
                    guard didWin, let self else {
                        if let wavURL = terminalCapture?.wavURL {
                            try? FileManager.default.removeItem(at: wavURL)
                        }
                        return
                    }
                    self.applyDictationLifecycleActions(self.dictationLifecycleFeedback.finish(
                        sessionID: sessionID,
                        outcome: .failure(recovery: .unavailable),
                        soundAllowed: self.shouldPlayDictationLifecycleSounds
                    ))
                    guard let terminalCapture else { return }
                    await self.persistAudioOnlyDictationRecording(
                        capture: terminalCapture,
                        startedAt: terminalStartedAt,
                        durationSeconds: max(Date().timeIntervalSince(terminalStartedAt), 0)
                    )
                }
            }
            if let sessionID,
               let pendingStop = pendingStandardDictationStops.removeValue(forKey: sessionID) {
                if !pendingStop.isTestMode {
                    recordDiagnosticIncident(
                        kind: .dictationAudioFailed,
                        stage: .dictationAudioSession,
                        backend: pendingStop.backend,
                        error: error
                    )
                }
                if let trace = pendingStop.latencyTrace {
                    markDictationLatency("audio_session_failed", trace: trace)
                }
                completeStandardDictationStop(.discarded, sequence: pendingStop.sequence)
                break
            }
            if !isDictationTestMode {
                recordDiagnosticIncident(
                    kind: .dictationAudioFailed,
                    stage: .dictationAudioSession,
                    backend: selectedBackend,
                    error: error
                )
            }
            resetDictationOutputMode()
            dictationStartedAt = nil
            clearCapturedDictationSessionContext()
            finishDictationLatencyTrace("audio_session_failed")
            standardDictationWorkChanged()
        case .latency(let sessionID, let event, let date):
            if let sessionID,
               let pendingTrace = pendingStandardDictationStops[sessionID]?.latencyTrace {
                markDictationLatency(event, trace: pendingTrace, at: date)
            } else if sessionID == dictationAudioSessionManager.currentSessionID {
                markDictationLatency(event, at: date)
            }
        }
    }

    private func activateDictationPreparingIndicator() {
        setState(.preparing)
    }

    private func activateDictationRecordingIndicator() {
        setState(.recording)
    }

    private func handleDictationStreamActive(sessionID: UUID, capturedAt: Date) {
        markDictationLatency("ui_stream_active_handling_begin")
        markDictationLatency("ui_stream_active_received", at: capturedAt)
        if dictationStartedAt == nil {
            dictationStartedAt = capturedAt
        }
        activateDictationRecordingIndicator()
        markDictationLatency("sound_start_requested:stream-active")
        applyDictationLifecycleActions(dictationLifecycleFeedback.streamActive(
            sessionID: sessionID,
            soundAllowed: shouldPlayDictationLifecycleSounds
        ))
        markDictationLatency("ui_stream_active")
        logDictationPowerSample(label: "ui_power_sample_350ms", delay: 0.35)
        logDictationPowerSample(label: "ui_power_sample_1000ms", delay: 1.0)
        if isDictationTestMode {
            dictationTestRecordingStarted?()
        }
        if shouldCaptureDictationContext {
            captureDictationContextAsync()
        }
    }

    private func handleDictationSpeechDetected(capturedAt: Date) {
        markDictationLatency("ui_speech_active", at: capturedAt)
    }

    private func logDictationPowerSample(label: String, delay: TimeInterval) {
        let traceID = dictationLatencyTraceID
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, traceID] in
            guard let self,
                  self.dictationLatencyTraceID == traceID,
                  self.dictationState == .recording else { return }
            let power = Int(self.dictationAudioSessionManager.currentPower().rounded())
            self.markDictationLatency("\(label)_db:\(power)")
        }
    }

    private var shouldCaptureDictationContext: Bool {
        guard let session = activeDictationStyleSession else { return false }
        return session.config.enableScreenContext
            && session.config.enablePostProcessor
            && !isDictationTestMode
    }

    @MainActor
    private func shouldContinueDictationOCRContextCapture(sessionID: UUID) -> Bool {
        activeDictationStyleSession?.id == sessionID
            && shouldCaptureDictationContext
            && dictationState == .recording
            && !isMeetingRecording()
    }

    private func captureDictationContextAsync() {
        guard shouldCaptureDictationContext,
              let session = activeDictationStyleSession,
              let target = session.target else { return }
        let sessionID = session.id
        let includeScreenOCR = session.config.enableDictationOCRContext
            && !isMeetingRecording()
            && CGPreflightScreenCaptureAccess()
        markDictationLatency("context_capture_enqueue")
        Task.detached(priority: .utility) { [weak self, sessionID, target, includeScreenOCR] in
            guard AXIsProcessTrusted() else { return }
            guard let baseContext = DictationContextCapture.capture(target: target) else { return }
            let baseResult = DictationSessionContextResult(sessionID: sessionID, context: baseContext)
            await MainActor.run { [weak self, sessionID] in
                guard let self,
                      self.activeDictationStyleSession?.id == sessionID,
                      self.shouldCaptureDictationContext,
                      self.dictationState == .recording else { return }
                self.activeDictationContextResult = baseResult
                self.markDictationLatency("context_capture_base_ready")
            }
            guard includeScreenOCR else { return }
            let enrichedContext = await DictationContextCapture.enrichWithScreenOCR(
                baseContext,
                target: target,
                includeScreenOCR: true,
                shouldCaptureScreenOCR: { [weak self] in
                    await self?.shouldContinueDictationOCRContextCapture(sessionID: sessionID) ?? false
                }
            )
            guard !enrichedContext.ocrText.isEmpty else { return }
            let enrichedResult = DictationSessionContextResult(sessionID: sessionID, context: enrichedContext)
            await MainActor.run { [weak self, sessionID] in
                guard let self,
                      self.activeDictationStyleSession?.id == sessionID,
                      self.shouldCaptureDictationContext,
                      self.dictationState == .recording else { return }
                self.activeDictationContextResult = enrichedResult
                self.markDictationLatency("context_capture_ocr_ready")
            }
        }
    }

    private func clearCapturedDictationSessionContext() {
        activeDictationStyleSession = nil
        activeDictationContextResult = nil
        stoppedDictationStyleSession = nil
        stoppedDictationContextResult = nil
    }

    private func beginDictationStyleSession(mode: DictationStyleSessionMode) {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let target = DictationSessionTarget(
            app: frontmostApplication == NSRunningApplication.current
                ? lastExternalApp
                : frontmostApplication
        )
        let sessionConfig = config
        let cleanupBackend = TranscriptCleanupBackendOption.resolved(sessionConfig.postProcessorBackend)
        let cleanupOption = runtimePostProcessorOption(config: sessionConfig, backend: cleanupBackend)
        let transcriptionBackend = BackendOption.resolve(
            backend: sessionConfig.sttBackend,
            model: sessionConfig.sttModel
        ) ?? selectedBackend
        let cleanupRuntime = DictationCleanupRuntimeSnapshot(
            readiness: transcriptCleanupReadiness(
                option: cleanupOption,
                config: sessionConfig,
                transcriptionBackend: transcriptionBackend,
                cleanupBackend: cleanupBackend
            ),
            backend: cleanupBackend,
            option: cleanupOption,
            config: sessionConfig
        )
        activeDictationStyleSession = DictationStyleSessionSnapshot(
            target: target,
            config: sessionConfig,
            mode: isDictationTestMode
                ? .dictationTest
                : (currentDictationOutputMode == .voiceNote ? .voiceNote : mode),
            cleanupRuntime: cleanupRuntime
        )
        activeDictationContextResult = nil
        stoppedDictationStyleSession = nil
        stoppedDictationContextResult = nil
    }

    private func freezeDictationStyleSessionAtStop() {
        stoppedDictationStyleSession = activeDictationStyleSession
        stoppedDictationContextResult = activeDictationContextResult
        activeDictationStyleSession = nil
        activeDictationContextResult = nil
    }

    /// The external app that owned focus, ignoring Muesli itself, for dictation
    /// attribution. `lastExternalApp` covers the case where Muesli's own window
    /// came forward between the paste and this read.
    private func currentExternalDictationTargetApp() -> (appName: String, bundleID: String)? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app = frontmost == NSRunningApplication.current ? lastExternalApp : frontmost
        guard let app else { return nil }
        return (app.localizedName ?? "Unknown", app.bundleIdentifier ?? "")
    }

    private func handleStart() {
        if shouldRejectDictationForComputerUseActivity() { return }
        guard canBeginDictationInteraction else { return }
        if isMeetingRecording() { return }
        if blockDictationForMeetingActivityIfNeeded() { return }
        guard ensureDictationBackendReady() else { return }

        // Nemotron backends support hold-to-talk (record → transcribe on release) in
        // addition to double-tap handsfree streaming. The hold path uses the normal
        // record-then-transcribe pipeline below; double-tap streaming is handled in
        // handleToggleStart. Prepare/arm pre-warm is intentionally skipped for these
        // backends (see isStreamingDictationBackend) so the double-tap detection window
        // stays clean; beginRecording cold-starts here just like the toggle path.
        fputs("[muesli-native] recording start\n", stderr)
        meetingMonitor.suppressWhileActive()
        beginDictationOutput()
        dictationStartedAt = nil
        clearCapturedDictationSessionContext()
        beginDictationStyleSession(mode: .standard)
        setState(.preparing)
        dictationAudioSessionManager.beginRecording(
            mode: "hold-start",
            duckingEnabled: config.muteSystemAudioDuringDictation,
            mediaPauseEnabled: config.pauseMediaDuringDictation,
            recordingSavePolicy: activeDictationRecordingSavePolicy
        )
    }

    private var activeDictationRecordingSavePolicy: DictationRecordingSavePolicy {
        activeDictationStyleSession?.config.dictationRecordingSavePolicy
            ?? config.dictationRecordingSavePolicy
    }

    @available(macOS 15, *)
    private func startNemotronStreamingAsync(
        sessionID: UUID,
        recordingSavePolicy: DictationRecordingSavePolicy,
        languageProfile: LanguageProfile
    ) {
        Task {
            let transcriber: Nemotron35StreamingTranscriber
            do {
                transcriber = try await transcriptionCoordinator.getLoadedNemotron35Transcriber()
            } catch {
                await MainActor.run {
                    self.handleNemotronStreamingStartFailure(
                        error: error,
                        sessionID: sessionID,
                        recordingSavePolicy: recordingSavePolicy
                    )
                }
                return
            }
            fputs("[muesli-native] got Nemotron 3.5 transcriber\n", stderr)
            let chunkSamples = transcriber.chunkSamples
            let promptId = Nemotron35Language.promptId(
                for: Self.dictationLanguageDecision(
                    profile: languageProfile,
                    backend: .nemotron35Multilingual
                )
            )
            let makeController: @MainActor (AudioObjectID?) -> StreamingDictationController = { preferredID in
                StreamingDictationController(
                    transcriber: transcriber,
                    preferredInputDeviceID: preferredID,
                    chunkSamples: chunkSamples,
                    makeStreamState: {
                        try await transcriber.makeStreamState(promptId: promptId)
                    }
                )
            }

            await MainActor.run {
                guard self.isNemotron35Streaming, self.nemotron35StreamingSessionID == sessionID else {
                    fputs("[muesli-native] Nemotron session cancelled before transcriber ready\n", stderr)
                    return
                }
                let currentPreferredInputDeviceID =
                    self.dictationAudioRoutingController.cachedPreferredInputDeviceIDForDictation()
                let controller = makeController(currentPreferredInputDeviceID)
                controller.onPartialText = { [weak self] fullText in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        guard self.isNemotron35Streaming, self.nemotron35StreamingSessionID == sessionID else { return }
                        let delta = String(fullText.dropFirst(self.previousStreamText.count))
                        fputs("[muesli-native] streaming partial: +\"\(delta)\" (total \(fullText.count) chars)\n", stderr)
                        if !delta.isEmpty {
                            self.previousStreamText = fullText
                            if self.currentDictationOutputMode != .voiceNote {
                                PasteController.typeText(delta)
                            }
                        }
                    }
                }
                controller.onFailureWithCapture = { [weak self] error, captureURL in
                    DispatchQueue.main.async {
                        self?.handleNemotronStreamingRuntimeFailure(
                            error: error,
                            sessionID: sessionID,
                            captureURL: captureURL,
                            recordingSavePolicy: recordingSavePolicy
                        )
                    }
                }
                controller.onStartFailureWithCapture = { [weak self] error, captureURL in
                    DispatchQueue.main.async {
                        self?.handleNemotronStreamingStartFailure(
                            error: error,
                            sessionID: sessionID,
                            captureURL: captureURL,
                            recordingSavePolicy: recordingSavePolicy
                        )
                    }
                }
                self._streamingDictationController = controller
                guard controller.start(recordingSavePolicy: recordingSavePolicy) else {
                    return
                }
                self.activateDictationRecordingIndicator()
                if let token = self.dictationMiniGeneration {
                    self.dictationMiniIndicator.updatePowerProvider(generation: token) { [weak controller] in
                        controller?.currentPower() ?? -160
                    }
                }
                self.applyDictationLifecycleActions(self.dictationLifecycleFeedback.streamActive(
                    sessionID: sessionID,
                    soundAllowed: self.shouldPlayDictationLifecycleSounds
                ))
                fputs("[muesli-native] Nemotron streaming controller started\n", stderr)
            }
        }
    }

    @MainActor
    private func handleNemotronStreamingStartFailure(
        error: Error,
        sessionID: UUID,
        captureURL: URL? = nil,
        recordingSavePolicy: DictationRecordingSavePolicy
    ) {
        guard isNemotron35Streaming, nemotron35StreamingSessionID == sessionID else { return }
        let startedAt = dictationStartedAt ?? Date()
        fputs("[muesli-native] Nemotron streaming controller failed to start\n", stderr)
        if !isDictationTestMode {
            recordDiagnosticIncident(
                kind: .streamingDictationStartFailed,
                stage: .nemotronStreamingStart,
                backend: selectedBackend,
                error: error
            )
        }
        let trace = dictationSessionTraces.removeValue(forKey: sessionID)
        Task { @MainActor [weak self] in
            let didWin = await trace?.fail(stage: "nemotron_streaming_start") ?? true
            guard didWin, let self else {
                if let captureURL { try? FileManager.default.removeItem(at: captureURL) }
                return
            }
            self.applyDictationLifecycleActions(self.dictationLifecycleFeedback.finish(
                sessionID: sessionID,
                outcome: .failure(recovery: .unavailable),
                soundAllowed: self.shouldPlayDictationLifecycleSounds
            ))
            guard recordingSavePolicy != .never else {
                if let captureURL { try? FileManager.default.removeItem(at: captureURL) }
                return
            }
            await self.persistAudioOnlyDictationRecording(
                capture: DictationAudioTerminalCapture(
                    sessionID: sessionID,
                    outcome: .failed,
                    recordingSavePolicy: recordingSavePolicy,
                    wavURL: captureURL
                ),
                startedAt: startedAt,
                durationSeconds: max(Date().timeIntervalSince(startedAt), 0)
            )
        }
        isNemotron35Streaming = false
        _streamingDictationController = nil
        nemotron35StreamingSessionID = nil
        nemotron35StreamingRecordingSavePolicy = .never
        previousStreamText = ""
        dictationStartedAt = nil
        clearCapturedDictationSessionContext()
        dictationAudioSessionManager.endExternalSession(reason: "nemotron-start-failed")
        resetDictationOutputMode()
        finishDictationLatencyTrace("nemotron_start_failed")
        standardDictationWorkChanged()
        if standardDictationWorkCount == 0 {
            syncDictationRecorderWarmup(intent: .idlePrewarm(.backendRecovery))
        }
    }

    @MainActor
    private func handleNemotronStreamingRuntimeFailure(
        error: Error,
        sessionID: UUID,
        captureURL: URL? = nil,
        recordingSavePolicy: DictationRecordingSavePolicy = .never
    ) {
        guard isNemotron35Streaming, nemotron35StreamingSessionID == sessionID else { return }
        let startedAt = dictationStartedAt ?? Date()
        fputs("[muesli-native] Nemotron streaming failed: \(error)\n", stderr)
        if !isDictationTestMode {
            recordDiagnosticIncident(
                kind: .streamingDictationRuntimeFailed,
                stage: .nemotronStreamingRuntime,
                backend: selectedBackend,
                error: error
            )
        }
        let trace = dictationSessionTraces.removeValue(forKey: sessionID)
        Task { @MainActor [weak self] in
            let didWin = await trace?.fail(stage: "nemotron_streaming_runtime") ?? true
            guard didWin, let self else {
                if let captureURL { try? FileManager.default.removeItem(at: captureURL) }
                return
            }
            self.applyDictationLifecycleActions(self.dictationLifecycleFeedback.finish(
                sessionID: sessionID,
                outcome: .failure(recovery: .unavailable),
                soundAllowed: self.shouldPlayDictationLifecycleSounds
            ))
            guard recordingSavePolicy != .never else {
                if let captureURL { try? FileManager.default.removeItem(at: captureURL) }
                return
            }
            await self.persistAudioOnlyDictationRecording(
                capture: DictationAudioTerminalCapture(
                    sessionID: sessionID,
                    outcome: .failed,
                    recordingSavePolicy: recordingSavePolicy,
                    wavURL: captureURL
                ),
                startedAt: startedAt,
                durationSeconds: max(Date().timeIntervalSince(startedAt), 0)
            )
        }
        isNemotron35Streaming = false
        _streamingDictationController = nil
        nemotron35StreamingSessionID = nil
        nemotron35StreamingRecordingSavePolicy = .never
        previousStreamText = ""
        dictationStartedAt = nil
        clearCapturedDictationSessionContext()
        dictationAudioSessionManager.endExternalSession(reason: "nemotron-runtime-failed")
        resetDictationOutputMode()
        finishDictationLatencyTrace("nemotron_runtime_failed")
        standardDictationWorkChanged()
        if standardDictationWorkCount == 0 {
            syncDictationRecorderWarmup(intent: .idlePrewarm(.backendRecovery))
        }
    }

    /// Marks the live audio session as cancelled before the asynchronous teardown so a late
    /// `.streamActive` for it is ignored, then cancels it.
    private func cancelDictationAudioSession(reason: String, retainCapture: Bool = true) {
        if let sessionID = dictationAudioSessionManager.currentSessionID {
            cancelledDictationAudioSessionIDs.insert(sessionID)
        }
        dictationAudioSessionManager.cancel(reason: reason, retainCapture: retainCapture)
    }

    /// An eager-start press resolved as a tap: same teardown as a cancel, but the capture is
    /// dropped regardless of the save policy so a tap never leaves a history row or a prompt.
    private func handleTapDiscard() {
        handleCancel(retainCapture: false)
    }

    private func handleCancel(retainCapture: Bool = true) {
        pendingStartCueToken = nil
        dictationHotkeyPressedAt = nil
        if isMeetingRecording() { return }
        if shouldIgnoreDictationCleanupForComputerUseActivity() { return }
        fputs("[muesli-native] \(retainCapture ? "cancel" : "tap-discard")\n", stderr)
        if shouldIgnoreCleanupAfterBlockedDictationStart {
            fputs("[muesli-native] ignoring dictation cancel because start was blocked\n", stderr)
            return
        }
        fputs("[muesli-native] cancel\n", stderr)
        resetDictationOutputMode()

        if isNemotron35Streaming {
            let sessionID = nemotron35StreamingSessionID
            let startedAt = dictationStartedAt ?? Date()
            let recordingSavePolicy = nemotron35StreamingRecordingSavePolicy
            let captureURL: URL?
            isNemotron35Streaming = false
            if #available(macOS 15, *), let sdc = _streamingDictationController as? StreamingDictationController {
                captureURL = sdc.cancel()
            } else {
                captureURL = nil
            }
            _streamingDictationController = nil
            nemotron35StreamingSessionID = nil
            nemotron35StreamingRecordingSavePolicy = .never
            previousStreamText = ""
            if let sessionID {
                let trace = dictationSessionTraces.removeValue(forKey: sessionID)
                Task { @MainActor [weak self] in
                    let didWin = await trace?.cancel(stage: "nemotron_streaming") ?? true
                    guard didWin, let self else {
                        if let captureURL { try? FileManager.default.removeItem(at: captureURL) }
                        return
                    }
                    self.applyDictationLifecycleActions(self.dictationLifecycleFeedback.finish(
                        sessionID: sessionID,
                        outcome: .neutral,
                        soundAllowed: self.shouldPlayDictationLifecycleSounds
                    ))
                    guard retainCapture, recordingSavePolicy != .never else {
                        if let captureURL { try? FileManager.default.removeItem(at: captureURL) }
                        return
                    }
                    await self.persistAudioOnlyDictationRecording(
                        capture: DictationAudioTerminalCapture(
                            sessionID: sessionID,
                            outcome: .cancelled,
                            recordingSavePolicy: recordingSavePolicy,
                            wavURL: captureURL
                        ),
                        startedAt: startedAt,
                        durationSeconds: max(Date().timeIntervalSince(startedAt), 0)
                    )
                }
            }
        }

        cancelDictationAudioSession(
            reason: retainCapture ? "user-cancel" : "tap-discard",
            retainCapture: retainCapture
        )
        clearCapturedDictationSessionContext()
        dictationStartedAt = nil
        finishDictationLatencyTrace("cancelled")
        standardDictationWorkChanged()
        if standardDictationWorkCount == 0 {
            syncDictationRecorderWarmup(intent: .postDictation(.cancel))
        }
    }

    @discardableResult
    private func handleToggleStart(outputMode: DictationOutputMode? = nil) -> Bool {
        if shouldRejectDictationForComputerUseActivity() { return false }
        guard canBeginDictationInteraction else { return false }
        if isMeetingRecording() { return false }
        if blockDictationForMeetingActivityIfNeeded() { return false }
        guard ensureDictationBackendReady() else { return false }
        fputs("[muesli-native] toggle dictation start\n", stderr)
        if dictationLatencyTraceID == nil {
            beginDictationLatencyTrace(reason: "toggle")
        }
        markDictationLatency("toggle_start")
        meetingMonitor.suppressWhileActive()
        beginDictationOutput(mode: outputMode)
        dictationMiniIndicator.showToast("Hands-free — tap \(config.dictationHotkey.label) to stop")
        dictationStartedAt = nil
        clearCapturedDictationSessionContext()
        beginDictationStyleSession(mode: isStreamingDictationBackend ? .streaming : .standard)
        setState(.preparing)

        // Nemotron streaming: live text at cursor in handsfree mode too
        if isStreamingDictationBackend {
            if #available(macOS 15, *) {
                let sessionID = UUID()
                let recordingSavePolicy = activeDictationRecordingSavePolicy
                let languageProfile = activeDictationStyleSession?.config.languageProfile
                    ?? config.languageProfile
                isNemotron35Streaming = true
                nemotron35StreamingSessionID = sessionID
                nemotron35StreamingRecordingSavePolicy = recordingSavePolicy
                applyDictationLifecycleActions(dictationLifecycleFeedback.begin(
                    sessionID: sessionID,
                    isTestMode: isDictationTestMode
                ))
                let sessionTrace = ensureDictationSessionTrace(
                    id: sessionID,
                    backend: selectedBackend,
                    cleanupBackend: selectedPostProcessorBackend,
                    startedAt: Date(),
                    languageProfile: languageProfile,
                    contextSources: ""
                )
                Task {
                    await sessionTrace.recordStageStarted("nemotron_streaming")
                }
                previousStreamText = ""
                dictationStartedAt = Date()
                dictationAudioSessionManager.beginExternalSession(
                    source: "nemotron-toggle",
                    duckingEnabled: config.muteSystemAudioDuringDictation,
                    mediaPauseEnabled: config.pauseMediaDuringDictation
                )
                meetingMonitor.refreshState()
                fputs("[muesli-native] Nemotron streaming toggle mode active\n", stderr)
                startNemotronStreamingAsync(
                    sessionID: sessionID,
                    recordingSavePolicy: recordingSavePolicy,
                    languageProfile: languageProfile
                )
                return true
            }
        }

        dictationAudioSessionManager.beginRecording(
            mode: "toggle",
            duckingEnabled: config.muteSystemAudioDuringDictation,
            mediaPauseEnabled: config.pauseMediaDuringDictation,
            recordingSavePolicy: activeDictationRecordingSavePolicy
        )
        return true
    }

    private func handleToggleStop() {
        fputs("[muesli-native] toggle dictation stop\n", stderr)
        handleStop()
    }

    func toggleVoiceNoteRecording() {
        if dictationStartedAt != nil || dictationAudioSessionManager.hasActiveSession || isNemotron35Streaming {
            handleToggleStop()
        } else if dictationState == .idle || dictationState == .transcribing {
            handleToggleStart(outputMode: .voiceNote)
        }
    }

    /// Hands-free dictation start for Shortcuts/App Intents. No-op (returns
    /// false) if dictation is already active or a meeting is recording or
    /// still starting, mirroring the admission guards the hotkey path uses.
    @discardableResult
    public func startDictationForShortcuts() -> Bool {
        guard config.hasCompletedOnboarding,
              ensureBasicDictationPermissionsBeforeDashboard(),
              !isDictationActivityInProgress,
              !dictationAudioSessionManager.hasActiveSession,
              canBeginDictationInteraction,
              !isMeetingRecording(),
              !isStartingMeetingRecording else { return false }
        return handleToggleStart()
    }

    /// Hands-free dictation stop for Shortcuts/App Intents. No-op (returns
    /// false) if dictation isn't currently active.
    @discardableResult
    public func stopDictationForShortcuts() -> Bool {
        guard dictationStartedAt != nil || dictationAudioSessionManager.hasActiveSession || isNemotron35Streaming else { return false }
        handleToggleStop()
        return true
    }

    /// Meeting recording start for Shortcuts/App Intents. Thin public wrapper
    /// around `startMeetingRecording` so that method's internal enum-typed
    /// parameters don't need to become part of the public API surface.
    @discardableResult
    public func startMeetingRecordingForShortcuts(title: String = "Meeting") -> Bool {
        guard config.hasCompletedOnboarding else { return false }
        return startMeetingRecordingFromEntryPoint(
            title: title,
            presentation: .backgroundPill
        )
    }

    /// Meeting recording stop for Shortcuts/App Intents. Cancels a pending
    /// meeting start through the same `cancelMeetingPreparation()` path the
    /// UI uses, stops an already-active recording, or returns false when no
    /// meeting is starting or recording.
    @discardableResult
    public func stopMeetingRecordingForShortcuts() -> Bool {
        if isStartingMeetingRecording, activeMeetingSession == nil {
            cancelMeetingPreparation()
            return true
        }
        guard isMeetingRecording() else { return false }
        stopMeetingRecording()
        return true
    }

    private func handleStop() {
        dictationHotkeyPressedAt = nil
        if isMeetingRecording() {
            cancelDictationAudioSessionForMeetingRecordingIfNeeded()
            return
        }
        if shouldIgnoreDictationCleanupForComputerUseActivity() { return }
        if shouldIgnoreCleanupAfterBlockedDictationStart {
            fputs("[muesli-native] ignoring dictation stop because start was blocked\n", stderr)
            return
        }
        fputs("[muesli-native] stop\n", stderr)
        let startedAt = dictationStartedAt ?? Date()
        dictationStartedAt = nil

        // Nemotron streaming: text already typed — just finalize and store
        if isNemotron35Streaming {
            let sessionID = nemotron35StreamingSessionID
            let recordingSavePolicy = nemotron35StreamingRecordingSavePolicy
            if #available(macOS 15, *), let controller = _streamingDictationController as? StreamingDictationController {
                let acceptedCapture = controller.stopWithCapture { [weak self] result in
                    DispatchQueue.main.async {
                        self?.finishNemotronStreamingStop(
                            finalText: result.transcript,
                            captureURL: result.captureURL,
                            recordingSavePolicy: recordingSavePolicy,
                            startedAt: startedAt,
                            sessionID: sessionID
                        )
                    }
                }
                if acceptedCapture, let sessionID {
                    applyDictationLifecycleActions(dictationLifecycleFeedback.captureAccepted(
                        sessionID: sessionID,
                        soundAllowed: shouldPlayDictationLifecycleSounds
                    ))
                }
                dictationAudioSessionManager.endExternalSession(reason: "nemotron-stop")
                setState(.transcribing)
            } else {
                fputs("[muesli-native] Nemotron streaming stop, controller not ready (short press)\n", stderr)
                // Finishes synchronously and settles on .idle — no transcription follows,
                // so this path must not be moved back to .transcribing.
                finishNemotronStreamingStop(
                    finalText: "",
                    captureURL: nil,
                    recordingSavePolicy: recordingSavePolicy,
                    startedAt: startedAt,
                    sessionID: sessionID
                )
                dictationAudioSessionManager.endExternalSession(reason: "nemotron-stop")
            }
            return
        }

        // Freeze whatever base context is ready now. Stop never waits for the
        // optional OCR enrichment, and late capture completions are rejected.
        freezeDictationStyleSessionAtStop()
        markDictationLatency("sound_release_requested:stop")
        guard let sessionID = dictationAudioSessionManager.currentSessionID else {
            fputs("[muesli-native] stop requested without an active audio session\n", stderr)
            finishDictationLatencyTrace("stop_without_session")
            settleStandardDictationSessionWithoutJob(intent: .postDictation(.stopWithoutWav))
            return
        }
        pendingStandardDictationStops[sessionID] = capturePendingStandardDictationStop(
            id: sessionID,
            startedAt: startedAt
        )
        clearCapturedDictationSessionContext()
        resetDictationOutputMode()
        dictationAudioSessionManager.stop()
    }

    private func capturePendingStandardDictationStop(
        id: UUID,
        startedAt: Date
    ) -> PendingStandardDictationStop {
        let sequence = nextStandardDictationStopSequence
        nextStandardDictationStopSequence &+= 1
        let isTestMode = isDictationTestMode
        let styleSession = stoppedDictationStyleSession
        let contextResult = stoppedDictationContextResult
        let sessionConfig = styleSession?.config ?? config
        let transcriptionSelection = frozenDictationTranscriptionSelections.removeValue(forKey: id)
            ?? frozenDictationTranscriptionSelection(sessionConfig: sessionConfig)
        let transcriptionBackend = transcriptionSelection.backend
        let frozenLanguageProfile = transcriptionSelection.languageProfile
        let capturedContext = styleSession?.matchingContext(contextResult)
        let correctionTargetApp = styleSession?.target
        let cleanupRuntime = styleSession?.mode.allowsAdaptiveStyles == true
            ? styleSession?.cleanupRuntime
            : nil
        let cleanupBackend = cleanupRuntime?.backend
            ?? TranscriptCleanupBackendOption.resolved(sessionConfig.postProcessorBackend)
        let ppOption = cleanupRuntime?.option
            ?? runtimePostProcessorOption(config: sessionConfig, backend: cleanupBackend)
        let cleanupReadiness = cleanupRuntime?.readiness ?? transcriptCleanupReadiness(
            option: ppOption,
            config: sessionConfig,
            transcriptionBackend: transcriptionBackend,
            cleanupBackend: cleanupBackend
        )
        let cleanupPolicy = styleSession?.cleanupPolicy(
            readiness: cleanupReadiness,
            context: contextResult
        ) ?? DictationCleanupPolicy(
            readiness: cleanupReadiness,
            systemPromptSnapshot: DictationCleanupPromptComposer.systemPrompt(
                config: sessionConfig,
                selection: nil,
                cleanupBackend: cleanupBackend,
                option: ppOption
            )
        )
        let cleanupRuntimeSnapshot = cleanupRuntime ?? DictationCleanupRuntimeSnapshot(
            readiness: cleanupReadiness,
            backend: cleanupBackend,
            option: ppOption,
            config: sessionConfig
        )
        let cleanupRequest = DictationCleanupRequestSnapshot(
            runtime: cleanupRuntimeSnapshot,
            policy: cleanupPolicy
        )
        let detectedSpeech: Bool
        if case .speechDetected(let sessionID) = dictationAudioSessionManager.currentState {
            detectedSpeech = sessionID == id
        } else {
            detectedSpeech = false
        }
        let sessionTrace = dictationSessionTraces[id] ?? ensureDictationSessionTrace(
            id: id,
            backend: transcriptionBackend,
            cleanupBackend: cleanupBackend,
            startedAt: startedAt,
            languageProfile: frozenLanguageProfile,
            contextSources: capturedContext.map { DictationContextCapture.formatForPrompt($0) } ?? ""
        )
        Task {
            await sessionTrace.storeArtifact(
                capturedContext.map { DictationContextCapture.formatForPrompt($0) } ?? "",
                kind: .contextSources
            )
        }
        return PendingStandardDictationStop(
            id: id,
            sequence: sequence,
            startedAt: startedAt,
            isTestMode: isTestMode,
            outputMode: currentDictationOutputMode,
            backend: transcriptionBackend,
            languageProfile: frozenLanguageProfile,
            promptContext: capturedContext.map { DictationContextCapture.formatForPrompt($0) },
            storageContext: capturedContext.map { DictationContextCapture.formatForStorage($0) }
                ?? correctionTargetApp?.appContext
                ?? "",
            correctionTargetApp: correctionTargetApp,
            customWords: serializedCustomWords(from: sessionConfig),
            cleanupRequest: cleanupRequest,
            detectedSpeech: detectedSpeech,
            recordingSavePolicy: sessionConfig.dictationRecordingSavePolicy,
            latencyTrace: detachDictationLatencyTrace("stop_requested"),
            sessionTrace: sessionTrace
        )
    }

    private func ensureDictationSessionTrace(
        id: UUID,
        backend: BackendOption? = nil,
        cleanupBackend: TranscriptCleanupBackendOption? = nil,
        startedAt: Date = Date(),
        languageProfile: LanguageProfile? = nil,
        contextSources: String? = nil
    ) -> SessionRunTrace {
        if let existing = dictationSessionTraces[id] { return existing }
        let resolvedBackend = backend ?? selectedBackend
        let resolvedCleanup = cleanupBackend ?? selectedPostProcessorBackend
        var initialArtifacts: [SessionTraceInitialArtifact] = []
        if let languageProfile {
            initialArtifacts.append(SessionTraceInitialArtifact(
                content: SessionTraceSnapshot.languageProfile(
                    backend: resolvedBackend,
                    profile: languageProfile
                ),
                kind: .languageProfile
            ))
        }
        if let contextSources {
            initialArtifacts.append(SessionTraceInitialArtifact(
                content: contextSources,
                kind: .contextSources
            ))
        }
        let trace = SessionRunTrace(
            id: id,
            store: sessionTraceStore,
            kind: .dictation,
            backendIdentity: SessionTraceSnapshot.backendIdentity(resolvedBackend),
            fallbackBackendIdentity: SessionTraceSnapshot.cleanupIdentity(resolvedCleanup),
            startedAt: startedAt,
            initialArtifacts: initialArtifacts,
            onTerminalWriteFinished: sessionTraceCompletionHandler()
        )
        dictationSessionTraces[id] = trace
        sessionTraceRegistry[id] = trace
        return trace
    }

    private func frozenDictationTranscriptionSelection(
        sessionConfig: AppConfig
    ) -> FrozenDictationTranscriptionSelection {
        Self.frozenDictationTranscriptionSelection(
            sessionConfig: sessionConfig,
            defaultBackend: selectedBackend,
            isTestMode: isDictationTestMode,
            testBackend: dictationTestBackend,
            testCohereLanguage: dictationTestCohereLanguage
        )
    }

    nonisolated static func frozenDictationTranscriptionSelection(
        sessionConfig: AppConfig,
        defaultBackend: BackendOption,
        isTestMode: Bool,
        testBackend: BackendOption?,
        testCohereLanguage: CohereTranscribeLanguage?
    ) -> FrozenDictationTranscriptionSelection {
        let configuredBackend = BackendOption.resolve(
            backend: sessionConfig.sttBackend,
            model: sessionConfig.sttModel
        ) ?? defaultBackend
        let backend = isTestMode ? (testBackend ?? configuredBackend) : configuredBackend
        guard isTestMode,
              backend.backend == "cohere",
              let testCohereLanguage,
              let language = TranscriptionLanguage(rawValue: testCohereLanguage.rawValue),
              let profile = try? LanguageProfile(
                  selectedLanguages: [language],
                  dominantLanguage: language,
                  meetingOutputPolicy: sessionConfig.languageProfile.meetingOutputPolicy
              ) else {
            return FrozenDictationTranscriptionSelection(
                backend: backend,
                languageProfile: sessionConfig.languageProfile
            )
        }
        return FrozenDictationTranscriptionSelection(
            backend: backend,
            languageProfile: profile
        )
    }

    /// Meeting-family traces record the meeting selection resolved with the
    /// workload of the call they describe, not dictation routing.
    private func makeMeetingSessionTrace(
        id: UUID = UUID(),
        backend: BackendOption,
        startedAt: Date,
        selection: TranscriptionLanguageSelection,
        workload: TranscriptionWorkload,
        meetingOutputPolicy: MeetingOutputLanguagePolicy
    ) -> SessionRunTrace {
        let trace = SessionRunTrace(
            id: id,
            store: sessionTraceStore,
            kind: .meeting,
            backendIdentity: SessionTraceSnapshot.backendIdentity(backend),
            fallbackBackendIdentity: SessionTraceSnapshot.fallbackIdentity(
                kind: "summary",
                value: selectedMeetingSummaryBackend.backend
            ),
            startedAt: startedAt,
            initialArtifacts: [
                SessionTraceInitialArtifact(
                    content: SessionTraceSnapshot.languageProfile(
                        backend: backend,
                        selection: selection,
                        workload: workload,
                        meetingOutputPolicy: meetingOutputPolicy
                    ),
                    kind: .languageProfile
                ),
            ],
            onTerminalWriteFinished: sessionTraceCompletionHandler()
        )
        sessionTraceRegistry[id] = trace
        return trace
    }

    private func sessionTraceCompletionHandler() -> @Sendable (UUID) -> Void {
        { [weak self] sessionID in
            Task { @MainActor [weak self] in
                self?.sessionTraceRegistry.removeValue(forKey: sessionID)
            }
        }
    }

    private func cancelDictationAudioSessionForMeetingRecordingIfNeeded() {
        let hasComputerUseActivity = interactiveAudioSessionOwnership.computerUseIsActive
        let hasQuilActivity = interactiveAudioSessionOwnership.quilIsActive
        guard dictationAudioSessionManager.hasActiveSession
            || isNemotron35Streaming
            || hasComputerUseActivity
            || hasQuilActivity else { return }
        fputs("[muesli-native] cancelling dictation audio session because meeting is active\n", stderr)

        if hasComputerUseActivity {
            handleComputerUseCancel()
        }
        if hasQuilActivity {
            clearQuilSession(cancelAudioReason: "meeting-active")
        }

        if isNemotron35Streaming {
            let streamingSessionID = nemotron35StreamingSessionID
            let startedAt = dictationStartedAt ?? Date()
            let recordingSavePolicy = nemotron35StreamingRecordingSavePolicy
            let captureURL: URL?
            isNemotron35Streaming = false
            if #available(macOS 15, *), let controller = _streamingDictationController as? StreamingDictationController {
                captureURL = controller.cancel()
            } else {
                captureURL = nil
            }
            _streamingDictationController = nil
            nemotron35StreamingSessionID = nil
            nemotron35StreamingRecordingSavePolicy = .never
            previousStreamText = ""
            if let streamingSessionID {
                let trace = dictationSessionTraces.removeValue(forKey: streamingSessionID)
                Task { @MainActor [weak self] in
                    let didWin = await trace?.cancel(stage: "meeting_started") ?? true
                    guard didWin, let self else {
                        if let captureURL { try? FileManager.default.removeItem(at: captureURL) }
                        return
                    }
                    self.applyDictationLifecycleActions(self.dictationLifecycleFeedback.finish(
                        sessionID: streamingSessionID,
                        outcome: .neutral,
                        soundAllowed: self.shouldPlayDictationLifecycleSounds
                    ))
                    guard recordingSavePolicy != .never else {
                        if let captureURL { try? FileManager.default.removeItem(at: captureURL) }
                        return
                    }
                    await self.persistAudioOnlyDictationRecording(
                        capture: DictationAudioTerminalCapture(
                            sessionID: streamingSessionID,
                            outcome: .cancelled,
                            recordingSavePolicy: recordingSavePolicy,
                            wavURL: captureURL
                        ),
                        startedAt: startedAt,
                        durationSeconds: max(Date().timeIntervalSince(startedAt), 0)
                    )
                }
            }
            dictationAudioSessionManager.endExternalSession(reason: "meeting-active")
        } else if dictationAudioSessionManager.hasActiveSession {
            cancelDictationAudioSession(reason: "meeting-active")
        }

        dictationStartedAt = nil
        clearCapturedDictationSessionContext()
        resetDictationOutputMode()
        setState(.idle)
        if activeMeetingID != nil || isStartingMeetingRecording || isMeetingRecording() {
            meetingMonitor.suppressWhileActive()
        } else {
            meetingMonitor.resumeAfterCooldown()
        }
        meetingMonitor.refreshState()
        finishDictationLatencyTrace("meeting_active_cancel")
        syncDictationRecorderWarmup(intent: .idlePrewarm(.meetingStateChanged))
    }

    private func finishNemotronStreamingStop(
        finalText: String,
        captureURL: URL?,
        recordingSavePolicy: DictationRecordingSavePolicy,
        startedAt: Date,
        sessionID: UUID?
    ) {
        guard isNemotron35Streaming, nemotron35StreamingSessionID == sessionID else {
            fputs("[muesli-native] ignoring stale Nemotron stop completion\n", stderr)
            return
        }
        isNemotron35Streaming = false
        _streamingDictationController = nil
        nemotron35StreamingSessionID = nil
        nemotron35StreamingRecordingSavePolicy = .never
        let deliveredStreamingPrefix = previousStreamText
        let streamingOutputMode = currentDictationOutputMode
        previousStreamText = ""
        let duration = max(Date().timeIntervalSince(startedAt), 0)
        let outputMode = currentDictationOutputMode
        fputs("[muesli-native] Nemotron streaming stop, got \(finalText.count) chars\n", stderr)
        let cleaned = FillerWordFilter.apply(finalText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionTrace = sessionID.flatMap { dictationSessionTraces.removeValue(forKey: $0) }
        let shouldPersistTargetApp = DictationAttributionPolicy.shouldPersist(
            isPasteOutput: outputMode == .paste,
            source: "dictation",
            text: cleaned
        )
        // If focus moved during streaming, attribute the completed session to the app active at stop.
        let targetApp = shouldPersistTargetApp ? currentExternalDictationTargetApp() : nil

        if !config.maraudersMapUnlocked { checkMaraudersMapActivation(cleaned) }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let recordingArtifact: RecordingArtifact?
            if recordingSavePolicy != .never,
               let captureURL,
               let sessionID {
                recordingArtifact = await self.adoptDictationRecording(
                    at: captureURL,
                    sessionID: sessionID,
                    policy: recordingSavePolicy,
                    terminalAt: Date()
                )
            } else {
                recordingArtifact = nil
                if let captureURL { try? FileManager.default.removeItem(at: captureURL) }
            }
            let recordingAvailability = recordingAvailability(for: recordingArtifact)
            let recordingReference = dictationRecordingReference(
                policy: recordingSavePolicy,
                artifact: recordingArtifact
            )
            let dictationID: Int64?
            if !cleaned.isEmpty {
                dictationID = try? self.dictationStore.insertDictation(
                    text: cleaned,
                    durationSeconds: duration,
                    dictationCleanupOutcome: DictationCleanupOutcome.skippedStreaming.rawValue,
                    targetAppName: targetApp?.appName,
                    targetAppBundleID: targetApp?.bundleID,
                    startedAt: startedAt,
                    endedAt: Date(),
                    recording: recordingReference
                )
            } else {
                dictationID = nil
                if let sessionID, let store = self.recordingArtifactStore,
                   recordingSavePolicy != .never {
                    try? await Task.detached(priority: .utility) {
                        try store.insertAudioOnlyDictationHistory(
                            sessionID: sessionID,
                            capturedAt: startedAt,
                            durationSeconds: duration,
                            terminalOutcome: .empty,
                            artifactID: recordingArtifact?.id,
                            availability: recordingAvailability
                        )
                    }.value
                }
            }
            await sessionTrace?.storeArtifact(finalText, kind: .rawASR)
            await sessionTrace?.storeArtifact(cleaned, kind: .cleanupResult)
            await sessionTrace?.storeArtifact(
                DictationDictionaryTrace.emptyContent,
                kind: .dictionaryChanges
            )
            await sessionTrace?.storeArtifact(cleaned, kind: .finalOutput)
            if let dictationID {
                await sessionTrace?.associate(dictationID: dictationID)
            }
            let didWin = await sessionTrace?.claimTerminal(
                .success,
                metadata: [
                    "cleanup_outcome": DictationCleanupOutcome.skippedStreaming.rawValue,
                    "history_created": String(dictationID != nil),
                    "output_characters": String(cleaned.count),
                ]
            ) ?? true
            guard didWin else {
                if let dictationID,
                   let artifactID = try? self.dictationStore.deleteDictation(id: dictationID),
                   let store = self.recordingArtifactStore {
                    try? await Task.detached(priority: .utility) {
                        try store.finishDurableDeletion(id: artifactID)
                    }.value
                } else if let sessionID {
                    await self.discardLateAudioOnlyDictation(
                        sessionID: sessionID,
                        artifact: recordingArtifact
                    )
                }
                return
            }
            if let sessionID {
                let feedbackOutcome: DictationLifecycleFeedback.Outcome
                if cleaned.isEmpty {
                    feedbackOutcome = .neutral
                } else if streamingOutputMode == .voiceNote {
                    feedbackOutcome = dictationID == nil
                        ? .failure(recovery: .unavailable)
                        : .success
                } else {
                    let deliveredCount = min(deliveredStreamingPrefix.count, finalText.count)
                    let remainder = String(finalText.dropFirst(deliveredCount))
                    if !remainder.isEmpty {
                        PasteController.typeText(remainder)
                    }
                    feedbackOutcome = deliveredStreamingPrefix.isEmpty && remainder.isEmpty
                        ? .neutral
                        : .success
                }
                self.applyDictationLifecycleActions(self.dictationLifecycleFeedback.finish(
                    sessionID: sessionID,
                    outcome: feedbackOutcome,
                    soundAllowed: self.shouldPlayDictationLifecycleSounds
                ))
            }
            if recordingSavePolicy == .prompt, let recordingArtifact {
                self.presentDictationRecordingDecision(for: recordingArtifact.id)
            }
            if dictationID != nil {
                self.scheduleICloudSyncAfterLocalChange()
            }
            self.statusBarController?.refresh()
            self.historyWindowController?.reload()
            self.syncAppState()
            self.clearCapturedDictationSessionContext()
            self.resetDictationOutputMode()
            fputs("[muesli-native] Nemotron streaming done (\(String(format: "%.1f", duration))s)\n", stderr)
            self.finishDictationLatencyTrace("nemotron_stop")
            self.standardDictationWorkChanged()
            if self.standardDictationWorkCount == 0 {
                self.syncDictationRecorderWarmup(intent: .idlePrewarm(.backendRecovery))
            }
        }
    }

    private func adoptDictationRecording(
        at sourceURL: URL,
        sessionID: UUID,
        policy: DictationRecordingSavePolicy,
        terminalAt: Date
    ) async -> RecordingArtifact? {
        guard let store = recordingArtifactStore,
              let savePolicy = policy.artifactPolicySnapshot else {
            try? FileManager.default.removeItem(at: sourceURL)
            return nil
        }
        do {
            let artifact = try await Task.detached(priority: .utility) {
                try store.adoptCapture(
                    at: sourceURL,
                    sessionID: sessionID,
                    captureKind: .dictation,
                    savePolicy: savePolicy,
                    terminalAt: terminalAt
                )
            }.value
            try? await Task.detached(priority: .utility) {
                try store.attachDiagnostic(
                    sessionID: sessionID,
                    artifactID: artifact.id,
                    availability: artifact.lifecycleState == .pending ? .pending : .available
                )
            }.value
            return artifact
        } catch {
            try? FileManager.default.removeItem(at: sourceURL)
            fputs("[dictation-recording] failed to retain capture: \(error)\n", stderr)
            return nil
        }
    }

    private func recordingAvailability(for artifact: RecordingArtifact?) -> RecordingAvailability {
        guard let artifact else { return .saveFailed }
        return artifact.lifecycleState == .pending ? .pending : .available
    }

    private func dictationRecordingReference(
        policy: DictationRecordingSavePolicy,
        artifact: RecordingArtifact?
    ) -> RecordingArtifactReference? {
        guard policy != .never else { return nil }
        return RecordingArtifactReference(
            artifactID: artifact?.id,
            availability: recordingAvailability(for: artifact)
        )
    }

    private func discardLateAudioOnlyDictation(
        sessionID: UUID,
        artifact: RecordingArtifact?
    ) async {
        guard let store = recordingArtifactStore else { return }
        let artifactToDelete = try? await Task.detached(priority: .utility) {
            try store.deleteAudioOnlyDictationHistory(sessionID: sessionID)
        }.value
        if let artifactToDelete {
            try? await Task.detached(priority: .utility) {
                try store.finishDurableDeletion(id: artifactToDelete)
            }.value
        } else if let artifact {
            try? await Task.detached(priority: .utility) {
                try store.deleteArtifact(id: artifact.id)
            }.value
        }
    }

    private func persistAudioOnlyDictationRecording(
        capture: DictationAudioTerminalCapture,
        startedAt: Date,
        durationSeconds: TimeInterval
    ) async {
        guard let sessionID = capture.sessionID,
              capture.recordingSavePolicy != .never,
              let store = recordingArtifactStore else {
            if let wavURL = capture.wavURL {
                try? FileManager.default.removeItem(at: wavURL)
            }
            return
        }

        let terminalAt = Date()
        let artifact: RecordingArtifact?
        if let wavURL = capture.wavURL {
            artifact = await adoptDictationRecording(
                at: wavURL,
                sessionID: sessionID,
                policy: capture.recordingSavePolicy,
                terminalAt: terminalAt
            )
        } else {
            artifact = nil
        }
        let availability = recordingAvailability(for: artifact)
        let outcome: DictationAudioTerminalOutcome = switch capture.outcome {
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .failed: .failed
        }
        do {
            try await Task.detached(priority: .utility) {
                try store.insertAudioOnlyDictationHistory(
                    sessionID: sessionID,
                    capturedAt: startedAt,
                    durationSeconds: durationSeconds,
                    terminalOutcome: outcome,
                    artifactID: artifact?.id,
                    availability: availability
                )
            }.value
        } catch {
            if let artifact {
                try? await Task.detached(priority: .utility) {
                    try store.deleteArtifact(id: artifact.id)
                }.value
            }
            fputs("[dictation-recording] failed to create audio-only history: \(error)\n", stderr)
            return
        }

        historyWindowController?.reload()
        if capture.recordingSavePolicy == .prompt, let artifact {
            presentDictationRecordingDecision(for: artifact.id)
        }
    }

    private func persistUnavailableAudioOnlyDictation(
        sessionID: UUID,
        startedAt: Date,
        durationSeconds: TimeInterval,
        outcome: DictationAudioTerminalOutcome,
        availability: RecordingAvailability
    ) async {
        guard let store = recordingArtifactStore else { return }
        do {
            try await Task.detached(priority: .utility) {
                try store.insertAudioOnlyDictationHistory(
                    sessionID: sessionID,
                    capturedAt: startedAt,
                    durationSeconds: durationSeconds,
                    terminalOutcome: outcome,
                    artifactID: nil,
                    availability: availability
                )
            }.value
            historyWindowController?.reload()
        } catch {
            fputs("[dictation-recording] failed to create unavailable audio history: \(error)\n", stderr)
        }
    }

    private func presentDictationRecordingDecision(for artifactID: RecordingArtifactID) {
        Task { @MainActor [weak self] in
            guard let self, let store = self.recordingArtifactStore else { return }
            let artifact = try? await Task.detached(priority: .utility) {
                try store.enforcePendingCapacity()
                return try store.artifact(id: artifactID)
            }.value
            await RecordingArtifactPlaybackCoordinator.shared.refreshAllCachedOwners()
            guard artifact != nil else {
                self.historyWindowController?.reload()
                self.syncAppState()
                return
            }
            self.scheduleDictationRecordingExpiry(artifactID)
            let shouldKeep = await self.promptToSaveDictationRecording()
            guard let store = self.recordingArtifactStore else { return }
            do {
                try await Task.detached(priority: .utility) {
                    if shouldKeep {
                        try store.retainPendingArtifact(id: artifactID)
                    } else {
                        try store.declinePendingArtifact(id: artifactID)
                    }
                }.value
            } catch {
                fputs("[dictation-recording] failed to resolve save decision: \(error)\n", stderr)
            }
            await RecordingArtifactPlaybackCoordinator.shared.refreshAllCachedOwners()
            self.historyWindowController?.reload()
        }
    }

    private func scheduleDictationRecordingExpiry(_ artifactID: RecordingArtifactID) {
        guard let store = recordingArtifactStore,
              let artifact = try? store.artifact(id: artifactID),
              let expiresAt = artifact.pendingExpiresAt else { return }
        Task { @MainActor [weak self] in
            let delay = max(expiresAt.timeIntervalSinceNow, 0)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            let expired = (try? await Task.detached(priority: .utility) {
                try store.expirePendingArtifactIfNeeded(id: artifactID, now: Date())
            }.value) == true
            guard expired, let self else { return }
            await RecordingArtifactPlaybackCoordinator.shared.refreshAllCachedOwners()
            self.historyWindowController?.reload()
            self.syncAppState()
        }
    }

    private func promptToSaveDictationRecording() async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Save dictation recording?"
        alert.informativeText = "Keep the source audio with this dictation. If you close this prompt, the temporary recording is deleted."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save Recording")
        alert.addButton(withTitle: "Delete Recording")
        guard let window = alertPresentationWindow(showHistoryIfNeeded: true) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    private func finishStandardDictationStop(
        wavURL stoppedWavURL: URL?,
        pendingStop: PendingStandardDictationStop
    ) {
        if let trace = pendingStop.latencyTrace {
            markDictationLatency("stop_finished", trace: trace)
        }
        guard let wavURL = stoppedWavURL else {
            fputs("[muesli-native] stop without wav\n", stderr)
            if let trace = pendingStop.latencyTrace {
                markDictationLatency("stop_without_wav", trace: trace)
            }
            dictationSessionTraces.removeValue(forKey: pendingStop.id)
            Task { @MainActor [weak self] in
                let didWin = await pendingStop.sessionTrace.cancel(
                    stage: "dictation_stop",
                    metadata: ["reason": "missing_wav"]
                )
                guard didWin, let self else { return }
                self.applyDictationLifecycleActions(self.dictationLifecycleFeedback.finish(
                    sessionID: pendingStop.id,
                    outcome: .neutral,
                    soundAllowed: self.shouldPlayDictationLifecycleSounds
                ))
                guard pendingStop.recordingSavePolicy != .never else { return }
                await self.persistAudioOnlyDictationRecording(
                    capture: DictationAudioTerminalCapture(
                        sessionID: pendingStop.id,
                        outcome: .cancelled,
                        recordingSavePolicy: pendingStop.recordingSavePolicy,
                        wavURL: nil
                    ),
                    startedAt: pendingStop.startedAt,
                    durationSeconds: max(Date().timeIntervalSince(pendingStop.startedAt), 0)
                )
            }
            completeStandardDictationStop(.discarded, sequence: pendingStop.sequence)
            return
        }
        let duration = max(Date().timeIntervalSince(pendingStop.startedAt), 0)
        if duration < 0.3 {
            fputs("[muesli-native] discarded short recording\n", stderr)
            if pendingStop.recordingSavePolicy == .never {
                try? FileManager.default.removeItem(at: wavURL)
            }
            if pendingStop.isTestMode {
                dictationTestCallback?("")
            }
            if let trace = pendingStop.latencyTrace {
                markDictationLatency("short_recording", trace: trace)
            }
            dictationSessionTraces.removeValue(forKey: pendingStop.id)
            Task { @MainActor [weak self] in
                let didWin = await pendingStop.sessionTrace.cancel(
                    stage: "dictation_stop",
                    metadata: ["reason": "short_recording"]
                )
                guard didWin, let self else {
                    if pendingStop.recordingSavePolicy != .never {
                        try? FileManager.default.removeItem(at: wavURL)
                    }
                    return
                }
                self.applyDictationLifecycleActions(self.dictationLifecycleFeedback.finish(
                    sessionID: pendingStop.id,
                    outcome: .neutral,
                    soundAllowed: self.shouldPlayDictationLifecycleSounds
                ))
                guard pendingStop.recordingSavePolicy != .never else { return }
                await self.persistAudioOnlyDictationRecording(
                    capture: DictationAudioTerminalCapture(
                        sessionID: pendingStop.id,
                        outcome: .cancelled,
                        recordingSavePolicy: pendingStop.recordingSavePolicy,
                        wavURL: wavURL
                    ),
                    startedAt: pendingStop.startedAt,
                    durationSeconds: duration
                )
            }
            completeStandardDictationStop(.discarded, sequence: pendingStop.sequence)
            return
        }

        let job = StandardDictationJob(
            id: pendingStop.id,
            wavURL: wavURL,
            startedAt: pendingStop.startedAt,
            duration: duration,
            isTestMode: pendingStop.isTestMode,
            outputMode: pendingStop.outputMode,
            backend: pendingStop.backend,
            languageProfile: pendingStop.languageProfile,
            promptContext: pendingStop.promptContext,
            storageContext: pendingStop.storageContext,
            correctionTargetApp: pendingStop.correctionTargetApp,
            customWords: pendingStop.customWords,
            cleanupRequest: pendingStop.cleanupRequest,
            detectedSpeech: pendingStop.detectedSpeech,
            recordingSavePolicy: pendingStop.recordingSavePolicy,
            latencyTrace: pendingStop.latencyTrace,
            sessionTrace: pendingStop.sessionTrace
        )
        completeStandardDictationStop(.job(job), sequence: pendingStop.sequence)
    }

    private func completeStandardDictationStop(
        _ completion: CompletedStandardDictationStop,
        sequence: UInt64
    ) {
        for next in completedStandardDictationStops.insert(completion, sequence: sequence) {
            if case .job(let job) = next {
                if job.isTestMode { dictationTestJobIDs.insert(job.id) }
                applyDictationLifecycleActions(dictationLifecycleFeedback.captureAccepted(
                    sessionID: job.id,
                    soundAllowed: shouldPlayDictationLifecycleSounds
                ))
                standardDictationJobQueue.enqueue(job)
            }
        }
        standardDictationWorkChanged()
    }

    private func settleStandardDictationSessionWithoutJob(intent: DictationWarmupIntent) {
        standardDictationWorkChanged()
        if standardDictationWorkCount == 0 {
            syncDictationRecorderWarmup(intent: intent)
        }
    }

    private var standardDictationWorkCount: Int {
        pendingStandardDictationStops.count
            + completedStandardDictationStops.count
            + standardDictationJobQueue.count
    }

    private func standardDictationJobCountChanged(_: Int) {
        standardDictationWorkChanged()
    }

    private func standardDictationWorkChanged() {
        reconcileTranscriptionActivityUI()
    }

    private func reconcileTranscriptionActivityUI() {
        guard dictationStartedAt == nil,
              !dictationAudioSessionManager.hasActiveSession,
              !isNemotron35Streaming,
              !isMeetingRecording(),
              !isStartingMeetingRecording else { return }
        let ownership = TranscriptionActivityOwnership(
            queuedDictations: standardDictationWorkCount,
            meetingFinalizations: 0
        )
        if ownership.isActive {
            guard dictationState != .transcribing else { return }
            setState(.transcribing)
            meetingMonitor.suppressWhileActive()
        } else {
            guard dictationState != .idle else { return }
            setState(.idle)
            meetingMonitor.resumeAfterCooldown()
            meetingMonitor.refreshState()
            syncDictationRecorderWarmup(intent: .postDictation(.transcriptionComplete))
        }
    }

    private func processStandardDictationJob(_ job: StandardDictationJob) async {
        defer {
            try? FileManager.default.removeItem(at: job.wavURL)
            dictationTestJobIDs.remove(job.id)
            dictationSessionTraces.removeValue(forKey: job.id)
        }

        do {
            let cleanupRuntime = job.cleanupRequest.runtime
            let cleanupPolicy = job.cleanupRequest.policy
            await transcriptionCoordinator.configurePostProcessor(
                backend: cleanupRuntime.backend,
                option: cleanupRuntime.option,
                systemPrompt: cleanupPolicy.systemPromptSnapshot,
                config: cleanupRuntime.config
            )
            let stageReporter: TranscriptionCoordinator.DictationStageReporter = { [weak self] event in
                self?.handleDictationStageEvent(event, for: job)
            }
            let traceReporter: TranscriptionCoordinator.DictationTraceReporter = { event in
                await Self.recordDictationTraceEvent(event, trace: job.sessionTrace)
            }
            await job.sessionTrace.recordStageStarted("speech_recognition")
            let frozenLanguageDecision = Self.dictationLanguageDecision(
                profile: job.languageProfile,
                backend: job.backend
            )
            let result = try await transcriptionCoordinator.transcribeDictationWithCleanupOutcome(
                at: job.wavURL,
                backend: job.backend,
                languageDecision: frozenLanguageDecision,
                cohereLanguage: job.languageProfile.resolvedCohereLanguage,
                indicASRLanguage: job.languageProfile.resolvedIndicASRLanguage,
                nemotron35Language: job.languageProfile.resolvedNemotron35Language,
                whisperLanguage: job.languageProfile.resolvedWhisperLanguage,
                enablePostProcessor: cleanupPolicy.readiness == .ready,
                cleanupRequestSnapshot: job.cleanupRequest,
                customWords: job.customWords,
                appContext: job.promptContext,
                stageReporter: stageReporter,
                traceReporter: traceReporter
            )
            try Task.checkCancellation()
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            let recordingArtifact: RecordingArtifact?
            if job.recordingSavePolicy == .never {
                recordingArtifact = nil
            } else {
                recordingArtifact = await adoptDictationRecording(
                    at: job.wavURL,
                    sessionID: job.id,
                    policy: job.recordingSavePolicy,
                    terminalAt: Date()
                )
            }
            let recordingAvailability = recordingAvailability(for: recordingArtifact)
            let recordingReference = dictationRecordingReference(
                policy: job.recordingSavePolicy,
                artifact: recordingArtifact
            )

            guard !text.isEmpty else {
                if job.recordingSavePolicy != .never,
                   let store = recordingArtifactStore {
                    try? await Task.detached(priority: .utility) {
                        try store.insertAudioOnlyDictationHistory(
                            sessionID: job.id,
                            capturedAt: job.startedAt,
                            durationSeconds: job.duration,
                            terminalOutcome: .empty,
                            artifactID: recordingArtifact?.id,
                            availability: recordingAvailability
                        )
                    }.value
                }
                let didWin = await job.sessionTrace.claimTerminal(
                    result.cleanupOutcome.terminalTraceOutcome,
                    metadata: [
                        "cleanup_outcome": result.cleanupOutcome.rawValue,
                        "output_characters": "0",
                    ]
                )
                if didWin {
                    applyDictationLifecycleActions(dictationLifecycleFeedback.finish(
                        sessionID: job.id,
                        outcome: .neutral,
                        soundAllowed: shouldPlayDictationLifecycleSounds
                    ))
                }
                if didWin, job.recordingSavePolicy == .prompt, let recordingArtifact {
                    presentDictationRecordingDecision(for: recordingArtifact.id)
                } else if !didWin {
                    await discardLateAudioOnlyDictation(
                        sessionID: job.id,
                        artifact: recordingArtifact
                    )
                }
                if job.isTestMode, didWin {
                    dictationTestCallback?(text)
                }
                if let trace = job.latencyTrace {
                    let speechStatus = job.detectedSpeech ? "detected_speech" : "no_detected_speech"
                    markDictationLatency("empty_result:\(speechStatus)", trace: trace)
                }
                return
            }

            let dictationID = try? dictationStore.insertDictation(
                text: text,
                durationSeconds: job.duration,
                appContext: job.storageContext,
                dictationStyleID: result.cleanupStyle?.styleID,
                dictationStyleName: result.cleanupStyle?.styleName,
                dictationStyleSelectionSource: result.cleanupStyle?.source.rawValue,
                dictationCleanupOutcome: result.cleanupOutcome.rawValue,
                startedAt: job.startedAt,
                endedAt: Date(),
                recording: recordingReference
            )
            if dictationID == nil, let store = recordingArtifactStore,
               job.recordingSavePolicy != .never {
                try? await Task.detached(priority: .utility) {
                    try store.insertAudioOnlyDictationHistory(
                        sessionID: job.id,
                        capturedAt: job.startedAt,
                        durationSeconds: job.duration,
                        terminalOutcome: .failed,
                        artifactID: recordingArtifact?.id,
                        availability: recordingAvailability
                    )
                }.value
            }
            if let dictationID {
                await job.sessionTrace.associate(dictationID: dictationID)
            }
            let didWinTerminal = await job.sessionTrace.claimTerminal(
                result.cleanupOutcome.terminalTraceOutcome,
                metadata: [
                    "cleanup_outcome": result.cleanupOutcome.rawValue,
                    "history_created": String(dictationID != nil),
                    "output_characters": String(text.count),
                ]
            )
            guard didWinTerminal else {
                if let dictationID {
                    if let artifactID = try? dictationStore.deleteDictation(id: dictationID),
                       let store = recordingArtifactStore {
                        try? await Task.detached(priority: .utility) {
                            try store.finishDurableDeletion(id: artifactID)
                        }.value
                    }
                } else {
                    await discardLateAudioOnlyDictation(
                        sessionID: job.id,
                        artifact: recordingArtifact
                    )
                }
                return
            }
            if job.recordingSavePolicy == .prompt, let recordingArtifact {
                presentDictationRecordingDecision(for: recordingArtifact.id)
            }
            if job.isTestMode {
                scheduleICloudSyncAfterLocalChange()
                statusBarController?.refresh()
                historyWindowController?.reload()
                syncAppState()
                dictationTestCallback?(text)
                if let trace = job.latencyTrace {
                    markDictationLatency("pipeline_completed chars:\(text.count)", trace: trace)
                }
                return
            }
            if !cleanupRuntime.config.maraudersMapUnlocked {
                checkMaraudersMapActivation(text)
            }
            scheduleICloudSyncAfterLocalChange()
            statusBarController?.refresh()
            historyWindowController?.reload()
            syncAppState()
            if job.outputMode == .voiceNote {
                applyDictationLifecycleActions(dictationLifecycleFeedback.finish(
                    sessionID: job.id,
                    outcome: dictationID == nil
                        ? .failure(recovery: .unavailable)
                        : .success,
                    soundAllowed: shouldPlayDictationLifecycleSounds
                ))
            } else {
                try await waitForDictationDeliveryWindow()
                if canPasteDictation(to: job.correctionTargetApp) {
                    await PasteController.pasteAndWait(text: text)
                    applyDictationLifecycleActions(dictationLifecycleFeedback.finish(
                        sessionID: job.id,
                        outcome: .success,
                        soundAllowed: shouldPlayDictationLifecycleSounds
                    ))
                    if cleanupRuntime.config.enableDictionaryCorrectionPrompts {
                        dictationCorrectionMonitor.start(
                            originalText: text,
                            appContext: job.storageContext,
                            targetApp: job.correctionTargetApp
                        ) { [weak self] suggestion in
                            self?.addDictionarySuggestion(suggestion)
                        }
                    }
                } else {
                    fputs("[muesli-native] dictation saved without paste because the target app changed\n", stderr)
                    applyDictationLifecycleActions(dictationLifecycleFeedback.finish(
                        sessionID: job.id,
                        outcome: .failure(
                            recovery: dictationID == nil ? .unavailable : .targetChangedWithRetainedHistory
                        ),
                        soundAllowed: shouldPlayDictationLifecycleSounds
                    ))
                }
            }
            if let trace = job.latencyTrace {
                markDictationLatency("pipeline_completed chars:\(text.count)", trace: trace)
            }
            var telemetryParameters = DictationStyleObservability.parameters(
                for: DictationStyleObservabilityInput(
                    selectionSource: result.cleanupStyle?.source,
                    isCustomStyle: result.cleanupStyle?.isCustom,
                    cleanupOutcome: result.cleanupOutcome,
                    cleanupBackend: cleanupRuntime.backend
                )
            )
            telemetryParameters["backend"] = job.backend.backend
            telemetryParameters["paste_method"] = job.outputMode.pasteMethod
            TelemetryDeck.signal("dictation.completed", parameters: telemetryParameters)
        } catch is CancellationError {
            let didWin = await job.sessionTrace.cancel(stage: "dictation_pipeline")
            applyDictationLifecycleActions(dictationLifecycleFeedback.finish(
                sessionID: job.id,
                outcome: .neutral,
                soundAllowed: shouldPlayDictationLifecycleSounds
            ))
            if didWin, job.recordingSavePolicy != .never {
                await persistAudioOnlyDictationRecording(
                    capture: DictationAudioTerminalCapture(
                        sessionID: job.id,
                        outcome: .cancelled,
                        recordingSavePolicy: job.recordingSavePolicy,
                        wavURL: job.wavURL
                    ),
                    startedAt: job.startedAt,
                    durationSeconds: job.duration
                )
            }
            fputs("[muesli-native] test dictation cancelled\n", stderr)
            if let trace = job.latencyTrace {
                markDictationLatency("pipeline_cancelled", trace: trace)
            }
        } catch {
            let didWin = await job.sessionTrace.fail(stage: "dictation_pipeline")
            if didWin {
                applyDictationLifecycleActions(dictationLifecycleFeedback.finish(
                    sessionID: job.id,
                    outcome: .failure(recovery: .unavailable),
                    soundAllowed: shouldPlayDictationLifecycleSounds
                ))
            }
            if didWin, job.recordingSavePolicy != .never {
                await persistAudioOnlyDictationRecording(
                    capture: DictationAudioTerminalCapture(
                        sessionID: job.id,
                        outcome: .failed,
                        recordingSavePolicy: job.recordingSavePolicy,
                        wavURL: job.wavURL
                    ),
                    startedAt: job.startedAt,
                    durationSeconds: job.duration
                )
            }
            fputs("[muesli-native] transcription failed: \(error)\n", stderr)
            if job.isTestMode {
                dictationTestFailureCallback?(userFacingDictationTestError(error))
            } else {
                recordDiagnosticIncident(
                    kind: .dictationTranscriptionFailed,
                    stage: .standardDictationTranscribe,
                    backend: job.backend,
                    error: error
                )
            }
            if let trace = job.latencyTrace {
                markDictationLatency("pipeline_failed", trace: trace)
            }
        }
    }

    private nonisolated static func recordDictationTraceEvent(
        _ event: DictationRuntimeTraceEvent,
        trace: SessionRunTrace
    ) async {
        switch event {
        case .artifact(let kind, let content):
            await trace.storeArtifact(content, kind: kind)
        case .stage(let stage):
            let metadata = [
                "outcome": stage.outcome.rawValue,
                "output_characters": String(stage.outputCharacterCount),
            ]
            switch stage.outcome {
            case .failed:
                await trace.recordStageFailed(
                    stage.stage.rawValue,
                    elapsedMilliseconds: stage.elapsedMilliseconds,
                    metadata: metadata
                )
            case .fallback, .deadlineExceeded:
                await trace.recordFallbackStarted(stage.stage.rawValue, metadata: metadata)
                await trace.recordStageCompleted(
                    stage.stage.rawValue,
                    elapsedMilliseconds: stage.elapsedMilliseconds,
                    metadata: metadata
                )
            case .completed, .skipped:
                await trace.recordStageCompleted(
                    stage.stage.rawValue,
                    elapsedMilliseconds: stage.elapsedMilliseconds,
                    metadata: metadata
                )
            }
        }
    }

    private func waitForDictationDeliveryWindow() async throws {
        while dictationStartedAt != nil
            || dictationAudioSessionManager.hasActiveSession
            || isNemotron35Streaming {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func canPasteDictation(to capturedTarget: DictationSessionTarget?) -> Bool {
        guard let capturedTarget else { return true }
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let deliveryApplication = frontmostApplication == NSRunningApplication.current
            ? lastExternalApp
            : frontmostApplication
        return capturedTarget.matches(
            processID: deliveryApplication?.processIdentifier,
            bundleID: deliveryApplication?.bundleIdentifier ?? ""
        )
    }

    private func handleDictationStageEvent(
        _ event: DictationTranscriptionStageEvent,
        for job: StandardDictationJob
    ) {
        if event.isEmptyCompletedSpeechRecognition,
           job.detectedSpeech,
           !job.isTestMode {
            recordDiagnosticIncident(
                kind: .dictationTranscriptionFailed,
                severity: .warning,
                stage: .standardDictationTranscribe,
                backend: job.backend,
                error: DictationTranscriptionDiagnosticError.emptyResultAfterDetectedSpeech,
                promptUser: false
            )
        }
        if let trace = job.latencyTrace {
            markDictationLatency(event.latencyEvent, trace: trace)
        }
    }

    private func userFacingDictationTestError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "MuesliTranscriptionRuntime" {
            switch nsError.code {
            case 1:
                return "Nemotron requires macOS 15 or later. Choose another model to test dictation."
            case 4:
                return "Cohere Transcribe requires macOS 15 or later. Choose another model to test dictation."
            default:
                return "The selected model is not available. Choose another model and try again."
            }
        }

        let rawMessage = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedMessage = rawMessage.lowercased()

        if lowercasedMessage.contains("not loaded") || lowercasedMessage.contains("loadmodels") {
            return "The model was not ready yet. We are preparing it again, then try once more."
        }
        if lowercasedMessage.contains("network") || lowercasedMessage.contains("internet") || lowercasedMessage.contains("timed out") {
            return "The model could not finish downloading. Check your connection and retry."
        }
        if lowercasedMessage.contains("permission") || lowercasedMessage.contains("microphone") {
            return "Muesli could not access the microphone. Check Microphone permission and try again."
        }
        return "Dictation could not start. Try again in a moment."
    }

    // MARK: - Marauder's Map

    private func checkMaraudersMapActivation(_ text: String) {
        guard !config.maraudersMapUnlocked else { return }
        guard MaraudersMapDetector.containsActivationPhrase(text) else { return }

        fputs("[muesli-native] Marauder's Map unlocked!\n", stderr)
        updateConfig { $0.maraudersMapUnlocked = true }
        SoundController.playMaraudersMapUnlock()
        statusBarController?.setStatus("Mischief Managed")
        statusBarController?.refresh()
        startMaraudersMapMonitoring()
    }

    private func startMaraudersMapMonitoring() {
        guard config.maraudersMapUnlocked else { return }

        let countdown = MaraudersMapCountdownController()
        self.maraudersMapCountdown = countdown

        countdown.startMonitoring(
            eventProvider: { [weak self] in
                guard let self else { return nil }
                let now = Date()
                let hidden = self.appState.hiddenCalendarEventIDs
                guard let event = (self.appState.upcomingCalendarEvents
                    .filter {
                        ScheduledMeetingNotificationPolicy.isJoinableMeeting($0, hiddenEventIDs: hidden)
                            && $0.startDate > now
                    }
                    .min(by: { $0.startDate < $1.startDate })) else { return nil }
                return (id: event.id, title: event.title, startDate: event.startDate)
            },
            audioClipID: config.maraudersMapAudioClip,
            customAudioPath: config.maraudersMapCustomAudioPath,
            onStatusBarUpdate: { [weak self] text in
                self?.statusBarController?.setCountdownOverride(text)
            },
            onCountdownFinished: { [weak self] info in
                guard let self, !self.isMeetingRecording() else { return }
                // Cancel any scheduled "starting now" timer for this event.
                // Match by event ID prefix so deleted/cancelled events (no longer
                // in upcomingCalendarEvents) still get their timers cancelled.
                let prefix = "\(info.id)|"
                let matchingTimerKeys = self.meetingStartingNowTimers.keys.filter { $0.hasPrefix(prefix) }
                for key in matchingTimerKeys {
                    guard let timer = self.meetingStartingNowTimers[key] else { continue }
                    timer.invalidate()
                    self.meetingStartingNowTimers.removeValue(forKey: key)
                }
                guard let event = ScheduledMeetingNotificationPolicy.startingNowCandidate(
                    from: self.appState.upcomingCalendarEvents,
                    eventID: info.id,
                    startDate: info.startDate,
                    hiddenEventIDs: self.appState.hiddenCalendarEventIDs
                ) else { return }
                // Reuse the same notification method as the timer path
                self.showMeetingStartingNowNotification(
                    title: event.title,
                    calendarOccurrence: event.resolvedCalendarOccurrence,
                    meetingURL: event.meetingURL,
                    endDate: event.endDate
                )
            }
        )
    }

    func updateMaraudersMapAudioClip() {
        maraudersMapCountdown?.updateAudioClip(config.maraudersMapAudioClip, customPath: config.maraudersMapCustomAudioPath)
    }

    func resetMaraudersMap() {
        maraudersMapCountdown?.stopMonitoring()
        maraudersMapCountdown = nil
        updateConfig {
            $0.maraudersMapUnlocked = false
            $0.maraudersMapAudioClip = "bbc_world_news"
            $0.maraudersMapCustomAudioPath = nil
        }
    }

    private func handleUpcomingMeeting(_ event: UpcomingMeetingEvent) {
        // Look up end date and meeting URL from unified calendar events
        let calendarEvent = appState.upcomingCalendarEvents
            .first(where: { $0.id == event.id && $0.startDate == event.startDate })
        let calendarEndDate = calendarEvent?.endDate
        let meetingURL = event.meetingURL ?? calendarEvent?.meetingURL
        let calendarOccurrence = event.calendarOccurrence ?? calendarEvent?.resolvedCalendarOccurrence

        // Show notification panel for calendar events (if not auto-recording)
        guard config.showScheduledMeetingNotifications,
              !isMeetingRecording(),
              !isStartingMeetingRecording else {
            return
        }
        isShowingCalendarNotification = true

        let minutesUntil = Int(ceil(event.startDate.timeIntervalSinceNow / 60))
        let timeLabel: String
        if minutesUntil > 0 {
            timeLabel = "starts in \(minutesUntil) min"
        } else if minutesUntil == 0 {
            timeLabel = "starting now"
        } else {
            timeLabel = "started \(abs(minutesUntil)) min ago"
        }

        let title = event.title
        let notificationTitle = minutesUntil <= 0 ? "Meeting starting now" : "Upcoming meeting"
        meetingNotification.show(
            title: notificationTitle,
            subtitle: "\(title) · \(timeLabel)",
            meetingURL: meetingURL,
            defaultAction: config.meetingJoinDefaultAction,
            onStartRecording: { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.recordOnly(
                    title: title,
                    meetingURL: meetingURL,
                    endDate: calendarEndDate,
                    calendarOccurrence: calendarOccurrence,
                    presentation: .backgroundPill
                )
            },
            onJoinAndRecord: meetingURL != nil ? { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.joinAndRecord(
                    title: title,
                    meetingURL: meetingURL!,
                    endDate: calendarEndDate,
                    calendarOccurrence: calendarOccurrence,
                    presentation: .backgroundPill
                )
            } : nil,
            onJoinOnly: meetingURL != nil ? { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.joinOnly(meetingURL: meetingURL!, endDate: calendarEndDate)
            } : nil,
            onDismiss: { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                let remaining = calendarEndDate.map { max($0.timeIntervalSinceNow, 120) } ?? 120
                self.meetingMonitor.suppress(for: remaining)
                self.meetingMonitor.refreshState()
            },
            onClose: { [weak self] in
                self?.isShowingCalendarNotification = false
                self?.showPendingMeetingCompletionNotificationIfPossible()
            }
        )
    }

    private func scheduleMeetingEndNotification(endDate: Date?, title: String) {
        meetingEndTimer?.invalidate()
        meetingEndTimer = nil

        guard let endDate else { return }

        let delay = endDate.timeIntervalSinceNow
        guard delay > 0 else {
            showMeetingEndNotification(title: title)
            return
        }

        meetingEndTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.showMeetingEndNotification(title: title)
            }
        }
    }

    private func armMeetingDurationLimit(meetingID: Int64, startedAt: Date) {
        cancelMeetingDurationLimit()

        let warningDelay = MeetingDurationLimitPolicy.warningDate(startedAt: startedAt).timeIntervalSinceNow
        if warningDelay > 0 {
            meetingDurationWarningTimer = scheduleMeetingDurationTimer(after: warningDelay) {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.showMeetingDurationLimitWarning(meetingID: meetingID)
                }
            }
        } else {
            showMeetingDurationLimitWarning(meetingID: meetingID)
        }

        let stopDelay = MeetingDurationLimitPolicy.stopDate(startedAt: startedAt).timeIntervalSinceNow
        guard stopDelay > 0 else {
            stopMeetingAtDurationLimit(meetingID: meetingID)
            return
        }
        meetingDurationStopTimer = scheduleMeetingDurationTimer(after: stopDelay) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopMeetingAtDurationLimit(meetingID: meetingID)
            }
        }
    }

    private func scheduleMeetingDurationTimer(
        after delay: TimeInterval,
        action: @escaping @Sendable (Timer) -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false, block: action)
        // Tracking menus or dragging the floating panel must not postpone the hard limit.
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func cancelMeetingDurationLimit() {
        meetingDurationWarningTimer?.invalidate()
        meetingDurationWarningTimer = nil
        meetingDurationStopTimer?.invalidate()
        meetingDurationStopTimer = nil
    }

    private func showMeetingDurationLimitWarning(meetingID: Int64) {
        meetingDurationWarningTimer = nil
        guard activeMeetingID == meetingID,
              activeMeetingSession?.isRecording == true,
              !isStoppingMeetingRecording else { return }

        meetingNotification.show(
            promptID: "meeting-duration-limit:\(meetingID)",
            title: "Meeting recording limit",
            subtitle: "This meeting will stop and finalize at the 3-hour limit.",
            actionLabel: "Stop Now",
            dismissAfter: MeetingDurationLimitPolicy.warningLeadTime,
            onStartRecording: { [weak self] in
                guard let self, self.activeMeetingID == meetingID else { return }
                self.stopMeetingRecording()
            }
        )
    }

    private func stopMeetingAtDurationLimit(meetingID: Int64) {
        meetingDurationStopTimer = nil
        guard activeMeetingID == meetingID,
              activeMeetingSession?.isRecording == true,
              !isStoppingMeetingRecording else { return }

        fputs("[meeting] auto-stopping recording at the three-hour safety limit\n", stderr)
        stopMeetingRecording()
    }

    private func showMeetingEndNotification(title: String) {
        guard isMeetingRecording() else { return }
        meetingNotification.show(
            title: "Meeting ended",
            subtitle: "\(title) · scheduled time is over",
            actionLabel: "Stop Transcribing",
            dismissAfter: 45,
            onStartRecording: { [weak self] in
                self?.stopMeetingRecording()
            },
            onDismiss: nil
        )
    }

    func serializedCustomWords() -> [[String: Any]] {
        serializedCustomWords(from: config)
    }

    private func serializedCustomWords(from config: AppConfig) -> [[String: Any]] {
        config.customWords.map { word in
            var dict: [String: Any] = ["word": word.word]
            if let replacement = word.replacement {
                dict["replacement"] = replacement
            }
            dict["matchingThreshold"] = word.matchingThreshold
            return dict
        }
    }
}

func selectCurrentOrNearbyCachedCalendarEvent(
    from events: [UnifiedCalendarEvent],
    now: Date = Date()
) -> CalendarEventContext? {
    let searchEnd = now.addingTimeInterval(5 * 60)
    let candidates = events
        .filter { event in
            !event.isAllDay && event.endDate > now && event.startDate < searchEnd
        }
        .sorted { $0.startDate < $1.startDate }

    if let active = candidates.first(where: { $0.startDate <= now && $0.endDate > now }) {
        return CalendarEventContext(
            id: active.id,
            title: active.title,
            calendarOccurrence: active.resolvedCalendarOccurrence
        )
    }

    return candidates.first(where: { $0.startDate > now })
        .map {
            CalendarEventContext(
                id: $0.id,
                title: $0.title,
                calendarOccurrence: $0.resolvedCalendarOccurrence
            )
        }
}
