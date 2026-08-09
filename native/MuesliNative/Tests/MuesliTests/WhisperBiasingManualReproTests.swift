import Foundation
import Testing
@testable import MuesliNativeApp

/// Manual reproduction harness for the empty-transcript-with-vocabulary-biasing bug.
/// Loads the real 626MB Whisper model and transcribes a real WAV, so it only runs
/// when pointed at one: MUESLI_WHISPER_REPRO_WAV=/path/to/16k-mono.wav swift test ...
@Suite(
    "Manual Whisper biasing repro",
    .enabled(if: ProcessInfo.processInfo.environment["MUESLI_WHISPER_REPRO_WAV"] != nil)
)
struct WhisperBiasingManualReproTests {
    @Test("biased decode should not be empty when unbiased decode has text")
    func biasedVersusUnbiased() async throws {
        let wav = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["MUESLI_WHISPER_REPRO_WAV"]!
        )
        let transcriber = WhisperKitTranscriber()
        try await transcriber.loadModel(modelName: "large-v3-v20240930_626MB")

        let unbiased = try await transcriber.transcribe(wavURL: wav)
        print("UNBIASED (\(String(format: "%.2f", unbiased.processingTime))s): '\(unbiased.text)'")

        let mixed = AsrVocabularyPrompt(
            text: "muesli, نعمل, one-to-many, refactor, project, b2b, b2c, qouta, capacity, registeration, invitation, countries, validate, activate, members, checkbox, integration, core, refund, audit, أيام, بيدخل, booking, template",
            termCount: 24
        )
        let biasedMixed = try await transcriber.transcribe(wavURL: wav, vocabulary: mixed)
        print("BIASED-MIXED (\(String(format: "%.2f", biasedMixed.processingTime))s): '\(biasedMixed.text)'")

        let latin = AsrVocabularyPrompt(
            text: "muesli, one-to-many, refactor, project, booking, template",
            termCount: 6
        )
        let biasedLatin = try await transcriber.transcribe(wavURL: wav, vocabulary: latin)
        print("BIASED-LATIN (\(String(format: "%.2f", biasedLatin.processingTime))s): '\(biasedLatin.text)'")

        #expect(!unbiased.text.isEmpty)
        #expect(!biasedMixed.text.isEmpty)
        #expect(!biasedLatin.text.isEmpty)
    }
}
