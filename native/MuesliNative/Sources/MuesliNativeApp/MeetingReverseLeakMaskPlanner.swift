import FluidAudio
import Foundation

/// Keeps spans the reverse-leak gate suppressed out of the offline system-transcript
/// recovery paths.
///
/// The suppressor removes leaked local speech from the realtime system chunks, but the
/// offline pass reads the recorder's own raw file, where the leak is still present. Without
/// this the health monitor counts leaked speech as uncovered, which both re-inserts the
/// suppressed utterance through selective repair and can flip the decision to a full-file
/// fallback (KTD7, R10).
///
/// Intervals arrive in the system arrival frame, which is the raw file's own frame: both
/// recorders write each callback's samples contiguously before invoking the session, so a
/// file offset equals the cumulative sample count the funnel counted.
enum MeetingReverseLeakMaskPlanner {
    /// Widens each suppressed interval before it is subtracted, absorbing sub-callback
    /// jitter between the arrival counter and the file.
    static let overlapPadSeconds: TimeInterval = 0.1

    /// Gain applied inside a suppressed span; matches the realtime gate's floor.
    static let maskGain: Float = 0.01

    /// Comfort-noise amplitude floor, so a masked span never becomes a digital-zero run.
    static let comfortNoiseAmplitude: Float = 0.001

    /// Subtracts `intervals` (padded) from every segment and returns the surviving
    /// unsuppressed portions.
    ///
    /// A segment fully covered by suppressed audio disappears. A partially covered segment
    /// keeps each remaining piece as its own segment, so genuine remote speech that follows a
    /// leak inside one VAD segment stays eligible for repair. Pieces shorter than
    /// `minimumDuration` are dropped because the health monitor ignores them anyway.
    static func filterSegments(
        _ segments: [VadSegment],
        excluding intervals: [MeetingSuppressedInterval],
        minimumDuration: TimeInterval,
        pad: TimeInterval = overlapPadSeconds
    ) -> [VadSegment] {
        guard !intervals.isEmpty else { return segments }
        let padded = normalized(intervals, pad: pad)
        guard !padded.isEmpty else { return segments }

        var result: [VadSegment] = []
        var intervalIndex = 0
        // Both sides are sorted by start, so one forward sweep covers every pair.
        for segment in segments.sorted(by: { $0.startTime < $1.startTime }) {
            while intervalIndex < padded.count, padded[intervalIndex].end <= segment.startTime {
                intervalIndex += 1
            }
            var cursor = segment.startTime
            var probe = intervalIndex
            while probe < padded.count, padded[probe].start < segment.endTime {
                let interval = padded[probe]
                if interval.start > cursor {
                    appendPiece(from: cursor, to: min(interval.start, segment.endTime),
                                minimumDuration: minimumDuration, into: &result)
                }
                cursor = max(cursor, interval.end)
                if cursor >= segment.endTime { break }
                probe += 1
            }
            if cursor < segment.endTime {
                appendPiece(from: cursor, to: segment.endTime,
                            minimumDuration: minimumDuration, into: &result)
            }
        }
        return result
    }

    /// Total speech seconds that fell inside suppressed spans. Bounds the false-suppression
    /// rate in the field, where a rising value means the gate is eating real remote speech.
    static func suppressedSpeechSeconds(
        _ segments: [VadSegment],
        intervals: [MeetingSuppressedInterval],
        pad: TimeInterval = overlapPadSeconds
    ) -> Double {
        guard !intervals.isEmpty else { return 0 }
        let padded = normalized(intervals, pad: pad)
        return segments.reduce(0.0) { total, segment in
            total + padded.reduce(0.0) { inner, interval in
                inner + max(0, min(segment.endTime, interval.end) - max(segment.startTime, interval.start))
            }
        }
    }

    /// Replaces suppressed spans in `samples` with the gate's floor plus comfort noise,
    /// in place so a long meeting never holds a second full-length copy.
    static func maskSamples(
        _ samples: inout [Float],
        intervals: [MeetingSuppressedInterval],
        sampleRate: Int,
        pad: TimeInterval = overlapPadSeconds
    ) {
        guard !intervals.isEmpty, !samples.isEmpty else { return }
        var noiseState: UInt64 = 0x9E37_79B9_7F4A_7C15
        for interval in normalized(intervals, pad: pad) {
            let start = max(0, Int(interval.start * Double(sampleRate)))
            let end = min(samples.count, Int(interval.end * Double(sampleRate)))
            guard end > start else { continue }
            for index in start..<end {
                samples[index] = samples[index] * maskGain + noise(&noiseState)
            }
        }
    }

    static func writeTemporaryWAV(samples: [Float]) throws -> URL {
        try WavWriter.writeTemporaryWAV(samples: samples, directoryName: "muesli-meeting-system-mask")
    }

    // MARK: - Helpers

    private static func appendPiece(
        from start: TimeInterval,
        to end: TimeInterval,
        minimumDuration: TimeInterval,
        into result: inout [VadSegment]
    ) {
        guard end - start >= minimumDuration else { return }
        result.append(VadSegment(startTime: start, endTime: end))
    }

    /// Pads, sorts, and merges the intervals so the sweep sees one ordered, disjoint list.
    private static func normalized(
        _ intervals: [MeetingSuppressedInterval],
        pad: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        let sorted = intervals
            .map { (start: max(0, $0.start - pad), end: $0.end + pad) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var merged: [(start: TimeInterval, end: TimeInterval)] = []
        for interval in sorted {
            if var last = merged.last, interval.start <= last.end {
                last.end = max(last.end, interval.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    private static func noise(_ state: inout UInt64) -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        let unit = Float(z >> 40) / Float(1 << 24)
        return (unit * 2 - 1) * comfortNoiseAmplitude
    }
}
