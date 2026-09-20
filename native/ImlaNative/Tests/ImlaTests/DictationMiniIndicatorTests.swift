import AppKit
import Testing
import ImlaCore
@testable import ImlaNativeApp

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
        let disc = CGSize(width: 14, height: 14)
        #expect(DictationMiniIndicatorController.surfaceSize(for: .idle) == disc)
        #expect(DictationMiniIndicatorController.surfaceSize(for: .preparing) == disc)
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
        #expect(DictationMiniRendering.successGlassTintAlpha == 0.18)
        #expect(DictationMiniRendering.successCheckLineWidth == 1.8)
        #expect(DictationMiniPalette.failureHex == 0xFF6961)
        #expect(DictationMiniRendering.glassTintAlpha == 0.44)
        #expect(DictationMiniRendering.idleCoreDiameter == 3)
        #expect(DictationMiniRendering.preparingCoreDiameter == 5)
        #expect(DictationMiniRendering.discGlassTintHex == 0x000000)
        #expect(DictationMiniRendering.discGlassTintAlpha == 0.80)
        #expect(DictationMiniRendering.completionDiameter == 20)
        // The processing field and the completion glow must stay inside the shared 20 pt window.
        let fieldExtent = 2 * DictationMiniRendering.processingPointSpacing
            + DictationMiniRendering.processingPointMaxDiameter
        #expect(fieldExtent * 2 < DictationMiniIndicatorController.signalWindowSide)
        #expect(DictationMiniRendering.completionDiameter == DictationMiniIndicatorController.signalWindowSide)
        // Bright signals carry no compositor shadow (it reads as a dark ring); glass capsules do.
        #expect(!DictationMiniIndicatorController.usesCompositorShadow(.success))
        #expect(DictationMiniIndicatorController.usesCompositorShadow(.preparing))
        #expect(DictationMiniIndicatorController.usesCompositorShadow(.idle))
        #expect(DictationMiniIndicatorController.usesCompositorShadow(.recording))
        #expect(DictationMiniIndicatorController.usesCompositorShadow(.processing))
        #expect(DictationMiniRendering.preparingCoreDiameter < DictationMiniIndicatorController.discSide)
        #expect(DictationMiniIndicatorController.morphs(from: .idle, to: .preparing))
        #expect(DictationMiniIndicatorController.morphs(from: .preparing, to: .recording))
        #expect(DictationMiniIndicatorController.morphs(from: .recording, to: .processing))
        #expect(!DictationMiniIndicatorController.morphs(from: .hidden, to: .preparing))
        #expect(!DictationMiniIndicatorController.morphs(from: .success, to: .hidden))
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

    @Test("recording follows the mouse without editable focus and survives app deactivation")
    func recordingFollowsMouseWithoutFocus() throws {
        var pointer = CGPoint(x: 300, y: 250)
        let controller = DictationMiniIndicatorController(
            screenProvider: { [screen] }, pointerPollingInterval: 60,
            pointerProvider: { pointer }
        )
        defer { controller.close() }
        let token = controller.beginPreparing()
        controller.showRecording(generation: token, powerProvider: { -30 })
        pointer = CGPoint(x: 600, y: 400)
        controller.refreshPointerForTesting()
        controller.setIdleActivity(DictationFollowerActivity(isTyping: true, isScrolling: true, isWindowMoving: true, isSwitchingSpace: true))
        controller.clearIdleContext()
        #expect(controller.presentation == .recording)
        #expect(controller.currentFrame?.minX == pointer.x + 12)
        #expect(controller.isVisibleForTesting)
        let panel = try #require(controller.surfaceViewForTesting?.window)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        panel.orderOut(nil)
        controller.restoreActiveVisibilityForTesting()
        #expect(controller.isVisibleForTesting)
    }

    @Test("recording follows the mouse and processing holds its last position")
    func frozenProcessingAnchor() {
        var caret = CGPoint(x: 220, y: 320)
        let controller = makeController(pointer: { caret })
        let token = controller.beginPreparing()
        controller.showRecording(generation: token) { -24 }
        let initialCenter = controller.currentFrame.map { CGPoint(x: $0.midX, y: $0.midY) }

        caret = CGPoint(x: 245, y: 320)
        controller.refreshPointerForTesting()
        let recordingCenter = controller.currentFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
        #expect(recordingCenter != initialCenter)

        let recordingFrame = controller.currentFrame
        caret = CGPoint(x: 700, y: 100)
        controller.showProcessing(generation: token)
        let processingFrame = controller.currentFrame

        #expect(controller.presentation == .processing)
        #expect(controller.isMouseTransparentForTesting)
        #expect(!controller.isFollowingPointerForTesting)
        // The top-left stays anchored beside the mouse as the waveform shrinks to a signal.
        #expect(processingFrame?.minX == recordingFrame?.minX)
        #expect(processingFrame?.maxY == recordingFrame?.maxY)
        #expect(recordingFrame?.minX == 245 + DictationMiniPlacement.pointerGap)
        #expect(processingFrame?.size == CGSize(width: 20, height: 20))
        controller.close()
    }

    @Test("without a pointer sample the Mini stays visible, then follows the next mouse sample")
    func fallsBackThenSnapsToCaret() {
        var caret: CGPoint?
        let controller = makeController(pointer: { caret })
        let token = controller.beginPreparing()

        #expect(controller.presentation == .preparing)
        #expect(controller.isVisibleForTesting)
        #expect(controller.isFollowingPointerForTesting)
        let fallbackFrame = controller.currentFrame
        #expect((fallbackFrame?.minY ?? 999) < 100)

        caret = CGPoint(x: 220, y: 320)
        controller.refreshPointerForTesting()

        #expect(controller.isVisibleForTesting)
        #expect(controller.currentFrame != fallbackFrame)
        #expect(controller.currentFrame?.minX == 220 + DictationMiniPlacement.pointerGap)
        #expect(controller.currentFrame?.maxY == 320 - DictationMiniPlacement.pointerGap)
        controller.dismiss(generation: token)
        controller.close()
    }

    @Test("terminal feedback holds the last recording position instead of chasing the mouse")
    func terminalHoldsSessionAnchor() {
        var caret = CGPoint(x: 220, y: 320)
        let controller = makeController(pointer: { caret })
        let token = controller.beginPreparing()
        let preparingFrame = controller.currentFrame
        controller.showRecording(generation: token) { -24 }
        controller.showProcessing(generation: token)
        let processingFrame = controller.currentFrame

        caret = CGPoint(x: 500, y: 320)
        controller.showSuccess(generation: token, duration: 10)
        let successFrame = controller.currentFrame

        // The same corner stays anchored while the terminal signal is visible.
        #expect(preparingFrame != nil)
        #expect(processingFrame?.minX == preparingFrame?.minX)
        #expect(processingFrame?.maxY == preparingFrame?.maxY)
        #expect(successFrame == processingFrame)
        #expect(!controller.isFollowingPointerForTesting)
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

    @Test("Reduce Motion replaces continuous processing animation with a static field")
    func reducedMotionPolicy() {
        #expect(DictationMiniIndicatorController.processingAnimationIsContinuous(reduceMotion: false))
        #expect(!DictationMiniIndicatorController.processingAnimationIsContinuous(reduceMotion: true))
    }

    @Test("the idle dot follows the text context, hides on activity and Escape, and yields to a session")
    func idleDotFollower() {
        var announcements: [String] = []
        let controller = makeController(accessibilitySink: { announcements.append($0) })
        #expect(DictationMiniIndicatorController.surfaceSize(for: .idle) == CGSize(width: 14, height: 14))
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

        // Typing hides it briefly; it returns on the next sample once the hold lapses.
        controller.updateIdleContext(sample(200))
        #expect(controller.presentation == .idle)
        controller.setIdleActivity(DictationFollowerActivity(isTyping: true))
        #expect(controller.presentation == .hidden)
        #expect(DictationFollowerActivity.typingHold < 1)
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

    @Test("app exclusions hide idle feedback without hiding an explicit recording")
    func excludedAppStillRecords() {
        let controller = makeController()
        defer { controller.close() }
        var config = AppConfig()
        config.dictationIdleDotExcludedApps = ["app.hidden"]
        let sample = DictationTextContextSample(
            anchor: CGPoint(x: 220, y: 320), processIdentifier: 42, hasSelection: false,
            element: AXElementToken(element: AXUIElementCreateSystemWide())
        )
        controller.isIdleDotAllowed = config.allowsDictationIdleDot(in: "app.visible")
        controller.updateIdleContext(sample)
        #expect(controller.presentation == .idle)
        controller.isIdleDotAllowed = config.allowsDictationIdleDot(in: "app.hidden")
        #expect(controller.presentation == .hidden)
        let session = controller.beginPreparing()
        controller.showRecording(generation: session, powerProvider: { -30 })
        #expect(controller.presentation == .recording)
        controller.dismiss(generation: session)
        config.dictationIdleDotExcludedApps.removeAll()
        controller.isIdleDotAllowed = config.allowsDictationIdleDot(in: "app.hidden")
        controller.updateIdleContext(sample)
        #expect(controller.presentation == .idle)
    }

    @Test("destination hints are deduplicated, clear on return, and respect other toast ownership")
    func destinationHints() {
        let controller = makeController()
        defer { controller.close() }
        let destination = DictationSessionTarget(processID: 1, appName: "Notes", bundleID: "app.notes")
        let session = controller.beginPreparing(destination: destination)
        controller.destinationApplicationChanged(processID: 1, bundleID: "app.notes")
        #expect(controller.hintTextForTesting == nil)
        controller.destinationApplicationChanged(processID: 2, bundleID: "app.other")
        #expect(controller.hintTextForTesting == "Return to Notes to paste")
        controller.showToast("Hands-free")
        controller.destinationApplicationChanged(processID: 3, bundleID: "app.third")
        #expect(controller.hintTextForTesting == "Hands-free")
        controller.destinationApplicationChanged(processID: 1, bundleID: "app.notes")
        #expect(controller.hintTextForTesting == "Hands-free")
        controller.destinationApplicationChanged(processID: 2, bundleID: "app.other")
        #expect(controller.hintTextForTesting == "Return to Notes to paste")
        controller.showProcessing(generation: session)
        #expect(controller.hintTextForTesting == nil)
        controller.destinationApplicationChanged(processID: 1, bundleID: "app.notes")
        controller.destinationApplicationChanged(processID: 2, bundleID: "app.other")
        #expect(controller.hintTextForTesting == nil)
        _ = controller.beginPreparing()
        controller.destinationApplicationChanged(processID: 2, bundleID: "app.other")
        #expect(controller.hintTextForTesting == nil)
    }

    @Test("a target captured after hotkey arming only attaches to that Mini session")
    func destinationAfterArming() {
        let controller = makeController()
        defer { controller.close() }
        let target = DictationSessionTarget(processID: 1, appName: "Notes", bundleID: "app.notes")
        let first = controller.beginPreparing()
        controller.setDestination(target, generation: first)
        controller.showRecording(generation: first, powerProvider: { -30 })
        controller.destinationApplicationChanged(processID: 2, bundleID: "app.other")
        #expect(controller.hintTextForTesting == "Return to Notes to paste")
        _ = controller.beginPreparing()
        controller.setDestination(target, generation: first)
        controller.destinationApplicationChanged(processID: 2, bundleID: "app.other")
        #expect(controller.hintTextForTesting == nil)
    }

    @Test("recovery buttons deliver the exact retained record once and expire with their session")
    func savedRecoveryActions() throws {
        let controller = makeController()
        defer { controller.close() }
        var calls: [(Int64, DictationRecoveryAction)] = []
        func recover(_ id: Int64) {
            let session = controller.beginPreparing()
            controller.showFailure(generation: session)
            controller.showSavedDictationRecovery(dictationID: id) { calls.append(($0, $1)) }
        }
        recover(42)
        #expect(!controller.hintIsMouseTransparentForTesting)
        let copy = try #require(controller.hintButtonsForTesting.first { $0.title == "Copy" })
        let content = try #require(copy.superview)
        #expect(copy.window?.styleMask.contains(.nonactivatingPanel) == true)
        let label = try #require(controller.hintLabelForTesting)
        #expect(label.frame.width >= label.fittingSize.width)
        #expect(content.bounds.width < 300)
        #expect(controller.surfaceViewForTesting?.accessibilityLabel() == "Dictation saved to history; automatic paste unavailable")
        for button in controller.hintButtonsForTesting {
            #expect(content.bounds.contains(button.frame))
            #expect(!button.acceptsFirstResponder)
        }
        try exportRecoveryPreview(controller: controller, content: content)
        try sendButtonAction(copy)
        try sendButtonAction(copy)
        #expect(calls.count == 1)
        #expect(calls.first?.0 == 42 && calls.first?.1 == .copy)
        #expect(controller.presentation == .hidden)
        recover(43)
        let open = try #require(controller.hintButtonsForTesting.first { $0.accessibilityLabel() == "Open dictation" })
        try sendButtonAction(open)
        #expect(calls.count == 2)
        #expect(calls.last?.0 == 43 && calls.last?.1 == .open)
        recover(44)
        let stale = try #require(controller.hintButtonsForTesting.first)
        _ = controller.beginPreparing()
        try sendButtonAction(stale)
        #expect(calls.count == 2)
        #expect(controller.hintTextForTesting == nil)
        recover(45)
        let dismiss = try #require(controller.hintButtonsForTesting.first { $0.accessibilityLabel() == "Dismiss" })
        let discarded = try #require(controller.hintButtonsForTesting.first)
        try sendButtonAction(dismiss)
        try sendButtonAction(discarded)
        #expect(calls.count == 2)
        recover(46)
        let closed = try #require(controller.hintButtonsForTesting.first)
        controller.close()
        try sendButtonAction(closed)
        #expect(calls.count == 2)
    }

    @Test("recovery looks up the requested history record and does not substitute another after deletion")
    func recoveryRecordLookup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationStore(databaseURL: directory.appendingPathComponent("test.db"))
        try store.migrateIfNeeded()
        let retained = try store.insertDictation(text: "Retained fixture", durationSeconds: 1, startedAt: Date(), endedAt: Date())
        _ = try store.insertDictation(text: "Newer fixture", durationSeconds: 1, startedAt: Date(), endedAt: Date())
        var copied: [String] = []
        var opened: [Int64] = []
        for action in [DictationRecoveryAction.copy, .open] {
            #expect(action.perform(dictationID: retained, store: store, copy: { copied.append($0) }, open: { opened.append($0) }))
        }
        #expect(copied == ["Retained fixture"])
        #expect(opened == [retained])
        _ = try store.deleteDictation(id: retained)
        for action in [DictationRecoveryAction.copy, .open] {
            #expect(!action.perform(dictationID: retained, store: store, copy: { copied.append($0) }, open: { opened.append($0) }))
        }
        #expect(copied == ["Retained fixture"])
        #expect(opened == [retained])
    }

    @Test("recovery expires and ordinary hints stay mouse-transparent")
    func recoveryTimeout() async throws {
        let controller = makeController()
        defer { controller.close() }
        var acted = false
        let session = controller.beginPreparing()
        controller.showFailure(generation: session)
        controller.showSavedDictationRecovery(dictationID: 42, duration: 0.01) { _, _ in acted = true }
        let oldButton = try #require(controller.hintButtonsForTesting.first)
        try await Task.sleep(for: .milliseconds(80))
        try sendButtonAction(oldButton)
        #expect(!acted)
        #expect(controller.presentation == .hidden)
        _ = controller.beginPreparing()
        controller.showToast("Hands-free")
        #expect(controller.hintIsMouseTransparentForTesting)
        #expect(controller.hintButtonsForTesting.isEmpty)
    }

    @Test("the idle dot shows hover keycaps, a selection hint, and toasts")
    func idleExtras() async {
        let controller = makeController()
        controller.hotkeyLabelProvider = { "Right Cmd" }
        controller.isIdleDotAllowed = true
        let token = AXElementToken(element: AXUIElementCreateSystemWide())
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
        _ = controller.beginPreparing()
        #expect(controller.hintTextForTesting == "Hands-free — tap Right Cmd to stop")

        // A toast with no visible Mini waits for the next presentation.
        controller.close()
        let fresh = makeController()
        fresh.showToast("Hands-free", duration: 10)
        #expect(fresh.hintTextForTesting == nil)
        _ = fresh.beginPreparing()
        #expect(fresh.hintTextForTesting == "Hands-free")
        fresh.close()
    }

    @Test("clearing the idle context withdraws the dot at once and no stale anchor survives a re-enable")
    func idleContextClear() {
        let controller = makeController()
        controller.isIdleDotAllowed = true
        let token = AXElementToken(element: AXUIElementCreateSystemWide())
        let sample = DictationTextContextSample(
            anchor: CGPoint(x: 200, y: 300), processIdentifier: 1, hasSelection: true, element: token)
        controller.updateIdleContext(sample)
        #expect(controller.presentation == .idle)
        #expect(controller.idleHasSelectionForTesting)

        // A single miss would merely start the hysteresis streak; a clear is immediate.
        controller.clearIdleContext()
        #expect(controller.presentation == .hidden)
        #expect(!controller.idleHasSelectionForTesting)

        // Re-enabling shows nothing until a fresh sample arrives, then the dot returns.
        controller.isIdleDotAllowed = false
        controller.isIdleDotAllowed = true
        #expect(controller.presentation == .hidden)
        controller.updateIdleContext(sample)
        #expect(controller.presentation == .idle)
        controller.close()
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
            pointerPollingInterval: 60,
            pointerProvider: { pointer }
        )
        let token = controller.beginPreparing()
        #expect(controller.isVisibleForTesting)
        let pointerFrame = controller.currentFrame
        #expect(pointerFrame?.minX == 400 + DictationMiniPlacement.pointerGap)
        controller.dismiss(generation: token)

        pointer = nil
        _ = controller.beginPreparing()
        #expect(controller.isVisibleForTesting)
        #expect(controller.currentFrame?.minX == 400 + DictationMiniPlacement.pointerGap)
        #expect(controller.currentFrame?.minY ?? 0 < 100)
        controller.close()

        let idle = DictationMiniIndicatorController(
            screenProvider: { [screen] },
            pointerPollingInterval: 60,
            pointerProvider: { CGPoint(x: 400, y: 100) }
        )
        idle.isIdleDotAllowed = true
        idle.updateIdleContext(nil)
        #expect(!idle.isIdleDotVisibleForTesting)
        idle.close()
    }

    @Test("caret lookup rejects this app and invalid processes before reading accessibility controls")
    func caretLookupRejectsLocalProcess() {
        for pid: pid_t in [ProcessInfo.processInfo.processIdentifier, 0, -1] {
            var reads = 0
            let result = DictationCaretAnchorProvider.focusedElement(in: pid) { _, _ in
                reads += 1
                return nil
            }
            #expect(result == nil)
            #expect(reads == 0)
        }
    }

    @Test("caret lookup stays bound to the captured external app when global focus changes")
    func caretLookupUsesCapturedProcess() {
        let target: pid_t = 2_000_000_000
        var queriedProcess: pid_t = 0
        let result = DictationCaretAnchorProvider.focusedElement(in: target) { application, attribute in
            AXUIElementGetPid(application, &queriedProcess)
            #expect(attribute as String == kAXFocusedUIElementAttribute as String)
            return nil
        }
        #expect(result == nil)
        #expect(queriedProcess == target)
    }

    @Test("caret lookup rejects a focused element belonging to another process")
    func caretLookupRejectsRetargetedElement() {
        let result = DictationCaretAnchorProvider.focusedElement(in: 2_000_000_000) { _, _ in
            AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        }
        #expect(result == nil)
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
        // Bottom-centre of the caret, so the Mini hangs directly under it.
        #expect(anchor == CGPoint(x: 121, y: 680))
        let field = CGRect(x: 10, y: 100, width: 300, height: 200)
        #expect(DictationCaretAnchorProvider.firstLineAnchor(inAppKitRect: field) == CGPoint(x: 18, y: 282))
    }

    @Test("recovery preserves label space and stacks actions on narrow displays")
    func recoveryLayout() {
        for width: CGFloat in [180, 220, 360] {
            for textWidth: CGFloat in [90, 110] {
                let layout = DictationMiniHintPanel.layout(
                    textSize: NSSize(width: textWidth, height: 14), buttonWidths: [60, 46, 24], maximumWidth: width
                )
                let bounds = NSRect(origin: .zero, size: layout.size)
                #expect(bounds.contains(layout.label))
                #expect(layout.label.width >= textWidth)
                for frame in layout.buttons {
                    #expect(bounds.contains(frame))
                    #expect(!frame.intersects(layout.label))
                }
                #expect(layout.size.width <= width)
                if width == 180 { #expect(layout.size.height == 62) }
            }
        }
    }

    @Test("pointer placement stays inside each display and clear of the click target")
    func pointerDisplayEdges() throws {
        let secondary = DictationMiniPlacement.Screen(
            frame: CGRect(x: -800, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: -800, y: 24, width: 800, height: 576)
        )
        for display in [screen, secondary] {
            for point in [
                CGPoint(x: display.frame.minX + 2, y: 30),
                CGPoint(x: display.frame.maxX - 2, y: 30),
                CGPoint(x: display.frame.minX + 2, y: 595),
                CGPoint(x: display.frame.maxX - 2, y: 595),
            ] {
                let result = try #require(DictationMiniPlacement.placeNearPointer(
                    point, size: CGSize(width: 58, height: 22), screens: [screen, secondary]
                ))
                #expect(result.screen == display)
                #expect(display.visibleFrame.insetBy(dx: 4, dy: 4).contains(result.frame))
                #expect(!result.frame.contains(point))
            }
        }
    }

    @Test("pointer tracking crosses displays and stops after capture or teardown")
    func pointerTrackingLifetime() {
        let secondary = DictationMiniPlacement.Screen(
            frame: CGRect(x: -800, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: -800, y: 24, width: 800, height: 576)
        )
        var pointer = CGPoint(x: 300, y: 300)
        let controller = DictationMiniIndicatorController(
            screenProvider: { [screen, secondary] }, pointerPollingInterval: 60,
            pointerProvider: { pointer }
        )
        defer { controller.close() }
        let token = controller.beginPreparing()
        controller.showRecording(generation: token, powerProvider: { -30 })
        #expect(controller.hasPointerTrackingActivityForTesting)
        pointer = CGPoint(x: -300, y: 300)
        controller.refreshPointerForTesting()
        #expect(controller.currentFrame.map { secondary.visibleFrame.contains($0) } == true)
        controller.showProcessing(generation: token)
        let frozen = controller.currentFrame
        pointer = CGPoint(x: 600, y: 500)
        controller.refreshPointerForTesting()
        #expect(controller.currentFrame == frozen)
        #expect(!controller.isFollowingPointerForTesting)
        #expect(!controller.hasPointerTrackingActivityForTesting)
        controller.close()
        controller.refreshPointerForTesting()
        #expect(controller.currentFrame == nil)
        #expect(!controller.isFollowingPointerForTesting)
        #expect(!controller.hasPointerTrackingActivityForTesting)
    }

    private func exportRecoveryPreview(controller: DictationMiniIndicatorController, content: NSView) throws {
        guard let directory = ProcessInfo.processInfo.environment["IMLA_MINI_PREVIEW_DIR"] else { return }
        let surface = try #require(controller.surfaceViewForTesting)
        let views = [surface, content]
        let image = NSImage(size: NSSize(width: content.bounds.width + 56, height: 68))
        image.lockFocus()
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
        NSRect(origin: .zero, size: image.size).fill()
        var x: CGFloat = 12
        for view in views {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let target = NSRect(x: x, y: (68 - view.bounds.height) / 2, width: view.bounds.width, height: view.bounds.height)
            NSGraphicsContext.saveGraphicsState()
            let radius = view.layer?.cornerRadius ?? 0
            NSBezierPath(roundedRect: target, xRadius: radius, yRadius: radius).addClip()
            bitmap.draw(in: target)
            NSGraphicsContext.restoreGraphicsState()
            x += view.bounds.width + 8
        }
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("recovery.png"))
    }

    private func sendButtonAction(_ button: NSButton) throws {
        // Stale callbacks must be harmless even after the view is detached. A synthetic mouse
        // click on a closed AppKit window can terminate the command-line test host.
        let target = try #require(button.target as? NSObject)
        let action = try #require(button.action)
        _ = target.perform(action, with: button)
    }

    private func makeController(
        pointer: @escaping () -> CGPoint? = { CGPoint(x: 220, y: 320) },
        accessibilitySink: @escaping DictationMiniIndicatorController.AccessibilitySink = { _ in }
    ) -> DictationMiniIndicatorController {
        DictationMiniIndicatorController(
            screenProvider: { [screen] },
            pointerPollingInterval: 60,
            pointerProvider: pointer,
            accessibilitySink: accessibilitySink
        )
    }
}
