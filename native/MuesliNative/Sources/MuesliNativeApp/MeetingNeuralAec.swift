import Accelerate
import DTLNAecCoreML
import Foundation
import os

protocol MeetingAecProcessor: AnyObject {
    var name: String { get }
    var frameSize: Int { get }
    var sampleRate: Int { get }
    func reset()
    func processFrame(mic: [Float], reference: [Float]) throws -> [Float]
}

enum MeetingAecModelBundle {
    static let bundleName = "DTLNAecCoreML_DTLNAec512.bundle"

    static func resolve(
        mainBundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> Bundle {
        let candidates = candidateURLs(mainBundle: mainBundle)

        for url in candidates {
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }

        let searched = candidates.map(\.path).joined(separator: ", ")
        throw NSError(
            domain: "MeetingAecModelBundle",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate \(bundleName) in: \(searched)"]
        )
    }

    static func candidateURLs(mainBundle: Bundle = .main) -> [URL] {
        let rawCandidates = [
            mainBundle.resourceURL?.appendingPathComponent(bundleName, isDirectory: true),
            mainBundle.bundleURL.appendingPathComponent(bundleName, isDirectory: true),
            mainBundle.executableURL?.deletingLastPathComponent().appendingPathComponent(bundleName, isDirectory: true),
        ].compactMap { $0 }

        var seen = Set<String>()
        return rawCandidates.filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }
}

final class DTLNMeetingAecProcessor: MeetingAecProcessor {
    let name = "dtln"
    let frameSize = 512
    let sampleRate = 16_000
    private let processor: DTLNAecEchoProcessor

    private init(processor: DTLNAecEchoProcessor) {
        self.processor = processor
    }

    static func load() async throws -> DTLNMeetingAecProcessor {
        let proc = DTLNAecEchoProcessor(modelSize: .large)
        try await proc.loadModelsAsync(from: MeetingAecModelBundle.resolve())
        return DTLNMeetingAecProcessor(processor: proc)
    }

    func reset() {
        processor.resetStates()
    }

    func processFrame(mic: [Float], reference: [Float]) throws -> [Float] {
        processor.feedFarEnd(reference)
        return processor.processNearEnd(mic)
    }
}

enum MeetingAecProcessorSelection {
    case production
    case localVQEStrict
    case dtlnOnly

    static var environmentDefault: MeetingAecProcessorSelection {
        switch ProcessInfo.processInfo.environment["MUESLI_AEC_PROCESSOR"]?.lowercased() {
        case "dtln":
            return .dtlnOnly
        case "localvqe-strict":
            return .localVQEStrict
        default:
            return .production
        }
    }
}

final class MeetingNeuralAec {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingAec")

    private var processor: MeetingAecProcessor?
    private var isLoaded = false

    private var frameSize = 256
    private let sampleRate = 16_000
    private let selection: MeetingAecProcessorSelection
    private var lastProcessingError: String?

    // Accessed only from MeetingSession's chunkRotationQueue.
    //
    // Mic and CoreAudio tap callbacks are delivered on independent queues. Keep
    // mic frames pending and system audio in a history buffer so the AEC model
    // can receive the far-end frame that matches the mic frame's sample position.
    private var pendingMicSamples: [Float] = []
    private var pendingMicStartSample: Int = 0
    private var systemHistory: [Float] = []
    private var systemTimelineStartSample: Int?
    private var systemHistoryStartSample: Int = 0
    private var micHistory: [Float] = []
    private var micHistoryStartSample: Int = 0
    private var systemSamplesReceived: Int = 0
    private var micSamplesReceived: Int = 0
    private var processedFrames = 0
    private var fullReferenceFrames = 0
    private var partialReferenceFrames = 0
    private var missingReferenceFrames = 0
    private let delayEstimator = MeetingAecDelayEstimator()
    private var currentDelaySamples = 0
    private var nextDelayEstimateSample = 8_000
    private var recentDelayResults: [MeetingAecDelayEstimator.Result] = []
    private var delayHistory: [MeetingAecDelayObservation] = []
    private var delaySkipHistory: [MeetingAecDelaySkip] = []
    private let maxReferenceWaitSamples = 48_000

    init(selection: MeetingAecProcessorSelection = .environmentDefault) {
        self.selection = selection
    }

    init(preloadedProcessor processor: MeetingAecProcessor) {
        self.selection = .production
        self.processor = processor
        self.frameSize = processor.frameSize
        self.isLoaded = true
    }

