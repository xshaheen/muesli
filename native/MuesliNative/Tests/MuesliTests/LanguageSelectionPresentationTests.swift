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
        let automatic = DictationLanguageProfile.automatic.presentation(
            for: .whisperSmall,
            isAvailable: true
        )
        #expect(automatic.state == .automatic)
        #expect(automatic.backendID == BackendOption.whisperSmall.transcriptionBackendID)

        let pinned = try DictationLanguageProfile(
            selectedLanguages: [.arabic]
        ).presentation(for: .whisperLargeTurbo, isAvailable: true)
        #expect(pinned.state == .pinned)
        #expect(pinned.selectedLanguageIDs == ["ar"])

        let constrainedDisabled = try DictationLanguageProfile(
            selectedLanguages: [.english, .arabic]
        ).presentation(for: .whisperLargeTurbo, isAvailable: true)
        #expect(constrainedDisabled.state == .incompatible)
        #expect(constrainedDisabled.selectedLanguageIDs == ["ar", "en"])

        let unavailable = try DictationLanguageProfile(
            selectedLanguages: [.arabic]
        ).presentation(for: .whisperLargeTurbo, isAvailable: false)
        #expect(unavailable.state == .unavailable)
        #expect(unavailable.backendID == BackendOption.whisperLargeTurbo.transcriptionBackendID)
        #expect(unavailable.selectedLanguageIDs == ["ar"])
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
