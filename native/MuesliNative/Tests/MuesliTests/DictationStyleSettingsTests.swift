import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Dictation style settings")
struct DictationStyleSettingsTests {
    @Test("adaptive toggle seeds categories and disabling preserves assignments")
    func adaptiveTogglePreservesConfiguration() {
        var config = AppConfig()
        config.activeTranscriptCleanupPromptId = TranscriptCleanupPrompts.emailID

        let enabled = DictationStyleSettingsModel.enabledConfiguration(from: config, enabled: true)
        let disabled = DictationStyleSettingsModel.enabledConfiguration(from: enabled, enabled: false)

        #expect(enabled.adaptiveDictationStylesEnabled)
        #expect(enabled.dictationStyleCategoryAssignments.count == DictationStyleCategory.allCases.count)
        #expect(enabled.activeTranscriptCleanupPromptId == TranscriptCleanupPrompts.emailID)
        #expect(disabled.adaptiveDictationStylesEnabled == false)
        #expect(disabled.dictationStyleCategoryAssignments == enabled.dictationStyleCategoryAssignments)
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
