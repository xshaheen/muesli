// Purpose: Ask questions about a meeting transcript, live or after the fact
// Created: 2026-07-31

import Observation
import SwiftUI
import AppKit

enum MeetingChatPresentation: Equatable {
    case standard
    case floatingPanel
}

/// Chat surface over a meeting transcript.
///
/// Sources nothing itself. The transcript and system prompt arrive as inputs so the same
/// view serves both the detail tab (live or finalized transcript) and the floating panel
/// without branching on meeting state internally.
struct MeetingChatView: View {
    @Bindable var conversation: MeetingChatConversation
    @Binding var draft: String
    /// Resolved when a question is sent, never in `body`. During a recording the
    /// transcript grows on every chunk, and a body that read it re-rendered this whole
    /// surface — composer included — each time, which showed up as flicker in the
    /// floating panel's chat tab. Send-time resolution also means a question always
    /// reasons over the freshest text, not the copy from the last render.
    let transcript: () -> String
    /// The cheap, rarely-changing stand-in the body gates on instead of the transcript.
    let hasTranscript: Bool
    let systemPrompt: String
    /// The user's own notes, sent alongside the transcript so answers reflect what
    /// they thought worth writing down, not only what was said aloud. A closure for
    /// the same reason `transcript` is: resolved per send, read nowhere in `body`.
    var manualNotes: () -> String = { "" }
    let config: () -> AppConfig
    var presentation: MeetingChatPresentation = .standard

    /// Which answer was just copied, so the button can confirm it happened.
    @State private var copiedTurnText: String?
    @FocusState private var isInputFocused: Bool

