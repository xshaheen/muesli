import AVFoundation
import Foundation
import SQLite3
import Testing
import ImlaCore
@testable import ImlaCLI

@Suite("ImlaCLI", .serialized)
struct ImlaCLITests {
    @Test("spec exposes the agent-facing command set")
    func specPayloadIncludesCommands() {
        let payload = ImlaCLI.specPayload()
        let names = Set(payload.commands.map(\.name))

        #expect(names.contains("spec"))
        #expect(names.contains("info"))
        #expect(names.contains("transcribe"))
        #expect(names.contains("meetings list"))
        #expect(names.contains("meetings get"))
        #expect(names.contains("meetings update-notes"))
        #expect(names.contains("dictations list"))
        #expect(names.contains("dictations get"))

        let transcribeSpec = payload.commands.first { $0.name == "transcribe" }
        #expect(transcribeSpec?.usage.contains("nemotron35") == true)
        #expect(transcribeSpec?.usage.contains("--dictionary") == true)
        for model in TranscribeModel.allCases {
            #expect(
                transcribeSpec?.usage.contains(model.rawValue) == true,
                "CLI spec does not advertise \(model.rawValue)"
            )
        }
    }

    @Test("explicit db path overrides support directory resolution")
    func cliContextUsesExplicitDatabasePath() {
        let context = CLIContext(
            dbPath: "/tmp/custom-imla.db",
            supportDir: "/tmp/ignored-support"
        )

        #expect(context.databaseURL.path == "/tmp/custom-imla.db")
        #expect(context.supportDirectory.path == "/tmp/ignored-support")
    }

    @Test("explicit support dir resolves the default db name inside it")
    func cliContextUsesExplicitSupportDirectory() {
        let context = CLIContext(
            dbPath: nil,
            supportDir: "/tmp/imla-support"
        )

        #expect(context.supportDirectory.path == "/tmp/imla-support")
        #expect(context.databaseURL.path == "/tmp/imla-support/imla.db")
    }

    @Test("summary config reads the app's persisted OpenRouter selection and protected credential")
    func summaryConfigReadsAppOpenRouterSettings() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imla-cli-openrouter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        try Data(
            #"{"meeting_summary_backend":"openrouter","openrouter_model":"openai/gpt-oss-120b:free"}"#.utf8
        )
            .write(to: supportDirectory.appendingPathComponent("config.json"))
        try Data(#"{"api_key":"sk-or-cli-test","user_id":"user_test"}"#.utf8)
            .write(to: supportDirectory.appendingPathComponent("openrouter-auth.json"))

        let config = CLISummaryConfig.load(from: supportDirectory)
        #expect(config.meetingSummaryBackend == "openrouter")
        #expect(config.openRouterModel == "openai/gpt-oss-120b:free")
        #expect(config.openRouterAPIKey == "sk-or-cli-test")
    }

    @Test("CLI OpenRouter summaries use the free router when no model is configured")
    func cliOpenRouterUsesProviderManagedDefaultModel() {
        #expect(CLISummaryClient.resolvedOpenRouterModel("") == "openrouter/free")
        #expect(CLISummaryClient.resolvedOpenRouterModel("  \n") == "openrouter/free")
        #expect(CLISummaryClient.resolvedOpenRouterModel("custom/model") == "custom/model")
    }

    @Test("migration runs before a read so a legacy database gains new columns")
    func migrationWarningsUpgradesLegacyDatabase() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imla-cli-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A meetings table shaped like an older Imla release, predating
        // visual_context (mirrors makeLegacyStore in DictationStoreTests).
        let dbURL = dir.appendingPathComponent("imla.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        let legacySQL = """
        CREATE TABLE meetings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            calendar_event_id TEXT,
            start_time TEXT NOT NULL,
            end_time TEXT,
            duration_seconds REAL,
            raw_transcript TEXT,
            formatted_notes TEXT,
            mic_audio_path TEXT,
            system_audio_path TEXT,
            word_count INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'meeting',
            created_at TEXT DEFAULT (datetime('now'))
        );
        """
        #expect(sqlite3_exec(db, legacySQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let context = CLIContext(dbPath: dbURL.path, supportDir: nil)
        #expect(migrationWarnings(context).isEmpty)
        // The read would fail with "no such column" without the migration above.
        #expect(try context.store.recentMeetings(limit: 1).isEmpty)
    }

    @Test("a failed migration is reported as a warning instead of thrown")
    func migrationWarningsReportsFailure() {
        // A directory in place of the database file: opening it fails, so the
        // migration cannot run and must surface as a warning, not a crash.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imla-cli-unwritable-\(UUID().uuidString)")
        let dbURL = dir.appendingPathComponent("imla.db")
        try? FileManager.default.createDirectory(at: dbURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let warnings = migrationWarnings(CLIContext(dbPath: dbURL.path, supportDir: nil))
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("Schema migration failed") == true)
    }

    @Test("a read that fails after a failed migration explains the stale schema")
    func withMigrationAttachesMigrationFailureToReadError() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imla-cli-enrich-\(UUID().uuidString)")
        let dbURL = dir.appendingPathComponent("imla.db")
        try? FileManager.default.createDirectory(at: dbURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let context = CLIContext(dbPath: dbURL.path, supportDir: nil)
        #expect(throws: CLIError.self) {
            try withMigration(context) { try context.store.recentMeetings(limit: 1) }
        }
        do {
            _ = try withMigration(context) { try context.store.recentMeetings(limit: 1) }
        } catch let error as CLIError {
            #expect(error.errorBody.code == "database_error")
            #expect(error.errorBody.fix?.contains("Schema migration failed") == true)
        } catch {
            Issue.record("expected a CLIError, got \(error)")
        }
    }

    @Test("a successful read still reports a migration warning")
    func withMigrationKeepsWarningOnSuccessfulRead() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imla-cli-passthrough-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let context = CLIContext(dbPath: dir.appendingPathComponent("imla.db").path, supportDir: nil)
        // A migration can fail against a schema that is already current (a busy
        // database while the app writes), where the read still succeeds. The
        // warning is the only signal the caller gets, so it must survive.
        try context.store.migrateIfNeeded()
        let (rows, warnings) = try withMigration(context, migrate: { _ in ["Schema migration failed: database is locked."] }) {
            try context.store.recentMeetings(limit: 5)
        }
        #expect(rows.isEmpty)
        #expect(warnings == ["Schema migration failed: database is locked."])
    }

    @Test("a read with no migration trouble reports no warnings")
    func withMigrationReportsNoWarningsOnCleanMigration() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imla-cli-clean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let context = CLIContext(dbPath: dir.appendingPathComponent("imla.db").path, supportDir: nil)
        let (rows, warnings) = try withMigration(context) { try context.store.recentMeetings(limit: 5) }
        #expect(rows.isEmpty)
        #expect(warnings.isEmpty)
    }

    @Test("meeting payloads expose applied template metadata")
    func meetingPayloadIncludesTemplateMetadata() {
        let record = MeetingRecord(
            id: 42,
            title: "Weekly Sync",
            startTime: "2026-03-22T10:00:00Z",
            durationSeconds: 1800,
            rawTranscript: "Transcript",
            formattedNotes: "## Summary",
            wordCount: 120,
            folderID: nil,
            selectedTemplateID: "weekly-team-meeting",
            selectedTemplateName: "Weekly Team Meeting",
            selectedTemplateKind: .builtin,
            selectedTemplatePrompt: "## Weekly Overview"
        )

        let listRow = MeetingListRow(record)
        let detailPayload = MeetingDetailPayload(record)

        #expect(listRow.selectedTemplateID == "weekly-team-meeting")
        #expect(listRow.selectedTemplateName == "Weekly Team Meeting")
        #expect(listRow.selectedTemplateKind == "builtin")
        #expect(detailPayload.selectedTemplatePrompt == "## Weekly Overview")
    }

    @Test("meeting detail payload exposes raw and cleaned transcript state")
    func meetingDetailPayloadIncludesCleanupState() {
        let record = MeetingRecord(
            id: 43,
            title: "Customer follow-up",
            startTime: "2026-03-22T11:00:00Z",
            durationSeconds: 1800,
            rawTranscript: "[10:00:00] Speaker 1: البرايمريكية",
            formattedNotes: "## Summary",
            wordCount: 3,
            folderID: nil,
            cleanedTranscript: "[10:00:00] Speaker 1: primary key",
            notesSource: .cleaned
        )

        let detailPayload = MeetingDetailPayload(record)

        #expect(detailPayload.rawTranscript == record.rawTranscript)
        #expect(detailPayload.cleanedTranscript == record.cleanedTranscript)
        #expect(detailPayload.notesSource == "cleaned")
    }

    @Test("CLI envelopes and meeting payloads exclude retained recording identities")
    func cliJSONExcludesRecordingPathsAndIdentities() throws {
        let sentinels = [
            "/Users/private/RECORDING_PATH_CANARY.m4a",
            "/Users/private/MIC_PATH_CANARY.wav",
            "/Users/private/SYSTEM_PATH_CANARY.wav",
            "00000000-0000-0000-0000-000000000014",
            "/Users/private/DB_PATH_CANARY.sqlite",
        ]
        let meeting = MeetingRecord(
            id: 14,
            title: "Private recording",
            startTime: "2026-08-14T00:00:00Z",
            durationSeconds: 30,
            rawTranscript: "safe transcript",
            formattedNotes: "safe notes",
            wordCount: 2,
            folderID: nil,
            micAudioPath: sentinels[1],
            systemAudioPath: sentinels[2],
            savedRecordingPath: sentinels[0]
        )
        let envelope = SuccessEnvelope(
            command: "imla-cli meetings get",
            data: MeetingDetailPayload(meeting),
            meta: MetaBody(
                schemaVersion: 1,
                generatedAt: "2026-08-14T00:00:00Z",
                warnings: []
            )
        )

        let outputs = [
            String(decoding: try encodedJSON(envelope), as: UTF8.self),
            String(decoding: try JSONEncoder().encode(meeting), as: UTF8.self),
        ]

        for output in outputs {
            for sentinel in sentinels {
                #expect(!output.contains(sentinel))
            }
            for forbiddenKey in ["micAudioPath", "systemAudioPath", "savedRecordingPath", "artifactID", "dbPath", "playback", "cache"] {
                #expect(!output.contains(forbiddenKey))
            }
        }
    }

    @Test("dictation JSON projections exclude local style provenance")
    func dictationJSONExcludesStyleProvenance() throws {
        let record = DictationRecord(
            id: 7,
            timestamp: "2026-08-09T00:00:00Z",
            durationSeconds: 2,
            rawText: "Styled dictation",
            appContext: "Notes|com.apple.Notes",
            wordCount: 2,
            dictationStyleID: "writing",
            dictationStyleName: "Writing",
            dictationStyleSelectionSource: "category",
            dictationCleanupOutcome: "applied"
        )

        for payload in [
            try JSONEncoder().encode(record),
            try JSONEncoder().encode(DictationListRow(record)),
            try JSONEncoder().encode(DictationDetailPayload(record)),
        ] {
            let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            #expect(object.keys.contains(where: { $0.localizedCaseInsensitiveContains("style") }) == false)
            #expect(object.keys.contains(where: { $0.localizedCaseInsensitiveContains("cleanup") }) == false)
        }
    }

    @Test("dictation CLI payloads do not expose local target app metadata")
    func dictationPayloadExcludesTargetAppMetadata() throws {
        let record = DictationRecord(
            id: 7,
            timestamp: "2026-08-16T10:00:00Z",
            durationSeconds: 2,
            rawText: "Hello Notes",
            appContext: "cleanup context",
            wordCount: 2,
            targetAppName: "Notes",
            targetAppBundleID: "com.apple.Notes"
        )

        for payload in [
            try JSONEncoder().encode(DictationListRow(record)),
            try JSONEncoder().encode(DictationDetailPayload(record)),
        ] {
            let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            #expect(object["targetAppName"] == nil)
            #expect(object["targetAppBundleID"] == nil)
            #expect(object["target_app_name"] == nil)
            #expect(object["target_app_bundle_id"] == nil)
        }
    }

    @Test("transcribe validation rejects undecodable extensions and names the fix for known ones")
    func transcribeRejectsUnsupportedExtension() {
        #expect(throws: Error.self) {
            _ = try TranscribeCommand.parse(["notes.txt"])
        }
        do {
            _ = try TranscribeCommand.parse(["standup.webm"])
            Issue.record("webm should be rejected: AVFoundation cannot open Matroska")
        } catch {
            let message = TranscribeCommand.message(for: error)
            #expect(message.contains("ffmpeg"), "webm rejection should carry a conversion hint, got: \(message)")
        }
    }

    @Test("transcribe validation accepts every voice-note container macOS can decode")
    func transcribeAcceptsVoiceNoteExtensions() throws {
        for name in [
            "PTT-20260921-WA0001.opus",  // WhatsApp
            "audio_2026-09-21.ogg",      // Telegram / Discord
            "Memo.M4A",                  // Apple Voice Memos, uppercase from a case-insensitive volume
            "rec.3gp", "rec.amr",        // Android recorders
            "message.caf",               // iMessage
            "take.aiff", "take.flac", "clip.mov",
        ] {
            let command = try TranscribeCommand.parse([name])
            #expect(command.file == name)
        }
        #expect(ImlaAudioFilePreparer.isSupportedFileURL(URL(fileURLWithPath: "/tmp/x.OGG")))
    }

    @Test("prepareAudio decodes an Opus voice note to Imla's 16 kHz mono WAV")
    func prepareAudioDecodesOpusVoiceNote() async throws {
        // Opus inside CAF is what Apple's own encoder writes; WhatsApp and Telegram
        // wrap the same codec in Ogg, which the same AudioToolbox decoder reads.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imla-cli-opus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("voice-note.caf")
        let seconds = 1.5
        try Self.writeOpusFixture(to: sourceURL, seconds: seconds)

        let prepared = try await ImlaAudioFilePreparer().prepareAudio(sourceURL: sourceURL)
        defer { try? FileManager.default.removeItem(at: prepared.wavURL) }

        let wav = try AVAudioFile(forReading: prepared.wavURL)
        #expect(wav.fileFormat.sampleRate == 16_000)
        #expect(wav.fileFormat.channelCount == 1)
        #expect(wav.fileFormat.commonFormat == .pcmFormatInt16)
        // Opus adds encoder pre-skip, so allow a frame of slack rather than exact equality.
        #expect(abs(prepared.durationSeconds - seconds) < 0.1)
        #expect(abs(Double(wav.length) / 16_000 - seconds) < 0.1)
    }

    /// Kept in its own function so the `AVAudioFile` writer is released, and the
    /// CAF header finalized, before anything reads the file back.
    private static func writeOpusFixture(to url: URL, seconds: Double) throws {
        let sampleRate = 48_000.0
        let pcm = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let writer = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatOpus,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channel = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frameCount) {
            channel[index] = 0.25 * sinf(2 * .pi * 440 * Float(index) / Float(sampleRate))
        }
        try writer.write(from: buffer)
    }

    @Test("transcribe enums accept documented model and format values")
    func transcribeEnumsAcceptDocumentedValues() {
        #expect(TranscribeModel(argument: "parakeet-v3") == .parakeetV3)
        #expect(TranscribeModel(argument: "parakeet-v2") == .parakeetV2)
        #expect(TranscribeModel(argument: "parakeet-eou-320ms") == .parakeetEou320ms)
        #expect(TranscribeModel(argument: "sensevoice") == .senseVoice)
        #expect(TranscribeModel(argument: "nemotron35") == .nemotron35)
        #expect(TranscribeModel(argument: "whisper-tiny") == .whisperTiny)
        #expect(TranscribeModel(argument: "whisper-tiny-english") == .whisperTinyEnglish)
        #expect(TranscribeModel(argument: "whisper-small") == .whisperSmall)
        #expect(TranscribeModel(argument: "whisper-small-english") == .whisperSmallEnglish)
        #expect(TranscribeModel(argument: "whisper-medium-english") == .whisperMediumEnglish)
        #expect(TranscribeModel(argument: "whisper-large-turbo") == .whisperLargeTurbo)
        #expect(TranscribeModel.nemotron35.asrModelVersion == nil)
        #expect(TranscribeModel.whisperTiny.whisperKitModelName == "tiny")
        #expect(TranscribeModel.whisperTinyEnglish.whisperKitModelName == "tiny.en")
        #expect(TranscribeModel.whisperSmall.whisperKitModelName == "small")
        #expect(TranscribeModel.whisperSmallEnglish.whisperKitModelName == "small.en")
        #expect(TranscribeModel.whisperMediumEnglish.whisperKitModelName == "medium.en")
        #expect(TranscribeModel.whisperLargeTurbo.whisperKitModelName == "large-v3-v20240930_626MB")
        #expect(TranscribeModel(argument: "whisper-medium") == nil)
        #expect(TranscribeModel(argument: "canary-qwen") == nil)
        #expect(TranscribeModel(argument: "qwen3-asr") == nil)
        #expect(TranscribeOutputFormat(argument: "text") == .text)
        #expect(TranscribeOutputFormat(argument: "json") == .json)
        #expect(TranscribeOutputFormat(argument: "markdown") == .markdown)
        #expect(TranscribeOutputFormat(argument: "xml") == nil)
    }

    /// R1/R3 at the CLI boundary: someone with `--model qwen3-asr` in a script must be
    /// told what replaced it, not just that the value is unrecognized.
    @Test("the CLI rejects a retired model and names its replacement")
    func transcribeRejectsRetiredModelWithNamedReplacement() throws {
        #expect(throws: (any Error).self) { try TranscribeModel.parse("qwen3-asr") }

        var message = ""
        do {
            _ = try TranscribeModel.parse("qwen3-asr")
        } catch {
            message = "\(error)"
        }
        #expect(message.contains("qwen3-asr"))
        #expect(message.contains("removed"))
        #expect(message.contains("parakeet-v3"))
        #expect(message.contains("whisper-large-turbo"))

        // A value that was never a model still gets the generic list, not this message.
        var unknownMessage = ""
        do {
            _ = try TranscribeModel.parse("not-a-model")
        } catch {
            unknownMessage = "\(error)"
        }
        #expect(unknownMessage.contains("Unknown model"))
        #expect(!unknownMessage.contains("removed"))
        #expect(try TranscribeModel.parse("parakeet-v3") == .parakeetV3)
    }

    @Test("streaming WAV reader emits ordered fixed chunks and pads only the tail")
    func streamingWavReaderChunksIncrementally() async throws {
        let chunkSamples = 5_120
        let tailSamples = 137
        let samples = [Float](repeating: 0.1, count: chunkSamples)
            + [Float](repeating: 0.2, count: chunkSamples)
            + [Float](repeating: 0.3, count: tailSamples)
        let url = try CLIWavWriter.writeTemporaryWAV(
            samples: samples,
            directoryName: "imla-cli-streaming-reader-tests"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        var chunks: [[Float]] = []
        let result = try await CLIWavReader.forEachMonoFloatChunk(
            url: url,
            chunkSamples: chunkSamples
        ) { buffer in
            let channel = buffer.floatChannelData![0]
            chunks.append(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
        }

        #expect(result.sampleCount == samples.count)
        #expect(result.chunkCount == 3)
        #expect(chunks.count == 3)
        #expect(abs(chunks[0][0] - 0.1) < 0.001)
        #expect(abs(chunks[1][0] - 0.2) < 0.001)
        #expect(abs(chunks[2][0] - 0.3) < 0.001)
        #expect(chunks[2][tailSamples...].allSatisfy { $0 == 0 })
    }

    @Test("--dictionary parses into the request")
    func dictionaryOptionParses() throws {
        let command = try TranscribeCommand.parse(["recording.wav", "--dictionary", "/tmp/dictionary.json"])
        #expect(command.dictionary == "/tmp/dictionary.json")
    }

    @Test("--language parses Auto, one ISO code, and a constrained set")
    func languageOptionParses() throws {
        #expect(try TranscribeCommand.parseLanguageSelection("auto") == .automatic)
        #expect(try TranscribeCommand.parseLanguageSelection("ar") ==
            TranscriptionLanguageSelection(selectedLanguages: [.arabic]))
        #expect(try TranscribeCommand.parseLanguageSelection("en,ar") ==
            TranscriptionLanguageSelection(selectedLanguages: [.arabic, .english]))
    }

    @Test("--language rejects unknown codes and Auto mixed with explicit codes")
    func languageOptionRejectsInvalidValues() {
        #expect(throws: Error.self) { try TranscribeCommand.parseLanguageSelection("auto,ar") }
        #expect(throws: Error.self) { try TranscribeCommand.parseLanguageSelection("xx") }
        #expect(throws: Error.self) { try TranscribeCommand.parseLanguageSelection("en,") }
    }

    @Test("pipeline fails fast when the language selection would degrade")
    func pipelineFailsFastOnDegradedLanguage() async throws {
        let fixture = try TranscribeFixture()
        let pipeline = ImlaAudioTranscriptionPipeline(
            audioPreparer: FakeAudioPreparer(wavURL: fixture.wavURL, durationSeconds: 3),
            transcriber: FailingTranscriber(),
            summarizer: SuccessfulSummarizer(notes: "should not run"),
            dataChangePoster: {}
        )
        let degraded: [(TranscribeModel, TranscriptionLanguageSelection)] = [
            // Parakeet cannot pin, so a single language would only be detected.
            (.parakeetV3, try TranscriptionLanguageSelection(selectedLanguages: [.arabic])),
            // Parakeet v2 is fixed English and would ignore Arabic.
            (.parakeetV2, try TranscriptionLanguageSelection(selectedLanguages: [.arabic, .english])),
        ]
        for (model, selection) in degraded {
            do {
                _ = try await pipeline.run(
                    request: ImlaAudioTranscriptionRequest(
                        sourceURL: fixture.sourceURL,
                        model: model,
                        languageSelection: selection,
                        title: "Degraded",
                        summarize: false,
                        saveMeeting: false
                    ),
                    context: fixture.context
                )
                Issue.record("Expected \(model.rawValue) with \(selection.selectedLanguages) to fail fast")
            } catch let error as CLIError {
                #expect(error.errorBody.code == "invalid_input")
                #expect(error.errorBody.fix?.contains("compatible --model/--language") == true)
            }
        }
    }

    @Test("pipeline runs two languages without a dominant as automatic detection")
    func pipelineDetectsAmongLanguagesWithoutDominant() async throws {
        let fixture = try TranscribeFixture()
        let pipeline = ImlaAudioTranscriptionPipeline(
            audioPreparer: FakeAudioPreparer(wavURL: fixture.wavURL, durationSeconds: 3),
            transcriber: FakeTranscriber(text: "detected automatically"),
            summarizer: SuccessfulSummarizer(notes: "unused"),
            dataChangePoster: {}
        )
        let result = try await pipeline.run(
            request: ImlaAudioTranscriptionRequest(
                sourceURL: fixture.sourceURL,
                model: .whisperLargeTurbo,
                languageSelection: try TranscriptionLanguageSelection(selectedLanguages: [.arabic, .english]),
                title: "Detecting",
                summarize: false,
                saveMeeting: false
            ),
            context: fixture.context
        )
        #expect(result.transcript == "detected automatically")
    }

    @Test("loadCustomWords accepts a plain JSON array")
    func loadCustomWordsAcceptsPlainArray() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("imla-cli-dictionary-\(UUID().uuidString).json")
        try Data("""
        [{"word": "museli", "replacement": "imla", "matching_threshold": 0.85}]
        """.utf8).write(to: url)

        let words = try ImlaAudioTranscriptionPipeline.loadCustomWords(from: url)
        #expect(words.count == 1)
        #expect(words[0].word == "museli")
        #expect(words[0].targetWord == "imla")
    }

    @Test("loadCustomWords accepts a config.json-shaped object")
    func loadCustomWordsAcceptsConfigShape() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("imla-cli-dictionary-\(UUID().uuidString).json")
        try Data("""
        {"custom_words": [{"word": "kubernete", "replacement": "Kubernetes"}], "other_config_key": true}
        """.utf8).write(to: url)

        let words = try ImlaAudioTranscriptionPipeline.loadCustomWords(from: url)
        #expect(words.count == 1)
        #expect(words[0].targetWord == "Kubernetes")
    }

    @Test("loadCustomWords rejects a missing file")
    func loadCustomWordsRejectsMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        #expect(throws: Error.self) {
            _ = try ImlaAudioTranscriptionPipeline.loadCustomWords(from: url)
        }
    }

    @Test("loadCustomWords distinguishes unreadable paths from missing files")
    func loadCustomWordsRejectsUnreadablePath() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("imla-cli-dictionary-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        do {
            _ = try ImlaAudioTranscriptionPipeline.loadCustomWords(from: url)
            Issue.record("Expected reading a directory as a dictionary to fail")
        } catch let error as CLIError {
            #expect(error.errorBody.code == "invalid_input")
            #expect(error.errorBody.message.contains("Could not read dictionary file"))
        }
    }

    @Test("pipeline validates the dictionary before transcription")
    func pipelineValidatesDictionaryBeforeTranscription() async throws {
        let fixture = try TranscribeFixture()
        let missingDictionaryURL = fixture.directory.appendingPathComponent("missing-dictionary.json")
        let pipeline = ImlaAudioTranscriptionPipeline(
            audioPreparer: FakeAudioPreparer(wavURL: fixture.wavURL, durationSeconds: 3),
            transcriber: FailingTranscriber(),
            summarizer: SuccessfulSummarizer(notes: "should not run"),
            dataChangePoster: {}
        )

        do {
            _ = try await pipeline.run(
                request: ImlaAudioTranscriptionRequest(
                    sourceURL: fixture.sourceURL,
                    model: .parakeetV3,
                    title: "Fail Fast Demo",
                    summarize: false,
                    saveMeeting: false,
                    dictionaryURL: missingDictionaryURL
                ),
                context: fixture.context
            )
            Issue.record("Expected the missing dictionary to fail before transcription")
        } catch let error as CLIError {
            #expect(error.errorBody.code == "not_found")
        }
    }

    @Test("pipeline applies the dictionary to the transcript")
    func pipelineAppliesDictionary() async throws {
        let fixture = try TranscribeFixture()
        let dictionaryURL = fixture.directory.appendingPathComponent("dictionary.json")
        try Data("""
        [{"word": "museli", "replacement": "imla"}]
        """.utf8).write(to: dictionaryURL)

        let pipeline = ImlaAudioTranscriptionPipeline(
            audioPreparer: FakeAudioPreparer(wavURL: fixture.wavURL, durationSeconds: 3),
            transcriber: FakeTranscriber(text: "I love museli"),
            summarizer: SuccessfulSummarizer(notes: "unused"),
            dataChangePoster: {}
        )

        let result = try await pipeline.run(
            request: ImlaAudioTranscriptionRequest(
                sourceURL: fixture.sourceURL,
                model: .parakeetV3,
                title: "Dictionary Demo",
                summarize: false,
                saveMeeting: false,
                dictionaryURL: dictionaryURL
            ),
            context: fixture.context
        )

        #expect(result.transcript == "I love imla")
    }

    @Test("pipeline rejects a dictionary that removes the entire transcript")
    func pipelineRejectsDictionaryEmptiedTranscript() async throws {
        let fixture = try TranscribeFixture()
        let dictionaryURL = fixture.directory.appendingPathComponent("empty-dictionary.json")
        try Data("""
        [{"word": "hello", "replacement": ""}]
        """.utf8).write(to: dictionaryURL)

        let pipeline = ImlaAudioTranscriptionPipeline(
            audioPreparer: FakeAudioPreparer(wavURL: fixture.wavURL, durationSeconds: 3),
            transcriber: FakeTranscriber(text: "hello"),
            summarizer: SuccessfulSummarizer(notes: "should not run"),
            dataChangePoster: {}
        )

        do {
            _ = try await pipeline.run(
                request: ImlaAudioTranscriptionRequest(
                    sourceURL: fixture.sourceURL,
                    model: .parakeetV3,
                    title: "Empty Dictionary Demo",
                    summarize: true,
                    saveMeeting: true,
                    dictionaryURL: dictionaryURL
                ),
                context: fixture.context
            )
            Issue.record("Expected the post-dictionary empty transcript to be rejected")
        } catch let error as CLIError {
            #expect(error.errorBody.code == "invalid_input")
            #expect(error.errorBody.message.contains("No speech remains"))
        }
    }

    @Test("pipeline rejects a dictionary that leaves only punctuation")
    func pipelineRejectsDictionaryPunctuationOnlyTranscript() async throws {
        let fixture = try TranscribeFixture()
        let dictionaryURL = fixture.directory.appendingPathComponent("punctuation-dictionary.json")
        try Data("""
        [{"word": "hello", "replacement": ""}]
        """.utf8).write(to: dictionaryURL)

        let pipeline = ImlaAudioTranscriptionPipeline(
            audioPreparer: FakeAudioPreparer(wavURL: fixture.wavURL, durationSeconds: 3),
            transcriber: FakeTranscriber(text: "hello!"),
            summarizer: SuccessfulSummarizer(notes: "should not run"),
            dataChangePoster: {}
        )

        do {
            _ = try await pipeline.run(
                request: ImlaAudioTranscriptionRequest(
                    sourceURL: fixture.sourceURL,
                    model: .parakeetV3,
                    title: "Punctuation Dictionary Demo",
                    summarize: true,
                    saveMeeting: true,
                    dictionaryURL: dictionaryURL
                ),
                context: fixture.context
            )
            Issue.record("Expected a punctuation-only post-dictionary transcript to be rejected")
        } catch let error as CLIError {
            #expect(error.errorBody.code == "invalid_input")
            #expect(error.errorBody.message.contains("No speech remains"))
        }
    }

    @Test("transcribe text output is transcript only")
    func transcribeTextOutputIsTranscriptOnly() throws {
        let result = ImlaAudioTranscriptionResult(
            title: "Demo",
            transcript: "hello from imla",
            summary: nil,
            durationSeconds: 2,
            wordCount: 3,
            model: .parakeetV3,
            warnings: [],
            savedMeetingID: nil
        )

        #expect(result.textOutput == "hello from imla\n")
    }

    @Test("transcribe markdown output includes title summary and transcript")
    func transcribeMarkdownOutputIncludesSections() throws {
        let result = ImlaAudioTranscriptionResult(
            title: "Demo",
            transcript: "hello from imla",
            summary: "## Summary\n\n- Done",
            durationSeconds: 2,
            wordCount: 3,
            model: .parakeetV3,
            warnings: [],
            savedMeetingID: nil
        )

        #expect(result.markdownOutput == """
        # Demo

        ## Summary

        - Done

        ## Raw Transcript

        hello from imla
        """)
    }

    @Test("transcribe json payload follows CLI envelope")
    func transcribeJSONPayloadUsesEnvelope() throws {
        let payload = TranscribeJSONPayload(
            ImlaAudioTranscriptionResult(
                title: "Demo",
                transcript: "hello from imla",
                summary: "## Summary\n\n- Done",
                durationSeconds: 4,
                wordCount: 3,
                model: .parakeetV2,
                warnings: ["summary warning"],
                savedMeetingID: 12
            )
        )
        let envelope = SuccessEnvelope(
            command: "imla-cli transcribe",
            data: payload,
            meta: MetaBody(schemaVersion: 1, generatedAt: "2026-07-08T00:00:00Z", warnings: ["summary warning"])
        )
        let data = try encodedJSON(envelope)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["ok"] as? Bool == true)
        #expect(json["command"] as? String == "imla-cli transcribe")
        let payloadData = try #require(json["data"] as? [String: Any])
        #expect(payloadData["transcript"] as? String == "hello from imla")
        #expect(payloadData["model"] as? String == "parakeet-v2")
        #expect(payloadData["savedMeetingID"] as? Int == 12)
        #expect(payloadData["summary"] as? String == "## Summary\n\n- Done")

        let nilPayload = TranscribeJSONPayload(
            ImlaAudioTranscriptionResult(
                title: "No Summary",
                transcript: "raw only",
                summary: nil,
                durationSeconds: 2,
                wordCount: 2,
                model: .parakeetV3,
                warnings: [],
                savedMeetingID: nil
            )
        )
        let nilData = try encodedJSON(nilPayload)
        let nilJSON = try #require(JSONSerialization.jsonObject(with: nilData) as? [String: Any])
        #expect(nilJSON.keys.contains("summary"))
        #expect(nilJSON["summary"] is NSNull)
        #expect(nilJSON.keys.contains("savedMeetingID"))
        #expect(nilJSON["savedMeetingID"] is NSNull)
    }

    @Test("transcribe summary failure keeps transcript with warning")
    func transcribeSummaryFailureKeepsTranscript() async throws {
        let fixture = try TranscribeFixture()
        let pipeline = ImlaAudioTranscriptionPipeline(
            audioPreparer: FakeAudioPreparer(wavURL: fixture.wavURL, durationSeconds: 3),
            transcriber: FakeTranscriber(text: "important transcript"),
            summarizer: FailingSummarizer(),
            dataChangePoster: {}
        )

        let result = try await pipeline.run(
            request: ImlaAudioTranscriptionRequest(
                sourceURL: fixture.sourceURL,
                model: .parakeetV3,
                title: "Failure Demo",
                summarize: true,
                saveMeeting: false
            ),
            context: fixture.context
        )

        #expect(result.transcript == "important transcript")
        #expect(result.summary == nil)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].contains("Summary failed"))
    }

    @Test("transcribe save meeting inserts audio import and posts data change")
    func transcribeSaveMeetingInsertsAudioImport() async throws {
        let fixture = try TranscribeFixture()
        var posted = 0
        let pipeline = ImlaAudioTranscriptionPipeline(
            audioPreparer: FakeAudioPreparer(wavURL: fixture.wavURL, durationSeconds: 5),
            transcriber: FakeTranscriber(text: "save this imported meeting"),
            summarizer: SuccessfulSummarizer(notes: "## Summary\n\n- Saved"),
            dataChangePoster: { posted += 1 }
        )

        let result = try await pipeline.run(
            request: ImlaAudioTranscriptionRequest(
                sourceURL: fixture.sourceURL,
                model: .parakeetV3,
                title: "Saved Import",
                summarize: true,
                saveMeeting: true
            ),
            context: fixture.context
        )

        let id = try #require(result.savedMeetingID)
        let meeting = try #require(try fixture.context.store.meeting(id: id))
        #expect(meeting.title == "Saved Import")
        #expect(meeting.rawTranscript == "save this imported meeting")
        #expect(meeting.formattedNotes == "## Summary\n\n- Saved")
        #expect(meeting.source == .audioImport)
        #expect(meeting.savedRecordingPath == nil)
        let artifactStore = try RecordingArtifactStore(
            databaseURL: fixture.context.databaseURL,
            recordingsRootURL: fixture.context.supportDirectory.appendingPathComponent("recordings", isDirectory: true),
            legacyMeetingRootURL: fixture.context.supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
        )
        let reference = try #require(try artifactStore.recordingForMeeting(id: id))
        let artifactID = try #require(reference.artifactID)
        let savedRecordingURL = try artifactStore.playableURL(id: artifactID)
        #expect(savedRecordingURL.pathExtension == fixture.sourceURL.pathExtension)
        #expect(posted == 1)
    }

    @Test("transcribe save meeting retains a WAV copy when the source container is not storable")
    func transcribeSaveMeetingFallsBackToWAVForVoiceNotes() async throws {
        let fixture = try TranscribeFixture()
        // The preparer is faked, so only the name has to look like a WhatsApp note;
        // what matters is that the artifact table would reject `.opus`.
        let opusURL = fixture.directory.appendingPathComponent("PTT-20260921-WA0001.opus")
        try FileManager.default.copyItem(at: fixture.sourceURL, to: opusURL)
        let pipeline = ImlaAudioTranscriptionPipeline(
            audioPreparer: FakeAudioPreparer(wavURL: fixture.wavURL, durationSeconds: 1),
            transcriber: FakeTranscriber(text: "voice note transcript"),
            summarizer: SuccessfulSummarizer(notes: "unused"),
            dataChangePoster: {}
        )

        let result = try await pipeline.run(
            request: ImlaAudioTranscriptionRequest(
                sourceURL: opusURL,
                model: .parakeetV3,
                title: nil,
                summarize: false,
                saveMeeting: true
            ),
            context: fixture.context
        )

        #expect(result.warnings.isEmpty, "audio copy must not degrade to a warning: \(result.warnings)")
        let id = try #require(result.savedMeetingID)
        let artifactStore = try RecordingArtifactStore(
            databaseURL: fixture.context.databaseURL,
            recordingsRootURL: fixture.context.supportDirectory.appendingPathComponent("recordings", isDirectory: true),
            legacyMeetingRootURL: fixture.context.supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
        )
        let reference = try #require(try artifactStore.recordingForMeeting(id: id))
        let artifactID = try #require(reference.artifactID)
        let savedRecordingURL = try artifactStore.playableURL(id: artifactID)
        #expect(savedRecordingURL.pathExtension == "wav")
        #expect(FileManager.default.fileExists(atPath: savedRecordingURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.wavURL.path), "the prepared WAV is copied, not moved")
    }

    @Test("summary config decodes the snake_case keys the app writes")
    func summaryConfigDecodesAppConfigKeys() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imla-cli-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {
          "meeting_summary_backend": "ollama",
          "openai_api_key": "sk-openai",
          "openrouter_api_key": "sk-openrouter",
          "openai_model": "gpt-5.4",
          "openrouter_model": "stepfun/step-3.5-flash",
          "ollama_url": "http://localhost:9999",
          "ollama_model": "qwen3.5:14b",
          "lmstudio_url": "http://localhost:4321",
          "lmstudio_model": "local-model",
          "custom_llm_url": "https://llm.example.com/v1",
          "custom_llm_api_key": "sk-custom",
          "custom_llm_model": "custom-model",
          "custom_llm_format": "anthropic"
        }
        """
        try json.write(to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let config = CLISummaryConfig.load(from: directory)

        #expect(config.meetingSummaryBackend == "ollama")
        #expect(config.openAIAPIKey == "sk-openai")
        #expect(config.openRouterAPIKey == "sk-openrouter")
        #expect(config.openAIModel == "gpt-5.4")
        #expect(config.openRouterModel == "stepfun/step-3.5-flash")
        #expect(config.ollamaURL == "http://localhost:9999")
        #expect(config.ollamaModel == "qwen3.5:14b")
        #expect(config.lmStudioURL == "http://localhost:4321")
        #expect(config.lmStudioModel == "local-model")
        #expect(config.customLLMURL == "https://llm.example.com/v1")
        #expect(config.customLLMAPIKey == "sk-custom")
        #expect(config.customLLMModel == "custom-model")
        #expect(config.customLLMFormat == "anthropic")
    }

    @Test("summary config falls back to defaults when config.json is missing")
    func summaryConfigFallsBackToDefaults() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imla-cli-config-missing-\(UUID().uuidString)", isDirectory: true)

        let config = CLISummaryConfig.load(from: directory)

        #expect(config.meetingSummaryBackend == "chatgpt")
        #expect(config.openAIAPIKey.isEmpty)
        #expect(config.ollamaURL == "http://localhost:11434")
        #expect(config.lmStudioURL == "http://localhost:1234")
    }

    @Test("transcribe output writes file content")
    func transcribeOutputWritesFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imla-cli-output-\(UUID().uuidString)", isDirectory: true)
        let outputURL = directory.appendingPathComponent("transcript.txt")
        try writeOutput("plain transcript\n", to: outputURL)

        #expect(try String(contentsOf: outputURL, encoding: .utf8) == "plain transcript\n")
    }
}

