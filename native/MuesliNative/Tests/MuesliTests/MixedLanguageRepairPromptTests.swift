import Foundation
import Testing

@testable import MuesliCore
@testable import MuesliNativeApp

/// The repair block is derived from the spoken-language profile (KTD1), so these
/// tests drive the selector from profiles rather than from any stored preset.
@Suite("Mixed-language repair prompt")
struct MixedLanguageRepairPromptTests {

    private func profile(
        _ languages: [TranscriptionLanguage],
        dominant: TranscriptionLanguage? = nil
    ) throws -> SpokenLanguageProfile {
        try SpokenLanguageProfile(selectedLanguages: languages, dominantLanguage: dominant)
    }

    @Test("Arabic and English selected yields the Arabic-specific block")
    func arabicEnglishUsesArabicExamples() throws {
        let block = try #require(
            MixedLanguageRepairPrompt.block(for: profile([.arabic, .english]), compact: false)
        )
        #expect(block.contains("primary key"))
        #expect(block.contains("البرايمريكية"))
    }

    @Test("A non-Arabic bilingual pair yields the script-neutral block")
    func otherPairUsesNeutralText() throws {
        let block = try #require(
            MixedLanguageRepairPrompt.block(for: profile([.french, .english]), compact: false)
        )
        // R3: the same rules, without examples drawn from a script the user did not select.
        #expect(!block.contains("البرايمريكية"))
        let arabicScript = block.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
        #expect(!arabicScript)
        #expect(block.lowercased().contains("restore"))
    }

    @Test("A single-language profile yields no block")
    func monolingualYieldsNil() throws {
        let block = MixedLanguageRepairPrompt.block(for: try profile([.english]), compact: false)
        #expect(block == nil)
    }

    @Test("An automatic profile yields no block")
    func automaticYieldsNil() {
        #expect(MixedLanguageRepairPrompt.block(for: .automatic, compact: false) == nil)
    }

    @Test("The compact block is shorter and keeps the load-bearing rules")
    func compactIsShorterAndComplete() throws {
        let full = try #require(
            MixedLanguageRepairPrompt.block(for: profile([.arabic, .english]), compact: false)
        )
        let compact = try #require(
            MixedLanguageRepairPrompt.block(for: profile([.arabic, .english]), compact: true)
        )
        // R6: the on-device budget is the reason the compact variant exists.
        #expect(compact.count < full.count)
        #expect(compact.lowercased().contains("translate"))
        #expect(compact.lowercased().contains("omit") || compact.lowercased().contains("summar"))
    }

    @Test("Both variants authorize restoring a mangled term")
    func bothVariantsAuthorizeRestoration() throws {
        let bilingual = try profile([.arabic, .english])
        for compact in [true, false] {
            let block = try #require(MixedLanguageRepairPrompt.block(for: bilingual, compact: compact))
            // R5: the carve-out has to be explicit, because the base prompt forbids
            // changing words and the model sees both.
            #expect(block.lowercased().contains("not paraphrasing"))
        }
    }

    @Test("The block is delimited so the model sees a bounded region")
    func blockIsDelimited() throws {
        let block = try #require(
            MixedLanguageRepairPrompt.block(for: profile([.arabic, .english]), compact: false)
        )
        #expect(block.hasPrefix(MixedLanguageRepairPrompt.openingTag))
        #expect(block.hasSuffix(MixedLanguageRepairPrompt.closingTag))
    }

    @Test("A three-language profile including Arabic and English still gets the Arabic block")
    func threeLanguagesIncludingPairUsesArabicExamples() throws {
        let block = try #require(
            MixedLanguageRepairPrompt.block(
                for: profile([.arabic, .english, .french]),
                compact: false
            )
        )
        #expect(block.contains("البرايمريكية"))
    }
}
