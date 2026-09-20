import AVFoundation
import Foundation
import ImlaCore
import Testing
@testable import ImlaNativeApp

@Suite("Cohere Arabic backend")
struct CohereArabicBackendTests {
    @Test("bounded overlap matching preserves whole-transcript merge results")
    func overlap() {
        let chunks = [
            "first second third " + (0..<60).map { "word\($0)" }.joined(separator: " "),
            "word57 word58 word59 testing   the overlap الآن نتحدث بالعربية",
            "الآن نتحدث بالعربية and then English",
            "",
            "A different ending.",
        ]
        var accumulator = CohereArabicTranscriptAccumulator()
        for chunk in chunks { accumulator.append(chunk) }
        #expect(accumulator.text == CohereTranscribeUtils.mergeOverlappingTranscripts([""] + chunks))
    }

    @Test("Arabic is a distinct offline model with independent residency")
    func catalog() throws {
        let option = BackendOption.cohereArabic
        #expect(BackendOption.all.contains(option))
        #expect(BackendOption.resolve(backend: option.backend, model: option.model) == option)
        #expect(option.backend != BackendOption.cohereTranscribe.backend)
        #expect(TranscriptionCoordinator.explicitlyRoutedBackendIdentifiers.contains(option.backend))
        #expect(option.supportsMeetingTranscription)
        #expect(!option.isStreamingDictationBackend)
        #expect(BackendOption.onboardingDefault == .parakeetUnified)
    }

    @Test("language routing pins Arabic and English and discloses fallback")
    func languages() throws {
        let option = BackendOption.cohereArabic
        let capabilities = option.languageCapabilities(isAvailable: true)
        #expect(capabilities.supportedLanguages == [.arabic, .english])
        #expect(!capabilities.supportsAutomaticDetection)
        for language in [TranscriptionLanguage.arabic, .english] {
            let profile = try SpokenLanguageProfile(selectedLanguages: [language])
            let presentation = profile.presentation(for: option, isAvailable: true)
            #expect(presentation.state == .pinned)
            #expect(presentation.degradation == nil)
        }
        let automatic = SpokenLanguageProfile.automatic.presentation(for: option, isAvailable: true)
        #expect(automatic.degradation == .providerFallback(to: .arabic))
        let unsupported = try SpokenLanguageProfile(selectedLanguages: [.german])
            .presentation(for: option, isAvailable: true)
        #expect(unsupported.degradation == .providerFallback(to: .arabic))
        let mixed = try SpokenLanguageProfile(selectedLanguages: [.arabic, .english], dominantLanguage: .english)
        #expect(mixed.presentation(for: option, isAvailable: true).state == .pinned)
    }

    @Test("Arabic selections survive config persistence without changing old defaults")
    func configuration() throws {
        let old = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(old.sttBackend == BackendOption.onboardingDefault.backend)
        var config = old
        config.sttBackend = BackendOption.cohereArabic.backend
        config.sttModel = BackendOption.cohereArabic.model
        config.meetingTranscriptionBackend = config.sttBackend
        config.meetingTranscriptionModel = config.sttModel
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(BackendOption.resolve(backend: decoded.sttBackend, model: decoded.sttModel) == .cohereArabic)
        #expect(BackendOption.resolve(backend: decoded.meetingTranscriptionBackend, model: decoded.meetingTranscriptionModel) == .cohereArabic)
    }

    @Test("model download pins its source, revision, size and digest")
    func manifest() throws {
        let manifest = CohereArabicModelStore.manifest
        let file = try #require(manifest.files.first)
        #expect(manifest.files.count == 1)
        #expect(file.remoteURL.host == "huggingface.co")
        #expect(file.remoteURL.path.contains(manifest.version))
        #expect(manifest.version != "main")
        #expect(file.expectedByteCount == CohereArabicModelStore.byteCount)
        #expect(file.sha256?.count == 64)
        #expect(CohereArabicModelStore.cacheDirectory.path.hasPrefix(AppIdentity.supportDirectoryURL.path + "/"))
    }

