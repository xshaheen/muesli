import AVFoundation
import Foundation

/// Joins a meeting's earlier saved recording with the segment a resumed session captured.
///
/// A meeting owns exactly one recording, so a resume that adopted the new segment on its own
/// would replace the earlier audio and the retranscribe action would then rewrite the whole
/// transcript from the last segment alone. Everything is decoded to PCM and re-encoded in the
/// segment's format rather than spliced at the container level: the earlier file may have been
/// written by an older build with a different sample rate or container.
enum MeetingRecordingConcatenator {
    struct ConcatenationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let framesPerRead: AVAudioFrameCount = 32_768

    /// Writes `prior` followed by `segment` to `outputURL`, which must not exist yet.
    /// `format` picks the container and codec; the segment's sample rate and channel
    /// count are kept, and the prior audio is converted to them when they differ.
    nonisolated static func concatenate(
        prior priorURL: URL,
        segment segmentURL: URL,
        to outputURL: URL,
        format: MeetingRecordingFileFormat
    ) throws {
        let prior = try AVAudioFile(forReading: priorURL)
        let segment = try AVAudioFile(forReading: segmentURL)
        let target = segment.processingFormat
        let writer = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings(format: format, processingFormat: target),
            commonFormat: target.commonFormat,
            interleaved: target.isInterleaved
        )
        do {
            try copy(prior, into: writer, target: target)
            try copy(segment, into: writer, target: target)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func outputSettings(
        format: MeetingRecordingFileFormat,
        processingFormat: AVAudioFormat
    ) -> [String: Any] {
        switch format {
        case .wav:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: processingFormat.sampleRate,
                AVNumberOfChannelsKey: processingFormat.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        case .m4a:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: processingFormat.sampleRate,
                AVNumberOfChannelsKey: processingFormat.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        }
    }

    private static func copy(_ source: AVAudioFile, into writer: AVAudioFile, target: AVAudioFormat) throws {
        let sourceFormat = source.processingFormat
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesPerRead) else {
            throw ConcatenationError(message: "Could not allocate a read buffer for the recording.")
        }
        let needsConversion = sourceFormat.sampleRate != target.sampleRate
            || sourceFormat.channelCount != target.channelCount
            || sourceFormat.commonFormat != target.commonFormat
            || sourceFormat.isInterleaved != target.isInterleaved
        let converter: AVAudioConverter?
        if needsConversion {
            guard let created = AVAudioConverter(from: sourceFormat, to: target) else {
                throw ConcatenationError(message: "The earlier recording's audio format cannot be converted to the new segment's format.")
            }
            converter = created
        } else {
            converter = nil
        }

        while source.framePosition < source.length {
            try source.read(into: inputBuffer, frameCount: framesPerRead)
            guard inputBuffer.frameLength > 0 else { break }
            guard let converter else {
                try writer.write(from: inputBuffer)
                continue
            }
            let ratio = target.sampleRate / sourceFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(inputBuffer.frameLength) * ratio).rounded(.up)) + 64
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw ConcatenationError(message: "Could not allocate a conversion buffer for the recording.")
            }
            var consumed = false
            var conversionError: NSError?
            converter.convert(to: outputBuffer, error: &conversionError) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return inputBuffer
            }
            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0 {
                try writer.write(from: outputBuffer)
            }
        }
        // A rate converter holds a tail of frames until it is told the input is over.
        if let converter, needsConversion, sourceFormat.sampleRate != target.sampleRate {
            guard let tail = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: framesPerRead) else { return }
            var conversionError: NSError?
            converter.convert(to: tail, error: &conversionError) { _, status in
                status.pointee = .endOfStream
                return nil
            }
            if let conversionError { throw conversionError }
            if tail.frameLength > 0 {
                try writer.write(from: tail)
            }
        }
    }
}
