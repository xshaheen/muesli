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
        /// Set when speaker identification failed and the transcript kept fewer labels.
        let warning: String?
    }

    enum Stage {
        case transcribingMic
        case transcribingSystem
        case transcribingMix
        case identifyingSpeakers
    }

    typealias Transcribe = @Sendable (URL, @escaping @Sendable (Double, String) async -> Void) async throws -> MeetingTranscriptionEvidence
    typealias Progress = @Sendable (Stage, Double, String) async -> Void

    /// Transcribes each side of the tracks as the live meeting did: the mic is the
    /// user, and only system audio is diarized into other speakers. Both sides replay
    /// through bounded windows, so a long meeting never sits in memory as PCM.
    static func retranscribe(
        tracks tracksURL: URL,
        meetingStart: Date,
        coordinator: TranscriptionCoordinator,
        transcribe: Transcribe,
        progress: @escaping Progress
    ) async throws -> Retranscription {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imla-meeting-retranscription", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let sources = try await Task.detached(priority: .userInitiated) {
            try Self.split(tracksURL, into: workDirectory)
        }.value
        let mic = try await transcribe(sources.mic) { await progress(.transcribingMic, $0, $1) }
        let system = try await transcribe(sources.system) { await progress(.transcribingSystem, $0, $1) }
        try Task.checkCancellation()
        let diarization = try await RecordedTranscriptDiarization.identify {
            await coordinator.preloadDiarizer(trigger: .retranscription)
            return try await coordinator.diarizeRecordedAudio(at: sources.system) {
                await progress(.identifyingSpeakers, $0, "")
            }
        }
        return Retranscription(
            transcript: TranscriptFormatter.merge(
                micSegments: mic.cleaned.segments,
                systemSegments: system.cleaned.segments,
                diarizationSegments: diarization.segments,
                meetingStart: meetingStart,
                conservativeSpeakerAttribution: true
            ),
            rawASR: "You:\n\(mic.raw.text)\n\nOthers:\n\(system.raw.text)",
            cleaned: "You:\n\(mic.cleaned.text)\n\nOthers:\n\(system.cleaned.text)",
            warning: diarization.warning
        )
    }

    /// Recordings saved before tracks existed only have the mono mix. The user's voice
    /// cannot be told apart there, so the best available is diarizing everyone into
    /// numbered speakers, as an audio import does.
    static func retranscribe(
        mix recordingURL: URL,
        meetingStart: Date,
        coordinator: TranscriptionCoordinator,
        transcribe: Transcribe,
        progress: @escaping Progress
    ) async throws -> Retranscription {
        let mix = try await transcribe(recordingURL) { await progress(.transcribingMix, $0, $1) }
        try Task.checkCancellation()
        let diarization = try await RecordedTranscriptDiarization.identify {
            await coordinator.preloadDiarizer(trigger: .retranscription)
            return try await coordinator.diarizeRecordedAudio(at: recordingURL) {
                await progress(.identifyingSpeakers, $0, "")
            }
        }
        let transcript = AudioFileImportController.formatTranscriptWithSpeakers(
            transcription: mix.cleaned,
            diarizationSegments: diarization.segments ?? [],
            meetingStart: meetingStart
        )
        return Retranscription(
            transcript: transcript,
            rawASR: mix.raw.text,
            cleaned: mix.cleaned.text,
            warning: diarization.warning
        )
    }
}
