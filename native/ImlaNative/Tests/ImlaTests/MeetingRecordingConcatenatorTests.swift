import AVFoundation
import Foundation
import Testing
@testable import ImlaNativeApp

@Suite("Meeting recording concatenation")
struct MeetingRecordingConcatenatorTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-concat-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A mono 16-bit WAV of `seconds` at `sampleRate`, filled with a constant so the
    /// content survives a codec round trip recognisably.
    private func writeWAV(at url: URL, seconds: Double, sampleRate: Double, value: Float = 0.25) throws -> AVAudioFrameCount {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = value }
        try file.write(from: buffer)
        return frames
    }

    @Test("WAV output holds every frame of both inputs in order")
    func wavConcatenationIsExact() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prior = root.appendingPathComponent("prior.wav")
        let segment = root.appendingPathComponent("segment.wav")
        let priorFrames = try writeWAV(at: prior, seconds: 1.0, sampleRate: 48_000, value: 0.25)
        let segmentFrames = try writeWAV(at: segment, seconds: 0.5, sampleRate: 48_000, value: -0.5)
        let output = root.appendingPathComponent("merged.wav")

        try MeetingRecordingConcatenator.concatenate(prior: prior, segment: segment, to: output, format: .wav)

        let merged = try AVAudioFile(forReading: output)
        #expect(AVAudioFrameCount(merged.length) == priorFrames + segmentFrames)
        let buffer = AVAudioPCMBuffer(pcmFormat: merged.processingFormat, frameCapacity: AVAudioFrameCount(merged.length))!
        try merged.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        #expect(abs(samples[Int(priorFrames) - 1] - 0.25) < 0.01)
        #expect(abs(samples[Int(priorFrames)] + 0.5) < 0.01)
    }

    @Test("a prior recording at another sample rate is resampled to the segment's rate")
    func mixedSampleRatesFollowTheSegment() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prior = root.appendingPathComponent("prior.wav")
        let segment = root.appendingPathComponent("segment.wav")
        _ = try writeWAV(at: prior, seconds: 1.0, sampleRate: 44_100)
        _ = try writeWAV(at: segment, seconds: 0.5, sampleRate: 48_000)
        let output = root.appendingPathComponent("merged.wav")

        try MeetingRecordingConcatenator.concatenate(prior: prior, segment: segment, to: output, format: .wav)

        let merged = try AVAudioFile(forReading: output)
        #expect(merged.processingFormat.sampleRate == 48_000)
        let expected = 1.5 * 48_000
        #expect(abs(Double(merged.length) - expected) < 200)
    }

    @Test("M4A output encodes both inputs and keeps the combined duration")
    func m4aConcatenationKeepsDuration() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prior = root.appendingPathComponent("prior.wav")
        let segment = root.appendingPathComponent("segment.wav")
        _ = try writeWAV(at: prior, seconds: 1.0, sampleRate: 48_000)
        _ = try writeWAV(at: segment, seconds: 0.5, sampleRate: 48_000)
        let output = root.appendingPathComponent("merged.m4a")

        try MeetingRecordingConcatenator.concatenate(prior: prior, segment: segment, to: output, format: .m4a)

        let merged = try AVAudioFile(forReading: output)
        let seconds = Double(merged.length) / merged.processingFormat.sampleRate
        #expect(abs(seconds - 1.5) < 0.1)
    }

    @Test("a failed merge leaves no partial output behind")
    func failureRemovesPartialOutput() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prior = root.appendingPathComponent("prior.wav")
        let notAudio = root.appendingPathComponent("segment.wav")
        _ = try writeWAV(at: prior, seconds: 0.2, sampleRate: 48_000)
        try Data(repeating: 0x00, count: 64).write(to: notAudio)
        let output = root.appendingPathComponent("merged.wav")

        #expect(throws: (any Error).self) {
            try MeetingRecordingConcatenator.concatenate(prior: prior, segment: notAudio, to: output, format: .wav)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
