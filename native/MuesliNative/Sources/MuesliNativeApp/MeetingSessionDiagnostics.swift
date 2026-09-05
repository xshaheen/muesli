import FluidAudio
import Foundation
import os

struct AudioSampleStatsSnapshot: Codable {
    let sampleCount: Int
    let zeroSampleCount: Int
    let rms: Double
    let peak: Double
}

struct AudioSampleStats: Codable {
    private(set) var sampleCount = 0
    private(set) var zeroSampleCount = 0
    private(set) var sumSquares: Double = 0
    private(set) var peak: Double = 0

    mutating func addInt16(_ samples: [Int16]) {
        for sample in samples {
            addInt16Sample(sample)
        }
    }

    mutating func addInt16Sample(_ sample: Int16) {
        let value = Double(sample) / 32768.0
        addNormalizedSample(value)
    }

    mutating func addFloats(_ samples: [Float]) {
        for sample in samples {
            addNormalizedSample(Double(sample))
        }
    }

    private mutating func addNormalizedSample(_ sample: Double) {
        sampleCount += 1
        if sample == 0 {
            zeroSampleCount += 1
        }
        sumSquares += sample * sample
        peak = max(peak, abs(sample))
    }

    func snapshot() -> AudioSampleStatsSnapshot {
        AudioSampleStatsSnapshot(
            sampleCount: sampleCount,
            zeroSampleCount: zeroSampleCount,
            rms: sampleCount > 0 ? sqrt(sumSquares / Double(sampleCount)) : 0,
            peak: peak
        )
    }
}

enum MeetingMicSignalClassifier {
    static let nonZeroPeakThreshold = 0.0001
    static let zeroRatioThreshold = 0.999

    static func containsSignal(_ stats: AudioSampleStatsSnapshot) -> Bool {
        guard stats.sampleCount > 0 else { return false }
        let zeroRatio = Double(stats.zeroSampleCount) / Double(stats.sampleCount)
        return stats.peak > nonZeroPeakThreshold || zeroRatio < zeroRatioThreshold
    }
}

struct SystemAudioCaptureDiagnosticsSnapshot: Codable {
    let backend: String
    let callbackCount: Int
    let bufferCount: Int
    let emptyBufferCount: Int
    let unsupportedFormatCount: Int
    let inputByteCount: Int
    let bytesWritten: Int
    let sourceSampleRate: Double
    let sourceChannels: UInt32
    let preConversion: AudioSampleStatsSnapshot
    let postConversion: AudioSampleStatsSnapshot
}

protocol SystemAudioDiagnosticsProviding {
    var diagnosticsSnapshot: SystemAudioCaptureDiagnosticsSnapshot { get }
}

struct MeetingAecDiagnosticsSnapshot: Codable {
    let ready: Bool
    /// Active AEC backend name (`localvqe`, `dtln`, or nil when unloaded).
    let processor: String?
    /// Model hop/frame size in samples (LocalVQE=256, DTLN=512, 0=unloaded).
    let frameSize: Int
    let processedFrames: Int
    let fullReferenceFrames: Int
    let partialReferenceFrames: Int
    let missingReferenceFrames: Int
    let systemSamplesReceived: Int
    let micSamplesReceived: Int
    let bufferedSystemSamples: Int
    let bufferedMicSamples: Int
    let currentDelayMs: Int
    let delayHistory: [MeetingAecDelayObservation]
    let delaySkipHistory: [MeetingAecDelaySkip]
}

extension MeetingAecDiagnosticsSnapshot {
    private enum CodingKeys: String, CodingKey {
        case ready
        case processor
        case frameSize
        case processedFrames
        case fullReferenceFrames
        case partialReferenceFrames
        case missingReferenceFrames
        case systemSamplesReceived
        case micSamplesReceived
        case bufferedSystemSamples
        case bufferedMicSamples
        case currentDelayMs
        case delayHistory
        case delaySkipHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ready = try container.decode(Bool.self, forKey: .ready)
        processor = try container.decodeIfPresent(String.self, forKey: .processor)
        frameSize = try container.decodeIfPresent(Int.self, forKey: .frameSize) ?? 0
        processedFrames = try container.decode(Int.self, forKey: .processedFrames)
        fullReferenceFrames = try container.decode(Int.self, forKey: .fullReferenceFrames)
        partialReferenceFrames = try container.decode(Int.self, forKey: .partialReferenceFrames)
        missingReferenceFrames = try container.decode(Int.self, forKey: .missingReferenceFrames)
        systemSamplesReceived = try container.decode(Int.self, forKey: .systemSamplesReceived)
        micSamplesReceived = try container.decode(Int.self, forKey: .micSamplesReceived)
        bufferedSystemSamples = try container.decode(Int.self, forKey: .bufferedSystemSamples)
        bufferedMicSamples = try container.decode(Int.self, forKey: .bufferedMicSamples)
        currentDelayMs = try container.decode(Int.self, forKey: .currentDelayMs)
        delayHistory = try container.decode([MeetingAecDelayObservation].self, forKey: .delayHistory)
        delaySkipHistory = try container.decode([MeetingAecDelaySkip].self, forKey: .delaySkipHistory)
    }
}

