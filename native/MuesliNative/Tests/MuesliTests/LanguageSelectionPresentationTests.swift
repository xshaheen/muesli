import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

/// These exercise a multilingual backend that supports single-language pinning.
/// They were written against Qwen3 ASR, which was removed after the 21-08-2026
/// measurement run; Whisper Large Turbo carries the identical capability shape
/// (all languages, automatic detection, single-language pinning), so the cases
/// still say what they were written to say.
@Suite("Language selection presentation")
struct LanguageSelectionPresentationTests {
    @Test("selection states preserve model and language identifiers")
    func presentationStatesPreserveIdentity() throws {
        let automatic = SpokenLanguageProfile.automatic.presentation(
            for: .whisperSmall,
            isAvailable: true
        )
        #expect(automatic.state == .automatic)
        #expect(automatic.degradation == nil)
        #expect(automatic.backendID == BackendOption.whisperSmall.transcriptionBackendID)

        let pinned = try SpokenLanguageProfile(
            selectedLanguages: [.arabic]
        ).presentation(for: .whisperLargeTurbo, isAvailable: true)
        #expect(pinned.state == .pinned)
        #expect(pinned.degradation == nil)
        #expect(pinned.selectedLanguageIDs == ["ar"])

        // Reversed under KD2/R17: two languages without a dominant on a detecting
        // backend detect automatically instead of being incompatible.
        let detectingAmong = try SpokenLanguageProfile(
            selectedLanguages: [.english, .arabic]
        ).presentation(for: .whisperLargeTurbo, isAvailable: true)
        #expect(detectingAmong.state == .automatic)
        #expect(detectingAmong.degradation == nil)
        #expect(detectingAmong.routingIdentifier == "auto")
        #expect(detectingAmong.selectedLanguageIDs == ["ar", "en"])
        #expect(detectingAmong.explanation.contains("Arabic"))
        #expect(detectingAmong.explanation.contains("English"))

        let unavailable = try SpokenLanguageProfile(
            selectedLanguages: [.arabic]
        ).presentation(for: .whisperLargeTurbo, isAvailable: false)
        #expect(unavailable.state == .unavailable)
        #expect(unavailable.backendID == BackendOption.whisperLargeTurbo.transcriptionBackendID)
        #expect(unavailable.selectedLanguageIDs == ["ar"])
    }

    @Test("a dominant language pins Whisper and names the accepted languages")
    func dominantPinsAndNamesAccepted() throws {
        let presentation = try SpokenLanguageProfile(
            selectedLanguages: [.english, .arabic],
            dominantLanguage: .arabic
        ).presentation(for: .whisperLargeTurbo, isAvailable: true)
        #expect(presentation.state == .pinned)
        #expect(presentation.degradation == nil)
        #expect(presentation.routingIdentifier == "pinned")
        #expect(presentation.explanation.contains("Arabic"))
        #expect(presentation.explanation.contains("English"))
    }

    @Test("three languages without a dominant detect among all of them")
    func threeLanguagesDetectAmong() throws {
        let presentation = try SpokenLanguageProfile(
            selectedLanguages: [.arabic, .english, .french]
        ).presentation(for: .whisperLargeTurbo, isAvailable: true)
        #expect(presentation.state == .automatic)
        #expect(presentation.degradation == nil)
        for label in ["Arabic", "English", "French"] {
            #expect(presentation.explanation.contains(label))
        }
    }

    @Test("Cohere and Indic fall back to their provider language and say so")
    func providerFallbackCopy() throws {
        let cohereAutomatic = SpokenLanguageProfile.automatic.presentation(
            for: .cohereTranscribe,
            isAvailable: true
        )
        #expect(cohereAutomatic.state == .degraded)
        #expect(cohereAutomatic.degradation == .providerFallback(to: .english))
        #expect(cohereAutomatic.routingIdentifier == "pinned")
        #expect(cohereAutomatic.explanation.contains("English"))
        #expect(cohereAutomatic.explanation.contains("dominant language"))

        let indicAutomatic = SpokenLanguageProfile.automatic.presentation(
            for: .indicASR,
            isAvailable: true
        )
        #expect(indicAutomatic.state == .degraded)
        #expect(indicAutomatic.degradation == .providerFallback(to: .hindi))
        #expect(indicAutomatic.explanation.contains("Hindi"))

        let cohereHindi = try SpokenLanguageProfile(
            selectedLanguages: [.hindi]
        ).presentation(for: .cohereTranscribe, isAvailable: true)
        #expect(cohereHindi.state == .degraded)
        #expect(cohereHindi.degradation == .providerFallback(to: .english))
        #expect(cohereHindi.explanation.contains("Hindi"))
        #expect(cohereHindi.explanation.contains("English"))

        let coherePair = try SpokenLanguageProfile(
            selectedLanguages: [.arabic, .english]
        ).presentation(for: .cohereTranscribe, isAvailable: true)
        #expect(coherePair.state == .degraded)
        #expect(coherePair.degradation == .providerFallback(to: .english))
        #expect(coherePair.explanation.contains("English"))

        let cohereDominant = try SpokenLanguageProfile(
            selectedLanguages: [.arabic, .english],
            dominantLanguage: .arabic
        ).presentation(for: .cohereTranscribe, isAvailable: true)
        #expect(cohereDominant.state == .pinned)
        #expect(cohereDominant.degradation == nil)
    }

