import CoreAudio
import Foundation
import os

enum MeetingMicHealthState: String, Codable, Equatable {
    case healthy
    case waitingForAudio
    case micCallbacksMissing
    case micAllZeroWhileSystemActive

    /// The failover record names the device that went silent, so the banner can
    /// say which microphone failed instead of blaming "the microphone".
    func userMessage(failover: MeetingMicFailoverRecord?) -> String? {
        switch self {
        case .healthy, .waitingForAudio:
            return nil
        case .micCallbacksMissing:
            return "Microphone audio is not reaching Muesli. This meeting transcript may miss your side."
        case .micAllZeroWhileSystemActive:
            guard let failover else {
                return "Microphone audio is silent. This meeting transcript may miss your side."
            }
            return failover.stillSilentMessage
        }
    }
}

/// The single automatic silent-mic failover a meeting is allowed. A nil
/// `fallbackDeviceID` records that the silence was detected but no distinct
/// input existed to switch to.
struct MeetingMicFailoverRecord: Codable, Equatable {
    let silentDeviceID: AudioObjectID?
    let silentDeviceName: String?
    let fallbackDeviceID: AudioObjectID?
    let fallbackDeviceName: String?
    let decidedAt: Date
    let handoffErrorDescription: String?

    init(
        silentDeviceID: AudioObjectID?,
        silentDeviceName: String?,
        fallbackDeviceID: AudioObjectID?,
        fallbackDeviceName: String?,
        decidedAt: Date,
        handoffErrorDescription: String? = nil
    ) {
        self.silentDeviceID = silentDeviceID
        self.silentDeviceName = silentDeviceName
        self.fallbackDeviceID = fallbackDeviceID
        self.fallbackDeviceName = fallbackDeviceName
        self.decidedAt = decidedAt
        self.handoffErrorDescription = handoffErrorDescription
    }

    var didSwitchInput: Bool { fallbackDeviceID != nil && handoffErrorDescription == nil }

    /// Nil unless the input actually moved, so a plain detection never claims a
    /// switch happened.
    var switchedMessage: String? {
        guard didSwitchInput else { return nil }
        return "\(silentSubject) was silent — switched to \(fallbackSubject)."
    }

    /// Shown while the mic is still reading zeros: after a completed switch this
    /// has to admit the fallback did not help, not just announce the switch.
    var stillSilentMessage: String {
        if handoffErrorDescription != nil {
            return "\(silentSubject) is silent — switching to \(fallbackSubject) failed. "
                + "This meeting transcript may miss your side."
        }
        guard didSwitchInput else {
            return "\(silentSubject) is silent. This meeting transcript may miss your side."
        }
        return "\(silentSubject) was silent — switched to \(fallbackSubject), which is also silent. "
            + "This meeting transcript may miss your side."
    }

    func recordingHandoffFailure(_ reason: String) -> MeetingMicFailoverRecord {
        MeetingMicFailoverRecord(
            silentDeviceID: silentDeviceID,
            silentDeviceName: silentDeviceName,
            fallbackDeviceID: fallbackDeviceID,
            fallbackDeviceName: fallbackDeviceName,
            decidedAt: decidedAt,
            handoffErrorDescription: reason
        )
    }

    private var silentSubject: String {
        silentDeviceName.map { "Microphone \(Self.quote($0))" } ?? "The microphone"
    }

    private var fallbackSubject: String {
        fallbackDeviceName ?? "another microphone"
    }

    static func quote(_ name: String) -> String {
        "\u{201C}\(name)\u{201D}"
    }
}

/// Correlates the recorder's asynchronous handoff result with the one
/// automatic failover selected by the meeting policy.
struct MeetingMicFailoverAttemptTracker {
    private(set) var pending: MeetingMicFailoverRecord?

    mutating func begin(_ record: MeetingMicFailoverRecord) {
        pending = record
    }

    mutating func resolve(_ result: MeetingMicHandoffResult) -> MeetingMicFailoverRecord? {
        guard let pending else { return nil }
        switch result {
        case .completed(let deviceID):
            guard deviceID == pending.fallbackDeviceID else { return nil }
            self.pending = nil
            return pending
        case .failed(let deviceID, let reason):
            guard deviceID == pending.fallbackDeviceID else { return nil }
            self.pending = nil
            return pending.recordingHandoffFailure(reason)
        }
    }
}

