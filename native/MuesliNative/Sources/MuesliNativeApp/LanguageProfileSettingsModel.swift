import Foundation
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

    let load: () -> LanguageProfile
    let save: (LanguageProfile) throws -> LanguageProfile
    let effectiveBehavior: (LanguageProfile, BackendOption) -> LanguageProfileEffectiveBehavior

    init(
        load: @escaping () -> LanguageProfile = { .automatic },
        save: @escaping (LanguageProfile) throws -> LanguageProfile,
        effectiveBehavior: @escaping (LanguageProfile, BackendOption) -> LanguageProfileEffectiveBehavior = {
            profile, backend in profile.effectiveBehavior(for: backend)
        }
    ) {
        self.load = load
        self.save = save
        self.effectiveBehavior = effectiveBehavior
    }
}

@MainActor
@Observable
final class LanguageProfileSettingsModel {
    private(set) var selectedLanguages: [TranscriptionLanguage]
    private(set) var dominantLanguage: TranscriptionLanguage?
    private(set) var meetingOutputPolicy: MeetingOutputLanguagePolicy
    private(set) var committedProfile: LanguageProfile
    private(set) var errorMessage: String?
    private(set) var didSave = false

    init(profile: LanguageProfile = .automatic) {
        selectedLanguages = profile.selectedLanguages
        dominantLanguage = profile.dominantLanguage
        meetingOutputPolicy = profile.meetingOutputPolicy
        committedProfile = profile
    }

    var hasUnsavedChanges: Bool {
        draftProfile != committedProfile
    }

    var draftProfile: LanguageProfile {
        // The mutation methods maintain the dominant-language invariant.
        (try? LanguageProfile(
            selectedLanguages: selectedLanguages,
            dominantLanguage: dominantLanguage,
            meetingOutputPolicy: meetingOutputPolicy
        )) ?? .automatic
    }

    func load(using client: LanguageProfileClient) {
        synchronize(with: client.load())
    }

    func synchronize(with profile: LanguageProfile) {
        guard !hasUnsavedChanges else { return }
        applyCommitted(profile)
    }

    func toggle(_ language: TranscriptionLanguage) {
        var selected = Set(selectedLanguages)
        if selected.contains(language) {
            selected.remove(language)
            if dominantLanguage == language {
                dominantLanguage = nil
                meetingOutputPolicy = .automatic
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
        meetingOutputPolicy = .automatic
        didSave = false
        errorMessage = nil
    }

    func setDominant(_ language: TranscriptionLanguage?) {
        dominantLanguage = language.flatMap { selectedLanguages.contains($0) ? $0 : nil }
        if dominantLanguage?.supportsMeetingOutputLanguage != true,
           meetingOutputPolicy == .dominantLanguage {
            meetingOutputPolicy = .automatic
        }
        didSave = false
        errorMessage = nil
    }

    func setMeetingOutputPolicy(_ policy: MeetingOutputLanguagePolicy) {
        meetingOutputPolicy = dominantLanguage?.supportsMeetingOutputLanguage == true
            ? policy
            : .automatic
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

    private func applyCommitted(_ profile: LanguageProfile) {
        selectedLanguages = profile.selectedLanguages
        dominantLanguage = profile.dominantLanguage
        meetingOutputPolicy = profile.meetingOutputPolicy
        committedProfile = profile
    }
}
