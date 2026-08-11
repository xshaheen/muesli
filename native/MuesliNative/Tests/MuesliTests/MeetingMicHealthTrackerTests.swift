import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingMicHealthTracker")
struct MeetingMicHealthTrackerTests {
    @Test("all-zero raw mic with active system audio raises degraded warning")
    func allZeroRawMicWithActiveSystemAudioRaisesWarning() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000), now: now)
        var snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(1))
        #expect(snapshot.state == .waitingForAudio)

        snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(2))
        #expect(snapshot.state == .waitingForAudio)

        snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(3))
        #expect(snapshot.state == .micAllZeroWhileSystemActive)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("system audio without mic callbacks is distinguishable from all-zero mic")
    func systemAudioWithoutMicCallbacksIsMissingCallbacks() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now)
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(1))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(2))

        #expect(snapshot.state == .micCallbacksMissing)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("mid-meeting mic callback loss after healthy input raises warning")
    func midMeetingMicCallbackLossRaisesWarning() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 400, count: 1_000), now: now)
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(2))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(3))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(4))

        #expect(snapshot.state == .micCallbacksMissing)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("mid-meeting mic callback loss still warns when system audio starts during grace window")
    func midMeetingMicCallbackLossWithGraceWindowRaisesWarning() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 400, count: 1_000), now: now)
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 1_600), now: now.addingTimeInterval(0.5))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(2))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(3))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(4))

        #expect(snapshot.state == .micCallbacksMissing)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("silence without active system audio does not warn")
    func silenceWithoutActiveSystemAudioDoesNotWarn() {
        let tracker = MeetingMicHealthTracker()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 0, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 0, count: 16_000))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 0, count: 16_000))

        #expect(snapshot.state == .waitingForAudio)
        #expect(snapshot.warningMessage == nil)
    }

    @Test("non-zero raw mic clears degraded warning")
    func nonZeroRawMicClearsWarning() {
        let tracker = MeetingMicHealthTracker()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000))
        let recovered = tracker.noteRawMicSamples(Array(repeating: 400, count: 1_000))

        #expect(recovered.state == .healthy)
        #expect(recovered.warningMessage == nil)
        #expect(recovered.firstNonZeroMicAt != nil)
    }

    @Test("warning threshold alone does not request a device failover")
    func degradedWarningDoesNotImmediatelyRequestFailover() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000), now: now)
        let snapshot = feedSilentMicSeconds(3, into: tracker, from: now)

        #expect(snapshot.state == .micAllZeroWhileSystemActive)
        #expect(snapshot.sustainedZeroMicWhileSystemActive == false)
    }

    @Test("sustained zero mic with active system audio requests a device failover")
    func sustainedZeroMicRequestsFailover() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000), now: now)
        let snapshot = feedSilentMicSeconds(6, into: tracker, from: now)

        #expect(snapshot.state == .micAllZeroWhileSystemActive)
        #expect(snapshot.sustainedZeroMicWhileSystemActive)
    }

    @Test("recovered mic withdraws the failover request")
    func recoveredMicWithdrawsFailoverRequest() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000), now: now)
        _ = feedSilentMicSeconds(6, into: tracker, from: now)
        let recovered = tracker.noteRawMicSamples(
            Array(repeating: 400, count: 1_000),
            now: now.addingTimeInterval(7)
        )

        #expect(recovered.sustainedZeroMicWhileSystemActive == false)
    }

    @Test("recorded failover names the silent device in the banner")
    func recordedFailoverNamesSilentDevice() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000), now: now)
        _ = feedSilentMicSeconds(6, into: tracker, from: now)
        let snapshot = tracker.recordFailover(
            MeetingMicFailoverRecord(
                silentDeviceID: 91,
                silentDeviceName: "Mahmoud's AirPods",
                fallbackDeviceID: 82,
                fallbackDeviceName: "MacBook Pro Microphone",
                decidedAt: now
            ),
            now: now
        )

        #expect(snapshot.warningMessage == "Microphone \u{201C}Mahmoud's AirPods\u{201D} was silent — switched to MacBook Pro Microphone.")
    }

    @Test("failover notice survives mic recovery for a bounded window")
    func failoverNoticeSurvivesRecoveryBriefly() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000), now: now)
        _ = feedSilentMicSeconds(6, into: tracker, from: now)
        _ = tracker.recordFailover(
            MeetingMicFailoverRecord(
                silentDeviceID: 91,
                silentDeviceName: "AirPods",
                fallbackDeviceID: 82,
                fallbackDeviceName: "MacBook Pro Microphone",
                decidedAt: now
            ),
            now: now
        )

        let recovered = tracker.noteRawMicSamples(
            Array(repeating: 400, count: 1_000),
            now: now.addingTimeInterval(7)
        )
        #expect(recovered.state == .healthy)
        #expect(recovered.warningMessage?.contains("switched to MacBook Pro Microphone") == true)

        let later = tracker.snapshot(now: now.addingTimeInterval(120))
        #expect(later.warningMessage == nil)
    }

    @Test("a fallback that is also silent is named in the warning")
    func silentFallbackIsNamedInWarning() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000), now: now)
        _ = feedSilentMicSeconds(6, into: tracker, from: now)
        let switched = tracker.recordFailover(
            MeetingMicFailoverRecord(
                silentDeviceID: 91,
                silentDeviceName: "AirPods",
                fallbackDeviceID: 82,
                fallbackDeviceName: "MacBook Pro Microphone",
                decidedAt: now
            ),
            now: now
        )
        // The fallback starts on a clean slate, so the handoff gap is not
        // reported as the replacement failing.
        #expect(switched.state == .waitingForAudio)
        #expect(switched.sustainedZeroMicWhileSystemActive == false)

        let stillSilent = feedSilentMicSeconds(3, into: tracker, from: now.addingTimeInterval(6))

        #expect(stillSilent.state == .micAllZeroWhileSystemActive)
        #expect(stillSilent.warningMessage?.contains("which is also silent") == true)
    }

    @Test("silent device with no fallback keeps the miss-your-side warning")
    func silentDeviceWithoutFallbackKeepsWarning() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000), now: now)
        _ = feedSilentMicSeconds(6, into: tracker, from: now)
        let snapshot = tracker.recordFailover(
            MeetingMicFailoverRecord(
                silentDeviceID: 82,
                silentDeviceName: "MacBook Pro Microphone",
                fallbackDeviceID: nil,
                fallbackDeviceName: nil,
                decidedAt: now
            ),
            now: now
        )

        #expect(snapshot.warningMessage == "Microphone \u{201C}MacBook Pro Microphone\u{201D} is silent. This meeting transcript may miss your side.")
    }

    /// Each second of active system audio while the mic reads all zeros.
    private func feedSilentMicSeconds(
        _ seconds: Int,
        into tracker: MeetingMicHealthTracker,
        from start: Date
    ) -> MeetingMicHealthSnapshot {
        var snapshot = tracker.snapshot(now: start)
        for second in 1...seconds {
            snapshot = tracker.noteSystemSamples(
                Array(repeating: 6_000, count: 16_000),
                now: start.addingTimeInterval(TimeInterval(second))
            )
        }
        return snapshot
    }
}

