import Testing
import Foundation
@testable import MuesliNativeApp

/// R5-R9: the one-time Writing Styles to Modes migration.
///
/// Every case decodes a real legacy config shape, because the migration is a decode
/// path: what the fixture proves is what an upgrading user's file produces.
@Suite("Dictation mode migration")
struct DictationModeMigrationTests {

    // MARK: - Helpers

    private func decode(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }

    private func prompt(_ id: String) throws -> String {
        try #require(TranscriptCleanupPrompts.builtIns.first { $0.id == id }?.prompt)
    }

    private func mode(_ config: AppConfig, _ id: String) throws -> DictationMode {
        try #require(config.dictationModes.first { $0.id == id })
    }

    private var builtInIDs: [String] {
        DictationModes.BuiltIn.allCases.map(\.id)
    }

    // MARK: - Groups (R5)

    /// Covers AE1.
    @Test("a group with two exact matchers migrates with its style text and both targets")
    func groupWithExactMatchersMigrates() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "dictation_style_groups": [
            {
              "id": "team-chat",
              "name": "Team chat",
              "style_id": "message",
              "matchers": [
                {"id": "m1", "kind": "bundle_id", "pattern": "com.tinyspeck.slackmacgap"},
                {"id": "m2", "kind": "hostname", "pattern": "web.whatsapp.com"}
              ]
            }
          ]
        }
        """)

        #expect(config.dictationModesMigrationApplied)
        #expect(config.dictationModes.map(\.id) == ["team-chat"] + builtInIDs)

        let migrated = try mode(config, "team-chat")
        #expect(migrated.name == "Team chat")
        #expect(migrated.isEnabled)
        #expect(migrated.instructions == (try prompt(TranscriptCleanupPrompts.messageID)))
        #expect(migrated.overrideDefaultInstructions == false)
        #expect(migrated.appBundleIDs == ["com.tinyspeck.slackmacgap"])
        #expect(migrated.websiteHostnames == ["web.whatsapp.com"])
        // Legacy had no auto-enter, so migration must not arm one.
        #expect(migrated.autoEnter == nil)

        // The appended built-in cannot re-claim a target the migrated mode owns.
        let messaging = try mode(config, DictationModes.BuiltIn.messaging.id)
        #expect(messaging.isEnabled == false)
        #expect(messaging.appBundleIDs == ["com.apple.mobilesms", "net.whatsapp.whatsapp"])
        #expect(messaging.websiteHostnames.isEmpty)
    }

    /// Covers AE2.
    @Test("adaptive styles off yields a disabled migrated mode")
    func adaptiveOffYieldsDisabledMode() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": false,
          "dictation_style_ruleset_initialized": true,
          "dictation_style_groups": [
            {
              "id": "team-chat",
              "name": "Team chat",
              "style_id": "message",
              "matchers": [{"id": "m1", "kind": "bundle_id", "pattern": "com.tinyspeck.slackmacgap"}]
            }
          ]
        }
        """)

        let migrated = try mode(config, "team-chat")
        #expect(migrated.isEnabled == false)
        #expect(config.dictationModes.allSatisfy { !$0.isEnabled })
    }

    @Test("a wildcard subdomain matcher becomes the bare host and other wildcards are dropped")
    func wildcardMatchersAreMappedOrDropped() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "dictation_style_groups": [
            {
              "id": "web",
              "name": "Web",
              "style_id": "writing",
              "matchers": [
                {"id": "m1", "kind": "hostname", "pattern": "*.example.com"},
                {"id": "m2", "kind": "hostname", "pattern": "mail-*.example.com"},
                {"id": "m3", "kind": "hostname", "pattern": "localhost"},
                {"id": "m4", "kind": "bundle_id", "pattern": "com.example.*"},
                {"id": "m5", "kind": "bundle_id", "pattern": "com.example.editor"}
              ]
            }
          ]
        }
        """)

        let migrated = try mode(config, "web")
        #expect(migrated.websiteHostnames == ["example.com"])
        #expect(migrated.appBundleIDs == ["com.example.editor"])
        #expect(config.dictationModes.first?.id == "web")
    }

    /// A dropped wildcard matcher's only trace used to be an `fputs` to stderr that a
    /// notarized, LSUIElement app never surfaces. It must also land in the decode-only
    /// notes field the Modes screen reads to disclose the drop once.
    @Test("a dropped wildcard matcher is named in the migration notes")
    func droppedWildcardMatcherIsNamedInMigrationNotes() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "dictation_style_groups": [
            {
              "id": "web",
              "name": "Web",
              "style_id": "writing",
              "matchers": [
                {"id": "m1", "kind": "hostname", "pattern": "mail-*.example.com"},
                {"id": "m2", "kind": "bundle_id", "pattern": "com.example.*"}
              ]
            }
          ]
        }
        """)

        #expect(!config.dictationModesMigrationNotes.isEmpty)
        #expect(config.dictationModesMigrationNotes.contains { $0.contains("mail-*.example.com") })
        #expect(config.dictationModesMigrationNotes.contains { $0.contains("com.example.*") })
    }

    /// The group's own name and text survive even when every matcher is unusable.
    @Test("a group whose matchers are all dropped is still created")
    func groupWithOnlyUnusableMatchersIsStillCreated() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "dictation_style_groups": [
            {
              "id": "web",
              "name": "Web",
              "style_id": "writing",
              "matchers": [{"id": "m1", "kind": "hostname", "pattern": "localhost"}]
            }
          ]
        }
        """)

        let migrated = try mode(config, "web")
        #expect(migrated.name == "Web")
        #expect(migrated.appBundleIDs.isEmpty)
        #expect(migrated.websiteHostnames.isEmpty)
        #expect(migrated.instructions == (try prompt(TranscriptCleanupPrompts.writingID)))
    }

    // MARK: - Base prompt and unreferenced prompts (R7)

    /// Covers AE3.
    @Test("an edited base prompt stays put while unreferenced prompts become disabled override modes")
    func unreferencedPromptsBecomeDisabledOverrideModes() throws {
        let longPrompt = String(repeating: "x", count: 3_000)
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": false,
          "post_processor_system_prompt": "My own edited base prompt.",
          "custom_transcript_cleanup_prompts": [
            {"id": "terse", "name": "Terse", "prompt": "Be terse."},
            {"id": "long", "name": "Long", "prompt": "\(longPrompt)"}
          ]
        }
        """)

        #expect(config.postProcessorSystemPrompt == "My own edited base prompt.")
        #expect(!config.dictationModes.contains { $0.instructions == "My own edited base prompt." })

        #expect(config.dictationModes.map(\.id) == ["legacy-prompt-terse", "legacy-prompt-long"] + builtInIDs)

        let terse = try mode(config, "legacy-prompt-terse")
        #expect(terse.name == "Terse")
        #expect(terse.instructions == "Be terse.")
        #expect(terse.overrideDefaultInstructions)
        #expect(terse.isEnabled == false)
        #expect(terse.appBundleIDs.isEmpty)
        #expect(terse.websiteHostnames.isEmpty)

        // R7: migration never truncates, even past the typed-instructions cap.
        let long = try mode(config, "legacy-prompt-long")
        #expect(long.instructions.count == 3_000)
        #expect(long.instructions == longPrompt)
    }

    @Test("a prompt referenced by a group or an exception does not also become its own mode")
    func referencedPromptsDoNotDuplicate() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "custom_transcript_cleanup_prompts": [
            {"id": "grouped", "name": "Grouped", "prompt": "Grouped text."},
            {"id": "excepted", "name": "Excepted", "prompt": "Excepted text."}
          ],
          "dictation_style_groups": [
            {"id": "g", "name": "Grouped group", "style_id": "grouped", "matchers": []}
          ],
          "dictation_style_exact_exceptions": [
            {"id": "e", "kind": "bundle_id", "target": "com.apple.notes", "style_id": "excepted"}
          ]
        }
        """)

        #expect(!config.dictationModes.contains { $0.id.hasPrefix("legacy-prompt-") })
        #expect(config.dictationModes.map(\.id) == ["g", "legacy-style-excepted"] + builtInIDs)
    }

    // MARK: - Exceptions (R6)

    @Test("an exception for a style with no group creates its own mode and steals the target")
    func exceptionCreatesModeAndMovesTarget() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "custom_transcript_cleanup_prompts": [
            {"id": "terse", "name": "Terse", "prompt": "Be terse."}
          ],
          "dictation_style_groups": [
            {
              "id": "work",
              "name": "Work",
              "style_id": "email",
              "matchers": [
                {"id": "m1", "kind": "bundle_id", "pattern": "com.apple.mail"},
                {"id": "m2", "kind": "bundle_id", "pattern": "com.apple.notes"}
              ]
            }
          ],
          "dictation_style_exact_exceptions": [
            {"id": "e1", "kind": "bundle_id", "target": "com.apple.mail", "style_id": "terse"}
          ]
        }
        """)

        #expect(config.dictationModes.map(\.id) == ["work", "legacy-style-terse"] + builtInIDs)

        let work = try mode(config, "work")
        #expect(work.appBundleIDs == ["com.apple.notes"])

        let exception = try mode(config, "legacy-style-terse")
        #expect(exception.name == "Terse")
        #expect(exception.instructions == "Be terse.")
        #expect(exception.isEnabled)
        #expect(exception.overrideDefaultInstructions == false)
        #expect(exception.appBundleIDs == ["com.apple.mail"])

        // The legacy winner for com.apple.mail was the exception's text.
        let owner = try #require(config.dictationModes.first { $0.appBundleIDs.contains("com.apple.mail") })
        #expect(owner.instructions == "Be terse.")
    }

    @Test("an exception whose style already has a group moves the target into that group's mode")
    func exceptionReusesTheGroupCarryingItsStyle() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "dictation_style_groups": [
            {
              "id": "mail",
              "name": "Mail",
              "style_id": "email",
              "matchers": [{"id": "m1", "kind": "bundle_id", "pattern": "com.apple.mail"}]
            },
            {
              "id": "chat",
              "name": "Chat",
              "style_id": "message",
              "matchers": [{"id": "m2", "kind": "bundle_id", "pattern": "com.apple.mobilesms"}]
            }
          ],
          "dictation_style_exact_exceptions": [
            {"id": "e1", "kind": "bundle_id", "target": "com.apple.mobilesms", "style_id": "email"}
          ]
        }
        """)

        #expect(config.dictationModes.map(\.id) == ["mail", "chat"] + builtInIDs)
        #expect((try mode(config, "mail")).appBundleIDs == ["com.apple.mail", "com.apple.mobilesms"])
        #expect((try mode(config, "chat")).appBundleIDs.isEmpty)
    }

    @Test("a hostname exception moves the website entry between modes")
    func hostnameExceptionMovesWebsiteEntry() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "custom_transcript_cleanup_prompts": [
            {"id": "terse", "name": "Terse", "prompt": "Be terse."}
          ],
          "dictation_style_groups": [
            {
              "id": "docs",
              "name": "Docs",
              "style_id": "writing",
              "matchers": [{"id": "m1", "kind": "hostname", "pattern": "docs.google.com"}]
            }
          ],
          "dictation_style_exact_exceptions": [
            {"id": "e1", "kind": "hostname", "target": "docs.google.com", "style_id": "terse"}
          ]
        }
        """)

        #expect((try mode(config, "docs")).websiteHostnames.isEmpty)
        #expect((try mode(config, "legacy-style-terse")).websiteHostnames == ["docs.google.com"])
    }

    @Test("the last exception for a target wins, as the legacy resolver did")
    func lastExceptionForATargetWins() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "custom_transcript_cleanup_prompts": [
            {"id": "first", "name": "First", "prompt": "First text."},
            {"id": "second", "name": "Second", "prompt": "Second text."}
          ],
          "dictation_style_groups": [],
          "dictation_style_exact_exceptions": [
            {"id": "e1", "kind": "bundle_id", "target": "com.apple.mail", "style_id": "first"},
            {"id": "e2", "kind": "bundle_id", "target": "com.apple.mail", "style_id": "second"}
          ]
        }
        """)

        let owner = try #require(config.dictationModes.first { $0.appBundleIDs.contains("com.apple.mail") })
        #expect(owner.instructions == "Second text.")
        #expect((try mode(config, "legacy-style-first")).appBundleIDs.isEmpty)
    }

    /// The legacy resolver returns no group when two groups match a target at equal
    /// rank, so the migration must not hand that target to either mode.
    @Test("a target two groups claim exactly is dropped from both")
    func ambiguousGroupTargetIsDroppedFromBoth() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "dictation_style_groups": [
            {
              "id": "a",
              "name": "A",
              "style_id": "email",
              "matchers": [
                {"id": "m1", "kind": "bundle_id", "pattern": "com.apple.mail"},
                {"id": "m2", "kind": "bundle_id", "pattern": "com.apple.notes"}
              ]
            },
            {
              "id": "b",
              "name": "B",
              "style_id": "message",
              "matchers": [{"id": "m3", "kind": "bundle_id", "pattern": "com.apple.mail"}]
            }
          ]
        }
        """)

        #expect((try mode(config, "a")).appBundleIDs == ["com.apple.notes"])
        #expect((try mode(config, "b")).appBundleIDs.isEmpty)
    }

    /// `*.example.com` and an exact `example.com` collapse onto the same entry. The
    /// legacy resolver picked the exact matcher, so the exact claim keeps it.
    @Test("an exact website claim beats a wildcard-derived claim from another group")
    func exactWebsiteClaimBeatsWildcardDerivedClaim() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "dictation_style_groups": [
            {
              "id": "wide",
              "name": "Wide",
              "style_id": "writing",
              "matchers": [{"id": "m1", "kind": "hostname", "pattern": "*.example.com"}]
            },
            {
              "id": "exact",
              "name": "Exact",
              "style_id": "email",
              "matchers": [{"id": "m2", "kind": "hostname", "pattern": "example.com"}]
            }
          ]
        }
        """)

        #expect((try mode(config, "wide")).websiteHostnames.isEmpty)
        #expect((try mode(config, "exact")).websiteHostnames == ["example.com"])
    }

    // MARK: - Built-in identity (R8)

    @Test("a starter category group keeps the built-in id for its category")
    func starterCategoryGroupKeepsBuiltInID() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "dictation_style_groups": [
            {
              "id": "starter-group-email",
              "name": "Email",
              "style_id": "email",
              "matchers": [{"id": "m1", "kind": "bundle_id", "pattern": "com.apple.mail"}]
            }
          ]
        }
        """)

        #expect(config.dictationModes.map(\.id) == [
            DictationModes.BuiltIn.email.id,
            DictationModes.BuiltIn.notes.id,
            DictationModes.BuiltIn.coding.id,
            DictationModes.BuiltIn.messaging.id,
        ])
        let email = try mode(config, DictationModes.BuiltIn.email.id)
        #expect(email.isEnabled)
        #expect(email.appBundleIDs == ["com.apple.mail"])
        #expect(config.dictationModes.dropFirst().allSatisfy { !$0.isEnabled })
    }

    @Test("a legacy category group keeps the built-in id and Writing maps to Notes")
    func legacyCategoryGroupKeepsBuiltInID() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "dictation_style_groups": [
            {
              "id": "legacy-group-email",
              "name": "Email",
              "style_id": "email",
              "matchers": []
            },
            {
              "id": "legacy-group-writing",
              "name": "Writing",
              "style_id": "writing",
              "matchers": []
            }
          ]
        }
        """)

        #expect(config.dictationModes.map(\.id) == [
            DictationModes.BuiltIn.email.id,
            DictationModes.BuiltIn.notes.id,
            DictationModes.BuiltIn.coding.id,
            DictationModes.BuiltIn.messaging.id,
        ])
        // The group's own name survives even when its id becomes the built-in's.
        #expect((try mode(config, DictationModes.BuiltIn.notes.id)).name == "Writing")
    }

    @Test("a category group with a non-default style keeps its own id")
    func categoryGroupWithCustomStyleKeepsItsOwnID() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "custom_transcript_cleanup_prompts": [
            {"id": "terse", "name": "Terse", "prompt": "Be terse."}
          ],
          "dictation_style_groups": [
            {"id": "starter-group-email", "name": "Email", "style_id": "terse", "matchers": []}
          ]
        }
        """)

        #expect(config.dictationModes.map(\.id) == ["starter-group-email"] + builtInIDs)
        // The built-in Email is appended under its shipped name, suffixed past the collision.
        #expect((try mode(config, DictationModes.BuiltIn.email.id)).name == "Email (2)")
    }

    @Test("absent built-ins are appended disabled with their shipped fields")
    func absentBuiltInsAreAppendedDisabled() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "dictation_style_groups": [
            {"id": "legacy-group-email", "name": "Email", "style_id": "email", "matchers": []}
          ]
        }
        """)

        let shipped = DictationModes.builtInModes(isEnabled: false)
        for builtIn in [DictationModes.BuiltIn.notes, .coding, .messaging] {
            let appended = try mode(config, builtIn.id)
            let expected = try #require(shipped.first { $0.id == builtIn.id })
            #expect(appended == expected)
        }
    }

    // MARK: - Names

    @Test("a group and an unreferenced prompt sharing a name both stay saveable")
    func collidingNamesAreSuffixed() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "custom_transcript_cleanup_prompts": [
            {"id": "grouped", "name": "Formal", "prompt": "Formal group text."},
            {"id": "loose", "name": "Formal", "prompt": "Formal prompt text."}
          ],
          "dictation_style_groups": [
            {"id": "g", "name": "Formal", "style_id": "grouped", "matchers": []}
          ]
        }
        """)

        #expect(config.dictationModes.map(\.id) == ["g", "legacy-prompt-loose"] + builtInIDs)
        #expect((try mode(config, "g")).name == "Formal")
        #expect((try mode(config, "legacy-prompt-loose")).name == "Formal (2)")

        let names = config.dictationModes.map { $0.name.lowercased() }
        #expect(Set(names).count == names.count)
    }

    // MARK: - Sentinel (R9)

    /// Covers AE13.
    @Test(
        "a null, object, or malformed dictation_modes value still migrates",
        arguments: ["null", "{}", "42", "\"modes\""]
    )
    func malformedSentinelStillMigrates(_ value: String) throws {
        let config = try decode("""
        {
          "dictation_modes": \(value),
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "dictation_style_groups": [
            {"id": "team-chat", "name": "Team chat", "style_id": "message", "matchers": []}
          ]
        }
        """)

        #expect(config.dictationModesMigrationApplied)
        #expect(config.dictationModes.map(\.id) == ["team-chat"] + builtInIDs)
    }

    /// Covers AE13.
    @Test("an empty but valid dictation_modes array suppresses the migration")
    func emptyArraySuppressesMigration() throws {
        let config = try decode("""
        {
          "dictation_modes": [],
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "dictation_style_groups": [
            {"id": "team-chat", "name": "Team chat", "style_id": "message", "matchers": []}
          ]
        }
        """)

        #expect(config.dictationModesMigrationApplied == false)
        #expect(config.dictationModes.isEmpty)
    }

    @Test("a populated dictation_modes array suppresses the migration")
    func populatedArraySuppressesMigration() throws {
        let config = try decode("""
        {
          "dictation_modes": [{"id": "kept", "name": "Kept"}],
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "dictation_style_groups": [
            {"id": "team-chat", "name": "Team chat", "style_id": "message", "matchers": []}
          ]
        }
        """)

        #expect(config.dictationModesMigrationApplied == false)
        #expect(config.dictationModes.map(\.id) == ["kept"])
    }

    // MARK: - Determinism (KTD13)

    /// Covers AE13.
    @Test("the same legacy fixture decodes to equal mode arrays, ids included")
    func migrationIsDeterministic() throws {
        let json = """
        {
          "adaptive_dictation_styles_enabled": true,
          "dictation_style_ruleset_initialized": true,
          "custom_transcript_cleanup_prompts": [
            {"id": "terse", "name": "Terse", "prompt": "Be terse."},
            {"id": "loose", "name": "Loose", "prompt": "Be loose."}
          ],
          "dictation_style_groups": [
            {
              "id": "work",
              "name": "Work",
              "style_id": "email",
              "matchers": [
                {"id": "m1", "kind": "bundle_id", "pattern": "com.apple.mail"},
                {"id": "m2", "kind": "hostname", "pattern": "mail.google.com"}
              ]
            }
          ],
          "dictation_style_exact_exceptions": [
            {"id": "e1", "kind": "bundle_id", "target": "com.apple.notes", "style_id": "terse"}
          ]
        }
        """

        let first = try decode(json)
        let second = try decode(json)

        #expect(first.dictationModes == second.dictationModes)
        #expect(first.dictationModes.map(\.id) == [
            "work",
            "legacy-style-terse",
            "legacy-prompt-loose",
        ] + builtInIDs)
    }

    /// Pre-August configs never had groups; they had category, app, and domain rules.
    @Test("a pre-canonical config projects its category and app rules into modes")
    func preCanonicalRulesProjectIntoModes() throws {
        let config = try decode("""
        {
          "adaptive_dictation_styles_enabled": true,
          "custom_transcript_cleanup_prompts": [
            {"id": "terse", "name": "Terse", "prompt": "Be terse."}
          ],
          "dictation_style_category_assignments": {"messages": "message"},
          "dictation_style_app_rules": [
            {"bundle_id": "com.example.chat", "display_name": "Chat", "category_id": "messages"},
            {"bundle_id": "com.example.terse", "display_name": "Terse", "style_id": "terse"}
          ],
          "dictation_style_domain_rules": [
            {"hostname": "chat.example.com", "category_id": "messages"}
          ]
        }
        """)

        // The projected category group carries the category's default style, so it
        // lands on the built-in id for that category (R8).
        let messages = try mode(config, DictationModes.BuiltIn.messaging.id)
        #expect(messages.instructions == (try prompt(TranscriptCleanupPrompts.messageID)))
        #expect(messages.appBundleIDs.contains("com.example.chat"))
        #expect(messages.websiteHostnames.contains("chat.example.com"))

        // A style-only app rule becomes an exception, so it lands on the style's mode.
        let terse = try mode(config, "legacy-style-terse")
        #expect(terse.appBundleIDs == ["com.example.terse"])
    }

    @Test("a config with no legacy state migrates to the disabled built-ins alone")
    func emptyLegacyStateYieldsBuiltInsOnly() throws {
        let config = try decode("{}")

        #expect(config.dictationModesMigrationApplied)
        #expect(config.dictationModes == DictationModes.builtInModes(isEnabled: false))
    }

    // MARK: - Website matching migration

    /// A legacy config predates `dictation_modes` and `match_modes_by_website` alike, so
    /// the fallback must read the user's stored `enable_screen_context`, not the
    /// property's declared default (regression: the fallback used to read the
    /// not-yet-decoded property and always observed `false`).
    @Test(
        "match_modes_by_website falls back to the stored enable_screen_context on upgrade",
        arguments: [true, false]
    )
    func matchModesByWebsiteFallsBackToStoredScreenContext(_ enableScreenContext: Bool) throws {
        let config = try decode("""
        {
          "enable_screen_context": \(enableScreenContext)
        }
        """)

        #expect(config.matchModesByWebsite == enableScreenContext)
    }

    // MARK: - Backup and save-on-load (R9, KTD13)

    private func makeStore(_ json: String) throws -> (ConfigStore, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.json")
        try Data(json.utf8).write(to: configURL)
        return (ConfigStore(supportDirectory: directory), configURL, directory.appendingPathComponent("config.pre-modes.json"))
    }

    private static let legacyFixture = """
    {
      "adaptive_dictation_styles_enabled": true,
      "dictation_style_ruleset_initialized": true,
      "dictation_style_groups": [
        {
          "id": "team-chat",
          "name": "Team chat",
          "style_id": "message",
          "matchers": [
            {"id": "m1", "kind": "bundle_id", "pattern": "com.tinyspeck.slackmacgap"},
            {"id": "m2", "kind": "hostname", "pattern": "web.whatsapp.com"}
          ]
        }
      ]
    }
    """

    /// Covers AE1.
    @Test("the migrating load backs up the original bytes and rewrites the config once")
    func migratingLoadWritesBackupAndConfig() throws {
        let (store, configURL, backupURL) = try makeStore(Self.legacyFixture)
        defer { try? FileManager.default.removeItem(at: store.supportDirectory()) }
        let original = try #require(
            JSONSerialization.jsonObject(with: try Data(contentsOf: configURL)) as? NSDictionary
        )

        let loaded = store.load()

        #expect(loaded.dictationModes.first?.id == "team-chat")
        // The backup is re-serialized (credentials get scrubbed on the way through), so
        // it is compared for semantic equality rather than byte-for-byte identity.
        let backedUp = try #require(
            JSONSerialization.jsonObject(with: try Data(contentsOf: backupURL)) as? NSDictionary
        )
        #expect(backedUp == original)

        let attributes = try FileManager.default.attributesOfItem(atPath: backupURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let rewritten = try #require(
            JSONSerialization.jsonObject(with: try Data(contentsOf: configURL)) as? [String: Any]
        )
        let modes = try #require(rewritten["dictation_modes"] as? [[String: Any]])
        #expect(modes.first?["id"] as? String == "team-chat")
        #expect(rewritten["dictation_style_groups"] == nil)
        #expect(rewritten["adaptive_dictation_styles_enabled"] == nil)
    }

    /// Covers AE1.
    @Test("a second load neither re-migrates nor touches the backup")
    func secondLoadLeavesTheBackupAlone() throws {
        let (store, _, backupURL) = try makeStore(Self.legacyFixture)
        defer { try? FileManager.default.removeItem(at: store.supportDirectory()) }

        _ = store.load()
        let backupAfterFirstLoad = try Data(contentsOf: backupURL)
        let modifiedBefore = try #require(
            FileManager.default.attributesOfItem(atPath: backupURL.path)[.modificationDate] as? Date
        )

        let second = store.load()

        #expect(second.dictationModesMigrationApplied == false)
        #expect(try Data(contentsOf: backupURL) == backupAfterFirstLoad)
        let modifiedAfter = try #require(
            FileManager.default.attributesOfItem(atPath: backupURL.path)[.modificationDate] as? Date
        )
        #expect(modifiedAfter == modifiedBefore)
    }

    @Test("an existing backup is never overwritten and does not block the migrating save")
    func existingBackupIsPreserved() throws {
        let (store, configURL, backupURL) = try makeStore(Self.legacyFixture)
        defer { try? FileManager.default.removeItem(at: store.supportDirectory()) }
        try Data("{\"earlier\": true}".utf8).write(to: backupURL)

        _ = store.load()

        #expect(try Data(contentsOf: backupURL) == Data("{\"earlier\": true}".utf8))
        let rewritten = try #require(
            JSONSerialization.jsonObject(with: try Data(contentsOf: configURL)) as? [String: Any]
        )
        #expect(rewritten["dictation_modes"] != nil)
    }

    @Test("a failed backup aborts the migrating save and leaves the legacy file intact")
    func failedBackupAbortsTheSave() throws {
        let (store, configURL, backupURL) = try makeStore(Self.legacyFixture)
        defer {
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.removeItem(at: store.supportDirectory())
        }
        let original = try Data(contentsOf: configURL)
        // A directory at the backup path cannot be replaced by a file write.
        try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: true)

        let loaded = store.load()

        #expect(loaded.dictationModes.first?.id == "team-chat")
        #expect(try Data(contentsOf: configURL) == original)
    }
}
