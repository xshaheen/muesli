import AppKit
import Testing
@testable import MuesliNativeApp

@MainActor
@Suite("Dictation Mini indicator", .serialized)
struct DictationMiniIndicatorTests {
    private let screen = DictationMiniPlacement.Screen(
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 0, y: 24, width: 800, height: 576)
    )

    @Test("idle owns no visible surface and every state has a distinct silhouette")
    func stateVocabulary() {
        #expect(DictationMiniIndicatorController.surfaceSize(for: .hidden) == .zero)
        #expect(DictationMiniIndicatorController.surfaceSize(for: .preparing) == CGSize(width: 14, height: 14))
        #expect(DictationMiniIndicatorController.surfaceSize(for: .recording) == CGSize(width: 58, height: 22))
        #expect(DictationMiniIndicatorController.surfaceSize(for: .processing) == CGSize(width: 28, height: 28))
        #expect(DictationMiniIndicatorController.surfaceSize(for: .success) == CGSize(width: 18, height: 14))
        #expect(DictationMiniIndicatorController.surfaceSize(for: .failure) == CGSize(width: 22, height: 22))
        #expect(DictationMiniIndicatorController.accessibilityLabel(for: .recording) == "Recording dictation")
        #expect(DictationMiniIndicatorController.accessibilityLabel(for: .processing) == "Generating transcription")
        #expect(DictationMiniIndicatorController.accessibilityLabel(for: .success) == "Dictation complete")
        #expect(DictationMiniIndicatorController.accessibilityLabel(for: .failure) == "Dictation failed")
    }

    @Test("palette matches the approved contextual spark direction")
    func contextualSparkPalette() {
        #expect(DictationMiniPalette.surfaceTopHex == 0x32312F)
        #expect(DictationMiniPalette.surfaceBottomHex == 0x181817)
        #expect(DictationMiniPalette.orbTopHex == 0x272725)
        #expect(DictationMiniPalette.orbBottomHex == 0x0E0E0D)
        #expect(DictationMiniPalette.accentHex == 0xFF7043)
        #expect(DictationMiniPalette.accentHighlightHex == 0xFFB04D)
        #expect(DictationMiniPalette.successHex == 0x62D691)
        #expect(DictationMiniPalette.failureHex == 0xFF6961)
    }

    @Test("recording follows the caret and processing freezes the recording anchor")
    func frozenProcessingAnchor() {
        var caret = CGPoint(x: 220, y: 320)
        let controller = makeController(caret: { caret })
        let token = controller.beginPreparing()
        controller.showRecording(generation: token) { -24 }
        let initialCenter = controller.currentFrame.map { CGPoint(x: $0.midX, y: $0.midY) }

        caret = CGPoint(x: 245, y: 320)
        controller.refreshCaretAnchorForTesting()
        let recordingCenter = controller.currentFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
        #expect(recordingCenter != initialCenter)

        caret = CGPoint(x: 700, y: 100)
        controller.showProcessing(generation: token)
        let processingCenter = controller.currentFrame.map { CGPoint(x: $0.midX, y: $0.midY) }

        #expect(controller.presentation == .processing)
        #expect(controller.isMouseTransparentForTesting)
        #expect(!controller.isFollowingCaretForTesting)
        #expect(recordingCenter == processingCenter)
        controller.close()
    }

    @Test("the Mini stays hidden until focused caret geometry becomes available")
    func waitsForCaretGeometry() {
        var caret: CGPoint?
        let controller = makeController(caret: { caret })
        let token = controller.beginPreparing()

        #expect(controller.presentation == .preparing)
        #expect(!controller.isVisibleForTesting)
        #expect(controller.isFollowingCaretForTesting)

        caret = CGPoint(x: 220, y: 320)
        controller.refreshCaretAnchorForTesting()

        #expect(controller.isVisibleForTesting)
        controller.dismiss(generation: token)
        controller.close()
    }

    @Test("terminal feedback reacquires the post-insertion caret once")
    func terminalCaretReacquisition() {
        var caret = CGPoint(x: 220, y: 320)
        let controller = makeController(caret: { caret })
        let token = controller.beginPreparing()
        controller.showRecording(generation: token) { -24 }
        controller.showProcessing(generation: token)
        let processingCenter = controller.currentFrame.map { CGPoint(x: $0.midX, y: $0.midY) }

        caret = CGPoint(x: 500, y: 320)
        controller.showSuccess(generation: token, duration: 10)
        let successCenter = controller.currentFrame.map { CGPoint(x: $0.midX, y: $0.midY) }

        #expect(successCenter != processingCenter)
        #expect(!controller.isFollowingCaretForTesting)
        controller.close()
    }

    @Test("a stale terminal dismissal cannot close a newer session")
    func terminalGenerationSafety() async {
        let controller = makeController()
        let first = controller.beginPreparing()
        controller.showSuccess(generation: first, duration: 0.01)
        _ = controller.beginPreparing(at: CGPoint(x: 300, y: 300))
        try? await Task.sleep(for: .milliseconds(30))

        #expect(controller.presentation == .preparing)
        #expect(controller.isVisibleForTesting)
        controller.close()
    }

    @Test("warnings yield to an active capture and announce accepted transitions once")
    func warningPriorityAndAnnouncements() {
        var announcements: [String] = []
        let controller = makeController(accessibilitySink: { announcements.append($0) })
        let token = controller.beginPreparing()
        controller.showRecording(generation: token) { -30 }
        controller.showRecording(generation: token) { -30 }

        #expect(controller.showWarning("Model warming") == nil)
        #expect(announcements == ["Recording dictation"])
        controller.dismiss(generation: token)
        #expect(controller.presentation == .hidden)
        controller.close()
    }

    @Test("accepted warnings normalize, announce, and dismiss")
    func acceptedWarningLifecycle() async {
        var announcements: [String] = []
        let controller = makeController(accessibilitySink: { announcements.append($0) })

        let token = controller.showWarning("  Model   warming  ", duration: 0.01)
        #expect(token != nil)
        #expect(controller.presentation == .warning("Model warming"))
        #expect(announcements == ["Model warming"])

        try? await Task.sleep(for: .milliseconds(30))
        #expect(controller.presentation == .hidden)
        controller.close()
    }

    @Test("recoverable failure keeps the failure mark before showing history guidance")
    func failureRecoveryGuidance() async {
        let controller = makeController()
        let token = controller.beginPreparing()
        controller.showFailure(generation: token, duration: 1)
        controller.showRecoveryWarningAfterFailure(
            "Saved in Recent Dictations — target changed",
            failureDuration: 0.01,
            warningDuration: 0.04
        )

        #expect(controller.presentation == .failure)
        try? await Task.sleep(for: .milliseconds(25))
        #expect(controller.presentation == .warning("Saved in Recent Dictations — target changed"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(controller.presentation == .hidden)
        controller.close()
    }

    @Test("Reduce Motion replaces continuous processing animation with a static field")
    func reducedMotionPolicy() {
        #expect(DictationMiniIndicatorController.processingAnimationIsContinuous(reduceMotion: false))
        #expect(!DictationMiniIndicatorController.processingAnimationIsContinuous(reduceMotion: true))
    }

    @Test("accessibility caret rectangles convert into AppKit screen coordinates")
    func caretCoordinateConversion() {
        let accessibilityRect = CGRect(x: 120, y: 200, width: 2, height: 20)
        let converted = DictationCaretAnchorProvider.appKitRect(
            fromAccessibilityRect: accessibilityRect,
            primaryMaxY: 900
        )
        let anchor = DictationCaretAnchorProvider.appKitAnchor(
            fromAccessibilityRect: accessibilityRect,
            primaryMaxY: 900
        )

        #expect(converted == CGRect(x: 120, y: 680, width: 2, height: 20))
        #expect(anchor == CGPoint(x: 120, y: 690))
    }

    private func makeController(
        caret: @escaping () -> CGPoint? = { CGPoint(x: 220, y: 320) },
        accessibilitySink: @escaping DictationMiniIndicatorController.AccessibilitySink = { _ in }
    ) -> DictationMiniIndicatorController {
        DictationMiniIndicatorController(
            screenProvider: { [screen] },
            caretAnchorProvider: caret,
            caretPollingInterval: 60,
            accessibilitySink: accessibilitySink
        )
    }
}