@Suite("MeetingMicFailoverPolicy")
struct MeetingMicFailoverPolicyTests {
    private static let airPods: AudioObjectID = 91
    private static let builtIn: AudioObjectID = 82

    @Test("no failover before the silence is sustained")
    func noFailoverBeforeSustainedSilence() {
        var policy = MeetingMicFailoverPolicy()

        let decision = policy.evaluate(sustainedZeroMic: false, route: externalMicRoute(), now: Date())

        #expect(decision == .wait)
        #expect(policy.hasAttemptedFailover == false)
    }

    @Test("sustained silence on an external mic switches to the built-in mic")
    func sustainedSilenceSwitchesToBuiltIn() {
        var policy = MeetingMicFailoverPolicy()
        let now = Date()

        let decision = policy.evaluate(sustainedZeroMic: true, route: externalMicRoute(), now: now)

        #expect(decision == .switchInput(
            MeetingMicFailoverRecord(
                silentDeviceID: Self.airPods,
                silentDeviceName: "AirPods",
                fallbackDeviceID: Self.builtIn,
                fallbackDeviceName: "MacBook Pro Microphone",
                decidedAt: now
            )
        ))
        #expect(policy.hasAttemptedFailover)
    }

    @Test("a mic that follows the system default fails over to the built-in mic")
    func systemDefaultFollowerFailsOverToBuiltIn() throws {
        var policy = MeetingMicFailoverPolicy()
        let route = MeetingMicFailoverRoute(
            currentDeviceID: nil,
            currentDeviceName: nil,
            systemDefaultDeviceID: Self.airPods,
            systemDefaultDeviceName: "AirPods",
            builtInDeviceID: Self.builtIn,
            builtInDeviceName: "MacBook Pro Microphone"
        )

        let decision = policy.evaluate(sustainedZeroMic: true, route: route, now: Date())

        let record = try #require(decision.switchRecord)
        #expect(record.silentDeviceID == Self.airPods)
        #expect(record.silentDeviceName == "AirPods")
        #expect(record.fallbackDeviceID == Self.builtIn)
    }

    @Test("a silent built-in mic falls back to a different system default")
    func silentBuiltInFallsBackToSystemDefault() throws {
        var policy = MeetingMicFailoverPolicy()
        let route = MeetingMicFailoverRoute(
            currentDeviceID: Self.builtIn,
            currentDeviceName: "MacBook Pro Microphone",
            systemDefaultDeviceID: Self.airPods,
            systemDefaultDeviceName: "AirPods",
            builtInDeviceID: Self.builtIn,
            builtInDeviceName: "MacBook Pro Microphone"
        )

        let decision = policy.evaluate(sustainedZeroMic: true, route: route, now: Date())

        let record = try #require(decision.switchRecord)
        #expect(record.fallbackDeviceID == Self.airPods)
        #expect(record.fallbackDeviceName == "AirPods")
    }

    @Test("no distinct fallback reports the silence without switching")
    func noDistinctFallbackDoesNotSwitch() throws {
        var policy = MeetingMicFailoverPolicy()
        let route = MeetingMicFailoverRoute(
            currentDeviceID: Self.builtIn,
            currentDeviceName: "MacBook Pro Microphone",
            systemDefaultDeviceID: Self.builtIn,
            systemDefaultDeviceName: "MacBook Pro Microphone",
            builtInDeviceID: Self.builtIn,
            builtInDeviceName: "MacBook Pro Microphone"
        )

        let first = policy.evaluate(sustainedZeroMic: true, route: route, now: Date())
        let second = policy.evaluate(sustainedZeroMic: true, route: route, now: Date())

        let record = try #require(first.noFallbackRecord)
        #expect(record.didSwitchInput == false)
        #expect(record.silentDeviceName == "MacBook Pro Microphone")
        // The banner is built once; later callbacks must not rebuild it.
        #expect(second == .wait)
        #expect(policy.hasAttemptedFailover == false)
    }

    @Test("only one automatic failover per meeting")
    func onlyOneFailoverPerMeeting() throws {
        var policy = MeetingMicFailoverPolicy()
        let now = Date()

        let first = policy.evaluate(sustainedZeroMic: true, route: externalMicRoute(), now: now)
        // The fallback is silent too, so the tracker asks again a minute later.
        let second = policy.evaluate(
            sustainedZeroMic: true,
            route: MeetingMicFailoverRoute(
                currentDeviceID: Self.builtIn,
                currentDeviceName: "MacBook Pro Microphone",
                systemDefaultDeviceID: Self.airPods,
                systemDefaultDeviceName: "AirPods",
                builtInDeviceID: Self.builtIn,
                builtInDeviceName: "MacBook Pro Microphone"
            ),
            now: now.addingTimeInterval(60)
        )

        _ = try #require(first.switchRecord)
        #expect(second == .wait)
    }

    @Test("mic recovery between silences does not unlock a second failover")
    func recoveryDoesNotUnlockSecondFailover() {
        var policy = MeetingMicFailoverPolicy()
        let now = Date()

        _ = policy.evaluate(sustainedZeroMic: true, route: externalMicRoute(), now: now)
        let recovered = policy.evaluate(sustainedZeroMic: false, route: externalMicRoute(), now: now.addingTimeInterval(30))
        let silentAgain = policy.evaluate(sustainedZeroMic: true, route: externalMicRoute(), now: now.addingTimeInterval(90))

        #expect(recovered == .wait)
        #expect(silentAgain == .wait)
    }

    private func externalMicRoute() -> MeetingMicFailoverRoute {
        MeetingMicFailoverRoute(
            currentDeviceID: Self.airPods,
            currentDeviceName: "AirPods",
            systemDefaultDeviceID: Self.airPods,
            systemDefaultDeviceName: "AirPods",
            builtInDeviceID: Self.builtIn,
            builtInDeviceName: "MacBook Pro Microphone"
        )
    }
}