struct MeetingMicHealthTransition: Codable, Equatable {
    let timestamp: Date
    let state: MeetingMicHealthState
    let reason: String
}

struct MeetingMicHealthSnapshot: Codable {
    let state: MeetingMicHealthState
    let rawMic: AudioSampleStatsSnapshot
    let systemAudio: AudioSampleStatsSnapshot
    let firstRawMicCallbackAt: Date?
    let firstNonZeroMicAt: Date?
    let firstSystemAudioAt: Date?
    let lastRawMicCallbackAt: Date?
    let lastNonZeroMicAt: Date?
    let lastSystemAudioAt: Date?
    let transitions: [MeetingMicHealthTransition]
    /// The mic has been digitally silent long enough to justify a device
    /// failover, which is a longer confirmation than the warning needs.
    let sustainedZeroMicWhileSystemActive: Bool
    let failover: MeetingMicFailoverRecord?
    /// Baked in rather than computed because a successful failover keeps
    /// announcing itself for a bounded window after the mic recovers.
    let warningMessage: String?
}

final class MeetingMicHealthTracker {
    private struct State {
        var healthState: MeetingMicHealthState = .waitingForAudio
        var rawMicStats = AudioSampleStats()
        var systemAudioStats = AudioSampleStats()
        var firstRawMicCallbackAt: Date?
        var firstNonZeroMicAt: Date?
        var firstSystemAudioAt: Date?
        var lastRawMicCallbackAt: Date?
        var lastNonZeroMicAt: Date?
        var lastSystemAudioAt: Date?
        var lastRawMicWasEffectivelyZero = true
        var activeSystemSamplesWhileMicMissing = 0
        var activeSystemSamplesWhileMicZero = 0
        var sustainedZeroMicWhileSystemActive = false
        var failover: MeetingMicFailoverRecord?
        var transitions: [MeetingMicHealthTransition] = []
    }

    private static let sampleRate = 16_000
    private static let activeSystemPeakThreshold = 0.01
    private static let degradedConfirmationSamples = sampleRate * 3
    /// Longer than the warning threshold: swapping the capture device mid-meeting
    /// costs a handoff gap, so only sustained silence is worth that.
    private static let failoverConfirmationSamples = sampleRate * 6
    private static let micCallbackStaleThreshold: TimeInterval = 1.0
    /// A completed switch keeps warning after recovery so the user learns their
    /// microphone changed; without this the notice would vanish with the silence.
    private static let failoverNoticeDuration: TimeInterval = 60
    private static let maxTransitions = 32

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func noteRawMicSamples(_ samples: [Int16], now: Date = Date()) -> MeetingMicHealthSnapshot {
        lock.withLock { state in
            state.rawMicStats.addInt16(samples)
            state.firstRawMicCallbackAt = state.firstRawMicCallbackAt ?? now
            state.lastRawMicCallbackAt = now
            state.activeSystemSamplesWhileMicMissing = 0

            let stats = statsForSamples(samples)
            let hasSignal = MeetingMicSignalClassifier.containsSignal(stats)
            state.lastRawMicWasEffectivelyZero = !hasSignal
            if hasSignal {
                state.firstNonZeroMicAt = state.firstNonZeroMicAt ?? now
                state.lastNonZeroMicAt = now
                state.activeSystemSamplesWhileMicMissing = 0
                state.activeSystemSamplesWhileMicZero = 0
                state.sustainedZeroMicWhileSystemActive = false
                transitionLocked(&state, to: .healthy, reason: "raw_mic_signal_detected", now: now)
            }
            return snapshotLocked(state, now: now)
        }
    }

