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

    /// One incrementally written WAV fed by two time-aligned sources.
    private struct OutputFile {
        enum Layout {
            /// Mono average of both sources: the recording people play back.
            case mix
            /// First source on the left channel, second on the right, so a later pass
            /// can transcribe each side on its own.
            case separated

            var channels: UInt16 {
                switch self {
                case .mix: 1
                case .separated: 2
                }
            }
        }

        let layout: Layout
        var fileHandle: FileHandle?
        var fileURL: URL?
        var bytesWritten = 0
        var writeOffset = 0
        var first = SourceState()
        var second = SourceState()

        init(layout: Layout, fileURL: URL? = nil, fileHandle: FileHandle? = nil) {
            self.layout = layout
            self.fileURL = fileURL
            self.fileHandle = fileHandle
        }
    }

    private struct State {
        /// Mic + system averaged: the recording people play back.
        var mix = OutputFile(layout: .mix)
        /// The same two sources kept apart, so retranscription can label the mic as the user.
        var tracks = OutputFile(layout: .separated)
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    private static let sampleRate: UInt32 = 16_000
    /// A dead mic or system stream would otherwise let the surviving side's
    /// backlog grow for the whole meeting (~115 MB/h) and then land as a
    /// duplicate-sounding single-track tail at `stop()`.
    private static let maxPendingImbalance = Int(sampleRate) * 3

    init() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imla-meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let fileURL = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let mix = try Self.openOutput(layout: .mix, at: fileURL)
        // The tracks file only improves retranscription; the mix is the recording, so
        // a tracks file that cannot open must not stop the meeting from recording.
        let tracks = (try? Self.openOutput(layout: .separated, at: Self.tracksURL(forRecording: fileURL)))
            ?? OutputFile(layout: .separated)
        lock.withLock {
            $0 = State(mix: mix, tracks: tracks)
        }
    }

    /// The companion file holding the separated sources of the recording at `url`.
    /// Every stage that moves, copies, or deletes a recording derives the companion's
    /// location from this one rule, so the two never need to be passed around together.
    static func tracksURL(forRecording url: URL) -> URL {
        let ext = url.pathExtension
        return url.deletingPathExtension().appendingPathExtension("tracks").appendingPathExtension(ext)
    }

    /// Removes a temporary recording together with its tracks companion.
    static func removeTemporaryRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: tracksURL(forRecording: url))
    }

    /// The echo-cancelled mic. The raw mic also hears the far side through the
    /// speakers, so mixing it would put every remote voice in the recording twice.
    func appendMic(_ samples: [Int16], atSampleOffset sampleOffset: Int) {
        append(samples, atSampleOffset: sampleOffset, from: .mic)
    }

    func appendSystem(_ samples: [Int16], atSampleOffset sampleOffset: Int) {
        append(samples, atSampleOffset: sampleOffset, from: .system)
    }

    /// Returns the mix. Its tracks companion, when one was written, sits at
    /// `tracksURL(forRecording:)` of the returned URL.
    func stop() -> URL? {
        lock.withLock { state in
            let tracksURL = Self.finish(&state.tracks)
            let mixURL = Self.finish(&state.mix)
            state = State()
            if mixURL == nil, let tracksURL {
                // Tracks without the recording they belong to have nothing to serve.
                try? FileManager.default.removeItem(at: tracksURL)
            }
            return mixURL
        }
    }

    func markPauseBoundary() {
        lock.withLock { state in
            Self.writeSamples(&state.mix, flushAll: true)
            Self.writeSamples(&state.tracks, flushAll: true)
        }
    }

    func cancel() {
        let tempURLs = lock.withLock { state -> [URL] in
            state.mix.fileHandle?.closeFile()
            state.tracks.fileHandle?.closeFile()
            let urls = [state.mix.fileURL, state.tracks.fileURL].compactMap { $0 }
            state = State()
            return urls
        }
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
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
        await persistTracksBestEffort(
            from: tracksURL(forRecording: tempURL),
            to: tracksURL(forRecording: destinationURL),
            fileFormat: fileFormat
        )
        return destinationURL
    }

    /// Tracks only sharpen a later retranscription, so losing them never fails the save:
    /// retranscription falls back to the mix.
    private static func persistTracksBestEffort(
        from tempURL: URL,
        to destinationURL: URL,
        fileFormat: MeetingRecordingFileFormat
    ) async {
        guard FileManager.default.fileExists(atPath: tempURL.path) else { return }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try? FileManager.default.removeItem(at: destinationURL)
        do {
            switch fileFormat {
            case .m4a:
                try await transcodeWAVToM4AAsync(sourceURL: tempURL, destinationURL: destinationURL)
            case .wav:
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            fputs("[recordings] meeting tracks not saved; retranscription will use the mix: \(error)\n", stderr)
        }
    }

    private enum Source {
        case mic
        case system
    }

    private func append(_ samples: [Int16], atSampleOffset sampleOffset: Int, from source: Source) {
        guard !samples.isEmpty else { return }
        lock.withLock { state in
            switch source {
            case .mic:
                Self.append(samples, atSampleOffset: sampleOffset, to: &state.mix.first, writeOffset: state.mix.writeOffset)
                Self.append(samples, atSampleOffset: sampleOffset, to: &state.tracks.first, writeOffset: state.tracks.writeOffset)
            case .system:
                Self.append(samples, atSampleOffset: sampleOffset, to: &state.mix.second, writeOffset: state.mix.writeOffset)
                Self.append(samples, atSampleOffset: sampleOffset, to: &state.tracks.second, writeOffset: state.tracks.writeOffset)
            }
            Self.writeSamples(&state.mix, flushAll: false)
            Self.writeSamples(&state.tracks, flushAll: false)
        }
    }

    private static func openOutput(layout: OutputFile.Layout, at fileURL: URL) throws -> OutputFile {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw NSError(
                domain: "MeetingRecordingWriter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not open retained meeting recording file for writing."]
            )
        }
        fileHandle.write(wavHeader(dataSize: 0, channels: layout.channels))
        return OutputFile(layout: layout, fileURL: fileURL, fileHandle: fileHandle)
    }

    /// Flushes, closes, and returns the file, or nil when nothing was written.
    private static func finish(_ output: inout OutputFile) -> URL? {
        writeSamples(&output, flushAll: true)
        guard let fileHandle = output.fileHandle, let fileURL = output.fileURL else { return nil }
        fileHandle.seek(toFileOffset: 0)
        fileHandle.write(wavHeader(dataSize: UInt32(output.bytesWritten), channels: output.layout.channels))
        fileHandle.closeFile()
        output.fileHandle = nil
        if output.bytesWritten == 0 {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return fileURL
    }

    private static func append(
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

    private static func writeSamples(_ output: inout OutputFile, flushAll: Bool) {
        guard output.fileHandle != nil else {
            // A file that never opened still drains its sources, so it cannot grow memory.
            output.first.segments.removeAll()
            output.second.segments.removeAll()
            return
        }
        let furthestObserved = max(output.first.observedThrough, output.second.observedThrough)
        let availableThrough: Int
        if flushAll {
            availableThrough = furthestObserved
        } else {
            let bothSourcesObservedThrough = min(output.first.observedThrough, output.second.observedThrough)
            let boundedSingleSourceThrough = furthestObserved - maxPendingImbalance
            availableThrough = max(bothSourcesObservedThrough, boundedSingleSourceThrough)
        }
        guard availableThrough > output.writeOffset else { return }

        while output.writeOffset < availableThrough {
            let blockEnd = min(availableThrough, output.writeOffset + 4_096)
            let block: [Int16]
            switch output.layout {
            case .mix:
                block = mix(
                    from: output.writeOffset,
                    through: blockEnd,
                    sources: [output.first.segments, output.second.segments]
                )
            case .separated:
                let left = mix(from: output.writeOffset, through: blockEnd, sources: [output.first.segments])
                let right = mix(from: output.writeOffset, through: blockEnd, sources: [output.second.segments])
                var interleaved = [Int16](repeating: 0, count: left.count * 2)
                for index in left.indices {
                    interleaved[index * 2] = left[index]
                    interleaved[index * 2 + 1] = right[index]
                }
                block = interleaved
            }
            let pcmData = block.withUnsafeBufferPointer { Data(buffer: $0) }
            output.fileHandle?.write(pcmData)
            output.bytesWritten += pcmData.count
            output.writeOffset = blockEnd
        }

        let writeOffset = output.writeOffset
        output.first.segments.removeAll { $0.endOffset <= writeOffset }
        output.second.segments.removeAll { $0.endOffset <= writeOffset }
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
        sources: [[TimedSamples]]
    ) -> [Int16] {
        let count = endOffset - startOffset
        var sums = [Int](repeating: 0, count: count)
        var contributors = [UInt8](repeating: 0, count: count)

        for segments in sources {
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

    private static func wavHeader(dataSize: UInt32, channels: UInt16) -> Data {
        let sampleRate = Self.sampleRate
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