    @Test("partial model files are never offered as installed")
    func partialModel() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!CohereArabicModelStore.isAvailable(at: directory))
        try Data("GGUF".utf8).write(to: directory.appendingPathComponent(CohereArabicModelStore.filename))
        #expect(!CohereArabicModelStore.isAvailable(at: directory))
    }

    @Test("audio conversion stays bounded and preserves the complete recording")
    func boundedAudio() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stereo.wav")
        try writeAudio(url: url, sampleRate: 44_100, channels: 2, seconds: 65)
        let reader = try CohereArabicAudioReader(url: url)
        var counts: [Int] = []
        while let samples = try reader.nextChunk() {
            #expect(samples.count <= Int(CohereArabicAudioReader.chunkSamples))
            #expect(samples.allSatisfy { $0.isFinite })
            #expect(abs(samples[samples.count / 2] - 0.5) < 0.001)
            counts.append(samples.count)
        }
        #expect(counts.count == 3)
        #expect(abs(counts.reduce(0, +) - 65 * 16_000) <= 1)
        #expect(try reader.nextChunk() == nil)
    }

    @Test("unsupported language fails before any download")
    func unsupportedLanguage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriber = CohereArabicTranscriber(directory: directory)
        await #expect(throws: LanguageRoutingIncompatibility.self) {
            _ = try await transcriber.transcribe(wavURL: directory.appendingPathComponent("missing.wav"), language: .german)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("cancelled preparation does not start a download")
    func cancelledPreparation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriber = CohereArabicTranscriber(directory: directory)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await transcriber.prepare()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        await transcriber.shutdown()
    }

    @Test("cancelling one preparation leaves the other caller active")
    func independentPreparationCancellation() async throws {
        let gate = CohereArabicResolutionGate()
        let transcriber = CohereArabicTranscriber { _, _, _ in try await gate.resolve() }
        var arrivals = gate.arrivals.stream.makeAsyncIterator()
        let first = Task { try await transcriber.prepare() }
        _ = await arrivals.next()
        let second = Task { try await transcriber.prepare() }
        _ = await arrivals.next()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await gate.releaseSecond()
        await #expect(throws: CohereArabicResolutionGate.Resolved.self) { try await second.value }
        await transcriber.shutdown()
    }

    @Test("native model transcribes speech, handles silence, and reloads",
          .enabled(if: ProcessInfo.processInfo.environment["MUESLI_COHERE_ARABIC_TEST_DIR"] != nil))
    func nativeInference() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MUESLI_COHERE_ARABIC_TEST_DIR"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        #expect(CohereArabicModelStore.isAvailable(at: directory))
        let transcriber = CohereArabicTranscriber(directory: directory)
        do {
            let result = try await transcriber.transcribe(wavURL: directory.appendingPathComponent("jfk.wav"), language: .english)
            #expect(result.text.lowercased().contains("country"))
            let arabic = try await transcriber.transcribe(wavURL: directory.appendingPathComponent("ar.wav"), language: .arabic)
            #expect(arabic.text.unicodeScalars.filter { (0x0600...0x06FF).contains($0.value) }.count > 20)
            let scratch = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let silence = scratch.appendingPathComponent("silence.wav")
            try writeAudio(url: silence, sampleRate: 16_000, channels: 1, seconds: 1, silent: true)
            let empty = try await transcriber.transcribe(wavURL: silence, language: .arabic)
            #expect(empty.text.isEmpty)
            await transcriber.shutdown()
            let reloaded = try await transcriber.transcribe(wavURL: directory.appendingPathComponent("jfk.wav"), language: .english)
            #expect(reloaded.text == result.text)
            await transcriber.shutdown()
        } catch {
            await transcriber.shutdown()
            throw error
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cohere-arabic-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeAudio(url: URL, sampleRate: Double, channels: AVAudioChannelCount, seconds: Int, silent: Bool = false) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate)))
        buffer.frameLength = buffer.frameCapacity
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(buffer.frameLength) {
                data[channel][frame] = silent ? 0 : (channels == 1 ? 0.5 : (channel == 0 ? 0.25 : 0.75))
            }
        }
        for _ in 0..<seconds { try file.write(from: buffer) }
    }
}

private actor CohereArabicResolutionGate {
    struct Resolved: Error {}
    nonisolated let arrivals = AsyncStream<Void>.makeStream()
    private let releases = [AsyncStream<Void>.makeStream(), AsyncStream<Void>.makeStream()]
    private var nextCaller = 0

    func resolve() async throws -> URL {
        let release = releases[nextCaller]
        nextCaller += 1
        arrivals.continuation.yield()
        var iterator = release.stream.makeAsyncIterator()
        _ = await iterator.next()
        try Task.checkCancellation()
        // Stop at the native-load boundary without downloading weights in CI.
        throw Resolved()
    }

    func releaseSecond() {
        releases[1].continuation.yield()
        releases[1].continuation.finish()
        arrivals.continuation.finish()
    }
}
