import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("ConfigStore", .serialized)
struct ConfigStoreTests {

    /// Every case that writes uses its own directory. The default one is the real
    /// support directory, and loading it now runs the modes migration, which would
    /// rewrite a developer's own config and drop the keys their installed build reads.
    private func makeStore() throws -> ConfigStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ConfigStore(supportDirectory: directory)
    }

    @Test("load returns a valid config")
    func loadReturnsConfig() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.supportDirectory()) }
        let config = store.load()
        #expect(HotkeyConfig.label(for: config.dictationHotkey.keyCode) != nil)
        #expect(!config.sttBackend.isEmpty)
    }

    @Test("save and load round-trip")
    func saveLoadRoundTrip() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.supportDirectory()) }
        let original = store.load()

        var config = original
        config.openAIAPIKey = "sk-test-roundtrip"
        config.openAIModel = "gpt-5.4-pro"
        config.openRouterAPIKey = "sk-or-test-roundtrip"
        config.openRouterModel = "nvidia/nemotron-3-super-120b-a12b:free"
        config.cohereLanguage = CohereTranscribeLanguage.german.rawValue
        config.whisperLanguage = WhisperKitLanguage.german.rawValue
        config.appleSpeechLanguage = "en-US"
        config.meetingSummaryBackend = "openrouter"
        store.save(config)

        let loaded = store.load()
        #expect(loaded.openAIAPIKey == "sk-test-roundtrip")
        #expect(loaded.openAIModel == "gpt-5.4-pro")
        #expect(loaded.openRouterAPIKey == "sk-or-test-roundtrip")
        #expect(loaded.openRouterModel == "nvidia/nemotron-3-super-120b-a12b:free")
        #expect(loaded.cohereLanguage == CohereTranscribeLanguage.german.rawValue)
        #expect(loaded.whisperLanguage == WhisperKitLanguage.german.rawValue)
        #expect(loaded.appleSpeechLanguage == "en-US")
        #expect(loaded.meetingSummaryBackend == "openrouter")
    }

    @Test("config path is in Application Support")
    func configPath() {
        let store = ConfigStore()
        let path = store.configPath().path
        #expect(path.contains("Application Support"))
        #expect(path.hasSuffix("config.json"))
    }

    @Test("saved config uses owner-only file permissions")
    func configPermissions() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.supportDirectory()) }

        store.save(store.load())

        let attributes = try FileManager.default.attributesOfItem(atPath: store.configPath().path)
        let permissions = attributes[.posixPermissions] as? NSNumber

        #expect(permissions?.intValue == 0o600)
    }

    /// The quarantine used to refuse every save while a ruleset was invalid, which
    /// also blocked unrelated writes. Nothing about the mode list may refuse a save.
    @Test("a config whose modes claim the same target is saved, not refused")
    func duplicateModeTargetsAreSavedNotRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(supportDirectory: directory)

        var config = AppConfig()
        config.openAIModel = "must-reach-disk"
        config.dictationModes = [
            DictationMode(id: "a", name: "A", appBundleIDs: ["com.apple.mail"]),
            DictationMode(id: "a", name: "B", appBundleIDs: ["com.apple.mail"]),
        ]
        store.save(config)

        let reloaded = ConfigStore(supportDirectory: directory).load()

        #expect(reloaded.openAIModel == "must-reach-disk")
        #expect(reloaded.dictationModes.map(\.id) == ["a", "mode-1"])
        #expect(reloaded.dictationModes.map(\.appBundleIDs) == [["com.apple.mail"], []])
    }

    /// An invalid legacy ruleset used to quarantine the whole config. It must now be
    /// inert: unrelated settings still reach disk on the very next save.
    @Test("an invalid legacy ruleset no longer blocks unrelated saves")
    func invalidLegacyRulesetDoesNotBlockSaves() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = """
        {"dictation_style_ruleset_initialized":true,"dictation_style_groups":[{"id":"","name":"Broken","style_id":"default","matchers":[]}]}
        """
        try Data(original.utf8).write(to: directory.appendingPathComponent("config.json"))
        let store = ConfigStore(supportDirectory: directory)

        _ = store.load()
        var unrelated = AppConfig()
        unrelated.openAIModel = "must-overwrite"
        store.save(unrelated)

        let reloaded = ConfigStore(supportDirectory: directory).load()
        #expect(reloaded.openAIModel == "must-overwrite")
    }

    /// R8: a missing file is the only fresh install, and it is the only place the
    /// built-ins arrive enabled.
    @Test("a missing config file seeds the four built-in modes enabled")
    func missingConfigFileSeedsEnabledBuiltIns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(supportDirectory: directory)

        let fresh = store.load()

        #expect(fresh.dictationModes == DictationModes.builtInModes(isEnabled: true))
        #expect(fresh.dictationModesMigrationApplied == false)
        #expect(!FileManager.default.fileExists(atPath: store.configPath().path))
        #expect(!FileManager.default.fileExists(atPath: store.legacyBackupURL().path))

        store.save(fresh)

        let data = try Data(contentsOf: store.configPath())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let modes = try #require(object["dictation_modes"] as? [[String: Any]])
        #expect(modes.map { $0["id"] as? String } == DictationModes.BuiltIn.allCases.map(\.id))
        #expect(modes.allSatisfy { $0["is_enabled"] as? Bool == true })
    }

    /// R8: an unreadable file is not a fresh install. It keeps its bytes, and nothing
    /// about the modes migration may write over a file this build could not parse.
    @Test("an unreadable config file writes nothing and stays byte-identical")
    func unreadableConfigFileIsLeftAlone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(supportDirectory: directory)
        let original = Data("{ this is not json".utf8)
        try original.write(to: store.configPath())

        let loaded = store.load()

        #expect(loaded.dictationModes == AppConfig().dictationModes)
        #expect(loaded.dictationModes.allSatisfy { !$0.isEnabled })
        #expect(loaded.dictationModesMigrationApplied == false)
        #expect(try Data(contentsOf: store.configPath()) == original)
        #expect(!FileManager.default.fileExists(atPath: store.legacyBackupURL().path))
    }

    /// R3: the nine legacy keys leave disk, `post_processor_system_prompt` stays.
    @Test("a saved config carries dictation_modes and no legacy style key")
    func savedConfigDropsLegacyStyleKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(supportDirectory: directory)

        var config = AppConfig()
        config.adaptiveDictationStylesEnabled = true
        config.dictationStyleRulesetInitialized = true
        config.customTranscriptCleanupPrompts = [
            CustomTranscriptCleanupPrompt(id: "formal", name: "Formal", prompt: "Be formal."),
        ]
        config.dictationModes = [DictationMode(id: "work", name: "Work", isEnabled: true)]
        store.save(config)

        let data = try Data(contentsOf: store.configPath())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["dictation_modes"] != nil)
        #expect(object["post_processor_system_prompt"] != nil)
        for key in [
            "active_transcript_cleanup_prompt_id",
            "custom_transcript_cleanup_prompts",
            "adaptive_dictation_styles_enabled",
            "dictation_style_ruleset_initialized",
            "dictation_style_groups",
            "dictation_style_exact_exceptions",
            "dictation_style_category_assignments",
            "dictation_style_app_rules",
            "dictation_style_domain_rules",
        ] {
            #expect(object[key] == nil, "\(key) must not be persisted")
        }
    }

    @Test("mode persistence creates and replaces the config atomically")
    func modePersistenceCreatesAndReplacesConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(supportDirectory: directory)

        var initial = AppConfig()
        initial.dictationModes = [
            DictationMode(
                id: "work",
                name: "Work",
                isEnabled: true,
                instructions: "Use a formal tone.",
                websiteHostnames: ["mail.example.com"]
            ),
        ]

        let persisted = try store.saveDictationStyleConfiguration(initial)

        #expect(FileManager.default.fileExists(atPath: store.configPath().path))
        #expect(persisted.dictationModes == initial.dictationModes)
        let initialReload = ConfigStore(supportDirectory: directory).load()
        #expect(initialReload.dictationModes == initial.dictationModes)

        var replacement = initial
        replacement.dictationModes[0].name = "Customer Work"
        replacement.dictationModes[0].instructions = "Use a concise professional tone."
        replacement.dictationModes[0].websiteHostnames = ["support.example.com"]

        _ = try store.saveDictationStyleConfiguration(replacement)

        let replacementReload = ConfigStore(supportDirectory: directory).load()
        #expect(replacementReload.dictationModes == replacement.dictationModes)
    }

    @Test("a saved config is normalized on the way to disk")
    func savedConfigIsNormalized() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(supportDirectory: directory)

        var config = AppConfig()
        config.dictationModes = [
            DictationMode(id: "  ", name: "   ", appBundleIDs: [" COM.Apple.Mail "]),
        ]
        store.save(config)

        let reloaded = ConfigStore(supportDirectory: directory).load()
        let mode = try #require(reloaded.dictationModes.first)

        #expect(mode.id == "mode-0")
        #expect(mode.name == DictationModes.fallbackName)
        #expect(mode.appBundleIDs == ["com.apple.mail"])
    }

    @Test("language profile persists before becoming authoritative")
    func languageProfilePersistsAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(supportDirectory: directory)
        var candidate = AppConfig()
        candidate.dictationLanguageProfile = try SpokenLanguageProfile(
            selectedLanguages: [.english, .arabic],
            dominantLanguage: .arabic
        )
        candidate.meetingSpokenLanguage = try SpokenLanguageProfile(
            selectedLanguages: [.arabic, .hindi],
            dominantLanguage: .hindi
        )
        candidate.meetingArtifactLanguagePolicy = .arabic
        candidate.languageProfileNeedsConfirmation = true

        let persisted = try store.saveLanguageProfileConfiguration(candidate)
        let reloaded = store.load()

        #expect(persisted.dictationLanguageProfile == candidate.dictationLanguageProfile)
        #expect(reloaded.dictationLanguageProfile == candidate.dictationLanguageProfile)
        // The meeting authority round-trips in the profile shape, independent of dictation.
        #expect(reloaded.meetingSpokenLanguage == candidate.meetingSpokenLanguage)
        #expect(reloaded.meetingArtifactLanguagePolicy == .arabic)
        #expect(!reloaded.languageProfileNeedsConfirmation)
        #expect(reloaded.cohereLanguage == CohereTranscribeLanguage.arabic.rawValue)
        #expect(reloaded.nemotron35Language == Nemotron35Language.arabic.rawValue)
        #expect(reloaded.whisperLanguage == WhisperKitLanguage.arabic.rawValue)
        #expect(reloaded.indicASRLanguage == IndicASRLanguage.defaultLanguage.rawValue)
    }

    /// AE7: saving the meeting card must leave the dictation authority, the four
    /// legacy provider pins and the migration flag byte-identical. The dictation
    /// seam clears that flag and re-mirrors the pins; the meeting seam must not.
    @Test("saving the meeting languages leaves the dictation authority untouched")
    func meetingLanguageSaveLeavesDictationUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(supportDirectory: directory)

        var seed = AppConfig()
        seed.dictationLanguageProfile = try SpokenLanguageProfile(
            selectedLanguages: [.german, .hindi]
        )
        seed.languageProfileNeedsConfirmation = true
        seed.cohereLanguage = "de"
        seed.indicASRLanguage = "hi"
        seed.whisperLanguage = "de"
        seed.nemotron35Language = "de"

        var candidate = seed
        candidate.meetingSpokenLanguage = try SpokenLanguageProfile(selectedLanguages: [.english])
        let persisted = try store.saveMeetingLanguageProfileConfiguration(candidate)
        let reloaded = store.load()

        #expect(persisted.meetingSpokenLanguage.selectedLanguages == [.english])
        #expect(reloaded.meetingSpokenLanguage.selectedLanguages == [.english])
        // Everything the dictation card owns is unchanged.
        #expect(reloaded.dictationLanguageProfile == seed.dictationLanguageProfile)
        #expect(reloaded.languageProfileNeedsConfirmation)
        #expect(reloaded.cohereLanguage == "de")
        #expect(reloaded.indicASRLanguage == "hi")
        #expect(reloaded.whisperLanguage == "de")
        #expect(reloaded.nemotron35Language == "de")
    }

    /// The reverse direction: a dictation save republishes its own authority and
    /// the pins, and leaves the meeting selection alone.
    @Test("saving the dictation profile leaves the meeting selection untouched")
    func dictationSaveLeavesMeetingSelectionUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(supportDirectory: directory)

        var candidate = AppConfig()
        candidate.meetingSpokenLanguage = try SpokenLanguageProfile(
            selectedLanguages: [.arabic, .english],
            dominantLanguage: .arabic
        )
        candidate.dictationLanguageProfile = try SpokenLanguageProfile(selectedLanguages: [.english])

        _ = try store.saveLanguageProfileConfiguration(candidate)
        let reloaded = store.load()

        #expect(reloaded.meetingSpokenLanguage == candidate.meetingSpokenLanguage)
        #expect(reloaded.dictationLanguageProfile == candidate.dictationLanguageProfile)
    }

    /// The notes-language row saves through the same canonical seam, so the
    /// policy persists on its own without touching either spoken authority.
    @Test("saving the notes language persists only the artifact policy")
    func notesLanguageSavePersistsOnlyThePolicy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(supportDirectory: directory)

        var candidate = AppConfig()
        candidate.meetingSpokenLanguage = try SpokenLanguageProfile(selectedLanguages: [.arabic])
        candidate.meetingArtifactLanguagePolicy = .arabic
        _ = try store.saveMeetingLanguageProfileConfiguration(candidate)
        let reloaded = store.load()

        #expect(reloaded.meetingArtifactLanguagePolicy == .arabic)
        #expect(reloaded.meetingSpokenLanguage.selectedLanguages == [.arabic])
        #expect(reloaded.dictationLanguageProfile == AppConfig().dictationLanguageProfile)
    }

    /// The pre-modes backup exists so a downgrade can recover the legacy Writing
    /// Styles keys, not so a rotated or cleared provider key keeps living in a
    /// second plaintext file. The credentials must come out; everything else the
    /// typed `AppConfig` doesn't model must round-trip untouched.
    @Test("the pre-modes backup blanks provider credentials but keeps legacy style keys")
    func preModesBackupScrubsCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(supportDirectory: directory)
        let legacyJSON = """
        {
          "openai_api_key": "sk-secret-openai",
          "openrouter_api_key": "sk-secret-openrouter",
          "custom_llm_api_key": "sk-secret-custom",
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "dictation_style_groups": [
            {
              "id": "team-chat",
              "name": "Team chat",
              "style_id": "message",
              "matchers": [
                {"id": "m1", "kind": "bundle_id", "pattern": "com.tinyspeck.slackmacgap"}
              ]
            }
          ]
        }
        """
        try Data(legacyJSON.utf8).write(to: store.configPath())

        _ = store.load()

        let backupObject = try #require(
            JSONSerialization.jsonObject(with: try Data(contentsOf: store.legacyBackupURL())) as? [String: Any]
        )
        #expect(backupObject["openai_api_key"] as? String == "")
        #expect(backupObject["openrouter_api_key"] as? String == "")
        #expect(backupObject["custom_llm_api_key"] as? String == "")
        let groups = try #require(backupObject["dictation_style_groups"] as? [[String: Any]])
        #expect(groups.first?["id"] as? String == "team-chat")

        let attributes = try FileManager.default.attributesOfItem(atPath: store.legacyBackupURL().path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
