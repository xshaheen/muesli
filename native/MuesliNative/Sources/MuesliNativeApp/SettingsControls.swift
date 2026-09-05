import AppKit
import SwiftUI

/// The settings surface recipes, shared so a screen outside `SettingsView` looks
/// like settings rather than approximating it.
///
/// `SettingsView` keeps thin private wrappers that pass its own control width, so
/// its call sites are unchanged.
enum SettingsControls {
    static let defaultControlWidth: CGFloat = 220

    @ViewBuilder
    static func section(
        _ title: String,
        icon: NSImage? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: 5) {
                if let icon {
                    Image(nsImage: icon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                }
                Text(title)
                    .font(MuesliTheme.font(size: 11, weight: .semibold))
                    .textCase(.uppercase)
            }
            .foregroundStyle(MuesliTheme.textTertiary)
            .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(MuesliTheme.spacing16)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
    }

    /// The card surface on its own, for a grid of cards that are not settings rows.
    @ViewBuilder
    static func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            content()
        }
        .padding(MuesliTheme.spacing16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    static func compactActionButton(
        _ title: String,
        systemImage: String? = nil,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isDestructive = role == .destructive
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(MuesliTheme.font(size: 12, weight: .medium))
            .foregroundStyle(isDestructive ? MuesliTheme.danger : MuesliTheme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(isDestructive ? MuesliTheme.danger.opacity(0.1) : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous)
                    .strokeBorder(
                        isDestructive ? MuesliTheme.danger.opacity(0.25) : MuesliTheme.surfaceBorder,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    static func settingsSwitch(isOn: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(get: { isOn }, set: onChange))
            .toggleStyle(.switch)
            .tint(MuesliTheme.accent)
            .labelsHidden()
    }

    @ViewBuilder
    static func description(_ text: String) -> some View {
        Text(text)
            .font(MuesliTheme.caption())
            .foregroundStyle(MuesliTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
