import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingReverseLeakSuppressor", .serialized)
struct MeetingReverseLeakSuppressorTests {
    private let sampleRate = 16_000
    private let blockLength = 4_096
    private let frameLength = 320
    private let floorRms: Float = 0.001

    /// Local utterances over 30 s: 1.5-3.2 s bursts with 0.6-3.6 s pauses.
    private let leakSchedule: [(startMs: Int, durationMs: Int)] = [
        (500, 2_500), (3_600, 1_800), (6_000, 3_200), (10_000, 2_400), (13_200, 1_500),
        (15_500, 3_000), (19_200, 2_200), (22_000, 2_800), (25_500, 1_900), (28_000, 1_500),
    ]

    // MARK: - Environment override

    @Test("MUESLI_REVERSE_LEAK_SUPPRESSION=0 disables; absent, 1 and other values do not")
    func environmentOverride() {
        #expect(MeetingReverseLeakSuppressor.isDisabledByEnvironment(["MUESLI_REVERSE_LEAK_SUPPRESSION": "0"]))
        #expect(MeetingReverseLeakSuppressor.isDisabledByEnvironment(["MUESLI_REVERSE_LEAK_SUPPRESSION": " 0 "]))
        #expect(!MeetingReverseLeakSuppressor.isDisabledByEnvironment([:]))
        #expect(!MeetingReverseLeakSuppressor.isDisabledByEnvironment(["MUESLI_REVERSE_LEAK_SUPPRESSION": "1"]))
        #expect(!MeetingReverseLeakSuppressor.isDisabledByEnvironment(["MUESLI_REVERSE_LEAK_SUPPRESSION": "false"]))
        #expect(!MeetingReverseLeakSuppressor.isDisabledByEnvironment(["MUESLI_REVERSE_LEAK_SUPPRESSION": ""]))
        #expect(!MeetingReverseLeakSuppressor.isDisabledByEnvironment(["OTHER": "0"]))
    }

    // MARK: - Leak gating

    @Test("a -20 dB leak locks within one grid step and gates at least 90% of leaked frames", arguments: [300, 700, 1_500])
    func leakIsGatedAfterLock(delayMs: Int) throws {
        let streams = leakStreams(delayMs: delayMs)
        let suppressor = MeetingReverseLeakSuppressor()
        let run = drive(suppressor, streams: streams)

        #expect(run.output.count == streams.system.count)
        let lockSample = try #require(run.lockSample)
        let locked = try #require(suppressor.lockedDelayMs)
        #expect(abs(locked - delayMs) <= 20)
        #expect(lockSample <= 12 * sampleRate, "lock should arrive within the first 12 s")

        let coverage = leakedFrameCoverage(input: streams.system, output: run.output, from: lockSample + frameLength)
        #expect(coverage.leaked > 100)
        #expect(coverage.fraction >= 0.9, "gated \(coverage.gated) of \(coverage.leaked) leaked frames")

        let snapshot = suppressor.diagnosticsSnapshot
        #expect(snapshot.enabled)
        #expect(snapshot.lockCount == 1)
        #expect(snapshot.gateOpenCount > 0)
        #expect(snapshot.suppressedSeconds > 5)
        #expect(snapshot.intervalCount > 0)
        #expect(snapshot.lockedDelayMs == locked)
        #expect(!snapshot.delayHistory.isEmpty)
        #expect(snapshot.maxBlockProcessingMicros > 0)
    }

    @Test("gated frames sit at or below -40 dB with comfort noise above the floor and no zero runs")
    func gatedFramesSitAtTheFloor() throws {
        let streams = leakStreams(delayMs: 500, leakGain: 0.5)
        let suppressor = MeetingReverseLeakSuppressor()
        let run = drive(suppressor, streams: streams)
        let lockSample = try #require(run.lockSample)

        var gatedInput: [Float] = []
        var gatedOutput: [Float] = []
        var longestZeroRun = 0
        var currentZeroRun = 0
        var gatedFrames = 0
        for frame in frames(from: lockSample + frameLength, count: streams.system.count) {
            let input = Array(streams.system[frame])
            let output = Array(run.output[frame])
            guard rms(input) > 0.01, projectionGain(input: input, output: output) < 0.5 else { continue }
            gatedFrames += 1
            gatedInput += input
            gatedOutput += output
            #expect(rms(output) >= floorRms * 0.6, "comfort noise must keep the frame above the -60 dBFS clamp")
            #expect(rms(output) <= rms(input) * 0.011 + floorRms * 1.6)
        }
        #expect(gatedFrames > 100)

        // Interior frames (away from ramps) carry at most -40 dB of the input.
        let gain = projectionGain(input: gatedInput, output: gatedOutput)
        #expect(gain <= 0.011, "residual input gain \(gain)")

        for sample in gatedOutput {
            if sample == 0 {
                currentZeroRun += 1
                longestZeroRun = max(longestZeroRun, currentZeroRun)
            } else {
                currentZeroRun = 0
            }
        }
        #expect(longestZeroRun <= 80, "longest run of exact zeros inside gated frames is \(longestZeroRun) samples")
    }

