import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("StreamingMicRecorder configuration-change debounce")
struct StreamingMicRecorderConfigChangeTests {
    @Test("a notification burst coalesces into the last scheduled restart")
    func burstCoalesces() {
        var scheduled: [(delay: TimeInterval, work: DispatchWorkItem)] = []
        let recorder = StreamingMicRecorder(
            directoryName: "muesli-test-config-change",
            recoversFromInputConfigurationChanges: true,
            configurationChangeSettleDelay: 0.25,
            configurationChangeRestartScheduler: { delay, work in
                scheduled.append((delay, work))
            }
        )
        let recordingID = UUID()

        recorder.debounceConfigurationChangeRestart(recordingID: recordingID)
        recorder.debounceConfigurationChangeRestart(recordingID: recordingID)
        recorder.debounceConfigurationChangeRestart(recordingID: recordingID)

        #expect(scheduled.count == 3)
        #expect(scheduled.allSatisfy { $0.delay == 0.25 })
        #expect(scheduled[0].work.isCancelled)
        #expect(scheduled[1].work.isCancelled)
        #expect(!scheduled[2].work.isCancelled)

        // The survivor firing against a recorder that is not recording must be
        // a safe no-op (the run-state guard, not timing, is the safety net).
        scheduled[2].work.perform()
    }
}
