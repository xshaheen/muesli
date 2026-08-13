import Testing
import AppKit
@testable import MuesliNativeApp

@Suite("Floating meeting transcript placement")
struct FloatingMeetingTranscriptPlacementTests {
    private let wideScreen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
    private let gap = FloatingMeetingTranscriptPlacement.gap
    private let inset = FloatingMeetingTranscriptPlacement.screenInset
    private let panelSize = FloatingMeetingTranscriptPlacement.panelSize

    @Test("the initial panel placement keeps a tight visual connection to the pill")
    func panelConnectionGap() {
        #expect(gap == 4)
    }

    private func pill(x: CGFloat, y: CGFloat = 440) -> NSRect {
        NSRect(x: x, y: y, width: 76, height: 22)
    }

    private func placement(
        beside indicator: NSRect,
        in visibleFrame: NSRect,
        preferring side: FloatingMeetingTranscriptPlacement.Side? = nil
    ) -> FloatingMeetingTranscriptPlacement.Placement {
        FloatingMeetingTranscriptPlacement.placement(
            beside: indicator,
            visibleFrame: visibleFrame,
            preferredSide: side
        )
    }

    @Test("a pill with room on both sides is placed left, one against an edge on the open side")
    func ordinaryPlacement() {
        let cases: [(indicator: NSRect, side: FloatingMeetingTranscriptPlacement.Side)] = [
            (pill(x: 1_350), .left),
            (pill(x: 14), .right),
            (pill(x: 700), .left),
        ]

        for (indicator, expected) in cases {
            let placed = placement(beside: indicator, in: wideScreen)

            #expect(placed.side == expected)
            #expect(wideScreen.insetBy(dx: inset, dy: inset).contains(placed.frame))
            #expect(!placed.frame.intersects(indicator))
            if expected == .left {
                #expect(placed.frame.maxX == indicator.minX - gap)
            } else {
                #expect(placed.frame.minX == indicator.maxX + gap)
            }
        }
    }

    @Test("the panel holds its side while the pill drifts across the fit threshold")
    func sideIsStickyAcrossSmallPillMovements() {
        // The panel is 360pt wide, so crossing the threshold relocates it by more than
        // its own width. A pill that drifts a few points must not be able to do that.
        // Start two points shy of the width the left side needs, so the panel starts right.
        let required = panelSize.width + gap + inset
        let held = placement(beside: pill(x: required - 2), in: wideScreen)
        #expect(held.side == .right, "no room on the left, so the first placement is on the right")

        for x in stride(from: required + 2, through: required + 22, by: 5) {
            let drifted = pill(x: x)
            let sticky = placement(beside: drifted, in: wideScreen, preferring: held.side)

            #expect(sticky.side == .right)
            #expect(sticky.frame.minX == drifted.maxX + gap)
            // Same input without the memory is what the panel used to do: jump.
            #expect(placement(beside: drifted, in: wideScreen).side == .left)
        }
    }

    @Test("the panel flips only once the side it holds stops fitting")
    func sideFlipsWhenItNoLongerFits() {
        let required = panelSize.width + gap + inset
        let stillFits = pill(x: wideScreen.maxX - required - 76)
        let tooTight = pill(x: wideScreen.maxX - required - 76 + 1)

        #expect(placement(beside: stillFits, in: wideScreen, preferring: .right).side == .right)

        let flipped = placement(beside: tooTight, in: wideScreen, preferring: .right)

        #expect(flipped.side == .left)
        #expect(flipped.frame.maxX == tooTight.minX - gap)
    }

    @Test("a screen too narrow for either side moves the panel clear of the pill")
    func narrowScreenKeepsThePillVisible() {
        // Traced from the review: on a 700pt display the clamp used to slide the panel
        // (8..368) straight over the pill (320..396), burying the only control the user
        // has during a call.
        let narrow = NSRect(x: 0, y: 0, width: 700, height: 800)
        let indicator = pill(x: 320, y: 400)

        let placed = placement(beside: indicator, in: narrow)

        #expect(!placed.frame.intersects(indicator))
        #expect(placed.frame.maxY == indicator.minY - gap, "room below, so it goes below")
        #expect(narrow.insetBy(dx: inset, dy: inset).contains(placed.frame))
    }

    @Test("with no room below, the panel clears the pill upwards")
    func narrowScreenGoesAboveWhenBelowIsFull() {
        let narrow = NSRect(x: 0, y: 0, width: 700, height: 800)
        let indicator = pill(x: 320, y: 20)

        let placed = placement(beside: indicator, in: narrow)

        #expect(!placed.frame.intersects(indicator))
        #expect(placed.frame.minY == indicator.maxY + gap)
        #expect(narrow.insetBy(dx: inset, dy: inset).contains(placed.frame))
    }

    @Test("a screen too narrow for either side still keeps the side it holds")
    func narrowScreenHoldsItsSide() {
        let narrow = NSRect(x: 0, y: 0, width: 700, height: 800)
        let indicator = pill(x: 320, y: 400)

        for side in [FloatingMeetingTranscriptPlacement.Side.left, .right] {
            let placed = placement(beside: indicator, in: narrow, preferring: side)

            #expect(placed.side == side)
            #expect(!placed.frame.intersects(indicator))
        }
    }

    @Test("the panel remembers its side across hides and forgets it on reset")
    @MainActor
    func controllerRemembersSideUntilReset() {
        let controller = FloatingMeetingTranscriptPanelController(
            onOpenNotes: {},
            onDismiss: {}
        )

        controller.show(beside: pill(x: 300), in: wideScreen)
        #expect(controller.placementSide == .right)

        controller.hide()
        // A pill that has drifted somewhere the left now fits: the side survives the hide.
        controller.show(beside: pill(x: 400), in: wideScreen)
        #expect(controller.placementSide == .right)

        controller.reset()
        #expect(controller.placementSide == nil)

        controller.show(beside: pill(x: 400), in: wideScreen)
        #expect(controller.placementSide == .left, "a fresh session places without memory")
    }

    @Test("the panel is resizable without resetting its size after a hide")
    @MainActor
    func controllerRetainsUserSizeAcrossHideAndShow() {
        let controller = FloatingMeetingTranscriptPanelController(
            onOpenNotes: {},
            onDismiss: {}
        )
        controller.show(beside: pill(x: 700), in: wideScreen)

        guard let panel = controller.presentationWindow else {
            Issue.record("expected the transcript panel to create its presentation window")
            return
        }
        #expect(panel.styleMask.contains(.resizable))
        #expect(panel.contentMinSize == FloatingMeetingTranscriptPlacement.minimumPanelSize)

        let resizedSize = NSSize(width: 560, height: 480)
        panel.setFrame(NSRect(origin: panel.frame.origin, size: resizedSize), display: false)
        controller.hide()
        controller.show(beside: pill(x: 700), in: wideScreen)

        #expect(controller.presentationWindow?.frame.size == resizedSize)

        controller.reset()
        controller.show(beside: pill(x: 700), in: wideScreen)

        #expect(controller.presentationWindow?.frame.size == resizedSize)
        controller.close()
    }
}
