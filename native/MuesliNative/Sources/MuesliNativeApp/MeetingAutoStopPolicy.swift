import Foundation

enum MeetingActivityDetectionPolicy {
    static func shouldRun(
        showDetectionNotification: Bool,
        isAutoStopArmed: Bool,
        isStartingRecording: Bool,
        isRecording: Bool
    ) -> Bool {
        showDetectionNotification || isAutoStopArmed || isStartingRecording || isRecording
    }
}

enum MeetingRecordingStartOrigin: Equatable {
    case manual
    case detectedPrompt
    case calendarAutoRecord
    case scheduledMeetingPrompt
    case joinAndRecord

    var enablesMeetingAutoStop: Bool {
        switch self {
        case .manual:
            return false
        case .detectedPrompt, .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord:
            return true
        }
    }

    var signalLossResponse: MeetingSignalLossResponse {
        switch self {
        case .manual:
            return .warnOnly
        case .detectedPrompt, .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord:
            return .autoStopAfterWarning
        }
    }

    func signalLossSource(
        explicitSource: MeetingAutoStopSource?,
        recentSource: @autoclosure () -> MeetingAutoStopSource?
    ) -> MeetingAutoStopSource? {
        switch self {
        case .manual, .detectedPrompt, .calendarAutoRecord, .scheduledMeetingPrompt, .joinAndRecord:
            return explicitSource ?? recentSource()
        }
    }
}

enum MeetingSignalLossResponse: Equatable {
    case none
    case warnOnly
    case autoStopAfterWarning
}

struct MeetingSignalLossPromptState: Equatable {
    private(set) var isPromptSuppressed = false
    private(set) var isDismissedForRecording = false

    var canPresentPrompt: Bool {
        !isPromptSuppressed && !isDismissedForRecording
    }

    mutating func resetForRecording() {
        isPromptSuppressed = false
        isDismissedForRecording = false
    }

    mutating func markPromptPresented() {
        isPromptSuppressed = true
    }

    mutating func markSourceRecovered() {
        isPromptSuppressed = false
    }

    mutating func markDismissedByUser() {
        isPromptSuppressed = true
        isDismissedForRecording = true
    }

    mutating func markAutoDismissed() {
        isPromptSuppressed = true
    }
}

struct MeetingAutoStopSource: Equatable {
    let candidateID: String?
    let suppressionID: String?
    let normalizedURL: String?
    let sourceBundleID: String?
    let hasObservedCandidate: Bool

    private init(
        candidateID: String?,
        suppressionID: String?,
        normalizedURL: String?,
        sourceBundleID: String?,
        hasObservedCandidate: Bool
    ) {
        self.candidateID = candidateID
        self.suppressionID = suppressionID
        self.normalizedURL = normalizedURL
        self.sourceBundleID = sourceBundleID
        self.hasObservedCandidate = hasObservedCandidate
    }

    init(candidate: MeetingCandidate) {
        self.candidateID = candidate.id
        self.suppressionID = candidate.suppressionID
        self.normalizedURL = candidate.url
        self.sourceBundleID = candidate.sourceBundleID
        self.hasObservedCandidate = true
    }

    init?(meetingURL: URL) {
        guard let normalized = MeetingURLNormalizer.normalize(meetingURL.absoluteString) else {
            return nil
        }
        self.candidateID = normalized.id
        self.suppressionID = normalized.id
        self.normalizedURL = normalized.url
        self.sourceBundleID = nil
        self.hasObservedCandidate = false
    }

    func refined(with candidate: MeetingCandidate) -> MeetingAutoStopSource {
        let refinedSuppressionID = candidate.suppressionID == candidate.id
            ? suppressionID ?? candidate.suppressionID
            : candidate.suppressionID
        return MeetingAutoStopSource(
            candidateID: candidateID ?? candidate.id,
            suppressionID: refinedSuppressionID,
            normalizedURL: normalizedURL ?? candidate.url,
            sourceBundleID: sourceBundleID ?? candidate.sourceBundleID,
            hasObservedCandidate: true
        )
    }
}

struct MeetingAutoStopTracker: Equatable {
    private(set) var source: MeetingAutoStopSource?
    private(set) var lastSeenAt: Date?
    private var observedBeforeRecordingStarted = false
    private(set) var lateArmExpiresAt: Date?

    var isArmed: Bool {
        source != nil
    }

    mutating func arm(source: MeetingAutoStopSource?, allowLateArmingUntil: Date? = nil) {
        self.source = source
        lastSeenAt = nil
        observedBeforeRecordingStarted = false
        lateArmExpiresAt = source == nil ? allowLateArmingUntil : nil
    }

    mutating func disarm() {
        source = nil
        lastSeenAt = nil
        observedBeforeRecordingStarted = false
        lateArmExpiresAt = nil
    }

    mutating func armFromObservedCandidateIfNeeded(
        _ candidate: MeetingCandidate,
        now: Date
    ) -> Bool {
        guard source == nil,
              let lateArmExpiresAt,
              now <= lateArmExpiresAt else { return false }
        source = MeetingAutoStopSource(candidate: candidate)
        lastSeenAt = now
        observedBeforeRecordingStarted = false
        self.lateArmExpiresAt = nil
        return true
    }

    mutating func observeBeforeRecordingStarted(candidate: MeetingCandidate?) {
        guard let currentSource = source,
              let candidate,
              MeetingAutoStopPolicy.matches(candidate: candidate, source: currentSource) else {
            return
        }
        source = currentSource.refined(with: candidate)
        observedBeforeRecordingStarted = true
    }

    mutating func markRecordingStarted(now: Date) {
        guard observedBeforeRecordingStarted, lastSeenAt == nil else { return }
        lastSeenAt = now
        observedBeforeRecordingStarted = false
    }

    mutating func observe(
        candidate: MeetingCandidate?,
        now: Date,
        gracePeriod: TimeInterval
    ) -> Bool {
        guard let currentSource = source else {
            return false
        }

        if let candidate,
           MeetingAutoStopPolicy.matches(candidate: candidate, source: currentSource) {
            source = currentSource.refined(with: candidate)
            lastSeenAt = now
            return false
        }

        guard let lastSeenAt else {
            return false
        }

        return now.timeIntervalSince(lastSeenAt) >= gracePeriod
    }
}

enum MeetingAutoStopPolicy {
    static func matches(candidate: MeetingCandidate, source: MeetingAutoStopSource) -> Bool {
        if let candidateID = source.candidateID, candidate.id == candidateID {
            return true
        }

        if let suppressionID = source.suppressionID, candidate.suppressionID == suppressionID {
            return true
        }

        if let normalizedURL = source.normalizedURL, candidate.url == normalizedURL {
            return true
        }

        return false
    }
}
