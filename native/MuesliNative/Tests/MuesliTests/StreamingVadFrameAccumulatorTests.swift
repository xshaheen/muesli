import FluidAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("StreamingVadFrameAccumulator")
struct StreamingVadFrameAccumulatorTests {
    private let frameLength = VadManager.chunkSize

    @Test("frame length is the VAD chunk size, not the mic buffer size")
    func frameLengthMatchesVadChunkSize() {
        #expect(StreamingVadFrameAccumulator.frameLength == 4096)
        #expect(StreamingVadFrameAccumulator.frameLength == VadManager.chunkSize)
    }

    @Test("eight 512-sample pushes yield one frame after the eighth push")
    func eightSmallPushesYieldOneFrame() {
        var accumulator = StreamingVadFrameAccumulator()
        var emitted: [[Float]] = []
        for index in 0..<8 {
            let frames = accumulator.push(ramp(start: index * 512, count: 512))
            if index < 7 {
                #expect(frames.isEmpty, "push \(index + 1) must not complete a frame")
            }
            emitted.append(contentsOf: frames)
        }

        #expect(emitted.count == 1)
        #expect(emitted.first?.count == frameLength)
        #expect(emitted.first == ramp(start: 0, count: frameLength))
        #expect(accumulator.pendingSampleCount == 0)
    }

    @Test("a 6000-sample push yields one frame and keeps 1904 samples pending")
    func oversizedPushKeepsRemainderPending() {
        var accumulator = StreamingVadFrameAccumulator()
        let frames = accumulator.push(ramp(start: 0, count: 6000))

        #expect(frames.count == 1)
        #expect(frames.first == ramp(start: 0, count: frameLength))
        #expect(accumulator.pendingSampleCount == 1904)

        let remainder = accumulator.flush()
        #expect(remainder == ramp(start: frameLength, count: 1904))
    }

    @Test("a push spanning several frames returns every complete frame in order")
    func multiFramePushReturnsAllFrames() {
        var accumulator = StreamingVadFrameAccumulator()
        let frames = accumulator.push(ramp(start: 0, count: frameLength * 3 + 5))

        #expect(frames.count == 3)
        #expect(frames.flatMap { $0 } == ramp(start: 0, count: frameLength * 3))
        #expect(accumulator.pendingSampleCount == 5)
    }

    @Test("flush returns the pending remainder and empties the accumulator")
    func flushReturnsRemainderAndEmpties() {
        var accumulator = StreamingVadFrameAccumulator()
        #expect(accumulator.flush() == nil, "an empty accumulator flushes nothing")

        _ = accumulator.push(ramp(start: 0, count: 300))
        let remainder = accumulator.flush()

        #expect(remainder == ramp(start: 0, count: 300))
        #expect(accumulator.pendingSampleCount == 0)
        #expect(accumulator.flush() == nil)

        let frames = accumulator.push(ramp(start: 300, count: frameLength))
        #expect(frames.count == 1, "a flush must not leave stale samples in the next frame")
        #expect(frames.first == ramp(start: 300, count: frameLength))
    }

    @Test("reset drops pending samples without emitting them")
    func resetDropsPendingSamples() {
        var accumulator = StreamingVadFrameAccumulator()
        _ = accumulator.push(ramp(start: 0, count: 1000))
        accumulator.reset()

        #expect(accumulator.pendingSampleCount == 0)
        #expect(accumulator.flush() == nil)
    }

    @Test("empty pushes emit nothing and leave the pending count unchanged")
    func emptyPushIsIgnored() {
        var accumulator = StreamingVadFrameAccumulator()
        _ = accumulator.push(ramp(start: 0, count: 10))
        #expect(accumulator.push([]).isEmpty)
        #expect(accumulator.pendingSampleCount == 10)
    }

    @Test("ordering is preserved across mixed push sizes")
    func orderingIsPreservedAcrossMixedSizes() {
        var accumulator = StreamingVadFrameAccumulator()
        let sizes = [100, 512, 4000, 6000, 1, 4096, 8191, 37, 512, 512]
        var offset = 0
        var received: [Float] = []
        var frameCount = 0
        for size in sizes {
            let frames = accumulator.push(ramp(start: offset, count: size))
            for frame in frames {
                #expect(frame.count == frameLength)
                received.append(contentsOf: frame)
            }
            frameCount += frames.count
            offset += size
        }
        if let remainder = accumulator.flush() {
            received.append(contentsOf: remainder)
        }

        let total = sizes.reduce(0, +)
        #expect(frameCount == total / frameLength)
        #expect(received == ramp(start: 0, count: total))
        #expect(accumulator.pendingSampleCount == 0)
    }

    private func ramp(start: Int, count: Int) -> [Float] {
        (start..<(start + count)).map { Float($0) }
    }
}
