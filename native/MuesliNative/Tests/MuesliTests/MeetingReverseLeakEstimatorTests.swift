import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingReverseLeakEstimator")
struct MeetingReverseLeakEstimatorTests {
    private let sampleRate = 16_000
    private let windowSamples = 8 * 16_000

    /// Irregular burst schedule (start ms, duration ms) so envelope autocorrelation has one clear peak.
    private let irregularSchedule: [(startMs: Int, durationMs: Int)] = [
        (200, 600), (1_100, 400), (1_900, 900), (3_200, 500),
        (4_000, 700), (5_100, 300), (5_700, 800), (6_800, 600),
    ]

    @Test("default envelope grid spans 80 ms to 2000 ms at 20 ms steps")
    func defaultEnvelopeGrid() {
        let grid = MeetingAecDelayEstimator.defaultEnvelopeCandidateLagFrames
        #expect(grid.count == 97)
        #expect(grid.first == 4)
        #expect(grid.last == 100)
        #expect(grid == Array(4...100))
        #expect(MeetingAecDelayEstimator.envelopeFrameDurationMs == 20)
        #expect(MeetingAecDelayEstimator.envelopeWindowFrames == 400)
        #expect(MeetingAecDelayEstimator.envelopeMinimumActiveReferenceFrames == 75)
    }

    @Test("forward grid and labels stay untouched")
    func forwardGridUnchanged() {
        let estimator = MeetingAecDelayEstimator()
        #expect(estimator.candidateDelaysMs == MeetingAecDelayEstimator.defaultCandidateDelaysMs)
        #expect(estimator.envelopeCandidateLagFrames == MeetingAecDelayEstimator.defaultEnvelopeCandidateLagFrames)
        #expect(estimator.windowSamples == 8 * 16_000)
        #expect(estimator.estimateIntervalSamples == 2 * 16_000)
    }

    @Test("envelope mode finds delayed -20 dB copies", arguments: [400, 900, 1_500])
    func envelopeModeFindsDelayedCopy(delayMs: Int) throws {
        let estimator = MeetingAecDelayEstimator()
        let reference = sineBursts(schedule: irregularSchedule)
        let nearEnd = delayed(reference, byMs: delayMs, gain: 0.1)

        let attempt = estimator.scoreEnvelopes(
            reference: envelope(of: reference),
            nearEnd: envelope(of: nearEnd),
            referenceMask: nil,
            activeThreshold: 0.01
        )

        guard case let .result(result) = attempt else {
            Issue.record("expected a result, got \(attempt)")
            return
        }
        #expect(result.delayMs == delayMs)
        #expect(result.delaySamples == delayMs * 16)
        #expect(result.score >= 0.8)
        #expect(result.peakRatio >= MeetingAecDelayEstimator.envelopeMinimumPeakRatio)
        #expect(result.activeReferenceFrames >= MeetingAecDelayEstimator.envelopeMinimumActiveReferenceFrames)
        #expect(result.comparedFrames > 0)
        #expect(result.candidateScores.count == MeetingAecDelayEstimator.defaultEnvelopeCandidateLagFrames.count)
        #expect(result.confidence > 0)
    }

    @Test("envelope mode rejects a window with under 1.5 s of active reference")
    func envelopeModeRejectsShortActiveReference() {
        let estimator = MeetingAecDelayEstimator()
        // One 1.2 s burst: 60 active frames, under the 75-frame floor.
        let reference = sineBursts(schedule: [(1_000, 1_200)])
        let nearEnd = delayed(reference, byMs: 500, gain: 0.1)

        let attempt = estimator.scoreEnvelopes(
            reference: envelope(of: reference),
            nearEnd: envelope(of: nearEnd),
            referenceMask: nil,
            activeThreshold: 0.01
        )

        guard case let .failure(failure) = attempt else {
            Issue.record("expected a failure, got \(attempt)")
            return
        }
        #expect(failure.reason == "insufficientActiveReference")
    }

