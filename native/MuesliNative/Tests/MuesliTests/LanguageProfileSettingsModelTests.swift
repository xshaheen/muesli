import Testing
@testable import MuesliNativeApp

@Suite("Language profile settings")
@MainActor
struct LanguageProfileSettingsModelTests {
    @Test("loading crosses one adapter and preserves an existing draft")
    func loadUsesOneAdapterWithoutOverwritingDraft() throws {
        let loaded = try LanguageProfile(
            selectedLanguages: [.arabic],
            dominantLanguage: .arabic
        )
        var loadCount = 0
        let client = LanguageProfileClient(
            load: {
                loadCount += 1
                return loaded
            },
            save: { $0 }
        )
        let model = LanguageProfileSettingsModel()

        model.load(using: client)
        model.toggle(.english)
        model.load(using: client)

        #expect(loadCount == 2)
        #expect(model.selectedLanguages == [.arabic, .english])
        #expect(model.committedProfile == loaded)
    }

    @Test("edits remain draft state until the atomic save succeeds")
    func failedSaveRetainsDraft() throws {
        let original = try LanguageProfile(
            selectedLanguages: [.english],
            dominantLanguage: .english
        )
        let model = LanguageProfileSettingsModel(profile: original)
        model.toggle(.arabic)
        model.setDominant(.arabic)

        let client = LanguageProfileClient { _ in
            struct PersistenceFailure: Error {}
            throw PersistenceFailure()
        }
        model.save(using: client)

        #expect(model.selectedLanguages == [.arabic, .english])
        #expect(model.dominantLanguage == .arabic)
        #expect(model.hasUnsavedChanges)
        #expect(model.errorMessage != nil)
    }

    @Test("a successful save publishes the canonical persisted profile once")
    func successfulSavePublishesOnce() throws {
        let model = LanguageProfileSettingsModel(profile: .automatic)
        model.toggle(.english)
        model.toggle(.arabic)
        model.setDominant(.arabic)
        model.setMeetingOutputPolicy(.dominantLanguage)
        var saveCount = 0

        let client = LanguageProfileClient { profile in
            saveCount += 1
            return profile
        }
        model.save(using: client)

        #expect(saveCount == 1)
        #expect(model.committedProfile.selectedLanguages == [.arabic, .english])
        #expect(model.committedProfile.dominantLanguage == .arabic)
        #expect(model.committedProfile.meetingOutputPolicy == .dominantLanguage)
        #expect(!model.hasUnsavedChanges)
        #expect(model.errorMessage == nil)
    }

    @Test("removing a dominant language clears dominance and its output policy")
    func removingDominantLanguageRepairsDraft() throws {
        let profile = try LanguageProfile(
            selectedLanguages: [.english, .arabic],
            dominantLanguage: .arabic,
            meetingOutputPolicy: .dominantLanguage
        )
        let model = LanguageProfileSettingsModel(profile: profile)

        model.toggle(.arabic)

        #expect(model.selectedLanguages == [.english])
        #expect(model.dominantLanguage == nil)
        #expect(model.meetingOutputPolicy == .automatic)
    }
}
