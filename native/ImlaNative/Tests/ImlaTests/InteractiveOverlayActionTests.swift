import CoreGraphics
import Testing
@testable import ImlaNativeApp

/// Replaces the coverage that left with upstream's single-indicator click test.
/// This fork routes Stop and Cancel through the computer-use overlay instead, so
/// what needs pinning is which interaction a click reaches and where the two
/// controls sit.
@Suite("Computer use overlay actions")
struct InteractiveOverlayActionTests {
    @Test("stop ends the running session, with a toggle outranking a held one")
    func stopPrecedence() {
        #expect(
            InteractiveOverlayActionPolicy.stopAction(
                for: .init(computerUseToggleRecording: true, quilToggleRecording: true, quilInFlight: true)
            ) == .stopComputerUseToggle
        )
        #expect(
            InteractiveOverlayActionPolicy.stopAction(
                for: .init(quilToggleRecording: true, quilInFlight: true)
            ) == .stopQuilToggle
        )
        #expect(
            InteractiveOverlayActionPolicy.stopAction(for: .init(quilInFlight: true)) == .stopQuil
        )
        #expect(InteractiveOverlayActionPolicy.stopAction(for: .init()) == .stopComputerUse)
    }

    /// A captured selection is a live Quill session even before the user has
    /// spoken, so cancel must discard it rather than stopping computer use.
    @Test("cancel belongs to Quill while any part of its session is live")
    func cancelPrecedence() {
        #expect(
            InteractiveOverlayActionPolicy.cancelAction(for: .init(quilToggleRecording: true)) == .cancelQuil
        )
        #expect(InteractiveOverlayActionPolicy.cancelAction(for: .init(quilInFlight: true)) == .cancelQuil)
        #expect(
            InteractiveOverlayActionPolicy.cancelAction(for: .init(quilSelectionPending: true)) == .cancelQuil
        )
        #expect(
            InteractiveOverlayActionPolicy.cancelAction(
                for: .init(computerUseToggleRecording: true)
            ) == .cancelComputerUse
        )
        #expect(InteractiveOverlayActionPolicy.cancelAction(for: .init()) == .cancelComputerUse)
    }

    /// The overlay follows the executor's cursor, so the controls are pinned to
    /// its trailing edge and a click anywhere else must do nothing at all.
    @MainActor
    @Test("stop and cancel keep fixed-width targets at the overlay's trailing edge")
    func clickZones() {
        let width: CGFloat = 200
        #expect(ComputerUseCursorOverlay.clickZone(atX: 199, width: width) == .stop)
        #expect(ComputerUseCursorOverlay.clickZone(atX: 166, width: width) == .stop)
        #expect(ComputerUseCursorOverlay.clickZone(atX: 165, width: width) == .cancel)
        #expect(ComputerUseCursorOverlay.clickZone(atX: 132, width: width) == .cancel)
        #expect(ComputerUseCursorOverlay.clickZone(atX: 131, width: width) == .none)
        #expect(ComputerUseCursorOverlay.clickZone(atX: 0, width: width) == .none)
    }
}
