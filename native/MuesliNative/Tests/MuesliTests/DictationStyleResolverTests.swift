import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("DictationStyleResolver")
struct DictationStyleResolverTests {
    @Test("adaptive styles stay opt-in and preserve the current global prompt")
    func adaptiveStylesOffUsesCurrentGlobalPrompt() {
        var config = configuredStyles()
        config.adaptiveDictationStylesEnabled = false

        let result = DictationStyleResolver.resolve(
            config: config,
            bundleID: "com.tinyspeck.slackmacgap",
            hostname: "docs.google.com"
        )

        #expect(result.styleID == "global-style")
        #expect(result.prompt == "Global prompt exactly as configured")
        #expect(result.source == .global)
    }

    @Test("first enable seeds canonical starter groups without changing global selection")
    func firstEnableSeedsCanonicalGroups() {
        var config = AppConfig()
        config.activeTranscriptCleanupPromptId = TranscriptCleanupPrompts.mixedLanguageRepairID
        config.postProcessorSystemPrompt = "Unchanged global prompt"
        let enabled = DictationStyleResolver.enablingAdaptiveStyles(in: config)
        let enabledAgain = DictationStyleResolver.enablingAdaptiveStyles(in: enabled)

        #expect(enabled.adaptiveDictationStylesEnabled)
        #expect(enabled.activeTranscriptCleanupPromptId == config.activeTranscriptCleanupPromptId)
        #expect(enabled.postProcessorSystemPrompt == "Unchanged global prompt")
        #expect(enabled.dictationStyleRulesetInitialized)
        #expect(enabled.dictationStyleGroups.map(\.styleID) == ["message", "email", "writing", "code"])
        #expect(enabledAgain.dictationStyleGroups == enabled.dictationStyleGroups)
    }

    @Test("selection follows domain app category global and built-in precedence")
    func selectionPrecedence() {
        var config = configuredStyles()

        #expect(resolve(config).styleID == "domain-style")
        #expect(resolve(config).source == .domain)

        config.dictationStyleDomainRules[0].styleID = "missing"
        #expect(resolve(config).styleID == "app-style")
        #expect(resolve(config).source == .app)

        config.dictationStyleAppRules[0].styleID = ""
        #expect(resolve(config).styleID == "category-style")
        #expect(resolve(config).source == .category)

        config.dictationStyleCategoryAssignments["writing"] = "missing"
        #expect(resolve(config).styleID == "global-style")
        #expect(resolve(config).source == .global)

        config.activeTranscriptCleanupPromptId = "missing"
        #expect(resolve(config).styleID == TranscriptCleanupPrompts.defaultID)
        #expect(resolve(config).source == .builtInFallback)
    }

    @Test("missing exact references fall through without hiding category membership")
    func invalidExactReferencesFallThrough() {
        var config = configuredStyles()
        config.dictationStyleDomainRules[0].styleID = "  "
        config.dictationStyleAppRules[0].styleID = "missing"

        let result = resolve(config)

        #expect(result.styleID == "category-style")
        #expect(result.source == .category)
        #expect(result.categoryID == DictationStyleCategory.writing.rawValue)
    }

