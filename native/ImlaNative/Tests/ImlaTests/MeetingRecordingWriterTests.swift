import AVFoundation
import Foundation
import Testing
@testable import ImlaNativeApp

@Suite("MeetingRecordingWriter")
struct MeetingRecordingWriterTests {

    @Test("streaming writer merges mic and system samples incrementally")
    func writerMergesIncrementally() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1000, 2000, 3000, 4000], atSampleOffset: 0)
        writer.appendSystem([3000, -2000], atSampleOffset: 0)
        writer.appendSystem([500, 1500], atSampleOffset: 2)

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [2000, 0, 1750, 2750])
    }

    @Test("streaming writer flushes single-track tail on stop")
    func writerFlushesSingleTrackTail() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1200, -800, 400], atSampleOffset: 0)

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [1200, -800, 400])
    }

    @Test("pause boundary prevents unmatched samples from mixing across pause")
    func pauseBoundaryFlushesPendingSamples() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1000, 3000], atSampleOffset: 0)
        writer.markPauseBoundary()
        writer.appendSystem([5000, 7000], atSampleOffset: 2)

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [1000, 3000, 5000, 7000])
    }

    @Test("a stream resuming after the bounded stall window keeps its true offset")
    func resumedStreamDoesNotMixAgainstOldBacklog() throws {
        let writer = try MeetingRecordingWriter()
        // Slightly over 4s of mic against a stalled system stream drains more
        // than 1s of mic-only audio while retaining at most a 3s window.
        writer.appendMic([Int16](repeating: 1000, count: 64_002), atSampleOffset: 0)
        // The resumed system callback belongs at 4s, where it overlaps the
        // current mic samples, not at the 1s write cursor left by the drain.
        writer.appendSystem([3000, 3000], atSampleOffset: 64_000)

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples.count == 64_002)
        #expect(samples[15_999] == 1000)
        #expect(samples[16_000] == 1000)
        #expect(samples[63_999] == 1000)
        #expect(samples[64_000] == 2000)
        #expect(samples[64_001] == 2000)
    }

    @Test("timeline excludes paused wall time from retained recording offsets")
    func timelineExcludesPausedWallTime() {
        let second: UInt64 = 1_000_000_000
        var timeline = MeetingRecordingTimeline()
        timeline.start(at: second)

        let firstStart = timeline.sampleStartOffset(
            for: .mic,
            sampleCount: 16_000,
            callbackUptimeNanoseconds: 2 * second
        )
        timeline.pause(at: 2 * second)
        timeline.resume(at: 12 * second)
        let resumedStart = timeline.sampleStartOffset(
            for: .mic,
            sampleCount: 16_000,
            callbackUptimeNanoseconds: 13 * second
        )

        #expect(firstStart == 0)
        #expect(resumedStart == 16_000)
        #expect(timeline.sampleOffset(at: 13 * second) == 32_000)
    }

    @Test("delayed capture starts the shared timeline at the first buffer, not the request")
    func delayedCaptureUsesFirstBufferOrigin() {
        let second: UInt64 = 1_000_000_000
        let callbackDate = Date(timeIntervalSince1970: 110)
        let origin = MeetingCaptureOrigin(
            callbackEndUptimeNanoseconds: 11 * second,
            callbackEndDate: callbackDate,
            sampleCount: 16_000
        )
        var timeline = MeetingRecordingTimeline()

        #expect(origin.uptimeNanoseconds == 10 * second)
        #expect(origin.wallClockDate == Date(timeIntervalSince1970: 109))
        let didStart = timeline.startIfNeeded(at: origin.uptimeNanoseconds)
        #expect(didStart)

        let systemStart = timeline.sampleStartOffset(
            for: .system,
            sampleCount: 16_000,
            callbackUptimeNanoseconds: 11 * second
        )
        let micStart = timeline.sampleStartOffset(
            for: .mic,
            sampleCount: 16_000,
            callbackUptimeNanoseconds: 13 * second
        )
        var systemTiming = MeetingChunkTimingTracker()
        var micTiming = MeetingChunkTimingTracker()
        systemTiming.start(atSampleIndex: Int64(systemStart))
        micTiming.start(atSampleIndex: Int64(micStart))
        systemTiming.append(sampleCount: 16_000)
        micTiming.append(sampleCount: 16_000)

        #expect(systemStart == 0)
        #expect(micStart == 32_000)
        #expect(systemTiming.finish()?.startTimeSeconds == 0)
        #expect(micTiming.finish()?.startTimeSeconds == 2)
    }

    @Test("persistTemporaryRecording moves the temp wav when WAV is selected")
    func persistTemporaryRecordingMovesWAVFile() async throws {
        let writer = try MeetingRecordingWriter()
        writer.appendSystem([1200, -800, 400], atSampleOffset: 0)
        let tempURL = try #require(writer.stop())
        let supportDirectory = makeTemporaryDirectory()
        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)

        let savedURL = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: tempURL,
            meetingTitle: "Weekly Product Sync! With Very Long Title Extra Words",
            startedAt: startedAt,
            supportDirectory: supportDirectory,
            fileFormat: .wav
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
        #expect(savedURL.deletingLastPathComponent().lastPathComponent == "meeting-recordings")
        #expect(savedURL.lastPathComponent.hasSuffix("-weekly-product-sync-with-very-long.wav"))
        #expect(try readMonoPCM16WAVSamples(from: savedURL) == [1200, -800, 400])
    }

    @Test("persistTemporaryRecording transcodes to M4A by default")
    func persistTemporaryRecordingTranscodesToM4AByDefault() async throws {
        let writer = try MeetingRecordingWriter()
        writer.appendSystem(Array(repeating: Int16(1200), count: 16_000), atSampleOffset: 0)
        let tempURL = try #require(writer.stop())
        let supportDirectory = makeTemporaryDirectory()
        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)

        let savedURL = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: tempURL,
            meetingTitle: "Weekly Product Sync",
            startedAt: startedAt,
            supportDirectory: supportDirectory
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
        #expect(savedURL.pathExtension == "m4a")
        #expect(savedURL.deletingLastPathComponent().lastPathComponent == "meeting-recordings")
        #expect(savedURL.lastPathComponent.hasSuffix("-weekly-product-sync.m4a"))

        let file = try AVAudioFile(forReading: savedURL)
        #expect(file.length > 0)
    }

    @Test("tracks keep the cleaned mic left and system right while the mix keeps the raw mic")
    func writerKeepsSeparatedTracks() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1000, 2000, 3000], atSampleOffset: 0)
        writer.appendCleanedMic([100, 200, 300], atSampleOffset: 0)
        writer.appendSystem([-500, -600, -700], atSampleOffset: 0)

        let mixURL = try #require(writer.stop())
        let tracksURL = MeetingRecordingWriter.tracksURL(forRecording: mixURL)
        defer { MeetingRecordingWriter.removeTemporaryRecording(at: mixURL) }

        #expect(try readMonoPCM16WAVSamples(from: mixURL) == [250, 700, 1150])
        // Interleaved frames: left is "You", right is everyone else.
        #expect(try readMonoPCM16WAVSamples(from: tracksURL) == [100, -500, 200, -600, 300, -700])
        #expect(try AVAudioFile(forReading: tracksURL).fileFormat.channelCount == 2)
    }

    @Test("removing a temporary recording removes its tracks and cancel leaves nothing behind")
    func tracksFollowTheRecordingLifecycle() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendCleanedMic([1, 2], atSampleOffset: 0)
        writer.appendSystem([3, 4], atSampleOffset: 0)
        let mixURL = try #require(writer.stop())
        let tracksURL = MeetingRecordingWriter.tracksURL(forRecording: mixURL)
        #expect(tracksURL.lastPathComponent == mixURL.deletingPathExtension().lastPathComponent + ".tracks.wav")
        #expect(FileManager.default.fileExists(atPath: tracksURL.path))

        MeetingRecordingWriter.removeTemporaryRecording(at: mixURL)
        #expect(!FileManager.default.fileExists(atPath: mixURL.path))
        #expect(!FileManager.default.fileExists(atPath: tracksURL.path))

        let cancelled = try MeetingRecordingWriter()
        cancelled.appendCleanedMic([1, 2], atSampleOffset: 0)
        cancelled.appendSystem([3, 4], atSampleOffset: 0)
        cancelled.cancel()
        #expect(cancelled.stop() == nil)
    }

    @Test("persisting as M4A keeps the tracks stereo beside the recording, and they split back apart")
    func persistedTracksSplitBackIntoSources() async throws {
        let writer = try MeetingRecordingWriter()
        let count = 16_000
        writer.appendMic(Array(repeating: Int16(4000), count: count), atSampleOffset: 0)
        writer.appendCleanedMic(Array(repeating: Int16(8000), count: count), atSampleOffset: 0)
        writer.appendSystem(Array(repeating: Int16(0), count: count), atSampleOffset: 0)
        let tempURL = try #require(writer.stop())
        let supportDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let savedURL = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: tempURL,
            meetingTitle: "Tracks",
            startedAt: Date(timeIntervalSince1970: 1_711_000_000),
            supportDirectory: supportDirectory
        )
        let savedTracks = MeetingRecordingWriter.tracksURL(forRecording: savedURL)
        #expect(!FileManager.default.fileExists(atPath: MeetingRecordingWriter.tracksURL(forRecording: tempURL).path))
        #expect(savedTracks.lastPathComponent.hasSuffix("-tracks.tracks.m4a"))
        #expect(try AVAudioFile(forReading: savedTracks).fileFormat.channelCount == 2)

        let split = try MeetingRecordingTracks.split(savedTracks, into: supportDirectory.appendingPathComponent("split"))
        let mic = try AVAudioFile(forReading: split.mic)
        let system = try AVAudioFile(forReading: split.system)
        #expect(mic.fileFormat.channelCount == 1)
        #expect(system.fileFormat.channelCount == 1)
        // AAC is lossy and primes with silence, so compare energy, not samples.
        #expect(try rms(of: split.mic) > 0.1)
        #expect(try rms(of: split.system) < 0.01)
    }

    private func rms(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData)[0]
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<frames { sum += samples[index] * samples[index] }
        return (sum / Float(frames)).squareRoot()
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-writer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readMonoPCM16WAVSamples(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        #expect(String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        let sampleBytes = data.subdata(in: 44..<data.count)
        let count = sampleBytes.count / MemoryLayout<Int16>.size
        return sampleBytes.withUnsafeBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: Int16.self)
            return Array(buffer.prefix(count)).map(Int16.init(littleEndian:))
        }
    }
}
