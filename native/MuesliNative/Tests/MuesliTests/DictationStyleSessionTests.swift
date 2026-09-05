import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Dictation style session")
struct DictationStyleSessionTests {
    private let mailTarget = DictationSessionTarget(
        processID: 42,
        appName: "Mail",
        bundleID: "com.apple.Mail"
    )
    private let browserTarget = DictationSessionTarget(
        processID: 77,
        appName: "Chrome",
        bundleID: "com.google.Chrome"
    )

    @Test("start target and configuration remain authoritative")
    func startSnapshotRemainsAuthoritative() {
        var config = adaptiveConfig()
        config.dictationStyleAppRules = [
            DictationStyleAppRule(bundleID: "com.apple.mail", styleID: TranscriptCleanupPrompts.emailID),
        ]
        let snapshot = DictationStyleSessionSnapshot(
            target: mailTarget,
            config: config,
            mode: .standard
        )

        config.dictationStyleAppRules = [
            DictationStyleAppRule(bundleID: "com.apple.mail", styleID: TranscriptCleanupPrompts.codeID),
            DictationStyleAppRule(bundleID: "com.apple.notes", styleID: TranscriptCleanupPrompts.writingID),
        ]

        let result = snapshot.resolveStyle(context: nil)
        #expect(result.styleID == TranscriptCleanupPrompts.emailID)
        #expect(result.source == .app)
    }

    @Test("matching browser hostname beats the browser app")
    func matchingHostnameWins() {
        var config = adaptiveConfig()
        config.dictationStyleDomainRules = [
            DictationStyleDomainRule(hostname: "docs.google.com", styleID: TranscriptCleanupPrompts.writingID),
        ]
        config.dictationStyleAppRules = [
            DictationStyleAppRule(bundleID: "com.google.chrome", styleID: TranscriptCleanupPrompts.codeID),
        ]
        let snapshot = DictationStyleSessionSnapshot(
            target: browserTarget,
            config: config,
            mode: .standard
        )
        let context = matchingContext(
            snapshot: snapshot,
            target: browserTarget,
            hostname: "Docs.Google.Com."
        )

        let result = snapshot.resolveStyle(context: context)
        #expect(result.styleID == TranscriptCleanupPrompts.writingID)
        #expect(result.source == .domain)
    }

    @Test("mismatched and late context cannot select a domain")
    func rejectsMismatchedAndLateContext() {
        var config = adaptiveConfig()
        config.dictationStyleDomainRules = [
            DictationStyleDomainRule(hostname: "docs.google.com", styleID: TranscriptCleanupPrompts.writingID),
        ]
        config.dictationStyleAppRules = [
            DictationStyleAppRule(bundleID: "com.google.chrome", styleID: TranscriptCleanupPrompts.codeID),
        ]
        let snapshot = DictationStyleSessionSnapshot(
            target: browserTarget,
            config: config,
            mode: .standard
        )
        let wrongSession = DictationSessionContextResult(
            sessionID: UUID(),
            context: context(target: browserTarget, hostname: "docs.google.com")
        )
        let wrongProcess = DictationSessionContextResult(
            sessionID: snapshot.id,
            context: DictationContext(
                processID: 78,
                appName: "Chrome",
                bundleID: browserTarget.bundleID,
                documentContext: "",
                selectedText: "",
                url: "docs.google.com/document/d/1",
                hostname: "docs.google.com",
                ocrText: ""
            )
        )
        let wrongBundle = DictationSessionContextResult(
            sessionID: snapshot.id,
            context: DictationContext(
                processID: browserTarget.processID,
                appName: "Safari",
                bundleID: "com.apple.Safari",
                documentContext: "",
                selectedText: "",
                url: "docs.google.com/document/d/1",
                hostname: "docs.google.com",
                ocrText: ""
            )
        )

        for rejected in [wrongSession, wrongProcess, wrongBundle] {
            let result = snapshot.resolveStyle(context: rejected)
            #expect(result.styleID == TranscriptCleanupPrompts.codeID)
            #expect(result.source == .app)
        }
    }

    @Test("missing context and target identity fall through without blocking")
    func missingContextFallsThrough() {
        var config = adaptiveConfig()
        config.activeTranscriptCleanupPromptId = TranscriptCleanupPrompts.emailID
        let targetSnapshot = DictationStyleSessionSnapshot(
            target: DictationSessionTarget(processID: 90, appName: "Unknown", bundleID: ""),
            config: config,
            mode: .standard
        )
        let missingTargetSnapshot = DictationStyleSessionSnapshot(
            target: nil,
            config: config,
            mode: .standard
        )

        #expect(targetSnapshot.resolveStyle(context: nil).styleID == TranscriptCleanupPrompts.emailID)
        #expect(missingTargetSnapshot.resolveStyle(context: nil).styleID == TranscriptCleanupPrompts.emailID)
    }