    func noteSystemSamples(_ samples: [Int16], now: Date = Date()) -> MeetingMicHealthSnapshot {
        lock.withLock { state in
            state.systemAudioStats.addInt16(samples)
            let stats = statsForSamples(samples)
            guard stats.peak > Self.activeSystemPeakThreshold else {
                return snapshotLocked(state, now: now)
            }

            state.firstSystemAudioAt = state.firstSystemAudioAt ?? now
            state.lastSystemAudioAt = now

            if state.lastRawMicCallbackAt == nil {
                state.activeSystemSamplesWhileMicMissing += samples.count
                if state.activeSystemSamplesWhileMicMissing >= Self.degradedConfirmationSamples {
                    transitionLocked(&state, to: .micCallbacksMissing, reason: "system_audio_active_without_mic_callbacks", now: now)
                }
            } else if state.lastRawMicWasEffectivelyZero {
                state.activeSystemSamplesWhileMicZero += samples.count
                if state.activeSystemSamplesWhileMicZero >= Self.degradedConfirmationSamples {
                    transitionLocked(&state, to: .micAllZeroWhileSystemActive, reason: "system_audio_active_with_zero_mic", now: now)
                }
                if state.activeSystemSamplesWhileMicZero >= Self.failoverConfirmationSamples {
                    state.sustainedZeroMicWhileSystemActive = true
                }
            } else if let lastRawMicCallbackAt = state.lastRawMicCallbackAt,
                      now.timeIntervalSince(lastRawMicCallbackAt) >= Self.micCallbackStaleThreshold {
                state.activeSystemSamplesWhileMicMissing += samples.count
                if state.activeSystemSamplesWhileMicMissing >= Self.degradedConfirmationSamples {
                    transitionLocked(&state, to: .micCallbacksMissing, reason: "system_audio_active_after_mic_callbacks_stopped", now: now)
                }
            } else {
                state.activeSystemSamplesWhileMicMissing = 0
                state.activeSystemSamplesWhileMicZero = 0
                state.sustainedZeroMicWhileSystemActive = false
            }
            return snapshotLocked(state, now: now)
        }
    }

    func snapshot(now: Date = Date()) -> MeetingMicHealthSnapshot {
        lock.withLock { snapshotLocked($0, now: now) }
    }

    /// Records what the failover policy decided so the banner and the meeting
    /// diagnostics both name the device that went silent.
    @discardableResult
    func recordFailover(_ record: MeetingMicFailoverRecord, now: Date = Date()) -> MeetingMicHealthSnapshot {
        lock.withLock { state in
            state.failover = record
            if record.didSwitchInput {
                // The fallback device deserves its own confirmation window;
                // carrying the old device's silence over would immediately
                // blame the replacement for the handoff gap.
                state.activeSystemSamplesWhileMicMissing = 0
                state.activeSystemSamplesWhileMicZero = 0
                state.sustainedZeroMicWhileSystemActive = false
                transitionLocked(&state, to: .waitingForAudio, reason: "mic_failover_switched_input", now: now)
            }
            return snapshotLocked(state, now: now)
        }
    }

    private func transitionLocked(
        _ state: inout State,
        to nextState: MeetingMicHealthState,
        reason: String,
        now: Date
    ) {
        guard state.healthState != nextState else { return }
        state.healthState = nextState
        state.transitions.append(MeetingMicHealthTransition(timestamp: now, state: nextState, reason: reason))
        if state.transitions.count > Self.maxTransitions {
            state.transitions.removeFirst(state.transitions.count - Self.maxTransitions)
        }
    }

    private func snapshotLocked(_ state: State, now: Date) -> MeetingMicHealthSnapshot {
        MeetingMicHealthSnapshot(
            state: state.healthState,
            rawMic: state.rawMicStats.snapshot(),
            systemAudio: state.systemAudioStats.snapshot(),
            firstRawMicCallbackAt: state.firstRawMicCallbackAt,
            firstNonZeroMicAt: state.firstNonZeroMicAt,
            firstSystemAudioAt: state.firstSystemAudioAt,
            lastRawMicCallbackAt: state.lastRawMicCallbackAt,
            lastNonZeroMicAt: state.lastNonZeroMicAt,
            lastSystemAudioAt: state.lastSystemAudioAt,
            transitions: state.transitions,
            sustainedZeroMicWhileSystemActive: state.sustainedZeroMicWhileSystemActive,
            failover: state.failover,
            warningMessage: Self.warningMessage(for: state, now: now)
        )
    }

    private static func warningMessage(for state: State, now: Date) -> String? {
        if let message = state.healthState.userMessage(failover: state.failover) {
            return message
        }
        guard let failover = state.failover,
              let switchedMessage = failover.switchedMessage,
              now.timeIntervalSince(failover.decidedAt) < failoverNoticeDuration else { return nil }
        return switchedMessage
    }

    private func statsForSamples(_ samples: [Int16]) -> AudioSampleStatsSnapshot {
        var stats = AudioSampleStats()
        stats.addInt16(samples)
        return stats.snapshot()
    }
}

/// Input devices the failover policy can choose between. `currentDeviceID` is
/// nil when the recorder follows the system default input.
struct MeetingMicFailoverRoute: Equatable {
    let currentDeviceID: AudioObjectID?
    let currentDeviceName: String?
    let systemDefaultDeviceID: AudioObjectID?
    let systemDefaultDeviceName: String?
    let builtInDeviceID: AudioObjectID?
    let builtInDeviceName: String?

