import AppKit
import Testing
@testable import MuesliNativeApp

@MainActor
@Suite("Meeting Record button", .serialized)
struct MeetingRecordButtonTests {
    @Test("the presentation hands the spot to the object, and only a pill start shows Starting…")
    func presentationPolicy() {
        func presentation(
            enabled: Bool = true,
            monitorsAllowed: Bool = true,
            candidate: Bool = true,
            dismissed: Bool = false,
            recording: Bool = false,
            starting: Bool = false,
            fromPill: Bool = false,
            panelVisible: Bool = false
        ) -> MeetingRecordButtonPresentation {
            MeetingRecordButtonPolicy.presentation(
                enabled: enabled,
                monitorsAllowed: monitorsAllowed,
                hasActivityCandidate: candidate,
                candidateDismissed: dismissed,
                isRecording: recording,
                isStartingRecording: starting,
                startOriginatedFromPill: fromPill,
                isRecordingPanelVisible: panelVisible
            )
        }
        #expect(presentation() == .record)
        #expect(presentation(enabled: false) == .hidden)
        #expect(presentation(monitorsAllowed: false) == .hidden)
        #expect(presentation(candidate: false) == .hidden)
        #expect(presentation(dismissed: true) == .hidden)
        #expect(presentation(recording: true) == .hidden)
        // A start the pill did not launch has nothing to hold: the entry point owns its own chrome.
        #expect(presentation(starting: true) == .hidden)
        #expect(presentation(starting: true, fromPill: true) == .starting)
        // The merged object owns the spot whenever it is on screen, finalizing included.
        #expect(presentation(panelVisible: true) == .hidden)
        #expect(presentation(recording: true, panelVisible: true) == .hidden)
        #expect(presentation(starting: true, fromPill: true, panelVisible: true) == .hidden)
    }

    @Test("a failed pill start restores the pill only while the detector still reports that meeting")
    func restoreAfterFailedStart() {
        func restores(started: String?, detector: String?) -> Bool {
            MeetingRecordButtonPolicy.restoresCandidateAfterFailedStart(
                startedCandidateID: started,
                detectorCandidateID: detector
            )
        }
        #expect(restores(started: "zoom-1", detector: "zoom-1"))
        #expect(!restores(started: "zoom-1", detector: nil))
        #expect(!restores(started: "zoom-1", detector: "meet-2"))
        #expect(!restores(started: nil, detector: "zoom-1"))
        #expect(!restores(started: nil, detector: nil))
    }

    @Test("Starting… keeps the pill's frame, ignores every pointer path, and hands back to Record")
    func startingHandOff() {
        let controller = MeetingRecordButtonController()
        var recorded = 0
        var dismissed = 0
        var savedCenter: CGPoint?
        controller.onRecord = { recorded += 1 }
        controller.onDismiss = { dismissed += 1 }
        controller.onCenterSaved = { savedCenter = $0 }
        controller.applySavedCenter(CGPoint(x: 400, y: 300))

        controller.apply(.record, platformName: "Zoom")
        let recordFrame = controller.frameForTesting
        #expect(recordFrame != nil)

        controller.apply(.starting, platformName: "Zoom")
        #expect(controller.isVisible)
        #expect(controller.frameForTesting == recordFrame)
        #expect(controller.labelTextForTesting == "Starting…")
        #expect(controller.accessibilityLabelForTesting == "Starting meeting recording")

        controller.setHovered(true)
        controller.pointerInteractionBegan(at: CGPoint(x: 400, y: 300))
        controller.pointerDragged(to: CGPoint(x: 480, y: 380))
        controller.pointerInteractionEnded(didDrag: false)
        controller.dismissRequested()
        #expect(recorded == 0)
        #expect(dismissed == 0)
        #expect(savedCenter == nil)
        #expect(!controller.isHoveredForTesting)
        #expect(controller.frameForTesting == recordFrame)

        // The object taking the spot must never rewrite the shared saved center.
        controller.apply(.hidden, platformName: "Zoom")
        #expect(!controller.isVisible)
        #expect(savedCenter == nil)

        controller.apply(.record, platformName: "Zoom")
        #expect(controller.frameForTesting == recordFrame)
        #expect(controller.labelTextForTesting == "Record")
        #expect(controller.accessibilityLabelForTesting == "Record Zoom meeting")
        controller.pointerInteractionBegan(at: CGPoint(x: 400, y: 300))
        controller.pointerInteractionEnded(didDrag: false)
        #expect(recorded == 1)
        controller.close()
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

        controller.apply(.record, platformName: "Zoom")
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
