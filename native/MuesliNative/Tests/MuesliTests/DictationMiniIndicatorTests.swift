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

    @Test("idle owns no visible surface and states use the approved footprints")
    func stateVocabulary() {
        #expect(DictationMiniIndicatorController.surfaceSize(for: .hidden) == .zero)
        let signal = CGSize(width: 20, height: 20)
        #expect(DictationMiniIndicatorController.surfaceSize(for: .preparing) == signal)
        #expect(DictationMiniIndicatorController.surfaceSize(for: .recording) == CGSize(width: 58, height: 22))
        #expect(DictationMiniIndicatorController.surfaceSize(for: .processing) == signal)
        #expect(DictationMiniIndicatorController.surfaceSize(for: .success) == signal)
        #expect(DictationMiniIndicatorController.surfaceSize(for: .failure) == signal)
        #expect(DictationMiniIndicatorController.accessibilityLabel(for: .recording) == "Recording dictation")
        #expect(DictationMiniIndicatorController.accessibilityLabel(for: .processing) == "Generating transcription")
        #expect(DictationMiniIndicatorController.accessibilityLabel(for: .success) == "Dictation complete")
        #expect(DictationMiniIndicatorController.accessibilityLabel(for: .failure) == "Dictation failed")
    }

    @Test("palette matches the approved contextual spark direction")
    func contextualSparkPalette() {
        #expect(DictationMiniPalette.glassTintHex == 0x211F1E)
        #expect(DictationMiniPalette.surfaceTopHex == 0x32312F)
        #expect(DictationMiniPalette.surfaceBottomHex == 0x181817)
        #expect(DictationMiniPalette.orbTopHex == 0x272725)
        #expect(DictationMiniPalette.orbBottomHex == 0x0E0E0D)
        #expect(DictationMiniPalette.accentHex == 0xFF7043)
        #expect(DictationMiniPalette.accentHighlightHex == 0xFFB04D)
        #expect(DictationMiniPalette.successHex == 0x48E57B)
        #expect(DictationMiniPalette.successHighlightHex == 0xB6FFCF)
        #expect(DictationMiniRendering.successGlassTintAlpha == 0.82)
        #expect(DictationMiniRendering.successCheckLineWidth == 1.8)
        #expect(DictationMiniPalette.failureHex == 0xFF6961)
        #expect(DictationMiniRendering.glassTintAlpha == 0.44)
        #expect(DictationMiniRendering.preparingDotDiameter == 10)
        #expect(DictationMiniRendering.completionDiameter == 20)
        // The processing field and the completion glow must stay inside the shared 20 pt window.
        let fieldExtent = 2 * DictationMiniRendering.processingPointSpacing
            + DictationMiniRendering.processingPointMaxDiameter
        #expect(fieldExtent * 2 < DictationMiniIndicatorController.signalWindowSide)
        #expect(DictationMiniRendering.completionDiameter == DictationMiniIndicatorController.signalWindowSide)
        // Bright signals carry no compositor shadow (it reads as a dark ring); glass capsules do.
        #expect(!DictationMiniIndicatorController.usesCompositorShadow(.success))
        #expect(!DictationMiniIndicatorController.usesCompositorShadow(.preparing))
        #expect(!DictationMiniIndicatorController.usesCompositorShadow(.reminder))
        #expect(DictationMiniIndicatorController.usesCompositorShadow(.recording))
        #expect(DictationMiniIndicatorController.usesCompositorShadow(.processing))
        #expect(DictationMiniRendering.preparingDotDiameter < DictationMiniRendering.completionDiameter)
    }

    @Test("recording keeps the compact capsule and renders a dense one-point history field")
    func recordingWaveGeometry() {
        #expect(DictationMiniRendering.recordingGlassTintAlpha == 0.62)
        #expect(DictationMiniRendering.recordingBarCount == 24)
        #expect(DictationMiniRendering.recordingBarWidth == 1)
        #expect(DictationMiniRendering.recordingBarPitch == 2)
        #expect(DictationMiniRendering.recordingBarMinHeight == 1)
        #expect(DictationMiniRendering.recordingBarMaxHeight == 12)
        #expect(DictationMiniRendering.recordingSampleInterval == TimeInterval(1) / 30)
        #expect(DictationMiniRendering.recordingTailAlpha == 0.42)

        // The bar field must clear the 11-point rounded ends of the 58 x 22 capsule.
        let fieldWidth = CGFloat(DictationMiniRendering.recordingBarCount - 1)
            * DictationMiniRendering.recordingBarPitch
            + DictationMiniRendering.recordingBarWidth
        let capsule = DictationMiniIndicatorController.surfaceSize(for: .recording)
        #expect(fieldWidth == 47)
        #expect((capsule.width - fieldWidth) / 2 >= 5)
        #expect(DictationMiniRendering.recordingBarMaxHeight <= capsule.height - 8)
    }

    @Test("microphone power maps to a clamped, monotonic bar level with fast attack and slow release")
    func recordingLevelMapping() {
        #expect(DictationMiniRendering.recordingLevel(decibels: -160) == 0)
        #expect(DictationMiniRendering.recordingLevel(decibels: -58) == 0)
        #expect(DictationMiniRendering.recordingLevel(decibels: 0) == 1)
        #expect(DictationMiniRendering.recordingLevel(decibels: -18) == 1)
        let quiet = DictationMiniRendering.recordingLevel(decibels: -50)
        let speech = DictationMiniRendering.recordingLevel(decibels: -32)
        let loud = DictationMiniRendering.recordingLevel(decibels: -20)
        #expect(quiet > 0.2 && quiet < speech && speech < loud && loud < 1)
        #expect(speech > 0.6 && speech < 0.9)

        let attack = DictationMiniRendering.recordingEnvelope(current: 0, target: 1)
        let release = DictationMiniRendering.recordingEnvelope(current: 1, target: 0)
        #expect(attack > 0.5)
        #expect(release > 0.6)
        #expect(attack > 1 - release)
    }

    @Test("the history buffer keeps a fixed capacity with the newest level on the right")
    func waveformHistory() {
        var history = DictationMiniWaveformHistory(count: 4)
        #expect(history.levels == [0, 0, 0, 0])
        history.push(0.5)
        history.push(2)
        history.push(-1)
        #expect(history.count == 4)
        #expect(history.levels == [0, 0.5, 1, 0])
        history.reset()
        #expect(history.levels == [0, 0, 0, 0])
        #expect(DictationMiniWaveformHistory(count: 0).count == 1)
    }

    @Test("bar ageing fades the tail and Reduce Motion uses a symmetric static envelope")
    func barAgeingAndStaticEnvelope() {
        #expect(DictationMiniRendering.recordingBarAge(index: 0, count: 24) == 0)
        #expect(DictationMiniRendering.recordingBarAge(index: 23, count: 24) == 1)
        #expect(DictationMiniRendering.recordingBarAge(index: 0, count: 1) == 1)
        let envelope = (0..<24).map {
            DictationMiniRendering.recordingStaticEnvelope(index: $0, count: 24)
        }
        #expect(envelope == envelope.reversed())
        #expect(envelope.allSatisfy { $0 > 0.3 && $0 <= 1 })
        #expect(envelope[11] > envelope[0])
    }

    @Test("vector geometry aligns to the active backing scale")
    func pixelAlignment() {
        #expect(DictationMiniRendering.pixelAligned(5.24, scale: 2) == 5)
        #expect(DictationMiniRendering.pixelAligned(5.26, scale: 2) == 5.5)
        #expect(DictationMiniRendering.pixelAligned(5.4, scale: 1) == 5)
        #expect(DictationMiniRendering.pixelAligned(5.4, scale: 0) == 5.4)
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

        let recordingFrame = controller.currentFrame
        caret = CGPoint(x: 700, y: 100)
        controller.showProcessing(generation: token)
        let processingFrame = controller.currentFrame

        #expect(controller.presentation == .processing)
        #expect(controller.isMouseTransparentForTesting)
        #expect(!controller.isFollowingCaretForTesting)
        // Processing hangs off the same caret anchor as the recording capsule did (shared
        // top-right corner), and ignores the caret that moved after recording ended.
        #expect(processingFrame?.maxX == recordingFrame?.maxX)
        #expect(processingFrame?.maxY == recordingFrame?.maxY)
        #expect(processingFrame?.size == CGSize(width: 20, height: 20))
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

    @Test("terminal feedback holds the session anchor instead of chasing the post-insertion caret")
    func terminalHoldsSessionAnchor() {
        var caret = CGPoint(x: 220, y: 320)
        let controller = makeController(caret: { caret })
        let token = controller.beginPreparing()
        let preparingCenter = controller.currentFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
        controller.showRecording(generation: token) { -24 }
        controller.showProcessing(generation: token)
        let processingCenter = controller.currentFrame.map { CGPoint(x: $0.midX, y: $0.midY) }

        caret = CGPoint(x: 500, y: 320)
        controller.showSuccess(generation: token, duration: 10)
        let successCenter = controller.currentFrame.map { CGPoint(x: $0.midX, y: $0.midY) }

        #expect(preparingCenter != nil)
        #expect(processingCenter == preparingCenter)
        #expect(successCenter == processingCenter)
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

    @Test("the focus reminder shows only while idle, holds its anchor, yields to a session, and self-dismisses")
    func focusReminderLifecycle() async {
        var announcements: [String] = []
        let controller = makeController(accessibilitySink: { announcements.append($0) })
        #expect(DictationMiniIndicatorController.surfaceSize(for: .reminder) == CGSize(width: 20, height: 20))
        #expect(DictationMiniIndicatorController.accessibilityLabel(for: .reminder) == "Dictation ready")

        #expect(controller.showReminder(duration: 10) != nil)
        #expect(controller.presentation == .reminder)
        #expect(controller.isVisibleForTesting)
        #expect(!controller.isFollowingCaretForTesting)
        #expect(announcements.isEmpty)
        let reminderCenter = controller.currentFrame.map { CGPoint(x: $0.midX, y: $0.midY) }

        let token = controller.beginPreparing()
        #expect(controller.presentation == .preparing)
        let preparingCenter = controller.currentFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
        #expect(preparingCenter == reminderCenter)
        #expect(controller.showReminder() == nil)
        controller.dismiss(generation: token)

        #expect(controller.showReminder(duration: 0.01) != nil)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(controller.presentation == .hidden)

        #expect(controller.showReminder(duration: 10) != nil)
        controller.dismissReminder()
        #expect(controller.presentation == .hidden)
        controller.close()
    }

    @Test("the reminder gate fires once per focused element with a global cooldown")
    func focusReminderGate() {
        #expect(DictationFocusReminderGate<String>.defaultRepeatInterval == 30)
        var gate = DictationFocusReminderGate<String>(cooldown: 1.5, repeatInterval: 60)
        let firstFocus = gate.shouldRemind(for: "field-a", at: 10)
        let sameElement = gate.shouldRemind(for: "field-a", at: 10.5)
        let withinCooldown = gate.shouldRemind(for: "field-b", at: 11)
        let afterCooldown = gate.shouldRemind(for: "field-c", at: 13)
        gate.focusLost()
        let bounceBackTooSoon = gate.shouldRemind(for: "field-c", at: 20)
        gate.focusLost()
        let bounceBackMuchLater = gate.shouldRemind(for: "field-c", at: 80)
        #expect(firstFocus)
        #expect(!sameElement)
        #expect(!withinCooldown)
        #expect(afterCooldown)
        #expect(!bounceBackTooSoon)
        #expect(bounceBackMuchLater)
        #expect(DictationCaretAnchorProvider.editableTextRoles == ["AXTextField", "AXTextArea", "AXComboBox"])
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
