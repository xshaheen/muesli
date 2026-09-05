import AppKit
import SwiftUI

/// Edits one mode: what it says, where it applies, and what to press afterwards.
struct DictationModeEditorView: View {
    @State private var draft: DictationMode
    private let originalID: String
    let model: DictationModesSettingsModel
    let catalog: InstalledApplicationCatalog
    let onSave: (DictationMode) -> Void
    let onCancel: () -> Void

    @State private var isAppPickerPresented = false
    @State private var appSearch = ""
    @State private var websiteInput = ""
    @State private var inlineMessage: String?
    @FocusState private var isSearchFocused: Bool

    init(
        mode: DictationMode,
        model: DictationModesSettingsModel,
        catalog: InstalledApplicationCatalog,
        onSave: @escaping (DictationMode) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: mode)
        originalID = mode.id
        self.model = model
        self.catalog = catalog
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var validationMessage: String? { model.validationMessage(for: draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            Text("Name")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
            TextField("Mode name", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            activationApps
            activationWebsites
            overrideToggle
            instructionsEditor
            autoEnter

            if let message = inlineMessage ?? validationMessage {
                Text(message)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.danger)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(validationMessage != nil)
            }
        }
        .padding(MuesliTheme.spacing24)
        .frame(width: 520)
        .background(MuesliTheme.backgroundBase)
    }

    // MARK: - Activation apps

    private var activationApps: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack {
                Text("Activation apps")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Spacer()
                SettingsControls.compactActionButton("Add", systemImage: "plus") {
                    isAppPickerPresented = true
                    isSearchFocused = true
                }
                .popover(isPresented: $isAppPickerPresented, arrowEdge: .bottom) { appPicker }
                SettingsControls.compactActionButton("Choose Application…") { chooseApplicationFile() }
            }

            if draft.appBundleIDs.isEmpty {
                SettingsControls.description("No activation apps selected.")
            } else {
                ForEach(draft.appBundleIDs, id: \.self) { bundleID in
                    HStack(spacing: MuesliTheme.spacing8) {
                        TargetApplicationIconView(
                            appName: bundleID,
                            bundleIdentifier: bundleID,
                            size: 16,
                            accessibilityLabel: "Activates in \(bundleID)"
                        )
                        Text(displayName(for: bundleID))
                            .font(MuesliTheme.body())
                        Spacer()
                        Button {
                            draft.appBundleIDs.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(MuesliTheme.danger)
                        .accessibilityLabel("Remove \(displayName(for: bundleID))")
                    }
                }
            }
        }
    }

    private var appPicker: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            TextField("Search apps", text: $appSearch)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)

            if catalog.isScanning {
                HStack(spacing: MuesliTheme.spacing8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for installed apps…")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }

            let matches = InstalledApplicationCatalog.filter(catalog.applications, query: appSearch)
            if matches.isEmpty, !catalog.isScanning {
                Text("No apps match.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(matches.prefix(200)) { app in
                        Button { add(bundleID: app.bundleID, named: app.displayName) } label: {
                            HStack(spacing: MuesliTheme.spacing8) {
                                TargetApplicationIconView(
                                    appName: app.displayName,
                                    bundleIdentifier: app.bundleID,
                                    size: 16,
                                    accessibilityLabel: app.displayName
                                )
                                Text(app.displayName)
                                    .font(MuesliTheme.body())
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 320, height: 260)
        }
        .padding(MuesliTheme.spacing12)
    }

    // MARK: - Activation websites

    private var activationWebsites: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text("Activation websites")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)

            HStack {
                TextField("chatgpt.com", text: $websiteInput)
                    .textFieldStyle(.roundedBorder)
                SettingsControls.compactActionButton("Add") { addWebsite() }
            }

            ForEach(draft.websiteHostnames, id: \.self) { host in
                HStack {
                    Text(host)
                        .font(MuesliTheme.mono(size: 12))
                    Spacer()
                    Button {
                        draft.websiteHostnames.removeAll { $0 == host }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MuesliTheme.danger)
                    .accessibilityLabel("Remove \(host)")
                }
            }

            SettingsControls.description(
                """
                Muesli reads the address of the page you are dictating into to match a mode. \
                The address is never stored or sent.
                """
            )
        }
    }

    // MARK: - Instructions and delivery

    private var overrideToggle: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Override default")
                    .font(MuesliTheme.body())
                SettingsControls.description(
                    "Use these instructions instead of the default ones, even if there are none."
                )
            }
            Spacer()
            SettingsControls.settingsSwitch(isOn: draft.overrideDefaultInstructions) {
                draft.overrideDefaultInstructions = $0
            }
            .accessibilityLabel("Override default instructions")
        }
    }

    private var instructionsEditor: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text("Custom instructions")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
            TextEditor(text: $draft.instructions)
                .font(MuesliTheme.body())
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96)
                .padding(MuesliTheme.spacing8)
                .background(MuesliTheme.backgroundBase)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
        }
    }

    private var autoEnter: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto enter")
                        .font(MuesliTheme.body())
                    SettingsControls.description(
                        """
                        Presses the key in whatever has keyboard focus after the paste: it sends \
                        the message, submits the form, or runs the command.
                        """
                    )
                }
                Spacer()
                SettingsControls.settingsSwitch(isOn: draft.autoEnter != nil) { isOn in
                    draft.autoEnter = isOn ? .return : nil
                }
                .accessibilityLabel("Press a key after pasting")
            }

            if draft.autoEnter != nil {
                Picker("", selection: Binding(
                    get: { draft.autoEnter ?? .return },
                    set: { draft.autoEnter = $0 }
                )) {
                    Text("Enter").tag(DictationModeAutoEnter.return)
                    Text("Cmd+Enter (send or submit)").tag(DictationModeAutoEnter.commandReturn)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // MARK: - Actions

    private func add(bundleID: String, named name: String) {
        guard let normalized = DictationModes.normalizedBundleID(bundleID) else {
            inlineMessage = "That application has no usable identifier."
            return
        }
        guard !draft.appBundleIDs.contains(normalized) else { return }
        if let owner = model.modeOwning(bundleID: normalized, excluding: originalID) {
            inlineMessage = "Moved \(name) from \(owner.name)."
        } else {
            inlineMessage = nil
        }
        draft.appBundleIDs.append(normalized)
        isAppPickerPresented = false
        appSearch = ""
    }

    private func addWebsite() {
        guard let normalized = DictationModes.normalizedHostname(websiteInput)
            ?? DictationModes.normalizedHostname(hostComponent(of: websiteInput))
        else {
            inlineMessage = "Enter a website like chatgpt.com."
            return
        }
        guard !draft.websiteHostnames.contains(normalized) else {
            websiteInput = ""
            return
        }
        if let owner = model.modeOwning(hostname: normalized, excluding: originalID) {
            inlineMessage = "Moved \(normalized) from \(owner.name)."
        } else {
            inlineMessage = nil
        }
        draft.websiteHostnames.append(normalized)
        websiteInput = ""
    }

    /// Accepts a pasted URL as well as a bare host, because that is what a user
    /// copying from the address bar actually has.
    private func hostComponent(of input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = URLComponents(string: trimmed)?.host { return host }
        if let host = URLComponents(string: "https://" + trimmed)?.host { return host }
        return trimmed
    }

    private func chooseApplicationFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let app = try InstalledApplicationCatalog.application(at: url)
            add(bundleID: app.bundleID, named: app.displayName)
        } catch {
            inlineMessage = error.localizedDescription
        }
    }

    private func displayName(for bundleID: String) -> String {
        catalog.applications.first { $0.bundleID == bundleID }?.displayName ?? bundleID
    }
}
