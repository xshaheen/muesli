import SwiftUI
import ImlaCore

enum SettingsWindowLayout {
    static let sidebarWidth: CGFloat = 220
    /// Wide enough for the Settings rows' 275pt controls beside their labels
    /// without wrapping, tall enough that the Dictation pane's first section is
    /// visible without scrolling.
    static let minimumContentWidth: CGFloat = 860
    static let minimumContentHeight: CGFloat = 560
    static let defaultContentSize = NSSize(width: 1000, height: 720)
}

/// The settings window: its own sidebar beside the Settings panes, Models,
/// Shortcuts, and About. Same two-column construction as the dashboard, for the
/// same reason — the leading column must own the window corner so the traffic
/// lights sit on the sidebar surface.
struct SettingsRootView: View {
    let appState: AppState
    let controller: ImlaController

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebarView(appState: appState, controller: controller)
                .frame(width: SettingsWindowLayout.sidebarWidth)

            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                detailContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ImlaTheme.backgroundBase)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(
            minWidth: SettingsWindowLayout.minimumContentWidth,
            minHeight: SettingsWindowLayout.minimumContentHeight
        )
        .preferredColorScheme(appState.config.darkMode ? .dark : .light)
        .featureTourHost(.settings, appState: appState, controller: controller)
        // The incident prompt navigates to About, which lives here, so the
        // sheet is anchored to this window rather than the dashboard.
        .sheet(
            item: Binding<DiagnosticIncident?>(
                get: { appState.pendingDiagnosticIncident },
                set: { if $0 == nil { controller.dismissDiagnosticIncidentPrompt() } }
            )
        ) { incident in
            DiagnosticIncidentReportView(
                incident: incident,
                onOpenIssue: { controller.openDiagnosticIncidentIssue(incident) },
                onDismiss: { controller.dismissDiagnosticIncidentPrompt() }
            )
        }
    }

    private var pageTitle: String {
        switch appState.selectedSettingsSection {
        case .settings: appState.selectedSettingsPane.title
        case .models, .shortcuts, .about: appState.selectedSettingsSection.title
        }
    }

    private var pageHeader: some View {
        Text(pageTitle)
            .font(ImlaTheme.title1())
            .foregroundStyle(ImlaTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ImlaTheme.spacing24)
            .padding(.top, ImlaTheme.spacing16)
            .padding(.bottom, ImlaTheme.spacing12)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch appState.selectedSettingsSection {
        case .settings:
            SettingsView(appState: appState, controller: controller)
        case .models:
            ModelsView(appState: appState, controller: controller)
        case .shortcuts:
            ShortcutsView(appState: appState, controller: controller)
        case .about:
            AboutView(
                appState: appState,
                onOpenManualDiagnosticReport: { controller.openManualDiagnosticReport() },
                onSetAutomaticDiagnosticIssuePrompts: { controller.setAutomaticDiagnosticIssuePrompts($0) }
            )
        }
    }
}

struct SettingsSidebarView: View {
    /// Same inset as the dashboard sidebar: the window has no titlebar band, so
    /// the traffic lights float over the top of this column.
    private static let titlebarHeight: CGFloat = 28
    private let rowOuterPadding: CGFloat = 8

    let appState: AppState
    let controller: ImlaController
    @Environment(\.colorScheme) private var colorScheme

    private var pendingUpdateCTA: SidebarUpdateCTA? {
        SidebarUpdateCTA.pending(
            status: appState.sparkleUpdateStatus,
            accentOverrideHex: appState.config.accentOverrideHex,
            colorScheme: colorScheme
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing4) {
            header

            ForEach(SettingsPane.allCases) { pane in
                paneRow(pane)
            }

            Divider()
                .padding(.horizontal, ImlaTheme.spacing16)
                .padding(.vertical, ImlaTheme.spacing8)

            sectionRow(.models, icon: "cpu")
            sectionRow(.shortcuts, icon: "command")
            sectionRow(.about, icon: "info.circle", updateCTA: pendingUpdateCTA)

            Spacer()
        }
        .frame(maxHeight: .infinity)
        .background(ImlaTheme.backgroundDeep.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: ImlaTheme.spacing12) {
            Image(systemName: "gearshape")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(ImlaTheme.accent)
                .frame(width: 22, height: 22)
            Text("Settings")
                .font(ImlaTheme.title2())
                .foregroundStyle(ImlaTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, ImlaTheme.spacing16)
        .padding(.top, Self.titlebarHeight + ImlaTheme.pageTop)
        .padding(.bottom, ImlaTheme.spacing20)
    }

    private func paneRow(_ pane: SettingsPane) -> some View {
        let isSelected = appState.selectedSettingsSection == .settings
            && appState.selectedSettingsPane == pane
        return Button {
            withAnimation(ImlaTheme.Motion.eased(0.15)) {
                controller.showSettingsPane(pane)
            }
        } label: {
            SidebarRowLabel(icon: Self.icon(for: pane), label: pane.title, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, rowOuterPadding)
    }

    private func sectionRow(
        _ section: SettingsWindowSection,
        icon: String,
        updateCTA: SidebarUpdateCTA? = nil
    ) -> some View {
        Button {
            withAnimation(ImlaTheme.Motion.eased(0.15)) {
                appState.selectedSettingsSection = section
            }
        } label: {
            SidebarRowLabel(
                icon: icon,
                label: section.title,
                isSelected: appState.selectedSettingsSection == section,
                updateCTA: updateCTA
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, rowOuterPadding)
    }

    static func icon(for pane: SettingsPane) -> String {
        switch pane {
        case .general: "slider.horizontal.3"
        case .speechModels: "waveform.badge.mic"
        case .dictation: "mic"
        case .meetings: "person.wave.2"
        case .writingAI: "sparkles"
        case .computerUse: "cursorarrow.click.2"
        case .sync: "icloud"
        case .appearance: "paintpalette"
        }
    }
}