    @Test("base browser context resolves without OCR completion")
    func hostnameDoesNotDependOnOCR() {
        var config = adaptiveConfig()
        config.dictationStyleDomainRules = [
            DictationStyleDomainRule(hostname: "docs.google.com", styleID: TranscriptCleanupPrompts.writingID),
        ]
        let snapshot = DictationStyleSessionSnapshot(
            target: browserTarget,
            config: config,
            mode: .standard
        )
        let base = matchingContext(snapshot: snapshot, target: browserTarget, hostname: "docs.google.com")
        let enriched = DictationSessionContextResult(
            sessionID: snapshot.id,
            context: context(target: browserTarget, hostname: "docs.google.com", ocrText: "visual text")
        )

        #expect(snapshot.resolveStyle(context: base).styleID == TranscriptCleanupPrompts.writingID)
        #expect(snapshot.resolveStyle(context: enriched).styleID == TranscriptCleanupPrompts.writingID)
    }

    @Test("context hostname is exact and never accepts path or query identity")
    func contextHostnameIsExact() {
        let exact = context(target: browserTarget, hostname: "Docs.Google.Com.")
        let path = context(target: browserTarget, hostname: "docs.google.com/document/d/1")
        let query = context(target: browserTarget, hostname: "docs.google.com?tab=1")

        #expect(exact.hostname == "docs.google.com")
        #expect(path.hostname == nil)
        #expect(query.hostname == nil)
    }

