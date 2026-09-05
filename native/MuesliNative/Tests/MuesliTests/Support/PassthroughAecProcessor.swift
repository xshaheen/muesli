import Foundation
@testable import MuesliNativeApp

/// Frame-identity AEC processor. `MeetingNeuralAec(preloadedProcessor:)` makes
/// `preload()` a no-op with this installed, so tests get the real streaming
/// buffering and reference alignment without a CoreML model.
final class PassthroughAecProcessor: MeetingAecProcessor {
    let name: String
    let frameSize: Int
    let sampleRate = 16_000
    private(set) var processedFrameCount = 0
    private(set) var nonZeroReferenceFrameCount = 0
    private(set) var firstReferenceFrameFirstSample: Float?

    init(name: String = "test-passthrough", frameSize: Int) {
        self.name = name
        self.frameSize = frameSize
    }

    func reset() {
        processedFrameCount = 0
        nonZeroReferenceFrameCount = 0
        firstReferenceFrameFirstSample = nil
    }

    func processFrame(mic: [Float], reference: [Float]) throws -> [Float] {
        processedFrameCount += 1
        if firstReferenceFrameFirstSample == nil {
            firstReferenceFrameFirstSample = reference.first
        }
        if reference.contains(where: { abs($0) > 0.0001 }) {
            nonZeroReferenceFrameCount += 1
        }
        return mic
    }
}
