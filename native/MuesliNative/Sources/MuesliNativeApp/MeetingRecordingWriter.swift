import AVFoundation
import Foundation
import os

enum MeetingRecordingFileFormat: String, CaseIterable, Sendable {
    case m4a
    case wav

    var displayName: String {
        switch self {
        case .m4a:
            return "M4A (AAC, smaller)"
        case .wav:
            return "WAV (lossless)"
        }
    }

    var fileExtension: String {
        switch self {
        case .m4a:
            return "m4a"
        case .wav:
            return "wav"
        }
    }

    static func resolved(_ rawValue: String) -> MeetingRecordingFileFormat {
        MeetingRecordingFileFormat(rawValue: rawValue) ?? .m4a
    }
}

/// Maps callback delivery times onto the gapless retained-recording timeline.
/// Mutated only on `MeetingSession.chunkRotationQueue`; callback timestamps are
/// captured before dispatch so queue latency cannot move audio later in time.
struct MeetingRecordingTimeline {
    enum Source {
        case mic
        case system
    }

    private static let sampleRate = 16_000.0
    private static let nanosecondsPerSecond = 1_000_000_000.0

    private var startedAt: UInt64?
    private var pausedAt: UInt64?
    private var excludedPauseNanoseconds: UInt64 = 0
    private var micEndOffset = 0
    private var systemEndOffset = 0

    @discardableResult
    mutating func startIfNeeded(at uptimeNanoseconds: UInt64) -> Bool {
        guard startedAt == nil else { return false }
        startedAt = uptimeNanoseconds
        pausedAt = nil
        excludedPauseNanoseconds = 0
        micEndOffset = 0
        systemEndOffset = 0
        return true
    }

    mutating func start(at uptimeNanoseconds: UInt64) {
        reset()
        _ = startIfNeeded(at: uptimeNanoseconds)
    }

    mutating func pause(at uptimeNanoseconds: UInt64) {
        guard startedAt != nil, pausedAt == nil else { return }
        pausedAt = uptimeNanoseconds
        // Both sources resume from the same boundary. This prevents an
        // unmatched pre-pause tail from being paired with post-resume audio.
        let boundaryOffset = max(
            sampleOffset(at: uptimeNanoseconds),
            max(micEndOffset, systemEndOffset)
        )
        micEndOffset = boundaryOffset
        systemEndOffset = boundaryOffset
    }

    mutating func resume(at uptimeNanoseconds: UInt64) {
        guard let pausedAt else { return }
        if uptimeNanoseconds > pausedAt {
            excludedPauseNanoseconds += uptimeNanoseconds - pausedAt
        }
        self.pausedAt = nil
    }

    mutating func reset() {
        self = MeetingRecordingTimeline()
    }

    mutating func sampleStartOffset(
        for source: Source,
        sampleCount: Int,
        callbackUptimeNanoseconds: UInt64
    ) -> Int {
        guard sampleCount > 0 else { return sampleOffset(at: callbackUptimeNanoseconds) }

        let callbackEndOffset = sampleOffset(at: callbackUptimeNanoseconds)
        let proposedStart = max(callbackEndOffset - sampleCount, 0)
        let previousEnd = source == .mic ? micEndOffset : systemEndOffset
        // Preserve every delivered sample when callback scheduling jitter makes
        // two adjacent buffers' wall-clock ranges overlap. Positive gaps remain
        // explicit, which is what keeps a stream resuming after a stall aligned.
        let resolvedStart = max(proposedStart, previousEnd)
        let resolvedEnd = resolvedStart + sampleCount
        if source == .mic {
            micEndOffset = resolvedEnd
        } else {
            systemEndOffset = resolvedEnd
        }
        return resolvedStart
    }

    func sampleOffset(at uptimeNanoseconds: UInt64) -> Int {
        guard let startedAt else { return 0 }
        let effectiveNow = pausedAt.map { min(uptimeNanoseconds, $0) } ?? uptimeNanoseconds
        guard effectiveNow > startedAt else { return 0 }
        let elapsedNanoseconds = effectiveNow - startedAt
        let activeNanoseconds = elapsedNanoseconds > excludedPauseNanoseconds
            ? elapsedNanoseconds - excludedPauseNanoseconds
            : 0
        return Int(
            (Double(activeNanoseconds) * Self.sampleRate / Self.nanosecondsPerSecond).rounded(.down)
        )
    }
}

struct MeetingCaptureOrigin: Equatable {
    private static let sampleRate = 16_000.0
    private static let nanosecondsPerSecond = 1_000_000_000.0

    let uptimeNanoseconds: UInt64
    let wallClockDate: Date

