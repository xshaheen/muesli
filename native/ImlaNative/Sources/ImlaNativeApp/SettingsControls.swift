import AppKit
import SwiftUI

/// The settings surface recipes, shared so a screen outside `SettingsView` looks
/// like settings rather than approximating it.
///
/// `SettingsView` keeps thin private wrappers that pass its own control width, so
/// its call sites are unchanged.
enum SettingsControls {
    static let defaultControlWidth: CGFloat = 220

    static func row(
        _ label: String,
        description: String? = nil,
        controlWidth: CGFloat = defaultControlWidth,
        @ViewBuilder control: () -> some View
    ) -> some View {
        SettingsRowLayout(controlWidth: controlWidth) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(ImlaTheme.body())
                    .foregroundStyle(ImlaTheme.textPrimary)
                if let description {
                    Self.description(description)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .trailing) {
                control()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel(label)
        }
        .padding(.vertical, ImlaTheme.spacing8)
    }

    static func actionButton(
        _ title: String,
        systemImage: String? = nil,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: ImlaTheme.spacing8) {
                Text(title)
                if let systemImage { Image(systemName: systemImage) }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ImlaActionButtonStyle())
    }

    @ViewBuilder
    static func section(
        _ title: String,
        icon: NSImage? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing8) {
            HStack(spacing: 5) {
                if let icon {
                    Image(nsImage: icon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                }
                Text(title)
                    .font(ImlaTheme.font(size: 11, weight: .semibold))
                    .textCase(.uppercase)
            }
            .foregroundStyle(ImlaTheme.textSecondary)
            .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(ImlaTheme.spacing16)
            .background(ImlaTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                    .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
            )
        }
    }

    /// The card surface on its own, for a grid of cards that are not settings rows.
    @ViewBuilder
    static func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing8) {
            content()
        }
        .padding(ImlaTheme.spacing16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ImlaTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    static func compactActionButton(
        _ title: String,
        systemImage: String? = nil,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: ImlaTheme.spacing8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .lineLimit(1)
            }
        }
        .buttonStyle(ImlaActionButtonStyle(compact: true))
    }

    @ViewBuilder
    static func settingsSwitch(isOn: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(get: { isOn }, set: onChange))
            .toggleStyle(.switch)
            .tint(ImlaTheme.accent)
            .labelsHidden()
    }

    @ViewBuilder
    static func description(_ text: String) -> some View {
        Text(text)
            .font(ImlaTheme.caption())
            .foregroundStyle(ImlaTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One control instance survives width changes, retaining focus and edit state.
struct SettingsRowLayout: Layout {
    var controlWidth: CGFloat = SettingsControls.defaultControlWidth
    var spacing: CGFloat = 20
    var stackedSpacing: CGFloat = 8

    struct Columns: Equatable {
        let labelWidth: CGFloat
        let controlWidth: CGFloat
        let isStacked: Bool
    }

    func columns(width: CGFloat, idealLabelWidth: CGFloat) -> Columns {
        let width = max(0, width)
        let labelMinimum = min(max(idealLabelWidth, 140), 320)
        let stacked = width < labelMinimum + spacing + controlWidth
        return Columns(
            labelWidth: stacked ? width : width - spacing - controlWidth,
            controlWidth: min(width, controlWidth),
            isStacked: stacked
        )
    }

    private func measurement(width: CGFloat, subviews: Subviews) -> (Columns, CGSize, CGSize) {
        let columns = columns(width: width, idealLabelWidth: subviews[0].sizeThatFits(.unspecified).width)
        let label = subviews[0].sizeThatFits(ProposedViewSize(width: columns.labelWidth, height: nil))
        let control = subviews[1].sizeThatFits(ProposedViewSize(width: columns.controlWidth, height: nil))
        return (columns, label, control)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? (320 + spacing + controlWidth)
        let (columns, label, control) = measurement(width: width, subviews: subviews)
        let height = columns.isStacked
            ? label.height + stackedSpacing + control.height
            : max(label.height, control.height)
        return CGSize(width: width, height: max(ImlaTheme.controlHeight, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (columns, label, control) = measurement(width: bounds.width, subviews: subviews)
        let labelY = columns.isStacked ? bounds.minY : bounds.midY - label.height / 2
        let controlY = columns.isStacked ? bounds.minY + label.height + stackedSpacing : bounds.midY - control.height / 2
        subviews[0].place(at: CGPoint(x: bounds.minX, y: labelY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: columns.labelWidth, height: label.height))
        subviews[1].place(at: CGPoint(x: columns.isStacked ? bounds.minX : bounds.maxX - columns.controlWidth, y: controlY),
                          anchor: .topLeading, proposal: ProposedViewSize(width: columns.controlWidth, height: control.height))
    }
}