    @Test("two block phases produce masks that differ by at most one frame per edge")
    func blockPhaseIndependence() throws {
        let streams = leakStreams(delayMs: 700)
        let phaseA = drive(MeetingReverseLeakSuppressor(), streams: streams)
        let phaseB = drive(MeetingReverseLeakSuppressor(), streams: streams, firstBlockLength: 1_000)
        #expect(phaseA.lockSample != nil)
        #expect(phaseB.lockSample != nil)

        let maskA = gatedMask(input: streams.system, output: phaseA.output)
        let maskB = gatedMask(input: streams.system, output: phaseB.output)
        #expect(maskA.count == maskB.count)

        var spans = 0
        for index in 1..<maskA.count where maskA[index] && !maskA[index - 1] {
            spans += 1
        }
        var differing = 0
        for index in maskA.indices where maskA[index] != maskB[index] {
            differing += 1
            let previous = index > 0 && maskA[index - 1] && maskB[index - 1]
            let next = index + 1 < maskA.count && maskA[index + 1] && maskB[index + 1]
            #expect(previous || next, "frame \(index) differs away from a shared edge")
        }
        #expect(spans > 5)
        #expect(differing <= 2 * spans, "\(differing) differing frames across \(spans) spans")
    }

    @Test("a genuine remote burst absent from the reference passes unchanged while locked")
    func genuineRemoteBurstPassesWhileLocked() throws {
        let delayMs = 500
        let schedule: [(startMs: Int, durationMs: Int)] = [
            (500, 2_500), (3_600, 1_800), (6_000, 3_200), (10_000, 2_400),
            (16_000, 3_000), (19_600, 2_200), (22_400, 2_800),
        ]
        var streams = leakStreams(delayMs: delayMs, schedule: schedule, seconds: 26)
        let remoteStart = 13_200 * sampleRate / 1_000
        let remoteEnd = 14_500 * sampleRate / 1_000
        let remote = speech(schedule: [(13_200, 1_300)], totalSamples: streams.system.count, amplitude: 0.2, seed: 99)
        for index in streams.system.indices {
            streams.system[index] += remote[index]
        }

        let suppressor = MeetingReverseLeakSuppressor()
        let run = drive(suppressor, streams: streams)
        let lockSample = try #require(run.lockSample)
        #expect(lockSample < remoteStart)

        #expect(Array(run.output[remoteStart..<remoteEnd]) == Array(streams.system[remoteStart..<remoteEnd]))
        // The leak after the remote burst is still gated.
        let coverage = leakedFrameCoverage(input: streams.system, output: run.output, from: 16_500 * sampleRate / 1_000)
        #expect(coverage.fraction >= 0.9)
    }

    @Test("no correlate at all: no lock, no gated frames, samples unchanged")
    func noCorrelateNeverLocks() {
        let cleanedMic = speech(schedule: leakSchedule, totalSamples: 30 * sampleRate, amplitude: 0.3, seed: 1)
        let remote = speech(
            schedule: [(1_200, 1_400), (4_800, 900), (9_400, 1_300), (12_800, 2_000), (18_000, 1_500), (24_500, 2_200)],
            totalSamples: 30 * sampleRate,
            amplitude: 0.2,
            seed: 7
        )
        let streams = Streams(cleanedMic: cleanedMic, rawMic: cleanedMic, system: remote)
        let suppressor = MeetingReverseLeakSuppressor()
        let run = drive(suppressor, streams: streams)

        #expect(run.lockSample == nil)
        #expect(suppressor.lockedDelayMs == nil)
        #expect(run.output == remote)
        let snapshot = suppressor.diagnosticsSnapshot
        #expect(snapshot.lockCount == 0)
        #expect(snapshot.gateOpenCount == 0)
        #expect(snapshot.suppressedSeconds == 0)
        #expect(snapshot.intervalCount == 0)
        #expect(suppressor.exportSuppressedIntervals().isEmpty)
        #expect(!snapshot.delaySkipHistory.isEmpty)
    }