    @Test("reference mask exclusions reduce the active reference count")
    func referenceMaskExcludesFrames() {
        let estimator = MeetingAecDelayEstimator()
        let reference = sineBursts(schedule: irregularSchedule)
        let nearEnd = delayed(reference, byMs: 500, gain: 0.1)
        let referenceEnvelope = envelope(of: reference)
        // Mask out everything after 2.0 s: 30 + 20 + 5 active frames remain, under the 75-frame floor
        // (the unmasked window carries about 240 active frames and locks at 500 ms).
        let mask = referenceEnvelope.indices.map { $0 < 100 }

        let attempt = estimator.scoreEnvelopes(
            reference: referenceEnvelope,
            nearEnd: envelope(of: nearEnd),
            referenceMask: mask,
            activeThreshold: 0.01
        )

        guard case let .failure(failure) = attempt else {
            Issue.record("expected a failure, got \(attempt)")
            return
        }
        #expect(failure.reason == "insufficientActiveReference")
    }

    @Test("peak ratio rejects a 250 ms periodic burst pattern")
    func peakRatioRejectsPeriodicPattern() {
        let estimator = MeetingAecDelayEstimator()
        let schedule = stride(from: 200, to: 7_800, by: 250).map { (startMs: $0, durationMs: 120) }
        let reference = sineBursts(schedule: schedule)
        let nearEnd = delayed(reference, byMs: 500, gain: 0.1)

        let attempt = estimator.scoreEnvelopes(
            reference: envelope(of: reference),
            nearEnd: envelope(of: nearEnd),
            referenceMask: nil,
            activeThreshold: 0.01
        )

        guard case let .failure(failure) = attempt else {
            Issue.record("expected a failure, got \(attempt)")
            return
        }
        #expect(failure.reason == "ambiguousPeak")
        #expect(failure.validCandidateCount == MeetingAecDelayEstimator.defaultEnvelopeCandidateLagFrames.count)
    }

    @Test("uncorrelated near end never reaches the peak threshold")
    func uncorrelatedNearEndIsRejected() {
        let estimator = MeetingAecDelayEstimator()
        let reference = sineBursts(schedule: irregularSchedule)
        // Genuine remote speech: bursts placed in the reference's silences, nothing shared.
        let remote = sineBursts(
            schedule: [(850, 200), (1_550, 300), (2_850, 300), (3_750, 200), (4_750, 300), (6_550, 200)],
            frequency: 620,
            amplitude: 0.2
        )

        let attempt = estimator.scoreEnvelopes(
            reference: envelope(of: reference),
            nearEnd: envelope(of: remote),
            referenceMask: nil,
            activeThreshold: 0.01
        )

        guard case let .failure(failure) = attempt else {
            Issue.record("expected a failure, got \(attempt)")
            return
        }
        #expect(["lowPeakCorrelation", "ambiguousPeak"].contains(failure.reason))
    }

    @Test("silent near end reports quiet audio")
    func silentNearEndIsQuiet() {
        let estimator = MeetingAecDelayEstimator()
        let reference = sineBursts(schedule: irregularSchedule)
        let silence = [Float](repeating: 0, count: reference.count)

        let attempt = estimator.scoreEnvelopes(
            reference: envelope(of: reference),
            nearEnd: envelope(of: silence),
            referenceMask: nil,
            activeThreshold: 0.01
        )

        guard case let .failure(failure) = attempt else {
            Issue.record("expected a failure, got \(attempt)")
            return
        }
        #expect(failure.reason == "quietNearEndAudio")
        #expect(failure.systemPeak == 0)
    }

    @Test("band-limit plus RMS yields the expected frame count and energy")
    func bandLimitAndRmsOnKnownSignal() {
        let seconds = 1
        let sampleCount = seconds * sampleRate
        let tone1k = (0..<sampleCount).map { index in
            Float(0.5 * sin(2.0 * .pi * 1_000.0 * Double(index) / Double(sampleRate)))
        }
        let tone50 = (0..<sampleCount).map { index in
            Float(0.5 * sin(2.0 * .pi * 50.0 * Double(index) / Double(sampleRate)))
        }

        let filter = MeetingAecEnvelopeHighPassFilter()
        let passedEnvelope = MeetingAecDelayEstimator.rmsEnvelope(of: filter.process(tone1k))
        filter.reset()
        let stoppedEnvelope = MeetingAecDelayEstimator.rmsEnvelope(of: filter.process(tone50))

        #expect(passedEnvelope.count == 50)
        #expect(stoppedEnvelope.count == 50)

        let expectedRms: Float = 0.5 / Float(2.0.squareRoot())
        // Skip the first frames so the biquad transient has settled.
        for value in passedEnvelope[10...] {
            #expect(abs(value - expectedRms) < expectedRms * 0.05)
        }
        for value in stoppedEnvelope[10...] {
            #expect(value < 0.05)
        }

        // Unfiltered RMS of the 1 kHz tone matches the analytic value per frame.
        let rawEnvelope = MeetingAecDelayEstimator.rmsEnvelope(of: tone1k)
        #expect(rawEnvelope.count == 50)
        for value in rawEnvelope {
            #expect(abs(value - expectedRms) < 0.01)
        }
    }