    private var isCompact: Bool { presentation == .floatingPanel }
    private var usesNeutralGlassStyle: Bool { presentation == .floatingPanel }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !conversation.isSending
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider().overlay(
                usesNeutralGlassStyle
                    ? Color.white.opacity(FloatingMeetingPanelPalette.separatorAlpha)
                    : MuesliTheme.surfaceBorder
            )
            composer
        }
        .background {
            // The floating panel paints its own translucent material behind this view;
            // covering it with the main window's opaque base made chat mode a visibly
            // different color from the transcript mode sharing the same panel.
            if !isCompact { MuesliTheme.backgroundBase }
        }
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
            .onAppear {
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
            .font(MuesliTheme.font(size: isCompact ? 11 : 12))
            .foregroundStyle(MuesliTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
    }

    private func turnBubble(_ turn: MeetingChatTurn) -> some View {
        let contentDirection = NaturalTextDirection.resolve(turn.displayText)

        return HStack(alignment: .top, spacing: 6) {
            if turn.role == .user { Spacer(minLength: 32) }
            VStack(
                alignment: contentDirection == .rightToLeft ? .trailing : .leading,
                spacing: 4
            ) {
                // Answers arrive as markdown, so render them the way notes and
                // transcripts render -- otherwise bullets and bold show up as
                // literal `-` and `**` in the middle of a sentence.
                if turn.role == .assistant {
                    MeetingMarkdownContent(
                        markdown: turn.displayText,
                        bodyPointSize: isCompact ? 12 : 13
                    )
                } else {
                    MeetingSelectableText(attributedText: MeetingSelectableTextContent.plain(
                        turn.displayText,
                        pointSize: isCompact ? 12 : 13
                    ))
                        .environment(\.layoutDirection, contentDirection.layoutDirection)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if turn.role == .assistant {
                    copyButton(for: turn.displayText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(turnBubbleFill(for: turn.role))
            )
            .overlay {
                if usesNeutralGlassStyle {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(FloatingMeetingPanelPalette.separatorAlpha),
                            lineWidth: 1
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
            if turn.role == .assistant { Spacer(minLength: 32) }
        }
    }

    private func turnBubbleFill(for role: MeetingChatTurn.Role) -> Color {
        if usesNeutralGlassStyle {
            return Color.white.opacity(
                role == .user
                    ? FloatingMeetingPanelPalette.strongSurfaceAlpha
                    : FloatingMeetingPanelPalette.subtleSurfaceAlpha
            )
        }
        return role == .user ? MuesliTheme.surfaceSelected : MuesliTheme.backgroundRaised
    }

    private func copyTurn(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedTurnText = text
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if copiedTurnText == text { copiedTurnText = nil }
        }
    }

    /// Copying one answer, rather than making the user select it by hand.
    private func copyButton(for text: String) -> some View {
        Button {
            copyTurn(text)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: copiedTurnText == text ? "checkmark" : "doc.on.doc")
                Text(copiedTurnText == text ? "Copied" : "Copy")
            }
            .font(MuesliTheme.font(size: isCompact ? 10 : 11))
            .foregroundStyle(MuesliTheme.textTertiary)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .accessibilityLabel(copiedTurnText == text ? "Copied answer" : "Copy answer")
    }

    private var thinkingRow: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .tint(usesNeutralGlassStyle ? Color.white.opacity(0.70) : MuesliTheme.accent)
            Text("Thinking…")
                .font(MuesliTheme.font(size: isCompact ? 11 : 12))
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .padding(.vertical, 2)
    }

    /// Errors render inline in the flow rather than as a modal — a failed question during a
    /// meeting should not take over the screen.
    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(MuesliTheme.font(size: isCompact ? 11 : 12))
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        usesNeutralGlassStyle
                            ? Color.white.opacity(FloatingMeetingPanelPalette.subtleSurfaceAlpha)
                            : MuesliTheme.backgroundRaised
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        usesNeutralGlassStyle
                            ? Color.white.opacity(FloatingMeetingPanelPalette.strongSurfaceAlpha)
                            : MuesliTheme.surfaceBorder,
                        lineWidth: 1
                    )
            )
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 6) {
            recipeChips
            inputRow
        }
        .padding(.horizontal, isCompact ? 10 : 14)
        .padding(.vertical, isCompact ? 8 : 10)
    }

    /// One-tap saved prompts. Each sends its full instruction through the same path a typed
    /// question uses, while the conversation shows only the recipe's name.
    ///
    /// A horizontal scroll, not a wrapping row: in the floating panel's 360pt the
    /// names used to wrap to two lines, turning the capsules into tall uneven
    /// lozenges. Single-line chips keep the capsule shape; overflow scrolls.
    private var recipeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MeetingChatRecipes.visible()) { recipe in
                    Button { run(recipe) } label: {
                        Text(recipe.name)
                            .font(MuesliTheme.font(size: isCompact ? 10 : 11, weight: .medium))
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(
                                    usesNeutralGlassStyle
                                        ? Color.white.opacity(FloatingMeetingPanelPalette.controlSurfaceAlpha)
                                        : MuesliTheme.backgroundRaised
                                )
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    usesNeutralGlassStyle
                                        ? Color.white.opacity(FloatingMeetingPanelPalette.strongSurfaceAlpha)
                                        : MuesliTheme.surfaceBorder,
                                    lineWidth: 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRunRecipe)
                    .help(recipe.prompt)
                }

                if !MeetingChatRecipes.overflow().isEmpty {
                    Menu {
                        ForEach(MeetingChatRecipes.overflow()) { recipe in
                            Button(recipe.name) { run(recipe) }
                        }
                    } label: {
                        Text("All recipes")
                            .font(MuesliTheme.font(size: isCompact ? 10 : 11))
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(!canRunRecipe)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canRunRecipe: Bool {
        hasTranscript && !conversation.isSending
    }

    private func run(_ recipe: MeetingChatRecipe) {
        guard canRunRecipe else { return }
        Task {
            await conversation.send(
                displayText: recipe.name,
                sentText: recipe.prompt,
                transcript: transcript(),
                systemPrompt: systemPrompt,
                manualNotes: manualNotes(),
                config: config()
            )
        }
    }

    private var inputRow: some View {
        let inputDirection = NaturalTextDirection.resolve(draft)

        return HStack(spacing: 8) {
            TextField("Ask anything", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(MuesliTheme.font(size: isCompact ? 12 : 13))
                .lineLimit(1 ... 4)
                .environment(\.layoutDirection, inputDirection.layoutDirection)
                .multilineTextAlignment(.leading)
                .focused($isInputFocused)
                .onSubmit(submit)
                .disabled(!hasTranscript)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: isCompact ? 16 : 18))
                    .foregroundStyle(
                        usesNeutralGlassStyle
                            ? Color.white.opacity(canSend ? 0.92 : 0.34)
                            : (canSend ? MuesliTheme.accent : MuesliTheme.textTertiary)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send")
        }
        .padding(.horizontal, usesNeutralGlassStyle ? 10 : 0)
        .padding(.vertical, usesNeutralGlassStyle ? 7 : 0)
        .background {
            if usesNeutralGlassStyle {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(FloatingMeetingPanelPalette.controlSurfaceAlpha))
            }
        }
        .overlay {
            if usesNeutralGlassStyle {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(FloatingMeetingPanelPalette.strongSurfaceAlpha),
                        lineWidth: 1
                    )
            }
        }
    }

    private func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !conversation.isSending else { return }
        draft = ""
        Task {
            await conversation.send(
                displayText: question,
                transcript: transcript(),
                systemPrompt: systemPrompt,
                manualNotes: manualNotes(),
                config: config()
            )
        }
    }
}
