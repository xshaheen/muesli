// Purpose: Ask questions about a meeting transcript, live or after the fact
// Created: 2026-07-31

import Observation
import SwiftUI

/// Chat surface over a meeting transcript.
///
/// Sources nothing itself. The transcript and system prompt arrive as inputs so the same
/// view serves both the detail tab (live or finalized transcript) and the floating panel
/// without branching on meeting state internally.
struct MeetingChatView: View {
    @Bindable var conversation: MeetingChatConversation
    let transcript: String
    let systemPrompt: String
    let config: AppConfig
    /// Compact mode trims padding and type size for the floating panel.
    var isCompact: Bool = false

    @State private var draft: String = ""
    @FocusState private var isInputFocused: Bool

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !conversation.isSending
    }

    private var hasTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider().overlay(MuesliTheme.surfaceBorder)
            composer
        }
        .background(MuesliTheme.backgroundBase)
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
                    if conversation.isEmpty {
                        emptyState
                    }
                    ForEach(conversation.turns) { turn in
                        turnBubble(turn)
                            .id(turn.id)
                    }
                    if conversation.isSending {
                        thinkingRow.id(Self.thinkingAnchor)
                    }
                    if let error = conversation.lastError {
                        errorRow(error).id(Self.errorAnchor)
                    }
                }
                .padding(isCompact ? 10 : 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: conversation.turns.count) { _, _ in
                scrollToEnd(proxy)
            }
            .onChange(of: conversation.isSending) { _, _ in
                scrollToEnd(proxy)
            }
        }
    }

    private static let thinkingAnchor = "chat-thinking"
    private static let errorAnchor = "chat-error"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if conversation.lastError != nil {
                proxy.scrollTo(Self.errorAnchor, anchor: .bottom)
            } else if conversation.isSending {
                proxy.scrollTo(Self.thinkingAnchor, anchor: .bottom)
            } else if let last = conversation.turns.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        Text(hasTranscript
             ? "Ask anything about this meeting."
             : "Nothing has been transcribed yet.")
            .font(.system(size: isCompact ? 11 : 12))
            .foregroundStyle(MuesliTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
    }

    private func turnBubble(_ turn: MeetingChatTurn) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if turn.role == .user { Spacer(minLength: 32) }
            Text(turn.displayText)
                .font(.system(size: isCompact ? 12 : 13))
                .foregroundStyle(MuesliTheme.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(turn.role == .user ? MuesliTheme.surfaceSelected : MuesliTheme.backgroundRaised)
                )
                .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
            if turn.role == .assistant { Spacer(minLength: 32) }
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Thinking…")
                .font(.system(size: isCompact ? 11 : 12))
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .padding(.vertical, 2)
    }

    /// Errors render inline in the flow rather than as a modal — a failed question during a
    /// meeting should not take over the screen.
    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: isCompact ? 11 : 12))
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MuesliTheme.backgroundRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask anything", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: isCompact ? 12 : 13))
                .lineLimit(1 ... 4)
                .focused($isInputFocused)
                .onSubmit(submit)
                .disabled(!hasTranscript)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: isCompact ? 16 : 18))
                    .foregroundStyle(canSend ? MuesliTheme.accent : MuesliTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send")
        }
        .padding(.horizontal, isCompact ? 10 : 14)
        .padding(.vertical, isCompact ? 8 : 10)
    }

    private func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !conversation.isSending else { return }
        draft = ""
        Task {
            await conversation.send(
                displayText: question,
                transcript: transcript,
                systemPrompt: systemPrompt,
                config: config
            )
        }
    }
}