    @Test("browser URL extraction keeps only the normalized exact host for styles")
    func browserURLExtractionSeparatesHostname() throws {
        let page = try #require(DictationContextCapture.browserPage(
            from: "https://Docs.Google.Com.:443/document/d/1?tab=editing#heading"
        ))

        #expect(page.hostname == "docs.google.com")
        #expect(page.displayURL == "docs.google.com/document/d/1")
        #expect(DictationContextCapture.browserPage(from: "not a browser URL") == nil)
    }

    @Test("only standard dictation receives adaptive cleanup policy")
    func excludedModesReceiveNoAdaptivePolicy() {
        let config = adaptiveConfig()
        let standard = DictationStyleSessionSnapshot(target: mailTarget, config: config, mode: .standard)
        #expect(standard.cleanupPolicy(enabled: true, context: nil) != nil)

        let excludedModes: [DictationStyleSessionMode] = [
            .voiceNote,
            .computerUse,
            .meeting,
            .streaming,
            .dictationTest,
        ]
        for mode in excludedModes {
            let snapshot = DictationStyleSessionSnapshot(target: mailTarget, config: config, mode: mode)
            #expect(snapshot.cleanupPolicy(enabled: true, context: nil) == nil)
        }
    }

    @Test("adaptive styles disabled preserves legacy prompt bytes with global provenance")
    func disabledAdaptiveStylesRetainsGlobalProvenance() throws {
        var config = adaptiveConfig()
        config.adaptiveDictationStylesEnabled = false
        config.activeTranscriptCleanupPromptId = TranscriptCleanupPrompts.emailID
        config.postProcessorSystemPrompt = "Legacy prompt bytes"
        config.customWords = [CustomWord(word: "muesli", replacement: "Muesli")]
        let hold = DictationStyleSessionSnapshot(target: mailTarget, config: config, mode: .standard)
        let toggle = DictationStyleSessionSnapshot(target: mailTarget, config: config, mode: .standard)

        let expectedPrompt = DictationCleanupPromptComposer.appendingSpeakerVocabulary(
            to: config.postProcessorSystemPrompt,
            customWords: config.customWords
        )
        for snapshot in [hold, toggle] {
            let policy = try #require(snapshot.cleanupPolicy(enabled: true, context: nil))
            #expect(policy.systemPromptSnapshot == expectedPrompt)
            #expect(policy.provenance?.styleID == TranscriptCleanupPrompts.emailID)
            #expect(policy.provenance?.source == .global)
        }
    }

    @Test("custom instructions follow the style block and precede the vocabulary")
    func customInstructionsOrderWithAdaptiveStyles() throws {
        var config = adaptiveConfig()
        config.customInstructions = "Use British English."
        config.customWords = [CustomWord(word: "muesli", replacement: "Muesli")]
        let snapshot = DictationStyleSessionSnapshot(target: mailTarget, config: config, mode: .standard)

        let prompt = try #require(snapshot.cleanupPolicy(enabled: true, context: nil)).systemPromptSnapshot
        let style = try #require(prompt.range(of: "<STYLE-INSTRUCTIONS>"))
        let block = try #require(prompt.range(of: CustomInstructions.openingTag))
        let vocabulary = try #require(prompt.range(of: "Speaker vocabulary"))
        #expect(style.lowerBound < block.lowerBound && block.lowerBound < vocabulary.lowerBound)
    }

    @Test("adaptive styles disabled keeps the raw preset bytes ahead of the instructions")
    func disabledAdaptiveStylesKeepsRawBytesFirst() throws {
        var config = adaptiveConfig()
        config.adaptiveDictationStylesEnabled = false
        config.postProcessorSystemPrompt = "Legacy prompt bytes"
        config.customInstructions = "Use British English."
        config.customWords = [CustomWord(word: "muesli", replacement: "Muesli")]
        let snapshot = DictationStyleSessionSnapshot(target: mailTarget, config: config, mode: .standard)

        let prompt = try #require(snapshot.cleanupPolicy(enabled: true, context: nil)).systemPromptSnapshot
        #expect(prompt.hasPrefix("Legacy prompt bytes"))
        let block = try #require(prompt.range(of: CustomInstructions.openingTag))
        let vocabulary = try #require(prompt.range(of: "Speaker vocabulary"))
        #expect(block.lowerBound < vocabulary.lowerBound)
    }

    @Test("custom instructions freeze at recording start")
    func customInstructionsFreezeAtStart() throws {
        var config = adaptiveConfig()
        config.customInstructions = "Instructions A"
        let snapshot = DictationStyleSessionSnapshot(target: mailTarget, config: config, mode: .standard)

        config.customInstructions = "Instructions B"

        let prompt = try #require(snapshot.cleanupPolicy(enabled: true, context: nil)).systemPromptSnapshot
        #expect(prompt.contains("Instructions A"))
        #expect(!prompt.contains("Instructions B"))
    }

    @Test("an S1-mini runtime snapshot stores only the trained S1 prompt")
    func s1MiniSnapshotKeepsTrainedPrompt() throws {
        var config = adaptiveConfig()
        config.customInstructions = "Use British English."
        config.customWords = [CustomWord(word: "muesli", replacement: "Muesli")]
        let runtime = DictationCleanupRuntimeSnapshot(readiness: .ready, backend: .local, option: .s1Mini, config: config)
        let snapshot = DictationStyleSessionSnapshot(target: mailTarget, config: config, mode: .standard, cleanupRuntime: runtime)

        let prompt = try #require(snapshot.cleanupPolicy(enabled: true, context: nil)).systemPromptSnapshot
        #expect(prompt == PostProcessorOption.s1MiniSystemPrompt)
        #expect(!prompt.contains(CustomInstructions.openingTag))
    }

    @Test("the session budget follows the frozen cleanup backend, else the configured one")
    func sessionBudgetFollowsBackend() throws {
        var config = adaptiveConfig()
        config.customInstructions = String(repeating: "x", count: 1_500)
        let runtime = DictationCleanupRuntimeSnapshot(readiness: .ready, backend: .gemma4LiteRT, option: nil, config: config)
        let hosted = DictationStyleSessionSnapshot(target: mailTarget, config: config, mode: .standard, cleanupRuntime: runtime)
        let configured = DictationStyleSessionSnapshot(target: mailTarget, config: config, mode: .standard)

        let hostedPrompt = try #require(hosted.cleanupPolicy(enabled: true, context: nil)).systemPromptSnapshot
        let localPrompt = try #require(configured.cleanupPolicy(enabled: true, context: nil)).systemPromptSnapshot
        #expect(hostedPrompt.contains(String(repeating: "x", count: 1_500)))
        #expect(localPrompt.contains(String(repeating: "x", count: 500)))
        #expect(!localPrompt.contains(String(repeating: "x", count: 501)))
    }

    @Test("adaptive prompt freezes speaker vocabulary at recording start")
    func adaptivePromptFreezesSpeakerVocabulary() throws {
        var config = adaptiveConfig()
        config.customWords = (0 ..< 79).map {
            CustomWord(word: "term-\($0)", replacement: "Term \($0)")
        } + [
            CustomWord(word: "included", replacement: "Included Boundary"),
            CustomWord(word: "excluded", replacement: "Excluded Boundary"),
        ]
        let snapshot = DictationStyleSessionSnapshot(target: mailTarget, config: config, mode: .standard)

        config.customWords = [CustomWord(word: "later", replacement: "Later Edit")]

        let policy = try #require(snapshot.cleanupPolicy(enabled: true, context: nil))
        #expect(policy.systemPromptSnapshot.contains("Speaker vocabulary"))
        #expect(policy.systemPromptSnapshot.contains("Included Boundary"))
        #expect(!policy.systemPromptSnapshot.contains("Excluded Boundary"))
        #expect(!policy.systemPromptSnapshot.contains("Later Edit"))
    }

    @Test("cleanup request keeps the recording-start local model")
    func cleanupRequestPinsLocalModel() throws {
        var config = adaptiveConfig()
        config.activePostProcessorId = PostProcessorOption.finetunedV2.id
        let runtime = DictationCleanupRuntimeSnapshot(
            readiness: .ready,
            backend: .local,
            option: .finetunedV2,
            config: config
        )
        let snapshot = DictationStyleSessionSnapshot(
            target: mailTarget,
            config: config,
            mode: .standard,
            cleanupRuntime: runtime
        )

        config.activePostProcessorId = PostProcessorOption.qwen35_0_8b.id

        let request = try #require(snapshot.cleanupRequest(context: nil))
        #expect(request.runtime.modelID == PostProcessorOption.finetunedV2.id)
        #expect(request.runtime.modelURL == PostProcessorOption.finetunedV2.modelURL)
        #expect(request.runtime.config.activePostProcessorId == PostProcessorOption.finetunedV2.id)
    }

    @Test("cleanup request commits the available hostname without waiting for later context")
    func cleanupRequestDoesNotChangeAfterCommit() throws {
        var config = adaptiveConfig()
        config.dictationStyleRulesetInitialized = true
        config.dictationStyleGroups = [
            DictationStyleGroup(
                id: "docs",
                name: "Docs",
                styleID: TranscriptCleanupPrompts.writingID,
                matchers: [DictationStyleMatcher(id: "docs-host", kind: .hostname, pattern: "docs.google.com")]
            ),
            DictationStyleGroup(
                id: "browser",
                name: "Browser",
                styleID: TranscriptCleanupPrompts.codeID,
                matchers: [DictationStyleMatcher(id: "chrome-app", kind: .bundleID, pattern: "com.google.chrome")]
            ),
        ]
        let runtime = DictationCleanupRuntimeSnapshot(
            readiness: .ready,
            backend: .local,
            option: .finetunedV2,
            config: config
        )
        let snapshot = DictationStyleSessionSnapshot(
            target: browserTarget,
            config: config,
            mode: .standard,
            cleanupRuntime: runtime
        )

        let committed = try #require(snapshot.cleanupRequest(context: nil))
        let lateContext = matchingContext(snapshot: snapshot, target: browserTarget, hostname: "docs.google.com")
        let laterRequest = try #require(snapshot.cleanupRequest(context: lateContext))

        #expect(committed.policy.provenance?.source == .group)
        #expect(committed.policy.provenance?.groupID == "browser")
        #expect(laterRequest.policy.provenance?.source == .group)
        #expect(laterRequest.policy.provenance?.groupID == "docs")
        #expect(committed.policy.systemPromptSnapshot != laterRequest.policy.systemPromptSnapshot)
    }

    private func adaptiveConfig() -> AppConfig {
        var config = AppConfig()
        config.enablePostProcessor = true
        config.adaptiveDictationStylesEnabled = true
        return config
    }

    private func matchingContext(
        snapshot: DictationStyleSessionSnapshot,
        target: DictationSessionTarget,
        hostname: String
    ) -> DictationSessionContextResult {
        DictationSessionContextResult(
            sessionID: snapshot.id,
            context: context(target: target, hostname: hostname)
        )
    }

    private func context(
        target: DictationSessionTarget,
        hostname: String,
        ocrText: String = ""
    ) -> DictationContext {
        DictationContext(
            processID: target.processID,
            appName: target.appName,
            bundleID: target.bundleID,
            documentContext: "",
            selectedText: "",
            url: "docs.google.com/document/d/1",
            hostname: hostname,
            ocrText: ocrText
        )
    }
}
