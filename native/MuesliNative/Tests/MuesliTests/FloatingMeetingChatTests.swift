import Testing
import AppKit
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Floating panel chat")
@MainActor
struct FloatingMeetingChatTests {
    // MARK: - Focus discipline

    @Test("the panel wants no keyboard focus until chat is deliberately opened")
    func noFocusUntilChatOpens() {
        // The failure this prevents: a floating panel that takes key focus during a call
        // swallows keystrokes meant for Zoom or Teams.
        let model = FloatingMeetingTranscriptModel()
        model.chatContext = FloatingMeetingChatContext(meetingID: 1, priorTranscript: "", currentConfig: { AppConfig() }, isReady: { true })

        #expect(model.isChatOpen == false)

        model.openChat()
        #expect(model.isChatOpen)

        model.closeChat()
        #expect(model.isChatOpen == false)
    }

    @Test("chat cannot open without a meeting context")
    func chatCannotOpenWithoutContext() {
        let model = FloatingMeetingTranscriptModel()
        model.chatContext = nil

        model.openChat()

        #expect(model.isChatOpen == false)
        #expect(model.isChatAvailable == false)
    }

    @Test("chat stays unavailable when the backend is not ready")
    func unreadyBackendHidesChat() {
        // The detail view hides its Chat tab when credentials are missing; the panel must
        // agree, or it offers a control whose every send fails.
        let model = FloatingMeetingTranscriptModel()
        model.chatContext = FloatingMeetingChatContext(
            meetingID: 1,
            priorTranscript: "",
            currentConfig: { AppConfig() },
            isReady: { false }
        )

        model.openChat()

        #expect(model.isChatAvailable == false)
        #expect(model.isChatOpen == false)
    }

    @Test("config is resolved at send time, not captured when recording starts")
    func configResolvesLate() {
        // Changing backend or credentials mid-meeting must reach panel chat the same way it
        // reaches the detail view.
        var current = AppConfig()
        current.meetingSummaryBackend = "ollama"

        let context = FloatingMeetingChatContext(
            meetingID: 1,
            priorTranscript: "",
            currentConfig: { current },
            isReady: { true }
        )

        #expect(context.currentConfig().meetingSummaryBackend == "ollama")
        current.meetingSummaryBackend = "openrouter"
        #expect(context.currentConfig().meetingSummaryBackend == "openrouter")
    }

    @Test("resetting the panel closes chat and drops its context")
    func resetClosesChat() {
        let model = FloatingMeetingTranscriptModel()
        model.chatContext = FloatingMeetingChatContext(meetingID: 1, priorTranscript: "x", currentConfig: { AppConfig() }, isReady: { true })
        model.openChat()

        model.reset()

        #expect(model.isChatOpen == false)
        #expect(model.chatContext == nil)
    }

    // MARK: - Notes tab

    @Test("notes are available with a meeting even when chat's backend is not ready")
    func notesAvailableWithoutBackend() {
        // Notes are the user's own text: they need a meeting, not credentials.
        let model = FloatingMeetingTranscriptModel()
        model.chatContext = FloatingMeetingChatContext(
            meetingID: 1,
            priorTranscript: "",
            currentConfig: { AppConfig() },
            isReady: { false }
        )

        #expect(model.isChatAvailable == false)
        #expect(model.isNotesAvailable)
        #expect(model.openNotes())
        #expect(model.selectedTab == .notes)
    }

    @Test("notes cannot open without a meeting context")
    func notesNeedContext() {
        let model = FloatingMeetingTranscriptModel()

        #expect(model.openNotes() == false)
        #expect(model.selectedTab == .transcript)
    }

    @Test("opening notes reads the shared cache and edits write through")
    func notesLoadAndWriteThrough() {
        // The closure pair models the controller's live cache: writes land in it
        // synchronously, reads always see the latest value from either editor.
        var cache = "existing notes"
        var saved: [String] = []
        let model = FloatingMeetingTranscriptModel()
        model.chatContext = FloatingMeetingChatContext(
            meetingID: 1,
            priorTranscript: "",
            currentConfig: { AppConfig() },
            isReady: { false },
            manualNotes: { cache },
            saveManualNotes: { cache = $0; saved.append($0) }
        )

        #expect(model.openNotes())
        #expect(model.notesDraft == "existing notes")

        model.notesEdited("existing notes + more")
        #expect(saved == ["existing notes + more"])

        // An edit made in the main window while this tab was away appears on
        // re-open — the reload is what keeps the two editors converged.
        model.selectedTab = .transcript
        cache = "edited in the main window"
        #expect(model.openNotes())
        #expect(model.notesDraft == "edited in the main window")
    }

    @Test("reset returns to the transcript tab and clears the notes draft")
    func resetClearsNotes() {
        let model = FloatingMeetingTranscriptModel()
        model.chatContext = FloatingMeetingChatContext(
            meetingID: 1,
            priorTranscript: "",
            currentConfig: { AppConfig() },
            isReady: { false },
            manualNotes: { "loaded" }
        )
        _ = model.openNotes()
        model.notesEdited("draft")

        model.reset()

        #expect(model.selectedTab == .transcript)
        #expect(model.notesDraft.isEmpty)
    }

