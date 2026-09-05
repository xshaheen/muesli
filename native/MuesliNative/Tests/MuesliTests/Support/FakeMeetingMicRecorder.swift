import CoreAudio
import Foundation
@testable import MuesliNativeApp

/// Scriptable `MeetingMicRecording` double shared by the route-aware recorder
/// tests and the meeting-session harnesses: call `onRawPCMSamples` directly to
/// drive the realtime path without CoreAudio.
final class FakeMeetingMicRecorder: MeetingMicRecording {
    var preferredInputDeviceID: AudioObjectID?
    var onRawPCMSamples: (([Int16]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var onHandoffOutcome: ((MeetingMicHandoffOutcome) -> Void)?

    let kind: MeetingMicRecorderKind
    var prepareCalls = 0
    var startCalls = 0
    var pauseCalls = 0
    var resumeCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var startError: Error?
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPrepareStarted: (() -> Void)?
    var prepareGate: DispatchSemaphore?
    var invalidatedForTeardown = false

    init(kind: MeetingMicRecorderKind) {
        self.kind = kind
    }

    func prepare() throws {
        prepareCalls += 1
        onPrepareStarted?()
        prepareGate?.wait()
    }

    func start() throws {
        if invalidatedForTeardown {
            throw NSError(domain: "test", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "invalidated",
            ])
        }
        startCalls += 1
        onStart?()
        if let startError { throw startError }
    }

    func pause() {
        pauseCalls += 1
    }

    func resume() {
        resumeCalls += 1
    }

    func stop() -> URL? {
        stopCalls += 1
        return nil
    }

    func cancel() {
        cancelCalls += 1
        onCancel?()
    }

    func invalidateForTeardown() {
        invalidatedForTeardown = true
    }

    func currentPower() -> Float {
        -80
    }

    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        MeetingMicRecorderDiagnosticsSnapshot(
            recorderKind: kind,
            preferredInputDeviceID: preferredInputDeviceID,
            route: nil
        )
    }
}
