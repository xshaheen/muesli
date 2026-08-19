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

    @Test("an unsupported explicit language never becomes Auto")
    func unsupportedExplicitSelectionIsIncompatible() throws {
        let capabilities = TranscriptionBackendCapabilities(
            backendID: backendID,
            supportedLanguages: [.english],
            supportsAutomaticDetection: true,
            supportsSingleLanguage: true,
            workloads: [.dictation]
        )
        let result = TranscriptionLanguageRouter.resolve(
            selection: try TranscriptionLanguageSelection(selectedLanguages: [.arabic]),
            capabilities: capabilities,
            workload: .dictation
        )
        #expect(result == .incompatible(.languageUnsupported(.arabic)))
    }

    @Test("English-Arabic candidates require enabled comparable confidence")
    func constrainedCandidatesRequireConformance() throws {
        let selection = try TranscriptionLanguageSelection(
            selectedLanguages: [.english, .arabic],
            dominantLanguage: .arabic
        )
        #expect(TranscriptionLanguageRouter.resolve(
            selection: selection,
            capabilities: multilingualCapabilities(),
            workload: .dictation
        ) == .incompatible(.tooManyLanguages(requested: 2, maximum: 0)))

        let enabled = multilingualCapabilities(constrained: true)
        #expect(TranscriptionLanguageRouter.resolve(
            selection: selection,
            capabilities: enabled,
            workload: .dictation
        ) == .constrainedCandidates(
            languages: [.arabic, .english],
            dominantLanguage: .arabic
        ))
    }

    @Test("oversized and non-English-Arabic sets remain incompatible")
    func unsupportedSetsRemainIncompatible() throws {
        let capabilities = multilingualCapabilities(constrained: true)
        let oversized = try TranscriptionLanguageSelection(
            selectedLanguages: [.arabic, .english, .french]
        )
        #expect(TranscriptionLanguageRouter.resolve(
            selection: oversized,
            capabilities: capabilities,
            workload: .dictation
        ) == .incompatible(.tooManyLanguages(requested: 3, maximum: 2)))

        let otherPair = try TranscriptionLanguageSelection(
            selectedLanguages: [.english, .french]
        )
        #expect(TranscriptionLanguageRouter.resolve(
            selection: otherPair,
            capabilities: capabilities,
            workload: .dictation
        ) == .incompatible(.constrainedCandidatesUnsupported))
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
        #expect(TranscriptionLanguageRouter.resolve(
            selection: try TranscriptionLanguageSelection(selectedLanguages: [.arabic]),
            capabilities: fixed,
            workload: .dictation
        ) == .incompatible(.languageUnsupported(.arabic)))

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