@Suite("Meeting mic session route override")
struct MeetingMicSessionRouteStateTests {
    @Test("unchanged route refresh preserves a pending or accepted fallback")
    func unchangedRefreshPreservesFallback() {
        var state = MeetingMicSessionRouteState(configuredDeviceID: 91)
        let route = routeSnapshot(preferred: 91, defaultInput: 91, builtIn: 82)
        state.beginFailover(to: 82, route: route)

        let decision = state.reconcileConfiguredRoute(
            deviceID: 91,
            route: route,
            explicitUserSelection: false
        )

        #expect(decision == .keepSessionOverride(82))
        #expect(state.sessionOverrideDeviceID == 82)
    }

    @Test("explicit input selection clears the session fallback and resets eligibility")
    func explicitSelectionClearsFallback() {
        var state = MeetingMicSessionRouteState(configuredDeviceID: 91)
        let route = routeSnapshot(preferred: 91, defaultInput: 91, builtIn: 82)
        state.beginFailover(to: 82, route: route)

        let decision = state.reconcileConfiguredRoute(
            deviceID: 93,
            route: routeSnapshot(preferred: 93, defaultInput: 91, builtIn: 82),
            explicitUserSelection: true
        )

        #expect(decision == .applyConfigured(93, resetFailoverEligibility: true))
        #expect(state.sessionOverrideDeviceID == nil)
    }

