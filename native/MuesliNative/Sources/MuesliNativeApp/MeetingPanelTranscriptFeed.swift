import AppKit
import SwiftUI

/// The merged panel's transcript: node 17's flat two-column line list.
///
/// Deliberately not `LiveTranscriptFeedView`. That view is the main window's chat feed —
/// right-aligned bubbles, borders, timestamps, per-message buttons — and the merged panel's
/// 360 pt glass has room for none of it. The panel reads as a script: a narrow speaker
/// gutter, then the utterance.
struct MeetingPanelTranscriptFeed: View {
    let messages: [TranscriptChatMessage]
    let partialYou: String
    let partialOthers: String
    /// Opens the meeting document. The only per-line affordance: the tab strip's copy
    /// button already covers copying the visible tab.
    let onOpen: () -> Void

    private var trimmedPartialYou: String {
        partialYou.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPartialOthers: String {
        partialOthers.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 7) {
            if messages.isEmpty, trimmedPartialYou.isEmpty, trimmedPartialOthers.isEmpty {
                Text("Waiting for speech…")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: DictationMiniPalette.inkHex).opacity(0.50))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Committed lines first, then the two in-flight tails in the order the
                // engine commits them — Others precedes You, as in the main window's feed.
                ForEach(messages) { message in
                    MeetingPanelTranscriptLine(
                        speaker: message.speaker ?? "",
                        text: message.text,
                        isUser: message.isUser,
                        isPartial: false,
                        onOpen: onOpen
                    )
                }
                if !trimmedPartialOthers.isEmpty {
                    MeetingPanelTranscriptLine(
                        speaker: "Others",
                        text: trimmedPartialOthers,
                        isUser: false,
                        isPartial: true,
                        onOpen: onOpen
                    )
                }
                if !trimmedPartialYou.isEmpty {
                    MeetingPanelTranscriptLine(
                        speaker: "You",
                        text: trimmedPartialYou,
                        isUser: true,
                        isPartial: true,
                        onOpen: onOpen
                    )
                }
            }
        }
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, MuesliTheme.spacing8)
    }
}

private struct MeetingPanelTranscriptLine: View {
    static let speakerGutterWidth: CGFloat = 44

    let speaker: String
    let text: String
    let isUser: Bool
    let isPartial: Bool
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing8) {
            Text(speaker)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(speakerColor)
                .lineLimit(1)
                // The gutter is fixed, so every utterance starts on the same column;
                // a long diarized name truncates rather than pushing the text right.
                .frame(width: Self.speakerGutterWidth, alignment: .leading)
                .padding(.top, 1)
                .help(speaker)

            MeetingSelectableText(
                attributedText: MeetingSelectableTextContent.plain(
                    text,
                    pointSize: 11,
                    color: bodyColor,
                    italic: isPartial,
                    // 11 pt over the node's 1.4 line-height.
                    lineSpacing: 2
                ),
                fillsAvailableWidth: true
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        // Overlaid, never inserted: a button that took part in the row's layout would
        // shift every line sideways the moment the pointer entered it.
        .overlay(alignment: .topTrailing) { openButton }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var openButton: some View {
        Button(action: onOpen) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(hex: DictationMiniPalette.inkHex).opacity(0.68))
                .frame(width: 16, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open meeting details")
        .accessibilityLabel("Open meeting details")
        .opacity(isHovered ? 1 : 0)
        // A zero-opacity button still takes clicks, which would steal them from the
        // text selection underneath.
        .allowsHitTesting(isHovered)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    /// Coral marks the user's own lines; everyone else's label sits back in dimmed ink.
    private var speakerColor: Color {
        isUser
            ? Color(hex: DictationMiniPalette.accentHex)
            : Color(hex: DictationMiniPalette.inkHex).opacity(0.55)
    }

    private var bodyColor: NSColor {
        NSColor.colorWith(hex: DictationMiniPalette.inkHex, alpha: isPartial ? 0.50 : 0.90)
    }
}
