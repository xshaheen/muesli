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
            size: MeetingRecordingPanelController.panelSize,
            screens: [screen]
        )
        let second = MeetingRecordingPanelController.resolvedFrame(
            savedCenter: nil,
            size: MeetingRecordingPanelController.panelSize,
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
            size: MeetingRecordingPanelController.panelSize,
            screens: [screen]
        )

        #expect(frame.midX == center.x)
        #expect(frame.midY == center.y)
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
            showTranscript: false
        )
        currentTime.addTimeInterval(5)
        controller.beginFinalizing(ownerID: firstOwner)
        controller.showRecording(
            ownerID: secondOwner,
            startedAt: currentTime,
            powerProvider: { -40 },
            showTranscript: false
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
            showTranscript: false
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
        #expect(!controller.isTranscriptPanelVisible)
        controller.close()
    }

    @Test("compact controls expose explicit accessible actions")
    func accessibleControls() {
        let now = Date(timeIntervalSinceReferenceDate: 30_000)
        let controller = makeController(now: { now })
        controller.showRecording(
            ownerID: UUID(),
            startedAt: now,
            powerProvider: { -160 },
            showTranscript: false
        )

        #expect(controller.controlAccessibilityLabelsForTesting == [
            "Show live transcript",
            "Pause meeting recording",
            "Stop meeting recording",
        ])
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
            pointerProvider: { CGPoint(x: 300, y: 300) }
        )
        let owner = UUID()
        controller.showRecording(
            ownerID: owner,
            startedAt: now,
            powerProvider: { -35 },
            showTranscript: false
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

    private func makeController(now: @escaping () -> Date) -> MeetingRecordingPanelController {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recording-panel-\(UUID().uuidString)", isDirectory: true)
        return MeetingRecordingPanelController(
            configStore: ConfigStore(supportDirectory: supportDirectory),
            now: now
        )
    }
}
