import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("ASR Vocabulary Prompt")
struct AsrVocabularyPromptTests {

    private func word(_ word: String, replacement: String? = nil) -> CustomWord {
        CustomWord(word: word, replacement: replacement)
    }

    @Test("empty dictionary produces no prompt")
    func emptyDictionary() {
        #expect(AsrVocabularyPrompt.build(customWords: []) == nil)
    }

    @Test("entries that trim to nothing produce no prompt")
    func blankEntries() {
        #expect(AsrVocabularyPrompt.build(customWords: [word("   "), word("\n")]) == nil)
    }

    @Test("terms are comma-separated in dictionary order")
    func joinsTerms() {
        let prompt = AsrVocabularyPrompt.build(customWords: [word("Kubernetes"), word("Muesli"), word("Parakeet")])
        #expect(prompt?.text == "Kubernetes, Muesli, Parakeet")
        #expect(prompt?.termCount == 3)
    }

    @Test("uses the replacement as the canonical spelling")
    func prefersReplacement() {
        let prompt = AsrVocabularyPrompt.build(customWords: [word("ريفا كتير", replacement: "refactor")])
        #expect(prompt?.text == "refactor")
    }

    @Test("terms are trimmed")
    func trimsWhitespace() {
        let prompt = AsrVocabularyPrompt.build(customWords: [word("  SwiftUI  "), word("\tCoreML\n")])
        #expect(prompt?.text == "SwiftUI, CoreML")
    }

    @Test("duplicates are dropped case-insensitively, keeping the first spelling")
    func dedupes() {
        let prompt = AsrVocabularyPrompt.build(customWords: [
            word("WhisperKit"),
            word("whisperkit"),
            word("misheard", replacement: "WHISPERKIT"),
            word("Nemotron"),
        ])
        #expect(prompt?.text == "WhisperKit, Nemotron")
        #expect(prompt?.termCount == 2)
    }

    @Test("prompt is capped at the character limit")
    func capsLongDictionaries() throws {
        let words = (0..<200).map { word("terminology-entry-\($0)") }
        let prompt = try #require(AsrVocabularyPrompt.build(customWords: words))
        #expect(prompt.text.count <= AsrVocabularyPrompt.maxCharacters)
        #expect(prompt.termCount < words.count)
        // Truncation happens at a term boundary, never mid-word.
        #expect(!prompt.text.hasSuffix(","))
        #expect(prompt.text.components(separatedBy: ", ").count == prompt.termCount)
    }

    @Test("a term that would overflow the cap does not truncate the prompt mid-term")
    func capsSingleOversizedTerm() {
        let long = String(repeating: "x", count: AsrVocabularyPrompt.maxCharacters + 1)
        #expect(AsrVocabularyPrompt.build(customWords: [word(long)]) == nil)
        let prompt = AsrVocabularyPrompt.build(customWords: [word("Muesli"), word(long)])
        #expect(prompt?.text == "Muesli")
    }

    @Test("term count matches the terms that survived truncation")
    func termCountMatchesText() throws {
        let words = (0..<200).map { word("term\($0)") }
        let prompt = try #require(AsrVocabularyPrompt.build(customWords: words))
        #expect(prompt.text.components(separatedBy: ", ").count == prompt.termCount)
    }
}
