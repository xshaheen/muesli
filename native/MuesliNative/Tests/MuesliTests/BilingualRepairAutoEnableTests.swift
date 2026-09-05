import Foundation
import Testing

@testable import MuesliCore
@testable import MuesliNativeApp

/// The one-time auto-enable latch (KTD6, R7).
@Suite("Bilingual repair auto-enable")
struct BilingualRepairAutoEnableTests {

    private func config(
        languages: [TranscriptionLanguage],
        cleanupOn: Bool = false,
        alreadyApplied: Bool = false
    ) throws -> AppConfig {
        var config = AppConfig()
        config.dictationLanguageProfile = try SpokenLanguageProfile(selectedLanguages: languages)
        config.enablePostProcessor = cleanupOn
        config.bilingualRepairAutoEnableApplied = alreadyApplied
        return config
    }

    @Test("a bilingual profile with the latch unset enables cleanup and records the attempt")
    func firstBilingualRunEnables() throws {
        let decision = BilingualRepairAutoEnable.decide(
            config: try config(languages: [.arabic, .english])
        )
        #expect(decision.recordsAttempt)
        #expect(decision.enablesPostProcessor)
    }

    @Test("the latch stops a second attempt")
    func latchStopsSecondAttempt() throws {
        let decision = BilingualRepairAutoEnable.decide(
            config: try config(languages: [.arabic, .english], alreadyApplied: true)
        )
        #expect(decision == .none)
    }

    @Test("a user who turned cleanup off after the latch keeps it off")
    func userOptOutSurvives() throws {
        let decision = BilingualRepairAutoEnable.decide(
            config: try config(languages: [.arabic, .english], cleanupOn: false, alreadyApplied: true)
        )
        #expect(!decision.enablesPostProcessor)
    }

    @Test("a monolingual profile neither enables nor records")
    func monolingualDoesNothing() throws {
        #expect(BilingualRepairAutoEnable.decide(config: try config(languages: [.english])) == .none)
    }

    @Test("an automatic profile neither enables nor records")
    func automaticDoesNothing() throws {
        #expect(BilingualRepairAutoEnable.decide(config: try config(languages: [])) == .none)
    }

    @Test("cleanup already on records the attempt without re-enabling")
    func alreadyOnRecordsOnly() throws {
        let decision = BilingualRepairAutoEnable.decide(
            config: try config(languages: [.arabic, .english], cleanupOn: true)
        )
        #expect(decision.recordsAttempt)
        #expect(!decision.enablesPostProcessor)
    }

    @Test("the latch round-trips through config encoding")
    func latchRoundTrips() throws {
        var original = try config(languages: [.arabic, .english])
        original.bilingualRepairAutoEnableApplied = true
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.bilingualRepairAutoEnableApplied)
    }

    @Test("a config saved before this feature decodes with the latch unset")
    func legacyConfigDecodesUnset() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(!decoded.bilingualRepairAutoEnableApplied)
    }
}
