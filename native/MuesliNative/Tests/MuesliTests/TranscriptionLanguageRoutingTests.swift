import MuesliCore
import Testing

@Suite("Transcription language routing")
struct TranscriptionLanguageRoutingTests {
    private let backendID = TranscriptionBackendID(rawValue: "test:multilingual")

    @Test("automatic and pinned selections resolve without provider fallback")
    func automaticAndPinned() throws {
        let capabilities = multilingualCapabilities()
        #expect(TranscriptionLanguageRouter.resolve(
            selection: .automatic,
            capabilities: capabilities,
            workload: .dictation
        ) == .automatic)
        #expect(TranscriptionLanguageRouter.resolve(
            selection: try TranscriptionLanguageSelection(selectedLanguages: [.arabic]),
            capabilities: capabilities,
            workload: .dictation
        ) == .pinned(.arabic))
    }

    // Reversed under KD2: an unsupported explicit language on a detecting backend
    // now degrades to automatic detection instead of aborting transcription.
    @Test("an unsupported explicit language degrades to Auto on a detecting backend")
    func unsupportedExplicitSelectionDegradesToAuto() throws {
        let capabilities = TranscriptionBackendCapabilities(
            backendID: backendID,
            supportedLanguages: [.english],
            supportsAutomaticDetection: true,
            supportsSingleLanguage: true,
            workloads: [.dictation]
        )
        let selection = try TranscriptionLanguageSelection(selectedLanguages: [.arabic])
        let result = TranscriptionLanguageRouter.resolve(
            selection: selection,
            capabilities: capabilities,
            workload: .dictation
        )
        #expect(result == .automatic)
        #expect(result.degradation(for: selection) == .notPinned(.arabic))
    }

    // Reversed under KD2/R17: a set dominant pins a backend that can pin; the
    // candidates arm is reachable only for a no-dominant selection that exactly
    // matches the advertised set.
    @Test("a dominant language pins; candidates need the exact advertised set without a dominant")
    func dominantPinsAndCandidatesNeedExactSet() throws {
        let dominant = try TranscriptionLanguageSelection(
            selectedLanguages: [.english, .arabic],
            dominantLanguage: .arabic
        )
        #expect(TranscriptionLanguageRouter.resolve(
            selection: dominant,
            capabilities: multilingualCapabilities(),
            workload: .dictation
        ) == .pinned(.arabic))
        #expect(TranscriptionLanguageRouter.resolve(
            selection: dominant,
            capabilities: multilingualCapabilities(constrained: true),
            workload: .dictation
        ) == .pinned(.arabic))
        #expect(LanguageRoutingDecision.pinned(.arabic).degradation(for: dominant) == nil)

        let noDominant = try TranscriptionLanguageSelection(
            selectedLanguages: [.english, .arabic]
        )
        #expect(TranscriptionLanguageRouter.resolve(
            selection: noDominant,
            capabilities: multilingualCapabilities(constrained: true),
            workload: .dictation
        ) == .constrainedCandidates(
            languages: [.arabic, .english],
            dominantLanguage: nil
        ))
        #expect(TranscriptionLanguageRouter.resolve(
            selection: noDominant,
            capabilities: multilingualCapabilities(),
            workload: .dictation
        ) == .automatic)
        #expect(LanguageRoutingDecision.automatic.degradation(for: noDominant) == nil)
    }

    // Reversed under KD2: sets the candidates arm cannot serve fall through to
    // automatic detection on a detecting backend instead of aborting.
    @Test("oversized and non-advertised sets detect automatically")
    func unsupportedSetsDetectAutomatically() throws {
        let capabilities = multilingualCapabilities(constrained: true)
        let oversized = try TranscriptionLanguageSelection(
            selectedLanguages: [.arabic, .english, .french]
        )
        #expect(TranscriptionLanguageRouter.resolve(
            selection: oversized,
            capabilities: capabilities,
            workload: .dictation
        ) == .automatic)

        let otherPair = try TranscriptionLanguageSelection(
            selectedLanguages: [.english, .french]
        )
        #expect(TranscriptionLanguageRouter.resolve(
            selection: otherPair,
            capabilities: capabilities,
            workload: .dictation
        ) == .automatic)
    }

    @Test("fixed and unavailable models return typed decisions")
    func fixedAndUnavailable() throws {
        let fixed = TranscriptionBackendCapabilities(
            backendID: backendID,
            supportedLanguages: [.english],
            supportsAutomaticDetection: false,
            supportsSingleLanguage: false,
            fixedLanguage: .english,
            workloads: [.dictation]
        )
        #expect(TranscriptionLanguageRouter.resolve(
            selection: .automatic,
            capabilities: fixed,
            workload: .dictation
        ) == .fixed(.english))
        #expect(LanguageRoutingDecision.fixed(.english).degradation(for: .automatic) == nil)
        // Reversed under KD2: a fixed-language model ignores a foreign selection
        // and explains it instead of aborting.
        let arabic = try TranscriptionLanguageSelection(selectedLanguages: [.arabic])
        let arabicOnFixed = TranscriptionLanguageRouter.resolve(
            selection: arabic,
            capabilities: fixed,
            workload: .dictation
        )
        #expect(arabicOnFixed == .fixed(.english))
        #expect(arabicOnFixed.degradation(for: arabic) == .fixedLanguageIgnoresSelection(.arabic))
        let mixed = try TranscriptionLanguageSelection(selectedLanguages: [.arabic, .english])
        let mixedOnFixed = TranscriptionLanguageRouter.resolve(
            selection: mixed,
            capabilities: fixed,
            workload: .dictation
        )
        #expect(mixedOnFixed == .fixed(.english))
        #expect(mixedOnFixed.degradation(for: mixed) == .fixedLanguageIgnoresSelection(.arabic))
        let englishOnly = try TranscriptionLanguageSelection(selectedLanguages: [.english])
        #expect(LanguageRoutingDecision.fixed(.english).degradation(for: englishOnly) == nil)

        let unavailable = TranscriptionBackendCapabilities(
            backendID: backendID,
            supportedLanguages: [.english],
            supportsAutomaticDetection: true,
            supportsSingleLanguage: true,
            workloads: [.dictation],
            isAvailable: false
        )
        #expect(TranscriptionLanguageRouter.resolve(
            selection: .automatic,
            capabilities: unavailable,
            workload: .dictation
        ) == .incompatible(.backendUnavailable(backendID)))
        #expect(TranscriptionLanguageRouter.resolve(
            selection: .automatic,
            capabilities: multilingualCapabilities(),
            workload: .meetingFinal
        ) == .incompatible(.unsupportedWorkload(.meetingFinal)))
    }

    @Test("a provider fallback language replaces automatic detection and unsupported languages")
    func providerFallbackReplacesUnservableShapes() throws {
        let cohereLike = TranscriptionBackendCapabilities(
            backendID: backendID,
            supportedLanguages: [.arabic, .english, .french],
            supportsAutomaticDetection: false,
            supportsSingleLanguage: true,
            fallbackLanguage: .english,
            workloads: [.dictation]
        )

        let automatic = TranscriptionLanguageRouter.resolve(
            selection: .automatic,
            capabilities: cohereLike,
            workload: .dictation
        )
        #expect(automatic == .pinned(.english))
        #expect(automatic.degradation(for: .automatic) == .providerFallback(to: .english))

        let hindi = try TranscriptionLanguageSelection(selectedLanguages: [.hindi])
        let hindiDecision = TranscriptionLanguageRouter.resolve(
            selection: hindi,
            capabilities: cohereLike,
            workload: .dictation
        )
        #expect(hindiDecision == .pinned(.english))
        #expect(hindiDecision.degradation(for: hindi) == .providerFallback(to: .english))

        let pairWithoutDominant = try TranscriptionLanguageSelection(
            selectedLanguages: [.arabic, .english]
        )
        let pairDecision = TranscriptionLanguageRouter.resolve(
            selection: pairWithoutDominant,
            capabilities: cohereLike,
            workload: .dictation
        )
        #expect(pairDecision == .pinned(.english))
        #expect(pairDecision.degradation(for: pairWithoutDominant) == .providerFallback(to: .english))

        let sole = try TranscriptionLanguageSelection(selectedLanguages: [.arabic])
        let soleDecision = TranscriptionLanguageRouter.resolve(
            selection: sole,
            capabilities: cohereLike,
            workload: .dictation
        )
        #expect(soleDecision == .pinned(.arabic))
        #expect(soleDecision.degradation(for: sole) == nil)

        let pairWithDominant = try TranscriptionLanguageSelection(
            selectedLanguages: [.arabic, .english],
            dominantLanguage: .arabic
        )
        let dominantDecision = TranscriptionLanguageRouter.resolve(
            selection: pairWithDominant,
            capabilities: cohereLike,
            workload: .dictation
        )
        #expect(dominantDecision == .pinned(.arabic))
        #expect(dominantDecision.degradation(for: pairWithDominant) == nil)
    }

    @Test("CLI-shaped capabilities without a fallback stay incompatible")
    func cliShapedCapabilitiesStayIncompatible() throws {
        let noAutoNoFallback = TranscriptionBackendCapabilities(
            backendID: backendID,
            supportedLanguages: [.english],
            supportsAutomaticDetection: false,
            supportsSingleLanguage: true,
            workloads: [.cli]
        )
        #expect(TranscriptionLanguageRouter.resolve(
            selection: .automatic,
            capabilities: noAutoNoFallback,
            workload: .cli
        ) == .incompatible(.automaticDetectionUnsupported))
        #expect(TranscriptionLanguageRouter.resolve(
            selection: try TranscriptionLanguageSelection(selectedLanguages: [.arabic]),
            capabilities: noAutoNoFallback,
            workload: .cli
        ) == .incompatible(.languageUnsupported(.arabic)))
        #expect(TranscriptionLanguageRouter.resolve(
            selection: try TranscriptionLanguageSelection(selectedLanguages: [.arabic, .english]),
            capabilities: noAutoNoFallback,
            workload: .cli
        ) == .incompatible(.automaticDetectionUnsupported))
    }

    @Test("a non-pinning detecting backend accepts a single language as automatic")
    func nonPinningBackendDegradesToAutomatic() throws {
        let parakeetLike = TranscriptionBackendCapabilities(
            backendID: backendID,
            supportedLanguages: Set(TranscriptionLanguage.allCases),
            supportsAutomaticDetection: true,
            supportsSingleLanguage: false,
            workloads: [.dictation]
        )
        let arabic = try TranscriptionLanguageSelection(selectedLanguages: [.arabic])
        let decision = TranscriptionLanguageRouter.resolve(
            selection: arabic,
            capabilities: parakeetLike,
            workload: .dictation
        )
        #expect(decision == .automatic)
        #expect(decision.degradation(for: arabic) == .notPinned(.arabic))

        let pairWithDominant = try TranscriptionLanguageSelection(
            selectedLanguages: [.arabic, .english],
            dominantLanguage: .arabic
        )
        let pairDecision = TranscriptionLanguageRouter.resolve(
            selection: pairWithDominant,
            capabilities: parakeetLike,
            workload: .dictation
        )
        #expect(pairDecision == .automatic)
        #expect(pairDecision.degradation(for: pairWithDominant) == .notPinned(.arabic))
    }

    @Test("runtime decision is nil for every incompatibility and the decision otherwise")
    func runtimeDecisionHidesIncompatibilities() throws {
        #expect(TranscriptionLanguageRouter.runtimeDecision(
            selection: .automatic,
            capabilities: multilingualCapabilities(),
            workload: .dictation
        ) == .automatic)
        #expect(TranscriptionLanguageRouter.runtimeDecision(
            selection: try TranscriptionLanguageSelection(selectedLanguages: [.arabic]),
            capabilities: multilingualCapabilities(),
            workload: .dictation
        ) == .pinned(.arabic))

        let unavailable = TranscriptionBackendCapabilities(
            backendID: backendID,
            supportedLanguages: [.english],
            supportsAutomaticDetection: true,
            supportsSingleLanguage: true,
            workloads: [.dictation],
            isAvailable: false
        )
        #expect(TranscriptionLanguageRouter.runtimeDecision(
            selection: .automatic,
            capabilities: unavailable,
            workload: .dictation
        ) == nil)
        #expect(TranscriptionLanguageRouter.runtimeDecision(
            selection: .automatic,
            capabilities: multilingualCapabilities(),
            workload: .meetingFinal
        ) == nil)

        let noAutoNoFallback = TranscriptionBackendCapabilities(
            backendID: backendID,
            supportedLanguages: [.english],
            supportsAutomaticDetection: false,
            supportsSingleLanguage: true,
            workloads: [.cli]
        )
        #expect(TranscriptionLanguageRouter.runtimeDecision(
            selection: .automatic,
            capabilities: noAutoNoFallback,
            workload: .cli
        ) == nil)
        #expect(TranscriptionLanguageRouter.runtimeDecision(
            selection: try TranscriptionLanguageSelection(selectedLanguages: [.arabic]),
            capabilities: noAutoNoFallback,
            workload: .cli
        ) == nil)
    }

    @Test("degradation is nil when the decision matches the selection")
    func degradationIsNilForHonoredSelections() throws {
        #expect(LanguageRoutingDecision.automatic.degradation(for: .automatic) == nil)
        let sole = try TranscriptionLanguageSelection(selectedLanguages: [.arabic])
        #expect(LanguageRoutingDecision.pinned(.arabic).degradation(for: sole) == nil)
        let dominant = try TranscriptionLanguageSelection(
            selectedLanguages: [.arabic, .english],
            dominantLanguage: .english
        )
        #expect(LanguageRoutingDecision.pinned(.english).degradation(for: dominant) == nil)
        let pair = try TranscriptionLanguageSelection(selectedLanguages: [.arabic, .english])
        #expect(LanguageRoutingDecision.automatic.degradation(for: pair) == nil)
        #expect(LanguageRoutingDecision.constrainedCandidates(
            languages: [.arabic, .english],
            dominantLanguage: nil
        ).degradation(for: pair) == nil)
        #expect(LanguageRoutingDecision.incompatible(.automaticDetectionUnsupported)
            .degradation(for: pair) == nil)
    }

    private func multilingualCapabilities(
        constrained: Bool = false
    ) -> TranscriptionBackendCapabilities {
        TranscriptionBackendCapabilities(
            backendID: backendID,
            supportedLanguages: [.arabic, .english, .french],
            supportsAutomaticDetection: true,
            supportsSingleLanguage: true,
            constrainedCandidateLanguages: constrained ? [.arabic, .english] : [],
            constrainedCandidateCapacity: constrained ? 2 : 0,
            hasComparableCandidateConfidence: constrained,
            supportsCodeSwitching: true,
            workloads: [.dictation]
        )
    }
}