    init(
        callbackEndUptimeNanoseconds: UInt64,
        callbackEndDate: Date,
        sampleCount: Int
    ) {
        let durationSeconds = Double(max(sampleCount, 0)) / Self.sampleRate
        let durationNanoseconds = UInt64(
            (durationSeconds * Self.nanosecondsPerSecond).rounded(.toNearestOrAwayFromZero)
        )
        uptimeNanoseconds = callbackEndUptimeNanoseconds > durationNanoseconds
            ? callbackEndUptimeNanoseconds - durationNanoseconds
            : 0
        wallClockDate = callbackEndDate.addingTimeInterval(-durationSeconds)
    }
}

final class MeetingRecordingWriter {
    private final class ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession

        init(_ session: AVAssetExportSession) {
            self.session = session
        }
    }

    private struct TimedSamples {
        let startOffset: Int
        let samples: [Int16]

        var endOffset: Int { startOffset + samples.count }
    }

    private struct SourceState {
        var observedThrough = 0
        var segments: [TimedSamples] = []
    }

    private struct State {
        var fileHandle: FileHandle?
        var fileURL: URL?
        var bytesWritten: Int = 0
        var writeOffset = 0
        var mic = SourceState()
        var system = SourceState()
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    private static let sampleRate: UInt32 = 16_000
    /// A dead mic or system stream would otherwise let the surviving side's
    /// backlog grow for the whole meeting (~115 MB/h) and then land as a
    /// duplicate-sounding single-track tail at `stop()`.
    private static let maxPendingImbalance = Int(sampleRate) * 3

    init() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let fileURL = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw NSError(
                domain: "MeetingRecordingWriter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not open retained meeting recording file for writing."]
            )
        }
        fileHandle.write(Self.wavHeader(dataSize: 0))
        lock.withLock {
            $0 = State(fileHandle: fileHandle, fileURL: fileURL)
        }
    }

    func appendMic(_ samples: [Int16], atSampleOffset sampleOffset: Int) {
        append(samples, atSampleOffset: sampleOffset, toMic: true)
    }

    func appendSystem(_ samples: [Int16], atSampleOffset sampleOffset: Int) {
        append(samples, atSampleOffset: sampleOffset, toMic: false)
    }

    func stop() -> URL? {
        lock.withLock { state in
            writeMixedSamples(state: &state, flushAll: true)
            guard let fileHandle = state.fileHandle, let fileURL = state.fileURL else { return nil }

            fileHandle.seek(toFileOffset: 0)
            fileHandle.write(Self.wavHeader(dataSize: UInt32(state.bytesWritten)))
            fileHandle.closeFile()

            let outputURL = fileURL
            let bytesWritten = state.bytesWritten
            state = State()
            if bytesWritten == 0 {
                try? FileManager.default.removeItem(at: outputURL)
                return nil
            }
            return outputURL
        }
    }

    func markPauseBoundary() {
        lock.withLock { state in
            writeMixedSamples(state: &state, flushAll: true)
        }
    }

    func cancel() {
        let tempURL = lock.withLock { state -> URL? in
            state.fileHandle?.closeFile()
            let fileURL = state.fileURL
            state = State()
            return fileURL
        }
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    static func persistTemporaryRecordingAsync(
        from tempURL: URL,
        meetingTitle: String,
        startedAt: Date,
        supportDirectory: URL,
        fileFormat: MeetingRecordingFileFormat = .m4a
    ) async throws -> URL {
        let recordingsDirectory = supportDirectory
            .appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = recordingsDirectory.appendingPathComponent(
            "\(fileNamePrefix(for: startedAt, title: meetingTitle)).\(fileFormat.fileExtension)"
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        switch fileFormat {
        case .m4a:
            do {
                try await transcodeWAVToM4AAsync(sourceURL: tempURL, destinationURL: destinationURL)
                try FileManager.default.removeItem(at: tempURL)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
        case .wav:
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        }
        return destinationURL
    }

    private func append(_ samples: [Int16], atSampleOffset sampleOffset: Int, toMic: Bool) {
        guard !samples.isEmpty else { return }
        lock.withLock { state in
            let writeOffset = state.writeOffset
            if toMic {
                append(samples, atSampleOffset: sampleOffset, to: &state.mic, writeOffset: writeOffset)
            } else {
                append(samples, atSampleOffset: sampleOffset, to: &state.system, writeOffset: writeOffset)
            }
            writeMixedSamples(state: &state, flushAll: false)
        }
    }

    private func append(
        _ samples: [Int16],
        atSampleOffset sampleOffset: Int,
        to source: inout SourceState,
        writeOffset: Int
    ) {
        let requestedStart = max(sampleOffset, 0)
        let requestedEnd = requestedStart + samples.count
        source.observedThrough = max(source.observedThrough, requestedEnd)

        // The file is written incrementally and cannot be rewritten. A callback
        // delayed past the bounded retention window may overlap data already on
        // disk, so retain only its still-writable tail.
        let retainedStart = max(requestedStart, writeOffset)
        guard retainedStart < requestedEnd else { return }
        var retainedSamples = Array(samples.dropFirst(retainedStart - requestedStart))

        // Capture callbacks for a source are ordered. Trim any small timestamp
        // overlap rather than duplicating samples when callback scheduling
        // jitter puts the next buffer slightly before the previous buffer's end.
        if let previous = source.segments.last, retainedStart < previous.endOffset {
            let overlap = min(previous.endOffset - retainedStart, retainedSamples.count)
            retainedSamples.removeFirst(overlap)
        }
        guard !retainedSamples.isEmpty else { return }

        let adjustedStart = requestedEnd - retainedSamples.count
        source.segments.append(TimedSamples(startOffset: adjustedStart, samples: retainedSamples))
    }

    private func writeMixedSamples(state: inout State, flushAll: Bool) {
        let furthestObserved = max(state.mic.observedThrough, state.system.observedThrough)
        let availableThrough: Int
        if flushAll {
            availableThrough = furthestObserved
        } else {
            let bothSourcesObservedThrough = min(state.mic.observedThrough, state.system.observedThrough)
            let boundedSingleSourceThrough = furthestObserved - Self.maxPendingImbalance
            availableThrough = max(bothSourcesObservedThrough, boundedSingleSourceThrough)
        }
        guard availableThrough > state.writeOffset else { return }

        while state.writeOffset < availableThrough {
            let blockEnd = min(availableThrough, state.writeOffset + 4_096)
            let mixedSamples = Self.mix(
                from: state.writeOffset,
                through: blockEnd,
                mic: state.mic.segments,
                system: state.system.segments
            )
            let pcmData = mixedSamples.withUnsafeBufferPointer { Data(buffer: $0) }
            state.fileHandle?.write(pcmData)
            state.bytesWritten += pcmData.count
            state.writeOffset = blockEnd
        }

        state.mic.segments.removeAll { $0.endOffset <= state.writeOffset }
        state.system.segments.removeAll { $0.endOffset <= state.writeOffset }
    }

    private static func fileNamePrefix(for date: Date, title: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let timestamp = formatter.string(from: date)

        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let normalized = title.unicodeScalars.map { allowed.contains($0) ? String($0) : " " }.joined()
        let slug = normalized
            .split(whereSeparator: \.isWhitespace)
            .prefix(6)
            .joined(separator: "-")
            .lowercased()

        return slug.isEmpty ? timestamp : "\(timestamp)-\(slug)"
    }

    private static func mix(
        from startOffset: Int,
        through endOffset: Int,
        mic: [TimedSamples],
        system: [TimedSamples]
    ) -> [Int16] {
        let count = endOffset - startOffset
        var sums = [Int](repeating: 0, count: count)
        var contributors = [UInt8](repeating: 0, count: count)

        for segments in [mic, system] {
            for segment in segments {
                let overlapStart = max(startOffset, segment.startOffset)
                let overlapEnd = min(endOffset, segment.endOffset)
                guard overlapStart < overlapEnd else { continue }

                for offset in overlapStart..<overlapEnd {
                    let outputIndex = offset - startOffset
                    let sourceIndex = offset - segment.startOffset
                    sums[outputIndex] += Int(segment.samples[sourceIndex])
                    contributors[outputIndex] += 1
                }
            }
        }

        return sums.indices.map { index in
            guard contributors[index] > 0 else { return 0 }
            return Int16(clamping: sums[index] / Int(contributors[index]))
        }
    }

    private static func transcodeWAVToM4AAsync(sourceURL: URL, destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NSError(
                domain: "MeetingRecordingWriter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not create M4A export session for meeting recording."]
            )
        }

        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .m4a
        let exportSessionBox = ExportSessionBox(exportSession)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSessionBox.session.exportAsynchronously {
                guard exportSessionBox.session.status == .completed else {
                    continuation.resume(throwing: exportSessionBox.session.error ?? NSError(
                        domain: "MeetingRecordingWriter",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Could not export meeting recording as M4A."]
                    ))
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private static func wavHeader(dataSize: UInt32) -> Data {
        let sampleRate = Self.sampleRate
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let chunkSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        return header
    }
}
