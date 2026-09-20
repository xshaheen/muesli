import SwiftUI
import ImlaCore

struct LanguageModelsSettingsView: View {
    let appState: AppState
    let updateConfig: ((inout AppConfig) -> Void) -> Void

    private var languages: [TranscriptionLanguage] {
        Self.displayedLanguages(keyboard: appState.keyboardLanguages, preferences: appState.config.languageModels)
    }

    static func displayedLanguages(
        keyboard: [TranscriptionLanguage], preferences: LanguageModelPreferences
    ) -> [TranscriptionLanguage] {
        let languages = Set(keyboard + preferences.languages)
        return languages.isEmpty ? [.english] : languages.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing24) {
            SettingsControls.section("Language & local models") {
                SettingsControls.description("Dictation captures your keyboard language when recording starts. Switch keyboards before dictating. During a meeting, use its language menu to choose the language for new speech.")
                SettingsControls.row("Current keyboard language") {
                    Text(appState.keyboardLanguage?.label ?? "Automatic detection")
                        .font(ImlaTheme.body())
                        .foregroundStyle(ImlaTheme.textSecondary)
                }
                if appState.dictationProvider.isHosted {
                    SettingsControls.description("Your \(appState.dictationProvider.label) provider stays selected. Dictation choices below are local fallbacks, used if hosted transcription fails. Meetings inherit the local model choice, never the hosted provider.")
                        .padding(.bottom, ImlaTheme.spacing8)
                }
                SettingsControls.description("Only installed, compatible models are offered. Choices apply to new recordings; active meetings keep their captured model assignments. Manage downloads in Models.")
                if let notice = appState.dictationLanguageModelNotice {
                    SettingsControls.description(notice)
                        .padding(.top, ImlaTheme.spacing8)
                }
            }

            ForEach(languages) { language in
                languageSection(language)
            }

            if languages.count < TranscriptionLanguage.allCases.count {
                Menu {
                    ForEach(TranscriptionLanguage.allCases.filter { !languages.contains($0) }) { language in
                        Button(language.label) {
                            updateConfig { $0.languageModels[language] = LanguageModelAssignment() }
                        }
                    }
                } label: {
                    Label("Add language", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .frame(minHeight: ImlaTheme.controlHeight)
                .help("Add a language without changing the active keyboard or meeting language.")
            }
        }
    }

    private func languageSection(_ language: TranscriptionLanguage) -> some View {
        SettingsControls.section(language.label) {
            modelRow(language, workload: .dictation)
            Divider().background(ImlaTheme.surfaceBorder)
            modelRow(language, workload: .meeting)
            if appState.config.languageModels.languages.contains(language) {
                Divider().background(ImlaTheme.surfaceBorder)
                HStack {
                    Spacer()
                    SettingsControls.compactActionButton(
                        appState.keyboardLanguages.contains(language) ? "Reset choices" : "Remove language",
                        systemImage: appState.keyboardLanguages.contains(language) ? "arrow.counterclockwise" : "minus"
                    ) {
                        updateConfig { $0.languageModels.remove(language) }
                    }
                    .help("Clear only \(language.label) model preferences. Enabled keyboard languages remain listed.")
                }
                .padding(.top, ImlaTheme.spacing8)
            }
        }
    }

    private func modelRow(_ language: TranscriptionLanguage, workload: LanguageModelRouting.Workload) -> some View {
        let assignment = appState.config.languageModels[language]
        let saved = workload == .dictation ? assignment.dictation : assignment.meeting
        let available = availableModels(for: workload)
        let options = available.filter { LanguageModelRouting.supports($0, language: language, workload: workload) }
        let defaultTitle = workload == .dictation ? "Default model" : "Same as dictation"
        let selectedIsUsable = saved?.option.map { options.contains($0) } ?? false
        let selectedTitle = saved.map { reference in
            (reference.option?.label ?? reference.model) + (selectedIsUsable ? "" : " (unavailable)")
        } ?? defaultTitle
        let resolution = LanguageModelRouting.resolve(
            language: language, preferences: appState.config.languageModels,
            dictationDefault: BackendOption.resolve(backend: appState.config.sttBackend, model: appState.config.sttModel) ?? appState.selectedBackend,
            meetingDefault: BackendOption.resolve(
                backend: appState.config.meetingTranscriptionBackend, model: appState.config.meetingTranscriptionModel
            ) ?? appState.selectedMeetingTranscriptionBackend,
            available: available, workload: workload
        )

        return SettingsControls.row(
            workload == .dictation ? "Dictation" : "Meeting",
            description: explanation(resolution, saved: saved, selectedIsUsable: selectedIsUsable, workload: workload),
            controlWidth: 275
        ) {
            Menu {
                Button(defaultTitle) { save(nil, language: language, workload: workload) }
                Divider()
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Button {
                        save(SpeechModelReference(option), language: language, workload: workload)
                    } label: {
                        if saved?.option == option {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
                if saved != nil, !selectedIsUsable {
                    Divider()
                    Text(selectedTitle)
                }
            } label: {
                Text(selectedTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .menuStyle(.borderlessButton)
            .frame(minHeight: ImlaTheme.compactControlHeight)
            .help(selectedTitle)
        }
    }

    private func availableModels(for workload: LanguageModelRouting.Workload) -> [BackendOption] {
        if workload == .dictation, appState.dictationProvider.isHosted {
            return appState.availableSpeechModels.filter(\.supportsHostedDictationFallback)
        }
        return appState.availableSpeechModels
    }

    private func explanation(
        _ resolution: LanguageModelRouting.Resolution,
        saved: SpeechModelReference?, selectedIsUsable: Bool,
        workload: LanguageModelRouting.Workload
    ) -> String {
        guard resolution.isUsable else {
            return "No compatible local model is installed. Download one from Models. Any saved choice is retained."
        }
        if saved != nil, !selectedIsUsable {
            return "Saved choice is unavailable or incompatible. Using \(resolution.backend.label) until it becomes available."
        }
        if resolution.usedFallback {
            return "Using \(resolution.backend.label) as a compatible fallback."
        }
        if workload == .meeting, saved == nil {
            return "Inherits the local dictation model when compatible. Currently \(resolution.backend.label)."
        }
        return "Uses \(resolution.backend.label)."
    }

    private func save(
        _ reference: SpeechModelReference?, language: TranscriptionLanguage,
        workload: LanguageModelRouting.Workload
    ) {
        updateConfig { config in
            if workload == .dictation {
                config.languageModels[language].dictation = reference
            } else {
                config.languageModels[language].meeting = reference
            }
        }
    }
}
