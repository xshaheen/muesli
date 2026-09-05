import FluidAudio
import Foundation
import Testing

@testable import MuesliNativeApp

@Suite("Meeting reverse leak mask planner")
struct MeetingReverseLeakMaskPlannerTests {
    private let minimumDuration: TimeInterval = 0.8
    private let sampleRate = 16_000

    private func interval(_ start: Double, _ end: Double) -> MeetingSuppressedInterval {
        MeetingSuppressedInterval(start: start, end: end)
    }

    private func segment(_ start: Double, _ end: Double) -> VadSegment {
        VadSegment(startTime: start, endTime: end)
    }

    @Test("a segment fully inside a suppressed interval is dropped")
    func fullyCoveredSegmentIsDropped() {
        let result = MeetingReverseLeakMaskPlanner.filterSegments(
            [segment(10, 14)],
            excluding: [interval(9, 15)],
            minimumDuration: minimumDuration
        )
        #expect(result.isEmpty)
    }

    @Test("a partially covered segment keeps its unsuppressed remainder")
    func partiallyCoveredSegmentKeepsRemainder() throws {
        // 10 s of speech whose first 3 s are leak: the tail must survive.
        let result = MeetingReverseLeakMaskPlanner.filterSegments(
            [segment(10, 20)],
            excluding: [interval(10, 13)],
            minimumDuration: minimumDuration,
            pad: 0
        )
        #expect(result.count == 1)
        let piece = try #require(result.first)
        #expect(abs(piece.startTime - 13) < 1e-6)
        #expect(abs(piece.endTime - 20) < 1e-6)
    }

    @Test("six seconds of leak followed by four seconds of remote speech keeps the remote part")
    func leakThenRemoteKeepsTheRemotePart() throws {
        let result = MeetingReverseLeakMaskPlanner.filterSegments(
            [segment(0, 10)],
            excluding: [interval(0, 6)],
            minimumDuration: minimumDuration,
            pad: 0
        )
        #expect(result.count == 1)
        let piece = try #require(result.first)
        #expect(abs(piece.startTime - 6) < 1e-6)
        #expect(abs(piece.duration - 4) < 1e-6)
    }

    @Test("an interval inside a segment splits it into two surviving pieces")
    func interiorIntervalSplitsSegment() {
        let result = MeetingReverseLeakMaskPlanner.filterSegments(
            [segment(0, 10)],
            excluding: [interval(4, 6)],
            minimumDuration: minimumDuration,
            pad: 0
        )
        #expect(result.count == 2)
        #expect(abs(result[0].endTime - 4) < 1e-6)
        #expect(abs(result[1].startTime - 6) < 1e-6)
    }

    @Test("pieces shorter than the health monitor minimum are dropped")
    func shortPiecesAreDropped() {
        // Only 0.4 s survives on each side, under the 0.8 s floor.
        let result = MeetingReverseLeakMaskPlanner.filterSegments(
            [segment(0, 5)],
            excluding: [interval(0.4, 4.6)],
            minimumDuration: minimumDuration,
            pad: 0
        )
        #expect(result.isEmpty)
    }

    @Test("a segment with no overlap is unchanged")
    func nonOverlappingSegmentIsUnchanged() throws {
        let result = MeetingReverseLeakMaskPlanner.filterSegments(
            [segment(20, 25)],
            excluding: [interval(0, 5)],
            minimumDuration: minimumDuration
        )
        #expect(result.count == 1)
        let piece = try #require(result.first)
        #expect(abs(piece.startTime - 20) < 1e-6)
        #expect(abs(piece.endTime - 25) < 1e-6)
    }

    @Test("an edge within the pad is treated as suppressed")
    func padCountsAsOverlap() throws {
        // The segment starts 50 ms after the interval ends, inside the 100 ms pad, so the
        // pad trims its head; the part beyond the pad survives.
        let result = MeetingReverseLeakMaskPlanner.filterSegments(
            [segment(5.05, 6.0)],
            excluding: [interval(1.0, 5.0)],
            minimumDuration: 0.5
        )
        #expect(result.count == 1)
        let piece = try #require(result.first)
        #expect(abs(piece.startTime - 5.1) < 1e-6)
        #expect(abs(piece.endTime - 6.0) < 1e-6)

        // A segment that lies entirely inside the pad disappears.
        let inside = MeetingReverseLeakMaskPlanner.filterSegments(
            [segment(5.0, 5.08)],
            excluding: [interval(1.0, 5.0)],
            minimumDuration: 0.01
        )
        #expect(inside.isEmpty)
    }