struct MeetingAecDelayObservation: Codable {
    let delayMs: Int
    let appliedDelayMs: Int
    let score: Double
    let confidence: Double
    let comparedFrames: Int
    let decision: String
    let candidateScores: [MeetingAecDelayCandidateScore]
}

struct MeetingAecDelayCandidateScore: Codable {
    let delayMs: Int
    let score: Double
    let comparedFrames: Int
}

struct MeetingAecDelaySkip: Codable {
    let reason: String
    let micSamplesReceived: Int
    let systemSamplesReceived: Int
    let micHistoryStartSample: Int
    let systemHistoryStartSample: Int
    let comparableEndSample: Int?
    let validCandidateCount: Int
    let missingCandidateCount: Int
    let lowActiveCandidateCount: Int
    let systemWindowSamples: Int
    let systemPeak: Double?
}

/// Reverse-leak suppressor state at the end of a meeting. Built on the chunk
/// rotation queue and handed to `writeFinalReport` as a sibling of the forward
/// AEC snapshot; every field is direction-neutral because the reverse estimator
/// treats the cleaned mic as the reference and the system track as the target.
struct MeetingReverseLeakDiagnosticsSnapshot: Codable, Sendable {
    /// Resolved enabled flag (config key and environment override applied).
    let enabled: Bool
    /// Locked reverse offset in ms; nil while unlocked.
    let lockedDelayMs: Int?
    let delayHistory: [MeetingAecDelayObservation]
    let delaySkipHistory: [MeetingReverseLeakDelaySkip]
    let lockCount: Int
    let relockCount: Int
    let resetCount: Int
    let gapResetCount: Int
    let gateOpenCount: Int
    let suppressedSeconds: Double
    let referenceUnavailableFrames: Int
    let intervalCount: Int
    /// Spread between the smallest and largest observed offsets, in ms.
    let offsetSpreadMs: Int
    let meanBlockProcessingMicros: Double
    let maxBlockProcessingMicros: Int
    /// Set by the offline repair pass when it runs; nil otherwise.
    var offlineSpeechSecondsInsideSuppressedIntervals: Double?

    init(
        enabled: Bool,
        lockedDelayMs: Int?,
        delayHistory: [MeetingAecDelayObservation],
        delaySkipHistory: [MeetingReverseLeakDelaySkip],
        lockCount: Int,
        relockCount: Int,
        resetCount: Int,
        gapResetCount: Int,
        gateOpenCount: Int,
        suppressedSeconds: Double,
        referenceUnavailableFrames: Int,
        intervalCount: Int,
        offsetSpreadMs: Int,
        meanBlockProcessingMicros: Double,
        maxBlockProcessingMicros: Int,
        offlineSpeechSecondsInsideSuppressedIntervals: Double? = nil
    ) {
        self.enabled = enabled
        self.lockedDelayMs = lockedDelayMs
        self.delayHistory = delayHistory
        self.delaySkipHistory = delaySkipHistory
        self.lockCount = lockCount
        self.relockCount = relockCount
        self.resetCount = resetCount
        self.gapResetCount = gapResetCount
        self.gateOpenCount = gateOpenCount
        self.suppressedSeconds = suppressedSeconds
        self.referenceUnavailableFrames = referenceUnavailableFrames
        self.intervalCount = intervalCount
        self.offsetSpreadMs = offsetSpreadMs
        self.meanBlockProcessingMicros = meanBlockProcessingMicros
        self.maxBlockProcessingMicros = maxBlockProcessingMicros
        self.offlineSpeechSecondsInsideSuppressedIntervals = offlineSpeechSecondsInsideSuppressedIntervals
    }
}

