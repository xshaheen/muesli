import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WritingStylesView: View {
    private enum Section: Hashable { case global, groups, styles, exceptions }
    private struct PendingStyleDeletion {
        let styleID: String
        let replacementID: String
    }

    let appState: AppState
    let controller: MuesliController
    let onClose: () -> Void

    @State private var draft: AppConfig
    @State private var selectedSection: Section? = .global
    @State private var selectedGroupID: String?
    @State private var groupName = ""
    @State private var matcherInput = ""
    @State private var matcherKind: DictationStyleMatcherKind = .bundleID
    @State private var exceptionInput = ""
    @State private var exceptionKind: DictationStyleMatcherKind = .bundleID
    @State private var errorMessage: String?
    @State private var importPreview: DictationStyleRulesetPreview?
    @State private var showCloseConfirmation = false
    @State private var isDirty = false
    @State private var editingStyleID: String?
    @State private var styleDraftName = ""
    @State private var styleDraftPrompt = ""
    @State private var pendingGroupDeletionID: String?
    @State private var pendingStyleDeletion: PendingStyleDeletion?

    init(appState: AppState, controller: MuesliController, onClose: @escaping () -> Void) {
        self.appState = appState
        self.controller = controller
        self.onClose = onClose
        _draft = State(initialValue: appState.config)
    }

    private var styles: [TranscriptCleanupPromptPreset] {
        TranscriptCleanupPrompts.presets(custom: draft.customTranscriptCleanupPrompts)
    }

    private var selectedGroup: DictationStyleGroup? {
        draft.dictationStyleGroups.first { $0.id == selectedGroupID }
    }

    private var validationMessage: String? {
        do { _ = try DictationStyleResolver.prepareCanonicalConfiguration(draft); return nil }
        catch { return error.localizedDescription }
    }

    private func canSave(_ validationMessage: String?) -> Bool {
        hasUnsavedChanges && validationMessage == nil
    }

    private var hasUnappliedStyleChanges: Bool {
        DictationStyleSettingsModel.hasUnappliedStyleChanges(
            styleID: editingStyleID,
            name: styleDraftName,
            instructions: styleDraftPrompt,
            in: draft
        )
    }

    private var hasUnsavedChanges: Bool {
        isDirty || hasUnappliedStyleChanges
    }

    private var appCandidates: [DictationStyleAppCandidate] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = DictationStyleResolver.normalizeBundleID(app.bundleIdentifier),
                  bundleID != DictationStyleResolver.normalizeBundleID(Bundle.main.bundleIdentifier),
                  seen.insert(bundleID).inserted
            else { return nil }
            return DictationStyleAppCandidate(bundleID: bundleID, displayName: app.localizedName ?? bundleID)
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var knownTargets: [DictationStyleTarget] {
        DictationStyleSettingsModel.knownTargets(
            appBundleIDs: appCandidates.map(\.bundleID),
            groups: draft.dictationStyleGroups,
            exactExceptions: draft.dictationStyleExactExceptions
        )
    }

    var body: some View {
        let validationMessage = validationMessage
        VStack(spacing: 0) {
            header(validationMessage: validationMessage)
            Divider().background(MuesliTheme.surfaceBorder)
            HStack(spacing: 0) {
                sidebar
                Divider().background(MuesliTheme.surfaceBorder)
                detail(validationMessage: validationMessage)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(MuesliTheme.backgroundBase)
        .confirmationDialog("Discard unsaved Writing Styles changes?", isPresented: $showCloseConfirmation, titleVisibility: .visible) {
            Button("Save") { saveAndClose() }.disabled(!canSave(validationMessage))
            Button("Discard", role: .destructive) { onClose() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your draft has not been applied to dictation yet.")
        }
        .confirmationDialog(
            pendingGroupDeletionID.flatMap { id in draft.dictationStyleGroups.first(where: { $0.id == id })?.name }.map { "Delete \($0)?" } ?? "Delete group?",
            isPresented: Binding(get: { pendingGroupDeletionID != nil }, set: { if !$0 { pendingGroupDeletionID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete group", role: .destructive) {
                guard let id = pendingGroupDeletionID else { return }
                mutate { $0 = DictationStyleSettingsModel.deletingGroup(id: id, from: $0) }
                selectedGroupID = nil
                pendingGroupDeletionID = nil
            }
            Button("Cancel", role: .cancel) { pendingGroupDeletionID = nil }
        } message: {
            Text(groupDeletionMessage)
        }
        .confirmationDialog(
            "Replace assignments and delete this style?",
            isPresented: Binding(get: { pendingStyleDeletion != nil }, set: { if !$0 { pendingStyleDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Replace and delete", role: .destructive) {
                guard let pendingStyleDeletion else { return }
                deleteStyle(pendingStyleDeletion.styleID, replacingWith: pendingStyleDeletion.replacementID)
                self.pendingStyleDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingStyleDeletion = nil }
        } message: {
            Text(styleDeletionMessage)
        }
        .sheet(isPresented: Binding(get: { importPreview != nil }, set: { if !$0 { importPreview = nil } })) {
            if let importPreview { importPreviewSheet(importPreview) }
        }
    }

    private func header(validationMessage: String?) -> some View {
        HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Writing Styles").font(MuesliTheme.title2()).foregroundStyle(MuesliTheme.textPrimary)
                Text("Choose a global style, reusable app groups, and exact exceptions.")
                    .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
            }
            Spacer()
            Button("Import", systemImage: "square.and.arrow.down", action: importRuleset)
                .accessibilityHint("Choose a Writing Styles JSON file and review its replacement preview")
                .disabled(hasUnsavedChanges)
            Button("Export", systemImage: "square.and.arrow.up", action: exportRuleset)
                .accessibilityHint("Save the current Writing Styles configuration as JSON")
                .disabled(hasUnsavedChanges)
            Button("Cancel", action: cancelDraft).disabled(!hasUnsavedChanges)
            Button("Save", action: saveDraft).disabled(!canSave(validationMessage)).keyboardShortcut("s", modifiers: .command)
            Button("Done", action: requestClose).keyboardShortcut(.defaultAction)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(MuesliTheme.spacing16)
    }

    private var sidebar: some View {
        List(selection: $selectedSection) {
            Label("Global", systemImage: "globe").tag(Section.global)
            Label("Groups", systemImage: "rectangle.3.group").tag(Section.groups)
            Label("Styles", systemImage: "text.badge.star").tag(Section.styles)
            Label("Exceptions", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90").tag(Section.exceptions)
        }
        .listStyle(.sidebar)
        .frame(width: 180)
        .accessibilityLabel("Writing Styles navigation")
    }

    @ViewBuilder private func detail(validationMessage: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                if let errorMessage { statusMessage(errorMessage, color: MuesliTheme.danger) }
                if let validationMessage { statusMessage(validationMessage, color: MuesliTheme.danger) }
                if !draft.adaptiveDictationStylesEnabled {
                    statusMessage("Adaptive Styles is off. Your global default remains active; groups and exceptions are saved but inactive.", color: MuesliTheme.textSecondary)
                }
                switch selectedSection ?? .global {
                case .global: globalPane
                case .groups: groupsPane
                case .styles: stylesPane
                case .exceptions: exceptionsPane
                }
            }
            .padding(MuesliTheme.spacing20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var globalPane: some View {
        pane(title: "Global default", subtitle: "Used when no valid exact exception or group matches.") {
            Picker("Global style", selection: Binding(get: { draft.activeTranscriptCleanupPromptId }, set: { setGlobalStyle($0) })) {
                ForEach(styles) { style in Text(style.name).tag(style.id) }
            }
            .accessibilityHint("Changing a global style also updates its cleanup instructions")
            Text(draft.postProcessorSystemPrompt).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(MuesliTheme.textSecondary).textSelection(.enabled)
                .padding(MuesliTheme.spacing12).background(MuesliTheme.backgroundRaised)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
    }

    private var groupsPane: some View {
        pane(title: "App groups", subtitle: "Groups assign one style to exact or wildcard app and website targets.") {
            HStack {
                TextField("New group name", text: $groupName).textFieldStyle(.roundedBorder)
                Button("Add group", action: addGroup).disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if draft.dictationStyleGroups.isEmpty {
                Text("No groups yet. Create one or turn on Adaptive Styles to seed editable starter groups.")
                    .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
            }
            ForEach(draft.dictationStyleGroups) { group in
                groupRow(group)
            }
            if let selectedGroup { selectedGroupPane(selectedGroup) }
        }
    }

    private func groupRow(_ group: DictationStyleGroup) -> some View {
        HStack {
            Button {
                selectedGroupID = group.id
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(MuesliTheme.captionMedium())
                    Text("\(group.matchers.count) matcher\(group.matchers.count == 1 ? "" : "s") · \(styleName(group.styleID))")
                        .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).accessibilityLabel("Edit group \(group.name)")
            Button { duplicateGroup(group.id) } label: { Image(systemName: "plus.square.on.square") }
                .accessibilityLabel("Duplicate group \(group.name)")
                .accessibilityHint("Creates a copy with the same style and no matchers")
            Button(role: .destructive) { pendingGroupDeletionID = group.id } label: { Image(systemName: "trash") }
                .accessibilityLabel("Delete group \(group.name)")
            if selectedGroupID == group.id { Image(systemName: "checkmark").foregroundStyle(MuesliTheme.accent) }
        }
        .padding(MuesliTheme.spacing12).background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    private func selectedGroupPane(_ group: DictationStyleGroup) -> some View {
        let candidates = appCandidates
        return VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Divider()
            Text("Selected group").font(MuesliTheme.headline())
            TextField("Group name", text: bindingForGroupName(group.id)).textFieldStyle(.roundedBorder)
            Picker("Group style", selection: bindingForGroupStyle(group.id)) {
                ForEach(styles) { style in Text(style.name).tag(style.id) }
            }
            Picker("Matcher type", selection: $matcherKind) {
                Text("Application").tag(DictationStyleMatcherKind.bundleID)
                Text("Website").tag(DictationStyleMatcherKind.hostname)
            }
            .pickerStyle(.segmented)
            if matcherKind == .bundleID {
                HStack {
                    Menu("Add running app") {
                        if candidates.isEmpty {
                            Text("No applications available")
                        } else {
                            ForEach(candidates) { candidate in
                                Button("\(candidate.displayName) — \(candidate.bundleID)") {
                                    addApplicationMatcher(candidate, to: group.id)
                                }
                            }
                        }
                    }
                    .accessibilityHint("Adds the app's exact local bundle identifier")
                    Button("Choose Application…") { chooseApplication(for: group.id) }
                        .accessibilityHint("Opens a file picker for a macOS application")
                }
            }
            HStack {
                TextField(matcherKind == .bundleID ? "com.example.*" : "*.example.com", text: $matcherInput).textFieldStyle(.roundedBorder)
                Button("Add matcher") { addMatcher(to: group.id) }.disabled(matcherInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(group.matchers) { matcher in
                HStack {
                    Text(matcher.kind == .bundleID ? "App" : "Website").font(MuesliTheme.captionMedium())
                    Text(matcher.pattern).font(.system(size: 12, design: .monospaced)).foregroundStyle(MuesliTheme.textSecondary)
                    Spacer()
                    Button(role: .destructive) { removeMatcher(matcher.id, from: group.id) } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Remove matcher \(matcher.pattern)")
                }
                .padding(.vertical, 4)
                let matches = previewTargets(for: matcher)
                Text(matches.isEmpty ? "Known matches: none" : "Known matches: \(matches.joined(separator: ", "))")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .accessibilityLabel("Known matches for \(matcher.pattern): \(matches.isEmpty ? "none" : matches.joined(separator: ", "))")
            }
        }
        .padding(MuesliTheme.spacing16).background(MuesliTheme.surfacePrimary.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
    }

    private var exceptionsPane: some View {
        pane(title: "Exact exceptions", subtitle: "Exceptions are independent of groups and win for one exact app or website target.") {
            Picker("Exception type", selection: $exceptionKind) {
                Text("Application").tag(DictationStyleMatcherKind.bundleID)
                Text("Website").tag(DictationStyleMatcherKind.hostname)
            }
            .pickerStyle(.segmented)
            HStack {
                TextField(exceptionKind == .bundleID ? "com.example.app" : "docs.example.com", text: $exceptionInput).textFieldStyle(.roundedBorder)
                Menu("Add exception") {
                    ForEach(styles) { style in Button(style.name) { addException(style.id) } }
                }
            }
            if draft.dictationStyleExactExceptions.isEmpty {
                Text("No exact exceptions. Add one only when a target must differ from its group.")
                    .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
            }
            ForEach(draft.dictationStyleExactExceptions) { exception in
                let effective = DictationStyleSettingsModel.effectiveState(config: draft, bundleID: exception.kind == .bundleID ? exception.target : nil, hostname: exception.kind == .hostname ? exception.target : nil)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exception.target).font(MuesliTheme.captionMedium())
                        Text("Effective: \(effective.styleName) · \(effective.sourceLabel)").font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                    }
                    Spacer()
                    Picker("Style for \(exception.target)", selection: bindingForExceptionStyle(exception.id)) {
                        ForEach(styles) { style in Text(style.name).tag(style.id) }
                    }.labelsHidden()
                    Button(role: .destructive) { removeException(exception.id) } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Remove exact exception for \(exception.target)")
                }
                .padding(MuesliTheme.spacing12).background(MuesliTheme.backgroundRaised)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var stylesPane: some View {
        pane(title: "Style library", subtitle: "Built-in styles are read-only. Duplicate one before editing it.") {
            ForEach(TranscriptCleanupPrompts.builtIns) { style in
                styleRow(style.name, prompt: style.prompt, custom: false, id: style.id)
            }
            ForEach(draft.customTranscriptCleanupPrompts) { style in
                styleRow(style.name, prompt: style.prompt, custom: true, id: style.id)
            }
            if editingStyleID != nil { styleEditor }
        }
    }

    private func styleRow(_ name: String, prompt: String, custom: Bool, id: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(MuesliTheme.captionMedium())
                Text(prompt).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary).lineLimit(2)
            }
            Spacer()
            if !custom {
                Button("Duplicate") { duplicateStyle(name: name, prompt: prompt) }
            } else {
                Button("Edit") { beginEditingStyle(id) }
                if styleIsReferenced(id) {
                    Menu("Replace and delete") {
                        ForEach(styles.filter { $0.id != id }) { replacement in
                            Button(replacement.name) { pendingStyleDeletion = PendingStyleDeletion(styleID: id, replacementID: replacement.id) }
                        }
                    }
                    .accessibilityLabel("Choose a replacement before deleting custom style \(name)")
                    Text(styleDeletionImpact(id).confirmationMessage)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(maxWidth: 240, alignment: .leading)
                } else {
                    Button(role: .destructive) { deleteStyle(id) } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Delete custom style \(name)")
                }
            }
        }
        .padding(MuesliTheme.spacing12).background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    private var styleEditor: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text("Edit custom style").font(MuesliTheme.captionMedium())
            TextField("Style name", text: $styleDraftName).textFieldStyle(.roundedBorder)
            TextEditor(text: $styleDraftPrompt).font(.system(size: 12, design: .monospaced))
                .accessibilityLabel("Style instructions")
                .accessibilityHint("Describe how Muesli should clean up dictation that uses this style")
                .frame(minHeight: 120).padding(MuesliTheme.spacing8).background(MuesliTheme.backgroundBase)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall).strokeBorder(MuesliTheme.surfaceBorder))
            HStack { Spacer(); Button("Cancel") { editingStyleID = nil }; Button("Apply style changes") { saveEditedStyle() } }
        }
        .padding(MuesliTheme.spacing12).background(MuesliTheme.surfacePrimary.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    private func pane<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Text(title).font(MuesliTheme.headline()).foregroundStyle(MuesliTheme.textPrimary)
            Text(subtitle).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
            content()
        }
    }

    private func statusMessage(_ text: String, color: Color) -> some View {
        Text(text).font(MuesliTheme.caption()).foregroundStyle(color)
            .padding(MuesliTheme.spacing12).background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .accessibilityLabel(text)
            .focusable()
    }

    private func setGlobalStyle(_ id: String) { mutate { candidate in
        guard let style = TranscriptCleanupPrompts.resolveOptional(id: id, custom: candidate.customTranscriptCleanupPrompts) else { return }
        candidate.activeTranscriptCleanupPromptId = style.id; candidate.postProcessorSystemPrompt = style.prompt
    } }
    private func addGroup() {
        do {
            let id = UUID().uuidString
            let candidate = try DictationStyleSettingsModel.addingGroup(name: groupName, styleID: draft.activeTranscriptCleanupPromptId, id: id, to: draft)
            mutate { $0 = candidate }
            selectedGroupID = id
            groupName = ""
        } catch { errorMessage = error.localizedDescription }
    }
    private func duplicateGroup(_ id: String) {
        do {
            let newID = UUID().uuidString
            let candidate = try DictationStyleSettingsModel.duplicatingGroup(id: id, newID: newID, in: draft)
            mutate { $0 = candidate }
            selectedGroupID = newID
        } catch { errorMessage = error.localizedDescription }
    }
    private func addMatcher(to groupID: String) {
        let input = matcherInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pattern = DictationStyleResolver.canonicalPattern(input, kind: matcherKind),
              let index = draft.dictationStyleGroups.firstIndex(where: { $0.id == groupID })
        else {
            errorMessage = "Enter a valid full app or hostname pattern."
            return
        }
        mutate { candidate in
            candidate.dictationStyleGroups[index].matchers.append(
                DictationStyleMatcher(id: UUID().uuidString, kind: matcherKind, pattern: pattern)
            )
        }
        matcherInput = ""
    }
    private func removeMatcher(_ matcherID: String, from groupID: String) { mutate { candidate in guard let index = candidate.dictationStyleGroups.firstIndex(where: { $0.id == groupID }) else { return }; candidate.dictationStyleGroups[index].matchers.removeAll { $0.id == matcherID } } }
    private func addException(_ styleID: String) {
        let input = exceptionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = exceptionKind == .hostname
            ? DictationStyleSettingsModel.normalizedHostnameInput(input)
            : DictationStyleResolver.normalizeBundleID(input)
        else {
            errorMessage = "Enter one exact app bundle ID or hostname."
            return
        }
        mutate { candidate in
            candidate.dictationStyleExactExceptions.append(DictationStyleExactException(
                id: UUID().uuidString,
                kind: exceptionKind,
                target: target,
                styleID: styleID
            ))
        }
        exceptionInput = ""
    }
    private func removeException(_ id: String) { mutate { $0.dictationStyleExactExceptions.removeAll { $0.id == id } } }
    private func duplicateStyle(name: String, prompt: String) { mutate { candidate in candidate.customTranscriptCleanupPrompts.append(CustomTranscriptCleanupPrompt(id: UUID().uuidString, name: suggestedStyleName(name, in: candidate), prompt: prompt)) } }
    private func beginEditingStyle(_ id: String) { guard let style = draft.customTranscriptCleanupPrompts.first(where: { $0.id == id }) else { return }; editingStyleID = id; styleDraftName = style.name; styleDraftPrompt = style.prompt }
    private func saveEditedStyle() { guard let editingStyleID else { return }; do { try DictationStyleSettingsModel.validateStyle(name: styleDraftName, instructions: styleDraftPrompt, excludingID: editingStyleID, config: draft); mutate { candidate in guard let index = candidate.customTranscriptCleanupPrompts.firstIndex(where: { $0.id == editingStyleID }) else { return }; candidate.customTranscriptCleanupPrompts[index].name = styleDraftName.trimmingCharacters(in: .whitespacesAndNewlines); candidate.customTranscriptCleanupPrompts[index].prompt = styleDraftPrompt.trimmingCharacters(in: .whitespacesAndNewlines); if candidate.activeTranscriptCleanupPromptId == editingStyleID { candidate.postProcessorSystemPrompt = candidate.customTranscriptCleanupPrompts[index].prompt } }; self.editingStyleID = nil } catch { errorMessage = error.localizedDescription } }
    private func styleIsReferenced(_ id: String) -> Bool { draft.activeTranscriptCleanupPromptId == id || draft.dictationStyleGroups.contains { $0.styleID == id } || draft.dictationStyleExactExceptions.contains { $0.styleID == id } }
    private func styleDeletionImpact(_ id: String) -> DictationStyleDeletionImpact { DictationStyleSettingsModel.deletionImpact(styleID: id, in: draft) }
    private func deleteStyle(_ id: String, replacingWith replacementID: String? = nil) {
        guard !styleIsReferenced(id) || replacementID != nil else { errorMessage = "Choose a replacement style before deleting a referenced custom style."; return }
        mutate { candidate in
            if let replacementID, let replacement = TranscriptCleanupPrompts.resolveOptional(id: replacementID, custom: candidate.customTranscriptCleanupPrompts) {
                for index in candidate.dictationStyleGroups.indices where candidate.dictationStyleGroups[index].styleID == id {
                    candidate.dictationStyleGroups[index].styleID = replacement.id
                }
                for index in candidate.dictationStyleExactExceptions.indices where candidate.dictationStyleExactExceptions[index].styleID == id {
                    candidate.dictationStyleExactExceptions[index].styleID = replacement.id
                }
                if candidate.activeTranscriptCleanupPromptId == id { candidate.activeTranscriptCleanupPromptId = replacement.id; candidate.postProcessorSystemPrompt = replacement.prompt }
            }
            candidate.customTranscriptCleanupPrompts.removeAll { $0.id == id }
        }
    }
    private func mutate(_ change: (inout AppConfig) -> Void) { change(&draft); isDirty = true; errorMessage = nil }
    private func cancelDraft() { draft = appState.config; isDirty = false; editingStyleID = nil; styleDraftName = ""; styleDraftPrompt = ""; errorMessage = nil }
    private func requestClose() { hasUnsavedChanges ? (showCloseConfirmation = true) : onClose() }
    private func saveAndClose() { saveDraft(); if errorMessage == nil { onClose() } }
    private func saveDraft() {
        do {
            try applyPendingStyleEdits()
            try controller.updateDictationStyleConfiguration { $0 = draft }
            draft = appState.config
            isDirty = false
            errorMessage = nil
        } catch {
            errorMessage = "Could not save Writing Styles. Your previous settings are unchanged. \(error.localizedDescription)"
        }
    }

    private func applyPendingStyleEdits() throws {
        guard let editingStyleID, hasUnappliedStyleChanges else { return }
        try DictationStyleSettingsModel.validateStyle(
            name: styleDraftName,
            instructions: styleDraftPrompt,
            excludingID: editingStyleID,
            config: draft
        )
        guard let index = draft.customTranscriptCleanupPrompts.firstIndex(where: { $0.id == editingStyleID }) else { return }
        draft.customTranscriptCleanupPrompts[index].name = styleDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.customTranscriptCleanupPrompts[index].prompt = styleDraftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.activeTranscriptCleanupPromptId == editingStyleID {
            draft.postProcessorSystemPrompt = draft.customTranscriptCleanupPrompts[index].prompt
        }
        self.editingStyleID = nil
        isDirty = true
    }
    private func styleName(_ id: String) -> String { styles.first(where: { $0.id == id })?.name ?? "Missing style" }
    private func suggestedStyleName(_ base: String, in config: AppConfig) -> String { var suffix = 2; var candidate = "\(base) Copy"; while DictationStyleSettingsModel.hasStyleNamed(candidate, excludingID: nil, in: config) { candidate = "\(base) Copy \(suffix)"; suffix += 1 }; return candidate }
    private var groupDeletionMessage: String {
        guard let id = pendingGroupDeletionID,
              let impact = try? DictationStyleSettingsModel.groupDeletionImpact(id: id, knownTargets: knownTargets, in: draft)
        else { return "The group and its matchers will be removed. Independent exceptions and styles remain." }
        return impact.confirmationMessage
    }
    private var styleDeletionMessage: String {
        guard let pendingStyleDeletion else { return "The custom style will be removed after its assignments are replaced." }
        return styleDeletionImpact(pendingStyleDeletion.styleID).confirmationMessage
    }
    private func previewTargets(for matcher: DictationStyleMatcher) -> [String] {
        Array(Set(knownTargets.compactMap { target in
            guard DictationStyleResolver.matches(matcher, target: target) else { return nil }
            return matcher.kind == .bundleID ? target.bundleID : target.hostname
        })).sorted()
    }
    private func addApplicationMatcher(_ app: DictationStyleAppCandidate, to groupID: String) {
        matcherKind = .bundleID
        matcherInput = app.bundleID
        addMatcher(to: groupID)
    }
    private func chooseApplication(for groupID: String) {
        let panel = NSOpenPanel()
        panel.title = "Choose an application for Writing Styles"
        panel.prompt = "Choose Application"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { addApplicationMatcher(try DictationStyleSettingsModel.applicationCandidate(at: url), to: groupID) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    private func bindingForGroupName(_ id: String) -> Binding<String> {
        Binding(get: { draft.dictationStyleGroups.first(where: { $0.id == id })?.name ?? "" }, set: { value in
            mutate { candidate in
                guard let index = candidate.dictationStyleGroups.firstIndex(where: { $0.id == id }) else { return }
                candidate.dictationStyleGroups[index].name = value
            }
        })
    }
    private func bindingForGroupStyle(_ id: String) -> Binding<String> {
        Binding(get: { draft.dictationStyleGroups.first(where: { $0.id == id })?.styleID ?? "" }, set: { value in
            mutate { candidate in
                guard let index = candidate.dictationStyleGroups.firstIndex(where: { $0.id == id }) else { return }
                candidate.dictationStyleGroups[index].styleID = value
            }
        })
    }
    private func bindingForExceptionStyle(_ id: String) -> Binding<String> {
        Binding(get: { draft.dictationStyleExactExceptions.first(where: { $0.id == id })?.styleID ?? "" }, set: { value in
            mutate { candidate in
                guard let index = candidate.dictationStyleExactExceptions.firstIndex(where: { $0.id == id }) else { return }
                candidate.dictationStyleExactExceptions[index].styleID = value
            }
        })
    }

    private func importRuleset() {
        let panel = NSOpenPanel(); panel.title = "Import Writing Styles"; panel.prompt = "Import"; panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { response in guard response == .OK, let url = panel.url else { return }; do { let ruleset = try DictationStyleRulesetCodec.decode(contentsOf: url); importPreview = try DictationStyleSettingsModel.previewingRulesetReplacement(ruleset, replacing: appState.config) } catch { errorMessage = "Could not import Writing Styles. \(error.localizedDescription)" } }
    }
    private func exportRuleset() {
        let panel = NSSavePanel(); panel.title = "Export Writing Styles"; panel.prompt = "Export"; panel.nameFieldStringValue = "muesli-writing-styles.json"; panel.allowedContentTypes = [.json]
        panel.begin { response in guard response == .OK, let url = panel.url else { return }; do { try DictationStyleRulesetCodec.encode(appState.config).write(to: url, options: .atomic); errorMessage = "Exported Writing Styles. The file includes configured identities and custom instructions; share it intentionally." } catch { errorMessage = "Could not export Writing Styles. \(error.localizedDescription)" } }
    }
    private func importPreviewSheet(_ preview: DictationStyleRulesetPreview) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            Text("Review Writing Styles import").font(MuesliTheme.title2())
            Text(preview.privacyWarningText).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.danger).accessibilityLabel(preview.privacyWarningText)
            Text("\(preview.additions.count) additions · \(preview.changes.count) changes · \(preview.removals.count) removals").font(MuesliTheme.callout())
            Text(preview.rulesWillBeActive ? "Imported group routing will be active immediately." : "Imported groups will remain inactive until Adaptive Styles is enabled locally.").font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
            ScrollView { VStack(alignment: .leading, spacing: MuesliTheme.spacing8) { ForEach(preview.additions + preview.changes + preview.removals + preview.effectiveChanges, id: \.self) { Text($0).font(MuesliTheme.caption()) }; Text("Global instructions").font(MuesliTheme.captionMedium()); Text(preview.ruleset.globalDefault.prompt).font(.system(size: 12, design: .monospaced)).textSelection(.enabled); ForEach(preview.ruleset.customStyles) { style in Text(style.name).font(MuesliTheme.captionMedium()); Text(style.prompt).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) } } }
            HStack { Spacer(); Button("Cancel") { importPreview = nil }; Button("Replace Writing Styles") { do { try controller.replaceDictationStyleRuleset(preview); draft = appState.config; isDirty = false; importPreview = nil } catch { errorMessage = "Could not replace Writing Styles. \(error.localizedDescription)"; importPreview = nil } }.keyboardShortcut(.defaultAction) }
        }.padding(MuesliTheme.spacing24).frame(width: 620, height: 480).background(MuesliTheme.backgroundBase)
    }
}
