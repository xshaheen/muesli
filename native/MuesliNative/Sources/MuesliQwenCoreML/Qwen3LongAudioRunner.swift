import Foundation
import MuesliCore

public enum Qwen3SilenceSignal: Equatable, Sendable {
    case silence
    case speech
    case indeterminate
}

public enum Qwen3SilenceClassification: Equatable, Sendable {
    case confirmedSilence
    case speech
    case indeterminate
}

/// Fail-closed composition used by both front ends: silence is accepted only
/// when independent energy and VAD signals both positively classify silence.
public struct Qwen3FailClosedSilenceClassifier: Sendable {
    public typealias Signal = @Sendable ([Float]) async throws -> Qwen3SilenceSignal

    private let energySignal: Signal
    private let vadSignal: Signal

    public init(energySignal: @escaping Signal, vadSignal: @escaping Signal) {
        self.energySignal = energySignal
        self.vadSignal = vadSignal
    }

    public func classify(_ samples: [Float]) async throws -> Qwen3SilenceClassification {
        try Task.checkCancellation()
        let energy = try await energySignal(samples)
        try Task.checkCancellation()
        let vad = try await vadSignal(samples)
        try Task.checkCancellation()
        switch (energy, vad) {
        case (.silence, .silence): return .confirmedSilence
        case (.speech, .speech): return .speech
        default: return .indeterminate
        }
    }

    public static func rootMeanSquareSignal(
        threshold: Float = 0.003
    ) -> Signal {
        { samples in
            guard !samples.isEmpty else { return .indeterminate }
            let sum = samples.reduce(0.0) { partial, sample in
                partial + Double(sample) * Double(sample)
            }
            let rms = sqrt(sum / Double(samples.count))
            guard rms.isFinite else { return .indeterminate }
            return rms < Double(threshold) ? .silence : .speech
        }
    }
}

public struct Qwen3LongAudioResult: Equatable, Sendable {
    public let text: String
    public let normalizedLexicalTokenConfidence: Double?
    public let lexicalTokenCount: Int
    public let duration: TimeInterval
    public let windowCount: Int
    public let language: TranscriptionLanguage?
}

public enum Qwen3LongAudioError: Error, LocalizedError, Equatable, Sendable {
    case durationExceeded(actual: TimeInterval, maximum: TimeInterval)
    case workLimitExceeded(requestedCalls: Int, maximumCalls: Int)
    case cacheCapacity(window: Int, promptLength: Int, capacity: Int)
    case windowFailed(window: Int, total: Int, detail: String)
    case emptySpeechWindow(window: Int, total: Int)
    case silenceClassificationIndeterminate(window: Int, total: Int)

    public var errorDescription: String? {
        switch self {
        case .durationExceeded(let actual, let maximum):
            "Qwen audio is \(String(format: "%.1f", actual)) seconds; the maximum is \(String(format: "%.0f", maximum)) seconds."
        case .workLimitExceeded(let requested, let maximum):
            "Qwen transcription would require \(requested) model calls; the maximum is \(maximum)."
        case .cacheCapacity(let window, let promptLength, let capacity):
            "Qwen window \(window + 1) exceeded decoder cache capacity (prompt \(promptLength), capacity \(capacity))."
        case .windowFailed(let window, let total, let detail):
            "Qwen window \(window + 1) of \(total) failed: \(detail)"
        case .emptySpeechWindow(let window, let total):
            "Qwen window \(window + 1) of \(total) returned empty text even though speech was detected."
        case .silenceClassificationIndeterminate(let window, let total):
            "Qwen window \(window + 1) of \(total) returned empty text and silence could not be confirmed."
        }
    }
}

/// Sequential, all-or-nothing Qwen orchestration. No window transcript escapes
/// before every requested candidate/window call, classification, and merge has
/// succeeded.
public struct Qwen3LongAudioRunner: Sendable {
    public typealias Inference = @Sendable (
        _ samples: [Float],
        _ language: TranscriptionLanguage?
    ) async throws -> MuesliQwen3Transcription

    public static let maximumDuration: TimeInterval = 20 * 60
    public static let maximumCandidateWindowCalls = 134

