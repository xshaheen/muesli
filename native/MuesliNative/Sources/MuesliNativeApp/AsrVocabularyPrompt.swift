import Foundation
import MuesliCore

/// ASR-stage vocabulary biasing built from the user's personal dictionary.
///
/// `CustomWordMatcher` repairs the transcript after the fact, which only works when the
/// recognizer produced something close to the intended word. Conditioning the recognizer
/// on the vocabulary up front prevents the damage instead: Whisper takes this as its
/// initial prompt (`DecodingOptions.promptTokens`), which biases the decoder toward the
/// listed spellings — the difference between "refactor" and a transliterated «ريفا كتير»
/// when dictating mixed Arabic/English.
///
/// The prompt is deliberately a bare comma-separated term list. Whisper copies prompt
/// *style* into its output, and on silence or a hallucination it can echo prompt words
/// verbatim, so anything sentence-shaped here would surface in real transcripts. Keeping
/// it to a term list bounds that leak to stray vocabulary words.
struct AsrVocabularyPrompt: Sendable {
    /// Whisper's prompt window is 224 tokens. 600 characters keeps a Latin-script term
    /// list safely inside it; longer dictionaries are truncated at a term boundary.
    static let maxCharacters = 600

    let text: String
    /// Terms that survived dedupe and truncation. Logged so biasing is auditable.
    let termCount: Int

    /// Build a biasing prompt from the user's dictionary, or nil when there is nothing
    /// to bias toward. Uses each entry's canonical form (the replacement when set), since
    /// that is the spelling we want the recognizer to emit.
    static func build(customWords: [CustomWord]) -> AsrVocabularyPrompt? {
        var seen = Set<String>()
        var terms: [String] = []
        var length = 0

        for word in customWords {
            let term = word.targetWord.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            let separator = terms.isEmpty ? 0 : 2 // ", "
            guard length + separator + term.count <= maxCharacters else { break }
            terms.append(term)
            length += separator + term.count
        }

        guard !terms.isEmpty else { return nil }
        return AsrVocabularyPrompt(text: terms.joined(separator: ", "), termCount: terms.count)
    }
}