    @Test("RMS envelope drops a trailing partial frame")
    func rmsEnvelopeDropsPartialFrame() {
        let samples = [Float](repeating: 0.25, count: 320 * 3 + 100)
        let envelope = MeetingAecDelayEstimator.rmsEnvelope(of: samples)
        #expect(envelope.count == 3)
        for value in envelope {
            #expect(abs(value - 0.25) < 1e-5)
        }
    }

    @Test("streaming high-pass matches whole-buffer filtering across block boundaries")
    func streamingHighPassIsContinuous() {
        let sampleCount = 4_096 * 3
        let signal = (0..<sampleCount).map { index in
            Float(0.4 * sin(2.0 * .pi * 300.0 * Double(index) / Double(sampleRate)))
        }

        let whole = MeetingAecEnvelopeHighPassFilter().process(signal)
        let streamed = MeetingAecEnvelopeHighPassFilter()
        var pieces: [Float] = []
        for start in stride(from: 0, to: sampleCount, by: 4_096) {
            pieces += streamed.process(Array(signal[start..<min(start + 4_096, sampleCount)]))
        }

        #expect(pieces.count == whole.count)
        for (lhs, rhs) in zip(whole, pieces) {
            #expect(abs(lhs - rhs) < 1e-5)
        }
    }

    @Test("zero-mean helper centers the envelope")
    func zeroMeanCentersEnvelope() {
        let envelope: [Float] = [0.1, 0.2, 0.3, 0.4]
        let centered = MeetingAecDelayEstimator.zeroMeaned(envelope)
        #expect(centered.count == 4)
        #expect(abs(centered.reduce(0, +)) < 1e-6)
        #expect(abs(centered[0] + 0.15) < 1e-6)
        #expect(MeetingAecDelayEstimator.zeroMeaned([]).isEmpty)
    }

    @Test("forward result memberwise construction still omits the envelope fields")
    func forwardResultMemberwiseInitializer() {
        let result = MeetingAecDelayEstimator.Result(
            delaySamples: 3_840,
            delayMs: 240,
            score: 0.8,
            confidence: 0.01,
            comparedFrames: 100,
            candidateScores: []
        )
        #expect(result.activeReferenceFrames == 0)
        #expect(result.peakRatio == 0)
    }

    // MARK: - Signal helpers

    private func sineBursts(
        schedule: [(startMs: Int, durationMs: Int)],
        frequency: Double = 440,
        amplitude: Double = 0.3
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: windowSamples)
        for burst in schedule {
            let start = burst.startMs * sampleRate / 1_000
            let end = min(windowSamples, start + burst.durationMs * sampleRate / 1_000)
            guard start < end else { continue }
            for index in start..<end {
                samples[index] = Float(amplitude * sin(2.0 * .pi * frequency * Double(index) / Double(sampleRate)))
            }
        }
        return samples
    }

    private func delayed(_ samples: [Float], byMs delayMs: Int, gain: Float) -> [Float] {
        let delaySamples = delayMs * sampleRate / 1_000
        var output = [Float](repeating: 0, count: samples.count)
        for index in 0..<(samples.count - delaySamples) {
            output[index + delaySamples] = samples[index] * gain
        }
        return output
    }

    private func envelope(of samples: [Float]) -> [Float] {
        MeetingAecDelayEstimator.rmsEnvelope(of: MeetingAecEnvelopeHighPassFilter().process(samples))
    }
}
