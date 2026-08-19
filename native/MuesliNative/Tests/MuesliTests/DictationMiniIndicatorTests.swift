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
        #expect(!DictationMiniIndicatorController.usesCompositorShadow(.idle))
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
        #expect(DictationMiniRendering.recordingQuietAlpha == 0.48)

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

    @Test("the spike engine is deterministic, bounded, quiet in silence and lively under voice")
    func spikeEngine() {
        var a = DictationMiniSpikeEngine(count: 24, seed: 7)
        var b = DictationMiniSpikeEngine(count: 24, seed: 7)
        for _ in 0..<40 { a.advance(level: 0.8); b.advance(level: 0.8) }
        #expect(a == b)
        #expect(a.bars.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(!a.isQuiet)
        let loudMean = a.bars.reduce(0, +) / CGFloat(a.bars.count)
        #expect(loudMean > 0.15)

        var quiet = DictationMiniSpikeEngine(count: 24, seed: 7)
        for _ in 0..<40 { quiet.advance(level: 0) }
        #expect(quiet.isQuiet)
        #expect(quiet.sparks.isEmpty)
        let quietMax = quiet.bars.max() ?? 1
        #expect(quietMax <= DictationMiniSpikeEngine.quietShimmer + 0.001)

        // Release: after the voice stops the field decays instead of snapping.
        var decaying = a
        decaying.advance(level: 0)
        let afterOneFrame = decaying.bars.reduce(0, +) / CGFloat(decaying.bars.count)
        #expect(afterOneFrame < loudMean && afterOneFrame > quietMax)
        for _ in 0..<120 { decaying.advance(level: 0) }
        #expect(decaying.bars.max() ?? 1 < 0.1)
        decaying.reset()
        #expect(decaying.bars.allSatisfy { $0 == 0 })
    }

    @Test("Reduce Motion uses a symmetric static envelope")
    func staticEnvelope() {
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

    @Test("without caret or pointer the Mini homes to the screen bottom, then snaps to the caret once it resolves")
    func fallsBackThenSnapsToCaret() {
        var caret: CGPoint?
        let controller = makeController(caret: { caret })
        let token = controller.beginPreparing()

        #expect(controller.presentation == .preparing)
        #expect(controller.isVisibleForTesting)
        #expect(controller.isFollowingCaretForTesting)
        let fallbackFrame = controller.currentFrame
        #expect((fallbackFrame?.minY ?? 999) < 100)

        caret = CGPoint(x: 220, y: 320)
        controller.refreshCaretAnchorForTesting()

        #expect(controller.isVisibleForTesting)
        #expect(controller.currentFrame != fallbackFrame)
        #expect(controller.currentFrame?.maxX == 210)
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

    @Test("the idle dot follows the text context, hides on activity and Escape, and yields to a session")
    func idleDotFollower() {
        var announcements: [String] = []
        let controller = makeController(accessibilitySink: { announcements.append($0) })
        #expect(DictationMiniIndicatorController.surfaceSize(for: .idle) == CGSize(width: 20, height: 20))
        #expect(DictationMiniIndicatorController.accessibilityLabel(for: .idle) == "Dictation ready")
        let token = AXElementToken(element: AXUIElementCreateSystemWide())
        func sample(_ x: CGFloat, selection: Bool = false) -> DictationTextContextSample {
            DictationTextContextSample(anchor: CGPoint(x: x, y: 300), processIdentifier: 1, hasSelection: selection, element: token)
        }

        // Not allowed yet: samples arrive but nothing shows.
        controller.updateIdleContext(sample(200))
        #expect(!controller.isIdleDotVisibleForTesting)

        controller.isIdleDotAllowed = true
        #expect(controller.isIdleDotVisibleForTesting)
        #expect(announcements.isEmpty)
        let first = controller.currentFrame

        // Follows the caret once it moves past the jitter threshold.
        controller.updateIdleContext(sample(260, selection: true))
        #expect(controller.currentFrame != first)
        #expect(controller.idleHasSelectionForTesting)

        // Brief misses hold the last caret; a streak withdraws it.
        controller.updateIdleContext(nil)
        controller.updateIdleContext(nil)
        #expect(controller.presentation == .idle)
        controller.updateIdleContext(nil)
        #expect(controller.presentation == .hidden)

        // Typing hides it; stopping typing brings it back on the next sample.
        controller.updateIdleContext(sample(200))
        #expect(controller.presentation == .idle)
        controller.setIdleActivity(DictationFollowerActivity(isTyping: true))
        #expect(controller.presentation == .hidden)
        controller.setIdleActivity(DictationFollowerActivity())
        controller.updateIdleContext(sample(200))
        #expect(controller.presentation == .idle)

        // Escape hides until the focused element changes.
        controller.hideIdleDotUntilFocusChanges()
        #expect(controller.presentation == .hidden)
        controller.updateIdleContext(sample(205))
        #expect(controller.presentation == .hidden)
        controller.idleFocusDidChange()
        #expect(controller.presentation == .idle)

        // A real session takes over in place and the dot returns after it ends.
        let session = controller.beginPreparing()
        #expect(controller.presentation == .preparing)
        controller.updateIdleContext(sample(200))
        #expect(controller.presentation == .preparing)
        controller.dismiss(generation: session)
        controller.updateIdleContext(sample(200))
        #expect(controller.presentation == .idle)

        // Snooze.
        controller.snoozeIdleDot(for: 60)
        #expect(controller.presentation == .hidden)
        controller.close()
    }

    @Test("the idle dot shows hover keycaps, a selection hint, toasts, and pins to the focused window")
    func idleExtras() async {
        let controller = makeController()
        controller.hotkeyLabelProvider = { "Right Cmd" }
        controller.isIdleDotAllowed = true
        let token = AXElementToken(element: AXUIElementCreateSystemWide())
        let window = CGRect(x: 100, y: 100, width: 600, height: 400)
        controller.updateIdleWindowFrame(window, processIdentifier: 42)
        controller.updateIdleContext(DictationTextContextSample(
            anchor: CGPoint(x: 220, y: 320), processIdentifier: 42, hasSelection: false, element: token))
        #expect(controller.presentation == .idle)

        controller.idleHoverChanged(true)
        #expect(controller.hintTextForTesting == "Hold Right Cmd to dictate")
        controller.idleHoverChanged(false)
        #expect(controller.hintTextForTesting == nil)

        controller.updateIdleContext(DictationTextContextSample(
            anchor: CGPoint(x: 220, y: 320), processIdentifier: 42, hasSelection: true, element: token))
        #expect(controller.hintTextForTesting == "Hold Right Cmd to replace the selection")

        controller.showToast("Hands-free — tap Right Cmd to stop", duration: 10)
        #expect(controller.hintTextForTesting == "Hands-free — tap Right Cmd to stop")

        // Drag the dot and drop it: it pins as an offset from the window's top-left and rides along.
        controller.idleDragged(to: CGPoint(x: 500, y: 420))
        controller.idleDragEnded()
        #expect(controller.isIdlePinnedForTesting)
        let pinnedFrame = controller.currentFrame
        #expect(pinnedFrame?.origin == CGPoint(x: 500, y: 420))
        controller.updateIdleWindowFrame(window.offsetBy(dx: 30, dy: -20), processIdentifier: 42)
        #expect(controller.currentFrame?.origin == CGPoint(x: 530, y: 400))

        // Pinned: caret samples no longer move it, and a miss streak does not hide it.
        controller.updateIdleContext(DictationTextContextSample(
            anchor: CGPoint(x: 150, y: 150), processIdentifier: 42, hasSelection: false, element: token))
        #expect(controller.currentFrame?.origin == CGPoint(x: 530, y: 400))
        for _ in 0..<4 { controller.updateIdleContext(nil) }
        #expect(controller.presentation == .idle)

        // A toast with no visible Mini waits for the next presentation.
        controller.close()
        let fresh = makeController()
        fresh.showToast("Hands-free", duration: 10)
        #expect(fresh.hintTextForTesting == nil)
        _ = fresh.beginPreparing()
        #expect(fresh.hintTextForTesting == "Hands-free")
        fresh.close()
    }

    @Test("follower hysteresis holds through two misses and withdraws on the third")
    func followerHysteresis() {
        var hysteresis = DictationFollowerHysteresis()
        let anchor = CGPoint(x: 10, y: 10)
        #expect(hysteresis.observe(anchor) == anchor)
        #expect(hysteresis.observe(nil) == anchor)
        #expect(hysteresis.observe(nil) == anchor)
        #expect(hysteresis.observe(nil) == nil)
        #expect(hysteresis.observe(nil) == nil)
        #expect(hysteresis.observe(anchor) == anchor)
        #expect(hysteresis.missStreak == 0)
        #expect(DictationFollowerActivity(isScrolling: true).isSuppressing)
        #expect(!DictationFollowerActivity().isSuppressing)
        #expect(DictationCaretAnchorProvider.editableTextRoles == ["AXTextField", "AXTextArea", "AXComboBox"])
    }

    @Test("active states fall back to the pointer, then the screen bottom, and the idle dot never does")
    func activeFallbackLadder() {
        var pointer: CGPoint? = CGPoint(x: 400, y: 100)
        let controller = DictationMiniIndicatorController(
            screenProvider: { [screen] },
            caretAnchorProvider: { nil },
            caretPollingInterval: 60,
            pointerProvider: { pointer }
        )
        let token = controller.beginPreparing()
        #expect(controller.isVisibleForTesting)
        let pointerFrame = controller.currentFrame
        #expect(pointerFrame?.maxX == 390)
        controller.dismiss(generation: token)

        pointer = nil
        _ = controller.beginPreparing()
        #expect(controller.isVisibleForTesting)
        #expect(controller.currentFrame?.maxX == 390)
        #expect(controller.currentFrame?.minY ?? 0 < 100)
        controller.close()

        let idle = DictationMiniIndicatorController(
            screenProvider: { [screen] },
            caretAnchorProvider: { nil },
            caretPollingInterval: 60,
            pointerProvider: { CGPoint(x: 400, y: 100) }
        )
        idle.isIdleDotAllowed = true
        idle.updateIdleContext(nil)
        #expect(!idle.isIdleDotVisibleForTesting)
        idle.close()
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
