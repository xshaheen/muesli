import Testing
import AppKit
@testable import MuesliNativeApp

@Suite("Floating indicator anchor restore")
@MainActor
struct FloatingIndicatorAnchorRestoreTests {
    private let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
    private let collapsed = NSSize(width: 44, height: 28)
    private let expanded = NSSize(width: 220, height: 36)

    private func anchor(_ center: CGPoint) -> CGPoint {
        FloatingIndicatorController.clampedAnchorCenter(center, in: screen, size: collapsed)
    }

    @Test("the anchor is defined against the collapsed pill")
    func anchorSizeIsTheCollapsedPill() {
        // Every restore and save clamps against this one size, which is what makes the
        // resolved anchor independent of the state that happens to ask first.
        #expect(FloatingIndicatorController.idleIndicatorSize == collapsed)
    }

    @Test("a centre the pill already fits around is taken verbatim")
    func onScreenCentreSurvivesUntouched() {
        let saved = CGPoint(x: 700, y: 450)

        #expect(anchor(saved) == saved)
    }

    @Test("an edge-saved centre is nudged in, not replaced by the default")
    func edgeCentreIsClampedNotDiscarded() {
        // The pill was parked at the bottom-right. The old policy vetoed it -- the fit
        // test insets by half the *expanded* pill -- and wrote the mid-trailing default
        // over it, every launch, because the config was never rewritten.
        let saved = CGPoint(x: 1_400, y: 10)
        #expect(!FloatingIndicatorController.isUsableIndicatorCenter(saved, in: screen, size: expanded))

        let resolved = anchor(saved)

        #expect(resolved.x == 1_400, "horizontal intent is kept")
        #expect(resolved.y == 14, "nudged just inside the collapsed pill's reach")
        #expect(resolved != FloatingIndicatorController.defaultIndicatorCenter(in: screen))
    }

    @Test("the restored anchor does not depend on which state resolves first")
    func restoreIsIndependentOfPillSize() {
        // Same saved centre, two answers under the size-dependent fit test -- which is
        // what made the veto a coin flip per launch. Clamping against the collapsed pill
        // gives it one answer.
        let saved = CGPoint(x: 1_400, y: 500)
        #expect(FloatingIndicatorController.isUsableIndicatorCenter(saved, in: screen, size: collapsed))
        #expect(!FloatingIndicatorController.isUsableIndicatorCenter(saved, in: screen, size: expanded))

        #expect(anchor(saved) == saved)
    }

    @Test("a kept anchor still yields an on-screen frame in a wide state")
    func wideStateStillClampsOnScreen() {
        let resolved = anchor(CGPoint(x: 1_400, y: 10))

        let wide = FloatingIndicatorController.clampedIndicatorFrame(
            center: resolved,
            size: NSSize(width: 720, height: 32),
            in: screen
        )

        #expect(wide.maxX <= screen.maxX)
        #expect(wide.minY >= screen.minY)
    }

    @Test("a pill larger than its display centres instead of inverting")
    func oversizedPillCentres() {
        let small = NSRect(x: 0, y: 0, width: 100, height: 60)

        let resolved = FloatingIndicatorController.clampedAnchorCenter(
            CGPoint(x: 5_000, y: -5_000),
            in: small,
            size: NSSize(width: 400, height: 200)
        )

        #expect(resolved == CGPoint(x: small.midX, y: small.midY))
    }
}

@Suite("Floating indicator drag")
@MainActor
struct FloatingIndicatorDragTests {
    private let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
    private let collapsed = NSSize(width: 44, height: 28)

    @Test("meeting pill clicks map to pause, panel toggle, and stop by region")
    func meetingPillClickMapping() {
        typealias C = FloatingIndicatorController
        let panelRegion: ClosedRange<CGFloat> = 57...81

        // No location: the pill's historical default is stop.
        #expect(C.meetingRecordingPillAction(clickX: nil, pauseRegionMaxX: 30, panelToggleRegion: panelRegion) == .stop)
        #expect(C.meetingRecordingPillAction(clickX: 10, pauseRegionMaxX: 30, panelToggleRegion: panelRegion) == .togglePause)
        // The waveform strip between pause and the toggle still stops, as it always has.
        #expect(C.meetingRecordingPillAction(clickX: 45, pauseRegionMaxX: 30, panelToggleRegion: panelRegion) == .stop)
        #expect(C.meetingRecordingPillAction(clickX: 69, pauseRegionMaxX: 30, panelToggleRegion: panelRegion) == .togglePanel)
        #expect(C.meetingRecordingPillAction(clickX: 90, pauseRegionMaxX: 30, panelToggleRegion: panelRegion) == .stop)
        // Without the glyph laid out there is no toggle region, and the middle stays stop.
        #expect(C.meetingRecordingPillAction(clickX: 69, pauseRegionMaxX: 30, panelToggleRegion: nil) == .stop)
    }

    @Test("an unclamped pill saves the anchor where it was dropped")
    func unclampedDragSavesTheDropPoint() {
        // Nothing was clamped, so anchor and pill centre started together -- and the
        // collapse displacement that keeps the grab under the pointer has to come along,
        // or the pill snaps back after the drop.
        let start = CGPoint(x: 700, y: 450)

        let saved = FloatingIndicatorController.draggedAnchorCenter(
            anchorAtDragStart: start,
            pillCenterAtDragStart: start,
            pillCenterAtDrop: CGPoint(x: 788, y: 470)
        )

        #expect(saved == CGPoint(x: 788, y: 470))
    }

