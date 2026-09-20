import Atomics
import AVFoundation
import CTranscribe
import Foundation
import ImlaCore

enum CohereArabicModelStore {
    static let repository = "handy-computer/cohere-transcribe-arabic-07-2026-gguf"
    static let revision = "5e6b33c211458ac69347d297abb6d47a250c328f"
    static let filename = "cohere-transcribe-arabic-07-2026-Q8_0.gguf"
    static let byteCount: Int64 = 2_410_655_136
    static let sha256 = "910de5c9c57f9fd8a280e1701f9cd96f63768878c1ca9e4ecf23638a5e0fef16"

    static var cacheDirectory: URL {
        AppIdentity.supportDirectoryURL
            .appendingPathComponent("models/cohere-transcribe-arabic", isDirectory: true)
    }

    static var manifest: ModelDownloadManifest {
        ModelDownloadManifest(id: repository, version: revision, files: [
            ModelDownloadFile(
                relativePath: filename,
                remoteURL: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")!,
                expectedByteCount: byteCount,
                sha256: sha256
            ),
        ], maximumConcurrency: 1)
    }

    static func isAvailable(at directory: URL = cacheDirectory) -> Bool {
        let url = directory.appendingPathComponent(filename)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.int64Value == byteCount,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }

    static func resolve(
        directory: URL = cacheDirectory,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws -> URL {
        if !isAvailable(at: directory) {
            try await ModelDownloadCoordinator.shared.download(manifest, to: directory) { snapshot in
                progress?(snapshot.fractionCompleted ?? 0, "Downloading Cohere Transcribe Arabic…")
                progressSnapshot?(snapshot)
            }
        }
        guard isAvailable(at: directory) else { throw CohereArabicError.invalidModel }
        return directory.appendingPathComponent(filename)
    }
}

enum CohereArabicError: LocalizedError {
    case invalidModel
    case nativeFailure(UInt32)
    case audioConversion