/// Direction-neutral counterpart of `MeetingAecDelaySkip`: "reference" is the
/// signal being searched for (cleaned mic) and "target" the signal it leaks
/// into (system audio).
struct MeetingReverseLeakDelaySkip: Codable, Sendable {
    let reason: String
    let referenceSamplesReceived: Int
    let targetSamplesReceived: Int
    let referenceHistoryStartSample: Int
    let targetHistoryStartSample: Int
    let comparableEndSample: Int?
    let validCandidateCount: Int
    let missingCandidateCount: Int
    let lowActiveCandidateCount: Int
    let targetWindowSamples: Int
    let targetPeak: Double?
}

final class MeetingSessionDiagnostics {
    static let retentionDuration: TimeInterval = 7 * 24 * 60 * 60
    static let maximumStoredRunCount = 10
    static let maximumStoredRunBytes = 128 * 1_024
    static let maximumStoredTotalBytes = 1 * 1_024 * 1_024

    struct ClearResult: Equatable, Sendable {
        let activeRunsPreserved: Int
    }

    struct ChunkStats: Codable {
        let successful: Int
        let empty: Int
        let failed: Int
    }

    struct MicRecorderSummary: Codable {
        let recorderKind: String
        let outputRouteKind: String?
        let outputIsAmbiguousBluetooth: Bool?
        let selectedInputDeviceResolved: Bool?
        let systemDefaultInputIsBuiltIn: Bool?

        init(_ snapshot: MeetingMicRecorderDiagnosticsSnapshot) {
            recorderKind = snapshot.recorderKind.rawValue
            outputRouteKind = snapshot.route?.outputRouteKind
            outputIsAmbiguousBluetooth = snapshot.route?.outputIsAmbiguousBluetooth
            selectedInputDeviceResolved = snapshot.route?.selectedInputDeviceResolved
            systemDefaultInputIsBuiltIn = snapshot.route?.systemDefaultInputIsBuiltIn
        }
    }

    struct MicHealthSummary: Codable {
        let state: MeetingMicHealthState
        let rawMic: AudioSampleStatsSnapshot
        let systemAudio: AudioSampleStatsSnapshot
        let firstRawMicCallbackAt: Date?
        let firstNonZeroMicAt: Date?
        let firstSystemAudioAt: Date?
        let lastRawMicCallbackAt: Date?
        let lastNonZeroMicAt: Date?
        let lastSystemAudioAt: Date?
        let transitionCount: Int
        let sustainedZeroMicWhileSystemActive: Bool
        let failoverAttempted: Bool
        let failoverSucceeded: Bool

        init(_ snapshot: MeetingMicHealthSnapshot) {
            state = snapshot.state
            rawMic = snapshot.rawMic
            systemAudio = snapshot.systemAudio
            firstRawMicCallbackAt = snapshot.firstRawMicCallbackAt
            firstNonZeroMicAt = snapshot.firstNonZeroMicAt
            firstSystemAudioAt = snapshot.firstSystemAudioAt
            lastRawMicCallbackAt = snapshot.lastRawMicCallbackAt
            lastNonZeroMicAt = snapshot.lastNonZeroMicAt
            lastSystemAudioAt = snapshot.lastSystemAudioAt
            transitionCount = snapshot.transitions.count
            sustainedZeroMicWhileSystemActive = snapshot.sustainedZeroMicWhileSystemActive
            failoverAttempted = snapshot.failover != nil
            failoverSucceeded = snapshot.failover?.didSwitchInput == true
        }
    }

    struct AecSummary: Codable {
        let ready: Bool
        let processor: String?
        let frameSize: Int
        let processedFrames: Int
        let fullReferenceFrames: Int
        let partialReferenceFrames: Int
        let missingReferenceFrames: Int
        let systemSamplesReceived: Int
        let micSamplesReceived: Int
        let bufferedSystemSamples: Int
        let bufferedMicSamples: Int
        let currentDelayMs: Int
        let delayObservationCount: Int
        let delaySkipCount: Int

