import Foundation
import Testing
@testable import MuesliNativeApp

/// Drives the real `MeetingSession` realtime path with fake recorders and a
/// passthrough AEC, then inspects the rotated system chunk audio: the funnel,
/// the gate, the block accumulators and the lifecycle flushes are only correct
/// together (R18, KTD10).
@Suite("Meeting session reverse leak harness", .serialized)
struct MeetingSessionReverseLeakHarnessTests {
    private static let sampleRate = 16_000
    private static let blockLength = 4_096

    /// Local utterances with 1.8 s pauses: long enough for the estimator to
    /// find edges and for a genuine remote burst to sit clear of both the gate's
    /// hangover and its 0.75 s correlation window.
    private static let micSchedule: [(startMs: Int, durationMs: Int)] = [
        (400, 2_400), (4_600, 2_400), (8_800, 2_600), (13_200, 2_400),
        (17_400, 2_600), (21_800, 2_400), (26_000, 2_600),
    ]

    // MARK: - Pass-through parity

    @Test(
        "with suppression disabled the rotated system chunk is byte-identical to the capture",
        arguments: [4_096, 512]
    )
    func disabledSuppressionKeepsByteParity(micBufferLength: Int) async throws {
        let system = Self.int16(Self.speech(schedule: Self.micSchedule, seconds: 10, amplitude: 0.4, seed: 11))
        let mic = Self.int16(Self.speech(schedule: Self.micSchedule, seconds: 10, amplitude: 0.3, seed: 12))
        // Full-scale negatives only survive a float round trip when ungated
        // samples keep their original Int16 bytes.
        var systemWithExtremes = system
        for index in stride(from: 100, to: systemWithExtremes.count, by: 5_003) {
            systemWithExtremes[index] = Int16.min
        }

        let harness = try await Harness(reverseLeakEnabled: false)
        defer { harness.tearDown() }
        harness.drive(
            system: systemWithExtremes,
            mic: mic,
            micBufferLength: micBufferLength,
            micLagSamples: micBufferLength == 512 ? 512 : Self.blockLength
        )
        harness.finish()

        #expect(harness.chunkSamples() == systemWithExtremes)
        for chunk in harness.chunks {
            #expect(Int(chunk.timing.sampleCount) == chunk.samples.count)
        }
        let snapshot = harness.session.reverseLeakDiagnosticsSnapshot()
        #expect(!snapshot.enabled)
        #expect(snapshot.suppressedSeconds == 0)
        #expect(harness.session.suppressedSystemIntervals().isEmpty)
    }

    @Test("the processed-samples hook releases every sample in order within one block")
    func captionFeedParity() async throws {
        let system = Self.int16(Self.speech(schedule: Self.micSchedule, seconds: 8, amplitude: 0.4, seed: 13))
        let harness = try await Harness(reverseLeakEnabled: false)
        defer { harness.tearDown() }
        harness.drive(system: system, mic: [], micBufferLength: 4_096, micLagSamples: 0, systemBufferLength: 1_500)
        harness.drain()
        // Everything but the trailing partial block is released before the flush.
        let releasedBeforeFlush = harness.processedSampleCount
        #expect(system.count - releasedBeforeFlush < Self.blockLength)
        harness.finish()

        #expect(harness.processedSampleCount == system.count)
        let released = harness.processedSamples
        for index in released.indices {
            #expect(abs(released[index] - Float(system[index]) / 32767.0) < 1e-6)
        }
    }

    // MARK: - Gating through the real enqueue path