    @Test("turn-taking with a fixed 400 ms gap never locks")
    func turnTakingNeverLocks() {
        let totalSamples = 48 * sampleRate
        var rng = SplitMix64(seed: 21)
        var micSchedule: [(startMs: Int, durationMs: Int)] = []
        var systemSchedule: [(startMs: Int, durationMs: Int)] = []
        var cursor = 400
        while cursor < 47_000 {
            let micDuration = Int(rng.range(600, 1_800))
            micSchedule.append((cursor, micDuration))
            cursor += micDuration + 400
            let systemDuration = Int(rng.range(600, 1_800))
            systemSchedule.append((cursor, systemDuration))
            cursor += systemDuration + 400
        }
        let cleanedMic = speech(schedule: micSchedule, totalSamples: totalSamples, amplitude: 0.3, seed: 3)
        let remote = speech(schedule: systemSchedule, totalSamples: totalSamples, amplitude: 0.25, seed: 4)
        let streams = Streams(cleanedMic: cleanedMic, rawMic: cleanedMic, system: remote)

        let suppressor = MeetingReverseLeakSuppressor()
        let run = drive(suppressor, streams: streams)

        #expect(run.lockSample == nil)
        #expect(suppressor.diagnosticsSnapshot.lockCount == 0)
        #expect(run.output == remote)
    }

    @Test("speaker residual 120 ms ahead of the system burst never locks when raw-mic energy is provided")
    func speakerResidualNeverLocks() {
        let totalSamples = 30 * sampleRate
        let remote = speech(schedule: leakSchedule, totalSamples: totalSamples, amplitude: 0.3, seed: 5)
        // The forward AEC leaves a 0.25-gain residual of the speaker output in the cleaned mic;
        // the raw mic carries the full echo. Both sit 120 ms ahead of the system track so the
        // uncorrected estimator would see a +120 ms lag inside its grid.
        let residual = shifted(remote, earlierByMs: 120, gain: 0.25)
        let rawEcho = shifted(remote, earlierByMs: 120, gain: 1.0)
        let streams = Streams(cleanedMic: residual, rawMic: rawEcho, system: remote)

        let suppressor = MeetingReverseLeakSuppressor()
        let run = drive(suppressor, streams: streams)

        #expect(run.lockSample == nil)
        #expect(suppressor.diagnosticsSnapshot.lockCount == 0)
        #expect(run.output == remote)
        let reasons = Set(suppressor.diagnosticsSnapshot.delaySkipHistory.map(\.reason))
        #expect(reasons.contains("insufficientActiveReference"), "skip reasons: \(reasons)")
    }

    @Test("double-talk frames pass through")
    func doubleTalkFramesPass() throws {
        let delayMs = 500
        var streams = leakStreams(delayMs: delayMs)
        // Genuine remote speech overlapping the leaked span of the 15.5-18.5 s utterance.
        let remoteStartMs = 15_500 + delayMs + 300
        let remoteDurationMs = 2_400
        let remote = speech(schedule: [(remoteStartMs, remoteDurationMs)], totalSamples: streams.system.count, amplitude: 0.2, seed: 11)
        for index in streams.system.indices {
            streams.system[index] += remote[index]
        }

        let suppressor = MeetingReverseLeakSuppressor()
        let run = drive(suppressor, streams: streams)
        let lockSample = try #require(run.lockSample)
        #expect(lockSample < remoteStartMs * sampleRate / 1_000)

        // Skip the first 200 ms of overlap: the hangover may cover the remote onset.
        let overlapStart = (remoteStartMs + 200) * sampleRate / 1_000
        let overlapEnd = (remoteStartMs + remoteDurationMs) * sampleRate / 1_000
        let mask = gatedMask(input: streams.system, output: run.output)
        let overlapFrames = (overlapStart / frameLength)..<(overlapEnd / frameLength)
        let gated = overlapFrames.filter { mask[$0] }.count
        #expect(gated <= overlapFrames.count / 10, "\(gated) of \(overlapFrames.count) double-talk frames were gated")

        // The leak is gated again once the remote speaker stops.
        let coverage = leakedFrameCoverage(input: streams.system, output: run.output, from: 22_500 * sampleRate / 1_000)
        #expect(coverage.fraction >= 0.9)
    }