    /// Pre-load the meeting AEC processor so it's ready for processing.
    func preload() async {
        guard !isLoaded else { return }

        if selection != .dtlnOnly {
            do {
                let localVQE = try await LocalVQEAudioProcessor.load()
                processor = localVQE
                frameSize = localVQE.frameSize
                isLoaded = true
                let libraryName = URL(fileURLWithPath: localVQE.libraryPath).lastPathComponent
                let modelName = URL(fileURLWithPath: localVQE.modelPath).lastPathComponent
                Self.logger.info("LocalVQE preloaded (frameSize=\(localVQE.frameSize, privacy: .public), library=\(libraryName, privacy: .public), model=\(modelName, privacy: .public))")
                return
            } catch {
                if selection == .localVQEStrict {
                    Self.logger.error("LocalVQE preload failed in strict mode (no DTLN fallback): \(String(describing: error), privacy: .private)")
                    return
                }
                Self.logger.error("LocalVQE preload failed; falling back to DTLN: \(String(describing: error), privacy: .private)")
            }
        }

        do {
            let dtln = try await DTLNMeetingAecProcessor.load()
            processor = dtln
            frameSize = dtln.frameSize
            isLoaded = true
            Self.logger.info("DTLN-aec model preloaded (frameSize=\(dtln.frameSize, privacy: .public))")
        } catch {
            Self.logger.error("DTLN-aec preload failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// Reset processor state and streaming buffers for a new meeting.
    func resetForStreaming() {
        processor?.reset()
        pendingMicSamples.removeAll(keepingCapacity: true)
        pendingMicStartSample = 0
        systemHistory.removeAll(keepingCapacity: true)
        systemTimelineStartSample = nil
        systemHistoryStartSample = 0
        micHistory.removeAll(keepingCapacity: true)
        micHistoryStartSample = 0
        systemSamplesReceived = 0
        micSamplesReceived = 0
        processedFrames = 0
        fullReferenceFrames = 0
        partialReferenceFrames = 0
        missingReferenceFrames = 0
        currentDelaySamples = 0
        nextDelayEstimateSample = sampleRate / 2
        recentDelayResults.removeAll(keepingCapacity: true)
        delayHistory.removeAll(keepingCapacity: true)
        delaySkipHistory.removeAll(keepingCapacity: true)
        lastProcessingError = nil
    }

    /// Buffer system audio samples indexed by absolute position.
    func feedSystemSamples(_ samples: [Float]) {
        if systemTimelineStartSample == nil {
            systemTimelineStartSample = 0
            systemHistoryStartSample = 0
        }
        systemHistory.append(contentsOf: samples)
        systemSamplesReceived += samples.count
        updateDelayEstimateIfNeeded()
        trimHistoryBuffersIfNeeded()
    }

    /// Process mic samples through the loaded AEC processor using the currently estimated far-end delay.
    func processStreamingMic(_ micSamples: [Float]) -> [Float] {
        // Always maintain history so trimHistoryBuffersIfNeeded() keeps the buffer bounded
        // regardless of whether the model is loaded. The delay estimator also benefits
        // from having data when the model finishes preloading.
        micHistory.append(contentsOf: micSamples)
        micSamplesReceived += micSamples.count
        updateDelayEstimateIfNeeded()

        guard let processor else {
            fputs("[meeting-aec] processor not loaded, passing through raw mic audio\n", stderr)
            trimHistoryBuffersIfNeeded()
            return micSamples
        }

        pendingMicSamples.append(contentsOf: micSamples)
        return processQueuedFrames(processor: processor, flush: false)
    }

    var micHistoryCount: Int { micHistory.count }

    /// Flush remaining buffered mic samples (zero-padded to frame boundary).
    func flushStreamingMic() -> [Float] {
        guard let processor, !pendingMicSamples.isEmpty else { return [] }
        return processQueuedFrames(processor: processor, flush: true)
    }

    private func referenceDelaySamples(for processor: MeetingAecProcessor? = nil) -> Int {
        let activeProcessor = processor ?? self.processor
        return activeProcessor?.name == "localvqe" ? 0 : currentDelaySamples
    }

    private func processQueuedFrames(processor: MeetingAecProcessor, flush: Bool) -> [Float] {
        var cleaned: [Float] = []
        cleaned.reserveCapacity(pendingMicSamples.count)

        while pendingMicSamples.count >= frameSize {
            if !flush,
               !canProcessFrameStartingAt(pendingMicStartSample, processor: processor),
               pendingMicSamples.count <= maxReferenceWaitSamples {
                break
            }

            let micFrame = Array(pendingMicSamples.prefix(frameSize))
            pendingMicSamples.removeFirst(frameSize)

            let systemFrame = systemFrame(forMicFrameStartingAt: pendingMicStartSample, processor: processor)
            autoreleasepool {
                do {
                    cleaned.append(contentsOf: try processor.processFrame(mic: micFrame, reference: systemFrame))
                } catch {
                    lastProcessingError = "\(error)"
                    fputs("[meeting-aec] \(processor.name) processing failed: \(error); passing through raw frame\n", stderr)
                    cleaned.append(contentsOf: micFrame)
                }
            }

            pendingMicStartSample += frameSize
            processedFrames += 1
        }

        if flush, !pendingMicSamples.isEmpty {
            let actualCount = pendingMicSamples.count
            let micFrame = pendingMicSamples + [Float](repeating: 0, count: frameSize - actualCount)
            pendingMicSamples.removeAll(keepingCapacity: true)

            let systemFrame = systemFrame(forMicFrameStartingAt: pendingMicStartSample, processor: processor)
            var cleanedFrame: [Float] = []
            autoreleasepool {
                do {
                    cleanedFrame = try processor.processFrame(mic: micFrame, reference: systemFrame)
                } catch {
                    lastProcessingError = "\(error)"
                    fputs("[meeting-aec] \(processor.name) flush processing failed: \(error); passing through raw frame\n", stderr)
                    cleanedFrame = micFrame
                }
            }
            cleaned.append(contentsOf: cleanedFrame.prefix(actualCount))
            pendingMicStartSample += actualCount
            processedFrames += 1
        }

        trimHistoryBuffersIfNeeded()
        return cleaned
    }

    private func canProcessFrameStartingAt(_ micStart: Int, processor: MeetingAecProcessor) -> Bool {
        let referenceEnd = micStart - referenceDelaySamples(for: processor) + frameSize
        if referenceEnd <= 0 {
            return true
        }
        return referenceEnd <= systemAbsoluteEndSample
    }

    private var systemAbsoluteEndSample: Int {
        (systemTimelineStartSample ?? 0) + systemSamplesReceived
    }

    private func systemFrame(forMicFrameStartingAt micStart: Int, processor: MeetingAecProcessor) -> [Float] {
        let referenceStart = micStart - referenceDelaySamples(for: processor)
        let referenceEnd = referenceStart + frameSize
        let systemEndSample = systemAbsoluteEndSample

        if referenceStart >= systemHistoryStartSample, referenceEnd <= systemEndSample {
            let startIndex = referenceStart - systemHistoryStartSample
            let frame = Array(systemHistory[startIndex..<(startIndex + frameSize)])
            fullReferenceFrames += 1
            return frame
        }

        let overlapStart = max(referenceStart, systemHistoryStartSample)
        let overlapEnd = min(referenceEnd, systemEndSample)
        guard overlapStart < overlapEnd else {
            missingReferenceFrames += 1
            return [Float](repeating: 0, count: frameSize)
        }

        var frame = [Float](repeating: 0, count: frameSize)
        let sourceStartIndex = overlapStart - systemHistoryStartSample
        let destinationStartIndex = overlapStart - referenceStart
        let overlapCount = overlapEnd - overlapStart
        frame.replaceSubrange(
            destinationStartIndex..<(destinationStartIndex + overlapCount),
            with: systemHistory[sourceStartIndex..<(sourceStartIndex + overlapCount)]
        )
        partialReferenceFrames += 1
        return frame
    }

    private func updateDelayEstimateIfNeeded() {
        // The live estimator is gated by mic sample position because each
        // candidate compares a mic window against the already captured system
        // history. System callbacks may call this too, but cannot advance the
        // gate without new mic samples to compare.
        guard micSamplesReceived >= nextDelayEstimateSample else { return }

        let maxCandidateDelaySamples = delayEstimator.maxCandidateDelaySamples
        let latestComparableSystemSample = min(systemAbsoluteEndSample, micSamplesReceived - maxCandidateDelaySamples)
        guard latestComparableSystemSample > 0 else {
            recordDelaySkip(
                reason: "waitingForComparableSystemAudio",
                comparableEndSample: nil,
                failure: nil
            )
            nextDelayEstimateSample = micSamplesReceived + delayEstimator.estimateIntervalSamples
            return
        }

        defer {
            nextDelayEstimateSample = micSamplesReceived + delayEstimator.estimateIntervalSamples
        }

        let attempt = delayEstimator.estimateAttempt(
            micHistory: micHistory,
            micHistoryStartSample: micHistoryStartSample,
            systemHistory: systemHistory,
            systemHistoryStartSample: systemHistoryStartSample,
            comparableEndSample: latestComparableSystemSample
        )

        guard case let .result(result) = attempt else {
            if case let .failure(failure) = attempt {
                recordDelaySkip(
                    reason: failure.reason,
                    comparableEndSample: latestComparableSystemSample,
                    failure: failure
                )
            }
            return
        }

        if result.score >= 0.55 {
            recentDelayResults.append(result)
            if recentDelayResults.count > 7 {
                recentDelayResults.removeFirst(recentDelayResults.count - 7)
            }
        }

        let decision = delayDecision(for: result)
        if decision.shouldApply {
            currentDelaySamples = decision.reason == "acceptedRepeatedSupport"
                ? MeetingAecDelayEstimator.recencyWeightedMedianDelay(from: recentDelayResults)
                : result.delaySamples
        }

        recordDelayObservation(result, decision: decision.reason)
    }

    private func trimHistoryBuffersIfNeeded() {
        let maxCandidateDelaySamples = delayEstimator.maxCandidateDelaySamples
        let retentionSamples = delayEstimator.windowSamples + maxCandidateDelaySamples
        let latestComparableSystemSample = min(systemAbsoluteEndSample, micSamplesReceived - maxCandidateDelaySamples)
        let oldestNeededForEstimator = latestComparableSystemSample > 0
            ? max(0, latestComparableSystemSample - delayEstimator.windowSamples)
            : max(0, systemSamplesReceived - retentionSamples)
        // AEC constraint: only protect system samples that queued mic frames actually need.
        // When the pending buffer is empty there is nothing to protect, so trim freely.
        let oldestNeededForAec = pendingMicSamples.isEmpty
            ? systemSamplesReceived
            : max(0, pendingMicStartSample - maxCandidateDelaySamples - frameSize)
        let micRetentionFloor = max(0, micSamplesReceived - retentionSamples)
        let systemRetentionFloor = max(0, systemSamplesReceived - retentionSamples)
        // micHistory is only used by the delay estimator. retentionSamples is sized to hold
        // exactly what the estimator needs, so always cap to it. When system audio is lagging,
        // the estimator cannot use old mic samples anyway.
        trimMicHistory(before: micRetentionFloor)
        // systemHistory is used by both estimator and AEC. systemRetentionFloor already
        // covers the estimator's window (retentionSamples = windowSamples + maxCandidateDelaySamples).
        // Cap at oldestNeededForAec so we never trim frames that queued mic frames still need
        // for echo cancellation — this prevents returning zero/partial references when system
        // audio gets ahead of mic audio during a long mic pause.
        trimSystemHistory(before: min(systemRetentionFloor, oldestNeededForAec))
    }

    private func delayDecision(for result: MeetingAecDelayEstimator.Result) -> (shouldApply: Bool, reason: String) {
        if result.score >= 0.55, result.confidence >= 0.003 {
            return (true, "acceptedConfidence")
        }

        if result.score >= 0.85, result.delayMs >= 160 {
            let baselineScore = result.candidateScores
                .first { $0.delayMs == 0 }?
                .score ?? result.candidateScores.min(by: { $0.delayMs < $1.delayMs })?.score
            if let baselineScore, result.score - baselineScore >= 0.015 {
                return (true, "acceptedBaselineSeparation")
            }
        }

        if result.score >= 0.55, hasConsistentRecentDelaySupport(around: result.delayMs) {
            return (true, "acceptedRepeatedSupport")
        }

        return (false, "rejectedLowConfidence")
    }

    private func hasConsistentRecentDelaySupport(around delayMs: Int) -> Bool {
        let candidates = Array(recentDelayResults.suffix(5))
        guard candidates.count >= 3 else { return false }

        let nearby = candidates.filter { abs($0.delayMs - delayMs) <= 80 }
        return nearby.count >= 3
    }

    private func recordDelayObservation(_ result: MeetingAecDelayEstimator.Result, decision: String) {
        let observation = MeetingAecDelayObservation(
            delayMs: result.delayMs,
            appliedDelayMs: Int(round(Double(currentDelaySamples) * 1000.0 / Double(sampleRate))),
            score: result.score,
            confidence: result.confidence,
            comparedFrames: result.comparedFrames,
            decision: decision,
            candidateScores: result.candidateScores
        )
        delayHistory.append(observation)
        if delayHistory.count > 24 {
            delayHistory.removeFirst(delayHistory.count - 24)
        }
    }

    private func recordDelaySkip(
        reason: String,
        comparableEndSample: Int?,
        failure: MeetingAecDelayEstimator.Failure?
    ) {
        let skip = MeetingAecDelaySkip(
            reason: reason,
            micSamplesReceived: micSamplesReceived,
            systemSamplesReceived: systemSamplesReceived,
            micHistoryStartSample: micHistoryStartSample,
            systemHistoryStartSample: systemHistoryStartSample,
            comparableEndSample: comparableEndSample,
            validCandidateCount: failure?.validCandidateCount ?? 0,
            missingCandidateCount: failure?.missingCandidateCount ?? 0,
            lowActiveCandidateCount: failure?.lowActiveCandidateCount ?? 0,
            systemWindowSamples: failure?.systemWindowSamples ?? 0,
            systemPeak: failure?.systemPeak
        )
        delaySkipHistory.append(skip)
        if delaySkipHistory.count > 24 {
            delaySkipHistory.removeFirst(delaySkipHistory.count - 24)
        }
    }

    private func trimSystemHistory(before samplePosition: Int) {
        let cappedSamplePosition = min(samplePosition, systemAbsoluteEndSample)
        guard cappedSamplePosition > systemHistoryStartSample else { return }
        let removeCount = min(cappedSamplePosition - systemHistoryStartSample, systemHistory.count)
        guard removeCount > 0 else { return }
        systemHistory.removeFirst(removeCount)
        systemHistoryStartSample += removeCount
    }

    private func trimMicHistory(before samplePosition: Int) {
        guard samplePosition > micHistoryStartSample else { return }
        let removeCount = min(samplePosition - micHistoryStartSample, micHistory.count)
        guard removeCount > 0 else { return }
        micHistory.removeFirst(removeCount)
        micHistoryStartSample += removeCount
    }

    /// Whether the model is loaded and ready.
    var isReady: Bool { isLoaded && processor != nil }

    var diagnosticsSnapshot: MeetingAecDiagnosticsSnapshot {
        MeetingAecDiagnosticsSnapshot(
            ready: isReady,
            processor: processor?.name,
            // 0 means unloaded — do not advertise LocalVQE's 256-sample default
            // before preload selects a processor.
            frameSize: processor?.frameSize ?? 0,
            processedFrames: processedFrames,
            fullReferenceFrames: fullReferenceFrames,
            partialReferenceFrames: partialReferenceFrames,
            missingReferenceFrames: missingReferenceFrames,
            systemSamplesReceived: systemSamplesReceived,
            micSamplesReceived: micSamplesReceived,
            bufferedSystemSamples: systemHistory.count,
            bufferedMicSamples: pendingMicSamples.count,
            currentDelayMs: Int(round(Double(currentDelaySamples) * 1000.0 / Double(sampleRate))),
            delayHistory: delayHistory,
            delaySkipHistory: delaySkipHistory
        )
    }
}

struct MeetingAecDelayEstimator {
    enum Attempt {
        case result(Result)
        case failure(Failure)
    }

    struct Result {
        let delaySamples: Int
        let delayMs: Int
        let score: Double
        let confidence: Double
        let comparedFrames: Int
        let candidateScores: [MeetingAecDelayCandidateScore]
        // Envelope-mode outputs (reverse direction). Defaulted trailing `var`s keep the
        // memberwise initializer the forward path and its tests already use.
        var activeReferenceFrames: Int = 0
        var peakRatio: Double = 0
    }

    struct Failure {
        let reason: String
        let validCandidateCount: Int
        let missingCandidateCount: Int
        let lowActiveCandidateCount: Int
        let systemWindowSamples: Int
        let systemPeak: Double?
    }

    static let defaultCandidateDelaysMs = [
        0, 40, 80, 120, 160, 200, 240, 280,
        320, 360, 400, 440, 480, 520, 560, 600, 640,
        720, 800,
    ]

    let sampleRate = 16_000
    let envelopeFrameSize = 320
    let windowSamples = 8 * 16_000
    let estimateIntervalSamples = 2 * 16_000
    let candidateDelaysMs: [Int]
    let envelopeCandidateLagFrames: [Int]

    init(
        candidateDelaysMs: [Int] = Self.defaultCandidateDelaysMs,
        envelopeCandidateLagFrames: [Int] = Self.defaultEnvelopeCandidateLagFrames
    ) {
        self.candidateDelaysMs = candidateDelaysMs
        self.envelopeCandidateLagFrames = envelopeCandidateLagFrames
    }

    var maxCandidateDelaySamples: Int {
        candidateDelaysMs.map(delaySamples(for:)).max() ?? 0
    }

    func estimate(
        micHistory: [Float],
        micHistoryStartSample: Int,
        systemHistory: [Float],
        systemHistoryStartSample: Int,
        comparableEndSample: Int
    ) -> Result? {
        guard case let .result(result) = estimateAttempt(
            micHistory: micHistory,
            micHistoryStartSample: micHistoryStartSample,
            systemHistory: systemHistory,
            systemHistoryStartSample: systemHistoryStartSample,
            comparableEndSample: comparableEndSample
        ) else {
            return nil
        }
        return result
    }

    func estimateAttempt(
        micHistory: [Float],
        micHistoryStartSample: Int,
        systemHistory: [Float],
        systemHistoryStartSample: Int,
        comparableEndSample: Int
    ) -> Attempt {
        let windowEnd = comparableEndSample
        let windowStart = max(0, windowEnd - windowSamples)
        let systemWindow = samples(
            from: systemHistory,
            historyStartSample: systemHistoryStartSample,
            startSample: windowStart,
            endSample: windowEnd
        )
        guard systemWindow.count >= envelopeFrameSize * 25 else {
            return .failure(Failure(
                reason: "insufficientSystemHistory",
                validCandidateCount: 0,
                missingCandidateCount: 0,
                lowActiveCandidateCount: 0,
                systemWindowSamples: systemWindow.count,
                systemPeak: nil
            ))
        }

        let systemEnvelope = rmsEnvelope(systemWindow)
        guard let systemPeak = systemEnvelope.max(), systemPeak > 0.0005 else {
            return .failure(Failure(
                reason: "quietSystemAudio",
                validCandidateCount: 0,
                missingCandidateCount: 0,
                lowActiveCandidateCount: 0,
                systemWindowSamples: systemWindow.count,
                systemPeak: systemEnvelope.max()
            ))
        }

        let activeThreshold = max(systemPeak * 0.18, 0.001)
        var scoredCandidates: [(
            delayMs: Int,
            delaySamples: Int,
            score: Double,
            compared: Int
        )] = []
        var missingCandidateCount = 0
        var lowActiveCandidateCount = 0

        for delayMs in candidateDelaysMs {
            let delaySamples = delaySamples(for: delayMs)
            let micWindow = samples(
                from: micHistory,
                historyStartSample: micHistoryStartSample,
                startSample: windowStart + delaySamples,
                endSample: windowEnd + delaySamples
            )
            guard micWindow.count == systemWindow.count else {
                missingCandidateCount += 1
                continue
            }

            let micEnvelope = rmsEnvelope(micWindow)
            let scored = activeSystemCosineSimilarity(
                micEnvelope: micEnvelope,
                systemEnvelope: systemEnvelope,
                activeThreshold: activeThreshold
            )
            guard scored.comparedFrames >= 25 else {
                lowActiveCandidateCount += 1
                continue
            }
            scoredCandidates.append((delayMs, delaySamples, scored.score, scored.comparedFrames))
        }

        guard let best = scoredCandidates.max(by: { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.compared < rhs.compared
            }
            return lhs.score < rhs.score
        }) else {
            let reason = missingCandidateCount == candidateDelaysMs.count
                ? "missingMicCandidateWindows"
                : "noValidCandidates"
            return .failure(Failure(
                reason: reason,
                validCandidateCount: scoredCandidates.count,
                missingCandidateCount: missingCandidateCount,
                lowActiveCandidateCount: lowActiveCandidateCount,
                systemWindowSamples: systemWindow.count,
                systemPeak: systemPeak
            ))
        }

        let runnerUpScore = scoredCandidates
            .filter { $0.delayMs != best.delayMs }
            .map(\.score)
            .max() ?? 0

        return .result(Result(
            delaySamples: best.delaySamples,
            delayMs: best.delayMs,
            score: best.score,
            confidence: best.score - runnerUpScore,
            comparedFrames: best.compared,
            candidateScores: scoredCandidates.map {
                MeetingAecDelayCandidateScore(
                    delayMs: $0.delayMs,
                    score: $0.score,
                    comparedFrames: $0.compared
                )
            }
        ))
    }

    private func delaySamples(for delayMs: Int) -> Int {
        Int(round(Double(delayMs) * Double(sampleRate) / 1000.0))
    }

    private func samples(
        from history: [Float],
        historyStartSample: Int,
        startSample: Int,
        endSample: Int
    ) -> [Float] {
        guard startSample >= historyStartSample, endSample > startSample else { return [] }
        let startIndex = startSample - historyStartSample
        let endIndex = endSample - historyStartSample
        guard startIndex >= 0, endIndex <= history.count else { return [] }
        return Array(history[startIndex..<endIndex])
    }

    private func rmsEnvelope(_ samples: [Float]) -> [Double] {
        guard envelopeFrameSize > 0 else { return [] }
        var envelope: [Double] = []
        envelope.reserveCapacity(samples.count / envelopeFrameSize)

        var index = 0
        while index + envelopeFrameSize <= samples.count {
            var sumSquares = 0.0
            for sample in samples[index..<(index + envelopeFrameSize)] {
                let value = Double(sample)
                sumSquares += value * value
            }
            envelope.append(sqrt(sumSquares / Double(envelopeFrameSize)))
            index += envelopeFrameSize
        }
        return envelope
    }

    private func activeSystemCosineSimilarity(
        micEnvelope: [Double],
        systemEnvelope: [Double],
        activeThreshold: Double
    ) -> (score: Double, comparedFrames: Int) {
        let comparedFrames = min(micEnvelope.count, systemEnvelope.count)
        guard comparedFrames > 0 else { return (0, 0) }

        var dot = 0.0
        var micNorm = 0.0
        var systemNorm = 0.0
        var activeFrames = 0

        for index in 0..<comparedFrames where systemEnvelope[index] >= activeThreshold {
            let mic = micEnvelope[index]
            let system = systemEnvelope[index]
            dot += mic * system
            micNorm += mic * mic
            systemNorm += system * system
            activeFrames += 1
        }

        guard activeFrames > 0, micNorm > 0, systemNorm > 0 else {
            return (0, activeFrames)
        }
        return (dot / sqrt(micNorm * systemNorm), activeFrames)
    }

    static func recencyWeightedMedianDelay(from results: [Result]) -> Int {
        guard !results.isEmpty else { return 0 }
        let weighted = results.enumerated().map { index, result in
            (delaySamples: result.delaySamples, weight: Double(index + 1))
        }
        let totalWeight = weighted.reduce(0) { $0 + $1.weight }
        let midpoint = totalWeight / 2.0
        var cumulative = 0.0
        for item in weighted.sorted(by: { $0.delaySamples < $1.delaySamples }) {
            cumulative += item.weight
            if cumulative > midpoint {
                return item.delaySamples
            }
        }
        return weighted.last?.delaySamples ?? 0
    }
}

// MARK: - Envelope-domain scoring (reverse direction)

extension MeetingAecDelayEstimator {
    /// Envelope frame length in samples (20 ms at 16 kHz); equals the forward `envelopeFrameSize`.
    static let envelopeFrameLength = 320
    static let envelopeFrameDurationMs = 20
    /// 8 s window expressed in envelope frames.
    static let envelopeWindowFrames = 400
    /// 80 ms ... 2000 ms at 20 ms steps: 97 lags.
    static let defaultEnvelopeCandidateLagFrames: [Int] = Array(4...100)
    /// 1.5 s of active reference audio inside the window.
    static let envelopeMinimumActiveReferenceFrames = 75
    static let envelopeMinimumPeakScore = 0.6
    static let envelopeMinimumPeakRatio = 1.3
    /// The runner-up is searched outside this many grid steps around the peak.
    static let envelopeRunnerUpExclusionSteps = 2
    static let envelopeQuietPeak: Float = 0.0005
    /// Floor for the runner-up score so a strong peak with a non-positive runner-up
    /// yields a large finite ratio instead of infinity.
    static let envelopeRunnerUpFloor = 0.01

    /// Scores precomputed 20 ms envelopes with zero-mean Pearson correlation over the
    /// candidate lag grid. Positive lag means the near end trails the reference
    /// (system[t] echoes cleanedMic[t - lag]).
    ///
    /// The Pearson pairs are `(reference[i], nearEnd[i + lag])` for every `i` where
    /// `referenceMask[i]` is true (`nil` means every frame is eligible); silence frames stay in
    /// so the on/off structure of speech contributes to the correlation. The mask is the
    /// exclusion hook for forward-residual frames. Active reference frames are the eligible
    /// frames whose envelope is at or above `activeThreshold`.
    ///
    /// Failure reasons are reverse-only strings; the forward reasons are untouched. The
    /// `Failure` slots map as: `validCandidateCount` scored lags, `missingCandidateCount`
    /// lags without any pair, `lowActiveCandidateCount` lags with too few pairs,
    /// `systemWindowSamples` near-end frames times the frame length, `systemPeak` near-end peak.
    func scoreEnvelopes(
        reference: [Float],
        nearEnd: [Float],
        referenceMask: [Bool]?,
        activeThreshold: Float
    ) -> Attempt {
        let frameCount = min(reference.count, nearEnd.count)
        let nearEndWindowSamples = nearEnd.count * Self.envelopeFrameLength
        let nearEndPeak = nearEnd.max().map(Double.init)

        guard frameCount >= Self.envelopeMinimumActiveReferenceFrames else {
            return .failure(Failure(
                reason: "insufficientEnvelopeHistory",
                validCandidateCount: 0,
                missingCandidateCount: 0,
                lowActiveCandidateCount: 0,
                systemWindowSamples: nearEndWindowSamples,
                systemPeak: nearEndPeak
            ))
        }
        guard let nearEndPeak, nearEndPeak > Double(Self.envelopeQuietPeak) else {
            return .failure(Failure(
                reason: "quietNearEndAudio",
                validCandidateCount: 0,
                missingCandidateCount: 0,
                lowActiveCandidateCount: 0,
                systemWindowSamples: nearEndWindowSamples,
                systemPeak: nearEndPeak
            ))
        }

        var mask = [Double](repeating: 1, count: frameCount)
        if let referenceMask {
            for index in 0..<min(frameCount, referenceMask.count) where !referenceMask[index] {
                mask[index] = 0
            }
        }
        var activeReferenceFrames = 0
        for index in 0..<frameCount where mask[index] != 0 && reference[index] >= activeThreshold {
            activeReferenceFrames += 1
        }
        guard activeReferenceFrames >= Self.envelopeMinimumActiveReferenceFrames else {
            return .failure(Failure(
                reason: "insufficientActiveReference",
                validCandidateCount: 0,
                missingCandidateCount: 0,
                lowActiveCandidateCount: 0,
                systemWindowSamples: nearEndWindowSamples,
                systemPeak: nearEndPeak
            ))
        }

        // Per-lag work is six vDSP reductions over these arrays; nothing is sliced or copied per lag.
        let x = reference.prefix(frameCount).map(Double.init)
        let y = nearEnd.prefix(frameCount).map(Double.init)
        let count = vDSP_Length(frameCount)
        var xm = [Double](repeating: 0, count: frameCount)
        var x2m = [Double](repeating: 0, count: frameCount)
        var y2 = [Double](repeating: 0, count: frameCount)
        vDSP_vmulD(x, 1, mask, 1, &xm, 1, count)
        vDSP_vmulD(xm, 1, x, 1, &x2m, 1, count)
        vDSP_vmulD(y, 1, y, 1, &y2, 1, count)

        var scored: [(lagFrames: Int, score: Double, compared: Int)] = []
        var missingCandidateCount = 0
        var lowActiveCandidateCount = 0

        for lagFrames in envelopeCandidateLagFrames {
            let pairs = frameCount - lagFrames
            guard pairs > 0 else {
                missingCandidateCount += 1
                continue
            }
            let statistics = Self.maskedPairStatistics(
                mask: mask, xm: xm, x2m: x2m, y: y, y2: y2, lag: lagFrames, pairs: pairs
            )
            let compared = Int(statistics.count.rounded())
            guard compared >= Self.envelopeMinimumActiveReferenceFrames else {
                lowActiveCandidateCount += 1
                continue
            }
            scored.append((lagFrames, Self.pearson(statistics), compared))
        }

        guard let best = scored.max(by: { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.compared < rhs.compared
            }
            return lhs.score < rhs.score
        }) else {
            return .failure(Failure(
                reason: "noValidCandidates",
                validCandidateCount: 0,
                missingCandidateCount: missingCandidateCount,
                lowActiveCandidateCount: lowActiveCandidateCount,
                systemWindowSamples: nearEndWindowSamples,
                systemPeak: nearEndPeak
            ))
        }

        let gridStep = Self.gridStep(of: envelopeCandidateLagFrames)
        let exclusion = Self.envelopeRunnerUpExclusionSteps * gridStep
        let runnerUpScore = scored
            .filter { abs($0.lagFrames - best.lagFrames) > exclusion }
            .map(\.score)
            .max() ?? 0
        let peakRatio = best.score / max(runnerUpScore, Self.envelopeRunnerUpFloor)

        let reason: String?
        if best.score < Self.envelopeMinimumPeakScore {
            reason = "lowPeakCorrelation"
        } else if peakRatio < Self.envelopeMinimumPeakRatio {
            reason = "ambiguousPeak"
        } else {
            reason = nil
        }
        if let reason {
            return .failure(Failure(
                reason: reason,
                validCandidateCount: scored.count,
                missingCandidateCount: missingCandidateCount,
                lowActiveCandidateCount: lowActiveCandidateCount,
                systemWindowSamples: nearEndWindowSamples,
                systemPeak: nearEndPeak
            ))
        }

        let delayMs = best.lagFrames * Self.envelopeFrameDurationMs
        return .result(Result(
            delaySamples: best.lagFrames * Self.envelopeFrameLength,
            delayMs: delayMs,
            score: best.score,
            confidence: best.score - runnerUpScore,
            comparedFrames: best.compared,
            candidateScores: scored.map {
                MeetingAecDelayCandidateScore(
                    delayMs: $0.lagFrames * Self.envelopeFrameDurationMs,
                    score: $0.score,
                    comparedFrames: $0.compared
                )
            },
            activeReferenceFrames: activeReferenceFrames,
            peakRatio: peakRatio
        ))
    }

    /// Non-overlapping RMS frames; a trailing partial frame is dropped.
    static func rmsEnvelope(of samples: [Float], frameSize: Int = envelopeFrameLength) -> [Float] {
        guard frameSize > 0, samples.count >= frameSize else { return [] }
        let frameCount = samples.count / frameSize
        var envelope = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for frame in 0..<frameCount {
                vDSP_rmsqv(base + frame * frameSize, 1, &envelope[frame], vDSP_Length(frameSize))
            }
        }
        return envelope
    }