private struct TranscribeFixture {
    let directory: URL
    let sourceURL: URL
    let wavURL: URL
    let context: CLIContext

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-cli-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sourceURL = directory.appendingPathComponent("recording.wav")
        wavURL = directory.appendingPathComponent("prepared.wav")
        let samples = Array(repeating: Float(0.1), count: 16_000)
        try CLIWavWriter.writeWAV(samples: samples, to: sourceURL)
        try CLIWavWriter.writeWAV(samples: samples, to: wavURL)
        context = CLIContext(
            dbPath: directory.appendingPathComponent("imla.db").path,
            supportDir: directory.path
        )
    }
}

private struct FakeAudioPreparer: AudioPreparing {
    let wavURL: URL
    let durationSeconds: Double

    func prepareAudio(sourceURL: URL) async throws -> PreparedAudioFile {
        PreparedAudioFile(wavURL: wavURL, durationSeconds: durationSeconds, deleteWhenDone: false)
    }
}

private struct FakeTranscriber: AudioTranscribing {
    let text: String

    func transcribe(wavURL: URL, model: TranscribeModel, progress: @escaping (String) -> Void) async throws -> HeadlessTranscription {
        progress("fake")
        return HeadlessTranscription(text: text, durationSeconds: nil)
    }
}

private struct FailingTranscriber: AudioTranscribing {
    func transcribe(wavURL: URL, model: TranscribeModel, progress: @escaping (String) -> Void) async throws -> HeadlessTranscription {
        throw CLIError.invalidInput("Transcription should not run when dictionary validation fails.")
    }
}

private struct SuccessfulSummarizer: MeetingSummarizing {
    let notes: String

    func summarize(transcript: String, title: String, supportDirectory: URL) async throws -> String {
        notes
    }
}

private struct FailingSummarizer: MeetingSummarizing {
    func summarize(transcript: String, title: String, supportDirectory: URL) async throws -> String {
        throw CLISummaryError.unavailable("summary backend unavailable")
    }
}