    @Test("a 700 ms leak is gated in both mic buffer shapes", arguments: [4_096, 512])
    func leakIsGatedForBothMicShapes(micBufferLength: Int) async throws {
        let result = try await Self.runLeak(
            delayMs: 700,
            micBufferLength: micBufferLength,
            micLagSamples: micBufferLength == 512 ? 512 : Self.blockLength
        )
        #expect(result.lockedDelayMs != nil)
        #expect(abs((result.lockedDelayMs ?? 0) - 700) <= 40)
        #expect(result.leakedFrames > 100)
        #expect(
            result.gatedFraction >= 0.9,
            "gated \(result.gatedFrames) of \(result.leakedFrames) leaked frames"
        )
        #expect(result.remoteGatedFrames == 0, "genuine remote speech must pass through")
        #expect(result.snapshot.suppressedSeconds > 3)
        #expect(result.snapshot.intervalCount > 0)
        #expect(result.intervals.allSatisfy { $0.end <= Double(result.systemSampleCount) / 16_000 + 0.05 })
    }

    @Test("a leak shorter than the 4096-sample mic lookahead counts missing reference")
    func shortDelayOnLargeMicBuffersCountsMissingReference() async throws {
        // The cleaned mic for a position arrives 256 ms after the system audio
        // for it, so a delay under 256 ms leaves the later frames of a block
        // without a reference and the gate fails open there (A1, R2).
        let result = try await Self.runLeak(
            delayMs: 150,
            micBufferLength: 4_096,
            micLagSamples: Self.blockLength
        )
        #expect(result.lockedDelayMs != nil)
        #expect(result.snapshot.referenceUnavailableFrames > 0)
        #expect(result.remoteGatedFrames == 0)
    }

    @Test("a 300 ms leak is gated on the 512-sample mic route")
    func shortDelayOnSmallMicBuffersIsGated() async throws {
        let result = try await Self.runLeak(
            delayMs: 300,
            micBufferLength: 512,
            micLagSamples: 512
        )
        #expect(result.lockedDelayMs != nil)
        #expect(result.leakedFrames > 100)
        #expect(
            result.gatedFraction >= 0.9,
            "gated \(result.gatedFrames) of \(result.leakedFrames) leaked frames"
        )
        #expect(result.remoteGatedFrames == 0)
    }

    @Test("a stalled mic feed keeps the reference aligned and gating resumes")
    func lateMicCallbacksKeepGating() async throws {
        let result = try await Self.runLeak(
            delayMs: 700,
            micBufferLength: 512,
            micLagSamples: 512,
            micStallBlocks: 6
        )
        #expect(result.lockedDelayMs != nil)
        #expect(
            result.gatedFraction >= 0.9,
            "gated \(result.gatedFrames) of \(result.leakedFrames) leaked frames"
        )
        #expect(result.remoteGatedFrames == 0)
    }

    @Test("without any mic callbacks the system stream passes through unchanged")
    func noMicCallbacksNeverGates() async throws {
        let system = Self.int16(Self.speech(schedule: Self.micSchedule, seconds: 12, amplitude: 0.4, seed: 17))
        let harness = try await Harness(reverseLeakEnabled: true)
        defer { harness.tearDown() }
        harness.drive(system: system, mic: [], micBufferLength: 4_096, micLagSamples: 0)
        harness.finish()

        #expect(harness.chunkSamples() == system)
        let snapshot = harness.session.reverseLeakDiagnosticsSnapshot()
        #expect(snapshot.enabled)
        #expect(snapshot.lockedDelayMs == nil)
        #expect(snapshot.suppressedSeconds == 0)
        #expect(snapshot.gateOpenCount == 0)
    }

    @Test("MUESLI_REVERSE_LEAK_SUPPRESSION=0 disables the gate for the whole meeting")
    func environmentOverrideDisablesTheGate() async throws {
        let streams = Self.leakStreams(delayMs: 700, seconds: 20)
        setenv(MeetingReverseLeakSuppressor.environmentKey, "0", 1)
        let harness: Harness
        do {
            harness = try await Harness(reverseLeakEnabled: true)
        } catch {
            unsetenv(MeetingReverseLeakSuppressor.environmentKey)
            throw error
        }
        unsetenv(MeetingReverseLeakSuppressor.environmentKey)
        defer { harness.tearDown() }

        harness.drive(
            system: streams.system,
            mic: streams.mic,
            micBufferLength: 512,
            micLagSamples: 512
        )
        harness.finish()

        let snapshot = harness.session.reverseLeakDiagnosticsSnapshot()
        #expect(!snapshot.enabled)
        #expect(snapshot.suppressedSeconds == 0)
        #expect(harness.chunkSamples() == streams.system)
    }

    // MARK: - Chunk boundaries and lifecycle

    @Test("a rotation inside a leaked span keeps the pending remainder for the next chunk")
    func rotationMidSpanKeepsTheRemainder() async throws {
        let streams = Self.leakStreams(delayMs: 700, seconds: 26)
        let harness = try await Harness(reverseLeakEnabled: true)
        defer { harness.tearDown() }
        harness.drive(
            system: streams.system,
            mic: streams.mic,
            micBufferLength: 512,
            micLagSamples: 512,
            systemBufferLength: 1_500,
            rotateAfterSystemSample: 20 * Self.sampleRate
        )
        harness.finish()

        #expect(harness.chunks.count >= 2)
        let first = try #require(harness.chunks.first)
        // VAD-driven rotation happens at block edges only (KTD5).
        #expect(first.samples.count % Self.blockLength == 0)
        #expect(harness.chunkSamples().count == streams.system.count)
        let gated = Self.gatedFrames(
            input: streams.system,
            output: harness.chunkSamples(),
            from: 13 * Self.sampleRate,
            excluding: streams.remoteOnly
        )
        #expect(gated.fraction >= 0.9, "gated \(gated.gated) of \(gated.leaked) leaked frames")
    }

    @Test("a capture interruption flushes the pending remainder into the interrupted chunk")
    func interruptionFlushesTheRemainder() async throws {
        let system = Self.int16(Self.speech(schedule: Self.micSchedule, seconds: 10, amplitude: 0.4, seed: 21))
        let harness = try await Harness(reverseLeakEnabled: true)
        defer { harness.tearDown() }
        let interruptAfter = 5 * Self.sampleRate
        harness.drive(
            system: system,
            mic: [],
            micBufferLength: 4_096,
            micLagSamples: 0,
            systemBufferLength: 1_500,
            interruptAfterSystemSample: interruptAfter
        )
        harness.finish()

        #expect(harness.chunks.count >= 2)
        let first = try #require(harness.chunks.first)
        let deliveredBeforeInterruption = Self.deliveredCount(
            total: system.count,
            bufferLength: 1_500,
            atLeast: interruptAfter
        )
        #expect(first.samples.count == deliveredBeforeInterruption)
        #expect(first.samples.count % Self.blockLength != 0, "the remainder must be part of the flush")
        #expect(Int(first.timing.sampleCount) == first.samples.count)
        #expect(harness.chunkSamples() == system)
    }

    @Test("the pending block at stop reaches the final chunk")
    func partialBlockAtStopIsFlushed() async throws {
        let system = Self.int16(Self.speech(schedule: Self.micSchedule, seconds: 6, amplitude: 0.4, seed: 23))
        let harness = try await Harness(reverseLeakEnabled: true)
        defer { harness.tearDown() }
        harness.drive(system: system, mic: [], micBufferLength: 4_096, micLagSamples: 0, systemBufferLength: 1_500)
        // Barrier first: without it the queue may simply not have run yet, so an empty
        // chunk list would prove nothing about rotation.
        harness.drain()
        #expect(harness.chunks.isEmpty)
        harness.finish()

        #expect(harness.chunks.count == 1)
        let final = try #require(harness.chunks.first)
        #expect(final.samples == system)
        #expect(Int(final.timing.sampleCount) == system.count)
    }

    @Test("pause clears the lock and keeps the intervals already exported")
    func pauseResetsTheLockAndKeepsIntervals() async throws {
        let streams = Self.leakStreams(delayMs: 700, seconds: 26)
        let harness = try await Harness(reverseLeakEnabled: true)
        defer { harness.tearDown() }
        harness.drive(
            system: streams.system,
            mic: streams.mic,
            micBufferLength: 512,
            micLagSamples: 512
        )
        let before = harness.session.reverseLeakDiagnosticsSnapshot()
        #expect(before.lockedDelayMs != nil)
        let intervalsBefore = harness.session.suppressedSystemIntervals()
        #expect(!intervalsBefore.isEmpty)

        harness.session.pause()
        harness.session.resume()

        let after = harness.session.reverseLeakDiagnosticsSnapshot()
        #expect(after.resetCount == before.resetCount + 1)
        #expect(after.lockedDelayMs == nil)
        let intervalsAfter = harness.session.suppressedSystemIntervals()
        #expect(intervalsAfter.count == intervalsBefore.count)
        #expect(intervalsAfter.dropLast() == intervalsBefore.dropLast())
        // The pause flush gates the remainder, so the open span can only grow.
        #expect((intervalsAfter.last?.end ?? 0) >= (intervalsBefore.last?.end ?? 0))

        // Nothing is gated again until a fresh lock forms.
        let resumeStart = harness.deliveredSystemSamples
        harness.drive(
            system: streams.system,
            mic: streams.mic,
            micBufferLength: 512,
            micLagSamples: 512
        )
        harness.finish()
        let all = harness.chunkSamples()
        let firstBlockAfterResume = Array(all[resumeStart..<min(all.count, resumeStart + 4 * Self.sampleRate)])
        let expected = Array(streams.system[0..<firstBlockAfterResume.count])
        #expect(firstBlockAfterResume == expected, "suppression must not resume before a new lock")
        #expect(harness.session.reverseLeakDiagnosticsSnapshot().lockedDelayMs != nil)
    }

    @Test("callbacks delivered while paused still advance the arrival counter")
    func pausedCallbacksKeepTheArrivalCounterEqualToTheRawFile() async throws {
        let system = Self.int16(Self.speech(schedule: Self.micSchedule, seconds: 4, amplitude: 0.4, seed: 27))
        let harness = try await Harness(reverseLeakEnabled: true)
        defer { harness.tearDown() }

        var deliveredWhilePaused = 0
        for _ in 0..<3 {
            harness.drive(system: system, mic: [], micBufferLength: 4_096, micLagSamples: 0)
            harness.session.pause()
            // The recorder writes to the raw file before the session's guard drops these.
            harness.systemRecorder.deliver(Array(system.prefix(4_096)))
            deliveredWhilePaused += 4_096
            harness.session.resume()
        }
        harness.finish()

        let rawFileSamples = 3 * system.count + deliveredWhilePaused
        #expect(harness.session.systemArrivalSampleCountForTesting == rawFileSamples)
    }

    @Test("a mic handoff that switched input clears the lock")
    func micHandoffResetsTheLock() async throws {
        let streams = Self.leakStreams(delayMs: 700, seconds: 26)
        let harness = try await Harness(reverseLeakEnabled: true)
        defer { harness.tearDown() }
        harness.drive(
            system: streams.system,
            mic: streams.mic,
            micBufferLength: 512,
            micLagSamples: 512
        )
        let before = harness.session.reverseLeakDiagnosticsSnapshot()
        #expect(before.lockedDelayMs != nil)

        harness.session.applyMicHandoffResultForTesting(
            record: MeetingMicFailoverRecord(
                silentDeviceID: 41,
                silentDeviceName: "Silent input",
                fallbackDeviceID: 42,
                fallbackDeviceName: "Fallback input",
                decidedAt: Date()
            ),
            result: .completed(preferredInputDeviceID: 42)
        )

        let after = harness.session.reverseLeakDiagnosticsSnapshot()
        #expect(after.resetCount == before.resetCount + 1)
        #expect(after.lockedDelayMs == nil)
        #expect(harness.session.suppressedSystemIntervals().count == before.intervalCount)
    }

    @Test("a late system callback exports its interval in the raw file's frame")
    func lateSystemCallbackKeepsIntervalsInTheArrivalFrame() async throws {
        let streams = Self.leakStreams(delayMs: 700, seconds: 30)
        let harness = try await Harness(reverseLeakEnabled: true)
        defer { harness.tearDown() }
        harness.drive(
            system: streams.system,
            mic: streams.mic,
            micBufferLength: 512,
            micLagSamples: 512,
            systemBufferLength: 1_500,
            // A forward timeline gap: the raw file stays contiguous, the
            // timeline does not (AE9).
            stallBeforeSystemSample: 18 * Self.sampleRate,
            stallSeconds: 0.5
        )
        harness.finish()

        let intervals = harness.session.suppressedSystemIntervals()
        #expect(!intervals.isEmpty)
        let fileSeconds = Double(streams.system.count) / Double(Self.sampleRate)
        let lastEnd = try #require(intervals.last?.end)
        #expect(lastEnd <= fileSeconds + 0.05, "intervals must stay inside the raw file")

        // The discriminating assertion. The last mic utterance runs 26.0-28.6 s, so its leak
        // sits at 26.7-29.3 s in the raw file; the gate's hangover adds at most 200 ms. The
        // 0.5 s stall injected at 18 s pushes the recording timeline about 0.4 s ahead of the
        // file for everything after it, so an interval exported in the timeline frame would
        // land near 29.8 s. Anything inside this window can only have come from the arrival
        // frame (AE9, KTD7).
        let lastLeak = Self.micSchedule[Self.micSchedule.count - 1]
        let expectedEnd = Double(lastLeak.startMs + lastLeak.durationMs + 700) / 1_000
        #expect(
            lastEnd >= expectedEnd - 0.25 && lastEnd <= expectedEnd + 0.3,
            "last interval ended at \(lastEnd); the raw-file position is \(expectedEnd) and a timeline-framed export would be about 0.4 s later"
        )
    }

    // MARK: - Leak scenario driver

    private struct LeakResult {
        let snapshot: MeetingReverseLeakDiagnosticsSnapshot
        let lockedDelayMs: Int?
        let intervals: [MeetingSuppressedInterval]
        let leakedFrames: Int
        let gatedFrames: Int
        let remoteGatedFrames: Int
        let systemSampleCount: Int

        var gatedFraction: Double {
            leakedFrames > 0 ? Double(gatedFrames) / Double(leakedFrames) : 0
        }
    }

    private static func runLeak(
        delayMs: Int,
        micBufferLength: Int,
        micLagSamples: Int,
        micStallBlocks: Int = 0
    ) async throws -> LeakResult {
        let streams = leakStreams(delayMs: delayMs, seconds: 30)
        let harness = try await Harness(reverseLeakEnabled: true)
        defer { harness.tearDown() }
        harness.drive(
            system: streams.system,
            mic: streams.mic,
            micBufferLength: micBufferLength,
            micLagSamples: micLagSamples,
            micStallBlocks: micStallBlocks
        )
        harness.finish()

        let output = harness.chunkSamples()
        let measureFrom = 13 * sampleRate
        let leaked = gatedFrames(
            input: streams.system,
            output: output,
            from: measureFrom,
            excluding: streams.remoteOnly
        )
        let remote = gatedFrames(input: streams.remoteOnly, output: output, from: 0)
        return LeakResult(
            snapshot: harness.session.reverseLeakDiagnosticsSnapshot(),
            lockedDelayMs: harness.session.reverseLeakDiagnosticsSnapshot().lockedDelayMs,
            intervals: harness.session.suppressedSystemIntervals(),
            leakedFrames: leaked.leaked,
            gatedFrames: leaked.gated,
            remoteGatedFrames: remote.gated,
            systemSampleCount: streams.system.count
        )
    }

    // MARK: - Harness

    private final class Harness {
        struct Chunk {
            let samples: [Int16]
            let timing: MeetingChunkTimingSnapshot
        }

        let session: MeetingSession
        let micRecorder = FakeMeetingMicRecorder(kind: .appScopedAudioQueue)
        let systemRecorder = FakeSystemAudioRecorder()
        private(set) var chunks: [Chunk] = []
        private(set) var processedSamples: [Float] = []
        private(set) var deliveredSystemSamples = 0

        var processedSampleCount: Int { processedSamples.count }

        init(reverseLeakEnabled: Bool) async throws {
            var config = AppConfig()
            config.meetingReverseLeakSuppression = reverseLeakEnabled
            config.meetingRecordingSavePolicy = .never
            session = MeetingSession(
                title: "Reverse leak harness",
                calendarEventID: nil,
                backend: .whisper,
                runtime: RuntimePaths(
                    repoRoot: FileManager.default.temporaryDirectory,
                    menuIcon: nil,
                    appIcon: nil,
                    bundlePath: nil
                ),
                config: config,
                templateSnapshot: MeetingTemplates.auto.snapshot,
                transcriptionCoordinator: TranscriptionCoordinator(),
                meetingMicRecorder: micRecorder,
                systemAudioRecorder: systemRecorder,
                neuralAec: MeetingNeuralAec(
                    preloadedProcessor: PassthroughAecProcessor(name: "localvqe", frameSize: 256)
                )
            )
            session.onSystemChunkRotated = { [weak self] url, timing in
                guard let data = try? Data(contentsOf: url), data.count > 44 else { return }
                let payload = Data(data[44...])
                let samples = payload.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                self?.chunks.append(Chunk(samples: samples, timing: timing))
            }
            session.onProcessedSystemSamples = { [weak self] samples in
                self?.processedSamples.append(contentsOf: samples)
            }
            try await session.start()
        }

        func chunkSamples() -> [Int16] {
            chunks.flatMap(\.samples)
        }

        /// Interleaves the two capture callbacks the way the recorders do: mic
        /// audio for a position arrives `micLagSamples` after the system audio
        /// covering the same position.
        func drive(
            system: [Int16],
            mic: [Int16],
            micBufferLength: Int,
            micLagSamples: Int,
            systemBufferLength: Int = 4_096,
            rotateAfterSystemSample: Int? = nil,
            interruptAfterSystemSample: Int? = nil,
            stallBeforeSystemSample: Int? = nil,
            stallSeconds: TimeInterval = 0,
            micStallBlocks: Int = 0
        ) {
            var micDelivered = 0
            var systemDelivered = 0
            var didRotate = rotateAfterSystemSample == nil
            var didInterrupt = interruptAfterSystemSample == nil
            var didStall = stallBeforeSystemSample == nil
            let stallRange = micStallBlocks > 0
                ? (system.count / 3)..<(system.count / 3 + micStallBlocks * systemBufferLength)
                : 0..<0

            while systemDelivered < system.count {
                let count = min(systemBufferLength, system.count - systemDelivered)
                let systemEnd = systemDelivered + count
                if let stallBefore = stallBeforeSystemSample, !didStall, systemEnd > stallBefore {
                    Thread.sleep(forTimeInterval: stallSeconds)
                    didStall = true
                }
                let micTarget = stallRange.contains(systemDelivered)
                    ? max(0, stallRange.lowerBound - micLagSamples)
                    : max(0, min(mic.count, systemEnd - micLagSamples))
                while micDelivered + micBufferLength <= micTarget {
                    micRecorder.onRawPCMSamples?(Array(mic[micDelivered..<(micDelivered + micBufferLength)]))
                    micDelivered += micBufferLength
                }
                systemRecorder.deliver(Array(system[systemDelivered..<systemEnd]))
                systemDelivered = systemEnd
                deliveredSystemSamples += count
                if let rotateAfter = rotateAfterSystemSample, !didRotate, systemDelivered >= rotateAfter {
                    session.rotateSystemChunk()
                    didRotate = true
                }
                if let interruptAfter = interruptAfterSystemSample, !didInterrupt, systemDelivered >= interruptAfter {
                    systemRecorder.onSystemAudioInterruption?()
                    didInterrupt = true
                }
            }
            while micDelivered + micBufferLength <= mic.count {
                micRecorder.onRawPCMSamples?(Array(mic[micDelivered..<(micDelivered + micBufferLength)]))
                micDelivered += micBufferLength
            }
        }

        /// Barrier for the serial chunk queue: every callback dispatched before
        /// this call has been processed when it returns.
        func drain() {
            _ = session.systemArrivalSampleCountForTesting
        }

        func finish() {
            session.finishRealtimeCapture()
        }

        func tearDown() {
            session.discard()
        }
    }

    // MARK: - Analysis

    private static func deliveredCount(total: Int, bufferLength: Int, atLeast: Int) -> Int {
        var delivered = 0
        while delivered < total {
            delivered += min(bufferLength, total - delivered)
            if delivered >= atLeast { break }
        }
        return delivered
    }

    /// Per-20 ms-frame gate detection from the audio itself: an active input
    /// frame is gated when the output keeps under half of it.
    private static func gatedFrames(
        input: [Int16],
        output: [Int16],
        from start: Int,
        excluding excluded: [Int16]? = nil
    ) -> (leaked: Int, gated: Int, fraction: Double) {
        let frameLength = 320
        var leaked = 0
        var gated = 0
        var cursor = (start + frameLength - 1) / frameLength * frameLength
        while cursor + frameLength <= min(input.count, output.count) {
            let inputFrame = Array(input[cursor..<(cursor + frameLength)]).map { Float($0) / 32767.0 }
            if let excluded, cursor + frameLength <= excluded.count {
                let excludedFrame = Array(excluded[cursor..<(cursor + frameLength)]).map { Float($0) / 32767.0 }
                if rms(excludedFrame) > 0.0005 {
                    cursor += frameLength
                    continue
                }
            }
            guard rms(inputFrame) > 0.003 else {
                cursor += frameLength
                continue
            }
            leaked += 1
            let outputFrame = Array(output[cursor..<(cursor + frameLength)]).map { Float($0) / 32767.0 }
            if projectionGain(input: inputFrame, output: outputFrame) < 0.5 {
                gated += 1
            }
            cursor += frameLength
        }
        return (leaked, gated, leaked > 0 ? Double(gated) / Double(leaked) : 0)
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    private static func projectionGain(input: [Float], output: [Float]) -> Float {
        var dot: Float = 0
        var energy: Float = 0
        for index in input.indices {
            dot += input[index] * output[index]
            energy += input[index] * input[index]
        }
        return energy > 0 ? dot / energy : 1
    }

    // MARK: - Synthetic streams

    private struct LeakStreams {
        let mic: [Int16]
        let system: [Int16]
        /// The genuine remote bursts alone, for the "never suppressed" check.
        let remoteOnly: [Int16]
    }

    /// Local speech plus its delayed -20 dB echo on the system track, with
    /// genuine remote bursts in the local speaker's gaps.
    private static func leakStreams(delayMs: Int, seconds: Int) -> LeakStreams {
        let total = seconds * sampleRate
        let mic = speech(schedule: micSchedule, seconds: seconds, amplitude: 0.3, seed: 31)
        var system = delayed(mic, byMs: delayMs, gain: 0.1)
        // Genuine remote bursts go in the leak's own gaps, clear of the gate's
        // 200 ms hangover: a burst that overlaps the leak is double-talk, which
        // the gate deliberately passes (AE3) and U2 covers directly.
        var remoteSchedule: [(startMs: Int, durationMs: Int)] = []
        let leakSpans = micSchedule.map {
            (start: $0.startMs + delayMs, end: $0.startMs + $0.durationMs + delayMs)
        }
        for index in 0..<(leakSpans.count - 1) {
            let burstStart = leakSpans[index].end + 400
            // 200 ms of remote plus the 750 ms correlation window must clear the
            // next leak span, or the control burst itself delays the gate.
            guard leakSpans[index + 1].start - burstStart >= 200 + 750 else { continue }
            remoteSchedule.append((startMs: burstStart, durationMs: 200))
        }
        let remote = speech(schedule: remoteSchedule, seconds: seconds, amplitude: 0.05, seed: 33)
        for index in 0..<total {
            system[index] += remote[index]
        }
        return LeakStreams(mic: int16(mic), system: int16(system), remoteOnly: int16(remote))
    }

    private static func int16(_ samples: [Float]) -> [Int16] {
        samples.map { Int16(max(-1.0, min(1.0, $0)) * 32767) }
    }

    private static func speech(
        schedule: [(startMs: Int, durationMs: Int)],
        seconds: Int,
        amplitude: Double,
        seed: UInt64
    ) -> [Float] {
        let totalSamples = seconds * sampleRate
        var samples = [Float](repeating: 0, count: totalSamples)
        var rng = SplitMix64(seed: seed)
        for burst in schedule {
            let burstStart = burst.startMs * sampleRate / 1_000
            guard burstStart < totalSamples else { continue }
            let burstEnd = min(totalSamples, burstStart + burst.durationMs * sampleRate / 1_000)
            var cursor = burstStart
            while cursor < burstEnd {
                let syllable = Int(rng.range(90, 220)) * sampleRate / 1_000
                let gap = Int(rng.range(15, 50)) * sampleRate / 1_000
                let level = amplitude * rng.range(0.5, 1.0)
                let f1 = rng.range(450, 900)
                let f2 = rng.range(1_200, 2_400)
                let phase = rng.range(0, 2 * .pi)
                let end = min(burstEnd, cursor + syllable)
                for index in cursor..<end {
                    let position = Double(index - cursor) / Double(syllable)
                    let window = 0.5 - 0.5 * cos(2 * .pi * position)
                    let t = Double(index) / Double(sampleRate)
                    let carrier = (sin(2 * .pi * f1 * t + phase) + 0.5 * sin(2 * .pi * f2 * t)) / 1.5
                    samples[index] = Float(level * window * carrier)
                }
                cursor = end + gap
            }
        }
        return samples
    }

    private static func delayed(_ samples: [Float], byMs delayMs: Int, gain: Float) -> [Float] {
        let delaySamples = delayMs * sampleRate / 1_000
        var output = [Float](repeating: 0, count: samples.count)
        for index in 0..<max(0, samples.count - delaySamples) {
            output[index + delaySamples] = samples[index] * gain
        }
        return output
    }

    private struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed &* 0x9E37_79B9_7F4A_7C15
        }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func range(_ lower: Double, _ upper: Double) -> Double {
            lower + (upper - lower) * Double(next() >> 11) / Double(1 << 53)
        }
    }
}
