import Foundation
import Testing
@testable import MuesliNativeApp

private actor SystemAudioTestSignal {
    private var pendingSignals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        if waiters.isEmpty {
            pendingSignals += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    func wait() async {
        if pendingSignals > 0 {
            pendingSignals -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite("SystemAudioRecorder lifecycle")
struct SystemAudioRecorderTests {
    @Test("startup timeout returns while start operation remains blocked")
    func startupTimeoutDoesNotAwaitBlockedOperation() async {
        let entered = SystemAudioTestSignal()
        let blocker = SystemAudioTestSignal()
        let startedAt = ContinuousClock.now

        do {
            let _: Int = try await SystemAudioStartupDeadline.wait(timeout: 0.02) {
                await entered.signal()
                await blocker.wait()
                return 1
            } onLateSuccess: { _ in }
            Issue.record("Expected startup timeout")
        } catch let error as SystemAudioStartupError {
            #expect(error == .timedOut)
            #expect(startedAt.duration(to: .now) < .seconds(1))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        await entered.wait()
        await blocker.signal()
    }

    @Test("late startup completion runs cleanup exactly once")
    func lateCompletionRunsCleanup() async {
        let entered = SystemAudioTestSignal()
        let cleanup = SystemAudioTestSignal()
        let blocker = SystemAudioTestSignal()

        do {
            let _: Int = try await SystemAudioStartupDeadline.wait(timeout: 0.02) {
                await entered.signal()
                await blocker.wait()
                return 42
            } onLateSuccess: { value in
                #expect(value == 42)
                await cleanup.signal()
            }
            Issue.record("Expected startup timeout")
        } catch is SystemAudioStartupError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        await entered.wait()
        await blocker.signal()
        await cleanup.wait()
    }

    @Test("startup cancellation returns while start operation remains blocked")
    func startupCancellationDoesNotAwaitBlockedOperation() async {
        let entered = SystemAudioTestSignal()
        let blocker = SystemAudioTestSignal()
        let cleanup = SystemAudioTestSignal()
        let task = Task {
            try await SystemAudioStartupDeadline.wait(timeout: 60) {
                await entered.signal()
                await blocker.wait()
                return 42
            } onLateSuccess: { value in
                #expect(value == 42)
                await cleanup.signal()
            }
        }

        await entered.wait()
        let canceledAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected startup cancellation")
        } catch is CancellationError {
            #expect(canceledAt.duration(to: .now) < .seconds(1))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        await blocker.signal()
        await cleanup.wait()
    }

    @Test("already canceled startup returns before installing work")
    func alreadyCanceledStartupReturnsPromptly() async {
        let blocker = SystemAudioTestSignal()
        let task = Task {
            try await SystemAudioStartupDeadline.wait(timeout: 60) {
                await blocker.wait()
                return 42
            } onLateSuccess: { _ in }
        }
        task.cancel()

        let canceledAt = ContinuousClock.now
        do {
            _ = try await task.value
            Issue.record("Expected startup cancellation")
        } catch is CancellationError {
            #expect(canceledAt.duration(to: .now) < .seconds(1))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // If the start closure won the cancellation race, let its unstructured
        // cleanup path finish instead of leaving test work suspended.
        await blocker.signal()
    }

    @Test("unexpected stop forwards once and expected stop is suppressed")
    func failureGateDeduplicatesAndSuppressesExpectedStop() {
        var gate = SystemAudioCaptureFailureGate()
        let beforeActivation = gate.shouldReportUnexpectedStop()
        #expect(!beforeActivation)
        gate.activate()
        let firstUnexpectedStop = gate.shouldReportUnexpectedStop()
        let duplicateUnexpectedStop = gate.shouldReportUnexpectedStop()
        #expect(firstUnexpectedStop)
        #expect(!duplicateUnexpectedStop)
        gate.deactivate()
        let expectedStop = gate.shouldReportUnexpectedStop()
        #expect(!expectedStop)
    }

    @Test("system audio failure stays visible after microphone recovers")
    func systemAudioWarningIsSticky() {
        var state = ActiveMeetingAudioWarningState()
        state.updateMicrophone(message: "Microphone is silent")
        state.recordSystemAudioFailure(message: "System audio stopped")
        state.updateMicrophone(message: nil)

        #expect(state.resolvedWarning(meetingID: 7)?.message == "System audio stopped")
        state.reset()
        #expect(state.resolvedWarning(meetingID: 7) == nil)
    }
}
