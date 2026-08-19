import Foundation
import MuesliCore
import Observation

/// Narrow persistence boundary for the profile editor. The runtime controller
/// supplies the live client; tests can prove save semantics without audio or UI.
@MainActor
struct LanguageProfileClient {
    enum Error: Swift.Error, LocalizedError {
        case controllerUnavailable

        var errorDescription: String? {
            "Language settings are unavailable. Reopen Settings and try again."
        }
    }

    let load: () -> DictationLanguageProfile
    let save: (DictationLanguageProfile) throws -> DictationLanguageProfile
    let presentation: (DictationLanguageProfile, BackendOption) -> LanguageSelectionPresentation

    init(
        load: @escaping () -> DictationLanguageProfile = { .automatic },
        save: @escaping (DictationLanguageProfile) throws -> DictationLanguageProfile,
        presentation: @escaping (DictationLanguageProfile, BackendOption) -> LanguageSelectionPresentation = {
            profile, backend in profile.presentation(for: backend)
        }
    ) {
        self.load = load
        self.save = save
        self.presentation = presentation
    }
}

@MainActor
@Observable
final class LanguageProfileSettingsModel {
    private(set) var selectedLanguages: [TranscriptionLanguage]
    private(set) var dominantLanguage: TranscriptionLanguage?
    private(set) var committedProfile: DictationLanguageProfile
    private(set) var errorMessage: String?
    private(set) var didSave = false

    init(profile: DictationLanguageProfile = .automatic) {
        selectedLanguages = profile.selectedLanguages
        dominantLanguage = profile.dominantLanguage
        committedProfile = profile
    }

    var hasUnsavedChanges: Bool {
        draftProfile != committedProfile
    }

    var draftProfile: DictationLanguageProfile {
        // The mutation methods maintain the dominant-language invariant.
        (try? DictationLanguageProfile(
            selectedLanguages: selectedLanguages,
            dominantLanguage: dominantLanguage
        )) ?? .automatic
    }

    func load(using client: LanguageProfileClient) {
        synchronize(with: client.load())
    }

    func synchronize(with profile: DictationLanguageProfile) {
        guard !hasUnsavedChanges else { return }
        applyCommitted(profile)
    }

    func toggle(_ language: TranscriptionLanguage) {
        var selected = Set(selectedLanguages)
        if selected.contains(language) {
            selected.remove(language)
            if dominantLanguage == language {
                dominantLanguage = nil
            }
        } else {
            selected.insert(language)
        }
        selectedLanguages = selected.sorted { $0.rawValue < $1.rawValue }
        didSave = false
        errorMessage = nil
    }

    func useAutomaticDetection() {
        selectedLanguages = []
        dominantLanguage = nil
        didSave = false
        errorMessage = nil
    }

    func setDominant(_ language: TranscriptionLanguage?) {
        dominantLanguage = language.flatMap { selectedLanguages.contains($0) ? $0 : nil }
        didSave = false
        errorMessage = nil
    }

    func save(using client: LanguageProfileClient) {
        let candidate = draftProfile
        do {
            let persisted = try client.save(candidate)
            applyCommitted(persisted)
            didSave = true
            errorMessage = nil
        } catch {
            didSave = false
            errorMessage = error.localizedDescription
        }
    }

    private func applyCommitted(_ profile: DictationLanguageProfile) {
        selectedLanguages = profile.selectedLanguages
        dominantLanguage = profile.dominantLanguage
        committedProfile = profile
    }
}
