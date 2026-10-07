import AVFoundation
import FluidAudio
import Foundation

/// Splits a meeting's separated tracks file back into the two sources live
/// transcription saw: the echo-cancelled mic ("You") and system audio (everyone else).
///
/// The playable recording is a mono mix, so transcribing it can only guess who spoke.
/// The tracks file keeps the sources apart (mic left, system right) so a retranscription
/// labels the user from the mic and diarizes only the far side, as the live meeting did.
enum MeetingRecordingTracks {
    struct SplitError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Split {
        let mic: URL
        let system: URL
    }

    private static let framesPerRead: AVAudioFrameCount = 32_768

    /// Writes the two channels of `tracksURL` as mono 16-bit WAVs inside `directory`.
    nonisolated static func split(_ tracksURL: URL, into directory: URL) throws -> Split {
        let source = try AVAudioFile(forReading: tracksURL)
        let format = source.processingFormat
        guard format.channelCount == 2 else {
            throw SplitError(message: "Meeting tracks have \(format.channelCount) channel(s); expected 2.")
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerRead),
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: format.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: framesPerRead)
        else {
            throw SplitError(message: "Could not allocate buffers to split the meeting tracks.")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let micURL = directory.appendingPathComponent("mic.wav")
        let systemURL = directory.appendingPathComponent("system.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            // Scoped so both writers close, and flush their headers, before the URLs return.
            do {
                let micWriter = try AVAudioFile(
                    forWriting: micURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
                )
                let systemWriter = try AVAudioFile(
                    forWriting: systemURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
                )
                while source.framePosition < source.length {
                    try source.read(into: input, frameCount: framesPerRead)
                    let frames = input.frameLength
                    guard frames > 0, let channels = input.floatChannelData,
                          let mono = monoBuffer.floatChannelData else { break }
                    monoBuffer.frameLength = frames
                    for (channel, writer) in [(0, micWriter), (1, systemWriter)] {
                        mono[0].update(from: channels[channel], count: Int(frames))
                        try writer.write(from: monoBuffer)
                    }
                }
            }
            return Split(mic: micURL, system: systemURL)
        } catch {
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: systemURL)
            throw error
        }
    }

    // MARK: - Retranscription

    struct Retranscription {
        let transcript: String
        let rawASR: String
        let cleaned: String
    }

    typealias Transcribe = (URL) async throws -> MeetingTranscriptionEvidence

    /// Transcribes each side of the tracks as the live meeting did: the mic is the
    /// user, and only system audio is diarized into other speakers.
    static func retranscribe(
        tracks tracksURL: URL,
        meetingStart: Date,
        coordinator: TranscriptionCoordinator,
        transcribe: Transcribe
    ) async throws -> Retranscription {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imla-meeting-retranscription", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let sources = try await Task.detached(priority: .userInitiated) {
            try Self.split(tracksURL, into: workDirectory)
        }.value
        let mic = try await transcribeInSpeechChunks(sources.mic, coordinator: coordinator, transcribe: transcribe)
        let system = try await transcribeInSpeechChunks(sources.system, coordinator: coordinator, transcribe: transcribe)
        let diarization = try? await coordinator.diarizeSystemAudio(at: sources.system)
        return Retranscription(
            transcript: TranscriptFormatter.merge(
                micSegments: mic.segments,
                systemSegments: system.segments,
                diarizationSegments: diarization?.segments,
                meetingStart: meetingStart
            ),
            rawASR: "You:\n\(mic.rawText)\n\nOthers:\n\(system.rawText)",
            cleaned: "You:\n\(mic.cleanedText)\n\nOthers:\n\(system.cleanedText)"
        )
    }

    /// Recordings saved before tracks existed only have the mono mix. The user's voice
    /// cannot be told apart there, so the best available is diarizing everyone into
    /// numbered speakers, as an audio import does.
    static func retranscribe(
        mix recordingURL: URL,
        meetingStart: Date,
        coordinator: TranscriptionCoordinator,
        transcribe: Transcribe
    ) async throws -> Retranscription {
        let mix = try await transcribeInSpeechChunks(recordingURL, coordinator: coordinator, transcribe: transcribe)
        let diarization = try? await coordinator.diarizeSystemAudio(at: recordingURL)
        let speakerCount = Set(diarization?.segments.map(\.speakerId) ?? []).count
        let transcript = speakerCount > 1
            ? TranscriptFormatter.merge(
                micSegments: [],
                systemSegments: mix.segments,
                diarizationSegments: diarization?.segments,
                meetingStart: meetingStart
            )
            : mix.cleanedText
        return Retranscription(transcript: transcript, rawASR: mix.rawText, cleaned: mix.cleanedText)
    }

    private struct TrackTranscription {
        var segments: [SpeechSegment] = []
        var rawText = ""
        var cleanedText = ""
    }

    /// Most backends return a whole file as one segment stamped at zero, which would
    /// collapse a meeting into one block per side. Transcribing speech regions one at a
    /// time, as the live meeting's chunks do, keeps every turn at its real time, and
    /// never sends silence to a recognizer that hallucinates on it.
    private static func transcribeInSpeechChunks(
        _ url: URL,
        coordinator: TranscriptionCoordinator,
        transcribe: Transcribe
    ) async throws -> TrackTranscription {
        let samples = try AudioConverter().resampleAudioFile(url)
        let sampleRate = Double(VadManager.sampleRate)
        guard let vadManager = await coordinator.getVadManager() else {
            let evidence = try await transcribe(url)
            return TrackTranscription(
                segments: SystemTurnNormalizer.normalize(
                    result: evidence.cleaned,
                    startTime: 0,
                    endTime: Double(samples.count) / sampleRate
                ),
                rawText: evidence.raw.text,
                cleanedText: evidence.cleaned.text
            )
        }
        let regions = try await vadManager.segmentSpeech(
            samples,
            config: VadSegmentationConfig(maxSpeechDuration: 10.0, speechPadding: 0.15)
        )
        var result = TrackTranscription()
        var rawTexts: [String] = []
        var cleanedTexts: [String] = []
        for region in regions {
            try Task.checkCancellation()
            let start = max(0, region.startSample(sampleRate: VadManager.sampleRate))
            let end = min(samples.count, region.endSample(sampleRate: VadManager.sampleRate))
            guard end > start else { continue }
            let chunkURL = try WavWriter.writeTemporaryWAV(
                samples: Array(samples[start..<end]),
                directoryName: "imla-meeting-retranscription"
            )
            defer { try? FileManager.default.removeItem(at: chunkURL) }
            let evidence = try await transcribe(chunkURL)
            result.segments.append(contentsOf: SystemTurnNormalizer.normalize(
                result: evidence.cleaned,
                startTime: Double(start) / sampleRate,
                endTime: Double(end) / sampleRate
            ))
            rawTexts.append(evidence.raw.text)
            cleanedTexts.append(evidence.cleaned.text)
        }
        result.rawText = rawTexts.filter { !$0.isEmpty }.joined(separator: "\n")
        result.cleanedText = cleanedTexts.filter { !$0.isEmpty }.joined(separator: " ")
        return result
    }
}