    @Test("fallback disappearance adopts the configured route and resets eligibility")
    func fallbackDisappearanceClearsOverride() {
        var state = MeetingMicSessionRouteState(configuredDeviceID: 91)
        let route = routeSnapshot(preferred: 91, defaultInput: 91, builtIn: 82)
        state.beginFailover(to: 82, route: route)

        let decision = state.reconcileConfiguredRoute(
            deviceID: 91,
            route: routeSnapshot(preferred: 91, defaultInput: 91, builtIn: nil),
            explicitUserSelection: false
        )

        #expect(decision == .applyConfigured(91, resetFailoverEligibility: true))
        #expect(state.sessionOverrideDeviceID == nil)
    }

    @Test("materially new default route supersedes the session fallback")
    func materialRouteChangeClearsOverride() {
        var state = MeetingMicSessionRouteState(configuredDeviceID: nil)
        let route = routeSnapshot(preferred: nil, defaultInput: 91, builtIn: 82)
        state.beginFailover(to: 82, route: route)

        let decision = state.reconcileConfiguredRoute(
            deviceID: nil,
            route: routeSnapshot(preferred: nil, defaultInput: 93, builtIn: 82),
            explicitUserSelection: false
        )

        #expect(decision == .applyConfigured(nil, resetFailoverEligibility: true))
        #expect(state.sessionOverrideDeviceID == nil)
    }

    private func routeSnapshot(
        preferred: AudioObjectID?,
        defaultInput: AudioObjectID?,
        builtIn: AudioObjectID?
    ) -> MeetingMicRouteDiagnosticsSnapshot {
        MeetingMicRouteDiagnosticsSnapshot(
            outputRouteKind: "headphoneLike",
            outputIsAmbiguousBluetooth: false,
            selectedInputDeviceUID: nil,
            selectedInputDeviceResolved: true,
            preferredInputDeviceID: preferred,
            preferredInputDeviceName: nil,
            defaultInputDeviceID: defaultInput,
            defaultInputDeviceName: nil,
            builtInInputDeviceID: builtIn,
            builtInInputDeviceName: nil,
            systemDefaultInputIsBuiltIn: defaultInput == builtIn
        )
    }
}

@Suite("MeetingMicFailoverAttemptTracker")
struct MeetingMicFailoverAttemptTrackerTests {
    @Test("does not report a switch until the requested input produces audio")
    func completionConfirmsTheRequestedInput() throws {
        var tracker = MeetingMicFailoverAttemptTracker()
        let record = failoverRecord()

        tracker.begin(record)
        #expect(tracker.resolve(.completed(preferredInputDeviceID: 99)) == nil)
        #expect(tracker.pending == record)

        let resolution = tracker.resolve(.completed(preferredInputDeviceID: 82))
        let resolved = try #require(resolution)
        #expect(resolved.didSwitchInput)
        #expect(resolved.handoffErrorDescription == nil)
        #expect(tracker.pending == nil)
    }

    @Test("failed handoff preserves the attempted fallback without claiming a switch")
    func failureDoesNotClaimSwitch() throws {
        var tracker = MeetingMicFailoverAttemptTracker()
        tracker.begin(failoverRecord())

        let resolution = tracker.resolve(.failed(
            preferredInputDeviceID: 82,
            reason: "No audio arrived"
        ))
        let resolved = try #require(resolution)

        #expect(!resolved.didSwitchInput)
        #expect(resolved.handoffErrorDescription == "No audio arrived")
        #expect(resolved.switchedMessage == nil)
        #expect(resolved.stillSilentMessage.contains("switching to MacBook Pro Microphone failed"))
        #expect(tracker.pending == nil)
    }

    private func failoverRecord() -> MeetingMicFailoverRecord {
        MeetingMicFailoverRecord(
            silentDeviceID: 91,
            silentDeviceName: "AirPods",
            fallbackDeviceID: 82,
            fallbackDeviceName: "MacBook Pro Microphone",
            decidedAt: Date()
        )
    }
}

private extension MeetingMicFailoverDecision {
    var switchRecord: MeetingMicFailoverRecord? {
        guard case .switchInput(let record) = self else { return nil }
        return record
    }

    var noFallbackRecord: MeetingMicFailoverRecord? {
        guard case .noFallback(let record) = self else { return nil }
        return record
    }
}