    init(
        currentDeviceID: AudioObjectID?,
        currentDeviceName: String?,
        systemDefaultDeviceID: AudioObjectID?,
        systemDefaultDeviceName: String?,
        builtInDeviceID: AudioObjectID?,
        builtInDeviceName: String?
    ) {
        self.currentDeviceID = currentDeviceID
        self.currentDeviceName = currentDeviceName
        self.systemDefaultDeviceID = systemDefaultDeviceID
        self.systemDefaultDeviceName = systemDefaultDeviceName
        self.builtInDeviceID = builtInDeviceID
        self.builtInDeviceName = builtInDeviceName
    }

    init(routeSnapshot: MeetingMicRouteDiagnosticsSnapshot, currentDeviceID: AudioObjectID?) {
        let currentName = currentDeviceID == nil
            ? routeSnapshot.defaultInputDeviceName
            : (currentDeviceID == routeSnapshot.preferredInputDeviceID ? routeSnapshot.preferredInputDeviceName : nil)
        self.init(
            currentDeviceID: currentDeviceID,
            currentDeviceName: currentName,
            systemDefaultDeviceID: routeSnapshot.defaultInputDeviceID,
            systemDefaultDeviceName: routeSnapshot.defaultInputDeviceName,
            builtInDeviceID: routeSnapshot.builtInInputDeviceID,
            builtInDeviceName: routeSnapshot.builtInInputDeviceName
        )
    }

    /// A nil `currentDeviceID` means "whatever the system default is", so the
    /// silent device is the default device in that case.
    var silentDeviceID: AudioObjectID? { currentDeviceID ?? systemDefaultDeviceID }

    var silentDeviceName: String? {
        if let currentDeviceName { return currentDeviceName }
        guard let silentDeviceID else { return nil }
        if silentDeviceID == systemDefaultDeviceID { return systemDefaultDeviceName }
        if silentDeviceID == builtInDeviceID { return builtInDeviceName }
        return nil
    }
}

enum MeetingMicFailoverDecision: Equatable {
    case wait
    case noFallback(MeetingMicFailoverRecord)
    case switchInput(MeetingMicFailoverRecord)
}

/// Decides whether a meeting whose microphone went digitally silent should hand
/// capture to another input. Pure and stateful only in the "already tried" flags
/// so the once-per-meeting guarantee is testable without CoreAudio.
struct MeetingMicFailoverPolicy {
    private(set) var hasAttemptedFailover = false
    private(set) var hasReportedNoFallback = false

    mutating func evaluate(
        sustainedZeroMic: Bool,
        route: MeetingMicFailoverRoute,
        now: Date
    ) -> MeetingMicFailoverDecision {
        guard sustainedZeroMic, !hasAttemptedFailover else { return .wait }

        let silentDeviceID = route.silentDeviceID
        let fallback = Self.fallback(for: silentDeviceID, route: route)
        let record = MeetingMicFailoverRecord(
            silentDeviceID: silentDeviceID,
            silentDeviceName: route.silentDeviceName,
            fallbackDeviceID: fallback?.deviceID,
            fallbackDeviceName: fallback?.name,
            decidedAt: now
        )

        guard fallback != nil else {
            // Reported once so a meeting with no alternative input does not
            // rebuild the same banner on every system-audio callback.
            guard !hasReportedNoFallback else { return .wait }
            hasReportedNoFallback = true
            return .noFallback(record)
        }
        hasAttemptedFailover = true
        return .switchInput(record)
    }

    /// The built-in mic is the trustworthy fallback for a silent external input;
    /// when the built-in is the one that went quiet, the system default is the
    /// only other candidate worth trying.
    private static func fallback(
        for silentDeviceID: AudioObjectID?,
        route: MeetingMicFailoverRoute
    ) -> (deviceID: AudioObjectID, name: String?)? {
        if let builtInDeviceID = route.builtInDeviceID, builtInDeviceID != silentDeviceID {
            return (builtInDeviceID, route.builtInDeviceName)
        }
        if let systemDefaultDeviceID = route.systemDefaultDeviceID, systemDefaultDeviceID != silentDeviceID {
            return (systemDefaultDeviceID, route.systemDefaultDeviceName)
        }
        return nil
    }
}
