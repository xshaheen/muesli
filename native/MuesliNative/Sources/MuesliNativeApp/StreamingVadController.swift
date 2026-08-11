import FluidAudio
import Foundation
import os

/// Bridges real-time meeting audio to VadManager's streaming API.
///
/// The key requirement here is single-flight state ownership: exactly one chunk
/// may be processed against the mutable stream state at a time. Chunks can
/// arrive faster than VAD inference finishes, so we queue them and drain
/// serially rather than spawning overlapping Tasks that race the same state.
final class StreamingVadController: @unchecked Sendable {
    /// Called when VAD detects a natural chunk boundary.
    /// Delivery is not main-thread guaranteed; handlers must dispatch before
    /// touching queue- or actor-isolated state.
    var onChunkBoundary: (() -> Void)?

    /// Backlog cap for undrained audio, in chunks (~256 ms each, so ~2 s).
    ///
    /// VAD inference can fall behind a live meeting indefinitely, and this queue
    /// only drives chunk-boundary rotation — the durable audio goes to the chunk
    /// recorders on a separate path. Stale samples would produce late boundaries
    /// anyway, and the max-duration timer still forces rotation, so dropping the
    /// oldest costs boundary precision rather than transcript content.
    static let maxPendingChunks = 8

    private struct State {
        var generation = 0
        var drainerEpoch = 0
        var isActive = false
        var isDraining = false
        var pendingChunks: [[Float]] = []
        var isDroppingChunks = false
        var streamState: VadStreamState?
        var lastRotationTime: Date?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let makeInitialState: @Sendable () async -> VadStreamState
    private let processStreamChunk: @Sendable ([Float], VadStreamState) async throws -> VadStreamResult
    private let logger = Logger(subsystem: "com.muesli.native", category: "StreamingVadController")

    /// Minimum chunk duration before allowing rotation (prevents rapid flipping).
    private let minChunkDuration: TimeInterval
    /// Maximum chunk duration before forcing rotation (safety cap).
    private let maxChunkDuration: TimeInterval
    private var maxDurationTimer: Timer?

    convenience init(vadManager: VadManager) {
        self.init(
            minChunkDuration: 3.0,
            // Keep live transcript latency bounded by forcing shorter meeting chunks.
            maxChunkDuration: 5.0,
            makeInitialState: { await vadManager.makeStreamState() },
            processStreamChunk: { samples, state in
                try await vadManager.processStreamingChunk(samples, state: state)
            }
        )
    }

    internal init(
        minChunkDuration: TimeInterval,
        maxChunkDuration: TimeInterval,
        makeInitialState: @escaping @Sendable () async -> VadStreamState,
        processStreamChunk: @escaping @Sendable ([Float], VadStreamState) async throws -> VadStreamResult
    ) {
        self.minChunkDuration = minChunkDuration
        self.maxChunkDuration = maxChunkDuration
        self.makeInitialState = makeInitialState
        self.processStreamChunk = processStreamChunk
    }

