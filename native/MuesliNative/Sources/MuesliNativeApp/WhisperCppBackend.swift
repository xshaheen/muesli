import Foundation
import WhisperKit
import MuesliCore

struct WhisperKitScoredTranscription: Sendable {
    let text: String
    let processingTime: Double
    let normalizedScore: Double?
    let tokenCount: Int
}

/// Native Swift transcription backend using WhisperKit (CoreML on ANE/GPU).
actor WhisperKitTranscriber {
    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    enum TranscriberError: Error, LocalizedError {
        case notLoaded
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notLoaded: return "WhisperKit model not loaded."
            case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
            }
        }
    }

    /// The model currently resident, if any. Model deletion consults this so
    /// removing one Whisper variant's files never unloads a resident sibling.
    func currentLoadedModelName() -> String? {
        whisperKit == nil ? nil : loadedModel
    }

    /// Load a WhisperKit CoreML model. Downloads from HuggingFace if not cached.
    func loadModel(
        modelName: String,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        if loadedModel == modelName, whisperKit != nil { return }

        fputs("[whisperkit] loading model: \(modelName)...\n", stderr)
        let plan = ManagedASRModelPlans.whisperKit(modelName: modelName)
        let loadedWhisperKit = try await ManagedASRModelDownloader.loadValidated(
            plan,
            progress: progress,
            progressSnapshot: progressSnapshot
        ) { modelFolder in
            let preparing = ModelDownloadProgress.preparing(
                modelID: plan.modelID,
                message: "Loading WhisperKit into Core ML..."
            )
            progress?(0.95, preparing.message)
            progressSnapshot?(preparing)

            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                )
            )
            return try await WhisperKit(config)
        }

        whisperKit = loadedWhisperKit
        loadedModel = modelName
        fputs("[whisperkit] model loaded: \(modelName)\n", stderr)
    }

    /// Transcribe a 16kHz mono WAV file.
    ///
    /// `vocabulary` conditions the decoder on the user's dictionary via Whisper's initial
    /// prompt. Prompt tokens sit before the start-of-transcript token, so WhisperKit strips
    /// them from the result — but the model can still echo them when it hallucinates on
    /// near-silent audio, which is why the prompt stays a bare term list.
    /// - Parameter language: `.auto` enables WhisperKit language detection; otherwise pins that ISO code.
    ///   Ignored for English-only `.en` models, which keep default English decoding.
    func transcribe(
        wavURL: URL,
        vocabulary: AsrVocabularyPrompt? = nil,
        language: WhisperKitLanguage = .defaultLanguage
    ) async throws -> (text: String, processingTime: Double) {
        let result = try await transcribeWithConfidence(
            wavURL: wavURL,
            vocabulary: vocabulary,
            language: language
        )
        return (result.text, result.processingTime)
    }

    func transcribeWithConfidence(
        wavURL: URL,
        vocabulary: AsrVocabularyPrompt? = nil,
        language: WhisperKitLanguage = .defaultLanguage
    ) async throws -> WhisperKitScoredTranscription {
        guard let whisperKit else { throw TranscriberError.notLoaded }
        guard let loadedModel else { throw TranscriberError.notLoaded }

        let start = CFAbsoluteTimeGetCurrent()
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioPath: wavURL.path,
            decodeOptions: decodeOptions(
                for: vocabulary,
                language: language,
                modelName: loadedModel,
                whisperKit: whisperKit
            )
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = results.flatMap(\.segments)
        let scoreInputs = segments.map {
            (averageLogProbability: Double($0.avgLogprob), tokenCount: $0.tokens.count)
        }
        return WhisperKitScoredTranscription(
            text: text,
            processingTime: elapsed,
            normalizedScore: WhisperSegmentConfidenceAdapter.normalizedScore(scoreInputs),
            tokenCount: scoreInputs.reduce(0) { $0 + $1.tokenCount }
        )
    }

    private func decodeOptions(
        for vocabulary: AsrVocabularyPrompt?,
        language: WhisperKitLanguage,
        modelName: String,
        whisperKit: WhisperKit
    ) -> DecodingOptions {
        var promptTokens: [Int]?
        if let vocabulary, let tokenizer = whisperKit.tokenizer {
            // Leading space matches Whisper's prompt convention: its BPE merges are space-prefixed,
            // so an unprefixed first term tokenizes differently from the same word mid-sentence.
            let tokens = tokenizer.encode(text: " " + vocabulary.text)
            if !tokens.isEmpty {
                promptTokens = tokens
                fputs("[whisperkit] vocabulary biasing: \(vocabulary.termCount) terms, \(tokens.count) prompt tokens\n", stderr)
            }
        } else if vocabulary != nil {
            fputs("[whisperkit] vocabulary biasing skipped: tokenizer unavailable\n", stderr)
        }

        return Self.makeDecodeOptions(
            language: language,
            modelName: modelName,
            promptTokens: promptTokens
        )
    }

    /// Build WhisperKit decode options for the loaded model.
    /// English-only checkpoints ignore language preference and keep default English decoding.
    static func makeDecodeOptions(
        language: WhisperKitLanguage,
        modelName: String,
        promptTokens: [Int]? = nil
    ) -> DecodingOptions {
        guard let effective = WhisperKitLanguage.preferenceForLoadedModel(language, modelName: modelName) else {
            return DecodingOptions(promptTokens: promptTokens)
        }
        switch effective {
        case .auto:
            // Default DecodingOptions leaves detectLanguage false when usePrefillPrompt is true,
            // which silently forces English. Request detection explicitly for multilingual models.
            return DecodingOptions(detectLanguage: true, promptTokens: promptTokens)
        default:
            return DecodingOptions(language: effective.rawValue, promptTokens: promptTokens)
        }
    }

    /// Run a short silent transcription to trigger CoreML compilation.
    /// First-run compilation takes 10-30s; subsequent loads are instant.
    func warmup() async throws {
        guard let whisperKit else { return }
        let silence = [Float](repeating: 0, count: 16000) // 1 second of silence at 16kHz
        let start = CFAbsoluteTimeGetCurrent()
        let _: [TranscriptionResult] = try await whisperKit.transcribe(audioArray: silence)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        fputs("[whisperkit] warmup transcription took \(String(format: "%.1f", elapsed))s\n", stderr)
    }

    func shutdown() {
        whisperKit = nil
        loadedModel = nil
    }

    // MARK: - Model Storage

    /// WhisperKit stores models under ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/.
    /// Each model variant is a direct subdirectory (e.g. openai_whisper-small/).
    static func isModelDownloaded(_ modelName: String) -> Bool {
        ManagedASRModelPlans.whisperKit(modelName: modelName).isAvailableLocally()
    }

    /// Delete cached model files for a WhisperKit model variant.
    static func deleteModel(_ modelName: String) {
        try? ManagedASRModelPlans.whisperKit(modelName: modelName).delete()
    }
}
