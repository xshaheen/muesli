import Accelerate
import Foundation

/// A gate-open span (open to close plus hangover) in the system arrival frame: seconds of raw
/// system samples delivered by the recorder, which is the raw system file's own time axis.
struct MeetingSuppressedInterval: Equatable, Sendable {
    let start: Double
    let end: Double
}

/// Lock state for the reverse (mic-to-system) registration offset. Lags are envelope-frame
/// counts on the estimator's 20 ms grid.
///
/// Lock after three consecutive accepted estimates within one grid step of each other; while
/// locked, estimates inside the gate tolerance agree with the lock, and five consecutive
/// disagreeing estimates that agree with each other within one step re-lock. A rejected
/// estimate breaks whichever chain is running but never clears a lock; only `reset` does.
struct MeetingReverseLeakLockPolicy {
    enum Decision: String, Equatable {
        case candidate
        case locked
        case agreesWithLock
        case relockCandidate
        case relocked
    }

    static let lockAgreementCount = 3
    static let relockAgreementCount = 5
    static let chainAgreementStepFrames = 1
    /// Plus or minus 60 ms: the same tolerance the gate applies around the lock.
    static let lockToleranceFrames = 3

    private(set) var lockedLagFrames: Int?
    private var candidateLags: [Int] = []
    private var relockLags: [Int] = []

    var isLocked: Bool { lockedLagFrames != nil }
    var candidateCount: Int { candidateLags.count }
    var relockCandidateCount: Int { relockLags.count }

    mutating func observe(lagFrames: Int) -> Decision {
        if let locked = lockedLagFrames {
            if abs(lagFrames - locked) <= Self.lockToleranceFrames {
                relockLags.removeAll(keepingCapacity: true)
                return .agreesWithLock
            }
            Self.extend(&relockLags, with: lagFrames)
            guard relockLags.count >= Self.relockAgreementCount else { return .relockCandidate }
            lockedLagFrames = Self.median(relockLags)
            relockLags.removeAll(keepingCapacity: true)
            return .relocked
        }

        Self.extend(&candidateLags, with: lagFrames)
        guard candidateLags.count >= Self.lockAgreementCount else { return .candidate }
        lockedLagFrames = Self.median(candidateLags)
        candidateLags.removeAll(keepingCapacity: true)
        return .locked
    }

    /// A cadence tick without an accepted estimate: chains are consecutive, the lock survives.
    mutating func observeRejected() {
        candidateLags.removeAll(keepingCapacity: true)
        relockLags.removeAll(keepingCapacity: true)
    }

    mutating func reset() {
        lockedLagFrames = nil
        candidateLags.removeAll(keepingCapacity: true)
        relockLags.removeAll(keepingCapacity: true)
    }

    private static func extend(_ chain: inout [Int], with lagFrames: Int) {
        if let anchor = chain.first, abs(lagFrames - anchor) <= chainAgreementStepFrames {
            chain.append(lagFrames)
        } else {
            chain = [lagFrames]
        }
    }

    private static func median(_ lags: [Int]) -> Int {
        let sorted = lags.sorted()
        return sorted[sorted.count / 2]
    }
}

/// Gates leaked local speech out of the system track before the system VAD, chunk recorder and
/// live-caption feed see it, using the AEC-cleaned mic as the reference.
///
/// Accessed only from MeetingSession's chunkRotationQueue.
///
/// Histories are 20 ms RMS envelopes of band-limited audio in the `MeetingRecordingTimeline`
/// frame (reference = cleaned mic, raw mic, system); no waveform is retained. Envelope frames
/// are anchored at 320-sample multiples of the timeline, which equals the system arrival count
/// until the first capture gap; a 4096-sample block therefore spans a partial frame at each end.
/// Every 2 s of reference audio (phased 1 s off the forward estimator) the envelope-domain
/// estimator scores the last 8 s and drives `MeetingReverseLeakLockPolicy`. Once locked, each
/// system frame is gated only when the cleaned mic was active at `t - D` (within tolerance),
/// the short-window correlation at lag `D` holds, and the system level is consistent with the
/// tracked leak gain; gated frames are scaled to -40 dB and mixed with comfort noise at the
/// tracked system floor through 10 ms ramps. Everything fails open.
final class MeetingReverseLeakSuppressor {
    static let sampleRate = 16_000
    static let frameLength = MeetingAecDelayEstimator.envelopeFrameLength
    static let frameDurationMs = MeetingAecDelayEstimator.envelopeFrameDurationMs
    static let windowFrames = MeetingAecDelayEstimator.envelopeWindowFrames
    /// 0.75 s short correlation window.
    static let shortWindowFrames = 38
    /// Plus or minus 60 ms around the lock.
    static let toleranceFrames = MeetingReverseLeakLockPolicy.lockToleranceFrames
    /// Window + max candidate lag + short window + tolerance.
    static let retentionFrames = windowFrames
        + (MeetingAecDelayEstimator.defaultEnvelopeCandidateLagFrames.last ?? 100)
        + shortWindowFrames + toleranceFrames
    /// Reverse estimates run every 2 s of reference audio, first at 1.5 s so the burst never
    /// coincides with the forward estimator's 0.5 s + 2 k s cadence.
    static let estimateIntervalFrames = 100
    static let firstEstimateFrame = 75
    /// Trailing partial frames at least this long are decided on their own samples.
    static let minimumPartialFrameSamples = 128
    static let rampSamples = 160
    /// -40 dB.
    static let gatedGain: Float = 0.01
    /// -60 dBFS RMS clamp for the tracked floor and the comfort noise.
    static let floorClampRms: Float = 0.001
    /// +10 dB over the tracked floor marks an active envelope frame.
    static let activeGainOverFloor: Float = 3.1623
    static let enterCorrelation = 0.6
    static let provisionalEnterCorrelation = 0.7
    static let exitCorrelation = 0.4
    static let levelConsistencyFactor: Float = 2
    static let leakGainRingCapacity = 250
    /// 1 s of leak-gain support before the enter threshold relaxes to 0.6.
    static let leakGainMinimumSupport = 50
    static let hangoverFrames = 10
    static let forwardResidualLookbackFrames = 15
    static let forwardResidualRatio: Float = 0.3
    static let historyLimit = 24
    static let estimateTimingLimit = 128
    static let environmentKey = "MUESLI_REVERSE_LEAK_SUPPRESSION"