    /// Subtracts the array mean.
    static func zeroMeaned(_ envelope: [Float]) -> [Float] {
        guard !envelope.isEmpty else { return [] }
        var mean: Float = 0
        vDSP_meanv(envelope, 1, &mean, vDSP_Length(envelope.count))
        var negatedMean = -mean
        var centered = [Float](repeating: 0, count: envelope.count)
        vDSP_vsadd(envelope, 1, &negatedMean, &centered, 1, vDSP_Length(envelope.count))
        return centered
    }

    private struct MaskedPairStatistics {
        var count = 0.0
        var sumX = 0.0
        var sumY = 0.0
        var sumXX = 0.0
        var sumYY = 0.0
        var sumXY = 0.0
    }

    private static func maskedPairStatistics(
        mask: [Double], xm: [Double], x2m: [Double], y: [Double], y2: [Double], lag: Int, pairs: Int
    ) -> MaskedPairStatistics {
        var statistics = MaskedPairStatistics()
        let length = vDSP_Length(pairs)
        mask.withUnsafeBufferPointer { maskBuffer in
            xm.withUnsafeBufferPointer { xmBuffer in
                x2m.withUnsafeBufferPointer { x2mBuffer in
                    y.withUnsafeBufferPointer { yBuffer in
                        y2.withUnsafeBufferPointer { y2Buffer in
                            guard let maskBase = maskBuffer.baseAddress,
                                  let xmBase = xmBuffer.baseAddress,
                                  let x2mBase = x2mBuffer.baseAddress,
                                  let yBase = yBuffer.baseAddress,
                                  let y2Base = y2Buffer.baseAddress
                            else { return }
                            vDSP_sveD(maskBase, 1, &statistics.count, length)
                            vDSP_sveD(xmBase, 1, &statistics.sumX, length)
                            vDSP_sveD(x2mBase, 1, &statistics.sumXX, length)
                            vDSP_dotprD(maskBase, 1, yBase + lag, 1, &statistics.sumY, length)
                            vDSP_dotprD(maskBase, 1, y2Base + lag, 1, &statistics.sumYY, length)
                            vDSP_dotprD(xmBase, 1, yBase + lag, 1, &statistics.sumXY, length)
                        }
                    }
                }
            }
        }
        return statistics
    }

