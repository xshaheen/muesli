import Testing
import AppKit
import MuesliCore
@testable import MuesliNativeApp

@Suite("Meeting panel body coordinator")
@MainActor
struct MeetingPanelBodyCoordinatorTests {
    private func readyContext(meetingID: Int64 = 1, notes: String = "") -> FloatingMeetingChatContext {
        FloatingMeetingChatContext(
            meetingID: meetingID,
            priorTranscript: "",
            currentConfig: { AppConfig() },
            isReady: { true },
            manualNotes: { notes }
        )
    }

    @Test("the body wants no keyboard focus until a typing tab is selected")
    func focusFollowsTheSelectedTab() {
        // A floating object that takes focus during a call swallows the keystrokes the
        // user is typing into Zoom, so only Chat and My notes may want the keyboard.
        let coordinator = MeetingPanelBodyCoordinator()
        coordinator.setChatContext(readyContext())

        #expect(!coordinator.wantsKeyboardFocus)

        coordinator.selectTab(.notes)
        #expect(coordinator.wantsKeyboardFocus)

        coordinator.selectTab(.transcript)
        #expect(!coordinator.wantsKeyboardFocus)
    }

    /// Covers AE5: an outside click hands the keyboard back from My notes and closes Chat,
    /// and the panel stays open either way.
    @Test("a typing tab arms outside-click dismissal and leaving it disarms")
    func typingTabsArmTheOutsideClickMonitor() {
        let coordinator = MeetingPanelBodyCoordinator()
        coordinator.setChatContext(readyContext())

        #expect(!coordinator.isOutsideClickMonitorArmedForTesting)

        coordinator.selectTab(.notes)
        #expect(coordinator.isOutsideClickMonitorArmedForTesting)

        coordinator.selectTab(.chat)
        #expect(coordinator.isChatOpen)
        #expect(coordinator.isOutsideClickMonitorArmedForTesting)

        coordinator.selectTab(.transcript)
        #expect(!coordinator.isChatOpen)
        #expect(!coordinator.isOutsideClickMonitorArmedForTesting)

        coordinator.teardown()
    }

    @Test("chat without a usable backend leaves no monitor running")
    func unreadyChatNeverArmsTheMonitor() {
        // Every teardown path is reached through the open tab, so arming for a tab that
        // never opened would leave a global event monitor nothing tears down.
        let coordinator = MeetingPanelBodyCoordinator()
        coordinator.setChatContext(
            FloatingMeetingChatContext(
                meetingID: 1,
                priorTranscript: "",
                currentConfig: { AppConfig() },
                isReady: { false }
            )
        )

        coordinator.selectTab(.chat)

        #expect(!coordinator.isChatOpen)
        #expect(!coordinator.isOutsideClickMonitorArmedForTesting)
    }

    /// R12 vs R13: releasing focus is not leaving the tab. Minimizing hands the keyboard
    /// back, but the user was working in Chat or My notes and must land there on reopen.
    @Test("releasing focus hands the keyboard back without changing the tab")
    func releaseFocusKeepsTheSelectedTab() {
        let coordinator = MeetingPanelBodyCoordinator()
        coordinator.setChatContext(readyContext())

        for tab in [FloatingMeetingPanelTab.chat, .notes] {
            coordinator.selectTab(tab)
            #expect(coordinator.isOutsideClickMonitorArmedForTesting)

            coordinator.releaseFocus()

            #expect(coordinator.model.selectedTab == tab)
            #expect(!coordinator.isOutsideClickMonitorArmedForTesting)
        }

        // Only choosing the Transcript tab returns the body to it.
        coordinator.selectTab(.transcript)
        #expect(coordinator.model.selectedTab == .transcript)
        #expect(!coordinator.wantsKeyboardFocus)
        coordinator.teardown()
    }