    /// `MUESLI_REVERSE_LEAK_SUPPRESSION=0` disables the feature regardless of config.
    static func isDisabledByEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }

    private(set) var isEnabled: Bool
    private(set) var isForcedOpen = false

    private let estimator = MeetingAecDelayEstimator()
    private var lockPolicy = MeetingReverseLeakLockPolicy()

    private var referenceHistory = EnvelopeHistory(retentionFrames: MeetingReverseLeakSuppressor.retentionFrames)
    private var rawMicHistory = EnvelopeHistory(retentionFrames: MeetingReverseLeakSuppressor.retentionFrames)
    private var systemHistory = EnvelopeHistory(retentionFrames: MeetingReverseLeakSuppressor.retentionFrames)
    private let referenceFilter = MeetingAecEnvelopeHighPassFilter()
    private let rawMicFilter = MeetingAecEnvelopeHighPassFilter()
    private let systemFilter = MeetingAecEnvelopeHighPassFilter()
    private var referenceFloor = FloorTracker()
    private var systemFloor = FloorTracker()

    private var nextEstimateFrame = MeetingReverseLeakSuppressor.firstEstimateFrame
    private var leakGainRing = LeakGainRing(capacity: MeetingReverseLeakSuppressor.leakGainRingCapacity)
    private var blockLeakGain: Float?

    // Gate state.
    private var gateEvidenceOpen = false
    private var hangoverRemaining = 0
    private var previousFrameGated = false
    private var ramp = RampState()

    // Intervals in the arrival frame, coalesced on append.
    private var closedIntervals: [(start: Int, end: Int)] = []
    private var openInterval: (start: Int, end: Int)?

    // Diagnostics.
    private var delayHistory: [MeetingAecDelayObservation] = []
    private var delaySkipHistory: [MeetingReverseLeakDelaySkip] = []
    private var lockCount = 0
    private var relockCount = 0
    private var resetCount = 0
    private var gapResetCount = 0
    private var gateOpenCount = 0
    private var suppressedSamples = 0
    private var referenceUnavailableFrames = 0
    private var minimumObservedDelayMs: Int?
    private var maximumObservedDelayMs: Int?
    private var blockProcessingCount = 0
    private var blockProcessingTotalMicros = 0
    private var maxBlockProcessingMicros = 0
    private(set) var recentEstimateProcessingMicros: [Int] = []

    private let noiseTile: [Float]
    private var noiseOffset = 0

    init(enabled: Bool = true) {
        isEnabled = enabled
        noiseTile = Self.makeNoiseTile(count: 8_192)
    }

    // MARK: - Controls

    var lockedDelayMs: Int? {
        lockPolicy.lockedLagFrames.map { $0 * Self.frameDurationMs }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    /// Live disable: the gate opens for the running meeting while the estimator keeps running.
    func forceOpen() {
        isForcedOpen = true
    }

    /// Live enable: gating resumes from the estimator's current lock state.
    func release() {
        isForcedOpen = false
    }

    /// Pause, system realign, or a completed mic handoff: clears the lock, candidate, hangover
    /// and ramp state. Suppressed intervals already accumulated are kept.
    func reset() {
        lockPolicy.reset()
        leakGainRing.removeAll()
        blockLeakGain = nil
        clearGateState()
        resetCount += 1
    }

    /// Session discard: everything goes, intervals included.
    func discard() {
        reset()
        referenceHistory.removeAll()
        rawMicHistory.removeAll()
        systemHistory.removeAll()
        referenceFilter.reset()
        rawMicFilter.reset()
        systemFilter.reset()
        referenceFloor = FloorTracker()
        systemFloor = FloorTracker()
        nextEstimateFrame = Self.firstEstimateFrame
        closedIntervals.removeAll()
        openInterval = nil
        delayHistory.removeAll()
        delaySkipHistory.removeAll()
        lockCount = 0
        relockCount = 0
        resetCount = 0
        gapResetCount = 0
        gateOpenCount = 0
        suppressedSamples = 0
        referenceUnavailableFrames = 0
        minimumObservedDelayMs = nil
        maximumObservedDelayMs = nil
        blockProcessingCount = 0
        blockProcessingTotalMicros = 0
        maxBlockProcessingMicros = 0
        recentEstimateProcessingMicros.removeAll()
    }

    private func clearGateState() {
        gateEvidenceOpen = false
        hangoverRemaining = 0
        previousFrameGated = false
        ramp = RampState()
        closeOpenInterval()
    }

    // MARK: - Reference feeds

    /// AEC-cleaned mic samples at their timeline position; drives the estimator cadence.
    func feedCleanedMicSamples(_ samples: [Float], timelineStartSample: Int) {
        guard !samples.isEmpty else { return }
        let reconciliation = referenceHistory.reconcile(position: timelineStartSample, count: samples.count)
        if reconciliation.didReset {
            referenceFilter.reset()
            handleGapReset()
        }
        guard reconciliation.drop < samples.count else { return }
        let filtered = referenceFilter.process(reconciliation.drop > 0 ? Array(samples[reconciliation.drop...]) : samples)
        for frame in referenceHistory.append(filtered) {
            referenceFloor.observe(frame.value)
        }
        runEstimateIfDue()
    }

    /// Raw mic samples at their timeline position; only used by the forward-residual exclusion.
    func feedRawMicSamples(_ samples: [Float], timelineStartSample: Int) {
        guard !samples.isEmpty else { return }
        let reconciliation = rawMicHistory.reconcile(position: timelineStartSample, count: samples.count)
        if reconciliation.didReset {
            rawMicFilter.reset()
        }
        guard reconciliation.drop < samples.count else { return }
        let filtered = rawMicFilter.process(reconciliation.drop > 0 ? Array(samples[reconciliation.drop...]) : samples)
        _ = rawMicHistory.append(filtered)
    }

    private func handleGapReset() {
        gapResetCount += 1
        lockPolicy.reset()
        leakGainRing.removeAll()
        blockLeakGain = nil
        gateEvidenceOpen = false
        hangoverRemaining = 0
        previousFrameGated = false
        closeOpenInterval()
    }

    // MARK: - System blocks

    /// Gates one system block. `timelineStartSample` is the position of the first sample in the
    /// recording timeline; `arrivalStartSample` is the running count of raw system samples the
    /// recorder had delivered before this block. Returns exactly `samples.count` samples.
    func processSystemBlock(_ samples: [Float], timelineStartSample: Int, arrivalStartSample: Int) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let started = ContinuousClock.now
        defer { recordBlockTime(started.duration(to: .now)) }

        let reconciliation = systemHistory.reconcile(position: timelineStartSample, count: samples.count)
        if reconciliation.didReset {
            systemFilter.reset()
            handleGapReset()
        }
        if reconciliation.drop > 0 {
            // Overlapping (non-monotonic) positions never happen in the timeline frame; keep the
            // history consistent and let the block through untouched.
            if reconciliation.drop < samples.count {
                _ = systemHistory.append(systemFilter.process(Array(samples[reconciliation.drop...])))
            }
            return samples
        }

        let filtered = systemFilter.process(samples)
        for frame in systemHistory.append(filtered) {
            systemFloor.observe(frame.value)
        }

        // Segment the block on the 320-sample timeline grid.
        let blockStart = timelineStartSample
        let blockEnd = timelineStartSample + samples.count
        var segments: [Segment] = []
        var cursor = blockStart
        let firstBoundary = (blockStart + Self.frameLength - 1) / Self.frameLength * Self.frameLength
        if firstBoundary > blockStart {
            let end = min(firstBoundary, blockEnd)
            segments.append(Segment(range: 0..<(end - blockStart), frame: blockStart / Self.frameLength, kind: .leading))
            cursor = end
        }
        while cursor + Self.frameLength <= blockEnd {
            segments.append(Segment(range: (cursor - blockStart)..<(cursor - blockStart + Self.frameLength), frame: cursor / Self.frameLength, kind: .full))
            cursor += Self.frameLength
        }
        if cursor < blockEnd {
            segments.append(Segment(range: (cursor - blockStart)..<(blockEnd - blockStart), frame: cursor / Self.frameLength, kind: .trailing))
        }

        blockLeakGain = leakGainRing.median()
        let gatingActive = isEnabled && !isForcedOpen && lockPolicy.isLocked
        var anyGated = false
        for index in segments.indices {
            let segment = segments[index]
            let gated: Bool
            switch segment.kind {
            case .leading:
                gated = previousFrameGated
            case .full:
                gated = gatingActive
                    ? evaluate(frame: segment.frame, systemEnvelope: systemHistory.value(at: segment.frame) ?? 0)
                    : passThrough()
            case .trailing:
                if segment.range.count >= Self.minimumPartialFrameSamples {
                    var envelope: Float = 0
                    filtered.withUnsafeBufferPointer { buffer in
                        vDSP_rmsqv(buffer.baseAddress! + segment.range.lowerBound, 1, &envelope, vDSP_Length(segment.range.count))
                    }
                    gated = gatingActive ? evaluate(frame: segment.frame, systemEnvelope: envelope) : passThrough()
                } else {
                    gated = previousFrameGated
                }
            }
            segments[index].gated = gated
            if gated {
                anyGated = true
                if !previousFrameGated {
                    gateOpenCount += 1
                }
                suppressedSamples += segment.range.count
                recordInterval(start: arrivalStartSample + segment.range.lowerBound, end: arrivalStartSample + segment.range.upperBound)
            } else if openInterval != nil {
                closeOpenInterval()
            }
            previousFrameGated = gated
        }

        guard anyGated || ramp.isActive else { return samples }
        return applyMask(to: samples, segments: segments)
    }

    private func passThrough() -> Bool {
        gateEvidenceOpen = false
        hangoverRemaining = 0
        return false
    }

    /// The KTD4 decision for one 20 ms system frame at timeline frame `frame`.
    private func evaluate(frame: Int, systemEnvelope: Float) -> Bool {
        guard let lag = lockPolicy.lockedLagFrames else { return passThrough() }
        let center = frame - lag
        guard referenceHistory.endFrame > center, center >= referenceHistory.startFrame else {
            referenceUnavailableFrames += 1
            return passThrough()
        }

        let low = max(center - Self.toleranceFrames, referenceHistory.startFrame)
        let high = min(center + Self.toleranceFrames, referenceHistory.endFrame - 1)
        let activeThreshold = referenceFloor.floor * Self.activeGainOverFloor
        var micActive = false
        var maxReference: Float = 0
        for candidate in low...high {
            let value = referenceHistory.value(at: candidate) ?? 0
            maxReference = max(maxReference, value)
            if !micActive, value > activeThreshold, !isForwardResidual(referenceFrame: candidate) {
                micActive = true
            }
        }

        let levelConsistent: Bool
        if let leakGain = blockLeakGain {
            levelConsistent = systemEnvelope <= Self.levelConsistencyFactor * leakGain * maxReference
        } else {
            levelConsistent = false
        }
        let correlation = shortWindowCorrelation(frame: frame, lag: lag, currentValue: systemEnvelope)
        let enterThreshold = leakGainRing.count >= Self.leakGainMinimumSupport
            ? Self.enterCorrelation
            : Self.provisionalEnterCorrelation

        // Staying open still needs the reference to be active at t - D; once it goes quiet the
        // hangover, not hysteresis, covers the tail, so silence never accumulates comfort noise.
        let confirmed = micActive && levelConsistent && correlation >= enterThreshold
        let sustained = gateEvidenceOpen && micActive && levelConsistent && correlation >= Self.exitCorrelation
        if confirmed || sustained {
            gateEvidenceOpen = true
            hangoverRemaining = 0
            if micActive, let centerValue = referenceHistory.value(at: center), centerValue > activeThreshold {
                leakGainRing.push(systemEnvelope / centerValue)
            }
            return true
        }

        if gateEvidenceOpen {
            gateEvidenceOpen = false
            // A level jump is most likely a genuine remote onset: cut immediately. Only a
            // correlation fade earns the hangover.
            hangoverRemaining = levelConsistent ? Self.hangoverFrames : 0
        }
        if hangoverRemaining > 0 {
            hangoverRemaining -= 1
            return true
        }
        return false
    }

    /// Zero-mean Pearson between `reference[k - lag]` and `system[k]` over the last 0.75 s.
    private func shortWindowCorrelation(frame: Int, lag: Int, currentValue: Float) -> Double {
        var count = 0.0
        var sumX = 0.0
        var sumY = 0.0
        var sumXX = 0.0
        var sumYY = 0.0
        var sumXY = 0.0
        for k in (frame - Self.shortWindowFrames + 1)...frame {
            let x = Double(referenceHistory.value(at: k - lag) ?? 0)
            let y = Double(k == frame ? currentValue : (systemHistory.value(at: k) ?? 0))
            count += 1
            sumX += x
            sumY += y
            sumXX += x * x
            sumYY += y * y
            sumXY += x * y
        }
        let covariance = sumXY - sumX * sumY / count
        let varianceX = sumXX - sumX * sumX / count
        let varianceY = sumYY - sumY * sumY / count
        guard varianceX > 1e-12, varianceY > 1e-12 else { return 0 }
        return covariance / (varianceX * varianceY).squareRoot()
    }

    /// Forward-residual exclusion: the system track was active in the preceding 300 ms and the
    /// cleaned mic carries under 0.3 of the raw mic energy, so the "reference" is speaker bleed.
    private func isForwardResidual(referenceFrame: Int) -> Bool {
        guard let raw = rawMicHistory.value(at: referenceFrame), raw > 0,
              let cleaned = referenceHistory.value(at: referenceFrame),
              cleaned < Self.forwardResidualRatio * raw
        else { return false }
        let systemThreshold = systemFloor.floor * Self.activeGainOverFloor
        for k in (referenceFrame - Self.forwardResidualLookbackFrames)..<referenceFrame {
            if let value = systemHistory.value(at: k), value > systemThreshold {
                return true
            }
        }
        return false
    }

    // MARK: - Mask application

    private struct Segment {
        let range: Range<Int>
        let frame: Int
        let kind: Kind
        var gated = false

        enum Kind {
            case leading
            case full
            case trailing
        }
    }

    /// Per-sample weight 0 (open) to 1 (gated) moving through 10 ms ramps that start at frame
    /// edges; gain = 1 - 0.99 w and comfort noise = floor * w.
    private func applyMask(to samples: [Float], segments: [Segment]) -> [Float] {
        let count = samples.count
        var weights = [Float](repeating: 0, count: count)
        for segment in segments {
            let target: Float = segment.gated ? 1 : 0
            if segment.kind != .leading, target != ramp.target {
                ramp.start(toward: target)
            }
            ramp.fill(&weights, range: segment.range)
        }

        var gains = [Float](repeating: 0, count: count)
        var slope = -(1 - Self.gatedGain)
        var one: Float = 1
        vDSP_vsmsa(weights, 1, &slope, &one, &gains, 1, vDSP_Length(count))

        var output = [Float](repeating: 0, count: count)
        vDSP_vmul(samples, 1, gains, 1, &output, 1, vDSP_Length(count))

        var noise = [Float](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let chunk = min(count - filled, noiseTile.count - noiseOffset)
            noise.replaceSubrange(filled..<(filled + chunk), with: noiseTile[noiseOffset..<(noiseOffset + chunk)])
            filled += chunk
            noiseOffset = (noiseOffset + chunk) % noiseTile.count
        }
        var floor = systemFloor.floor
        var weightedNoise = [Float](repeating: 0, count: count)
        vDSP_vmul(noise, 1, weights, 1, &weightedNoise, 1, vDSP_Length(count))
        var result = [Float](repeating: 0, count: count)
        vDSP_vsma(weightedNoise, 1, &floor, output, 1, &result, 1, vDSP_Length(count))
        return result
    }

    private struct RampState {
        private(set) var target: Float = 0
        private var value: Float = 0
        private var increment: Float = 0
        private var remaining = 0

        var isActive: Bool { remaining > 0 || target != 0 }

        mutating func start(toward newTarget: Float) {
            target = newTarget
            remaining = MeetingReverseLeakSuppressor.rampSamples
            increment = (newTarget - value) / Float(remaining)
        }

        /// Writes the weights for `range`: the rest of any running ramp, then a hold.
        mutating func fill(_ weights: inout [Float], range: Range<Int>) {
            var cursor = range.lowerBound
            if remaining > 0 {
                let rampCount = min(remaining, range.count)
                var first = value + increment
                var step = increment
                weights.withUnsafeMutableBufferPointer { buffer in
                    vDSP_vramp(&first, &step, buffer.baseAddress! + cursor, 1, vDSP_Length(rampCount))
                }
                value += Float(rampCount) * increment
                remaining -= rampCount
                if remaining == 0 {
                    value = target
                }
                cursor += rampCount
            }
            let holdCount = range.upperBound - cursor
            guard holdCount > 0 else { return }
            var hold = value
            weights.withUnsafeMutableBufferPointer { buffer in
                vDSP_vfill(&hold, buffer.baseAddress! + cursor, 1, vDSP_Length(holdCount))
            }
        }
    }

    private static func makeNoiseTile(count: Int) -> [Float] {
        // Uniform noise in [-sqrt(3), sqrt(3)] has unit RMS; a fixed seed keeps runs reproducible.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let amplitude = Float(3.0.squareRoot())
        return (0..<count).map { _ in
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            let unit = Float(z >> 40) / Float(1 << 24)
            return (unit * 2 - 1) * amplitude
        }
    }

    // MARK: - Intervals

    private func recordInterval(start: Int, end: Int) {
        if var open = openInterval, start <= open.end {
            open.end = max(open.end, end)
            openInterval = open
        } else {
            closeOpenInterval()
            openInterval = (start, end)
        }
    }

    private func closeOpenInterval() {
        guard let open = openInterval else { return }
        openInterval = nil
        if var last = closedIntervals.last, open.start <= last.end {
            last.end = max(last.end, open.end)
            closedIntervals[closedIntervals.count - 1] = last
        } else {
            closedIntervals.append(open)
        }
    }

    /// Coalesced, sorted, non-overlapping gate-open spans in the arrival frame. Kept across
    /// resets for the whole session; cleared only by `discard`.
    func exportSuppressedIntervals() -> [MeetingSuppressedInterval] {
        var intervals = closedIntervals
        if let open = openInterval {
            if var last = intervals.last, open.start <= last.end {
                last.end = max(last.end, open.end)
                intervals[intervals.count - 1] = last
            } else {
                intervals.append(open)
            }
        }
        let rate = Double(Self.sampleRate)
        return intervals.map { MeetingSuppressedInterval(start: Double($0.start) / rate, end: Double($0.end) / rate) }
    }

    // MARK: - Estimator

    private func runEstimateIfDue() {
        guard referenceHistory.framesReceived >= nextEstimateFrame else { return }
        nextEstimateFrame = referenceHistory.framesReceived + Self.estimateIntervalFrames
        let started = ContinuousClock.now
        defer { recordEstimateTime(started.duration(to: .now)) }

        guard !referenceHistory.isEmpty, !systemHistory.isEmpty else {
            lockPolicy.observeRejected()
            recordSkip(reason: "waitingForComparableTargetAudio", comparableEndFrame: nil, failure: nil)
            return
        }
        let comparableEnd = min(referenceHistory.endFrame, systemHistory.endFrame)
        let windowStart = max(comparableEnd - Self.windowFrames, referenceHistory.startFrame, systemHistory.startFrame)
        guard comparableEnd > windowStart else {
            lockPolicy.observeRejected()
            recordSkip(reason: "waitingForComparableTargetAudio", comparableEndFrame: nil, failure: nil)
            return
        }

        let reference = referenceHistory.slice(windowStart..<comparableEnd)
        let nearEnd = systemHistory.slice(windowStart..<comparableEnd)
        let mask = (windowStart..<comparableEnd).map { !isForwardResidual(referenceFrame: $0) }
        let attempt = estimator.scoreEnvelopes(
            reference: reference,
            nearEnd: nearEnd,
            referenceMask: mask,
            activeThreshold: referenceFloor.floor * Self.activeGainOverFloor
        )

        switch attempt {
        case let .failure(failure):
            lockPolicy.observeRejected()
            recordSkip(reason: failure.reason, comparableEndFrame: comparableEnd, failure: failure)
        case let .result(result):
            let lagFrames = result.delaySamples / Self.frameLength
            let decision = lockPolicy.observe(lagFrames: lagFrames)
            switch decision {
            case .locked:
                lockCount += 1
                seedLeakGain(windowEnd: comparableEnd)
            case .relocked:
                relockCount += 1
                leakGainRing.removeAll()
                seedLeakGain(windowEnd: comparableEnd)
            case .candidate, .agreesWithLock, .relockCandidate:
                break
            }
            minimumObservedDelayMs = min(minimumObservedDelayMs ?? result.delayMs, result.delayMs)
            maximumObservedDelayMs = max(maximumObservedDelayMs ?? result.delayMs, result.delayMs)
            delayHistory.append(MeetingAecDelayObservation(
                delayMs: result.delayMs,
                appliedDelayMs: lockedDelayMs ?? 0,
                score: result.score,
                confidence: result.confidence,
                comparedFrames: result.comparedFrames,
                decision: decision.rawValue,
                candidateScores: result.candidateScores
            ))
            if delayHistory.count > Self.historyLimit {
                delayHistory.removeFirst(delayHistory.count - Self.historyLimit)
            }
        }
    }

    /// Seeds the leak-gain ring from the frames of the windows that produced the lock.
    private func seedLeakGain(windowEnd: Int) {
        guard let lag = lockPolicy.lockedLagFrames else { return }
        let activeThreshold = referenceFloor.floor * Self.activeGainOverFloor
        let firstFrame = max(referenceHistory.startFrame, windowEnd - Self.windowFrames - 2 * Self.estimateIntervalFrames)
        for k in firstFrame..<windowEnd {
            guard let reference = referenceHistory.value(at: k), reference > activeThreshold,
                  let system = systemHistory.value(at: k + lag),
                  !isForwardResidual(referenceFrame: k)
            else { continue }
            leakGainRing.push(system / reference)
        }
    }

    private func recordSkip(reason: String, comparableEndFrame: Int?, failure: MeetingAecDelayEstimator.Failure?) {
        delaySkipHistory.append(MeetingReverseLeakDelaySkip(
            reason: reason,
            referenceSamplesReceived: referenceHistory.framesReceived * Self.frameLength,
            targetSamplesReceived: systemHistory.framesReceived * Self.frameLength,
            referenceHistoryStartSample: referenceHistory.startFrame * Self.frameLength,
            targetHistoryStartSample: systemHistory.startFrame * Self.frameLength,
            comparableEndSample: comparableEndFrame.map { $0 * Self.frameLength },
            validCandidateCount: failure?.validCandidateCount ?? 0,
            missingCandidateCount: failure?.missingCandidateCount ?? 0,
            lowActiveCandidateCount: failure?.lowActiveCandidateCount ?? 0,
            targetWindowSamples: failure?.systemWindowSamples ?? 0,
            targetPeak: failure?.systemPeak
        ))
        if delaySkipHistory.count > Self.historyLimit {
            delaySkipHistory.removeFirst(delaySkipHistory.count - Self.historyLimit)
        }
    }

    // MARK: - Timing and diagnostics

    private func recordBlockTime(_ duration: Duration) {
        let micros = Self.microseconds(duration)
        blockProcessingCount += 1
        blockProcessingTotalMicros += micros
        maxBlockProcessingMicros = max(maxBlockProcessingMicros, micros)
    }

    private func recordEstimateTime(_ duration: Duration) {
        recentEstimateProcessingMicros.append(Self.microseconds(duration))
        if recentEstimateProcessingMicros.count > Self.estimateTimingLimit {
            recentEstimateProcessingMicros.removeFirst(recentEstimateProcessingMicros.count - Self.estimateTimingLimit)
        }
    }

    private static func microseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds) * 1_000_000 + Int(components.attoseconds / 1_000_000_000_000)
    }

    var diagnosticsSnapshot: MeetingReverseLeakDiagnosticsSnapshot {
        MeetingReverseLeakDiagnosticsSnapshot(
            enabled: isEnabled,
            lockedDelayMs: lockedDelayMs,
            delayHistory: delayHistory,
            delaySkipHistory: delaySkipHistory,
            lockCount: lockCount,
            relockCount: relockCount,
            resetCount: resetCount,
            gapResetCount: gapResetCount,
            gateOpenCount: gateOpenCount,
            suppressedSeconds: Double(suppressedSamples) / Double(Self.sampleRate),
            referenceUnavailableFrames: referenceUnavailableFrames,
            intervalCount: closedIntervals.count + (openInterval == nil ? 0 : 1),
            offsetSpreadMs: (maximumObservedDelayMs ?? 0) - (minimumObservedDelayMs ?? 0),
            meanBlockProcessingMicros: blockProcessingCount > 0
                ? Double(blockProcessingTotalMicros) / Double(blockProcessingCount)
                : 0,
            maxBlockProcessingMicros: maxBlockProcessingMicros
        )
    }

    // MARK: - Envelope history

    /// Position-indexed 20 ms RMS envelope frames with a sample accumulator aligned to the
    /// 320-sample timeline grid. Gaps up to the retention length are zero-filled; a larger gap
    /// resets the history (the caller counts it). Retains only the last `retentionFrames`.
    private struct EnvelopeHistory {
        let retentionFrames: Int
        private(set) var values: [Float] = []
        private(set) var startFrame = 0
        private(set) var framesReceived = 0
        private var pending: [Float] = []
        private var nextPosition: Int?
        private var skipUntilAligned = 0

        init(retentionFrames: Int) {
            self.retentionFrames = retentionFrames
        }

        var endFrame: Int { startFrame + values.count }
        var isEmpty: Bool { values.isEmpty }

        func value(at frame: Int) -> Float? {
            let index = frame - startFrame
            guard index >= 0, index < values.count else { return nil }
            return values[index]
        }

        /// Frames in `range`, zero outside the retained history.
        func slice(_ range: Range<Int>) -> [Float] {
            range.map { value(at: $0) ?? 0 }
        }

        /// Moves the cursor to `position`; returns the leading samples already covered (overlap)
        /// and whether the gap was too large to fill.
        mutating func reconcile(position: Int, count: Int) -> (drop: Int, didReset: Bool) {
            guard let cursor = nextPosition else {
                restart(at: position)
                return (0, false)
            }
            if position == cursor {
                return (0, false)
            }
            if position < cursor {
                return (min(cursor - position, count), false)
            }
            let gap = position - cursor
            if gap <= retentionFrames * MeetingReverseLeakSuppressor.frameLength {
                _ = append([Float](repeating: 0, count: gap))
                return (0, false)
            }
            restart(at: position)
            return (0, true)
        }

        private mutating func restart(at position: Int) {
            values.removeAll(keepingCapacity: true)
            pending.removeAll(keepingCapacity: true)
            let frameLength = MeetingReverseLeakSuppressor.frameLength
            startFrame = (position + frameLength - 1) / frameLength
            skipUntilAligned = startFrame * frameLength - position
            nextPosition = position
        }

        /// Appends filtered samples at the cursor and returns the frames completed.
        mutating func append(_ samples: [Float]) -> [(frame: Int, value: Float)] {
            nextPosition = (nextPosition ?? 0) + samples.count
            var input = samples[...]
            if skipUntilAligned > 0 {
                let skipped = min(skipUntilAligned, input.count)
                input = input.dropFirst(skipped)
                skipUntilAligned -= skipped
            }
            guard !input.isEmpty else { return [] }

            let frameLength = MeetingReverseLeakSuppressor.frameLength
            var completed: [(frame: Int, value: Float)] = []
            var buffer: [Float]
            if pending.isEmpty {
                buffer = Array(input)
            } else {
                buffer = pending
                buffer.append(contentsOf: input)
                pending.removeAll(keepingCapacity: true)
            }
            let frameCount = buffer.count / frameLength
            if frameCount > 0 {
                buffer.withUnsafeBufferPointer { pointer in
                    guard let base = pointer.baseAddress else { return }
                    for frame in 0..<frameCount {
                        var rms: Float = 0
                        vDSP_rmsqv(base + frame * frameLength, 1, &rms, vDSP_Length(frameLength))
                        completed.append((endFrame + frame, rms))
                    }
                }
                values.append(contentsOf: completed.map(\.value))
                framesReceived += frameCount
            }
            let remainder = buffer.count - frameCount * frameLength
            if remainder > 0 {
                pending = Array(buffer[(frameCount * frameLength)...])
            }
            if values.count > retentionFrames {
                let excess = values.count - retentionFrames
                values.removeFirst(excess)
                startFrame += excess
            }
            return completed
        }

        mutating func removeAll() {
            values.removeAll(keepingCapacity: true)
            pending.removeAll(keepingCapacity: true)
            startFrame = 0
            framesReceived = 0
            nextPosition = nil
            skipUntilAligned = 0
        }
    }

    /// Minimum statistics over fixed 1.5 s sub-windows held in a bounded ring, clamped at -60 dBFS.
    private struct FloorTracker {
        static let subWindowFrames = 75
        static let ringCapacity = 8

        private var minima: [Float] = []
        private var nextIndex = 0
        private var currentMinimum = Float.greatestFiniteMagnitude
        private var currentCount = 0

        var floor: Float {
            var minimum = minima.min() ?? Float.greatestFiniteMagnitude
            if minima.isEmpty, currentCount > 0 {
                minimum = currentMinimum
            }
            guard minimum < Float.greatestFiniteMagnitude else { return MeetingReverseLeakSuppressor.floorClampRms }
            return max(minimum, MeetingReverseLeakSuppressor.floorClampRms)
        }

        mutating func observe(_ value: Float) {
            currentMinimum = min(currentMinimum, value)
            currentCount += 1
            guard currentCount >= Self.subWindowFrames else { return }
            if minima.count < Self.ringCapacity {
                minima.append(currentMinimum)
            } else {
                minima[nextIndex] = currentMinimum
            }
            nextIndex = (nextIndex + 1) % Self.ringCapacity
            currentMinimum = Float.greatestFiniteMagnitude
            currentCount = 0
        }
    }

    /// Fixed-size ring of system-to-reference envelope ratios for confirmed leak frames.
    private struct LeakGainRing {
        let capacity: Int
        private var values: [Float] = []
        private var nextIndex = 0
        private var cachedMedian: Float?

        init(capacity: Int) {
            self.capacity = capacity
        }

        var count: Int { values.count }

        mutating func push(_ value: Float) {
            guard value.isFinite else { return }
            if values.count < capacity {
                values.append(value)
            } else {
                values[nextIndex] = value
            }
            nextIndex = (nextIndex + 1) % capacity
            cachedMedian = nil
        }

        mutating func median() -> Float? {
            guard !values.isEmpty else { return nil }
            if let cachedMedian { return cachedMedian }
            let sorted = values.sorted()
            let median = sorted[sorted.count / 2]
            cachedMedian = median
            return median
        }

        mutating func removeAll() {
            values.removeAll(keepingCapacity: true)
            nextIndex = 0
            cachedMedian = nil
        }
    }
}
