import AppKit
import Testing
@testable import MuesliNativeApp

@Suite("Meeting recording elapsed clock")
struct MeetingRecordingElapsedClockTests {
    @Test("paused time is excluded after resume")
    func excludesPausedTime() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var clock = MeetingRecordingElapsedClock()

        clock.start(at: start)
        clock.pause(at: start.addingTimeInterval(12))
        #expect(clock.elapsed(at: start.addingTimeInterval(42)) == 12)

        clock.resume(at: start.addingTimeInterval(42))
        #expect(clock.elapsed(at: start.addingTimeInterval(50)) == 20)
    }
}

@Suite("Meeting recording panel geometry")
struct MeetingRecordingPanelGeometryTests {
    private let screen = NSRect(x: -1_920, y: 0, width: 1_920, height: 1_080)

    @Test("default placement is stable at the display bottom trailing edge")
    func stableDefaultPlacement() {
        let first = MeetingRecordingPanelController.resolvedFrame(
            savedCenter: nil,
            size: MeetingRecordingPanelController.basePillSize,
            screens: [screen]
        )
        let second = MeetingRecordingPanelController.resolvedFrame(
            savedCenter: nil,
            size: MeetingRecordingPanelController.basePillSize,
            screens: [screen]
        )

        #expect(first == second)
        #expect(first.maxX == screen.maxX - 12)
        #expect(first.minY == screen.minY + 12)
    }

    @Test("a saved center with negative coordinates is restored on its display")
    func restoresNegativeSavedCenter() {
        let center = CGPoint(x: -800, y: 450)

        let frame = MeetingRecordingPanelController.resolvedFrame(
            savedCenter: center,
            size: MeetingRecordingPanelController.basePillSize,
            screens: [screen]
        )

        #expect(frame.midX == center.x)
        #expect(frame.midY == center.y)
    }

    /// The drag anchor tracks the pointer 1:1, so it legally leaves every `visibleFrame` —
    /// the menu-bar strip, the Dock strip, the gap between mismatched displays. Resolving
    /// those to the default corner teleported the object to the primary display mid-drag and
    /// then saved the jump as the user's spot.
    @Test("an anchor outside every visible frame resolves on the nearest display")
    func anchorOutsideEveryVisibleFrameKeepsItsDisplay() {
        // The menu-bar strip: inside the display, outside its visible frame.
        let inMenuBarStrip = CGPoint(x: screen.midX, y: screen.maxY + 20)

        let frame = MeetingRecordingPanelController.basePillFrame(
            anchorCenter: inMenuBarStrip,
            screens: [screen]
        )

        #expect(frame.midX == inMenuBarStrip.x, "the pointer's column is kept")
        #expect(frame.maxY == screen.maxY - 12, "clamped down into the display, not dropped to its corner")
        #expect(frame.minY != screen.minY + 12, "the default bottom-trailing corner is not a drag destination")
    }

    @Test("an anchor in the gap between displays lands on the nearer one")
    func anchorBetweenDisplaysPicksTheNearestOne() {
        let secondary = NSRect(x: 1_920, y: 300, width: 1_440, height: 900)
        let primary = NSRect(x: 0, y: 0, width: 1_920, height: 1_080)
        // Below the secondary and well right of the primary: outside both visible frames.
        let inTheGap = CGPoint(x: 2_600, y: 120)

        let frame = MeetingRecordingPanelController.basePillFrame(
            anchorCenter: inTheGap,
            screens: [primary, secondary]
        )

        #expect(frame.midX == inTheGap.x)
        #expect(frame.minY == secondary.minY + 12, "clamped into the nearer display")
        #expect(frame.minX >= secondary.minX)
    }

    @Test("only an absent anchor takes the default corner")
    func absentAnchorStillTakesTheDefaultCorner() {
        // `MeetingRecordButtonController.show()` relies on this for a first run.
        let frame = MeetingRecordingPanelController.resolvedFrame(
            savedCenter: nil,
            size: MeetingRecordingPanelController.basePillSize,
            screens: [screen]
        )

        #expect(frame.maxX == screen.maxX - 12)
        #expect(frame.minY == screen.minY + 12)
    }

    @Test("the held corner is the display half the base pill rests in")
    func heldCornerFollowsTheDisplayHalf() {
        let bottomTrailing = MeetingRecordingPanelController.basePillFrame(
            anchorCenter: CGPoint(x: -100, y: 100),
            screens: [screen]
        )
        let topLeading = MeetingRecordingPanelController.basePillFrame(
            anchorCenter: CGPoint(x: -1_800, y: 980),
            screens: [screen]
        )

        #expect(MeetingRecordingPanelController.heldCorner(for: bottomTrailing, in: screen) == .bottomTrailing)
        #expect(MeetingRecordingPanelController.heldCorner(for: topLeading, in: screen) == .topLeading)
    }

    /// Covers AE1: at the bottom-trailing corner every layout keeps the pill's trailing and
    /// bottom edges, so the row unfolds leftward and the panel grows up and to the left.
    @Test("row and panel grow from a held bottom trailing corner")
    func layoutsGrowFromTheBottomTrailingCorner() {
        let pill = MeetingRecordingPanelController.basePillFrame(anchorCenter: nil, screens: [screen])
        let corner = MeetingRecordingPanelController.heldCorner(for: pill, in: screen)

        #expect(corner == .bottomTrailing)
        #expect(pill.maxX == screen.maxX - 12)
        #expect(pill.minY == screen.minY + 12)

        let row = MeetingRecordingPanelController.frame(
            for: .row,
            anchoredTo: pill,
            corner: corner,
            size: MeetingRecordingPanelController.rowSize,
            screen: screen
        )
        let panel = MeetingRecordingPanelController.frame(
            for: .panel,
            anchoredTo: pill,
            corner: corner,
            size: MeetingRecordingPanelController.defaultPanelSize,
            screen: screen
        )
        let minimized = MeetingRecordingPanelController.frame(
            for: .pill,
            anchoredTo: pill,
            corner: corner,
            size: MeetingRecordingPanelController.basePillSize,
            screen: screen
        )

        #expect(row.maxX == pill.maxX)
        #expect(row.minY == pill.minY)
        #expect(row.width == 212)
        #expect(panel.maxX == pill.maxX)
        #expect(panel.minY == pill.minY)
        #expect(minimized == pill)
    }

