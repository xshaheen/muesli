import Foundation
import Testing
@testable import ImlaNativeApp

@Suite("Dictation lifecycle feedback")
struct DictationLifecycleFeedbackTests {
    @Test("sound preference remains authoritative on every output route")
    func soundPreferencePolicy() {
        #expect(DictationLifecycleFeedback.soundAllowed(preferenceEnabled: true))
        #expect(!DictationLifecycleFeedback.soundAllowed(preferenceEnabled: false))
    }

    @Test("each lifecycle transition is emitted once")
    func deduplicatesTransitions() {
        var feedback = DictationLifecycleFeedback()
        let sessionID = UUID()

        #expect(feedback.begin(sessionID: sessionID, isTestMode: false) == [.mini(sessionID: sessionID, .preparing)])
        #expect(feedback.streamActive(sessionID: sessionID, soundAllowed: true) == [
            .mini(sessionID: sessionID, .recording), .cue(.start),
        ])
        #expect(feedback.streamActive(sessionID: sessionID, soundAllowed: true).isEmpty)
        #expect(feedback.captureAccepted(sessionID: sessionID, soundAllowed: true) == [
            .mini(sessionID: sessionID, .processing), .cue(.stop),
        ])
        #expect(feedback.captureAccepted(sessionID: sessionID, soundAllowed: true).isEmpty)
        #expect(feedback.finish(sessionID: sessionID, outcome: .success, soundAllowed: true) == [
            .mini(sessionID: sessionID, .success), .cue(.success),
        ])
        #expect(feedback.finish(sessionID: sessionID, outcome: .failure(recovery: .unavailable), soundAllowed: true).isEmpty)
    }

    @Test("disabled sounds still advance visuals and cannot replay later")
    func disabledSoundConsumesTransitions() {
        var feedback = DictationLifecycleFeedback()
        let sessionID = UUID()
        _ = feedback.begin(sessionID: sessionID, isTestMode: false)

        #expect(feedback.streamActive(sessionID: sessionID, soundAllowed: false) == [
            .mini(sessionID: sessionID, .recording),
        ])
        #expect(feedback.streamActive(sessionID: sessionID, soundAllowed: true).isEmpty)
        #expect(feedback.captureAccepted(sessionID: sessionID, soundAllowed: false) == [
            .mini(sessionID: sessionID, .processing),
        ])
        #expect(feedback.captureAccepted(sessionID: sessionID, soundAllowed: true).isEmpty)
    }

    @Test("test sessions are entirely silent and invisible")
    func testSessionsProduceNoActions() {
        var feedback = DictationLifecycleFeedback()
        let sessionID = UUID()

        #expect(feedback.begin(sessionID: sessionID, isTestMode: true).isEmpty)
        #expect(feedback.streamActive(sessionID: sessionID, soundAllowed: true).isEmpty)
        #expect(feedback.captureAccepted(sessionID: sessionID, soundAllowed: true).isEmpty)
        #expect(feedback.finish(sessionID: sessionID, outcome: .success, soundAllowed: true).isEmpty)
    }

    @Test("neutral completion blocks a later failure")
    func neutralIsTerminal() {
        var feedback = DictationLifecycleFeedback()
        let sessionID = UUID()
        _ = feedback.begin(sessionID: sessionID, isTestMode: false)

        #expect(feedback.finish(sessionID: sessionID, outcome: .neutral, soundAllowed: true) == [
            .mini(sessionID: sessionID, .hidden),
        ])
        #expect(feedback.finish(sessionID: sessionID, outcome: .failure(recovery: .unavailable), soundAllowed: true).isEmpty)
    }

    @Test("older queued work cannot replace a newer foreground recording")
    func foregroundArbitration() {
        var feedback = DictationLifecycleFeedback()
        let older = UUID()
        let newer = UUID()
        _ = feedback.begin(sessionID: older, isTestMode: false)
        _ = feedback.captureAccepted(sessionID: older, soundAllowed: true)
        _ = feedback.begin(sessionID: newer, isTestMode: false)

        #expect(feedback.finish(sessionID: older, outcome: .success, soundAllowed: true).isEmpty)
        #expect(feedback.foregroundSessionID == newer)
        #expect(feedback.streamActive(sessionID: newer, soundAllowed: true) == [
            .mini(sessionID: newer, .recording), .cue(.start),
        ])
    }

    @Test("recoverable failure carries the exact saved dictation")
    func recoverableFailure() {
        var feedback = DictationLifecycleFeedback()
        let sessionID = UUID()
        _ = feedback.begin(sessionID: sessionID, isTestMode: false)

        #expect(feedback.finish(
            sessionID: sessionID,
            outcome: .failure(recovery: .targetChangedWithRetainedHistory(dictationID: 42)),
            soundAllowed: true
        ) == [
            .mini(sessionID: sessionID, .failure),
            .cue(.failure),
            .showTargetChangedWithRetainedHistoryRecovery(dictationID: 42),
        ])
    }

    @Test("an older failed session cannot offer recovery over a new recording")
    func staleRecovery() {
        var feedback = DictationLifecycleFeedback()
        let old = UUID()
        let current = UUID()
        _ = feedback.begin(sessionID: old, isTestMode: false)
        _ = feedback.begin(sessionID: current, isTestMode: false)
        #expect(feedback.finish(
            sessionID: old, outcome: .failure(recovery: .targetChangedWithRetainedHistory(dictationID: 42)),
            soundAllowed: true
        ).isEmpty)
        #expect(feedback.foregroundSessionID == current)
    }

    @Test("unavailable failure emits only the terminal failure feedback")
    func unavailableFailure() {
        var feedback = DictationLifecycleFeedback()
        let sessionID = UUID()
        _ = feedback.begin(sessionID: sessionID, isTestMode: false)

        #expect(feedback.finish(
            sessionID: sessionID,
            outcome: .failure(recovery: .unavailable),
            soundAllowed: true
        ) == [
            .mini(sessionID: sessionID, .failure),
            .cue(.failure),
        ])
    }
}
