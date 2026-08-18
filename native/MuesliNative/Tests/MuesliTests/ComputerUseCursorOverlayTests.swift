import AppKit
import Testing
@testable import MuesliNativeApp

@MainActor
@Suite("Computer-use cursor overlay", .serialized)
struct ComputerUseCursorOverlayTests {
    @Test("cursor geometry converts Quartz coordinates and clamps on a secondary display")
    func secondaryDisplayGeometry() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1_440, height: 900),
            CGRect(x: -1_280, y: 0, width: 1_280, height: 800),
        ]
        let visible = [
            CGRect(x: 0, y: 24, width: 1_440, height: 852),
            CGRect(x: -1_280, y: 0, width: 1_280, height: 776),
        ]

        let frame = ComputerUseCursorOverlay.cursorFrame(
            forQuartzPoint: CGPoint(x: -1_270, y: 890),
            size: CGSize(width: 120, height: 30),
            offsetFromTarget: true,
            screens: screens,
            visibleFrames: visible
        )

        #expect(frame.minX == visible[1].minX)
        #expect(frame.minY == visible[1].minY)
        #expect(frame.maxX <= visible[1].maxX)
    }

    @Test("surface geometry remains reachable when wider than a display")
    func oversizedSurfaceGeometry() {
        let visible = CGRect(x: -200, y: 40, width: 100, height: 80)
        let frame = ComputerUseCursorOverlay.surfaceFrame(
            near: CGPoint(x: -150, y: 70),
            size: CGSize(width: 180, height: 32),
            visibleFrames: [visible]
        )

        #expect(frame.minX == visible.minX)
        #expect(frame.minY >= visible.minY)
    }

    @Test("temporary target presentation restores the recording lifecycle")
    func targetRestoresRecording() {
        let overlay = ComputerUseCursorOverlay.shared
        overlay.showRecording { -20 }
        #expect(overlay.presentation == .recording)

        overlay.showTarget(at: CGPoint(x: 100, y: 100), label: "Click")
        #expect(overlay.presentation == .target("Click"))

        overlay.hideTarget()
        #expect(overlay.presentation == .recording)

        overlay.hide()
        #expect(overlay.presentation == .hidden)
    }

    @Test("a newer status invalidates an older terminal dismissal")
    func terminalGenerationSafety() async {
        let overlay = ComputerUseCursorOverlay.shared
        overlay.showTerminal("Failed", kind: .failure, duration: 0.01)
        overlay.showStatus("Retrying")
        try? await Task.sleep(for: .milliseconds(30))

        #expect(overlay.presentation == .status("Retrying"))
        overlay.hide()
    }
}