    @Test("a held top leading corner keeps minX and maxY")
    func layoutsGrowFromTheTopLeadingCorner() {
        let pill = MeetingRecordingPanelController.basePillFrame(
            anchorCenter: CGPoint(x: screen.minX + 48, y: screen.maxY - 24),
            screens: [screen]
        )
        let corner = MeetingRecordingPanelController.heldCorner(for: pill, in: screen)

        #expect(corner == .topLeading)

        for size in [
            MeetingRecordingPanelController.rowSize,
            MeetingRecordingPanelController.defaultPanelSize,
        ] {
            let frame = MeetingRecordingPanelController.frame(
                for: size == MeetingRecordingPanelController.rowSize ? .row : .panel,
                anchoredTo: pill,
                corner: corner,
                size: size,
                screen: screen
            )
            #expect(frame.minX == pill.minX)
            #expect(frame.maxY == pill.maxY)
        }
    }

    @Test("every layout stays inside a negative-origin display")
    func layoutsStayInsideANegativeOriginDisplay() {
        for anchor in [
            CGPoint(x: screen.minX + 4, y: screen.minY + 4),
            CGPoint(x: screen.maxX - 4, y: screen.maxY - 4),
            CGPoint(x: screen.midX, y: screen.midY),
        ] {
            let pill = MeetingRecordingPanelController.basePillFrame(anchorCenter: anchor, screens: [screen])
            let corner = MeetingRecordingPanelController.heldCorner(for: pill, in: screen)
            for layout in [MeetingObjectLayout.pill, .row, .panel] {
                let frame = MeetingRecordingPanelController.frame(
                    for: layout,
                    anchoredTo: pill,
                    corner: corner,
                    size: MeetingRecordingPanelController.size(
                        for: layout,
                        content: .clock(hasHours: false)
                    ),
                    screen: screen
                )
                #expect(frame.minX >= screen.minX + 12)
                #expect(frame.minY >= screen.minY + 12)
                #expect(frame.maxX <= screen.maxX - 12)
                #expect(frame.maxY <= screen.maxY - 12)
            }
        }
    }

    /// Covers AE9: the clock steps the width once at the first hour, and the finalizing
    /// vocabulary steps it once more — never per status word.
    @Test("the pill and row widths step once for the hour and once for the status word")
    func widthStepsOncePerContent() {
        #expect(MeetingRecordingPanelController.pillSize(for: .clock(hasHours: false))
            == NSSize(width: 72, height: 22))
        #expect(MeetingRecordingPanelController.pillSize(for: .clock(hasHours: true))
            == NSSize(width: 86, height: 22))
        #expect(MeetingRecordingPanelController.size(for: .row, content: .clock(hasHours: false)).width == 212)
        #expect(MeetingRecordingPanelController.size(for: .row, content: .clock(hasHours: true)).width == 226)

        let statusFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        var statusWidths: Set<CGFloat> = []
        for word in MeetingRecordingPanelController.finalizingStatusWords {
            let size = MeetingRecordingPanelController.pillSize(for: .status(word))
            let text = (word as NSString).size(withAttributes: [.font: statusFont]).width
            // 9 pt lead-in, the 8 pt dot, a 5 pt gap and 11 pt of trailing padding (node 17).
            #expect(size.width >= 9 + 8 + 5 + text + 11)
            #expect(size.height == 22)
            statusWidths.insert(size.width)
        }
        #expect(statusWidths.count == 1)
    }

    /// The regression net for a row narrower than its own parts: AppKit places absolute
    /// frames, so a control that does not fit is silently clipped by the window edge rather
    /// than shrinking the way a flexbox row would.
    @Test("every row control fits inside the row at both widths and on both corners")
    func rowControlsFitInsideTheRow() {
        for content in [MeetingObjectContent.clock(hasHours: false), .clock(hasHours: true)] {
            let size = MeetingRecordingPanelController.size(for: .row, content: content)
            let pillWidth = MeetingRecordingPanelController.pillSize(for: content).width
            for mirrored in [true, false] {
                let row = MeetingRecordingPanelController.rowLayout(
                    in: NSRect(origin: .zero, size: size),
                    pillWidth: pillWidth,
                    mirrored: mirrored
                )
                for part in row.everything {
                    #expect(part.minX >= 0)
                    #expect(part.maxX <= size.width)
                }
                #expect(row.controls.count == 3)
                // The controls' outer edge keeps the same 6 pt inset the pill's own text
                // slot uses, whichever side they unfold on.
                let outerEdge = mirrored
                    ? row.controls.map(\.minX).min()
                    : row.controls.map(\.maxX).max().map { size.width - $0 }
                #expect(outerEdge == MeetingRecordingPanelController.rowEdgeInset)
            }
        }
    }

    /// Covers AE10: dragging saves the *base pill's* center, so a dragged panel minimizes and
    /// reopens on the same corner instead of drifting inward.
    @Test("dragging a panel saves the base pill center, not the panel midpoint")
    func draggingSavesTheBasePillCenter() {
        let pill = MeetingRecordingPanelController.basePillFrame(anchorCenter: nil, screens: [screen])
        let corner = MeetingRecordingPanelController.heldCorner(for: pill, in: screen)
        let panel = MeetingRecordingPanelController.frame(
            for: .panel,
            anchoredTo: pill,
            corner: corner,
            size: MeetingRecordingPanelController.defaultPanelSize,
            screen: screen
        )

        let anchor = MeetingRecordingPanelController.anchorCenter(afterDragging: panel, corner: corner)

        #expect(anchor == CGPoint(x: pill.midX, y: pill.midY))
        #expect(anchor != CGPoint(x: panel.midX, y: panel.midY))

        let reopened = MeetingRecordingPanelController.frame(
            for: .panel,
            anchoredTo: MeetingRecordingPanelController.basePillFrame(anchorCenter: anchor, screens: [screen]),
            corner: corner,
            size: MeetingRecordingPanelController.defaultPanelSize,
            screen: screen
        )
        #expect(reopened == panel)
    }
}