    @Test("a typing tab that survived a fold re-arms its outside-click rule on reopen")
    func resumingFocusRulesRearmsTheMonitor() {
        // Without this the panel comes back on Chat or My notes with nothing watching for
        // the click that should hand the keyboard back.
        let coordinator = MeetingPanelBodyCoordinator()
        coordinator.setChatContext(readyContext())
        coordinator.selectTab(.notes)
        coordinator.releaseFocus()

        coordinator.resumeFocusRules()

        #expect(coordinator.model.selectedTab == .notes)
        #expect(coordinator.isOutsideClickMonitorArmedForTesting)

        coordinator.selectTab(.transcript)
        coordinator.resumeFocusRules()

        #expect(!coordinator.isOutsideClickMonitorArmedForTesting, "the transcript never arms it")
        coordinator.teardown()
    }

    /// Covers AE5: an outside click closes Chat but only hands the keyboard back from
    /// My notes, and neither closes the panel.
    @Test("an outside click closes chat but leaves my notes selected")
    func outsideClickSplitsChatFromNotes() {
        let coordinator = MeetingPanelBodyCoordinator()
        coordinator.setChatContext(readyContext())

        coordinator.selectTab(.chat)
        coordinator.handleOutsideClickForTesting()

        #expect(coordinator.model.selectedTab == .transcript)
        #expect(!coordinator.isOutsideClickMonitorArmedForTesting)

        coordinator.selectTab(.notes)
        coordinator.model.notesEdited("half a thought")
        coordinator.handleOutsideClickForTesting()

        #expect(coordinator.model.selectedTab == .notes, "the user is glancing at the call")
        #expect(coordinator.model.notesDraft == "half a thought")
        #expect(coordinator.isOutsideClickMonitorArmedForTesting, "still watching for the next click")
        coordinator.teardown()
    }

    @Test("losing the meeting context drops the body back to the transcript")
    func clearingContextClosesTypingTabs() {
        let coordinator = MeetingPanelBodyCoordinator()
        coordinator.setChatContext(readyContext())
        coordinator.selectTab(.notes)

        coordinator.setChatContext(nil)

        #expect(coordinator.model.selectedTab == .transcript)
        #expect(!coordinator.hasMeetingContextForTesting)
        #expect(!coordinator.isOutsideClickMonitorArmedForTesting)
    }

    @Test("the notes draft reloads from the shared cache every time the tab opens")
    func notesDraftReloadsOnOpen() {
        // The main window may have edited the same manual notes while this tab was away.
        var cached = "written in the main window"
        let coordinator = MeetingPanelBodyCoordinator()
        coordinator.setChatContext(
            FloatingMeetingChatContext(
                meetingID: 7,
                priorTranscript: "",
                currentConfig: { AppConfig() },
                isReady: { true },
                manualNotes: { cached },
                saveManualNotes: { cached = $0 }
            )
        )

        coordinator.selectTab(.notes)
        #expect(coordinator.model.notesDraft == "written in the main window")

        coordinator.model.notesEdited("typed in the panel")
        #expect(cached == "typed in the panel")

        coordinator.selectTab(.transcript)
        cached = "changed again elsewhere"
        coordinator.selectTab(.notes)

        #expect(coordinator.model.notesDraft == "changed again elsewhere")
        coordinator.teardown()
    }

    @Test("copy takes the visible tab's payload, not always the transcript")
    func copyFollowsTheVisibleTab() {
        let coordinator = MeetingPanelBodyCoordinator()
        coordinator.setChatContext(readyContext(meetingID: 11))
        coordinator.update(
            transcript: "[10:00:00] You: spoken line",
            partialYou: "",
            partialOthers: ""
        )

        coordinator.model.copyToPasteboard()
        #expect(NSPasteboard.general.string(forType: .string)?.contains("spoken line") == true)

        coordinator.selectTab(.notes)
        coordinator.model.notesEdited("only in my notes")
        coordinator.model.copyToPasteboard()

        #expect(NSPasteboard.general.string(forType: .string) == "only in my notes")
        coordinator.teardown()
    }
}
