import AppKit
import AVFoundation
import FluidAudio
import Foundation
import MuesliCore
import UniformTypeIdentifiers

/// Handles importing audio files (m4a, mp4, wav, mp3) for offline transcription.
/// Converts the source file to 16kHz mono WAV, transcribes it, optionally runs
/// speaker diarization, and creates a meeting record with the result.
enum AudioFileImportController {
    static let supportedExtensions: Set<String> = ["m4a", "mp4", "wav", "mp3"]

    private static let allowedTypes: [UTType] = {
        var types: [UTType] = [
            .wav,
            .mp3,
            .mpeg4Audio,
            .appleProtectedMPEG4Audio,
        ]
        if let m4a = UTType(filenameExtension: "m4a") { types.append(m4a) }
        if let mp4 = UTType(filenameExtension: "mp4") { types.append(mp4) }
        return types
    }()

    static func isSupportedFileURL(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - File Selection

    /// Presents an NSOpenPanel for selecting an audio file and returns the chosen URL.
    static func selectFile() async -> URL? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.title = "Import Audio File for Transcription"
                panel.message = "Choose an audio file (m4a, mp4, wav, mp3)"
                panel.allowedContentTypes = allowedTypes
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.canCreateDirectories = false

                NSApp.activate()
                if let window = NSApp.keyWindow {
                    panel.beginSheetModal(for: window) { response in
                        continuation.resume(
                            returning: response == .OK ? panel.url : nil
                        )
                    }
                } else {
                    panel.begin { response in
                        continuation.resume(
                            returning: response == .OK ? panel.url : nil
                        )
                    }
                }
            }
        }
    }

    // MARK: - Audio Conversion

    enum ImportError: Error, Equatable, LocalizedError {
        case unsupportedFormat
        case conversionFailed(String)
        case noAudioTracks
        case readError(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "This audio file format is not supported."
            case .conversionFailed(let detail):
                return "Could not convert the audio file. \(detail)"
            case .noAudioTracks:
                return "The selected file does not contain any audio tracks."
            case .readError(let detail):
                return "Could not read the audio file. \(detail)"
            }
        }
    }

    /// Converts the source audio file to 16kHz mono WAV for transcription.
    /// Returns the temporary WAV URL and the audio duration in seconds.
    static func convertToWAV(sourceURL: URL) async throws -> (wavURL: URL, duration: TimeInterval) {
        guard isSupportedFileURL(sourceURL) else {
            throw ImportError.unsupportedFormat
        }
        try Task.checkCancellation()

        if let compatibleWAV = try compatibleWAVInfo(sourceURL: sourceURL) {
            let outputURL = try temporaryWAVURL()
            try FileManager.default.copyItem(at: sourceURL, to: outputURL)
            return (outputURL, compatibleWAV.duration)
        }

        let duration = try await audioDuration(sourceURL: sourceURL)
        try Task.checkCancellation()

        let samples: [Float]
        do {
            samples = try AudioConverter().resampleAudioFile(sourceURL)
        } catch {
            samples = try await decodeSamplesWithAssetReader(sourceURL: sourceURL)
        }
        try Task.checkCancellation()

        guard !samples.isEmpty else {
            throw ImportError.noAudioTracks
        }

        let wavURL = try WavWriter.writeTemporaryWAV(samples: samples, directoryName: "muesli-import")
        let resolvedDuration = duration ?? Double(samples.count) / Double(WavWriter.sampleRate)
        guard resolvedDuration > 0, resolvedDuration.isFinite else {
            try? FileManager.default.removeItem(at: wavURL)
            throw ImportError.readError("Invalid audio duration.")
        }
        return (wavURL, resolvedDuration)
    }

    // MARK: - Import Pipeline

    enum ImportFallbackReason: String, Hashable, Sendable {
        case diarizationUnavailable = "diarization_unavailable"
        case diarizationFailed = "diarization_failed"
        case titleGeneration = "title_generation"
        case summaryGeneration = "summary_generation"
    }

    struct ImportFallbackSummary: Equatable, Sendable {
        private(set) var reasons: Set<ImportFallbackReason> = []

        var usedFallback: Bool { !reasons.isEmpty }
        var usedSummaryFallback: Bool { reasons.contains(.summaryGeneration) }

        mutating func record(_ reason: ImportFallbackReason) {
            reasons.insert(reason)
        }
    }

    enum ImportStageTiming {
        static func elapsedMilliseconds(since startedAt: Date, now: Date = Date()) -> Int {
            max(Int(now.timeIntervalSince(startedAt) * 1_000), 0)
        }
    }

    struct ImportResult {
        let meetingID: Int64
        let title: String
        let rawTranscript: String
        let formattedNotes: String
        let durationSeconds: Double
        let wordCount: Int
        let completedAt: Date
        let fallbackSummary: ImportFallbackSummary

        var usedFallback: Bool { fallbackSummary.usedFallback }
        var usedSummaryFallback: Bool { fallbackSummary.usedSummaryFallback }
    }

    struct ImportContext {
        let config: AppConfig
        let backend: BackendOption
        let transcriptionCoordinator: TranscriptionCoordinator
        let templateSnapshot: MeetingTemplateSnapshot
    }

    /// Runs the full import pipeline: convert, transcribe, diarize, format, persist, summarize.
    static func importAudioFile(
        sourceURL: URL,
        title: String,
        controller: MuesliController,
        context: ImportContext,
        sessionTrace: SessionRunTrace? = nil,
        progress: @escaping (String) -> Void
    ) async throws -> ImportResult {
        progress("Converting audio file...")
        await sessionTrace?.recordStageStarted("audio_conversion")
        let conversionStartedAt = Date()
        let wavURL: URL
        let duration: TimeInterval
        do {
            (wavURL, duration) = try await convertToWAV(sourceURL: sourceURL)
            let elapsedMilliseconds = stageElapsedMilliseconds(since: conversionStartedAt)
            await sessionTrace?.recordStageCompleted(
                "audio_conversion",
                elapsedMilliseconds: elapsedMilliseconds
            )
        } catch {
            let elapsedMilliseconds = stageElapsedMilliseconds(since: conversionStartedAt)
            await sessionTrace?.recordStageFailed(
                "audio_conversion",
                elapsedMilliseconds: elapsedMilliseconds
            )
            throw error
        }
        defer { try? FileManager.default.removeItem(at: wavURL) }

        try Task.checkCancellation()

        let config = context.config
        let backend = context.backend
        let transcriptionCoordinator = context.transcriptionCoordinator

        progress("Loading transcription model...")
        await sessionTrace?.recordStageStarted("model_preload")
        let preloadStartedAt = Date()
        do {
            try await transcriptionCoordinator.preloadRequired(
                backend: backend,
                enablePostProcessor: false,
                includeMeetingHelpers: true,
                meetingHelperTrigger: .audioImport
            )
            let elapsedMilliseconds = stageElapsedMilliseconds(since: preloadStartedAt)
            await sessionTrace?.recordStageCompleted(
                "model_preload",
                elapsedMilliseconds: elapsedMilliseconds
            )
        } catch {
            let elapsedMilliseconds = stageElapsedMilliseconds(since: preloadStartedAt)
            await sessionTrace?.recordStageFailed(
                "model_preload",
                elapsedMilliseconds: elapsedMilliseconds
            )
            throw error
        }

        try Task.checkCancellation()

        // Run VAD to skip silent files (prevents Cohere hallucinations on silence)
        if let vadManager = await transcriptionCoordinator.getVadManager() {
            do {
                let vadResults = try await vadManager.process(wavURL)
                let hasSpeech = vadResults.contains { $0.probability > 0.5 }
                if !hasSpeech {
                    throw ImportError.readError("No speech detected in the selected audio file.")
                }
            } catch let error as ImportError {
                throw error
            } catch {
                fputs("[import] VAD check failed, transcribing anyway: \(error)\n", stderr)
            }
        }

        try Task.checkCancellation()

        progress("Transcribing audio...")
        await sessionTrace?.recordStageStarted("transcribing_audio")
        let transcriptionStartedAt = Date()
        let transcriptionEvidence: MeetingTranscriptionEvidence
        do {
            transcriptionEvidence = try await transcriptionCoordinator.transcribeMeetingWithEvidence(
                at: wavURL,
                backend: backend,
                profile: config.languageProfile,
                customWords: config.customWords
            )
        } catch {
            let elapsedMilliseconds = stageElapsedMilliseconds(since: transcriptionStartedAt)
            await sessionTrace?.recordStageFailed(
                "transcribing_audio",
                elapsedMilliseconds: elapsedMilliseconds
            )
            throw error
        }
        let transcriptionElapsedMilliseconds = stageElapsedMilliseconds(since: transcriptionStartedAt)
        let recognizerTranscript = transcriptionEvidence.raw.text
        await sessionTrace?.storeArtifact(recognizerTranscript, kind: .rawASR)
        let transcription = transcriptionEvidence.cleaned
        let cleanedTranscript = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTranscript.isEmpty else {
            await sessionTrace?.recordStageFailed(
                "transcribing_audio",
                elapsedMilliseconds: transcriptionElapsedMilliseconds,
                metadata: ["reason": "empty_cleanup_result"]
            )
            throw ImportError.readError("No speech was transcribed from the selected audio file.")
        }
        await sessionTrace?.recordStageCompleted(
            "transcribing_audio",
            elapsedMilliseconds: transcriptionElapsedMilliseconds
        )

        try Task.checkCancellation()

        // Run speaker diarization if available
        var diarizedTranscript = cleanedTranscript
        var fallbackSummary = ImportFallbackSummary()
        var diarizationFallbackReason: ImportFallbackReason?
        await sessionTrace?.recordStageStarted("speaker_diarization")
        let diarizationStartedAt = Date()
        if let diarizerManager = await transcriptionCoordinator.getDiarizerManager(),
           diarizerManager.isAvailable {
            progress("Identifying speakers...")
            do {
                let converter = AudioConverter()
                let samples = try converter.resampleAudioFile(wavURL)
                try Task.checkCancellation()
                let diarizationResult = try diarizerManager.performCompleteDiarization(
                    samples,
                    sampleRate: 16000
                )
                if !diarizationResult.segments.isEmpty {
                    diarizedTranscript = formatTranscriptWithSpeakers(
                        transcription: transcription,
                        diarizationSegments: diarizationResult.segments,
                        meetingStart: importedTranscriptTimelineStart()
                    )
                }
            } catch is CancellationError {
                let elapsedMilliseconds = stageElapsedMilliseconds(since: diarizationStartedAt)
                await sessionTrace?.recordStageFailed(
                    "speaker_diarization",
                    elapsedMilliseconds: elapsedMilliseconds
                )
                throw CancellationError()
            } catch {
                fputs("[import] diarization failed, using raw transcript: \(error)\n", stderr)
                fallbackSummary.record(.diarizationFailed)
                diarizationFallbackReason = .diarizationFailed
            }
        } else {
            fallbackSummary.record(.diarizationUnavailable)
            diarizationFallbackReason = .diarizationUnavailable
        }
        let diarizationElapsedMilliseconds = stageElapsedMilliseconds(since: diarizationStartedAt)
        if let diarizationFallbackReason {
            await sessionTrace?.recordFallbackStarted(
                "speaker_diarization",
                metadata: [
                    "from": "diarized_transcript",
                    "reason": diarizationFallbackReason.rawValue,
                    "to": "cleaned_transcript",
                ]
            )
        }
        await sessionTrace?.recordStageCompleted(
            "speaker_diarization",
            elapsedMilliseconds: diarizationElapsedMilliseconds,
            metadata: fallbackSummary.reasons.contains(.diarizationUnavailable)
                || fallbackSummary.reasons.contains(.diarizationFailed)
                ? ["outcome": "fallback"]
                : [:]
        )
        await sessionTrace?.storeArtifact(cleanedTranscript, kind: .cleanupResult)
        await sessionTrace?.storeArtifact(DictationDictionaryTrace.emptyContent, kind: .dictionaryChanges)
        await sessionTrace?.storeArtifact(diarizedTranscript, kind: .finalOutput)

        try Task.checkCancellation()

        let wordCount = DictationStore.countWords(in: diarizedTranscript)
        let generatedTitle: String
        var usedTitleFallback = false
        progress("Generating title...")
        await sessionTrace?.recordStageStarted("title_generation")
        let titleStartedAt = Date()
        if let autoTitle = await MeetingSummaryClient.generateTitle(transcript: diarizedTranscript, config: config),
           !autoTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            generatedTitle = autoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            generatedTitle = title
            fallbackSummary.record(.titleGeneration)
            usedTitleFallback = true
        }
        let titleElapsedMilliseconds = stageElapsedMilliseconds(since: titleStartedAt)
        if usedTitleFallback {
            await sessionTrace?.recordFallbackStarted(
                "title_generation",
                metadata: [
                    "from": "generated_title",
                    "reason": ImportFallbackReason.titleGeneration.rawValue,
                    "to": "source_filename",
                ]
            )
        }
        await sessionTrace?.recordStageCompleted(
            "title_generation",
            elapsedMilliseconds: titleElapsedMilliseconds,
            metadata: fallbackSummary.reasons.contains(.titleGeneration)
                ? ["outcome": "fallback"]
                : [:]
        )

        try Task.checkCancellation()

        progress("Generating summary...")
        let templateSnapshot = context.templateSnapshot
        let formattedNotes: String
        var usedSummaryFallback = false
        await sessionTrace?.recordStageStarted("summary_generation")
        let summaryStartedAt = Date()
        do {
            formattedNotes = try await MeetingSummaryClient.summarize(
                transcript: diarizedTranscript,
                meetingTitle: generatedTitle,
                config: config,
                template: templateSnapshot,
                existingNotes: nil,
                manualNotesToRetain: ""
            )
        } catch {
            fputs("[import] summary generation failed: \(error)\n", stderr)
            fallbackSummary.record(.summaryGeneration)
            usedSummaryFallback = true
            formattedNotes = MeetingSummaryClient.summaryFailureNotes(
                transcript: diarizedTranscript,
                meetingTitle: generatedTitle,
                error: error,
                manualNotes: "",
                languageProfile: config.languageProfile
            )
        }
        let summaryElapsedMilliseconds = stageElapsedMilliseconds(since: summaryStartedAt)
        if usedSummaryFallback {
            await sessionTrace?.recordFallbackStarted(
                "summary_generation",
                metadata: [
                    "from": "generated_summary",
                    "reason": ImportFallbackReason.summaryGeneration.rawValue,
                    "to": "failure_notes",
                ]
            )
        }
        await sessionTrace?.recordStageCompleted(
            "summary_generation",
            elapsedMilliseconds: summaryElapsedMilliseconds,
            metadata: fallbackSummary.reasons.contains(.summaryGeneration)
                ? ["outcome": "fallback"]
                : [:]
        )

        try Task.checkCancellation()

        progress("Saving...")
        let now = Date()
        let startTime = now.addingTimeInterval(-duration)
        await sessionTrace?.recordStageStarted("meeting_persistence")
        let persistenceStartedAt = Date()
        let meetingID: Int64
        do {
            // Persist the converted WAV as a saved recording so retranscription works.
            let savedRecordingPath = try persistRecording(wavURL: wavURL, title: generatedTitle)
            meetingID = try await controller.persistImportedAudioMeetingWithoutPublishing(
                title: generatedTitle,
                calendarEventID: nil,
                startTime: startTime,
                endTime: now,
                rawTranscript: diarizedTranscript,
                formattedNotes: formattedNotes,
                micAudioPath: nil,
                systemAudioPath: nil,
                savedRecordingPath: savedRecordingPath,
                sessionID: sessionTrace?.sessionID ?? UUID(),
                selectedTemplateID: templateSnapshot.id,
                selectedTemplateName: templateSnapshot.name,
                selectedTemplateKind: templateSnapshot.kind,
                selectedTemplatePrompt: templateSnapshot.prompt
            )
            let elapsedMilliseconds = stageElapsedMilliseconds(since: persistenceStartedAt)
            await sessionTrace?.recordStageCompleted(
                "meeting_persistence",
                elapsedMilliseconds: elapsedMilliseconds
            )
        } catch {
            let elapsedMilliseconds = stageElapsedMilliseconds(since: persistenceStartedAt)
            await sessionTrace?.recordStageFailed(
                "meeting_persistence",
                elapsedMilliseconds: elapsedMilliseconds
            )
            throw error
        }

        return ImportResult(
            meetingID: meetingID,
            title: generatedTitle,
            rawTranscript: diarizedTranscript,
            formattedNotes: formattedNotes,
            durationSeconds: duration,
            wordCount: wordCount,
            completedAt: now,
            fallbackSummary: fallbackSummary
        )
    }

    // MARK: - Helpers

    private static func stageElapsedMilliseconds(since startedAt: Date) -> Int {
        ImportStageTiming.elapsedMilliseconds(since: startedAt)
    }

    private static func temporaryWAVURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-import", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("import_\(UUID().uuidString).wav")
    }

    private struct CompatibleWAVInfo {
        let duration: TimeInterval
    }

    private static func compatibleWAVInfo(sourceURL: URL) throws -> CompatibleWAVInfo? {
        guard sourceURL.pathExtension.lowercased() == "wav" else { return nil }
        let file = try AVAudioFile(forReading: sourceURL)
        let fileFormat = file.fileFormat
        guard fileFormat.sampleRate == Double(WavWriter.sampleRate),
              fileFormat.channelCount == UInt32(WavWriter.channels),
              fileFormat.commonFormat == .pcmFormatInt16 else {
            return nil
        }
        let duration = Double(file.length) / fileFormat.sampleRate
        guard duration > 0, duration.isFinite else {
            throw ImportError.readError("Invalid audio duration.")
        }
        return CompatibleWAVInfo(duration: duration)
    }

    private static func audioDuration(sourceURL: URL) async throws -> TimeInterval? {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.load(.tracks)
        guard tracks.contains(where: { $0.mediaType == .audio }) else {
            throw ImportError.noAudioTracks
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        return duration > 0 && duration.isFinite ? duration : nil
    }

    private static func decodeSamplesWithAssetReader(sourceURL: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.load(.tracks)
        guard let audioTrack = tracks.first(where: { $0.mediaType == .audio }) else {
            throw ImportError.noAudioTracks
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ImportError.conversionFailed("Could not read audio samples from the selected file.")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw ImportError.readError(reader.error?.localizedDescription ?? "Unknown read error")
        }

        let converter = AudioConverter()
        var samples: [Float] = []
        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }
            samples.append(contentsOf: try converter.resampleSampleBuffer(sampleBuffer))
        }

        guard reader.status == .completed else {
            throw ImportError.readError(reader.error?.localizedDescription ?? "Read did not complete")
        }
        return samples
    }

    /// Copies the converted WAV to the meeting-recordings directory so the imported
    /// meeting can be retranscribed later.
    private static func persistRecording(wavURL: URL, title: String) throws -> String {
        let recordingsDirectory = AppIdentity.supportDirectoryURL
            .appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let datePrefix = dateFormatter.string(from: Date())
        let safeTitle = safeFilenameComponent(title)
        let filename = "\(datePrefix)_\(safeTitle)_\(UUID().uuidString.prefix(8)).wav"
        let destinationURL = recordingsDirectory.appendingPathComponent(filename)

        try FileManager.default.copyItem(at: wavURL, to: destinationURL)
        return destinationURL.path
    }

    private static func safeFilenameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        return collapsed.isEmpty ? "Imported-Recording" : String(collapsed.prefix(80))
    }

    private static func importedTranscriptTimelineStart() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    /// Formats transcript text with speaker labels based on diarization segments.
    /// When diarization identifies multiple speakers, the transcript is annotated with
    /// speaker labels using ASR segment timestamps so both the user and summarizer can
    /// attribute spoken text to individual speakers without inventing text boundaries.
    static func formatTranscriptWithSpeakers(
        transcription: SpeechTranscriptionResult,
        diarizationSegments: [TimedSpeakerSegment],
        meetingStart: Date
    ) -> String {
        let rawText = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty, !diarizationSegments.isEmpty else { return rawText }

        let speakerCount = Set(diarizationSegments.map(\.speakerId)).count
        guard speakerCount > 1 else { return rawText }

        if rawText.range(of: #"(?m)^\[[0-9]{2}:[0-9]{2}(?::[0-9]{2})?\]\s+(You|Others|Speaker\s+\d+):"#, options: .regularExpression) != nil {
            return rawText
        }

        let transcribedSegments = transcription.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !transcribedSegments.isEmpty else { return rawText }

        let formatted = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: transcribedSegments,
            diarizationSegments: diarizationSegments,
            meetingStart: meetingStart
        )
        return formatted.isEmpty ? rawText : formatted
    }

    /// Backward-compatible helper for tests and any callers that only have raw text.
    static func formatTranscriptWithSpeakers(
        rawText: String,
        diarizationSegments: [TimedSpeakerSegment],
        duration: TimeInterval
    ) -> String {
        let transcription = SpeechTranscriptionResult(
            text: rawText,
            segments: [SpeechSegment(start: 0, end: max(duration, 0.1), text: rawText)]
        )
        return formatTranscriptWithSpeakers(
            transcription: transcription,
            diarizationSegments: diarizationSegments,
            meetingStart: importedTranscriptTimelineStart()
        )
    }
}