    @Test("frames whose reference has not arrived pass through and are counted")
    func referenceUnavailableFailsOpen() throws {
        // 100 ms lag with the cleaned mic one block behind: most frames of each block need
        // reference samples that have not been fed yet.
        let streams = leakStreams(delayMs: 100)
        let suppressor = MeetingReverseLeakSuppressor()
        let run = drive(suppressor, streams: streams, micLagBlocks: 1)
        let lockSample = try #require(run.lockSample)

        let snapshot = suppressor.diagnosticsSnapshot
        #expect(snapshot.referenceUnavailableFrames > 100)

        let coverage = leakedFrameCoverage(input: streams.system, output: run.output, from: lockSample + frameLength)
        #expect(coverage.fraction < 0.75, "unavailable-reference frames must not be gated")

        // Frames whose reference is unavailable are byte-identical to the input.
        var unchangedFrames = 0
        for frame in frames(from: lockSample + frameLength, count: streams.system.count)
        where rms(Array(streams.system[frame])) > 0.003 && Array(run.output[frame]) == Array(streams.system[frame]) {
            unchangedFrames += 1
        }
        #expect(unchangedFrames > 100)
    }

    @Test("hangover never exceeds 200 ms after evidence stops")
    func hangoverIsBounded() throws {
        let streams = leakStreams(delayMs: 700)
        let suppressor = MeetingReverseLeakSuppressor()
        let run = drive(suppressor, streams: streams)
        let lockSample = try #require(run.lockSample)

        let mask = gatedMask(input: streams.system, output: run.output)
        let active = activeMask(streams.system)
        var longestTail = 0
        var tail = 0
        for index in (lockSample / frameLength)..<mask.count {
            if mask[index] && !active[index] {
                tail += 1
                longestTail = max(longestTail, tail)
            } else {
                tail = 0
            }
        }
        #expect(longestTail <= 11, "gate stayed closed \(longestTail) frames past the last active frame")
    }

