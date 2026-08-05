import Testing
import AppKit
@testable import MuesliNativeApp

@Suite("Floating indicator placement")
@MainActor
struct FloatingIndicatorPlacementTests {
    private let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
    private let collapsed = NSSize(width: 44, height: 22)
    private let expanded = NSSize(width: 220, height: 22)

    private func frame(center: CGPoint, size: NSSize) -> NSRect {
        FloatingIndicatorController.clampedIndicatorFrame(center: center, size: size, in: screen)
    }

    @Test("a pill away from the edges centres on its anchor")
    func centresOnAnchor() {
        let placed = frame(center: CGPoint(x: 700, y: 450), size: collapsed)

        #expect(placed.midX == 700)
        #expect(placed.midY == 450)
    }

    @Test("expanding then collapsing returns a corner pill to where it started")
    func collapseReturnsToAnchorInCorner() {
        // The regression: expanding near an edge clamps the frame on-screen, so the
        // expanded pill's real centre is not its anchor. Deriving the next size from
        // that centre walked the pill inward on every hover.
        let anchor = CGPoint(x: 24, y: 20)

        let before = frame(center: anchor, size: collapsed)
        let whileExpanded = frame(center: anchor, size: expanded)
        let after = frame(center: anchor, size: collapsed)

        #expect(whileExpanded.midX != anchor.x, "expanding in a corner should clamp")
        #expect(after == before)
    }

    @Test("a clamped frame stays fully on screen")
    func clampKeepsPillOnScreen() {
        for center in [CGPoint(x: -500, y: -500), CGPoint(x: 5_000, y: 5_000)] {
            let placed = frame(center: center, size: expanded)

            #expect(placed.minX >= screen.minX)
            #expect(placed.minY >= screen.minY)
            #expect(placed.maxX <= screen.maxX)
            #expect(placed.maxY <= screen.maxY)
        }
    }

    @Test("every size resolved from one anchor shares that anchor when it fits")
    func sizesAgreeAwayFromEdges() {
        let anchor = CGPoint(x: 700, y: 450)

        for size in [collapsed, expanded, NSSize(width: 76, height: 22)] {
            #expect(frame(center: anchor, size: size).midX == anchor.x)
        }
    }
}
