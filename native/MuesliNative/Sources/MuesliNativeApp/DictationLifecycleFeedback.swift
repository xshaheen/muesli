import Foundation

/// Resolves one coherent visual and audible lifecycle for each dictation session.
/// The controller owns effects; this value owns ordering, deduplication, and foreground arbitration.
struct DictationLifecycleFeedback {
    static func soundAllowed(preferenceEnabled: Bool) -> Bool {
        preferenceEnabled
    }

    enum Outcome: Equatable {
        case success
        case failure(recovery: Recovery)
        case neutral
    }

    enum Recovery: Equatable {
        case unavailable
        case targetChangedWithRetainedHistory
    }

    enum Cue: Equatable {
        case start
        case stop
        case success
        case failure
    }

    enum MiniPresentation: Equatable {
        case preparing
        case recording
        case processing
        case success
        case failure
        case hidden
    }

    enum Action: Equatable {
        case cue(Cue)
        case mini(sessionID: UUID, MiniPresentation)
        case showTargetChangedWithRetainedHistoryRecovery
    }

    private struct Session {
        let isTestMode: Bool
        var didStart = false
        var didStop = false
        var outcome: Outcome?
    }

    private static let retainedSessionLimit = 128
    private var sessions: [UUID: Session] = [:]
    private var sessionOrder: [UUID] = []
    private(set) var foregroundSessionID: UUID?

    mutating func begin(sessionID: UUID, isTestMode: Bool) -> [Action] {
        if let foregroundSessionID,
           foregroundSessionID != sessionID,
           var superseded = sessions[foregroundSessionID],
           superseded.outcome == nil {
            superseded.outcome = .neutral
            sessions[foregroundSessionID] = superseded
        }
        sessions[sessionID] = Session(isTestMode: isTestMode)
        sessionOrder.removeAll { $0 == sessionID }
        sessionOrder.append(sessionID)
        foregroundSessionID = sessionID
        trimSettledSessions()
        return isTestMode ? [] : [.mini(sessionID: sessionID, .preparing)]
    }

    mutating func streamActive(sessionID: UUID, soundAllowed: Bool) -> [Action] {
        guard var session = sessions[sessionID], session.outcome == nil, !session.didStart else { return [] }
        session.didStart = true
        sessions[sessionID] = session
        guard !session.isTestMode, foregroundSessionID == sessionID else { return [] }

        var actions: [Action] = [.mini(sessionID: sessionID, .recording)]
        if soundAllowed { actions.append(.cue(.start)) }
        return actions
    }

    mutating func captureAccepted(sessionID: UUID, soundAllowed: Bool) -> [Action] {
        guard var session = sessions[sessionID], session.outcome == nil, !session.didStop else { return [] }
        session.didStop = true
        sessions[sessionID] = session
        guard !session.isTestMode, foregroundSessionID == sessionID else { return [] }

        var actions: [Action] = [.mini(sessionID: sessionID, .processing)]
        if soundAllowed { actions.append(.cue(.stop)) }
        return actions
    }

    mutating func finish(
        sessionID: UUID,
        outcome: Outcome,
        soundAllowed: Bool
    ) -> [Action] {
        guard var session = sessions[sessionID], session.outcome == nil else { return [] }
        session.outcome = outcome
        sessions[sessionID] = session
        guard !session.isTestMode, foregroundSessionID == sessionID else {
            trimSettledSessions()
            return []
        }

        foregroundSessionID = nil
        let actions: [Action]
        switch outcome {
        case .success:
            actions = terminalActions(sessionID: sessionID, presentation: .success, cue: .success, soundAllowed: soundAllowed)
        case let .failure(recovery):
            var failureActions = terminalActions(
                sessionID: sessionID,
                presentation: .failure,
                cue: .failure,
                soundAllowed: soundAllowed
            )
            if recovery == .targetChangedWithRetainedHistory {
                failureActions.append(.showTargetChangedWithRetainedHistoryRecovery)
            }
            actions = failureActions
        case .neutral:
            actions = [.mini(sessionID: sessionID, .hidden)]
        }
        trimSettledSessions()
        return actions
    }

    private func terminalActions(
        sessionID: UUID,
        presentation: MiniPresentation,
        cue: Cue,
        soundAllowed: Bool
    ) -> [Action] {
        var actions: [Action] = [.mini(sessionID: sessionID, presentation)]
        if soundAllowed { actions.append(.cue(cue)) }
        return actions
    }

    private mutating func trimSettledSessions() {
        guard sessions.count > Self.retainedSessionLimit else { return }
        while sessions.count > Self.retainedSessionLimit,
              let candidate = sessionOrder.first(where: { sessions[$0]?.outcome != nil }) {
            sessionOrder.removeAll { $0 == candidate }
            sessions.removeValue(forKey: candidate)
        }
    }
}