    @Test("a model that cannot pin detects automatically and says so")
    func notPinnedCopy() throws {
        let presentation = try SpokenLanguageProfile(
            selectedLanguages: [.arabic]
        ).presentation(for: .parakeetMultilingual, isAvailable: true)
        #expect(presentation.state == .degraded)
        #expect(presentation.degradation == .notPinned(.arabic))
        #expect(presentation.routingIdentifier == "auto")
        #expect(presentation.explanation.contains("Arabic"))
    }

    @Test("a fixed-language model ignores a foreign selection and says so")
    func fixedLanguageIgnoresSelectionCopy() throws {
        let single = try SpokenLanguageProfile(
            selectedLanguages: [.arabic]
        ).presentation(for: .whisperTinyEnglish, isAvailable: true)
        #expect(single.state == .degraded)
        #expect(single.degradation == .fixedLanguageIgnoresSelection(.arabic))
        #expect(single.routingIdentifier == "fixed")
        #expect(single.explanation.contains("English"))
        #expect(single.explanation.contains("Arabic"))

        let pair = try SpokenLanguageProfile(
            selectedLanguages: [.arabic, .english]
        ).presentation(for: .whisperTinyEnglish, isAvailable: true)
        #expect(pair.state == .degraded)
        #expect(pair.degradation == .fixedLanguageIgnoresSelection(.arabic))

        let english = try SpokenLanguageProfile(
            selectedLanguages: [.english]
        ).presentation(for: .whisperTinyEnglish, isAvailable: true)
        #expect(english.state == .fixed)
        #expect(english.degradation == nil)
    }

    @Test("Whisper multilingual pins every listed language")
    func whisperPinsEveryListedLanguage() throws {
        let dutch = try SpokenLanguageProfile(
            selectedLanguages: [.dutch]
        ).presentation(for: .whisperLargeTurbo, isAvailable: true)
        #expect(dutch.state == .pinned)
        #expect(dutch.degradation == nil)
        for language in TranscriptionLanguage.allCases {
            #expect(WhisperKitLanguage(rawValue: language.rawValue) != nil, "\(language.rawValue)")
        }
    }

    @Test("a model that does not transcribe meetings says so")
    func unsupportedWorkloadCopy() throws {
        let presentation = try SpokenLanguageProfile(
            selectedLanguages: [.arabic]
        ).presentation(for: .nemotron35Multilingual, workload: .meetingFinal, isAvailable: true)
        #expect(presentation.state == .incompatible)
        #expect(presentation.degradation == nil)
        #expect(presentation.routingIdentifier == "incompatible")
        #expect(presentation.explanation.contains("does not transcribe meetings"))
        #expect(!presentation.explanation.contains("cannot honor"))
    }

    @Test("no app backend yields a selection-reason incompatibility for any selection shape")
    func appBackendsNeverYieldSelectionIncompatibility() throws {
        for backend in BackendOption.all {
            let capabilities = backend.languageCapabilities(isAvailable: true)
            let supported = capabilities.supportedLanguages.sorted { $0.rawValue < $1.rawValue }
            let unsupported = TranscriptionLanguage.allCases.first {
                !capabilities.supportedLanguages.contains($0)
            }
            var shapes: [TranscriptionLanguageSelection] = [.automatic]
            if let one = supported.first {
                shapes.append(try TranscriptionLanguageSelection(selectedLanguages: [one]))
            }
            if let unsupported {
                shapes.append(try TranscriptionLanguageSelection(selectedLanguages: [unsupported]))
            }
            if supported.count >= 2 {
                let pair = Array(supported.prefix(2))
                shapes.append(try TranscriptionLanguageSelection(
                    selectedLanguages: pair,
                    dominantLanguage: pair[0]
                ))
                shapes.append(try TranscriptionLanguageSelection(selectedLanguages: pair))
            } else if let unsupported, let one = supported.first {
                let pair = [one, unsupported]
                shapes.append(try TranscriptionLanguageSelection(
                    selectedLanguages: pair,
                    dominantLanguage: one
                ))
                shapes.append(try TranscriptionLanguageSelection(selectedLanguages: pair))
            }

            for workload in capabilities.workloads {
                for selection in shapes {
                    let decision = TranscriptionLanguageRouter.resolve(
                        selection: selection,
                        capabilities: capabilities,
                        workload: workload
                    )
                    if case .incompatible(let reason) = decision {
                        Issue.record(
                            "\(backend.label) \(workload.rawValue) \(selection.selectedLanguages.map(\.rawValue)) -> \(reason)"
                        )
                    }
                    #expect(TranscriptionLanguageRouter.runtimeDecision(
                        selection: selection,
                        capabilities: capabilities,
                        workload: workload
                    ) == decision)
                }
            }
        }
    }

    @Test("trace snapshot records content-free selection and routing fields")
    func traceSnapshotIsContentFree() throws {
        let profile = try LanguageProfile(
            selectedLanguages: [.arabic],
            dominantLanguage: .arabic
        )
        let data = Data(SessionTraceSnapshot.languageProfile(
            backend: .whisperLargeTurbo,
            profile: profile
        ).utf8)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["selectedLanguages"] as? [String] == ["ar"])
        #expect(json["routingResult"] as? String == "pinned")
        #expect(json["candidateCount"] as? Int == 1)
        #expect(json["confidence"] == nil)
        #expect(json["transcript"] == nil)
        #expect(json["audio"] == nil)
    }
}