    @Test("a nudge in a clamped state moves the anchor by the nudge")
    func clampedNudgeMovesAnchorByDelta() {
        // A collapsed pill parked against the right edge, nudged 5pt while transcribing.
        // The wide pill is clamped ~340pt inward, so adopting its centre would migrate
        // the anchor there permanently.
        let anchorAtDragStart = CGPoint(x: 1_418, y: 450)
        let wideFrame = FloatingIndicatorController.clampedIndicatorFrame(
            center: anchorAtDragStart,
            size: NSSize(width: 720, height: 32),
            in: screen
        )
        let pillCentre = CGPoint(x: wideFrame.midX, y: wideFrame.midY)
        let drop = CGPoint(x: pillCentre.x + 5, y: pillCentre.y)

        let moved = FloatingIndicatorController.draggedAnchorCenter(
            anchorAtDragStart: anchorAtDragStart,
            pillCenterAtDragStart: pillCentre,
            pillCenterAtDrop: drop
        )
        let saved = FloatingIndicatorController.clampedAnchorCenter(moved, in: screen, size: collapsed)

        #expect(moved.x == 1_423)
        #expect(saved.x == 1_418, "still at the edge it was nudged along")
        #expect(saved.x != drop.x, "the clamped centre is not the anchor")
    }

    @Test("an edge-parked expanded pill saves against the collapsed pill, not the clamp")
    func expandedEdgeDragSavesAgainstTheCollapsedPill() {
        // Hover expands the idle pill to 220pt, and at this anchor the expansion is
        // clamped 88pt inward. The collapse undoes that clamp before the drag starts, so
        // the drag has to be measured from where the collapse left the pill. Measuring
        // from the pre-collapse centre counts the clamp a second time.
        let anchorAtDragStart = CGPoint(x: 1_418, y: 450)
        let expanded = FloatingIndicatorController.clampedIndicatorFrame(
            center: anchorAtDragStart,
            size: NSSize(width: 220, height: 36),
            in: screen
        )
        #expect(expanded.midX == 1_330, "the expansion cannot sit around its anchor here")

        // Grabbed at the expanded pill's leading edge, so the collapse leaves the
        // collapsed pill's leading edge under the pointer.
        let grab = CGPoint(x: expanded.minX, y: expanded.midY)
        let collapsedOrigin = FloatingIndicatorController.collapsedDragOrigin(
            pillFrame: expanded,
            collapsedSize: collapsed,
            grabPoint: grab
        )
        let collapsedCentre = CGPoint(
            x: collapsedOrigin.x + collapsed.width / 2,
            y: collapsedOrigin.y + collapsed.height / 2
        )
        #expect(collapsedCentre.x == 1_242)

        let drop = CGPoint(x: 1_251, y: collapsedCentre.y)
        let moved = FloatingIndicatorController.draggedAnchorCenter(
            anchorAtDragStart: anchorAtDragStart,
            pillCenterAtDragStart: collapsedCentre,
            pillCenterAtDrop: drop
        )
        let saved = FloatingIndicatorController.clampedAnchorCenter(moved, in: screen, size: collapsed)

        #expect(moved.x == 1_427, "the anchor moves by the 9pt the collapsed pill moved")
        #expect(saved.x == 1_418, "a 9pt nudge leaves the pill on the edge it was parked on")

        // What the pre-collapse centre would have saved instead: a 79pt migration inward
        // for a drag that moved the pill 9pt out.
        let fromExpandedCentre = FloatingIndicatorController.draggedAnchorCenter(
            anchorAtDragStart: anchorAtDragStart,
            pillCenterAtDragStart: CGPoint(x: expanded.midX, y: expanded.midY),
            pillCenterAtDrop: drop
        )
        #expect(fromExpandedCentre.x == 1_339)
    }

    @Test("collapsing a pill that keeps its size leaves the origin alone")
    func collapseIsIdentityForUnchangedSize() {
        let pill = NSRect(x: 300, y: 400, width: 76, height: 22)

        let origin = FloatingIndicatorController.collapsedDragOrigin(
            pillFrame: pill,
            collapsedSize: pill.size,
            grabPoint: CGPoint(x: 340, y: 410)
        )

        #expect(abs(origin.x - pill.minX) < 0.001)
        #expect(abs(origin.y - pill.minY) < 0.001)
    }

    @Test("a drag that keeps the centre on a display is left alone")
    func draggedOriginOnScreenIsUntouched() {
        let origin = NSPoint(x: 100, y: 100)

        #expect(
            FloatingIndicatorController.clampedDragOrigin(
                origin,
                size: collapsed,
                screens: [screen]
            ) == origin
        )
    }

    @Test("a pill dropped in the gap between displays returns to the nearer one")
    func draggedOriginSnapsOutOfDisplayGap() {
        let left = screen
        let right = NSRect(x: 1_600, y: 0, width: 1_440, height: 900)
        // Centre at 1480: 40pt past the left display, 120pt short of the right one.
        let inGap = NSPoint(x: 1_480 - collapsed.width / 2, y: 400)

        let clamped = FloatingIndicatorController.clampedDragOrigin(
            inGap,
            size: collapsed,
            screens: [left, right]
        )

        #expect(clamped.x + collapsed.width / 2 == left.maxX)
        #expect(clamped.y == inGap.y)
    }

    @Test("a pill dragged past the last display stays reachable")
    func draggedOriginStaysOnScreen() {
        let clamped = FloatingIndicatorController.clampedDragOrigin(
            NSPoint(x: 4_000, y: -900),
            size: collapsed,
            screens: [screen]
        )

        #expect(clamped.x + collapsed.width / 2 == screen.maxX)
        #expect(clamped.y + collapsed.height / 2 == screen.minY)
    }

    @Test("with no displays to clamp against the origin is returned as-is")
    func draggedOriginWithoutScreens() {
        let origin = NSPoint(x: 12, y: 34)

        #expect(FloatingIndicatorController.clampedDragOrigin(origin, size: collapsed, screens: []) == origin)
    }
}
