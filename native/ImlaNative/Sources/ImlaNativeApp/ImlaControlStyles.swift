import SwiftUI

/// Action buttons share their geometry and interaction feedback across pages;
/// row selection and recording overlays keep their own interaction styles.
struct ImlaActionButtonStyle: ButtonStyle {
    enum Tone {
        case primary, secondary, quiet, destructive, recording
    }

    var tone: Tone = .secondary
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let resolvedTone = configuration.role == .destructive ? .destructive : tone
        configuration.label
            .font(ImlaTheme.font(size: compact ? 12 : 13, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(foreground(for: resolvedTone))
            .padding(.horizontal, compact ? 10 : ImlaTheme.spacing12)
            .frame(minHeight: compact ? ImlaTheme.compactControlHeight : ImlaTheme.controlHeight)
            .background(background(for: resolvedTone), in: ImlaTheme.shape(ImlaTheme.cornerSmall))
            .overlay {
                ImlaTheme.shape(ImlaTheme.cornerSmall)
                    .strokeBorder(border(for: resolvedTone), lineWidth: 1)
            }
            .contentShape(ImlaTheme.shape(ImlaTheme.cornerSmall))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
            .onHover { value in
                if isHovered != value { isHovered = value }
            }
            .animation(ImlaTheme.Motion.eased(0.12, reduceMotion: reduceMotion), value: isHovered)
    }

    private func foreground(for tone: Tone) -> Color {
        switch tone {
        case .primary, .recording: return .white
        case .destructive: return ImlaTheme.danger
        case .secondary: return ImlaTheme.textPrimary
        case .quiet: return isHovered && isEnabled ? ImlaTheme.textPrimary : ImlaTheme.textSecondary
        }
    }

    private func background(for tone: Tone) -> Color {
        let hovered = isHovered && isEnabled
        switch tone {
        case .primary: return ImlaTheme.accent.opacity(hovered ? 0.88 : 1)
        case .recording: return ImlaTheme.recording.opacity(hovered ? 0.88 : 1)
        case .secondary: return hovered ? ImlaTheme.surfaceSelected : ImlaTheme.surfacePrimary
        case .quiet: return hovered ? ImlaTheme.backgroundHover : .clear
        case .destructive: return ImlaTheme.danger.opacity(hovered ? 0.18 : 0.10)
        }
    }

    private func border(for tone: Tone) -> Color {
        switch tone {
        case .primary: return ImlaTheme.accent.opacity(0.65)
        case .recording: return ImlaTheme.recording.opacity(0.65)
        case .destructive: return ImlaTheme.danger.opacity(0.25)
        case .secondary: return ImlaTheme.surfaceBorder
        case .quiet: return isHovered && isEnabled ? ImlaTheme.surfaceBorder : .clear
        }
    }
}

/// Multiline editors pass their existing focus state, preserving their keyboard
/// navigation and save behavior while sharing a visible focus boundary.
struct ImlaEditorSurface: ViewModifier {
    var isFocused = false

    func body(content: Content) -> some View {
        content
            .padding(ImlaTheme.spacing12)
            .background(ImlaTheme.backgroundBase)
            .clipShape(ImlaTheme.shape(ImlaTheme.cornerSmall))
            .overlay {
                ImlaTheme.shape(ImlaTheme.cornerSmall)
                    .strokeBorder(isFocused ? ImlaTheme.accent : ImlaTheme.surfaceBorder, lineWidth: isFocused ? 2 : 1)
            }
    }
}
