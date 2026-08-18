import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Dictation lifecycle feedback")
struct DictationLifecycleFeedbackTests {
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

    @Test("recoverable failure keeps the existing history affordance")
    func recoverableFailure() {
        var feedback = DictationLifecycleFeedback()
        let sessionID = UUID()
        _ = feedback.begin(sessionID: sessionID, isTestMode: false)

        #expect(feedback.finish(
            sessionID: sessionID,
            outcome: .failure(recovery: .retainedHistory),
            soundAllowed: true
        ) == [
            .mini(sessionID: sessionID, .failure),
            .cue(.failure),
            .showRetainedHistoryRecovery,
        ])
    }
}