    @Test("ramps keep the sample-to-sample jump at gate edges bounded")
    func rampContinuity() throws {
        let streams = leakStreams(delayMs: 500, leakGain: 0.5)
        let suppressor = MeetingReverseLeakSuppressor()
        let run = drive(suppressor, streams: streams)
        #expect(run.lockSample != nil)
        let coverage = leakedFrameCoverage(input: streams.system, output: run.output, from: try #require(run.lockSample) + frameLength)
        #expect(coverage.fraction >= 0.9)

        var maxInputJump: Float = 0
        var maxOutputJump: Float = 0
        for index in 1..<run.output.count {
            maxInputJump = max(maxInputJump, abs(streams.system[index] - streams.system[index - 1]))
            maxOutputJump = max(maxOutputJump, abs(run.output[index] - run.output[index - 1]))
        }
        // A hard cut would jump by the leak amplitude (about 0.15); a 10 ms ramp adds under 0.01.
        #expect(maxOutputJump <= maxInputJump + 0.01, "output jump \(maxOutputJump) vs input jump \(maxInputJump)")
    }

    @Test("gate-open spans coalesce into sorted non-overlapping intervals in the arrival frame")
    func intervalsAreCoalescedInArrivalFrame() throws {
        let streams = leakStreams(delayMs: 500)
        let suppressor = MeetingReverseLeakSuppressor()
        // The arrival frame trails the timeline by 0.5 s (one earlier capture gap).
        let arrivalOffset = -8_000
        let run = drive(suppressor, streams: streams, arrivalOffset: arrivalOffset)
        let lockSample = try #require(run.lockSample)

        let intervals = suppressor.exportSuppressedIntervals()
        #expect(!intervals.isEmpty)
        for (index, interval) in intervals.enumerated() {
            #expect(interval.end > interval.start)
            if index > 0 {
                #expect(interval.start > intervals[index - 1].end, "intervals must be sorted and non-adjacent after coalescing")
            }
            // Convert back to the timeline: every interval sits inside a leaked utterance after the lock.
            let timelineStart = interval.start - Double(arrivalOffset) / Double(sampleRate)
            #expect(timelineStart >= Double(lockSample) / Double(sampleRate) - 0.05)
            // The interval spans the gate-open run including its hangover tail, so a quiet tail
            // frame reads as ungated in the mask (there was nothing audible to attenuate). The
            // invariant that holds is: every audible frame inside the interval was gated, and the
            // interval contains at least one such frame.
            let mask = gatedMask(input: streams.system, output: run.output)
            let timelineEnd = interval.end - Double(arrivalOffset) / Double(sampleRate)
            let firstFrame = Int(timelineStart * Double(sampleRate)) / frameLength
            let lastFrame = min(mask.count - 1, Int(timelineEnd * Double(sampleRate)) / frameLength)
            var audibleFrames = 0
            for frame in firstFrame...max(firstFrame, lastFrame) where frame < mask.count {
                let samples = Array(streams.system[frames(from: 0, count: streams.system.count)[frame]])
                guard rms(samples) > 0.003 else { continue }
                audibleFrames += 1
                #expect(mask[frame], "audible frame \(frame) inside a suppressed interval is not gated")
            }
            #expect(audibleFrames > 0, "interval \(index) covers no audible frame")
        }

        let leakedUtterancesAfterLock = leakSchedule.filter { ($0.startMs + 500) * sampleRate / 1_000 >= lockSample }.count
        #expect(intervals.count <= leakedUtterancesAfterLock + 2, "\(intervals.count) intervals for \(leakedUtterancesAfterLock) utterances")
        #expect(suppressor.diagnosticsSnapshot.intervalCount == intervals.count)
        let totalSeconds = intervals.reduce(0.0) { $0 + $1.end - $1.start }
        #expect(abs(totalSeconds - suppressor.diagnosticsSnapshot.suppressedSeconds) < 0.05)
    }

    @Test("a 60 s timeline gap resets the histories and the next lock is fresh")
    func timelineGapResetsHistory() throws {
        let streams = leakStreams(delayMs: 500, seconds: 20)
        let suppressor = MeetingReverseLeakSuppressor()
        let first = drive(suppressor, streams: streams)
        #expect(first.lockSample != nil)
        #expect(suppressor.diagnosticsSnapshot.gapResetCount == 0)

        let gap = 60 * sampleRate
        let second = drive(suppressor, streams: streams, timelineOffset: streams.system.count + gap, arrivalOffset: streams.system.count)
        let snapshot = suppressor.diagnosticsSnapshot
        #expect(snapshot.gapResetCount >= 1)
        #expect(snapshot.lockCount == 2)
        #expect(second.lockSample != nil)
        #expect(suppressor.lockedDelayMs == 500)
        // Nothing is gated between the gap and the fresh lock.
        let lockSample = try #require(second.lockSample)
        let mask = gatedMask(input: streams.system, output: second.output)
        #expect(!mask[0..<(lockSample / frameLength)].contains(true))
        let coverage = leakedFrameCoverage(input: streams.system, output: second.output, from: lockSample + frameLength)
        #expect(coverage.fraction >= 0.9)
    }

    @Test("disabled: histories update and the estimator locks, but no frame is gated")
    func disabledNeverGates() {
        let streams = leakStreams(delayMs: 500)
        let suppressor = MeetingReverseLeakSuppressor(enabled: false)
        let run = drive(suppressor, streams: streams)

        #expect(suppressor.lockedDelayMs == 500)
        #expect(run.output == streams.system)
        let snapshot = suppressor.diagnosticsSnapshot
        #expect(!snapshot.enabled)
        #expect(snapshot.gateOpenCount == 0)
        #expect(snapshot.suppressedSeconds == 0)
        #expect(suppressor.exportSuppressedIntervals().isEmpty)
    }

    @Test("forced open passes everything; release resumes gating from the current lock")
    func forceOpenAndRelease() throws {
        let streams = leakStreams(delayMs: 500)
        let suppressor = MeetingReverseLeakSuppressor()
        suppressor.forceOpen()
        suppressor.forceOpen()
        let forced = drive(suppressor, streams: streams)
        #expect(suppressor.lockedDelayMs == 500)
        #expect(forced.output == streams.system)
        #expect(suppressor.diagnosticsSnapshot.gateOpenCount == 0)

        suppressor.release()
        let released = drive(suppressor, streams: streams, timelineOffset: streams.system.count, arrivalOffset: streams.system.count)
        let coverage = leakedFrameCoverage(input: streams.system, output: released.output, from: 0)
        #expect(coverage.fraction >= 0.9, "gating must resume without waiting for a new lock")
        #expect(suppressor.diagnosticsSnapshot.lockCount == 1)
    }

    @Test("reset clears the lock, hangover and ramp state, keeps intervals; discard clears intervals")
    func resetKeepsIntervalsAndDiscardClearsThem() throws {
        let streams = leakStreams(delayMs: 500)
        let suppressor = MeetingReverseLeakSuppressor()
        let first = drive(suppressor, streams: streams)
        #expect(first.lockSample != nil)
        let intervalsBeforeReset = suppressor.exportSuppressedIntervals()
        #expect(!intervalsBeforeReset.isEmpty)

        suppressor.reset()
        #expect(suppressor.lockedDelayMs == nil)
        #expect(suppressor.diagnosticsSnapshot.resetCount == 1)
        #expect(suppressor.exportSuppressedIntervals() == intervalsBeforeReset)

        let second = drive(suppressor, streams: streams, timelineOffset: streams.system.count, arrivalOffset: streams.system.count)
        let relock = try #require(second.lockSample)
        let mask = gatedMask(input: streams.system, output: second.output)
        #expect(!mask[0..<(relock / frameLength)].contains(true), "nothing is gated before the fresh lock")
        #expect(suppressor.diagnosticsSnapshot.lockCount == 2)
        #expect(suppressor.exportSuppressedIntervals().count > intervalsBeforeReset.count)

        suppressor.discard()
        #expect(suppressor.exportSuppressedIntervals().isEmpty)
        #expect(suppressor.diagnosticsSnapshot.intervalCount == 0)
        #expect(suppressor.lockedDelayMs == nil)
    }

    @Test("the diagnostics snapshot carries the reverse-leak fields")
    func diagnosticsSnapshotFields() throws {
        let streams = leakStreams(delayMs: 700)
        let suppressor = MeetingReverseLeakSuppressor()
        _ = drive(suppressor, streams: streams)
        let snapshot = suppressor.diagnosticsSnapshot

        #expect(snapshot.lockedDelayMs == 700)
        #expect(snapshot.delayHistory.count <= 24)
        #expect(snapshot.delaySkipHistory.count <= 24)
        #expect(snapshot.delayHistory.contains { $0.decision == "locked" })
        // Early windows are shorter than 8 s, so the long lags lack pairs and are not scored.
        let gridSize = MeetingAecDelayEstimator.defaultEnvelopeCandidateLagFrames.count
        #expect(snapshot.delayHistory.allSatisfy { !$0.candidateScores.isEmpty && $0.candidateScores.count <= gridSize })
        #expect(snapshot.delayHistory.last?.candidateScores.count == gridSize)
        #expect(snapshot.delayHistory.last?.appliedDelayMs == 700)
        #expect(snapshot.offsetSpreadMs <= 20)
        #expect(snapshot.meanBlockProcessingMicros > 0)
        #expect(snapshot.maxBlockProcessingMicros >= Int(snapshot.meanBlockProcessingMicros))
        #expect(snapshot.resetCount == 0)
        #expect(snapshot.relockCount == 0)
        #expect(snapshot.gapResetCount == 0)
        #expect(snapshot.offlineSpeechSecondsInsideSuppressedIntervals == nil)
    }

    // MARK: - Performance

    @Test("block and estimate cost stay under the committed caps on a 60 s leak stream")
    func performanceCaps() throws {
        let capsURL = try #require(Bundle.module.resourceURL?
            .appendingPathComponent("Fixtures/ReverseLeak/performance-caps.json"))
        let caps = try JSONDecoder().decode(PerformanceCaps.self, from: Data(contentsOf: capsURL)).reverseLeakOverhead

        let schedule = stride(from: 0, to: 60_000, by: 6_000).map { (startMs: $0 + 500, durationMs: 3_800) }
        let streams = leakStreams(delayMs: 500, schedule: schedule, seconds: 60)
        let suppressor = MeetingReverseLeakSuppressor()
        let run = drive(suppressor, streams: streams)
        #expect(run.lockSample != nil)

        let blockMillis = run.blockMicros.dropFirst(5).map { $0 / 1_000 }
        let estimateMillis = suppressor.recentEstimateProcessingMicros.dropFirst(5).map { Double($0) / 1_000 }
        #expect(blockMillis.count > 200)
        #expect(estimateMillis.count >= 20)
        let blockP95 = percentile(blockMillis, 0.95)
        let estimateP95 = percentile(estimateMillis, 0.95)
        print("REVERSE_LEAK_OVERHEAD block_p50_ms=\(percentile(blockMillis, 0.5)) block_p95_ms=\(blockP95) block_max_ms=\(blockMillis.max() ?? 0) estimate_p50_ms=\(percentile(estimateMillis, 0.5)) estimate_p95_ms=\(estimateP95) estimate_max_ms=\(estimateMillis.max() ?? 0)")
        #expect(blockP95 <= caps.committedBlockCapMilliseconds)
        #expect(estimateP95 <= caps.committedEstimateCapMilliseconds)
    }

