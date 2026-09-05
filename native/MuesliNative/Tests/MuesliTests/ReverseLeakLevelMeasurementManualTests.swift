import FluidAudio
import Foundation
import Testing

@testable import MuesliNativeApp

/// Manual harness for the one measurement the synthetic corpus cannot make: what Silero
/// actually reports for gated audio.
///
/// The gate's floor depth was chosen from published residual-echo practice, not from this
/// codebase's own VAD. FluidAudio hands Silero raw amplitude with no normalization, and
/// Silero's behaviour on very quiet input is undocumented, so any depth shallower than the
/// shipped floor needs this measurement first.
///
/// Run it against a 16 kHz mono WAV of speech:
///
///     MUESLI_REVERSE_LEAK_MEASURE_WAV=/path/to/16k-mono.wav \
///       swift test --package-path native/MuesliNative \
///       --filter ReverseLeakLevelMeasurementManualTests
///
/// Constructing `VadManager` downloads the Silero model on first use if it is absent.
@Suite(
    "Reverse leak level measurement (manual)",
    .enabled(if: ProcessInfo.processInfo.environment["MUESLI_REVERSE_LEAK_MEASURE_WAV"] != nil)
)
struct ReverseLeakLevelMeasurementManualTests {
    @Test("gated audio stays below the Silero speech threshold")
    func gatedAudioIsBelowTheSpeechThreshold() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MUESLI_REVERSE_LEAK_MEASURE_WAV"])
        let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
        try #require(samples.count >= VadManager.chunkSize * 4, "need at least four VAD frames of audio")

        let vadManager = try await VadManager()
        let gains: [(label: String, gain: Float)] = [
            ("0 dB", 1.0),
            ("-20 dB", 0.1),
            ("-40 dB", MeetingReverseLeakMaskPlanner.maskGain),
        ]

        var probabilitiesByLabel: [String: [Float]] = [:]
        for (label, gain) in gains {
            var state = await vadManager.makeStreamState()
            var probabilities: [Float] = []
            for start in stride(from: 0, to: samples.count - VadManager.chunkSize, by: VadManager.chunkSize) {
                var frame = Array(samples[start..<(start + VadManager.chunkSize)]).map { $0 * gain }
                if gain == MeetingReverseLeakMaskPlanner.maskGain {
                    // The gate emits the floored signal mixed with comfort noise, so measure
                    // that, not bare attenuation: the noise is what keeps Whisper off a
                    // digital-zero run, and it is also what the VAD actually sees.
                    var noiseCarrier = [Float](repeating: 0, count: frame.count)
                    MeetingReverseLeakMaskPlanner.maskSamples(
                        &noiseCarrier,
                        intervals: [MeetingSuppressedInterval(start: 0, end: Double(frame.count) / 16_000)],
                        sampleRate: 16_000,
                        pad: 0
                    )
                    for index in frame.indices {
                        frame[index] += noiseCarrier[index]
                    }
                }
                let result = try await vadManager.processStreamingChunk(frame, state: state)
                state = result.state
                probabilities.append(result.probability)
            }
            probabilitiesByLabel[label] = probabilities
            let peak = probabilities.max() ?? 0
            let mean = probabilities.isEmpty ? 0 : probabilities.reduce(0, +) / Float(probabilities.count)
            print("[reverse-leak-measure] \(label): peak \(peak), mean \(mean), frames \(probabilities.count)")
        }

        let gatedPeak = probabilitiesByLabel["-40 dB"]?.max() ?? 0
        // Half the app's 0.85 speech threshold, so a gated span never reads as speech.
        #expect(gatedPeak <= 0.5, "gated audio peaked at \(gatedPeak)")
    }
}