    var errorDescription: String? {
        switch self {
        case .invalidModel: "Cohere Transcribe Arabic model is incomplete or invalid. Download it again."
        case .nativeFailure(let code): "Cohere Transcribe Arabic failed (status \(code))."
        case .audioConversion: "Could not convert the recording to 16 kHz mono audio."
        }
    }
}

/// Owns one session because transcribe.cpp cannot run concurrent inference on a shared model.
actor CohereArabicTranscriber {
    typealias ModelResolver = (URL, ((Double, String?) -> Void)?, ModelDownloadProgressHandler?) async throws -> URL
    private var session: OpaquePointer?
    private var generation = UUID()
    private let directory: URL
    private let resolveModel: ModelResolver

    // Native diagnostics can contain token text. Install this once before any
    // native model is loaded; report only status codes through our own errors.
    private static let configureLogging: Void = transcribe_log_set(nil, nil)

    init(
        directory: URL = CohereArabicModelStore.cacheDirectory,
        resolveModel: @escaping ModelResolver = CohereArabicModelStore.resolve
    ) {
        self.directory = directory
        self.resolveModel = resolveModel
    }

    deinit {
        transcribe_session_free(session)
    }

    func prepare(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        try Task.checkCancellation()
        if session != nil { return }
        let identity = generation
        // The download coordinator already coalesces transfers and detaches
        // cancelled callers. Sharing another Task here would couple their cancellation.
        let url = try await resolveModel(directory, progress, progressSnapshot)
        try Task.checkCancellation()
        guard identity == generation else { throw CancellationError() }
        if session != nil { return }
        let loading = ModelDownloadProgress.preparing(
            modelID: CohereArabicModelStore.repository, message: "Loading Cohere Transcribe Arabic…"
        )
        progress?(0.98, loading.message)
        progressSnapshot?(loading)
        _ = Self.configureLogging
        var loaded: OpaquePointer?
        let status = transcribe_open(url.path, nil, nil, &loaded)
        guard status == TRANSCRIBE_OK, let loaded else {
            throw CohereArabicError.nativeFailure(status.rawValue)
        }
        if Task.isCancelled {
            transcribe_session_free(loaded)
            throw CancellationError()
        }
        session = loaded
        progress?(1, nil)
        progressSnapshot?(loading.replacing(phase: .ready, message: "Model ready"))
    }

    func shutdown() {
        generation = UUID()
        transcribe_session_free(session)
        session = nil
    }

    func transcribe(wavURL: URL, language: TranscriptionLanguage) async throws -> (text: String, processingTime: Double) {
        guard language == .arabic || language == .english else {
            throw LanguageRoutingIncompatibility.languageUnsupported(language)
        }
        try await prepare()
        guard let session else { throw CancellationError() }
        let cancelled = ManagedAtomic(false)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let start = CFAbsoluteTimeGetCurrent()
            let reader = try CohereArabicAudioReader(url: wavURL)
            let context = Unmanaged.passUnretained(cancelled).toOpaque()
            transcribe_set_abort_callback(session, { pointer in
                guard let pointer else { return false }
                return Unmanaged<ManagedAtomic<Bool>>.fromOpaque(pointer).takeUnretainedValue().load(ordering: .relaxed)
            }, context)
            defer { transcribe_set_abort_callback(session, nil, nil) }
            var transcript = CohereArabicTranscriptAccumulator()
            var overlap: [Float] = []
            while let next = try reader.nextChunk() {
                try Task.checkCancellation()
                let audio = overlap + next
                overlap = Array(next.suffix(5 * 16_000))
                // Exact digital silence needs no inference and otherwise elicits
                // hallucinations. Speech/noise discrimination remains with VAD.
                guard audio.contains(where: { $0 != 0 }) else { continue }
                var params = transcribe_run_params()
                transcribe_run_params_init(&params)
                params.timestamps = TRANSCRIBE_TIMESTAMPS_NONE
                let status = language.rawValue.withCString { code in
                    params.language = code
                    return audio.withUnsafeBufferPointer { samples in
                        transcribe_run(session, samples.baseAddress, Int32(samples.count), &params)
                    }
                }
                if status == TRANSCRIBE_ERR_ABORTED { throw CancellationError() }
                guard status == TRANSCRIBE_OK else { throw CohereArabicError.nativeFailure(status.rawValue) }
                try Task.checkCancellation()
                let chunk = transcribe_full_text(session).map { String(cString: $0) } ?? ""
                transcript.append(chunk)
            }
            return (transcript.text, CFAbsoluteTimeGetCurrent() - start)
        } onCancel: {
            cancelled.store(true, ordering: .relaxed)
        }
    }
}

/// Only the previous 40 words participate in overlap matching. Keep the full
/// output append-only so long meetings do not repeatedly tokenize their history.
struct CohereArabicTranscriptAccumulator {
    private(set) var text = ""
    private var tail = ""

    mutating func append(_ chunk: String) {
        let merged = CohereTranscribeUtils.mergeOverlappingTranscripts([tail, chunk])
        text.append(contentsOf: merged.dropFirst(tail.count))
        tail = merged.split(separator: " ").suffix(40).joined(separator: " ")
    }
}

/// Resamples incrementally so importing a long meeting never materializes the
/// whole recording in memory. The decoder sees at most 35 seconds with overlap.
final class CohereArabicAudioReader {
    static let chunkSamples: AVAudioFrameCount = 30 * 16_000
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var finished = false

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunkSamples) else {
            throw CohereArabicError.audioConversion
        }
        self.converter = converter
        converter.downmix = true
        self.input = input
        self.output = output
    }

    func nextChunk() throws -> [Float]? {
        if finished { return nil }
        output.frameLength = 0
        var conversionError: NSError?
        var readError: Error?
        let status = converter.convert(to: output, error: &conversionError) { [self] requested, inputStatus in
            do {
                let remaining = file.length - file.framePosition
                guard remaining > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let count = min(AVAudioFrameCount(min(remaining, 4096)), requested)
                try file.read(into: input, frameCount: count)
                inputStatus.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                return input.frameLength == 0 ? nil : input
            } catch {
                readError = error
                inputStatus.pointee = .endOfStream
                return nil
            }
        }
        if let readError { throw readError }
        if let conversionError { throw conversionError }
        if status == .error { throw CohereArabicError.audioConversion }
        finished = status == .endOfStream
        guard output.frameLength > 0, let samples = output.floatChannelData?[0] else {
            if finished { return nil }
            throw CohereArabicError.audioConversion
        }
        return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }
}