    @Test("block cost stays flat across a 30 minute synthetic soak")
    func thirtyMinuteSoak() throws {
        let minuteSamples = 60 * sampleRate
        let schedule = stride(from: 0, to: 60_000, by: 6_000).map { (startMs: $0 + 500, durationMs: 3_800) }
        let minute = leakStreams(delayMs: 500, schedule: schedule, seconds: 60)
        let suppressor = MeetingReverseLeakSuppressor()

        var minuteMeans: [Double] = []
        for minuteIndex in 0..<30 {
            let offset = minuteIndex * minuteSamples
            let run = drive(suppressor, streams: minute, timelineOffset: offset, arrivalOffset: offset)
            let micros = run.blockMicros
            minuteMeans.append(micros.reduce(0, +) / Double(micros.count))
        }
        #expect(suppressor.lockedDelayMs == 500)
        #expect(suppressor.diagnosticsSnapshot.lockCount == 1)

        let first = minuteMeans[0]
        let last = minuteMeans[29]
        print("REVERSE_LEAK_SOAK first_minute_mean_us=\(first) last_minute_mean_us=\(last) max_minute_mean_us=\(minuteMeans.max() ?? 0)")
        #expect(last <= 2 * first, "last-minute mean \(last) us exceeds twice the first-minute mean \(first) us")
        let coverage = leakedFrameCoverage(input: minute.system, output: drive(suppressor, streams: minute, timelineOffset: 30 * minuteSamples, arrivalOffset: 30 * minuteSamples).output, from: 0)
        #expect(coverage.fraction >= 0.9)
    }