        init(_ snapshot: MeetingAecDiagnosticsSnapshot) {
            ready = snapshot.ready
            processor = snapshot.processor
            frameSize = snapshot.frameSize
            processedFrames = snapshot.processedFrames
            fullReferenceFrames = snapshot.fullReferenceFrames
            partialReferenceFrames = snapshot.partialReferenceFrames
            missingReferenceFrames = snapshot.missingReferenceFrames
            systemSamplesReceived = snapshot.systemSamplesReceived
            micSamplesReceived = snapshot.micSamplesReceived
            bufferedSystemSamples = snapshot.bufferedSystemSamples
            bufferedMicSamples = snapshot.bufferedMicSamples
            currentDelayMs = snapshot.currentDelayMs
            delayObservationCount = snapshot.delayHistory.count
            delaySkipCount = snapshot.delaySkipHistory.count
        }
    }

    struct ReverseLeakSummary: Codable, Equatable {
        let enabled: Bool
        let lockedDelayMs: Int?
        let delayObservationCount: Int
        let delaySkipCount: Int
        let lockCount: Int
        let relockCount: Int
        let resetCount: Int
        let gapResetCount: Int
        let gateOpenCount: Int
        let suppressedSeconds: Double
        let referenceUnavailableFrames: Int
        let intervalCount: Int
        let offsetSpreadMs: Int
        let meanBlockProcessingMicros: Double
        let maxBlockProcessingMicros: Int
        let offlineSpeechSecondsInsideSuppressedIntervals: Double?

        init(_ snapshot: MeetingReverseLeakDiagnosticsSnapshot) {
            enabled = snapshot.enabled
            lockedDelayMs = snapshot.lockedDelayMs
            delayObservationCount = snapshot.delayHistory.count
            delaySkipCount = snapshot.delaySkipHistory.count
            lockCount = snapshot.lockCount
            relockCount = snapshot.relockCount
            resetCount = snapshot.resetCount
            gapResetCount = snapshot.gapResetCount
            gateOpenCount = snapshot.gateOpenCount
            suppressedSeconds = snapshot.suppressedSeconds
            referenceUnavailableFrames = snapshot.referenceUnavailableFrames
            intervalCount = snapshot.intervalCount
            offsetSpreadMs = snapshot.offsetSpreadMs
            meanBlockProcessingMicros = snapshot.meanBlockProcessingMicros
            maxBlockProcessingMicros = snapshot.maxBlockProcessingMicros
            offlineSpeechSecondsInsideSuppressedIntervals = snapshot.offlineSpeechSecondsInsideSuppressedIntervals
        }
    }

    struct Summary: Codable {
        let schemaVersion: Int
        let startedAt: String
        let endedAt: String
        let durationSeconds: Double
        let systemCapture: SystemAudioCaptureDiagnosticsSnapshot?
        let micRecorder: MicRecorderSummary?
        let micHealth: MicHealthSummary?
        let aec: AecSummary
        /// Absent in payloads written before reverse-leak suppression shipped.
        let reverseLeak: ReverseLeakSummary?
        let micChunks: ChunkStats
        let systemChunks: ChunkStats
        let diarizationSegments: Int
        let diarizationSpeakers: Int
        let protectedSystemSegments: Int
        let rawMic: AudioSampleStatsSnapshot?
        let cleanedMicAec: AudioSampleStatsSnapshot
        let systemAudio: AudioSampleStatsSnapshot?
    }

    struct StoredSummary {
        let id: String
        let modifiedAt: Date
        let summary: Summary
    }

    private struct State {
        var cleanedMicStats = AudioSampleStats()
        var isFinalized = false
    }

    private struct DiagnosticRun {
        let url: URL
        let modifiedAt: Date
        let byteSize: Int
        let isActive: Bool
    }

    private let outputDirectory: URL?
    private let diagnosticsRoot: URL
    private let activeRunPath: String?
    private let enabled: Bool
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private static let activeRunsLock = OSAllocatedUnfairLock(initialState: Set<String>())

    static var isEnabled: Bool {
        isEnabled(rootURL: AppIdentity.supportDirectoryURL)
    }

