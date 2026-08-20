import AppKit
import Observation
import SwiftUI

struct FloatingMeetingChatContext {
    let meetingID: Int64
    /// Transcript captured before the current recording session began. Empty for a fresh
    /// meeting; non-empty after a resume, where `liveMeetingTranscript` holds only the new
    /// portion.
    let priorTranscript: String
    /// Resolved when the panel sends, not captured, so changing backend or credentials
    /// mid-meeting takes effect here as it does in the detail view.
    let currentConfig: () -> AppConfig
    /// Whether the selected backend is actually usable. The detail view hides its Chat tab
    /// when this is false; the panel must agree, or it offers a control that always fails.
    let isReady: () -> Bool
    /// Resolved per send, like the config, because the user types notes during the
    /// meeting and the panel must see what they have written by the time they ask.
    var manualNotes: () -> String = { "" }
    /// Routes a Notes-tab edit into the same cache-then-persist path the main
    /// window's notes editor uses, so the two editors converge on one value.
    var saveManualNotes: (String) -> Void = { _ in }
}

/// What the panel body is showing. Chat and Notes both need a meeting
/// context; Chat additionally needs a usable summarization backend.
enum FloatingMeetingPanelTab: Equatable {
    case transcript
    case chat
    case notes
}

@MainActor
@Observable
final class FloatingMeetingTranscriptModel {
    let presentation = LiveTranscriptPresentationModel()
    var isPaused = false
    var isPresented = false
    var didCopy = false
    /// Coral, not the user's theme accent: the merged object is drawn in the Contextual
    /// Spark palette, which owns its own selection colour.
    var selectionAccentHex = DictationMiniPalette.accentHex

    /// The panel opens on the transcript; Chat and Notes are deliberate choices.
    /// Keyboard focus is gated on the selected tab: on the transcript the window
    /// must never become key, or it would swallow keystrokes meant for the
    /// meeting app the user is actually talking in.
    var selectedTab: FloatingMeetingPanelTab = .transcript
    var chatContext: FloatingMeetingChatContext?

    /// The Notes draft mirrors the shared manual-notes cache: reloaded every
    /// time the tab opens, written through on every edit. The cache is updated
    /// synchronously by every notes editor, so a tab-open read is never stale —
    /// and reloading each open is what reconciles an edit made in the main
    /// window while this tab was away.
    var notesDraft = ""

    /// The unsent chat question. It lives here rather than in the body's SwiftUI state
    /// because the hosting view survives minimize and reopen for the whole recording, and
    /// `@State` in a view that is never torn down cannot be cleared when a new meeting
    /// starts — the previous meeting's private draft would show up, and be sendable, in
    /// the next one.
    var chatDraft = ""

    var isChatOpen: Bool { selectedTab == .chat }
    var isChatAvailable: Bool { chatContext?.isReady() == true }
    /// Notes need a meeting, not a backend — they are the user's own text.
    var isNotesAvailable: Bool { chatContext != nil }

    /// The transcript chat reasons over: what was recorded before this session plus what has
    /// been captured since. Mirrors the detail view's Live tab; using the live portion alone
    /// would drop a resumed meeting's earlier half.
    var chatTranscript: String {
        MeetingChatSource.liveTranscript(
            prior: chatContext?.priorTranscript ?? "",
            live: presentation.transcript
        )
    }

    /// What the chat tab's body gates on. Reads `hasContent`, not the transcript
    /// itself: a body read of the growing transcript re-rendered the chat surface on
    /// every chunk — the panel's chat-tab flicker — while this flips at most once.
    var chatHasTranscript: Bool {
        if let prior = chatContext?.priorTranscript,
           !prior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return presentation.hasContent
    }

    func openChat() {
        guard isChatAvailable else { return }
        selectedTab = .chat
    }

    func closeChat() {
        if selectedTab == .chat { selectedTab = .transcript }
    }

    func toggleChat() {
        isChatOpen ? closeChat() : openChat()
    }

    /// Selects the Notes tab, reloading the draft from the shared cache so an
    /// edit made in the main window while this tab was away is what appears
    /// here. Returns false when there is no meeting to attach notes to.
    @discardableResult
    func openNotes() -> Bool {
        guard let chatContext else { return false }
        notesDraft = chatContext.manualNotes()
        selectedTab = .notes
        return true
    }

    /// Write-through: every edit lands in the shared manual-notes cache, whose
    /// debounced persistence the controller already owns.
    func notesEdited(_ text: String) {
        notesDraft = text
        chatContext?.saveManualNotes(text)
    }

    func update(transcript: String, partialYou: String, partialOthers: String) {
        presentation.update(
            transcript: transcript,
            partialYou: partialYou,
            partialOthers: partialOthers
        )
    }

    func setSelectionAccentHex(_ hex: Int) {
        selectionAccentHex = hex
    }

    /// Copies whatever the panel is currently showing.
    ///
    /// The tab strip's button is the only copy affordance the panel has, so it must
    /// copy the visible tab. Copying the transcript while chat or notes is open
    /// gives the user something they were not looking at, silently.
    func copyToPasteboard() {
        let text: String
        switch selectedTab {
        case .chat where chatContext != nil:
            text = MeetingChatConversations.shared
                .conversation(for: chatContext!.meetingID)
                .transcriptForCopying()
        case .notes:
            text = notesDraft
        default:
            text = LiveTranscriptCopyContent.text(
                transcript: presentation.transcript,
                partialYou: presentation.partialYou,
                partialOthers: presentation.partialOthers
            )
        }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopyConfirmation()
    }

    func reset() {
        presentation.reset()
        isPaused = false
        isPresented = false
        didCopy = false
        selectedTab = .transcript
        chatContext = nil
        notesDraft = ""
        chatDraft = ""
    }

    func showCopyConfirmation() {
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.didCopy = false
        }
    }
}

/// A hosting view that answers the first click, so a body control works without first
/// activating the app — the object floats over a call the user is still focused on.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
