import AVFoundation
import Foundation
import MuesliCore
import MuesliQwenCoreML
import Testing

@Suite("Qwen3 bounded long-audio orchestration")
struct Qwen3LongAudioTests {
    @Test("20-second windows with 2-second overlap cover every sample exactly to the tail")
    func exactCoverage() {
        let total = 53 * Qwen3AudioWindowReader.targetSampleRate + 7
        let windows = Qwen3AudioWindowReader.descriptors(totalSampleCount: total)
        #expect(windows.map(\.startSample) == [0, 288_000, 576_000])
        #expect(windows.map(\.endSample) == [320_000, 608_000, total])
        #expect(windows.last?.sampleCount == total - 576_000)

        #expect(windows.first?.startSample == 0)
        #expect(windows.last?.endSample == total)
        for pair in zip(windows, windows.dropFirst()) {
            #expect(pair.1.startSample <= pair.0.endSample)
            #expect(pair.0.endSample - pair.1.startSample == Qwen3AudioWindowReader.overlapSampleCount)
        }
    }

    @Test("20-minute two-candidate request is exactly the 134-call ceiling")
    func workCeiling() {
        let windows = Qwen3AudioWindowReader.descriptors(
            totalSampleCount: 20 * 60 * Qwen3AudioWindowReader.targetSampleRate
        )
        #expect(windows.count == 67)
        #expect(windows.count * 2 == Qwen3LongAudioRunner.maximumCandidateWindowCalls)
    }

    @Test("three-word overlap merges but short or ambiguous overlap preserves both")
    func wordMerge() {
        #expect(Qwen3TranscriptMerger.merge(
            "alpha beta one two three",
            "one two three gamma delta"
        ) == "alpha beta one two three gamma delta")
        #expect(Qwen3TranscriptMerger.merge(
            "alpha beta one two",
            "one two gamma"
        ) == "alpha beta one two one two gamma")
    }

    @Test("eight-grapheme overlap merges Arabic boundaries")
    func graphemeMerge() {
        #expect(Qwen3TranscriptMerger.merge("قبل العربيةجميلة", "العربيةجميلة جدا") == "قبل العربيةجميلة جدا")
    }

    @Test("silence classification fails closed on disagreement and unavailable signals")
    func silenceFailsClosed() async throws {
        let disagreement = Qwen3FailClosedSilenceClassifier(
            energySignal: { _ in .silence },
            vadSignal: { _ in .speech }
        )
        #expect(try await disagreement.classify([0]) == .indeterminate)

        let unavailable = Qwen3FailClosedSilenceClassifier(
            energySignal: { _ in .silence },
            vadSignal: { _ in .indeterminate }
        )
        #expect(try await unavailable.classify([0]) == .indeterminate)
    }

    @Test("empty decode succeeds only for independently confirmed silence")
    func emptyDecodeContract() async throws {
        let url = try temporaryWAV(samples: [Float](repeating: 0, count: 16_000))
        defer { try? FileManager.default.removeItem(at: url) }
        let runner = Qwen3LongAudioRunner(
            silenceClassifier: Qwen3FailClosedSilenceClassifier(
                energySignal: { _ in .silence },
                vadSignal: { _ in .silence }
            ),
            inference: { _, _ in
                MuesliQwen3Transcription(
                    text: "",
                    normalizedLexicalTokenConfidence: nil,
                    lexicalTokenCount: 0
                )
            }
        )
        let result = try await runner.run(wavURL: url, language: .english)
        #expect(result.text.isEmpty)
        #expect(result.windowCount == 1)
    }

    @Test("candidate scores use epsilon, then dominant language, then ISO code")
    func candidateTieBreak() throws {
        let candidates = [
            TranscriptionLanguageCandidate(language: .english, value: "English", normalizedScore: -0.25),
            TranscriptionLanguageCandidate(language: .arabic, value: "Arabic", normalizedScore: -0.25005),
        ]
        #expect(try TranscriptionLanguageCandidateSelector.select(
            candidates,
            expectedLanguages: [.arabic, .english],
            dominantLanguage: .arabic
        ).language == .arabic)
        #expect(try TranscriptionLanguageCandidateSelector.select(
            candidates,
            expectedLanguages: [.arabic, .english],
            dominantLanguage: nil
        ).language == .arabic)
    }

    private func temporaryWAV(samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-long-audio-\(UUID().uuidString).wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData![0].update(from: samples, count: samples.count)
        try file.write(from: buffer)
        return url
    }
}