    static func isEnabled(rootURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: enabledFlagURL(rootURL: rootURL).path)
    }

    init(
        startedAt: Date,
        rootURL: URL = AppIdentity.supportDirectoryURL,
        enabledOverride: Bool? = nil
    ) {
        let resolvedDiagnosticsRoot = Self.diagnosticsRoot(rootURL: rootURL)
        diagnosticsRoot = resolvedDiagnosticsRoot
        enabled = enabledOverride ?? Self.isEnabled(rootURL: rootURL)
        guard enabled else {
            outputDirectory = nil
            activeRunPath = nil
            return
        }

        let timestamp = Self.fileTimestamp.string(from: startedAt)
        let id = "\(timestamp)-\(UUID().uuidString.lowercased())"
        let runDirectory = resolvedDiagnosticsRoot.appendingPathComponent(id, isDirectory: true)
        let runPath = Self.canonicalPath(runDirectory)
        let didCreateRun = Self.activeRunsLock.withLock { activeIDs in
            activeIDs.insert(runPath)
            do {
                try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
                Self.pruneOldRuns(in: resolvedDiagnosticsRoot, now: Date(), activeIDs: activeIDs)
                return true
            } catch {
                activeIDs.remove(runPath)
                return false
            }
        }
        if didCreateRun {
            outputDirectory = runDirectory
            activeRunPath = runPath
            fputs("[meeting-diagnostics] local metadata capture enabled\n", stderr)
        } else {
            outputDirectory = nil
            activeRunPath = nil
            fputs("[meeting-diagnostics] failed to create local metadata directory\n", stderr)
        }
    }

    deinit {
        unregisterActiveRun()
    }

    func appendCleanedMicSamples(_ samples: [Int16]) {
        guard enabled, !samples.isEmpty else { return }
        lock.withLock { state in
            guard !state.isFinalized else { return }
            state.cleanedMicStats.addInt16(samples)
        }
    }

    func writeFinalReport(
        startedAt: Date,
        endedAt: Date,
        systemCapture: SystemAudioCaptureDiagnosticsSnapshot?,
        micRecorder: MeetingMicRecorderDiagnosticsSnapshot?,
        micHealth: MeetingMicHealthSnapshot?,
        aec: MeetingAecDiagnosticsSnapshot,
        micChunks: MeetingTranscriptChunkHealthSnapshot,
        systemChunks: MeetingTranscriptChunkHealthSnapshot,
        diarizationSegments: [TimedSpeakerSegment]?,
        protectedSystemSegmentCount: Int,
        reverseLeak: MeetingReverseLeakDiagnosticsSnapshot? = nil,
        retentionReferenceDate: Date = Date()
    ) {
        guard enabled, let outputDirectory else { return }
        guard let cleanedMicStats = finalizeCleanedMic() else { return }
        defer { unregisterActiveRun() }

        let summary = Summary(
            schemaVersion: 1,
            startedAt: Self.iso8601.string(from: startedAt),
            endedAt: Self.iso8601.string(from: endedAt),
            durationSeconds: max(endedAt.timeIntervalSince(startedAt), 0),
            systemCapture: systemCapture,
            micRecorder: micRecorder.map(MicRecorderSummary.init),
            micHealth: micHealth.map(MicHealthSummary.init),
            aec: AecSummary(aec),
            reverseLeak: reverseLeak.map(ReverseLeakSummary.init),
            micChunks: ChunkStats(
                successful: micChunks.successfulChunkCount,
                empty: micChunks.emptyChunkCount,
                failed: micChunks.failedChunkCount
            ),
            systemChunks: ChunkStats(
                successful: systemChunks.successfulChunkCount,
                empty: systemChunks.emptyChunkCount,
                failed: systemChunks.failedChunkCount
            ),
            diarizationSegments: diarizationSegments?.count ?? 0,
            diarizationSpeakers: Set((diarizationSegments ?? []).map(\.speakerId)).count,
            protectedSystemSegments: protectedSystemSegmentCount,
            rawMic: micHealth?.rawMic,
            cleanedMicAec: cleanedMicStats,
            systemAudio: systemCapture?.postConversion ?? micHealth?.systemAudio
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(summary)
            guard data.count <= Self.maximumStoredRunBytes else {
                fputs("[meeting-diagnostics] local metadata exceeded the per-run cap\n", stderr)
                return
            }
            try data.write(
                to: outputDirectory.appendingPathComponent("diagnostics.json"),
                options: .atomic
            )
        } catch {
            fputs("[meeting-diagnostics] failed to write diagnostics.json\n", stderr)
        }

        unregisterActiveRun()
        Self.pruneOldRuns(in: diagnosticsRoot, now: retentionReferenceDate)
    }

    static func loadStoredSummaries(
        rootURL: URL = AppIdentity.supportDirectoryURL,
        now: Date = Date()
    ) -> [StoredSummary] {
        let root = diagnosticsRoot(rootURL: rootURL)
        pruneOldRuns(in: root, now: now)
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { runURL -> StoredSummary? in
            let values = try? runURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { return nil }
            let reportURL = runURL.appendingPathComponent("diagnostics.json")
            guard let data = try? Data(contentsOf: reportURL, options: .mappedIfSafe),
                  data.count <= maximumStoredRunBytes,
                  let summary = try? JSONDecoder().decode(Summary.self, from: data),
                  summary.schemaVersion == 1
            else { return nil }
            return StoredSummary(
                id: runURL.lastPathComponent,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                summary: summary
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    static func prepareStore(
        rootURL: URL = AppIdentity.supportDirectoryURL,
        now: Date = Date()
    ) {
        pruneOldRuns(in: diagnosticsRoot(rootURL: rootURL), now: now)
    }

    static func clearStoredRuns(
        rootURL: URL = AppIdentity.supportDirectoryURL
    ) throws -> ClearResult {
        let root = diagnosticsRoot(rootURL: rootURL)
        return try activeRunsLock.withLock { activeIDs in
            let fileManager = FileManager.default
            let activePathsInRoot = activeIDs.filter {
                canonicalPath(URL(fileURLWithPath: $0).deletingLastPathComponent())
                    == canonicalPath(root)
            }
            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: []
                )
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return ClearResult(activeRunsPreserved: activePathsInRoot.count)
            }

            for url in contents where !activeIDs.contains(canonicalPath(url)) {
                try fileManager.removeItem(at: url)
            }
            if activePathsInRoot.isEmpty {
                try fileManager.removeItem(at: root)
            }
            return ClearResult(activeRunsPreserved: activePathsInRoot.count)
        }
    }

    private func finalizeCleanedMic() -> AudioSampleStatsSnapshot? {
        lock.withLock { state in
            guard !state.isFinalized else { return nil }
            state.isFinalized = true
            return state.cleanedMicStats.snapshot()
        }
    }

    private func unregisterActiveRun() {
        guard let activeRunPath else { return }
        _ = Self.activeRunsLock.withLock { $0.remove(activeRunPath) }
    }

    private static func pruneOldRuns(in diagnosticsRoot: URL, now: Date) {
        activeRunsLock.withLock { activeIDs in
            pruneOldRuns(in: diagnosticsRoot, now: now, activeIDs: activeIDs)
        }
    }

    private static func pruneOldRuns(
        in diagnosticsRoot: URL,
        now: Date,
        activeIDs: Set<String>
    ) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: diagnosticsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var runs = contents.compactMap { url -> DiagnosticRun? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { return nil }
            return DiagnosticRun(
                url: url,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                byteSize: directoryByteSize(url),
                isActive: activeIDs.contains(canonicalPath(url))
            )
        }
        runs.sort {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.modifiedAt > $1.modifiedAt
        }

        let expirationDate = now.addingTimeInterval(-retentionDuration)
        var retainedCount = 0
        var retainedBytes = 0
        for run in runs {
            if !run.isActive, !isCurrentMetadataRun(run.url) {
                try? fileManager.removeItem(at: run.url)
                continue
            }
            let isExpired = run.modifiedAt < expirationDate
            let fitsBounds = retainedCount < maximumStoredRunCount
                && retainedBytes + run.byteSize <= maximumStoredTotalBytes
            if run.isActive || (!isExpired && fitsBounds) {
                retainedCount += 1
                retainedBytes += run.byteSize
            } else {
                try? fileManager.removeItem(at: run.url)
            }
        }
    }

    private static func isCurrentMetadataRun(_ runURL: URL) -> Bool {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: runURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ), contents.map(\.lastPathComponent).sorted() == ["diagnostics.json"] else {
            return false
        }
        let reportURL = runURL.appendingPathComponent("diagnostics.json")
        guard let data = try? Data(contentsOf: reportURL, options: .mappedIfSafe),
              data.count <= maximumStoredRunBytes,
              let summary = try? JSONDecoder().decode(Summary.self, from: data)
        else { return false }
        return summary.schemaVersion == 1
    }

    private static func directoryByteSize(_ url: URL) -> Int {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += values?.fileSize ?? 0
        }
        return total
    }

    private static func diagnosticsRoot(rootURL: URL) -> URL {
        rootURL.appendingPathComponent("MeetingDiagnostics", isDirectory: true)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func enabledFlagURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent("MeetingDiagnostics.enabled")
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fileTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