@Suite("Meeting recording panel lifecycle")
@MainActor
struct MeetingRecordingPanelLifecycleTests {
    @Test("stale terminal callbacks cannot close a newer recording")
    func staleOwnerCannotCloseReplacement() {
        var currentTime = Date(timeIntervalSinceReferenceDate: 10_000)
        let controller = makeController(now: { currentTime })
        let firstOwner = UUID()
        let secondOwner = UUID()

        controller.showRecording(
            ownerID: firstOwner,
            startedAt: currentTime,
            powerProvider: { -30 },
            presentation: .backgroundPill
        )
        currentTime.addTimeInterval(5)
        controller.beginFinalizing(ownerID: firstOwner)
        controller.showRecording(
            ownerID: secondOwner,
            startedAt: currentTime,
            powerProvider: { -40 },
            presentation: .backgroundPill
        )

        controller.close(ownerID: firstOwner)

        #expect(controller.activeOwnerIDForTesting == secondOwner)
        #expect(controller.stateForTesting == .recording)
        #expect(controller.isVisible)
        controller.close()
    }

    @Test("pause freezes elapsed time and finalizing disables every control")
    func pauseAndFinalizingState() {
        var currentTime = Date(timeIntervalSinceReferenceDate: 20_000)
        let controller = makeController(now: { currentTime })
        let owner = UUID()
        controller.showRecording(
            ownerID: owner,
            startedAt: currentTime,
            powerProvider: { -25 },
            presentation: .backgroundPill
        )

        currentTime.addTimeInterval(8)
        controller.setPaused(true, ownerID: owner)
        currentTime.addTimeInterval(30)

        #expect(controller.stateForTesting == .paused)
        #expect(controller.elapsedSecondsForTesting == 8)
        #expect(controller.controlsEnabledForTesting)

        controller.beginFinalizing(ownerID: owner, status: "Transcribing")

        #expect(controller.stateForTesting == .finalizing("Transcribing"))
        #expect(!controller.controlsEnabledForTesting)
        #expect(!controller.isPanelOpen)
        controller.close()
    }

    /// Covers AE8: the pill is one button with custom actions; the row is a group whose
    /// buttons carry the labels, in key order.
    @Test("accessibility roles and actions follow the layout")
    func accessibilityFollowsLayout() {
        let now = Date(timeIntervalSinceReferenceDate: 30_000)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )

        #expect(controller.accessibilityRoleForTesting == .button)
        #expect(controller.accessibilityLabelForTesting == "Meeting recording, 00:00, recording")
        #expect(controller.accessibilityCustomActionNamesForTesting == ["Open panel", "Pause", "Stop"])
        #expect(controller.controlAccessibilityLabelsForTesting.isEmpty)

        controller.pointerEntered()

