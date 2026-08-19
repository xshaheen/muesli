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
            presentation: .backgroundPill
        )

        #expect(controller.controlAccessibilityLabelsForTesting == [
            "Show live transcript",
            "Pause meeting recording",
            "Stop meeting recording",
        ])
        controller.close()
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
        controller.onDiscard = { discardCount += 1 }
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
