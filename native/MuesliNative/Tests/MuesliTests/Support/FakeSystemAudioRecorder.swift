import Foundation
@testable import MuesliNativeApp

/// Scriptable `SystemAudioCapturing` double for the meeting-session harnesses.
///
/// `stop()` returns `nil` so the session skips diarization, the offline repair
/// pass, and every full-file fallback; the harness drives capture by invoking
/// `onPCMSamples` directly.
final class FakeSystemAudioRecorder: SystemAudioCapturing {
    var onPCMSamples: (([Int16]) -> Void)?
    var onSystemAudioInterruption: (() -> Void)?
    var onSystemAudioFailure: ((Error) -> Void)?
    var onSystemAudioRecovery: (() -> Void)?

    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var startCalls = 0
    private(set) var pauseCalls = 0
    private(set) var resumeCalls = 0
    private(set) var stopCalls = 0

    func start() async throws {
        startCalls += 1
        isRecording = true
        isPaused = false
    }

    func pause() {
        pauseCalls += 1
        isPaused = true
    }

    func resume() {
        resumeCalls += 1
        isPaused = false
    }

    func stop() async -> URL? {
        stopCalls += 1
        isRecording = false
        isPaused = false
        return nil
    }

    /// Delivers one capture callback exactly as the real recorders do: the raw
    /// samples reach the session after the raw file already holds them.
    func deliver(_ samples: [Int16]) {
        onPCMSamples?(samples)
    }
}