        #expect(controller.accessibilityRoleForTesting == .group)
        #expect(controller.accessibilityCustomActionNamesForTesting.isEmpty)
        #expect(controller.controlAccessibilityLabelsForTesting == [
            "Pause meeting recording",
            "Stop meeting recording",
            "Open meeting panel",
        ])
        controller.close()
    }

    /// Covers R9 and R17: pause, stop and open-panel all no-op while finalizing, so VoiceOver
    /// must not offer them — an announced action that does nothing reads as broken, not
    /// disabled.
    @Test("the finalizing pill offers no custom actions")
    func finalizingPillDropsItsCustomActions() {
        let now = Date(timeIntervalSinceReferenceDate: 31_000)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        let owner = UUID()
        controller.showRecording(
            ownerID: owner,
            startedAt: now,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )

        #expect(controller.accessibilityCustomActionNamesForTesting == ["Open panel", "Pause", "Stop"])

        controller.setPaused(true, ownerID: owner)
        #expect(controller.accessibilityCustomActionNamesForTesting == ["Open panel", "Resume", "Stop"])

        controller.beginFinalizing(ownerID: owner, status: "Summarizing")

        #expect(controller.layoutForTesting == .pill)
        #expect(controller.accessibilityCustomActionNamesForTesting.isEmpty)
        controller.close()
    }

    /// Covers AE1: every size grows from the pill's held corner, and minimizing returns the
    /// exact pill frame it left.
    @Test("hover and the panel keep the pill's held corner")
    func layoutsKeepTheHeldCorner() {
        let now = Date(timeIntervalSinceReferenceDate: 60_000)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )

        guard let pill = controller.frameForTesting else {
            Issue.record("the object never showed")
            return
        }
        let corner = controller.heldCornerForTesting
        #expect(controller.layoutForTesting == .pill)
        #expect(pill.size == MeetingRecordingPanelController.basePillSize)

        controller.pointerEntered()
        guard let row = controller.frameForTesting else { return }
        #expect(controller.layoutForTesting == .row)
        #expect(row.size == MeetingRecordingPanelController.rowSize)
        expectHeldEdges(row, matching: pill, corner: corner)

        controller.toggleTranscriptPanel()
        guard let panel = controller.frameForTesting else { return }
        #expect(controller.layoutForTesting == .panel)
        #expect(panel.size == MeetingRecordingPanelController.defaultPanelSize)
        expectHeldEdges(panel, matching: pill, corner: corner)

        controller.toggleTranscriptPanel()

        #expect(controller.layoutForTesting == .pill)
        #expect(controller.frameForTesting == pill)
        #expect(controller.heldCornerForTesting == corner)
        controller.close()
    }

    /// Covers AE3: the row survives a short exit and a drag, and folds after the full grace.
    @Test("the row folds only after the full hover grace")
    func hoverGraceHoldsTheRow() {
        var currentTime = Date(timeIntervalSinceReferenceDate: 65_000)
        let controller = makeController(now: { currentTime })
        controller.reduceMotionOverrideForTesting = true
        controller.showRecording(
            ownerID: UUID(),
            startedAt: currentTime,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )

        controller.pointerEntered()
        #expect(controller.layoutForTesting == .row)

        controller.pointerExited()
        currentTime.addTimeInterval(0.3)
        controller.fireHoverGraceForTesting()
        #expect(controller.layoutForTesting == .row)

        controller.pointerEntered()
        controller.pointerExited()
        currentTime.addTimeInterval(0.5)
        controller.fireHoverGraceForTesting()
        #expect(controller.layoutForTesting == .pill)

        // A drag holds the row open even after the pointer has left it.
        controller.pointerEntered()
        #expect(controller.layoutForTesting == .row)
        controller.pointerInteractionBegan(at: NSPoint(x: 100, y: 100))
        controller.pointerDragged(to: NSPoint(x: 140, y: 160))
        controller.pointerExited()
        currentTime.addTimeInterval(0.5)
        controller.fireHoverGraceForTesting()
        #expect(controller.layoutForTesting == .row)

        controller.pointerInteractionEnded(didDrag: true)
        currentTime.addTimeInterval(0.5)
        controller.fireHoverGraceForTesting()
        #expect(controller.layoutForTesting == .pill)
        controller.close()
    }

    @Test("hover does nothing while the panel is open and waits for an exit after a minimize")
    func hoverIsSuppressedAfterMinimize() {
        let now = Date(timeIntervalSinceReferenceDate: 70_000)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            presentation: .floatingPanel
        )

        #expect(controller.layoutForTesting == .panel)
        controller.pointerEntered()
        #expect(controller.layoutForTesting == .panel)

        controller.toggleTranscriptPanel()
        #expect(controller.layoutForTesting == .pill)

        // The pointer never moved, so the size the user just dismissed must not reopen.
        controller.pointerEntered()
        #expect(controller.layoutForTesting == .pill)

        controller.pointerExited()
        controller.pointerEntered()
        #expect(controller.layoutForTesting == .row)
        controller.close()
    }

    /// `pointerExited` is the only thing that clears the suppression, and AppKit never fires
    /// it without a prior `mouseEntered`. Suppressing for a fold the pointer was nowhere near
    /// — the status bar's Minimize, a Stop from a notification, auto-stop, the 3 h limit —
    /// therefore killed hover for the rest of the recording.
    @Test("a fold the pointer was never over does not suppress the next hover")
    func hoverSurvivesAFoldFromAcrossTheScreen() {
        let now = Date(timeIntervalSinceReferenceDate: 70_500)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        let owner = UUID()
        controller.showRecording(
            ownerID: owner,
            startedAt: now,
            powerProvider: { -160 },
            presentation: .floatingPanel
        )

        // The status bar's "Minimize Meeting Panel": no pointer ever entered the object.
        #expect(controller.layoutForTesting == .panel)
        controller.toggleTranscriptPanel()
        #expect(controller.layoutForTesting == .pill)

        controller.pointerEntered()
        #expect(controller.layoutForTesting == .row)
        controller.pointerExited()

        // The same for the finalizing fold, which a Stop from anywhere can trigger.
        controller.beginFinalizing(ownerID: owner, status: "Transcribing")
        #expect(controller.layoutForTesting == .pill)

        controller.pointerEntered()
        #expect(controller.layoutForTesting == .row)
        controller.close()
    }

    /// Option-click is a discard *request*, not an escape from the pointer lifecycle: the
    /// press it ends is the only thing holding the row open.
    @Test("an option-click discard still ends the press, so the row can fold")
    func optionClickDiscardEndsThePress() {
        var currentTime = Date(timeIntervalSinceReferenceDate: 71_000)
        let controller = makeController(now: { currentTime })
        controller.reduceMotionOverrideForTesting = true
        let owner = UUID()
        var discarded: [UUID] = []
        controller.onDiscard = { discarded.append($0) }
        controller.showRecording(
            ownerID: owner,
            startedAt: currentTime,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )

        controller.pointerEntered()
        #expect(controller.layoutForTesting == .row)

        controller.pointerInteractionBegan(at: NSPoint(x: 100, y: 100))
        controller.pointerUp(didDrag: false, isDiscardModifier: true)

        #expect(discarded == [owner])

        controller.pointerExited()
        currentTime.addTimeInterval(0.5)
        controller.fireHoverGraceForTesting()

        #expect(controller.layoutForTesting == .pill, "a press left down blocks the fold forever")
        controller.close()
    }

    /// A morph completion that lands after its recording ended must not touch the one that
    /// replaced it. The counter is the guard: a stale completion carries the old value and
    /// returns before clearing `isMorphing` or re-pinning the size limits.
    @Test("close and a new recording retire any morph left in flight")
    func morphCompletionsAreScopedToTheirRecording() {
        let now = Date(timeIntervalSinceReferenceDate: 71_500)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        let first = controller.morphGenerationForTesting

        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )
        let started = controller.morphGenerationForTesting
        #expect(started > first)

        controller.close()
        let closed = controller.morphGenerationForTesting
        #expect(closed > started)

        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )
        #expect(controller.morphGenerationForTesting > closed)
        controller.close()
    }

    /// The body host is deliberately kept alive across minimize and reopen (R12), so SwiftUI
    /// view state could carry an unsent, private question from the meeting that just ended
    /// into the one that replaced it — where it is visible and sendable.
    @Test("an unsent chat draft never survives into the next recording")
    func chatDraftDoesNotSurviveANewRecording() {
        let now = Date(timeIntervalSinceReferenceDate: 72_500)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        let context = FloatingMeetingChatContext(
            meetingID: 31,
            priorTranscript: "",
            currentConfig: { AppConfig() },
            isReady: { true }
        )
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            chatContext: context,
            presentation: .backgroundPill
        )

        controller.toggleTranscriptPanel()
        controller.panelBodyForTesting.selectTab(.chat)
        controller.panelBodyForTesting.model.chatDraft = "is my salary being discussed"

        // A new recording while the previous body host is still alive.
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            chatContext: context,
            presentation: .backgroundPill
        )

        #expect(controller.panelBodyForTesting.model.chatDraft.isEmpty)
        controller.close()
    }

    @Test("open and minimize each write the remembered choice exactly once")
    func panelToggleWritesOncePerDirection() {
        let now = Date(timeIntervalSinceReferenceDate: 75_000)
        var saved: [Bool] = []
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        controller.onPanelOpenSaved = { saved.append($0) }
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )

        controller.pointerEntered()
        controller.toggleTranscriptPanel()
        controller.toggleTranscriptPanel()

        #expect(saved == [true, false])
        #expect(controller.panelOpenSaveCountForTesting == 2)
        controller.close()
    }

    /// Covers R6: Reduce Motion lands the derived frame immediately instead of animating.
    @Test("Reduce Motion lands the derived frame immediately")
    func reduceMotionSkipsTheMorph() {
        let now = Date(timeIntervalSinceReferenceDate: 80_000)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )

        controller.pointerEntered()

        guard let anchor = controller.anchorCenterForTesting else {
            Issue.record("the anchor was never resolved")
            return
        }
        let screens = NSScreen.screens.map(\.visibleFrame)
        let expected = MeetingRecordingPanelController.frame(
            for: .row,
            anchoredTo: MeetingRecordingPanelController.basePillFrame(anchorCenter: anchor, screens: screens),
            corner: controller.heldCornerForTesting,
            size: MeetingRecordingPanelController.rowSize,
            screen: MeetingRecordingPanelController.screenFrame(containing: anchor, screens: screens)
        )
        #expect(controller.frameForTesting == expected)
        controller.close()
    }

    /// Covers AE9: the hour steps the pill and the row once, keeping the held edge.
    @Test("the first hour steps the pill and row widths once")
    func hourStepsTheWidthOnce() {
        var currentTime = Date(timeIntervalSinceReferenceDate: 85_000)
        let controller = makeController(now: { currentTime })
        controller.reduceMotionOverrideForTesting = true
        controller.showRecording(
            ownerID: UUID(),
            startedAt: currentTime,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )
        guard let pill = controller.frameForTesting else { return }
        let corner = controller.heldCornerForTesting

        currentTime.addTimeInterval(3_600)
        controller.tickForTesting()

        guard let widePill = controller.frameForTesting else { return }
        #expect(widePill.size == MeetingRecordingPanelController.widePillSize)
        expectHeldEdges(widePill, matching: pill, corner: corner)

        controller.pointerEntered()
        guard let wideRow = controller.frameForTesting else { return }
        #expect(wideRow.size == MeetingRecordingPanelController.wideRowSize)
        expectHeldEdges(wideRow, matching: pill, corner: corner)

        currentTime.addTimeInterval(60)
        controller.tickForTesting()
        #expect(controller.frameForTesting?.size == MeetingRecordingPanelController.wideRowSize)
        controller.close()
    }

    /// Covers AE6: finalizing folds the panel to a status pill and refuses to reopen.
    @Test("finalizing folds to the status pill and blocks the panel")
    func finalizingFoldsToTheStatusPill() {
        let now = Date(timeIntervalSinceReferenceDate: 90_000)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        let owner = UUID()
        controller.showRecording(
            ownerID: owner,
            startedAt: now,
            powerProvider: { -160 },
            presentation: .floatingPanel
        )
        #expect(controller.layoutForTesting == .panel)

        controller.beginFinalizing(ownerID: owner, status: "Transcribing")

        #expect(controller.layoutForTesting == .pill)
        #expect(!controller.controlsEnabledForTesting)
        #expect(controller.frameForTesting?.width
            == MeetingRecordingPanelController.pillSize(for: .status("Transcribing")).width)
        #expect(controller.accessibilityLabelForTesting?.hasSuffix("transcribing") == true)

        controller.toggleTranscriptPanel()
        #expect(controller.layoutForTesting == .pill)

        controller.updateFinalizingStatus("Summarizing", ownerID: owner)
        #expect(controller.accessibilityLabelForTesting?.hasSuffix("summarizing") == true)

        // Hover still opens the row, with every control disabled.
        controller.pointerExited()
        controller.pointerEntered()
        #expect(controller.layoutForTesting == .row)
        #expect(!controller.controlsEnabledForTesting)
        controller.close()
    }

    /// Covers AE4: a status-bar pause mirrors in the pill and in the row.
    @Test("pause freezes the clock in the pill and swaps the glyph in the row")
    func pauseMirrorsInEverySize() {
        var currentTime = Date(timeIntervalSinceReferenceDate: 95_000)
        let controller = makeController(now: { currentTime })
        controller.reduceMotionOverrideForTesting = true
        let owner = UUID()
        controller.showRecording(
            ownerID: owner,
            startedAt: currentTime,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )

        currentTime.addTimeInterval(9)
        controller.setPaused(true, ownerID: owner)
        currentTime.addTimeInterval(30)

        #expect(controller.layoutForTesting == .pill)
        #expect(controller.elapsedSecondsForTesting == 9)
        #expect(controller.accessibilityLabelForTesting == "Meeting recording, 00:09, paused")

        controller.pointerEntered()
        #expect(controller.controlAccessibilityLabelsForTesting.first == "Resume meeting recording")
        controller.close()
    }

    @Test("state changes announce once and hover announces nothing")
    func announcementsFireOncePerStateChange() {
        var currentTime = Date(timeIntervalSinceReferenceDate: 100_000)
        let controller = makeController(now: { currentTime })
        controller.reduceMotionOverrideForTesting = true
        controller.accessibilitySink = { _ in }
        let owner = UUID()
        controller.showRecording(
            ownerID: owner,
            startedAt: currentTime,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )

        controller.pointerEntered()
        controller.pointerExited()
        currentTime.addTimeInterval(0.5)
        controller.fireHoverGraceForTesting()
        #expect(controller.accessibilityAnnouncementsForTesting.isEmpty)

        controller.setPaused(true, ownerID: owner)
        controller.setPaused(true, ownerID: owner)
        controller.setPaused(false, ownerID: owner)
        controller.toggleTranscriptPanel()
        controller.toggleTranscriptPanel()
        controller.beginFinalizing(ownerID: owner)

        #expect(controller.accessibilityAnnouncementsForTesting == [
            "Meeting recording paused",
            "Meeting recording resumed",
            "Meeting panel opened",
            "Meeting panel minimized",
            "Meeting recording finalizing",
        ])
        controller.close()
    }

    @Test("clicks in the hosted body never reach the drag and discard surface")
    func bodyClicksAreNotTheDragSurface() {
        let now = Date(timeIntervalSinceReferenceDate: 105_000)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            presentation: .floatingPanel
        )
        #expect(controller.layoutForTesting == .panel)

        #expect(controller.hitTargetForTesting(at: NSPoint(x: 180, y: 120)) == .body)
        #expect(controller.hitTargetForTesting(at: NSPoint(x: 60, y: 305)) == .surface)

        guard let pause = controller.controlFramesForTesting["Pause meeting recording"] else {
            Issue.record("the pause control was never laid out")
            return
        }
        #expect(controller.hitTargetForTesting(at: NSPoint(x: pause.midX, y: pause.midY))
            == .control("Pause meeting recording"))
        controller.close()
    }

    @Test("discard carries the owner the object is showing")
    func discardCarriesTheCurrentOwner() {
        let now = Date(timeIntervalSinceReferenceDate: 110_000)
        var discarded: [UUID] = []
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        controller.onDiscard = { discarded.append($0) }
        let first = UUID()
        let second = UUID()

        controller.showRecording(
            ownerID: first,
            startedAt: now,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )
        controller.discardRequested()
        controller.beginFinalizing(ownerID: first)
        // A finalizing object no longer offers discard.
        controller.discardRequested()

        controller.showRecording(
            ownerID: second,
            startedAt: now,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )
        controller.discardRequested()

        #expect(discarded == [first, second])
        controller.close()
    }

    /// Covers AE1: the resting pointer sits over the dot and clock, so they must not move
    /// when the controls unfold — mirrored when the row grows from a trailing corner.
    @Test("the dot and clock keep their place when the row unfolds")
    func rowUnfoldsAwayFromThePill() {
        let now = Date(timeIntervalSinceReferenceDate: 115_000)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )
        let dot = controller.dotOriginForTesting
        let clock = controller.clockOriginForTesting

        controller.pointerEntered()

        #expect(controller.layoutForTesting == .row)
        #expect(controller.dotOriginForTesting == dot)
        #expect(controller.clockOriginForTesting == clock)

        // Every control sits on the far side of the clock, never under the resting pointer.
        let clockX = controller.clockOriginForTesting?.x ?? 0
        for (label, frame) in controller.controlFramesForTesting {
            guard let panelFrame = controller.frameForTesting else { continue }
            let screenMinX = panelFrame.minX + frame.minX
            if controller.heldCornerForTesting.holdsTrailing {
                #expect(screenMinX + frame.width <= clockX, "\(label) unfolded under the pointer")
            } else {
                #expect(screenMinX >= clockX, "\(label) unfolded under the pointer")
            }
        }
        controller.close()
    }

    /// Covers R11 and R17: one Contextual Spark surface in every size, with the radius
    /// morphing 11 → 14 and the accessibility fallbacks resolved by the shared surface.
    @Test("every size wears the Contextual Spark glass")
    func sparkGlassInEverySize() {
        let now = Date(timeIntervalSinceReferenceDate: 130_000)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )

        #expect(controller.surfaceStyleForTesting?.tintHex == DictationMiniPalette.glassTintHex)
        #expect(controller.surfaceStyleForTesting?.cornerRadius == 11)

        controller.pointerEntered()
        #expect(controller.surfaceStyleForTesting?.cornerRadius == 11)

        controller.toggleTranscriptPanel()
        #expect(controller.surfaceStyleForTesting?.cornerRadius == 14)

        let reduceTransparency = ContextualSparkSurfaceStyle.resolve(
            cornerRadius: 14,
            reduceTransparency: true,
            increaseContrast: true
        )
        #expect(!reduceTransparency.usesGlassEffect)
        #expect(reduceTransparency.tintColorAlpha == 1)
        #expect(reduceTransparency.borderWidth == 2)
        controller.close()
    }

    /// Covers AE10: a dragged panel reopens exactly where it was left.
    @Test("a dragged panel minimizes and reopens on the same frame")
    func draggedPanelReopensWhereItWasLeft() {
        let now = Date(timeIntervalSinceReferenceDate: 120_000)
        var savedCenters: [CGPoint] = []
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        controller.onControlCenterSaved = { savedCenters.append($0) }
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            presentation: .floatingPanel
        )
        #expect(controller.layoutForTesting == .panel)

        controller.pointerInteractionBegan(at: NSPoint(x: 600, y: 400))
        controller.pointerDragged(to: NSPoint(x: 400, y: 550))
        controller.pointerInteractionEnded(didDrag: true)

        guard let dragged = controller.frameForTesting else { return }
        let corner = controller.heldCornerForTesting
        #expect(savedCenters.count == 1)
        #expect(savedCenters.first != CGPoint(x: dragged.midX, y: dragged.midY))

        controller.toggleTranscriptPanel()
        #expect(controller.layoutForTesting == .pill)
        controller.toggleTranscriptPanel()

        #expect(controller.layoutForTesting == .panel)
        #expect(controller.frameForTesting == dragged)
        #expect(controller.heldCornerForTesting == corner)
        controller.close()
    }

    @Test("resizing the panel keeps the held corner and re-derives the anchor")
    func resizeKeepsTheHeldCorner() {
        let now = Date(timeIntervalSinceReferenceDate: 125_000)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            presentation: .floatingPanel
        )
        guard let opened = controller.frameForTesting else { return }
        let corner = controller.heldCornerForTesting
        let anchor = controller.anchorCenterForTesting

        controller.endLiveResizeForTesting(to: NSSize(width: 420, height: 380))

        guard let resized = controller.frameForTesting else { return }
        #expect(resized.size == NSSize(width: 420, height: 380))
        expectHeldEdges(resized, matching: opened, corner: corner)
        #expect(controller.heldCornerForTesting == corner)
        // The free edges moved, so the anchor is unchanged and the pill returns where it was.
        #expect(controller.anchorCenterForTesting == anchor)

        controller.toggleTranscriptPanel()
        #expect(controller.frameForTesting?.size == MeetingRecordingPanelController.basePillSize)
        controller.toggleTranscriptPanel()
        #expect(controller.frameForTesting == resized)
        controller.close()
    }

    private func expectHeldEdges(
        _ derived: NSRect,
        matching pill: NSRect,
        corner: MeetingObjectCorner,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        if corner.holdsTrailing {
            #expect(derived.maxX == pill.maxX, sourceLocation: sourceLocation)
        } else {
            #expect(derived.minX == pill.minX, sourceLocation: sourceLocation)
        }
        if corner.holdsTop {
            #expect(derived.maxY == pill.maxY, sourceLocation: sourceLocation)
        } else {
            #expect(derived.minY == pill.minY, sourceLocation: sourceLocation)
        }
    }

    @Test("panel activation preserves the meeting chat and notes context")
    func preservesMeetingContext() {
        let now = Date(timeIntervalSinceReferenceDate: 35_000)
        let controller = makeController(now: { now })
        let context = FloatingMeetingChatContext(
            meetingID: 42,
            priorTranscript: "Earlier transcript",
            currentConfig: { AppConfig() },
            isReady: { true },
            manualNotes: { "Existing notes" },
            saveManualNotes: { _ in }
        )

        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            chatContext: context,
            presentation: .backgroundPill
        )

        #expect(controller.hasMeetingContextForTesting)
        controller.close()
    }

    @Test("dictation presentation changes cannot mutate the meeting panel")
    func dictationPresentationIsIndependent() {
        let now = Date(timeIntervalSinceReferenceDate: 40_000)
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recording-routing-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigStore(supportDirectory: supportDirectory)
        let controller = MeetingRecordingPanelController(configStore: store, now: { now })
        let indicator = DictationMiniIndicatorController(
            screenProvider: {
                [DictationMiniPlacement.Screen(
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                    visibleFrame: CGRect(x: 0, y: 24, width: 800, height: 576)
                )]
            },
            caretAnchorProvider: { CGPoint(x: 300, y: 300) }
        )
        let owner = UUID()
        controller.showRecording(
            ownerID: owner,
            startedAt: now,
            powerProvider: { -35 },
            presentation: .backgroundPill
        )

        let generation = indicator.beginPreparing()
        indicator.showRecording(generation: generation, powerProvider: { -35 })
        indicator.showProcessing(generation: generation)
        indicator.showSuccess(generation: generation, duration: 0.01)
        for _ in 0..<4 {
            #expect(controller.activeOwnerIDForTesting == owner)
            #expect(controller.stateForTesting == .recording)
            #expect(controller.isVisible)
        }

        indicator.close()
        controller.close()
    }

    @Test("an absent choice defers to the start entry point, a remembered one overrides it")
    func rememberedChoiceResolution() {
        // Absent: the entry point decides.
        #expect(MeetingRecordingPanelController.resolvesPanelOpen(
            preferred: nil,
            presentation: .floatingPanel
        ))
        #expect(!MeetingRecordingPanelController.resolvesPanelOpen(
            preferred: nil,
            presentation: .backgroundPill
        ))
        #expect(!MeetingRecordingPanelController.resolvesPanelOpen(
            preferred: nil,
            presentation: .foregroundNotes
        ))

        // Remembered: the last user choice wins for every floating start.
        #expect(!MeetingRecordingPanelController.resolvesPanelOpen(
            preferred: false,
            presentation: .floatingPanel
        ))
        #expect(MeetingRecordingPanelController.resolvesPanelOpen(
            preferred: true,
            presentation: .backgroundPill
        ))

        // A start that opens the meeting document always rests as the pill.
        #expect(!MeetingRecordingPanelController.resolvesPanelOpen(
            preferred: true,
            presentation: .foregroundNotes
        ))
    }

    @Test("a start never writes the remembered panel choice")
    func startDoesNotRememberResolvedChoice() {
        let now = Date(timeIntervalSinceReferenceDate: 45_000)
        let controller = makeController(now: { now })
        let owner = UUID()

        controller.showRecording(
            ownerID: owner,
            startedAt: now,
            powerProvider: { -160 },
            presentation: .floatingPanel
        )

        #expect(controller.resolvedPanelOpenForTesting)
        #expect(controller.preferredPanelOpenForTesting == nil)
        #expect(controller.panelOpenSaveCountForTesting == 0)
        controller.close()
    }

    @Test("a remembered minimize survives a config re-apply and the next start")
    func rememberedMinimizeSurvivesConfigReapply() {
        let now = Date(timeIntervalSinceReferenceDate: 50_000)
        var saved: [Bool] = []
        let controller = makeController(now: { now })
        controller.onPanelOpenSaved = { saved.append($0) }

        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            presentation: .floatingPanel
        )
        controller.toggleTranscriptPanel()

        #expect(saved == [false])
        #expect(controller.lastSavedPanelOpenForTesting == false)
        #expect(controller.preferredPanelOpenForTesting == false)

        // A config apply that has not yet observed the write must not resurrect
        // the old preference for the running meeting.
        controller.applyConfiguration(AppConfig())
        var persisted = AppConfig()
        persisted.meetingPanelOpen = false
        controller.applyConfiguration(persisted)
        controller.close()

        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            presentation: .floatingPanel
        )

        #expect(!controller.resolvedPanelOpenForTesting)
        #expect(saved == [false])
        controller.close()
    }

    @Test("finalizing, discard and close never write the remembered panel choice")
    func terminalTransitionsDoNotRememberPanelChoice() {
        let now = Date(timeIntervalSinceReferenceDate: 55_000)
        var config = AppConfig()
        config.meetingPanelOpen = true
        var saved: [Bool] = []
        var discardCount = 0
        let controller = makeController(now: { now }, configuration: config)
        controller.onPanelOpenSaved = { saved.append($0) }
        controller.onDiscard = { _ in discardCount += 1 }
        let owner = UUID()

        controller.showRecording(
            ownerID: owner,
            startedAt: now,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )

        #expect(controller.resolvedPanelOpenForTesting)

        controller.discardRequested()
        controller.beginFinalizing(ownerID: owner)
        controller.close(ownerID: owner)

        #expect(discardCount == 1)
        #expect(saved.isEmpty)
        #expect(controller.panelOpenSaveCountForTesting == 0)
        #expect(controller.preferredPanelOpenForTesting == true)
    }

    @Test("the transcript reaches the body while the object is still a pill")
    func transcriptFeedsTheBodyWithoutOpeningThePanel() {
        // The panel must open onto a transcript that is already there, so the feed keeps
        // arriving into the model in every size — without that ever forcing the panel open.
        let now = Date(timeIntervalSinceReferenceDate: 60_000)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )

        controller.updateMeetingTranscript(
            transcript: "[10:00:00] You: spoken while minimized",
            partialYou: "still talking",
            partialOthers: ""
        )

        #expect(controller.layoutForTesting == .pill)
        #expect(!controller.isPanelOpen)
        #expect(controller.panelBodyForTesting.model.presentation.transcript.contains("spoken while minimized"))
        #expect(controller.panelBodyForTesting.model.presentation.partialYou == "still talking")
        controller.close()
    }

    @Test("the body's content survives open, minimize and reopen within one recording")
    func bodyContentSurvivesTheFold() {
        let now = Date(timeIntervalSinceReferenceDate: 61_000)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        var cachedNotes = "carried across"
        let context = FloatingMeetingChatContext(
            meetingID: 91,
            priorTranscript: "Earlier half",
            currentConfig: { AppConfig() },
            isReady: { true },
            manualNotes: { cachedNotes },
            saveManualNotes: { cachedNotes = $0 }
        )
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            chatContext: context,
            presentation: .backgroundPill
        )
        controller.updateMeetingTranscript(
            transcript: "[10:00:00] You: before the fold",
            partialYou: "",
            partialOthers: ""
        )

        controller.toggleTranscriptPanel()
        #expect(controller.isPanelOpen)
        #expect(controller.isPanelBodyHostedForTesting)
        controller.panelBodyForTesting.selectTab(.notes)
        controller.panelBodyForTesting.model.notesEdited("typed in the panel")

        controller.toggleTranscriptPanel()
        #expect(!controller.isPanelOpen)
        controller.toggleTranscriptPanel()

        let model = controller.panelBodyForTesting.model
        #expect(controller.isPanelOpen)
        // R12: the tab the user was working in is part of what survives the fold.
        #expect(model.selectedTab == .notes)
        #expect(controller.panelBodyForTesting.isOutsideClickMonitorArmedForTesting)
        #expect(model.presentation.transcript.contains("before the fold"))
        #expect(model.notesDraft == "typed in the panel")
        #expect(model.chatContext?.meetingID == 91)
        #expect(controller.hasMeetingContextForTesting)
        controller.close()
    }

    @Test("a minimize from chat reopens on chat with its context intact")
    func chatTabSurvivesTheFold() {
        let now = Date(timeIntervalSinceReferenceDate: 61_500)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            chatContext: FloatingMeetingChatContext(
                meetingID: 77,
                priorTranscript: "Earlier half",
                currentConfig: { AppConfig() },
                isReady: { true }
            ),
            presentation: .backgroundPill
        )

        controller.toggleTranscriptPanel()
        controller.panelBodyForTesting.selectTab(.chat)
        controller.toggleTranscriptPanel()

        #expect(!controller.isPanelOpen)
        #expect(controller.panelBodyForTesting.isChatOpen, "minimizing is not leaving chat")

        controller.toggleTranscriptPanel()

        #expect(controller.isPanelOpen)
        #expect(controller.panelBodyForTesting.isChatOpen)
        #expect(controller.panelBodyForTesting.model.chatContext?.meetingID == 77)
        #expect(controller.panelBodyForTesting.isOutsideClickMonitorArmedForTesting)
        controller.close()
    }

    /// Covers R13: focus is handed back before the body disappears, so no invisible window
    /// is left holding keystrokes meant for the call — while R12's surviving tab is left
    /// alone, because a fold is not the user leaving Chat or My notes.
    @Test("minimizing and finalizing release focus before the body folds away")
    func foldingReleasesFocusFirst() {
        let now = Date(timeIntervalSinceReferenceDate: 62_000)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        let owner = UUID()
        controller.showRecording(
            ownerID: owner,
            startedAt: now,
            powerProvider: { -160 },
            chatContext: FloatingMeetingChatContext(
                meetingID: 92,
                priorTranscript: "",
                currentConfig: { AppConfig() },
                isReady: { true }
            ),
            presentation: .backgroundPill
        )
        controller.updateMeetingTranscript(
            transcript: "[10:00:00] You: said before finalizing",
            partialYou: "",
            partialOthers: ""
        )

        controller.toggleTranscriptPanel()
        controller.panelBodyForTesting.selectTab(.chat)
        #expect(controller.panelBodyForTesting.isChatOpen)

        controller.toggleTranscriptPanel()

        // The keyboard is handed back and nothing is left listening, but the tab stands.
        #expect(!controller.panelBodyForTesting.isOutsideClickMonitorArmedForTesting)
        #expect(controller.panelBodyForTesting.isChatOpen)

        controller.toggleTranscriptPanel()
        controller.panelBodyForTesting.selectTab(.notes)
        controller.beginFinalizing(ownerID: owner, status: "Summarizing")

        #expect(controller.layoutForTesting == .pill)
        #expect(!controller.panelBodyForTesting.isOutsideClickMonitorArmedForTesting)
        // The fold is not the end of the meeting: what was captured stays readable until
        // the recording is saved and the object closes, and so does the tab it was on.
        #expect(controller.panelBodyForTesting.model.selectedTab == .notes)
        #expect(controller.panelBodyForTesting.model.presentation.transcript.contains("said before finalizing"))
        #expect(controller.hasMeetingContextForTesting)

        controller.close(ownerID: owner)
        #expect(!controller.hasMeetingContextForTesting)
    }

    @Test("the status bar reads the panel size, not a separate transcript window")
    func statusBarTitleFollowsTheLayout() {
        let now = Date(timeIntervalSinceReferenceDate: 63_000)
        let controller = makeController(now: { now })
        controller.reduceMotionOverrideForTesting = true
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            presentation: .backgroundPill
        )

        #expect(!controller.isPanelOpen, "pill: the item offers Open Meeting Panel")

        controller.toggleTranscriptPanel()
        #expect(controller.isPanelOpen, "panel: the item offers Minimize Meeting Panel")

        controller.toggleTranscriptPanel()
        #expect(!controller.isPanelOpen)
        controller.close()
    }

    private func makeController(
        now: @escaping () -> Date,
        configuration: AppConfig? = nil
    ) -> MeetingRecordingPanelController {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recording-panel-\(UUID().uuidString)", isDirectory: true)
        return MeetingRecordingPanelController(
            configStore: ConfigStore(supportDirectory: supportDirectory),
            configuration: configuration,
            now: now
        )
    }
}
