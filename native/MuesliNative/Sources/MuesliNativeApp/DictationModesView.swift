import AppKit
import SwiftUI

/// The Modes screen: standing preferences on top, then one card per destination.
struct DictationModesView: View {
    @Bindable var appState: AppState
    let controller: MuesliController
    let onClose: () -> Void

    @State private var model: DictationModesSettingsModel
    @State private var catalog = InstalledApplicationCatalog()
    @State private var editingMode: DictationMode?
    @State private var pendingDeletion: DictationMode?
    @State private var isResetConfirmationPresented = false

    private let client: DictationModesClient

    init(appState: AppState, controller: MuesliController, onClose: @escaping () -> Void) {
        self.appState = appState
        self.controller = controller
        self.onClose = onClose
        let client = controller.dictationModesClient()
        self.client = client
        _model = State(initialValue: DictationModesSettingsModel(client: client))
    }

    private let columns = [
        GridItem(.flexible(), spacing: MuesliTheme.spacing12),
        GridItem(.flexible(), spacing: MuesliTheme.spacing12),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                    SettingsControls.section("Custom instructions") {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                            CustomInstructionsEditor(committed: appState.config.customInstructions) {
                                controller.setCustomInstructions($0)
                            }
                            SettingsControls.description(
                                "Applies to every dictation, plus meeting transcript cleanup and meeting notes."
                            )
                        }
                    }

                    migrationNotice
                    modesSection
                }
                .padding(.bottom, MuesliTheme.spacing16)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.danger)
            }
        }
        .padding(MuesliTheme.spacing24)
        .frame(minWidth: 820, minHeight: 620)
        .background(MuesliTheme.backgroundBase)
        .sheet(item: $editingMode) { mode in
            DictationModeEditorView(
                mode: mode,
                model: model,
                catalog: catalog,
                onSave: { edited in
                    model.save(edited, using: client)
                    editingMode = nil
                },
                onCancel: { editingMode = nil }
            )
        }
        .alert(
            "Delete \(pendingDeletion?.name ?? "this mode")?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let pendingDeletion {
                    model.delete(id: pendingDeletion.id, using: client)
                }
                pendingDeletion = nil
            }
        } message: {
            Text("This can't be undone. Its apps, websites, and instructions won't move to another mode.")
        }
        .alert("Reset modes?", isPresented: $isResetConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { model.resetToBuiltIns(using: client) }
        } message: {
            Text(
                """
                Built-in modes go back to their original name, instructions, apps, websites \
                and send key, and any of their apps or websites you moved to another mode \
                come back. Modes you created are kept.
                """
            )
        }
        .onAppear { catalog.loadIfNeeded() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Modes")
                    .font(MuesliTheme.title2())
                Text("Muesli picks a mode from the app or website you dictate into.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            Spacer()
            HStack(spacing: MuesliTheme.spacing8) {
                SettingsControls.compactActionButton("Reset modes", systemImage: "arrow.counterclockwise") {
                    isResetConfirmationPresented = true
                }
                SettingsControls.compactActionButton("Create mode", systemImage: "plus") {
                    editingMode = DictationMode(id: UUID().uuidString, name: "New mode")
                }
                SettingsControls.compactActionButton("Done") { onClose() }
            }
        }
    }

    /// One-time disclosure for R5-R9's migration: a wildcard app or website matcher
    /// has no exact-match equivalent in the new model, so it was dropped rather than
    /// silently kept. Shown only while notes remain, dismissed by clearing them in
    /// memory (they are decode-only and never reach disk either way).
    @ViewBuilder
    private var migrationNotice: some View {
        if !appState.config.dictationModesMigrationNotes.isEmpty {
            SettingsControls.card {
                HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text("Some activation rules couldn't migrate")
                            .font(MuesliTheme.headline())
                        Text(migrationNoticeBody)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: MuesliTheme.spacing12)
                    SettingsControls.compactActionButton("Dismiss") {
                        controller.updateConfig { $0.dictationModesMigrationNotes = [] }
                    }
                }
            }
        }
    }

    private var migrationNoticeBody: String {
        let notes = appState.config.dictationModesMigrationNotes
        let count = notes.count
        let header = count == 1
            ? "1 activation rule from your previous setup couldn't be carried over automatically:"
            : "\(count) activation rules from your previous setup couldn't be carried over automatically:"
        return (["\(header)"] + notes.map { "• \($0)" }).joined(separator: "\n")
    }

    private var modesSection: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: MuesliTheme.spacing12) {
            ForEach(model.modes) { mode in
                card(for: mode)
            }
        }
    }

    private func card(for mode: DictationMode) -> some View {
        SettingsControls.card {
            HStack(alignment: .firstTextBaseline) {
                Text(mode.name)
                    .font(MuesliTheme.headline())
                    .lineLimit(1)
                Spacer()
                SettingsControls.compactActionButton("Edit", systemImage: "pencil") {
                    editingMode = mode
                }
                SettingsControls.compactActionButton(
                    "Delete",
                    systemImage: "trash",
                    role: .destructive
                ) {
                    pendingDeletion = mode
                }
                .accessibilityLabel("Delete \(mode.name)")
            }

            HStack(spacing: MuesliTheme.spacing8) {
                targets(for: mode)
                Spacer()
                SettingsControls.settingsSwitch(isOn: mode.isEnabled) { isOn in
                    model.setEnabled(isOn, id: mode.id, using: client)
                }
                .accessibilityLabel("Enable \(mode.name)")
            }
        }
    }

    @ViewBuilder
    private func targets(for mode: DictationMode) -> some View {
        if mode.appBundleIDs.isEmpty, mode.websiteHostnames.isEmpty {
            Text("Not used in any app")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
        } else {
            HStack(spacing: 4) {
                ForEach(mode.appBundleIDs.prefix(4), id: \.self) { bundleID in
                    TargetApplicationIconView(
                        appName: bundleID,
                        bundleIdentifier: bundleID,
                        size: 16,
                        accessibilityLabel: "Activates in \(bundleID)"
                    )
                }
                ForEach(mode.websiteHostnames.prefix(2), id: \.self) { host in
                    Text(host)
                        .font(MuesliTheme.font(size: 11, weight: .medium))
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerChip, style: .continuous))
                }
                if overflowCount(for: mode) > 0 {
                    Text("+\(overflowCount(for: mode))")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }
        }
    }

    private func overflowCount(for mode: DictationMode) -> Int {
        max(0, mode.appBundleIDs.count - 4) + max(0, mode.websiteHostnames.count - 2)
    }
}
