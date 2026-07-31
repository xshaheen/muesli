import Testing
import AppKit
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Floating panel chat")
@MainActor
struct FloatingMeetingChatTests {
    private let panel = NSRect(x: 0, y: 0, width: 360, height: 300)

    private func point(fromRight offset: CGFloat, inHeader: Bool = true) -> NSPoint {
        NSPoint(x: panel.maxX - offset, y: inHeader ? panel.maxY - 10 : panel.minY + 10)
    }

    // MARK: - Hit regions

    @Test("the chat toggle has its own header region")
    func chatToggleHasItsOwnRegion() {
        let action = FloatingMeetingTranscriptInteraction.action(at: point(fromRight: 100), in: panel)

        #expect(action == .toggleChat)
    }

    @Test("existing header regions still resolve unchanged")
    func existingRegionsUnchanged() {
        // Regression guard: the new region is carved out of the header without shifting the
        // controls that were already there.
        #expect(FloatingMeetingTranscriptInteraction.action(at: point(fromRight: 20), in: panel) == .copy)
        #expect(FloatingMeetingTranscriptInteraction.action(at: point(fromRight: 60), in: panel) == .dismiss)
        #expect(FloatingMeetingTranscriptInteraction.action(at: point(fromRight: 200), in: panel) == .openMeeting)
    }

    @Test("points outside the panel resolve to nothing")
    func outsidePanelIsNil() {
        #expect(FloatingMeetingTranscriptInteraction.action(at: NSPoint(x: -10, y: 10), in: panel) == nil)
        #expect(FloatingMeetingTranscriptInteraction.action(at: NSPoint(x: 1_000, y: 10), in: panel) == nil)
    }

    @Test("points below the header resolve to nothing")
    func belowHeaderIsNil() {
        #expect(FloatingMeetingTranscriptInteraction.action(at: point(fromRight: 100, inHeader: false), in: panel) == nil)
    }

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

    @Test("a fresh meeting with no prior transcript reads the live one")
    func freshMeetingReadsLive() {
        let model = FloatingMeetingTranscriptModel()
        model.chatContext = FloatingMeetingChatContext(meetingID: 1, priorTranscript: "", currentConfig: { AppConfig() }, isReady: { true })
        model.update(transcript: "[10:00:00] You: hello", partialYou: "", partialOthers: "")

        #expect(model.chatTranscript.contains("hello"))
    }

    // MARK: - Cross-surface continuity

    @Test("a question asked in the panel is visible in the detail tab")
    func panelAndTabShareConversation() async {
        let registry = MeetingChatConversations.shared
        registry.forget(meetingID: 7777)

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

        registry.forget(meetingID: 7777)
    }
}
