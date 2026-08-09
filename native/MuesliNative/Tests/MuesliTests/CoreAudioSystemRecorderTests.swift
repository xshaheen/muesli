import CoreAudio
import Testing
@testable import MuesliNativeApp

@Suite("CoreAudioSystemRecorder")
struct CoreAudioSystemRecorderTests {

    @Test("tap recovery keeps retrying after the fast retry window")
    func tapRecoveryKeepsRetrying() {
        #expect(CoreAudioTapRecoveryPolicy.retryDelay(afterFailedAttempt: 0) == 0.5)
        #expect(CoreAudioTapRecoveryPolicy.retryDelay(afterFailedAttempt: 1) == 1)
        #expect(CoreAudioTapRecoveryPolicy.retryDelay(afterFailedAttempt: 2) == 2)
        #expect(CoreAudioTapRecoveryPolicy.retryDelay(afterFailedAttempt: 3) == 5)
        #expect(CoreAudioTapRecoveryPolicy.retryDelay(afterFailedAttempt: 4) == 10)
        #expect(CoreAudioTapRecoveryPolicy.retryDelay(afterFailedAttempt: 5) == 30)
        #expect(CoreAudioTapRecoveryPolicy.retryDelay(afterFailedAttempt: 50) == 30)
        #expect(!CoreAudioTapRecoveryPolicy.shouldReportInterruption(afterFailedAttempt: 2))
        #expect(CoreAudioTapRecoveryPolicy.shouldReportInterruption(afterFailedAttempt: 3))
        #expect(!CoreAudioTapRecoveryPolicy.shouldReportInterruption(afterFailedAttempt: 4))
        #expect(CoreAudioTapRecoveryPolicy.shouldReportNoSamples(
            isAwaitingRecoverySamples: true,
            didReportInterruption: false
        ))
        #expect(!CoreAudioTapRecoveryPolicy.shouldReportNoSamples(
            isAwaitingRecoverySamples: true,
            didReportInterruption: true
        ))
        #expect(!CoreAudioTapRecoveryPolicy.shouldReportNoSamples(
            isAwaitingRecoverySamples: false,
            didReportInterruption: false
        ))
    }

    @Test("watchdog detects only an active capture callback stall")
    func watchdogDetectsActiveCaptureStall() {
        let timeout = CoreAudioTapRecoveryPolicy.callbackTimeoutNanoseconds
        let lastCallback = UInt64(1_000)

        #expect(!CoreAudioTapRecoveryPolicy.hasCallbackStalled(
            lastCallbackUptimeNanoseconds: lastCallback,
            nowUptimeNanoseconds: lastCallback + timeout - 1,
            isPaused: false,
            isRecovering: false
        ))
        #expect(CoreAudioTapRecoveryPolicy.hasCallbackStalled(
            lastCallbackUptimeNanoseconds: lastCallback,
            nowUptimeNanoseconds: lastCallback + timeout,
            isPaused: false,
            isRecovering: false
        ))
        #expect(!CoreAudioTapRecoveryPolicy.hasCallbackStalled(
            lastCallbackUptimeNanoseconds: lastCallback,
            nowUptimeNanoseconds: lastCallback + timeout,
            isPaused: true,
            isRecovering: false
        ))
        #expect(!CoreAudioTapRecoveryPolicy.hasCallbackStalled(
            lastCallbackUptimeNanoseconds: lastCallback,
            nowUptimeNanoseconds: lastCallback + timeout,
            isPaused: false,
            isRecovering: true
        ))
    }

    @Test("global tap description captures process mix except Muesli")
    func globalTapDescriptionExcludesSelfAudio() {
        let tapDescription = CoreAudioSystemRecorder.makeGlobalTapDescription(
            excludingProcessID: 123,
            name: "Muesli Global Test Tap"
        )

        #expect(tapDescription.name == "Muesli Global Test Tap")
        #expect(tapDescription.deviceUID == nil)
        #expect(tapDescription.stream == nil)
        #expect(tapDescription.processes == [123])
        #expect(tapDescription.isPrivate)
        #expect(tapDescription.muteBehavior == .unmuted)
    }

    @Test("aggregate device description includes tap with drift compensation")
    func aggregateDeviceDescriptionIncludesTap() throws {
        let description = CoreAudioSystemRecorder.makeAggregateDeviceDescription(
            tapUID: "tap-uid",
            aggregateUID: "aggregate-uid"
        )

        #expect(description[kAudioAggregateDeviceNameKey] as? String == "Muesli System Audio")
        #expect(description[kAudioAggregateDeviceUIDKey] as? String == "aggregate-uid")
        #expect(description[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        #expect(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool == true)

        let taps = try #require(description[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        let tap = try #require(taps.first)
        #expect(tap[kAudioSubTapUIDKey] as? String == "tap-uid")
        #expect(tap[kAudioSubTapDriftCompensationKey] as? Bool == true)
    }
}
