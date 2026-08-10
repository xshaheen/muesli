import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("ConfigStore", .serialized)
struct ConfigStoreTests {

    @Test("load returns a valid config")
    func loadReturnsConfig() {
        let store = ConfigStore()
        let config = store.load()
        // Hotkey may have been customized by user — just verify it loaded
        #expect(HotkeyConfig.label(for: config.dictationHotkey.keyCode) != nil)
        #expect(!config.sttBackend.isEmpty)
    }

    @Test("save and load round-trip")
    func saveLoadRoundTrip() {
        let store = ConfigStore()
        let original = store.load()

        var config = original
        config.openAIAPIKey = "sk-test-roundtrip"
        config.openAIModel = "gpt-5.4-pro"
        config.openRouterAPIKey = "sk-or-test-roundtrip"
        config.openRouterModel = "nvidia/nemotron-3-super-120b-a12b:free"
        config.cohereLanguage = CohereTranscribeLanguage.german.rawValue
        config.meetingSummaryBackend = "openrouter"
        store.save(config)

        let loaded = store.load()
        #expect(loaded.openAIAPIKey == "sk-test-roundtrip")
        #expect(loaded.openAIModel == "gpt-5.4-pro")
        #expect(loaded.openRouterAPIKey == "sk-or-test-roundtrip")
        #expect(loaded.openRouterModel == "nvidia/nemotron-3-super-120b-a12b:free")
        #expect(loaded.cohereLanguage == CohereTranscribeLanguage.german.rawValue)
        #expect(loaded.meetingSummaryBackend == "openrouter")

        // Restore original
        store.save(original)
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
        let store = ConfigStore()
        let original = store.load()

        store.save(original)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.configPath().path)
        let permissions = attributes[.posixPermissions] as? NSNumber

        #expect(permissions?.intValue == 0o600)
    }

    @Test("invalid canonical rulesets are quarantined and cannot be overwritten")
    func invalidCanonicalRulesetIsQuarantined() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = """
        {"dictation_style_ruleset_initialized":true,"dictation_style_groups":[{"id":"","name":"Broken","style_id":"default","matchers":[]}]}
        """
        try Data(original.utf8).write(to: directory.appendingPathComponent("config.json"))
        let store = ConfigStore(supportDirectory: directory)

        if case .quarantined(let fallback, _) = store.loadResult() {
            #expect(!fallback.adaptiveDictationStylesEnabled)
        } else {
            Issue.record("Expected invalid canonical ruleset to be quarantined")
        }
        var unrelated = AppConfig()
        unrelated.openAIModel = "must-not-overwrite"
        store.save(unrelated)
        #expect(try String(contentsOf: directory.appendingPathComponent("config.json")) == original)
    }

    @Test("ruleset persistence rejects a preview fidelity mismatch before writing")
    func rulesetPersistenceRejectsFidelityMismatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(supportDirectory: directory)
        var config = AppConfig()
        config.dictationStyleRulesetInitialized = true
        let expected = try DictationStyleRulesetCodec.ruleset(from: config)
        var mismatched = expected
        mismatched.globalDefault.prompt = "Different"

        #expect(throws: DictationStyleRulesetCodec.Error.self) {
            _ = try store.saveDictationStyleRulesetConfiguration(config, expectedRuleset: mismatched)
        }
        #expect(!FileManager.default.fileExists(atPath: store.configPath().path))
    }

    @Test("ruleset persistence creates and replaces the config atomically")
    func rulesetPersistenceCreatesAndReplacesConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(supportDirectory: directory)

        var initial = AppConfig()
        initial.dictationStyleRulesetInitialized = true
        initial.customTranscriptCleanupPrompts = [
            CustomTranscriptCleanupPrompt(id: "formal", name: "Formal", prompt: "Use a formal tone."),
        ]
        initial.dictationStyleGroups = [
            DictationStyleGroup(
                id: "work",
                name: "Work",
                styleID: "formal",
                matchers: [
                    DictationStyleMatcher(
                        id: "work-mail",
                        kind: .hostname,
                        pattern: "mail.example.com"
                    ),
                ]
            ),
        ]
        let initialRuleset = try DictationStyleRulesetCodec.ruleset(from: initial)

        _ = try store.saveDictationStyleRulesetConfiguration(initial, expectedRuleset: initialRuleset)

        #expect(FileManager.default.fileExists(atPath: store.configPath().path))
        let initialReload = ConfigStore(supportDirectory: directory).load()
        #expect(try DictationStyleRulesetCodec.ruleset(from: initialReload) == initialRuleset)

        var replacement = initial
        replacement.customTranscriptCleanupPrompts[0].prompt = "Use a concise professional tone."
        replacement.dictationStyleGroups[0].name = "Customer Work"
        replacement.dictationStyleGroups[0].matchers[0].pattern = "*.example.com"
        let replacementRuleset = try DictationStyleRulesetCodec.ruleset(from: replacement)

        _ = try store.saveDictationStyleRulesetConfiguration(
            replacement,
            expectedRuleset: replacementRuleset
        )

        let replacementReload = ConfigStore(supportDirectory: directory).load()
        #expect(try DictationStyleRulesetCodec.ruleset(from: replacementReload) == replacementRuleset)
    }
}