    private static func pearson(_ s: MaskedPairStatistics) -> Double {
        guard s.count > 1 else { return 0 }
        let covariance = s.sumXY - s.sumX * s.sumY / s.count
        let varianceX = s.sumXX - s.sumX * s.sumX / s.count
        let varianceY = s.sumYY - s.sumY * s.sumY / s.count
        guard varianceX > 1e-12, varianceY > 1e-12 else { return 0 }
        return covariance / (varianceX * varianceY).squareRoot()
    }

    private static func gridStep(of lags: [Int]) -> Int {
        let sorted = lags.sorted()
        var step = Int.max
        for index in 1..<max(sorted.count, 1) {
            let difference = sorted[index] - sorted[index - 1]
            if difference > 0 {
                step = min(step, difference)
            }
        }
        return step == Int.max ? 1 : step
    }
}

/// Streaming second-order Butterworth high-pass (about 250 Hz) that band-limits audio before
/// envelope extraction, so low-frequency room rumble does not drive the correlation.
/// Not thread-safe: owned by the reverse suppressor and used only on MeetingSession's chunkRotationQueue.
final class MeetingAecEnvelopeHighPassFilter {
    private let setup: vDSP_biquad_Setup
    private var delay: [Float]

    init(cutoffHz: Double = 250, sampleRate: Double = 16_000) {
        let omega = 2 * Double.pi * cutoffHz / sampleRate
        let cosOmega = cos(omega)
        let alpha = sin(omega) / 2.0.squareRoot() // sin(w0) / (2Q) with Butterworth Q = 1/sqrt(2)
        let a0 = 1 + alpha
        let coefficients: [Double] = [
            (1 + cosOmega) / 2 / a0,
            -(1 + cosOmega) / a0,
            (1 + cosOmega) / 2 / a0,
            -2 * cosOmega / a0,
            (1 - alpha) / a0,
        ]
        guard let setup = vDSP_biquad_CreateSetup(coefficients, 1) else {
            preconditionFailure("vDSP_biquad_CreateSetup failed")
        }
        self.setup = setup
        delay = [Float](repeating: 0, count: 2 * 1 + 2)
    }

    deinit {
        vDSP_biquad_DestroySetup(setup)
    }

    /// Filters one block, carrying the filter state into the next call.
    func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        var output = [Float](repeating: 0, count: input.count)
        vDSP_biquad(setup, &delay, input, 1, &output, 1, vDSP_Length(input.count))
        return output
    }

    func reset() {
        for index in delay.indices {
            delay[index] = 0
        }
    }
}
