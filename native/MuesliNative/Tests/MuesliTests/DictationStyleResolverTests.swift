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
        config.activeTranscriptCleanupPromptId = TranscriptCleanupPrompts.emailID
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

    @Test("canonical wildcard patterns normalize and resolve by specificity")
    func canonicalWildcardResolution() throws {
        #expect(DictationStyleResolver.canonicalPattern(" COM.MICROSOFT.*** ", kind: .bundleID) == "com.microsoft.*")
        #expect(DictationStyleResolver.canonicalPattern("*.Google.COM.", kind: .hostname) == "*.google.com")
        #expect(DictationStyleResolver.canonicalPattern("docs.google.com/path", kind: .hostname) == nil)
        #expect(DictationStyleResolver.canonicalPattern("com..microsoft", kind: .bundleID) == nil)
        #expect(DictationStyleResolver.canonicalPattern("éxample.*", kind: .hostname) == nil)
        #expect(DictationStyleResolver.canonicalPattern("-invalid*", kind: .hostname) == nil)

        var config = canonicalConfig()
        config.dictationStyleGroups = [
            group("broad", styleID: "broad", matcher: matcher("broad-matcher", .hostname, "*.example.com")),
            group("narrow", styleID: "narrow", matcher: matcher("narrow-matcher", .hostname, "docs.example.com")),
        ]
        let prepared = try DictationStyleResolver.prepareCanonicalConfiguration(config)
        #expect(prepared.dictationStyleGroups == config.dictationStyleGroups)
        #expect(prepared.dictationStyleExactExceptions == config.dictationStyleExactExceptions)
        #expect(prepared.customTranscriptCleanupPrompts == config.customTranscriptCleanupPrompts)

        let result = DictationStyleResolver.resolve(config: config, bundleID: nil, hostname: "docs.example.com")
        #expect(result.styleID == "narrow")
        #expect(result.source == .group)
        #expect(result.groupID == "narrow")
    }

    @Test("equal-specificity overlaps conflict while safe overlaps remain valid")
    func canonicalOverlapValidation() throws {
        var conflict = canonicalConfig()
        conflict.dictationStyleGroups = [
            group("left", styleID: "broad", matcher: matcher("left-matcher", .hostname, "a*.example.com")),
            group("right", styleID: "narrow", matcher: matcher("right-matcher", .hostname, "*a.example.com")),
        ]
        #expect(throws: DictationStyleResolver.ConfigurationError.self) {
            _ = try DictationStyleResolver.prepareCanonicalConfiguration(conflict)
        }

        var unequal = canonicalConfig()
        unequal.dictationStyleGroups = [
            group("broad", styleID: "broad", matcher: matcher("broad-matcher", .hostname, "*.example.com")),
            group("narrow", styleID: "narrow", matcher: matcher("narrow-matcher", .hostname, "docs*.example.com")),
        ]
        _ = try DictationStyleResolver.prepareCanonicalConfiguration(unequal)
        #expect(DictationStyleResolver.resolve(
            config: unequal,
            bundleID: nil,
            hostname: "docs.example.com"
        ).styleID == "narrow")

        unequal.dictationStyleGroups.reverse()
        #expect(DictationStyleResolver.resolve(
            config: unequal,
            bundleID: nil,
            hostname: "docs.example.com"
        ).styleID == "narrow")

        var sameGroup = canonicalConfig()
        sameGroup.dictationStyleGroups = [DictationStyleGroup(
            id: "one",
            name: "One",
            styleID: "broad",
            matchers: [
                matcher("one-left", .hostname, "a*.example.com"),
                matcher("one-right", .hostname, "*a.example.com"),
            ]
        )]
        _ = try DictationStyleResolver.prepareCanonicalConfiguration(sameGroup)
    }

    @Test("exact matcher outranks an overlapping wildcard with equal literal specificity")
    func exactMatcherOutranksEqualSpecificityWildcard() throws {
        var config = canonicalConfig()
        config.dictationStyleGroups = [
            group("wildcard", styleID: "broad", matcher: matcher("wildcard-matcher", .bundleID, "com.microsoft.word*")),
            group("exact", styleID: "narrow", matcher: matcher("exact-matcher", .bundleID, "com.microsoft.word")),
        ]

        _ = try DictationStyleResolver.prepareCanonicalConfiguration(config)
        let result = DictationStyleResolver.resolve(
            config: config,
            bundleID: "com.microsoft.word",
            hostname: nil
        )

        #expect(result.styleID == "narrow")
        #expect(result.groupID == "exact")
    }

    @Test("canonical hostname groups outrank app groups and conflicts fall through")
    func canonicalTieringAndConflictFallback() throws {
        var config = canonicalConfig()
        config.dictationStyleGroups = [
            group("host-one", styleID: "broad", matcher: matcher("host-one-matcher", .hostname, "*.example.com")),
            group("host-two", styleID: "narrow", matcher: matcher("host-two-matcher", .hostname, "*.example.com")),
            group("app", styleID: "app", matcher: matcher("app-matcher", .bundleID, "com.example.browser")),
        ]

        #expect(throws: DictationStyleResolver.ConfigurationError.self) {
            _ = try DictationStyleResolver.prepareCanonicalConfiguration(config)
        }
        let fallback = DictationStyleResolver.resolve(
            config: config,
            bundleID: "com.example.browser",
            hostname: "docs.example.com"
        )
        #expect(fallback.styleID == "app")

        config.dictationStyleGroups.remove(at: 1)
        let hostnameWinner = DictationStyleResolver.resolve(
            config: config,
            bundleID: "com.example.browser",
            hostname: "docs.example.com"
        )
        #expect(hostnameWinner.styleID == "broad")
    }

    @Test("canonical validation rejects duplicate and invalid rule data")
    func strictCanonicalValidation() {
        var duplicateNames = canonicalConfig()
        duplicateNames.dictationStyleGroups = [
            group("one", styleID: "broad", matcher: matcher("one-matcher", .bundleID, "com.example.one")),
            group("two", name: "ONE", styleID: "narrow", matcher: matcher("two-matcher", .bundleID, "com.example.two")),
        ]
        #expect(throws: DictationStyleResolver.ConfigurationError.self) {
            _ = try DictationStyleResolver.prepareCanonicalConfiguration(duplicateNames)
        }

        var duplicateMatcherID = canonicalConfig()
        duplicateMatcherID.dictationStyleGroups = [
            group("one", styleID: "broad", matcher: matcher("same", .bundleID, "com.example.one")),
            group("two", styleID: "narrow", matcher: matcher("same", .bundleID, "com.example.two")),
        ]
        #expect(throws: DictationStyleResolver.ConfigurationError.self) {
            _ = try DictationStyleResolver.prepareCanonicalConfiguration(duplicateMatcherID)
        }

        var duplicatePattern = canonicalConfig()
        duplicatePattern.dictationStyleGroups = [
            group("one", styleID: "broad", matcher: matcher("one-matcher", .bundleID, "com.example.*")),
            group("two", styleID: "narrow", matcher: matcher("two-matcher", .bundleID, "com.example.*")),
        ]
        #expect(throws: DictationStyleResolver.ConfigurationError.self) {
            _ = try DictationStyleResolver.prepareCanonicalConfiguration(duplicatePattern)
        }

        var duplicateStyles = canonicalConfig()
        duplicateStyles.customTranscriptCleanupPrompts.append(
            CustomTranscriptCleanupPrompt(id: "broad", name: "Different", prompt: "Duplicate ID")
        )
        #expect(throws: DictationStyleResolver.ConfigurationError.self) {
            _ = try DictationStyleResolver.prepareCanonicalConfiguration(duplicateStyles)
        }

        var duplicateStyleName = canonicalConfig()
        duplicateStyleName.customTranscriptCleanupPrompts.append(
            CustomTranscriptCleanupPrompt(id: "other", name: " broad ", prompt: "Duplicate name")
        )
        #expect(throws: DictationStyleResolver.ConfigurationError.self) {
            _ = try DictationStyleResolver.prepareCanonicalConfiguration(duplicateStyleName)
        }

        var reservedStyleID = canonicalConfig()
        reservedStyleID.customTranscriptCleanupPrompts.append(
            CustomTranscriptCleanupPrompt(id: TranscriptCleanupPrompts.defaultID, name: "Reserved", prompt: "Reserved ID")
        )
        #expect(throws: DictationStyleResolver.ConfigurationError.self) {
            _ = try DictationStyleResolver.prepareCanonicalConfiguration(reservedStyleID)
        }

        var emptyPrompt = canonicalConfig()
        emptyPrompt.customTranscriptCleanupPrompts[0].prompt = "  "
        #expect(throws: DictationStyleResolver.ConfigurationError.self) {
            _ = try DictationStyleResolver.prepareCanonicalConfiguration(emptyPrompt)
        }

        var invalidGlobal = canonicalConfig()
        invalidGlobal.activeTranscriptCleanupPromptId = "missing"
        #expect(throws: DictationStyleResolver.ConfigurationError.self) {
            _ = try DictationStyleResolver.prepareCanonicalConfiguration(invalidGlobal)
        }
    }

    @Test("exact exception removal restores group effective state")
    func exceptionRemovalRestoresInheritance() {
        var config = canonicalConfig()
        config.dictationStyleGroups = [
            group("group", styleID: "broad", matcher: matcher("group-matcher", .bundleID, "com.example.app")),
        ]
        config.dictationStyleExactExceptions = [
            DictationStyleExactException(id: "exception", kind: .bundleID, target: "com.example.app", styleID: "narrow"),
        ]
        #expect(DictationStyleResolver.resolve(config: config, bundleID: "com.example.app", hostname: nil).styleID == "narrow")

        config.dictationStyleExactExceptions.removeAll()
        #expect(DictationStyleResolver.resolve(config: config, bundleID: "com.example.app", hostname: nil).styleID == "broad")
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

    private func canonicalConfig() -> AppConfig {
        var config = AppConfig()
        config.adaptiveDictationStylesEnabled = true
        config.dictationStyleRulesetInitialized = true
        config.customTranscriptCleanupPrompts = [
            CustomTranscriptCleanupPrompt(id: "broad", name: "Broad", prompt: "Broad prompt"),
            CustomTranscriptCleanupPrompt(id: "narrow", name: "Narrow", prompt: "Narrow prompt"),
            CustomTranscriptCleanupPrompt(id: "app", name: "App", prompt: "App prompt"),
            CustomTranscriptCleanupPrompt(id: "global", name: "Global", prompt: "Global prompt"),
        ]
        config.activeTranscriptCleanupPromptId = "global"
        config.postProcessorSystemPrompt = "Global prompt"
        return config
    }

    private func group(
        _ id: String,
        name: String? = nil,
        styleID: String,
        matcher: DictationStyleMatcher
    ) -> DictationStyleGroup {
        DictationStyleGroup(id: id, name: name ?? id, styleID: styleID, matchers: [matcher])
    }

    private func matcher(
        _ id: String,
        _ kind: DictationStyleMatcherKind,
        _ pattern: String
    ) -> DictationStyleMatcher {
        DictationStyleMatcher(id: id, kind: kind, pattern: pattern)
    }
}
