import AppKit
import Testing
@testable import MuesliNativeApp

@MainActor
@Suite("Meeting Record button", .serialized)
struct MeetingRecordButtonTests {
    @Test("the pill shows only for an active, undismissed meeting candidate outside a recording")
    func visibilityPolicy() {
        func show(
            enabled: Bool = true,
            monitorsAllowed: Bool = true,
            candidate: Bool = true,
            dismissed: Bool = false,
            recording: Bool = false,
            starting: Bool = false
        ) -> Bool {
            MeetingRecordButtonPolicy.shouldShow(
                enabled: enabled,
                monitorsAllowed: monitorsAllowed,
                hasActivityCandidate: candidate,
                candidateDismissed: dismissed,
                isRecording: recording,
                isStartingRecording: starting
            )
        }
        #expect(show())
        #expect(!show(enabled: false))
        #expect(!show(monitorsAllowed: false))
        #expect(!show(candidate: false))
        #expect(!show(dismissed: true))
        #expect(!show(recording: true))
        #expect(!show(starting: true))
    }

    @Test("the pill shares the Contextual Spark palette and a compact footprint")
    func palette() {
        #expect(MeetingRecordButtonController.pillSize == NSSize(width: 72, height: 22))
        #expect(MeetingRecordButtonController.recordDotDiameter == 8)
        #expect(MeetingRecordButtonController.pillSize.height == DictationMiniIndicatorController.surfaceSize(for: .recording).height)
        #expect(MeetingRecordButtonPalette.glassTintHex == DictationMiniPalette.glassTintHex)
        #expect(MeetingRecordButtonPalette.recordHex == 0xFF7043)
        #expect(MeetingRecordButtonPalette.recordHighlightHex == 0xFFB04D)
        #expect(MeetingRecordButtonPalette.glassTintAlpha == 0.62)
        #expect(MeetingRecordButtonPalette.hoverGlassTintAlpha < MeetingRecordButtonPalette.glassTintAlpha)
    }

    @Test("showing names the platform, a click records, a drag saves the shared center, and hide withdraws")
    func lifecycle() {
        let controller = MeetingRecordButtonController()
        var recorded = 0
        var savedCenter: CGPoint?
        controller.onRecord = { recorded += 1 }
        controller.onCenterSaved = { savedCenter = $0 }
        controller.applySavedCenter(CGPoint(x: 400, y: 300))

        controller.show(platformName: "Zoom")
        #expect(controller.isVisible)
        #expect(controller.accessibilityLabelForTesting == "Record Zoom meeting")

        controller.pointerInteractionBegan(at: CGPoint(x: 400, y: 300))
        controller.pointerInteractionEnded(didDrag: false)
        #expect(recorded == 1)

        controller.pointerInteractionBegan(at: CGPoint(x: 400, y: 300))
        controller.pointerDragged(to: CGPoint(x: 420, y: 330))
        controller.pointerInteractionEnded(didDrag: true)
        #expect(recorded == 1)
        #expect(savedCenter != nil)

        controller.hide()
        #expect(!controller.isVisible)
        controller.close()
    }
}