    @Test("empty intervals leave the segments untouched")
    func emptyIntervalsAreIdentity() {
        let segments = [segment(0, 3), segment(5, 9)]
        let result = MeetingReverseLeakMaskPlanner.filterSegments(
            segments,
            excluding: [],
            minimumDuration: minimumDuration
        )
        #expect(result.count == 2)
        #expect(abs(result[0].startTime - 0) < 1e-6)
        #expect(abs(result[1].endTime - 9) < 1e-6)
    }

    @Test("adjacent and overlapping intervals merge before subtraction")
    func adjacentIntervalsMerge() {
        // Two touching intervals must not leave a zero-length sliver between them.
        let result = MeetingReverseLeakMaskPlanner.filterSegments(
            [segment(0, 12)],
            excluding: [interval(2, 6), interval(6, 9)],
            minimumDuration: minimumDuration,
            pad: 0
        )
        #expect(result.count == 2)
        #expect(abs(result[0].endTime - 2) < 1e-6)
        #expect(abs(result[1].startTime - 9) < 1e-6)
    }

    @Test("suppressed speech seconds sum the overlap")
    func suppressedSpeechSecondsSumsOverlap() {
        let seconds = MeetingReverseLeakMaskPlanner.suppressedSpeechSeconds(
            [segment(0, 10), segment(20, 30)],
            intervals: [interval(4, 8), interval(25, 40)],
            pad: 0
        )
        // 4 s inside the first segment plus 5 s inside the second.
        #expect(abs(seconds - 9) < 1e-6)
    }

    @Test("masking floors the samples inside intervals and leaves the rest alone")
    func maskingFloorsOnlyTheInterval() {
        var samples = [Float](repeating: 0.5, count: 5 * 16_000)
        let original = samples
        MeetingReverseLeakMaskPlanner.maskSamples(
            &samples,
            intervals: [interval(1, 2)],
            sampleRate: sampleRate,
            pad: 0
        )
        #expect(samples.count == original.count)

        for index in 0..<16_000 {
            #expect(samples[index] == original[index])
        }
        for index in (2 * 16_000)..<samples.count {
            #expect(samples[index] == original[index])
        }
        for index in 16_000..<(2 * 16_000) {
            // -40 dB of the original plus comfort noise, and never a digital zero run.
            #expect(abs(samples[index]) < 0.02)
        }
        let maskedSlice = samples[16_000..<(2 * 16_000)]
        #expect(maskedSlice.contains { $0 != 0 })
    }

    @Test("masking with no intervals is an identity operation")
    func maskingWithoutIntervalsIsIdentity() {
        var samples: [Float] = [0.1, -0.2, 0.3, -0.4]
        let original = samples
        MeetingReverseLeakMaskPlanner.maskSamples(
            &samples,
            intervals: [],
            sampleRate: sampleRate
        )
        #expect(samples == original)
    }

    @Test("all offline speech inside intervals leaves nothing to evaluate")
    func allLeakMeetingFiltersToNothing() {
        // The success case of the feature: every system utterance was leak.
        let segments = (0..<10).map { index in
            segment(Double(index) * 3, Double(index) * 3 + 2)
        }
        let intervals = segments.map { interval($0.startTime - 0.2, $0.endTime + 0.2) }
        let result = MeetingReverseLeakMaskPlanner.filterSegments(
            segments,
            excluding: intervals,
            minimumDuration: minimumDuration
        )
        #expect(result.isEmpty)

        let health = MeetingTranscriptHealthMonitor.evaluate(
            existingSegments: [],
            offlineSpeechSegments: result,
            chunkHealth: MeetingTranscriptChunkHealthSnapshot(
                successfulChunkCount: 4,
                emptyChunkCount: 0,
                failedChunkCount: 0
            )
        )
        #expect(health.action == .accept)
    }

    @Test("a large interval and segment count filters quickly")
    func largeInputFiltersQuickly() {
        let intervals = (0..<20_000).map { index in
            interval(Double(index) * 0.5, Double(index) * 0.5 + 0.2)
        }
        let segments = (0..<1_000).map { index in
            segment(Double(index) * 10, Double(index) * 10 + 4)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let result = MeetingReverseLeakMaskPlanner.filterSegments(
            segments,
            excluding: intervals,
            minimumDuration: minimumDuration
        )
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        #expect(elapsedMs < 500, "filter took \(elapsedMs) ms")
        // Padded intervals every 0.5 s leave only 0.1 s gaps, all under the minimum, so a
        // densely suppressed meeting filters down to nothing rather than exploding into slivers.
        #expect(result.isEmpty)
    }
}
