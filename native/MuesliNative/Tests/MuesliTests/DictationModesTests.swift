import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("Dictation modes")
struct DictationModesTests {

    // MARK: - Codable

    @Test("two valid modes round-trip through encode and decode with identical fields")
    func validModesRoundTrip() throws {
        var config = AppConfig()
        config.dictationModes = [
            DictationMode(
                id: "work",
                name: "Work",
                isEnabled: true,
                instructions: "Keep it formal.",
                overrideDefaultInstructions: true,
                appBundleIDs: ["com.apple.mail"],
                websiteHostnames: ["mail.example.com"],
                autoEnter: nil
            ),
            DictationMode(
                id: "chat",
                name: "Chat",
                isEnabled: false,
                instructions: "Keep it casual.",
                overrideDefaultInstructions: false,
                appBundleIDs: ["com.tinyspeck.slackmacgap"],
                websiteHostnames: ["web.whatsapp.com"],
                autoEnter: .return
            ),
        ]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.dictationModes == config.dictationModes)
    }

    @Test("mode keys are snake_case in the encoded config")
    func modeKeysAreSnakeCase() throws {
        var config = AppConfig()
        config.dictationModes = [
            DictationMode(
                id: "work",
                name: "Work",
                isEnabled: true,
                instructions: "Keep it formal.",
                overrideDefaultInstructions: true,
                appBundleIDs: ["com.apple.mail"],
                websiteHostnames: ["mail.example.com"],
                autoEnter: .commandReturn
            ),
        ]

        let data = try JSONEncoder().encode(config)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let modes = try #require(object["dictation_modes"] as? [[String: Any]])
        let mode = try #require(modes.first)

        #expect(mode["id"] as? String == "work")
        #expect(mode["name"] as? String == "Work")
        #expect(mode["is_enabled"] as? Bool == true)
        #expect(mode["instructions"] as? String == "Keep it formal.")
        #expect(mode["override_default_instructions"] as? Bool == true)
        #expect(mode["app_bundle_ids"] as? [String] == ["com.apple.mail"])
        #expect(mode["website_hostnames"] as? [String] == ["mail.example.com"])
        #expect(mode["auto_enter"] as? String == "command_return")
    }

    /// Covers AE12.
    @Test("a nameless object keeps its capped instructions and a string element is dropped")
    func namelessObjectSurvivesAndStringElementIsDropped() throws {
        let longInstructions = String(repeating: "a", count: CustomInstructions.maxLength)
        let json = """
        {
          "dictation_modes": [
            {"id": "valid", "name": "Valid", "is_enabled": true},
            {"id": "nameless", "instructions": "\(longInstructions)"},
            "not-an-object"
          ]
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.dictationModes.count == 2)
        #expect(config.dictationModes.map(\.id) == ["valid", "nameless"])
        #expect(config.dictationModes[1].name == DictationModes.fallbackName)
        #expect(config.dictationModes[1].instructions == longInstructions)
    }

    @Test("a mode element missing every optional field decodes to the documented defaults")
    func missingFieldsDecodeToDefaults() throws {
        let json = """
        {"dictation_modes": [{"id": "bare", "name": "Bare"}]}
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        let mode = try #require(config.dictationModes.first)

        #expect(mode.isEnabled == false)
        #expect(mode.instructions.isEmpty)
        #expect(mode.overrideDefaultInstructions == false)
        #expect(mode.appBundleIDs.isEmpty)
        #expect(mode.websiteHostnames.isEmpty)
        #expect(mode.autoEnter == nil)
    }

    @Test("a wrongly typed field falls back per field instead of dropping the mode")
    func wronglyTypedFieldsFallBackPerField() throws {
        let json = """
        {
          "dictation_modes": [
            {
              "id": "typed",
              "name": "Typed",
              "is_enabled": "yes",
              "instructions": 42,
              "app_bundle_ids": "com.apple.mail",
              "website_hostnames": [7, "example.com"]
            }
          ]
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        let mode = try #require(config.dictationModes.first)

        #expect(mode.id == "typed")
        #expect(mode.name == "Typed")
        #expect(mode.isEnabled == false)
        #expect(mode.instructions.isEmpty)
        #expect(mode.appBundleIDs.isEmpty)
        #expect(mode.websiteHostnames.isEmpty)
    }

    @Test("an unknown auto_enter value decodes as none")
    func unknownAutoEnterDecodesAsNone() throws {
        let json = """
        {"dictation_modes": [{"id": "chat", "name": "Chat", "auto_enter": "banana"}]}
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.dictationModes.first?.autoEnter == nil)
    }

    @Test("known auto_enter values decode to their cases")
    func knownAutoEnterValuesDecode() throws {
        let json = """
        {
          "dictation_modes": [
            {"id": "a", "name": "A", "auto_enter": "return"},
            {"id": "b", "name": "B", "auto_enter": "command_return"},
            {"id": "c", "name": "C", "auto_enter": null}
          ]
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.dictationModes.map(\.autoEnter) == [.return, .commandReturn, nil])
    }

    // MARK: - Identity

    @Test("a blank id becomes its index-derived id and a later duplicate is reassigned")
    func blankAndDuplicateIDsBecomeIndexDerived() throws {
        let json = """
        {
          "dictation_modes": [
            {"id": "shared", "name": "First"},
            {"id": "   ", "name": "Blank"},
            {"id": "shared", "name": "Duplicate"}
          ]
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.dictationModes.map(\.id) == ["shared", "mode-1", "mode-2"])
        #expect(config.dictationModes.map(\.name) == ["First", "Blank", "Duplicate"])

        let second = DictationModes.sanitized(modes: config.dictationModes)
        #expect(second == config.dictationModes)
    }

    @Test("a missing id becomes its index-derived id")
    func missingIDBecomesIndexDerived() throws {
        let json = """
        {"dictation_modes": [{"name": "First"}, {"name": "Second"}]}
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.dictationModes.map(\.id) == ["mode-0", "mode-1"])
    }

    // MARK: - Normalizer

    @Test("a name of only spaces becomes the fallback name")
    func whitespaceNameBecomesFallback() {
        let sanitized = DictationModes.sanitized(modes: [
            DictationMode(id: "a", name: "   \n ", instructions: "Body"),
        ])

        #expect(sanitized.first?.name == DictationModes.fallbackName)
    }

    @Test("a name keeps its inner spacing and loses only the surrounding whitespace")
    func nameIsTrimmed() {
        let sanitized = DictationModes.sanitized(modes: [
            DictationMode(id: "a", name: "  Work  Email  "),
        ])

        #expect(sanitized.first?.name == "Work  Email")
    }

    @Test("a bundle id claimed by an earlier mode is removed from every later mode")
    func duplicateBundleIDBelongsToTheFirstMode() {
        let sanitized = DictationModes.sanitized(modes: [
            DictationMode(id: "a", name: "A", appBundleIDs: ["com.apple.mail"]),
            DictationMode(id: "b", name: "B", appBundleIDs: ["com.apple.notes"]),
            DictationMode(id: "c", name: "C", appBundleIDs: ["com.apple.mail", "com.apple.textedit"]),
        ])

        #expect(sanitized.map(\.appBundleIDs) == [
            ["com.apple.mail"],
            ["com.apple.notes"],
            ["com.apple.textedit"],
        ])
    }

    @Test("a website claimed by an earlier mode is removed from every later mode")
    func duplicateHostnameBelongsToTheFirstMode() {
        let sanitized = DictationModes.sanitized(modes: [
            DictationMode(id: "a", name: "A", websiteHostnames: ["mail.google.com"]),
            DictationMode(id: "b", name: "B", websiteHostnames: ["MAIL.google.com.", "docs.google.com"]),
        ])

        #expect(sanitized.map(\.websiteHostnames) == [
            ["mail.google.com"],
            ["docs.google.com"],
        ])
    }

    @Test("targets are normalized and de-duplicated inside one mode")
    func targetsAreNormalizedWithinAMode() {
        let sanitized = DictationModes.sanitized(modes: [
            DictationMode(
                id: "a",
                name: "A",
                appBundleIDs: [" COM.Apple.Mail ", "com.apple.mail"],
                websiteHostnames: ["Mail.Example.com:443", "mail.example.com"]
            ),
        ])

        #expect(sanitized.first?.appBundleIDs == ["com.apple.mail"])
        #expect(sanitized.first?.websiteHostnames == ["mail.example.com"])
    }

    @Test("a hostname with a path and a single-label host are dropped")
    func invalidHostnamesAreDropped() {
        let sanitized = DictationModes.sanitized(modes: [
            DictationMode(
                id: "a",
                name: "A",
                websiteHostnames: [
                    "example.com/inbox",
                    "https://example.com/inbox",
                    "localhost",
                    "",
                    "example.com",
                ]
            ),
        ])

        #expect(sanitized.first?.websiteHostnames == ["example.com"])
    }

    @Test("an invalid bundle id is dropped")
    func invalidBundleIDsAreDropped() {
        let sanitized = DictationModes.sanitized(modes: [
            DictationMode(id: "a", name: "A", appBundleIDs: ["notabundleid", "com apple mail", "", "com.apple.mail"]),
        ])

        #expect(sanitized.first?.appBundleIDs == ["com.apple.mail"])
    }

    @Test("typed instructions over the cap are truncated")
    func typedInstructionsAreCapped() {
        let typed = "  " + String(repeating: "b", count: CustomInstructions.maxLength + 500)

        let normalized = DictationModes.normalizedTypedInstructions(typed)

        #expect(normalized.count == CustomInstructions.maxLength)
        #expect(normalized == String(repeating: "b", count: CustomInstructions.maxLength))
    }

    /// R7: migration never truncates a migrated prompt, so the sanitizer that runs on
    /// every decode and save must not either. The cap belongs to the text a user types.
    @Test("the sanitizer preserves instructions longer than the typed cap")
    func sanitizerPreservesLongInstructions() {
        let migrated = String(repeating: "c", count: CustomInstructions.maxLength + 500)

        let sanitized = DictationModes.sanitized(modes: [
            DictationMode(id: "a", name: "A", instructions: migrated),
        ])

        #expect(sanitized.first?.instructions == migrated)
    }

    @Test("an unknown auto_enter value survives sanitizing as none")
    func sanitizerKeepsAutoEnterCases() {
        let sanitized = DictationModes.sanitized(modes: [
            DictationMode(id: "a", name: "A", autoEnter: .return),
            DictationMode(id: "b", name: "B", autoEnter: .commandReturn),
            DictationMode(id: "c", name: "C", autoEnter: nil),
        ])

        #expect(sanitized.map(\.autoEnter) == [.return, .commandReturn, nil])
    }

    @Test("sanitizing is idempotent over a hostile configuration")
    func sanitizingIsIdempotent() {
        let hostile = [
            DictationMode(
                id: "",
                name: "  ",
                appBundleIDs: [" COM.Apple.Mail ", "bad id", "com.apple.mail"],
                websiteHostnames: ["Example.com.", "localhost"]
            ),
            DictationMode(
                id: "",
                name: "Second",
                appBundleIDs: ["com.apple.mail"],
                websiteHostnames: ["example.com", "docs.google.com"]
            ),
        ]

        let once = DictationModes.sanitized(modes: hostile)
        let twice = DictationModes.sanitized(modes: once)

        #expect(once == twice)
        #expect(once.map(\.appBundleIDs) == [["com.apple.mail"], []])
        #expect(once.map(\.websiteHostnames) == [["example.com"], ["docs.google.com"]])
    }

    /// Covers AE13.
    @Test("order C, A, B survives sanitize, encode, and decode")
    func modeOrderIsPreserved() throws {
        var config = AppConfig()
        config.dictationModes = DictationModes.sanitized(modes: [
            DictationMode(id: "c", name: "C"),
            DictationMode(id: "a", name: "A"),
            DictationMode(id: "b", name: "B"),
        ])

        #expect(config.dictationModes.map(\.id) == ["c", "a", "b"])

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.dictationModes.map(\.id) == ["c", "a", "b"])
        #expect(decoded.dictationModes.map(\.name) == ["C", "A", "B"])
    }

    // MARK: - Built-ins

    @Test("the memberwise default seeds the four built-in modes disabled")
    func memberwiseDefaultSeedsDisabledBuiltIns() {
        let config = AppConfig()

        #expect(config.dictationModes.map(\.id) == DictationModes.builtInModes(isEnabled: true).map(\.id))
        #expect(config.dictationModes.allSatisfy { !$0.isEnabled })
        #expect(config.dictationModes.map(\.name) == ["Email", "Notes", "Coding", "Messaging"])
    }

    /// Protects the prompt byte pins: an enabled Email built-in would change the
    /// composed prompt for every `AppConfig()`-based test that targets Mail.
    @Test("AppConfig() matches no enabled mode for com.apple.mail")
    func defaultConfigMatchesNoEnabledModeForMail() {
        let config = AppConfig()

        let matches = config.dictationModes.filter {
            $0.isEnabled && $0.appBundleIDs.contains("com.apple.mail")
        }

        #expect(matches.isEmpty)
        #expect(config.dictationModes.contains { $0.appBundleIDs.contains("com.apple.mail") })
    }

    @Test("built-in instructions come from the shipped cleanup presets")
    func builtInInstructionsComeFromPresets() throws {
        let builtIns = DictationModes.builtInModes(isEnabled: true)
        let email = try #require(builtIns.first { $0.id == DictationModes.BuiltIn.email.id })
        let notes = try #require(builtIns.first { $0.id == DictationModes.BuiltIn.notes.id })
        let coding = try #require(builtIns.first { $0.id == DictationModes.BuiltIn.coding.id })
        let messaging = try #require(builtIns.first { $0.id == DictationModes.BuiltIn.messaging.id })

        func prompt(_ id: String) throws -> String {
            try #require(TranscriptCleanupPrompts.builtIns.first { $0.id == id }?.prompt)
        }

        #expect(email.instructions == (try prompt(TranscriptCleanupPrompts.emailID)))
        #expect(notes.instructions == (try prompt(TranscriptCleanupPrompts.writingID)))
        #expect(coding.instructions == (try prompt(TranscriptCleanupPrompts.codeID)))
        #expect(messaging.instructions == (try prompt(TranscriptCleanupPrompts.messageID)))
    }

    @Test("built-in targets come from the curated catalogs and messaging alone auto-enters")
    func builtInTargetsMatchCuratedCatalogs() throws {
        let builtIns = DictationModes.builtInModes(isEnabled: true)
        let email = try #require(builtIns.first { $0.id == DictationModes.BuiltIn.email.id })
        let messaging = try #require(builtIns.first { $0.id == DictationModes.BuiltIn.messaging.id })

        #expect(email.appBundleIDs == ["com.apple.mail"])
        #expect(email.websiteHostnames == ["mail.google.com", "outlook.office.com"])
        #expect(messaging.autoEnter == .return)
        #expect(builtIns.filter { $0.autoEnter != nil }.map(\.id) == [DictationModes.BuiltIn.messaging.id])
        #expect(builtIns.allSatisfy { !$0.overrideDefaultInstructions })
    }

    @Test("the shipped built-ins are already sanitized")
    func builtInsAreSanitized() {
        let enabled = DictationModes.builtInModes(isEnabled: true)
        let disabled = DictationModes.builtInModes(isEnabled: false)

        #expect(DictationModes.sanitized(modes: enabled) == enabled)
        #expect(DictationModes.sanitized(modes: disabled) == disabled)
        #expect(enabled.allSatisfy { $0.isEnabled })
        #expect(disabled.allSatisfy { !$0.isEnabled })
    }

    @Test("built-in ids cannot collide with an index-derived id")
    func builtInIDsCannotCollideWithIndexDerivedIDs() {
        for mode in DictationModes.builtInModes(isEnabled: true) {
            #expect(!mode.id.hasPrefix("mode-"))
        }
    }
}