    // MARK: - Stream driver

    private struct Streams {
        var cleanedMic: [Float]
        var rawMic: [Float]?
        var system: [Float]
    }

    private struct DriveResult {
        var output: [Float]
        /// Timeline start of the first system block processed with a (fresh) lock in place; 0 when
        /// the suppressor was already locked for the whole drive.
        var lockSample: Int?
        var blockMicros: [Double]
    }

    /// Feeds mic block `b - micLagBlocks` and then processes system block `b`, in order.
    @discardableResult
    private func drive(
        _ suppressor: MeetingReverseLeakSuppressor,
        streams: Streams,
        firstBlockLength: Int = 4_096,
        micLagBlocks: Int = 0,
        timelineOffset: Int = 0,
        arrivalOffset: Int = 0
    ) -> DriveResult {
        let total = streams.system.count
        var blocks: [Range<Int>] = []
        var start = 0
        var end = min(firstBlockLength, total)
        while start < total {
            blocks.append(start..<end)
            start = end
            end = min(start + blockLength, total)
        }

        var output: [Float] = []
        output.reserveCapacity(total)
        var lockSample: Int?
        var blockMicros: [Double] = []
        var sawUnlocked = suppressor.lockedDelayMs == nil
        for (index, block) in blocks.enumerated() {
            let micIndex = index - micLagBlocks
            if micIndex >= 0 {
                let micBlock = blocks[micIndex]
                suppressor.feedCleanedMicSamples(Array(streams.cleanedMic[micBlock]), timelineStartSample: micBlock.lowerBound + timelineOffset)
                if let rawMic = streams.rawMic {
                    suppressor.feedRawMicSamples(Array(rawMic[micBlock]), timelineStartSample: micBlock.lowerBound + timelineOffset)
                }
            }
            if suppressor.lockedDelayMs == nil {
                sawUnlocked = true
            } else if lockSample == nil, sawUnlocked {
                lockSample = block.lowerBound
            }
            let started = ContinuousClock.now
            let processed = suppressor.processSystemBlock(
                Array(streams.system[block]),
                timelineStartSample: block.lowerBound + timelineOffset,
                arrivalStartSample: block.lowerBound + arrivalOffset
            )
            blockMicros.append(microseconds(from: started.duration(to: .now)))
            precondition(processed.count == block.count, "sample count must be one-to-one")
            output += processed
        }
        if lockSample == nil, !sawUnlocked {
            lockSample = 0
        }
        return DriveResult(output: output, lockSample: lockSample, blockMicros: blockMicros)
    }

