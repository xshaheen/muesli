import FluidAudio
import Foundation

/// Re-blocks an arbitrary-length sample feed into complete VAD frames.
///
/// The system audio callback delivers whatever buffer size the capture path
/// negotiated, while the reverse-leak gate decides per completed VAD frame.
/// This value type sits in front of `StreamingVadController.processAudio` so
/// the controller only ever sees whole frames and the pending remainder stays
/// with the next chunk (or is flushed at pause, stop, and interruption).
struct StreamingVadFrameAccumulator: Sendable {
    /// Frame length is always the VAD model's chunk size, never the mic or
    /// system capture buffer size.
    static let frameLength = VadManager.chunkSize

    private var pending: [Float] = []

    init() {
        pending.reserveCapacity(Self.frameLength)
    }

    var pendingSampleCount: Int { pending.count }

    /// Appends `samples` and returns every frame completed by the append, in
    /// arrival order. Samples that do not fill a frame stay pending.
    mutating func push(_ samples: [Float]) -> [[Float]] {
        guard !samples.isEmpty else { return [] }
        pending.append(contentsOf: samples)
        guard pending.count >= Self.frameLength else { return [] }

        let frameCount = pending.count / Self.frameLength
        var frames: [[Float]] = []
        frames.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            let start = index * Self.frameLength
            frames.append(Array(pending[start..<(start + Self.frameLength)]))
        }
        pending.removeFirst(frameCount * Self.frameLength)
        return frames
    }

    /// Returns the pending remainder (shorter than one frame) and empties the
    /// accumulator; `nil` when nothing is pending. The remainder must never be
    /// pushed to a VAD controller, which expects whole frames.
    mutating func flush() -> [Float]? {
        guard !pending.isEmpty else { return nil }
        let remainder = pending
        pending.removeAll(keepingCapacity: true)
        return remainder
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }
}
