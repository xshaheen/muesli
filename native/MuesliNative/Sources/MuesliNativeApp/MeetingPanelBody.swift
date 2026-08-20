import SwiftUI

/// The merged panel's body: the 28 pt tab strip and the live feed, chat or notes editor
/// under it.
///
/// It draws no glass and no drag handle. `ContextualSparkGlassSurfaceView` already paints
/// the one window's ground, and the AppKit header above owns drag, minimize and the
/// transport controls.
struct MeetingPanelBody: View {
    static let tabStripHeight: CGFloat = 28

    let model: FloatingMeetingTranscriptModel
    let onOpenNotes: () -> Void
    var onSelectTab: (FloatingMeetingPanelTab) -> Void = { _ in }
    @State private var chatDraft = ""

    private var ink: Color { Color(hex: DictationMiniPalette.inkHex) }

    private var partialYou: String {
        model.presentation.partialYou.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var partialOthers: String {
        model.presentation.partialOthers.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var copyText: String {
        LiveTranscriptCopyContent.text(
            transcript: model.presentation.transcript,
            partialYou: model.presentation.partialYou,
            partialOthers: model.presentation.partialOthers
        )
    }

    /// The copy button must enable off the visible tab's payload: notes written
    /// before any speech exists are copyable even though the transcript is empty.
    private var copyPayloadIsEmpty: Bool {
        switch model.selectedTab {
        case .notes:
            return model.notesDraft.isEmpty
        case .chat where model.chatContext != nil:
            return MeetingChatConversations.shared
                .conversation(for: model.chatContext!.meetingID)
                .transcriptForCopying()
                .isEmpty
        default:
            return copyText.isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .tint(ink.opacity(0.90))
    }

    // MARK: Tab strip

    private var tabStrip: some View {
        HStack(spacing: 2) {
            tabButton(.transcript, title: "Transcript")
            if model.isChatAvailable {
                tabButton(.chat, title: "Chat")
            }
            if model.isNotesAvailable {
                tabButton(.notes, title: "My notes")
            }
            Spacer(minLength: MuesliTheme.spacing8)
            liveIndicator
            copyButton
        }
        .padding(.leading, MuesliTheme.spacing8)
        .padding(.trailing, 6)
        .frame(height: Self.tabStripHeight)
        // Hairlines inside the 28 pt band, so the strip never steals a point from the body.
        .overlay(alignment: .top) { hairline }
        .overlay(alignment: .bottom) { hairline }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
    }

    private func tabButton(_ tab: FloatingMeetingPanelTab, title: String) -> some View {
        let isSelected = model.selectedTab == tab
        let selectionAccent = Color(hex: model.selectionAccentHex)
        return Button { onSelectTab(tab) } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? selectionAccent : ink.opacity(0.62))
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private var liveIndicator: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(hex: model.isPaused
                    ? DictationMiniPalette.accentHighlightHex
                    : DictationMiniPalette.successHex))
                .frame(width: 5, height: 5)
            Text(model.isPaused ? "Paused" : "Live")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ink.opacity(0.62))
                .fixedSize()
        }
    }

    private var copyButton: some View {
        Button { model.copyToPasteboard() } label: {
            Image(systemName: model.didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.didCopy
                    ? Color(hex: DictationMiniPalette.successHex)
                    : ink.opacity(0.68))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(copyPayloadIsEmpty)
        .help("Copy")
        .accessibilityLabel(model.didCopy ? "Copied" : "Copy")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.selectedTab {
        case .chat where model.chatContext != nil:
            // Send-time resolvers, not resolved values: reading the growing
            // transcript (or re-resolving notes/config) in this body rebuilt
            // the whole chat surface on every transcript chunk, which the
            // user saw as the chat tab flickering while people spoke.
            MeetingChatView(
                conversation: MeetingChatConversations.shared.conversation(for: model.chatContext!.meetingID),
                draft: $chatDraft,
                transcript: { [model] in model.chatTranscript },
                hasTranscript: model.chatHasTranscript,
                systemPrompt: MeetingChatSource.systemPrompt(isRecording: true),
                manualNotes: model.chatContext!.manualNotes,
                config: model.chatContext!.currentConfig,
                presentation: .floatingPanel
            )
        case .notes:
            notesEditor
        default:
            transcript
        }
    }

    private var transcript: some View {
        ScrollView {
            LiveTranscriptFeedView(
                messages: model.presentation.messages,
                partialYou: partialYou,
                partialOthers: partialOthers,
                horizontalPadding: MuesliTheme.spacing12,
                topPadding: MuesliTheme.spacing8,
                bottomPadding: MuesliTheme.spacing8,
                surfacePresentation: .floatingPanel,
                onOpen: onOpenNotes
            )
        }
        .defaultScrollAnchor(.bottom)
    }

    /// A plain text editor over the same manual notes the main window edits.
    /// Every keystroke writes through to the shared cache; persistence is the
    /// controller's existing debounced path.
    private var notesEditor: some View {
        TextEditor(text: Binding(
            get: { model.notesDraft },
            set: { model.notesEdited($0) }
        ))
        .font(.system(size: 12))
        .foregroundStyle(ink.opacity(0.92))
        .scrollContentBackground(.hidden)
        .padding(.horizontal, MuesliTheme.spacing8)
        .padding(.vertical, MuesliTheme.spacing8)
        .overlay(alignment: .topLeading) {
            if model.notesDraft.isEmpty {
                Text("Type your notes — they feed the meeting summary.")
                    .font(.system(size: 12))
                    .foregroundStyle(ink.opacity(0.42))
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, MuesliTheme.spacing12)
                    .allowsHitTesting(false)
            }
        }
    }
}
