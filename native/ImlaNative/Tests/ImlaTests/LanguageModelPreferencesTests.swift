import Foundation
import ImlaCore
import Testing
@testable import ImlaNativeApp

@Suite("Language model preferences")
struct LanguageModelPreferencesTests {
    @Test("language choices round-trip through the snake_case config key")
    func configRoundTrip() throws {
        var config = AppConfig()
        config.languageModels[.arabic] = .init(dictation: .init(.cohereArabic), meeting: .init(.whisperLargeTurbo))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.languageModels == config.languageModels)
        #expect(String(decoding: data, as: UTF8.self).contains("\"language_models\""))
        #expect(try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8)).languageModels.languages.isEmpty)
    }

    @Test("a corrupt assignment does not erase another language or its valid meeting override")
    func lossyEntries() throws {
        let input = #"{"ar":{"dictation":{"backend":"future","model":"future-model"}},"en":{"dictation":42,"meeting":{"backend":"whisper","model":"small"}},"fr":false,"unknown":{"dictation":null}}"#
        let preferences = try JSONDecoder().decode(LanguageModelPreferences.self, from: Data(input.utf8))
        #expect(preferences.languages == [.arabic, .english])
        #expect(preferences[.arabic].dictation?.model == "future-model")
        #expect(preferences[.english].dictation == nil)
        #expect(preferences[.english].meeting?.option == .whisperSmall)
    }

    @Test("meetings inherit compatible dictation choices and honor their own overrides")
    func meetingInheritance() {
        var preferences = LanguageModelPreferences()
        preferences[.arabic] = .init(dictation: .init(.cohereArabic))
        let inherited = resolve(.arabic, preferences: preferences, workload: .meeting)
        #expect(inherited.backend == .cohereArabic)
        #expect(!inherited.usedFallback)
        preferences[.arabic].meeting = .init(.whisperLargeTurbo)
        #expect(resolve(.arabic, preferences: preferences, workload: .meeting).backend == .whisperLargeTurbo)
        #expect(resolve(.arabic, preferences: preferences, workload: .dictation).backend == .cohereArabic)
    }

    @Test("a streaming-only dictation model uses a compatible meeting fallback")
    func streamingInheritanceFallback() {
        var preferences = LanguageModelPreferences()
        preferences[.arabic] = .init(dictation: .init(.nemotron35Multilingual))
        let result = resolve(.arabic, preferences: preferences, workload: .meeting)
        #expect(result.backend == .whisperLargeTurbo)
        #expect(result.usedFallback)
        #expect(result.isUsable)
    }

    @Test("missing models fall back only to installed language-compatible models")
    func missingModelFallback() {
        var preferences = LanguageModelPreferences()
        preferences[.arabic] = .init(dictation: .init(.cohereArabic))
        let result = LanguageModelRouting.resolve(
            language: .arabic, preferences: preferences,
            dictationDefault: .parakeetUnified, meetingDefault: .parakeetUnified,
            available: [.parakeetUnified, .whisperSmall], workload: .dictation
        )
        #expect(result.backend == .whisperSmall)
        #expect(result.usedFallback && result.isUsable)
        let unavailable = LanguageModelRouting.resolve(
            language: .arabic, preferences: preferences,
            dictationDefault: .parakeetUnified, meetingDefault: .parakeetUnified,
            available: [.parakeetUnified], workload: .dictation
        )
        #expect(!unavailable.isUsable)
    }

    @Test("keyboard locales normalize to one language and ambiguous sources detect automatically")
    func keyboardLanguageResolution() {
        #expect(KeyboardLanguageSnapshot.resolve(["en-US"]) == .english)
        #expect(KeyboardLanguageSnapshot.resolve(["ar-EG"]) == .arabic)
        #expect(KeyboardLanguageSnapshot.resolve(["en-US", "en-GB"]) == .english)
        #expect(KeyboardLanguageSnapshot.resolve(["en", "ar"]) == nil)
        #expect(KeyboardLanguageSnapshot.resolve([]) == nil)
        #expect(KeyboardLanguageSnapshot.resolve(["zz"]) == nil)
    }

    @Test("captured keyboard profiles remain stable when the next input source changes")
    func keyboardSnapshotRemainsStable() {
        let arabic = KeyboardLanguageSnapshot(language: .arabic, enabledLanguages: [.arabic, .english])
        let before = arabic.spokenProfile()
        let english = KeyboardLanguageSnapshot(language: .english, enabledLanguages: [.arabic, .english])
        #expect(before.dominantLanguage == .arabic)
        #expect(english.spokenProfile().dominantLanguage == .english)
        #expect(before.selectedLanguages == [.arabic, .english])
    }

    private func resolve(
        _ language: TranscriptionLanguage, preferences: LanguageModelPreferences,
        workload: LanguageModelRouting.Workload
    ) -> LanguageModelRouting.Resolution {
        LanguageModelRouting.resolve(
            language: language, preferences: preferences,
            dictationDefault: .parakeetUnified, meetingDefault: .whisperLargeTurbo,
            available: [.parakeetUnified, .cohereArabic, .whisperLargeTurbo, .nemotron35Multilingual],
            workload: workload
        )
    }
}