    private func leakStreams(
        delayMs: Int,
        leakGain: Float = 0.1,
        schedule: [(startMs: Int, durationMs: Int)]? = nil,
        seconds: Int = 30,
        seed: UInt64 = 1
    ) -> Streams {
        let totalSamples = seconds * sampleRate
        let cleanedMic = speech(schedule: schedule ?? leakSchedule, totalSamples: totalSamples, amplitude: 0.3, seed: seed)
        let system = delayed(cleanedMic, byMs: delayMs, gain: leakGain)
        return Streams(cleanedMic: cleanedMic, rawMic: cleanedMic, system: system)
    }

    // MARK: - Analysis helpers

    private func frames(from start: Int, count: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var cursor = (start + frameLength - 1) / frameLength * frameLength
        while cursor + frameLength <= count {
            result.append(cursor..<(cursor + frameLength))
            cursor += frameLength
        }
        return result
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// Least-squares gain of `output` on `input`; 1 for pass-through, about 0.01 for a gated frame.
    private func projectionGain(input: [Float], output: [Float]) -> Float {
        var dot: Float = 0
        var energy: Float = 0
        for index in input.indices {
            dot += input[index] * output[index]
            energy += input[index] * input[index]
        }
        return energy > 0 ? dot / energy : 1
    }

    /// Per-frame mask derived from the output: gated when the residual input gain is under 0.5.
    private func gatedMask(input: [Float], output: [Float]) -> [Bool] {
        frames(from: 0, count: input.count).map { frame in
            let inputFrame = Array(input[frame])
            guard rms(inputFrame) > 0.003 else { return false }
            return projectionGain(input: inputFrame, output: Array(output[frame])) < 0.5
        }
    }

    private func activeMask(_ input: [Float]) -> [Bool] {
        frames(from: 0, count: input.count).map { rms(Array(input[$0])) > 0.003 }
    }

    private func leakedFrameCoverage(input: [Float], output: [Float], from start: Int) -> (leaked: Int, gated: Int, fraction: Double) {
        var leaked = 0
        var gated = 0
        for frame in frames(from: start, count: input.count) {
            let inputFrame = Array(input[frame])
            guard rms(inputFrame) > 0.003 else { continue }
            leaked += 1
            if projectionGain(input: inputFrame, output: Array(output[frame])) < 0.5 {
                gated += 1
            }
        }
        return (leaked, gated, leaked > 0 ? Double(gated) / Double(leaked) : 0)
    }

    private func percentile(_ values: [Double], _ percentile: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[max(0, Int(ceil(percentile * Double(sorted.count))) - 1)]
    }

    private func microseconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000_000 + Double(components.attoseconds) / 1_000_000_000_000
    }

    // MARK: - Signal helpers

    /// Speech-like bursts: random 90-220 ms syllables with raised-cosine envelopes, random
    /// two-tone carriers and 15-50 ms gaps, so envelopes carry syllabic modulation.
    private func speech(
        schedule: [(startMs: Int, durationMs: Int)],
        totalSamples: Int,
        amplitude: Double,
        seed: UInt64
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: totalSamples)
        var rng = SplitMix64(seed: seed)
        for burst in schedule {
            let burstStart = burst.startMs * sampleRate / 1_000
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

    private func delayed(_ samples: [Float], byMs delayMs: Int, gain: Float) -> [Float] {
        let delaySamples = delayMs * sampleRate / 1_000
        var output = [Float](repeating: 0, count: samples.count)
        for index in 0..<max(0, samples.count - delaySamples) {
            output[index + delaySamples] = samples[index] * gain
        }
        return output
    }

    private func shifted(_ samples: [Float], earlierByMs shiftMs: Int, gain: Float) -> [Float] {
        let shift = shiftMs * sampleRate / 1_000
        var output = [Float](repeating: 0, count: samples.count)
        for index in shift..<samples.count {
            output[index - shift] = samples[index] * gain
        }
        return output
    }

    private struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func range(_ lower: Double, _ upper: Double) -> Double {
            lower + (upper - lower) * Double(next() >> 11) / Double(1 << 53)
        }
    }

    private struct PerformanceCaps: Decodable {
        let reverseLeakOverhead: ReverseLeakOverhead

        struct ReverseLeakOverhead: Decodable {
            let committedBlockCapMilliseconds: Double
            let committedEstimateCapMilliseconds: Double
        }
    }
}
