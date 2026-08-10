import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Dictation style settings")
struct DictationStyleSettingsTests {
    @Test("adaptive toggle seeds groups and disabling preserves configuration")
    func adaptiveTogglePreservesConfiguration() {
        var config = AppConfig()
        config.activeTranscriptCleanupPromptId = TranscriptCleanupPrompts.emailID

        let enabled = DictationStyleSettingsModel.enabledConfiguration(from: config, enabled: true)
        let disabled = DictationStyleSettingsModel.enabledConfiguration(from: enabled, enabled: false)

        #expect(enabled.adaptiveDictationStylesEnabled)
        #expect(enabled.dictationStyleRulesetInitialized)
        #expect(enabled.dictationStyleGroups.count == DictationStyleCategory.allCases.count)
        #expect(enabled.activeTranscriptCleanupPromptId == TranscriptCleanupPrompts.emailID)
        #expect(disabled.adaptiveDictationStylesEnabled == false)
        #expect(disabled.dictationStyleGroups == enabled.dictationStyleGroups)
    }

    @Test("hostname input accepts URLs and normalizes exact hosts")
    func hostnameNormalization() throws {
        #expect(DictationStyleSettingsModel.normalizedHostnameInput(" HTTPS://Docs.Google.COM:443/path?q=1 ") == "docs.google.com")
        #expect(DictationStyleSettingsModel.normalizedHostnameInput("docs.google.com/path") == "docs.google.com")
        #expect(DictationStyleSettingsModel.normalizedHostnameInput("not a host") == nil)

        let first = try DictationStyleSettingsModel.addingDomainRule(
            input: "https://Docs.Google.com/document/1",
            to: AppConfig()
        )
        #expect(first.dictationStyleDomainRules.first?.hostname == "docs.google.com")
        #expect(first.dictationStyleDomainRules.first?.styleID == nil)
        #expect(DictationStyleResolver.sanitizeConfiguration(first).dictationStyleDomainRules.count == 1)
        #expect(throws: DictationStyleSettingsError.self) {
            try DictationStyleSettingsModel.addingDomainRule(input: "DOCS.GOOGLE.COM", to: first)
        }
    }

    @Test("app rules require and normalize a unique bundle identifier")
    func appRuleValidation() throws {
        #expect(throws: DictationStyleSettingsError.self) {
            try DictationStyleSettingsModel.addingAppRule(bundleID: nil, displayName: "Unknown", to: AppConfig())
        }
        let first = try DictationStyleSettingsModel.addingAppRule(
            bundleID: " COM.APPLE.MAIL ",
            displayName: " Mail ",
            to: AppConfig()
        )
        #expect(first.dictationStyleAppRules.first?.bundleID == "com.apple.mail")
        #expect(first.dictationStyleAppRules.first?.displayName == "Mail")
        #expect(first.dictationStyleAppRules.first?.styleID == nil)
        #expect(DictationStyleResolver.sanitizeConfiguration(first).dictationStyleAppRules.count == 1)
        #expect(throws: DictationStyleSettingsError.self) {
            try DictationStyleSettingsModel.addingAppRule(
                bundleID: "com.apple.mail",
                displayName: "Mail",
                to: first
            )
        }
    }

    @Test("effective state names exact and inherited sources")
    func effectiveStateExplainsSource() {
        var config = configuredStyles()
        let exact = DictationStyleSettingsModel.effectiveState(
            config: config,
            bundleID: "com.apple.mail",
            hostname: nil
        )
        #expect(exact.styleName == "App style")
        #expect(exact.sourceLabel == "Exact app")

        config.dictationStyleAppRules[0].styleID = nil
        let inherited = DictationStyleSettingsModel.effectiveState(
            config: config,
            bundleID: "com.apple.mail",
            hostname: nil
        )
        #expect(inherited.styleName == "Category style")
        #expect(inherited.sourceLabel == "Email")
    }

    @Test("deletion impact reports and repairs every reference in one candidate")
    func deletionRepairsReferences() {
        var config = configuredStyles()
        config.activeTranscriptCleanupPromptId = "app-style"
        config.postProcessorSystemPrompt = "App prompt"
        config.dictationStyleCategoryAssignments["writing"] = "app-style"
        config.dictationStyleDomainRules = [
            DictationStyleDomainRule(hostname: "mail.example", styleID: "app-style"),
        ]
        let impact = DictationStyleSettingsModel.deletionImpact(styleID: "app-style", in: config)
        let repaired = DictationStyleSettingsModel.deletingStyle(id: "app-style", from: config)

        #expect(impact.repairsGlobal)
        #expect(impact.categoryCount == 1)
        #expect(impact.appCount == 1)
        #expect(impact.domainCount == 1)
        #expect(impact.confirmationMessage.contains("1 app rule"))
        #expect(repaired.activeTranscriptCleanupPromptId == TranscriptCleanupPrompts.defaultID)
        #expect(repaired.dictationStyleCategoryAssignments["writing"] == nil)
        #expect(repaired.dictationStyleAppRules.first?.styleID == nil)
        #expect(repaired.dictationStyleDomainRules.first?.styleID == nil)
        #expect(repaired.customTranscriptCleanupPrompts.contains(where: { $0.id == "app-style" }) == false)
    }

    @Test("style validation is case insensitive across built-ins and custom styles")
    func styleValidation() throws {
        var config = AppConfig()
        config.customTranscriptCleanupPrompts = [
            CustomTranscriptCleanupPrompt(id: "custom", name: "Concise", prompt: "Shorten it"),
        ]
        #expect(throws: DictationStyleSettingsError.self) {
            try DictationStyleSettingsModel.validateStyle(
                name: " concise ",
                instructions: "Instructions",
                excludingID: nil,
                config: config
            )
        }
        try DictationStyleSettingsModel.validateStyle(
            name: "Concise",
            instructions: "Updated",
            excludingID: "custom",
            config: config
        )
    }

    @Test("failed persistence does not publish the candidate")
    func failedPersistenceRetainsCurrentConfiguration() {
        var live = AppConfig()
        live.adaptiveDictationStylesEnabled = false

        do {
            live = try DictationStyleSettingsModel.committing(
                current: live,
                mutate: { $0.adaptiveDictationStylesEnabled = true },
                persist: { _ in throw PersistenceFailure.expected }
            )
            Issue.record("Expected persistence to fail")
        } catch {
            #expect(error as? PersistenceFailure == .expected)
        }
        #expect(live.adaptiveDictationStylesEnabled == false)
    }

    @Test("invalid canonical settings candidate never reaches persistence")
    func invalidCanonicalCandidateIsRejectedBeforePersistence() {
        var current = AppConfig()
        current.dictationStyleRulesetInitialized = true
        current.customTranscriptCleanupPrompts = [
            CustomTranscriptCleanupPrompt(id: "custom", name: "Custom", prompt: "Prompt"),
        ]
        current.activeTranscriptCleanupPromptId = "custom"
        current.postProcessorSystemPrompt = "Prompt"
        var persisted = false

        #expect(throws: DictationStyleResolver.ConfigurationError.self) {
            _ = try DictationStyleSettingsModel.committing(
                current: current,
                mutate: { $0.dictationStyleGroups = [
                    DictationStyleGroup(id: "group", name: "Group", styleID: "missing"),
                ] },
                persist: { candidate in
                    persisted = true
                    return candidate
                }
            )
        }
        #expect(!persisted)
    }

    @Test("canonical group effective state is textual and independent of exceptions")
    func canonicalGroupEffectiveState() {
        var config = AppConfig()
        config.adaptiveDictationStylesEnabled = true
        config.dictationStyleRulesetInitialized = true
        config.customTranscriptCleanupPrompts = [
            CustomTranscriptCleanupPrompt(id: "group-style", name: "Group style", prompt: "Group prompt"),
        ]
        config.activeTranscriptCleanupPromptId = "group-style"
        config.postProcessorSystemPrompt = "Group prompt"
        config.dictationStyleGroups = [
            DictationStyleGroup(
                id: "group",
                name: "Client Work",
                styleID: "group-style",
                matchers: [DictationStyleMatcher(id: "matcher", kind: .bundleID, pattern: "com.example.app")]
            ),
        ]

        let inherited = DictationStyleSettingsModel.effectiveState(config: config, bundleID: "com.example.app", hostname: nil)
        #expect(inherited.sourceLabel == "Group")
        #expect(inherited.accessibilityDescription.contains("Group"))

        config.dictationStyleExactExceptions = [
            DictationStyleExactException(id: "exception", kind: .bundleID, target: "com.example.app", styleID: "group-style"),
        ]
        let exact = DictationStyleSettingsModel.effectiveState(config: config, bundleID: "com.example.app", hostname: nil)
        #expect(exact.sourceLabel == "Exact exception")
    }

    @Test("group workspace mutations preserve identities and deletion boundaries")
    func groupWorkspaceMutations() throws {
        var config = AppConfig()
        config.adaptiveDictationStylesEnabled = true
        config.dictationStyleRulesetInitialized = true
        config = try DictationStyleSettingsModel.addingGroup(
            name: "  Client   Work ",
            styleID: TranscriptCleanupPrompts.defaultID,
            id: "group-a",
            to: config
        )
        config = try DictationStyleSettingsModel.renamingGroup(
            id: "group-a",
            name: "Client Writing",
            in: config
        )
        config.dictationStyleGroups[0].matchers = [
            DictationStyleMatcher(id: "matcher-a", kind: .bundleID, pattern: "com.example.*"),
        ]
        config.dictationStyleExactExceptions = [
            DictationStyleExactException(
                id: "exception-a",
                kind: .bundleID,
                target: "com.example.mail",
                styleID: TranscriptCleanupPrompts.defaultID
            ),
        ]
        config = try DictationStyleSettingsModel.duplicatingGroup(
            id: "group-a",
            newID: "group-b",
            in: config
        )

        #expect(config.dictationStyleGroups.map(\.id) == ["group-a", "group-b"])
        #expect(config.dictationStyleGroups[0].name == "Client Writing")
        #expect(config.dictationStyleGroups[1].name == "Client Writing Copy")
        #expect(config.dictationStyleGroups[1].matchers.isEmpty)
        #expect(throws: DictationStyleSettingsError.self) {
            try DictationStyleSettingsModel.renamingGroup(id: "group-b", name: "client writing", in: config)
        }

        let impact = try DictationStyleSettingsModel.groupDeletionImpact(
            id: "group-a",
            knownTargets: [DictationStyleTarget(bundleID: "com.example.mail", hostname: nil)],
            in: config
        )
        #expect(impact.matcherCount == 1)
        #expect(impact.knownTargetCount == 1)
        #expect(impact.survivingExceptionCount == 1)

        var persistenceCount = 0
        let committed = try DictationStyleSettingsModel.committing(
            current: config,
            mutate: { $0 = DictationStyleSettingsModel.deletingGroup(id: "group-a", from: $0) },
            persist: { candidate in persistenceCount += 1; return candidate }
        )
        #expect(persistenceCount == 1)
        #expect(committed.dictationStyleGroups.map(\.id) == ["group-b"])
        #expect(committed.dictationStyleExactExceptions.map(\.id) == ["exception-a"])
    }

    @Test("known targets include exact group matchers and deduplicate configured identities")
    func knownTargetsIncludeExactGroupMatchers() {
        let targets = DictationStyleSettingsModel.knownTargets(
            appBundleIDs: ["com.example.mail"],
            groups: [DictationStyleGroup(id: "group", name: "Group", styleID: "default", matchers: [
                DictationStyleMatcher(id: "exact-app", kind: .bundleID, pattern: "com.example.mail"),
                DictationStyleMatcher(id: "exact-site", kind: .hostname, pattern: "docs.example.com"),
                DictationStyleMatcher(id: "wildcard", kind: .hostname, pattern: "*.example.com"),
            ])],
            exactExceptions: [
                DictationStyleExactException(id: "duplicate", kind: .hostname, target: "docs.example.com", styleID: "default"),
            ]
        )

        #expect(targets == [
            DictationStyleTarget(bundleID: "com.example.mail", hostname: nil),
            DictationStyleTarget(bundleID: nil, hostname: "docs.example.com"),
        ])
    }

    @Test("style editor detects unapplied field changes")
    func styleEditorDirtyState() {
        var config = AppConfig()
        config.customTranscriptCleanupPrompts = [
            CustomTranscriptCleanupPrompt(id: "custom", name: "Custom", prompt: "Original"),
        ]

        #expect(!DictationStyleSettingsModel.hasUnappliedStyleChanges(
            styleID: "custom", name: "Custom", instructions: "Original", in: config
        ))
        #expect(DictationStyleSettingsModel.hasUnappliedStyleChanges(
            styleID: "custom", name: "Custom", instructions: "Changed", in: config
        ))
    }

    private func configuredStyles() -> AppConfig {
        var config = AppConfig()
        config.adaptiveDictationStylesEnabled = true
        config.customTranscriptCleanupPrompts = [
            CustomTranscriptCleanupPrompt(id: "app-style", name: "App style", prompt: "App prompt"),
            CustomTranscriptCleanupPrompt(id: "category-style", name: "Category style", prompt: "Category prompt"),
        ]
        config.dictationStyleCategoryAssignments = ["email": "category-style"]
        config.dictationStyleAppRules = [
            DictationStyleAppRule(bundleID: "com.apple.mail", categoryID: "email", styleID: "app-style"),
        ]
        return config
    }

    private enum PersistenceFailure: Error, Equatable {
        case expected
    }
}