    private let reader: Qwen3AudioWindowReader
    private let silenceClassifier: Qwen3FailClosedSilenceClassifier
    private let inference: Inference

    public init(
        reader: Qwen3AudioWindowReader = Qwen3AudioWindowReader(),
        silenceClassifier: Qwen3FailClosedSilenceClassifier,
        inference: @escaping Inference
    ) {
        self.reader = reader
        self.silenceClassifier = silenceClassifier
        self.inference = inference
    }

    public func preflight(
        wavURL: URL,
        candidateCount: Int
    ) throws -> (duration: TimeInterval, windows: [Qwen3AudioWindowDescriptor]) {
        let duration = try reader.duration(of: wavURL)
        guard duration <= Self.maximumDuration else {
            throw Qwen3LongAudioError.durationExceeded(
                actual: duration,
                maximum: Self.maximumDuration
            )
        }
        let windows = try reader.descriptors(forDuration: duration)
        let requestedCalls = windows.count * max(candidateCount, 1)
        guard requestedCalls <= Self.maximumCandidateWindowCalls else {
            throw Qwen3LongAudioError.workLimitExceeded(
                requestedCalls: requestedCalls,
                maximumCalls: Self.maximumCandidateWindowCalls
            )
        }
        return (duration, windows)
    }

    public func run(
        wavURL: URL,
        language: TranscriptionLanguage?,
        candidateCount: Int = 1
    ) async throws -> Qwen3LongAudioResult {
        try Task.checkCancellation()
        let plan = try preflight(wavURL: wavURL, candidateCount: candidateCount)
        try Task.checkCancellation()

        var transcripts: [String] = []
        var weightedScore = 0.0
        var scoredTokenCount = 0
        var hasUnscoredSpeech = false

        for descriptor in plan.windows {
            try Task.checkCancellation()
            let window = try reader.read(descriptor, from: wavURL)
            try Task.checkCancellation()

            let transcription: MuesliQwen3Transcription
            do {
                transcription = try await inference(window.samples, language)
            } catch let error as MuesliQwen3AsrError {
                switch error {
                case .cacheCapacityExceeded(let promptLength, let capacity):
                    throw Qwen3LongAudioError.cacheCapacity(
                        window: descriptor.index,
                        promptLength: promptLength,
                        capacity: capacity
                    )
                default:
                    throw Qwen3LongAudioError.windowFailed(
                        window: descriptor.index,
                        total: descriptor.totalCount,
                        detail: error.localizedDescription
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Qwen3LongAudioError.windowFailed(
                    window: descriptor.index,
                    total: descriptor.totalCount,
                    detail: error.localizedDescription
                )
            }
            try Task.checkCancellation()

            let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                let classification = try await silenceClassifier.classify(window.samples)
                try Task.checkCancellation()
                switch classification {
                case .confirmedSilence:
                    continue
                case .speech:
                    throw Qwen3LongAudioError.emptySpeechWindow(
                        window: descriptor.index,
                        total: descriptor.totalCount
                    )
                case .indeterminate:
                    throw Qwen3LongAudioError.silenceClassificationIndeterminate(
                        window: descriptor.index,
                        total: descriptor.totalCount
                    )
                }
            }

            transcripts.append(text)
            if let score = transcription.normalizedLexicalTokenConfidence,
               score.isFinite,
               transcription.lexicalTokenCount > 0 {
                weightedScore += score * Double(transcription.lexicalTokenCount)
                scoredTokenCount += transcription.lexicalTokenCount
            } else {
                hasUnscoredSpeech = true
            }
        }

        try Task.checkCancellation()
        let merged = Qwen3TranscriptMerger.merge(transcripts)
        try Task.checkCancellation()
        let normalizedScore = !hasUnscoredSpeech && scoredTokenCount > 0
            ? weightedScore / Double(scoredTokenCount)
            : nil
        try Task.checkCancellation()
        return Qwen3LongAudioResult(
            text: merged,
            normalizedLexicalTokenConfidence: normalizedScore,
            lexicalTokenCount: scoredTokenCount,
            duration: plan.duration,
            windowCount: plan.windows.count,
            language: language
        )
    }
}