    func start() {
        let startGeneration = lock.withLock { state -> Int? in
            guard !state.isActive else { return nil }
            state.generation += 1
            state.isActive = true
            state.isDraining = false
            state.pendingChunks.removeAll(keepingCapacity: true)
            state.isDroppingChunks = false
            state.streamState = nil
            state.lastRotationTime = Date()
            return state.generation
        }
        guard let startGeneration else { return }

        Task { [weak self] in
            guard let self else { return }
            let initialState = await self.makeInitialState()
            let shouldKickDrain = self.lock.withLock { state in
                guard state.isActive, state.generation == startGeneration else { return false }
                state.streamState = initialState
                return !state.pendingChunks.isEmpty
            }
            if shouldKickDrain {
                self.startDrainIfNeeded()
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.maxDurationTimer?.invalidate()
            guard self.lock.withLock({ $0.isActive && $0.generation == startGeneration }) else { return }
            self.maxDurationTimer = Timer.scheduledTimer(withTimeInterval: self.maxChunkDuration, repeats: true) { [weak self] _ in
                self?.handleMaxDurationTimer()
            }
        }
    }

    func stop() {
        let stopGeneration = lock.withLock { state in
            state.isActive = false
            state.pendingChunks.removeAll(keepingCapacity: false)
            state.isDroppingChunks = false
            state.streamState = nil
            return state.generation
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.lock.withLock({ !$0.isActive && $0.generation == stopGeneration }) else { return }
            self.maxDurationTimer?.invalidate()
            self.maxDurationTimer = nil
        }
    }

    /// Feed a chunk of Float audio samples (typically 4096 samples = 256ms at 16kHz).
    func processAudio(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        let outcome = lock.withLock { state -> (shouldStart: Bool, droppedChunks: Int) in
            guard state.isActive else { return (false, 0) }
            state.pendingChunks.append(samples)
            var dropped = 0
            if state.pendingChunks.count > Self.maxPendingChunks {
                dropped = state.pendingChunks.count - Self.maxPendingChunks
                state.pendingChunks.removeFirst(dropped)
            }
            // One notice per burst: a backlog drops a chunk on every subsequent
            // append, and logging each one would bury the meeting's other output.
            let shouldLogDrop = dropped > 0 && !state.isDroppingChunks
            if dropped > 0 {
                state.isDroppingChunks = true
            }
            return (state.streamState != nil && !state.isDraining, shouldLogDrop ? dropped : 0)
        }

        if outcome.droppedChunks > 0 {
            logger.notice("VAD backlog exceeded \(Self.maxPendingChunks, privacy: .public) chunks; dropping oldest audio")
            fputs("[vad] backlog exceeded \(Self.maxPendingChunks) chunks, dropping oldest audio\n", stderr)
        }
        if outcome.shouldStart {
            startDrainIfNeeded()
        }
    }

    /// Notify that an external rotation just happened.
    func notifyRotation() {
        lock.withLock { state in
            state.lastRotationTime = Date()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.maxDurationTimer?.fireDate = Date().addingTimeInterval(self.maxChunkDuration)
        }
    }

    private func handleMaxDurationTimer() {
        let shouldRotate = lock.withLock { state in
            guard state.isActive else { return false }
            let now = Date()
            let elapsed = now.timeIntervalSince(state.lastRotationTime ?? now)
            guard elapsed >= self.minChunkDuration else { return false }
            state.lastRotationTime = now
            return true
        }
        guard shouldRotate else { return }
        fputs("[vad] max chunk duration reached, forcing rotation\n", stderr)
        DispatchQueue.main.async { [weak self] in
            self?.onChunkBoundary?()
        }
    }

    private func startDrainIfNeeded() {
        let drainerEpoch = lock.withLock { state -> Int? in
            guard state.isActive, state.streamState != nil, !state.isDraining else { return nil }
            guard !state.pendingChunks.isEmpty else { return nil }
            state.drainerEpoch += 1
            state.isDraining = true
            return state.drainerEpoch
        }
        guard let drainerEpoch else { return }

        Task { [weak self] in
            await self?.drainQueue(drainerEpoch: drainerEpoch)
        }
    }

    private func drainQueue(drainerEpoch: Int) async {
        while true {
            let next: (generation: Int, chunk: [Float], streamState: VadStreamState)? = lock.withLock { state in
                guard state.isActive, state.isDraining, state.drainerEpoch == drainerEpoch else {
                    if !state.isActive {
                        state.isDraining = false
                        state.pendingChunks.removeAll(keepingCapacity: false)
                    }
                    return nil
                }
                guard let streamState = state.streamState else {
                    state.isDraining = false
                    return nil
                }
                guard !state.pendingChunks.isEmpty else {
                    state.isDraining = false
                    state.isDroppingChunks = false
                    return nil
                }
                let chunk = state.pendingChunks.removeFirst()
                if state.pendingChunks.isEmpty {
                    // Caught up, so the next overflow is a new burst worth logging.
                    state.isDroppingChunks = false
                }
                return (state.generation, chunk, streamState)
            }

            guard let next else { return }

            do {
                let result = try await processStreamChunk(next.chunk, next.streamState)

                let shouldRotate = lock.withLock { state in
                    guard state.isActive, state.generation == next.generation else { return false }
                    state.streamState = result.state

                    guard let event = result.event, event.kind == .speechEnd else {
                        return false
                    }

                    let now = Date()
                    let elapsed = now.timeIntervalSince(state.lastRotationTime ?? now)
                    guard elapsed >= self.minChunkDuration else { return false }
                    state.lastRotationTime = now
                    return true
                }

                if shouldRotate {
                    fputs("[vad] speech end detected, rotating chunk\n", stderr)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.onChunkBoundary?()
                        self.maxDurationTimer?.fireDate = Date().addingTimeInterval(self.maxChunkDuration)
                    }
                }
            } catch {
                logger.error("streaming VAD chunk failed: \(String(describing: error), privacy: .public)")
                fputs("[vad] streaming chunk failed: \(error)\n", stderr)
            }
        }
    }
}
