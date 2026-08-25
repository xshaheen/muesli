import SwiftUI

struct TranscriptCleanupPromptsManagerView: View {
    let appState: AppState
    let controller: MuesliController
    let onClose: () -> Void

    @State private var isCreatingPrompt = false
    @State private var editingPromptID: String?
    @State private var draftPromptName = ""
    @State private var draftPrompt = ""
    @State private var nameValidationMessage: String?
    @State private var showPromptValidationError = false
    @State private var promptToDelete: CustomTranscriptCleanupPrompt?
    @State private var operationErrorMessage: String?

    private var activePromptID: String {
        appState.config.activeTranscriptCleanupPromptId
    }

    private var builtInPresets: [TranscriptCleanupPromptPreset] {
        TranscriptCleanupPrompts.builtIns
    }

    private var customPresets: [CustomTranscriptCleanupPrompt] {
        appState.config.customTranscriptCleanupPrompts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    Text("Built-in styles are read-only. Duplicate one to customize it.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)

                    presetSection(title: "Built-in Styles") {
                        VStack(spacing: MuesliTheme.spacing8) {
                            ForEach(builtInPresets) { preset in
                                builtInPresetRow(preset)
                            }
                        }
                    }

                    presetSection(title: "Custom Styles") {
                        if customPresets.isEmpty {
                            emptyState
                        } else {
                            VStack(spacing: MuesliTheme.spacing8) {
                                ForEach(customPresets) { preset in
                                    customPresetRow(preset)
                                }
                            }
                        }
                    }

                    if isCreatingPrompt || editingPromptID != nil {
                        promptEditor
                    }

                    if let operationErrorMessage {
                        Text(operationErrorMessage)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.danger)
                            .accessibilityLabel("Style settings error: \(operationErrorMessage)")
                    }
                }
                .padding(.bottom, MuesliTheme.spacing4)
            }
        }
        .padding(MuesliTheme.spacing24)
        .frame(minWidth: 760, minHeight: 560)
        .background(MuesliTheme.backgroundBase)
        .alert(
            "Delete \"\(promptToDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { promptToDelete != nil },
                set: { if !$0 { promptToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                promptToDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard let preset = promptToDelete else { return }
                do {
                    try controller.deleteTranscriptCleanupPrompt(id: preset.id)
                    if editingPromptID == preset.id {
                        resetPromptEditor()
                    }
                    promptToDelete = nil
                    operationErrorMessage = nil
                } catch {
                    operationErrorMessage = persistenceError(error)
                }
            }
        } message: {
            Text(deletionImpactMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Manage Cleanup Styles")
                    .font(MuesliTheme.title2())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Create reusable prompts for local and cloud dictation cleanup.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            Spacer()

            HStack(spacing: MuesliTheme.spacing8) {
                if isCreatingPrompt || editingPromptID != nil {
                    actionButton("Cancel", systemImage: "xmark") {
                        resetPromptEditor()
                    }
                } else {
                    actionButton("New style", systemImage: "plus") {
                        beginCreatingPrompt()
                    }
                }

                actionButton("Done", systemImage: "checkmark") {
                    onClose()
                }
                .disabled(isEditingPromptInProgress)
                .opacity(isEditingPromptInProgress ? 0.55 : 1)
                .help(isEditingPromptInProgress ? "Finish or cancel prompt editing before closing." : "Close prompt manager")
            }
        }
    }

    private func presetSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text(title.uppercased())
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(MuesliTheme.textTertiary)
            content()
        }
    }

    private var emptyState: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 11))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("No custom cleanup styles yet.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, 10)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func builtInPresetRow(_ preset: TranscriptCleanupPromptPreset) -> some View {
        presetRow(
            name: preset.name,
            prompt: preset.prompt,
            isActive: activePromptID == preset.id,
            systemImage: "sparkles"
        ) {
            actionButton("Use", systemImage: "checkmark") {
                selectStyle(preset.id)
            }
            .disabled(activePromptID == preset.id)

            actionButton("Duplicate", systemImage: "doc.on.doc") {
                beginDuplicatingPrompt(name: preset.name, prompt: preset.prompt)
            }
        }
    }

    private func customPresetRow(_ preset: CustomTranscriptCleanupPrompt) -> some View {
        presetRow(
            name: preset.name,
            prompt: preset.prompt,
            isActive: activePromptID == preset.id,
            systemImage: "text.badge.checkmark"
        ) {
            actionButton("Use", systemImage: "checkmark") {
                selectStyle(preset.id)
            }
            .disabled(activePromptID == preset.id)

            actionButton("Edit", systemImage: "pencil") {
                beginEditingPrompt(preset)
            }

            actionButton("Delete", systemImage: "trash", role: .destructive) {
                promptToDelete = preset
            }
        }
    }

    private func presetRow<Actions: View>(
        name: String,
        prompt: String,
        isActive: Bool,
        systemImage: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: systemImage)
                            .font(.system(size: 10))
                            .foregroundStyle(MuesliTheme.accent)
                        Text(name)
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        if isActive {
                            Text("Active")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(MuesliTheme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MuesliTheme.accentSubtle)
                                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
                        }
                    }
                    Text(prompt)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                HStack(spacing: MuesliTheme.spacing8) {
                    actions()
                }
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous)
                .strokeBorder(isActive ? MuesliTheme.accent.opacity(0.35) : MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Text(isCreatingPrompt ? "New style" : "Edit style")
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(MuesliTheme.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                TextField("Context-aware cleanup", text: $draftPromptName)
                    .textFieldStyle(.roundedBorder)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                nameValidationMessage == nil ? .clear : MuesliTheme.danger.opacity(0.75),
                                lineWidth: 1
                            )
                    }
                    .onChange(of: draftPromptName) { _, newValue in
                        if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            nameValidationMessage = nil
                        }
                    }
                if let nameValidationMessage {
                    Text(nameValidationMessage)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.danger)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                TextEditor(text: $draftPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
                    .padding(MuesliTheme.spacing8)
                    .background(MuesliTheme.backgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous)
                            .strokeBorder(
                                showPromptValidationError ? MuesliTheme.danger.opacity(0.75) : MuesliTheme.surfaceBorder,
                                lineWidth: 1
                            )
                    )
                    .onChange(of: draftPrompt) { _, newValue in
                        if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            showPromptValidationError = false
                        }
                    }
                if showPromptValidationError {
                    Text("Enter cleanup instructions for this style.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.danger)
                }
            }

            HStack {
                Spacer()
                actionButton(
                    isCreatingPrompt ? "Create style" : "Save changes",
                    systemImage: isCreatingPrompt ? "plus.circle" : "checkmark.circle"
                ) {
                    savePromptEditor()
                }
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func beginCreatingPrompt() {
        isCreatingPrompt = true
        editingPromptID = nil
        draftPromptName = ""
        draftPrompt = ""
        clearValidationErrors()
    }

    private func beginDuplicatingPrompt(name: String, prompt: String) {
        isCreatingPrompt = true
        editingPromptID = nil
        draftPromptName = suggestedUniqueName(for: "\(name) Copy")
        draftPrompt = prompt
        clearValidationErrors()
    }

    private func beginEditingPrompt(_ preset: CustomTranscriptCleanupPrompt) {
        isCreatingPrompt = false
        editingPromptID = preset.id
        draftPromptName = preset.name
        draftPrompt = preset.prompt
        clearValidationErrors()
    }

    private func resetPromptEditor() {
        isCreatingPrompt = false
        editingPromptID = nil
        draftPromptName = ""
        draftPrompt = ""
        clearValidationErrors()
    }

    private func savePromptEditor() {
        let trimmedName = draftPromptName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try DictationStyleSettingsModel.validateStyle(
                name: trimmedName,
                instructions: trimmedPrompt,
                excludingID: editingPromptID,
                config: appState.config
            )
            if let editingPromptID {
                try controller.updateTranscriptCleanupPrompt(
                    id: editingPromptID,
                    name: trimmedName,
                    prompt: trimmedPrompt
                )
            } else {
                try controller.createTranscriptCleanupPrompt(
                    name: trimmedName,
                    prompt: trimmedPrompt
                )
            }
            operationErrorMessage = nil
            resetPromptEditor()
        } catch let error as DictationStyleSettingsError {
            switch error {
            case .missingStyleName, .duplicateStyleName:
                nameValidationMessage = error.localizedDescription
            case .missingStyleInstructions:
                showPromptValidationError = true
            default:
                operationErrorMessage = error.localizedDescription
            }
        } catch {
            operationErrorMessage = persistenceError(error)
        }
    }

    private func selectStyle(_ id: String) {
        do {
            try controller.selectTranscriptCleanupPrompt(id: id)
            operationErrorMessage = nil
        } catch {
            operationErrorMessage = persistenceError(error)
        }
    }

    private var deletionImpactMessage: String {
        guard let promptToDelete else { return "This custom style will be permanently removed." }
        return DictationStyleSettingsModel.deletionImpact(
            styleID: promptToDelete.id,
            in: appState.config
        ).confirmationMessage
    }

    private func persistenceError(_ error: Error) -> String {
        "Could not save cleanup styles. Your previous settings are unchanged. \(error.localizedDescription)"
    }

    private var isEditingPromptInProgress: Bool {
        isCreatingPrompt || editingPromptID != nil
    }

    private func clearValidationErrors() {
        nameValidationMessage = nil
        showPromptValidationError = false
    }

    private func presetNameExists(_ name: String, excludingID: String?) -> Bool {
        DictationStyleSettingsModel.hasStyleNamed(name, excludingID: excludingID, in: appState.config)
    }

    private func suggestedUniqueName(for baseName: String) -> String {
        let trimmedBase = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackBase = trimmedBase.isEmpty ? "Custom Cleanup" : trimmedBase
        if !presetNameExists(fallbackBase, excludingID: nil) {
            return fallbackBase
        }
        for suffix in 2...99 {
            let candidate = "\(fallbackBase) \(suffix)"
            if !presetNameExists(candidate, excludingID: nil) {
                return candidate
            }
        }
        return "\(fallbackBase) \(UUID().uuidString.prefix(4))"
    }

    private func actionButton(
        _ title: String,
        systemImage: String? = nil,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isDestructive = role == .destructive
        return Button(role: role, action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isDestructive ? MuesliTheme.danger : MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .frame(height: 28)
            .background(isDestructive ? MuesliTheme.danger.opacity(0.1) : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous)
                    .strokeBorder(
                        isDestructive ? MuesliTheme.danger.opacity(0.2) : MuesliTheme.surfaceBorder,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
