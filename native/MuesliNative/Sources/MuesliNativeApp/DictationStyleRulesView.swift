import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DictationStyleRulesView: View {
    let appState: AppState
    let controller: MuesliController
    let onClose: () -> Void

    @State private var domainInput = ""
    @State private var errorMessage: String?

    private var styles: [TranscriptCleanupPromptPreset] {
        TranscriptCleanupPrompts.presets(custom: appState.config.customTranscriptCleanupPrompts)
    }

    private var appCandidates: [DictationStyleAppCandidate] {
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> DictationStyleAppCandidate? in
            guard let bundleID = DictationStyleResolver.normalizeBundleID(app.bundleIdentifier),
                  bundleID != DictationStyleResolver.normalizeBundleID(Bundle.main.bundleIdentifier) else { return nil }
            return DictationStyleAppCandidate(
                bundleID: bundleID,
                displayName: app.localizedName ?? bundleID
            )
        }
        let recent = appState.config.dictationStyleAppRules.map {
            DictationStyleAppCandidate(
                bundleID: $0.bundleID,
                displayName: $0.displayName.isEmpty ? $0.bundleID : $0.displayName
            )
        }
        var byID: [String: DictationStyleAppCandidate] = [:]
        for candidate in recent + running { byID[candidate.bundleID] = candidate }
        return byID.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                    statusDisclosure
                    categorySection
                    appRulesSection
                    domainRulesSection
                    privacyDisclosure
                    if let errorMessage {
                        Text(errorMessage)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.recording)
                            .accessibilityLabel("Adaptive Styles error: \(errorMessage)")
                    }
                }
                .padding(.bottom, MuesliTheme.spacing8)
            }
        }
        .padding(MuesliTheme.spacing24)
        .frame(minWidth: 820, minHeight: 620)
        .background(MuesliTheme.backgroundBase)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Adaptive Styles")
                    .font(MuesliTheme.title2())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Choose cleanup styles by category, exact application, or exact website hostname.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Closes Adaptive Styles settings")
        }
    }

    private var statusDisclosure: some View {
        Group {
            if !appState.config.enablePostProcessor {
                disclosure(
                    icon: "pause.circle",
                    text: "AI transcript cleanup is off. Rules stay editable and saved, but they will not run until cleanup is enabled."
                )
            } else if !appState.config.adaptiveDictationStylesEnabled {
                disclosure(
                    icon: "switch.2",
                    text: "Adaptive Styles is off. Your saved assignments are inactive; dictation uses the Global style."
                )
            }
        }
    }

    private var categorySection: some View {
        section(title: "Category styles", subtitle: "Used when no exact website or app style is assigned.") {
            VStack(spacing: MuesliTheme.spacing8) {
                ForEach(DictationStyleCategory.allCases) { category in
                    HStack {
                        Text(category.displayName)
                            .font(MuesliTheme.body())
                        Spacer()
                        stylePicker(
                            label: "\(category.displayName) category style",
                            selection: appState.config.dictationStyleCategoryAssignments[category.rawValue]
                        ) { styleID in
                            persist(DictationStyleSettingsModel.settingCategoryStyle(
                                styleID,
                                category: category,
                                in: appState.config
                            ))
                        }
                        .frame(width: 260)
                    }
                    .padding(.vertical, 4)
                    if category != DictationStyleCategory.allCases.last {
                        Divider().background(MuesliTheme.surfaceBorder)
                    }
                }
            }
        }
    }

    private var appRulesSection: some View {
        section(title: "Exact app rules", subtitle: "App identity is matched locally from its bundle identifier and does not require Accessibility.") {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                HStack {
                    Menu("Add running or recent app") {
                        if appCandidates.isEmpty {
                            Text("No applications available")
                        } else {
                            ForEach(appCandidates) { candidate in
                                Button("\(candidate.displayName) — \(candidate.bundleID)") {
                                    addApp(candidate)
                                }
                            }
                        }
                    }
                    .accessibilityHint("Adds an exact application rule using its local bundle identifier")
                    Button("Choose Application…") { chooseApplication() }
                        .accessibilityHint("Opens a file picker for a macOS application")
                    Spacer()
                }

                if appState.config.dictationStyleAppRules.isEmpty {
                    emptyText("No exact app rules.")
                } else {
                    ForEach(appState.config.dictationStyleAppRules) { rule in
                        appRuleRow(rule)
                    }
                }
            }
        }
    }

    private var domainRulesSection: some View {
        section(title: "Exact website rules", subtitle: "Enter a hostname or URL. Paths, queries, wildcards, and parent-domain matching are not used.") {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                HStack {
                    TextField("docs.google.com or https://docs.google.com/path", text: $domainInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Website hostname or URL")
                        .onSubmit(addDomain)
                    Button("Add Website", action: addDomain)
                        .disabled(domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if appState.config.dictationStyleDomainRules.isEmpty {
                    emptyText("No exact website rules.")
                } else {
                    ForEach(appState.config.dictationStyleDomainRules) { rule in
                        domainRuleRow(rule)
                    }
                }
            }
        }
    }

    private var privacyDisclosure: some View {
        disclosure(
            icon: "hand.raised",
            text: "Website matching uses the URL already available through opt-in App Context and Accessibility. It never enables OCR or requests Screen Recording. App identity and hostname rules stay local. If you use cloud cleanup, only separately enabled App Context content may be sent to that provider."
        )
        .accessibilityLabel("Privacy. Website matching depends on App Context and Accessibility, never OCR. App identities and hostname rules stay local.")
    }

    private func appRuleRow(_ rule: DictationStyleAppRule) -> some View {
        let effective = DictationStyleSettingsModel.effectiveState(
            config: appState.config,
            bundleID: rule.bundleID,
            hostname: nil
        )
        return ruleCard(title: rule.displayName.isEmpty ? rule.bundleID : rule.displayName, subtitle: rule.bundleID, effective: effective) {
            categoryPicker(label: "Category for \(rule.displayName)", selection: rule.categoryID) { categoryID in
                persist(DictationStyleSettingsModel.settingAppRule(
                    bundleID: rule.bundleID,
                    categoryID: categoryID,
                    styleID: rule.styleID,
                    in: appState.config
                ))
            }
            stylePicker(label: "Exact style for \(rule.displayName)", selection: rule.styleID) { styleID in
                persist(DictationStyleSettingsModel.settingAppRule(
                    bundleID: rule.bundleID,
                    categoryID: rule.categoryID,
                    styleID: styleID,
                    in: appState.config
                ))
            }
            Button(role: .destructive) {
                persist(DictationStyleSettingsModel.removingAppRule(bundleID: rule.bundleID, from: appState.config))
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete app rule for \(rule.displayName.isEmpty ? rule.bundleID : rule.displayName)")
        }
    }

    private func domainRuleRow(_ rule: DictationStyleDomainRule) -> some View {
        let effective = DictationStyleSettingsModel.effectiveState(
            config: appState.config,
            bundleID: nil,
            hostname: rule.hostname
        )
        return ruleCard(title: rule.hostname, subtitle: "Exact hostname", effective: effective) {
            categoryPicker(label: "Category for \(rule.hostname)", selection: rule.categoryID) { categoryID in
                persist(DictationStyleSettingsModel.settingDomainRule(
                    hostname: rule.hostname,
                    categoryID: categoryID,
                    styleID: rule.styleID,
                    in: appState.config
                ))
            }
            stylePicker(label: "Exact style for \(rule.hostname)", selection: rule.styleID) { styleID in
                persist(DictationStyleSettingsModel.settingDomainRule(
                    hostname: rule.hostname,
                    categoryID: rule.categoryID,
                    styleID: styleID,
                    in: appState.config
                ))
            }
            Button(role: .destructive) {
                persist(DictationStyleSettingsModel.removingDomainRule(hostname: rule.hostname, from: appState.config))
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete website rule for \(rule.hostname)")
        }
    }

    private func ruleCard<Controls: View>(
        title: String,
        subtitle: String,
        effective: DictationStyleEffectiveState,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(MuesliTheme.captionMedium()).foregroundStyle(MuesliTheme.textPrimary)
                Text(subtitle).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
                Text("Effective: \(effective.styleName) · \(effective.sourceLabel)")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .accessibilityLabel(effective.accessibilityDescription)
            }
            Spacer()
            controls()
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall).strokeBorder(MuesliTheme.surfaceBorder))
    }

    private func categoryPicker(label: String, selection: String?, onChange: @escaping (String?) -> Void) -> some View {
        Picker(label, selection: Binding(get: { selection ?? "" }, set: { onChange($0.isEmpty ? nil : $0) })) {
            Text("No category").tag("")
            ForEach(DictationStyleCategory.allCases) { category in
                Text(category.displayName).tag(category.rawValue)
            }
        }
        .labelsHidden()
        .frame(width: 130)
        .accessibilityLabel(label)
    }

    private func stylePicker(
        label: String,
        selection: String?,
        onChange: @escaping (String?) -> Void
    ) -> some View {
        Picker(label, selection: Binding(get: { selection ?? "" }, set: { onChange($0.isEmpty ? nil : $0) })) {
            Text("Inherit / Global").tag("")
            ForEach(styles) { style in Text(style.name).tag(style.id) }
        }
        .labelsHidden()
        .accessibilityLabel(label)
        .accessibilityHint("Selects a style by name; internal identifiers are hidden")
    }

    private func section<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(MuesliTheme.headline()).foregroundStyle(MuesliTheme.textPrimary)
                Text(subtitle).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
            }
            content()
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.surfacePrimary.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
    }

    private func disclosure(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing8) {
            Image(systemName: icon).foregroundStyle(MuesliTheme.accent)
            Text(text).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.accentSubtle.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    private func emptyText(_ text: String) -> some View {
        Text(text).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
    }

    private func persist(_ candidate: AppConfig) {
        do {
            try controller.updateDictationStyleConfiguration { $0 = candidate }
            errorMessage = nil
        } catch {
            errorMessage = "Could not save Adaptive Styles. Your previous settings are unchanged. \(error.localizedDescription)"
        }
    }

    private func addApp(_ candidate: DictationStyleAppCandidate) {
        do {
            persist(try DictationStyleSettingsModel.addingAppRule(
                bundleID: candidate.bundleID,
                displayName: candidate.displayName,
                to: appState.config
            ))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an application for Adaptive Styles"
        panel.prompt = "Choose Application"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { addApp(try DictationStyleSettingsModel.applicationCandidate(at: url)) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func addDomain() {
        do {
            persist(try DictationStyleSettingsModel.addingDomainRule(input: domainInput, to: appState.config))
            domainInput = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
