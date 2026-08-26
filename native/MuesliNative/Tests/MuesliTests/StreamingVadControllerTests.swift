import FluidAudio
import Foundation
import Testing
@testable import MuesliNativeApp

private actor StreamingVadTestProbe {
    private(set) var processedCount = 0
    private(set) var inFlightCount = 0
    private(set) var maxConcurrentCount = 0
    private(set) var boundaryCount = 0

    func processingStarted() {
        inFlightCount += 1
        maxConcurrentCount = max(maxConcurrentCount, inFlightCount)
    }

    func processingFinished() {
        inFlightCount = max(0, inFlightCount - 1)
        processedCount += 1
    }

    func boundaryTriggered() {
        boundaryCount += 1
    }
}

private final class StreamingVadBoundaryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var countStorage = 0

    var count: Int {
        lock.withLock { countStorage }
    }

    func boundaryTriggered() {
        lock.withLock {
            countStorage += 1
        }
    }
}

/// Holds streaming VAD inference open so a test can build a backlog on purpose.
private actor StreamingVadReleaseGate {
    private var isOpen = false

    func open() {
        isOpen = true
    }

    func waitUntilOpen() async {
        while !isOpen {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@Suite("StreamingVadController", .serialized)
struct StreamingVadControllerTests {
    @Test("serializes streaming VAD processing to a single in-flight chunk")
    func serializesChunkProcessing() async throws {
        let probe = StreamingVadTestProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { _, state in
                await probe.processingStarted()
                try? await Task.sleep(for: .milliseconds(25))
                await probe.processingFinished()
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )

        controller.start()
        // Exactly the queue cap: this test asserts serialization, not overflow
        // behavior — the cap's drop-oldest semantics have their own tests.
        for _ in 0..<StreamingVadController.maxPendingChunks {
            controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))
        }

        let deadline = ContinuousClock.now + .seconds(2)
        while await probe.processedCount < StreamingVadController.maxPendingChunks, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.stop()

        #expect(await probe.processedCount == StreamingVadController.maxPendingChunks)
        #expect(await probe.maxConcurrentCount == 1)
    }

    @Test("buffers chunks that arrive before stream state initialization completes")
    func buffersChunksBeforeStateReady() async throws {
        let probe = StreamingVadTestProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: {
                try? await Task.sleep(for: .milliseconds(120))
                return VadStreamState.initial()
            },
            processStreamChunk: { _, state in
                await probe.processingStarted()
                try? await Task.sleep(for: .milliseconds(10))
                await probe.processingFinished()
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )

        controller.start()
        for _ in 0..<3 {
            controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))
        }

        let deadline = ContinuousClock.now + .seconds(2)
        while await probe.processedCount < 3, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.stop()

        #expect(await probe.processedCount == 3)
        #expect(await probe.maxConcurrentCount == 1)
    }

    @Test("emits a chunk boundary when streaming VAD detects speech end")
    func emitsChunkBoundaryOnSpeechEnd() async throws {
        let probe = StreamingVadTestProbe()
        let boundaryProbe = StreamingVadBoundaryProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { _, state in
                await probe.processingStarted()
                await probe.processingFinished()
                return VadStreamResult(
                    state: state,
                    event: VadStreamEvent(kind: .speechEnd, sampleIndex: VadManager.chunkSize),
                    probability: 0.05
                )
            }
        )

        controller.onChunkBoundary = {
            boundaryProbe.boundaryTriggered()
        }

        controller.start()
        controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))

        // Generous deadline: the controller delivers through the main queue, which
        // @MainActor suites monopolize for seconds when the full run is parallel.
        let deadline = ContinuousClock.now + .seconds(15)
        while boundaryProbe.count < 1, ContinuousClock.now < deadline {
            // The controller deliberately delivers boundaries on the main queue.
            // Yield there so this non-main-actor test exercises that delivery.
            await MainActor.run {}
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.stop()

        #expect(boundaryProbe.count == 1)
    }

    @Test("ignores stale VAD results after stop and restart")
    func ignoresStaleResultsAfterRestart() async throws {
        let probe = StreamingVadTestProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { _, state in
                await probe.processingStarted()
                try? await Task.sleep(for: .milliseconds(120))
                await probe.processingFinished()
                return VadStreamResult(
                    state: state,
                    event: VadStreamEvent(kind: .speechEnd, sampleIndex: VadManager.chunkSize),
                    probability: 0.05
                )
            }
        )

        controller.onChunkBoundary = {
            Task { await probe.boundaryTriggered() }
        }

        controller.start()
        controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))

        let startedDeadline = ContinuousClock.now + .seconds(1)
        while await probe.inFlightCount == 0, ContinuousClock.now < startedDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        controller.stop()
        controller.start()

        let finishedDeadline = ContinuousClock.now + .seconds(2)
        while await probe.processedCount < 1, ContinuousClock.now < finishedDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.stop()

        #expect(await probe.processedCount == 1)
        #expect(await probe.boundaryCount == 0)
    }

    @Test("stale drainer does not clear restarted session queue")
    func staleDrainerDoesNotClearRestartedSessionQueue() async throws {
        let probe = StreamingVadTestProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { _, state in
                await probe.processingStarted()
                try? await Task.sleep(for: .milliseconds(120))
                await probe.processingFinished()
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )

        controller.start()
        controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))

        let startedDeadline = ContinuousClock.now + .seconds(1)
        while await probe.inFlightCount == 0, ContinuousClock.now < startedDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        controller.stop()
        controller.start()
        for _ in 0..<3 {
            controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))
        }

        let finishedDeadline = ContinuousClock.now + .seconds(2)
        while await probe.processedCount < 4, ContinuousClock.now < finishedDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.stop()

        #expect(await probe.processedCount == 4)
    }

    @Test("drops the oldest audio once the pending queue exceeds its cap")
    func dropsOldestChunksBeyondBacklogCap() async throws {
        let probe = StreamingVadTestProbe()
        let gate = StreamingVadReleaseGate()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { _, state in
                await probe.processingStarted()
                await gate.waitUntilOpen()
                await probe.processingFinished()
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )

        controller.start()
        // The first chunk parks inside inference, so everything fed after it piles
        // up in the pending queue exactly as it would behind a slow meeting.
        controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))
        let startedDeadline = ContinuousClock.now + .seconds(2)
        while await probe.inFlightCount == 0, ContinuousClock.now < startedDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let overflowCount = StreamingVadController.maxPendingChunks * 4
        for _ in 0..<overflowCount {
            controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))
        }
        await gate.open()

        let expected = StreamingVadController.maxPendingChunks + 1
        let finishedDeadline = ContinuousClock.now + .seconds(5)
        while await probe.processedCount < expected, ContinuousClock.now < finishedDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Settle time to catch an over-cap queue that is still draining.
        try? await Task.sleep(for: .milliseconds(100))
        controller.stop()

        #expect(await probe.processedCount == expected)
    }

    @Test("keeps every chunk when the backlog stays within the cap")
    func keepsChunksWithinBacklogCap() async throws {
        let probe = StreamingVadTestProbe()
        let gate = StreamingVadReleaseGate()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { _, state in
                await probe.processingStarted()
                await gate.waitUntilOpen()
                await probe.processingFinished()
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )

        controller.start()
        controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))
        let startedDeadline = ContinuousClock.now + .seconds(2)
        while await probe.inFlightCount == 0, ContinuousClock.now < startedDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        for _ in 0..<StreamingVadController.maxPendingChunks {
            controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))
        }
        await gate.open()

        let expected = StreamingVadController.maxPendingChunks + 1
        let finishedDeadline = ContinuousClock.now + .seconds(5)
        while await probe.processedCount < expected, ContinuousClock.now < finishedDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.stop()

        #expect(await probe.processedCount == expected)
    }
}