    // MARK: - Transcript parity

    @Test("panel chat combines the prior transcript with the live one")
    func panelCombinesPriorAndLive() {
        // Same regression as the detail view: the panel is fed only the current session's
        // transcript, so a resumed meeting would otherwise lose everything before the resume.
        let model = FloatingMeetingTranscriptModel()
        model.chatContext = FloatingMeetingChatContext(
            meetingID: 1,
            priorTranscript: "[09:00:00] You: before the resume",
            currentConfig: { AppConfig() },
            isReady: { true }
        )
        model.update(
            transcript: "[10:00:00] You: after the resume",
            partialYou: "",
            partialOthers: ""
        )

        #expect(model.chatTranscript.contains("before the resume"))
        #expect(model.chatTranscript.contains("after the resume"))
    }

    @Test("panel chat transcript matches the detail view's combination")
    func panelMatchesDetailViewCombination() {
        let prior = "[09:00:00] You: earlier"
        let live = "[10:00:00] You: now"

        let model = FloatingMeetingTranscriptModel()
        model.chatContext = FloatingMeetingChatContext(meetingID: 1, priorTranscript: prior, currentConfig: { AppConfig() }, isReady: { true })
        model.update(transcript: live, partialYou: "", partialOthers: "")

        #expect(model.chatTranscript == MeetingResumePolicy.combinedResumeTranscript(prior: prior, new: live))
    }

    @Test("the panel and the recording detail tab ask over identical input")
    func panelAndRecordingTabAgree() {
        // Both surfaces route through MeetingChatSource so the same question cannot get a
        // different answer depending on whether it was asked from the pill or the window.
        // The combination used to be written out separately in each, which is exactly how
        // they would drift.
        let prior = "[09:00:00] You: earlier"
        let live = "[10:00:00] You: now"
        let record = MeetingRecord(
            id: 1,
            title: "Test",
            startTime: "2026-07-31T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: prior,
            formattedNotes: "",
            wordCount: 0,
            folderID: nil
        )

        let model = FloatingMeetingTranscriptModel()
        model.chatContext = FloatingMeetingChatContext(
            meetingID: 1,
            priorTranscript: prior,
            currentConfig: { AppConfig() },
            isReady: { true }
        )
        model.update(transcript: live, partialYou: "", partialOthers: "")

        let detailTranscript = MeetingChatSource.transcript(for: record, live: live, isRecording: true)

        #expect(model.chatTranscript == detailTranscript)
        #expect(MeetingChatSource.systemPrompt(isRecording: true) == MeetingChatPrompts.live)
    }

    @Test("a fresh meeting with no prior transcript reads the live one")
    func freshMeetingReadsLive() {
        let model = FloatingMeetingTranscriptModel()
        model.chatContext = FloatingMeetingChatContext(meetingID: 1, priorTranscript: "", currentConfig: { AppConfig() }, isReady: { true })
        model.update(transcript: "[10:00:00] You: hello", partialYou: "", partialOthers: "")

        #expect(model.chatTranscript.contains("hello"))
    }

    @Test("chat's has-transcript gate tracks live chunks, prior transcript, and reset")
    func chatHasTranscriptGate() {
        // The chat tab's body gates on this flag instead of the growing transcript,
        // so it must agree with the transcript's emptiness at every stage — a gate
        // stuck false leaves the composer disabled while text is plainly visible.
        let model = FloatingMeetingTranscriptModel()
        model.chatContext = FloatingMeetingChatContext(meetingID: 1, priorTranscript: "", currentConfig: { AppConfig() }, isReady: { true })
        #expect(!model.chatHasTranscript)

        model.update(transcript: "[10:00:00] You: hello", partialYou: "", partialOthers: "")
        #expect(model.chatHasTranscript)

        model.reset()
        #expect(!model.presentation.hasContent)

        // A resumed meeting has something to ask about before any new speech.
        model.chatContext = FloatingMeetingChatContext(meetingID: 1, priorTranscript: "[09:00:00] You: earlier", currentConfig: { AppConfig() }, isReady: { true })
        #expect(model.chatHasTranscript)
    }

    // MARK: - Cross-surface continuity

    @Test("a question asked in the panel is visible in the detail tab")
    func panelAndTabShareConversation() async {
        let registry = MeetingChatConversations()
        let fromPanel = registry.conversation(for: 7777)
        await fromPanel.send(
            displayText: "asked from the floating panel",
            transcript: "T",
            systemPrompt: MeetingChatPrompts.live,
            config: AppConfig(),
            send: { _, _ in "answered" }
        )

        let fromTab = registry.conversation(for: 7777)
        #expect(fromTab.turns.count == 2)
        #expect(fromTab.turns.first?.displayText == "asked from the floating panel")

    }
}