    @Test("target normalization is exact and rejects URL identity")
    func targetNormalization() {
        #expect(DictationStyleResolver.normalizeBundleID(" COM.Microsoft.VSCode ") == "com.microsoft.vscode")
        #expect(DictationStyleResolver.normalizeBundleID("Notes") == nil)
        #expect(DictationStyleResolver.normalizeHostname("MAIL.Example.com.:443") == "mail.example.com")
        #expect(DictationStyleResolver.normalizeHostname("one.mail.example.com") == "one.mail.example.com")
        #expect(DictationStyleResolver.normalizeHostname("https://mail.example.com/inbox") == nil)
        #expect(DictationStyleResolver.normalizeHostname("mail.example.com?inbox=1") == nil)
        #expect(DictationStyleResolver.normalizeHostname("mail.example.com:70000") == nil)
        #expect(DictationStyleResolver.hasDomainRuleCollision(
            hostname: "MAIL.Example.com.:443",
            in: [DictationStyleDomainRule(hostname: "mail.example.com", styleID: "email")]
        ))
        #expect(DictationStyleResolver.hasAppRuleCollision(
            bundleID: "COM.MICROSOFT.VSCODE",
            in: [DictationStyleAppRule(bundleID: "com.microsoft.vscode", styleID: "code")]
        ))
    }

    @Test("user membership outranks curated hostname and curated hostname outranks bundle")
    func categoryClassificationOrder() {
        var config = AppConfig()
        let target = DictationStyleTarget(
            bundleID: "com.tinyspeck.slackmacgap",
            hostname: "docs.google.com"
        )

        #expect(DictationStyleResolver.category(for: target, config: config) == .writing)

        config.dictationStyleAppRules = [
            DictationStyleAppRule(bundleID: "com.tinyspeck.slackmacgap", categoryID: "email"),
        ]
        #expect(DictationStyleResolver.category(for: target, config: config) == .email)

        config.dictationStyleDomainRules = [
            DictationStyleDomainRule(hostname: "docs.google.com", categoryID: "code"),
        ]
        #expect(DictationStyleResolver.category(for: target, config: config) == .code)
        #expect(
            DictationStyleResolver.category(
                for: DictationStyleTarget(bundleID: "com.unknown.app", hostname: "unknown.example"),
                config: config
            ) == nil
        )
    }

    @Test("deletion repairs references and leaves captured selections unchanged")
    func deletionRepair() {
        var config = configuredStyles()
        config.activeTranscriptCleanupPromptId = "domain-style"
        config.postProcessorSystemPrompt = "Domain prompt"
        config.dictationStyleCategoryAssignments["email"] = "domain-style"
        config.dictationStyleAppRules.append(
            DictationStyleAppRule(bundleID: "com.only.style", styleID: "domain-style")
        )
        config.dictationStyleDomainRules.append(
            DictationStyleDomainRule(hostname: "membership.example", categoryID: "email", styleID: "domain-style")
        )
        let captured = DictationStyleResolver.resolve(
            config: config,
            bundleID: "com.tinyspeck.slackmacgap",
            hostname: "docs.google.com"
        )

        let repaired = DictationStyleResolver.deletingCustomStyle(id: "domain-style", from: config)

        #expect(captured.prompt == "Domain prompt")
        #expect(repaired.customTranscriptCleanupPrompts.contains(where: { $0.id == "domain-style" }) == false)
        #expect(repaired.activeTranscriptCleanupPromptId == TranscriptCleanupPrompts.defaultID)
        #expect(repaired.postProcessorSystemPrompt == PostProcessorOption.defaultSystemPrompt)
        #expect(repaired.dictationStyleCategoryAssignments["email"] == nil)
        #expect(repaired.dictationStyleCategoryAssignments["writing"] == "category-style")
        #expect(repaired.dictationStyleAppRules.first?.categoryID == "writing")
        #expect(repaired.dictationStyleAppRules.first?.styleID == "app-style")
        #expect(repaired.dictationStyleAppRules.contains(where: { $0.bundleID == "com.only.style" }) == false)
        #expect(repaired.dictationStyleDomainRules.last?.hostname == "membership.example")
        #expect(repaired.dictationStyleDomainRules.last?.categoryID == "email")
        #expect(repaired.dictationStyleDomainRules.last?.styleID == nil)
    }

    @Test("legacy migration is deterministic and exact style rules displace curated membership")
    func legacyMigrationPrefersExactRules() {
        var config = AppConfig()
        config.dictationStyleCategoryAssignments = ["messages": "message"]
        config.dictationStyleAppRules = [
            DictationStyleAppRule(bundleID: "com.tinyspeck.slackmacgap", styleID: "email"),
        ]
        let projection = DictationStyleResolver.projectLegacyConfiguration(config)

        #expect(projection.initialized)
        #expect(projection.exceptions == [
            DictationStyleExactException(id: "legacy-exception-bundle-id-com.tinyspeck.slackmacgap", kind: .bundleID, target: "com.tinyspeck.slackmacgap", styleID: "email"),
        ])
        #expect(projection.groups.first?.matchers.contains(where: { $0.pattern == "com.tinyspeck.slackmacgap" }) == false)
        #expect(DictationStyleResolver.projectLegacyConfiguration(config) == projection)
    }

    @Test("legacy rules with membership and direct style project both records")
    func legacyMigrationPreservesMembershipAndException() {
        var config = AppConfig()
        config.dictationStyleCategoryAssignments = ["messages": "message"]
        config.dictationStyleAppRules = [
            DictationStyleAppRule(
                bundleID: "com.tinyspeck.slackmacgap",
                categoryID: "messages",
                styleID: "email"
            ),
        ]

        let projection = DictationStyleResolver.projectLegacyConfiguration(config)

        #expect(projection.groups.first?.matchers.contains(where: {
            $0.kind == .bundleID && $0.pattern == "com.tinyspeck.slackmacgap"
        }) == true)
        let preservedException = projection.exceptions.contains(where: {
            $0.kind == .bundleID
                && $0.target == "com.tinyspeck.slackmacgap"
                && $0.styleID == "email"
        })
        #expect(preservedException)
    }

    @Test("initialized empty rulesets never reseed and canonical conflicts are rejected")
    func initializedEmptyAndCanonicalValidation() {
        var empty = AppConfig()
        empty.adaptiveDictationStylesEnabled = true
        empty.dictationStyleRulesetInitialized = true
        #expect(DictationStyleResolver.enablingAdaptiveStyles(in: empty).dictationStyleGroups.isEmpty)

        var invalid = empty
        invalid.dictationStyleGroups = [DictationStyleGroup(id: "", name: "Broken", styleID: "default")]
        #expect(throws: DictationStyleResolver.ConfigurationError.self) {
            _ = try DictationStyleResolver.prepareCanonicalConfiguration(invalid)
        }

        var legacy = AppConfig()
        legacy.dictationStyleCategoryAssignments = ["messages": "missing-style"]
        legacy.dictationStyleAppRules = [DictationStyleAppRule(bundleID: "bad", styleID: "missing-style")]
        #expect(!DictationStyleResolver.projectLegacyConfiguration(legacy).initialized)
    }

    private func resolve(_ config: AppConfig) -> DictationStyleSelectionResult {
        DictationStyleResolver.resolve(
            config: config,
            bundleID: "com.tinyspeck.slackmacgap",
            hostname: "docs.google.com"
        )
    }

    private func configuredStyles() -> AppConfig {
        var config = AppConfig()
        config.adaptiveDictationStylesEnabled = true
        config.customTranscriptCleanupPrompts = [
            CustomTranscriptCleanupPrompt(id: "domain-style", name: "Domain", prompt: "Domain prompt"),
            CustomTranscriptCleanupPrompt(id: "app-style", name: "App", prompt: "App prompt"),
            CustomTranscriptCleanupPrompt(id: "category-style", name: "Category", prompt: "Category prompt"),
            CustomTranscriptCleanupPrompt(id: "global-style", name: "Global", prompt: "Global prompt definition"),
        ]
        config.activeTranscriptCleanupPromptId = "global-style"
        config.postProcessorSystemPrompt = "Global prompt exactly as configured"
        config.dictationStyleCategoryAssignments = ["writing": "category-style"]
        config.dictationStyleAppRules = [
            DictationStyleAppRule(
                bundleID: "com.tinyspeck.slackmacgap",
                categoryID: "writing",
                styleID: "app-style"
            ),
        ]
        config.dictationStyleDomainRules = [
            DictationStyleDomainRule(
                hostname: "docs.google.com",
                categoryID: "writing",
                styleID: "domain-style"
            ),
        ]
        return config
    }
}
