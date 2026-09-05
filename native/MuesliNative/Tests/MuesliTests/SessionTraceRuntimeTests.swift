import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Session trace runtime")
struct SessionTraceRuntimeTests {
    @Test("language trace records the frozen profile and effective backend behavior")
    func languageTraceRecordsFrozenProfile() throws {
        let profile = try LanguageProfile(
            selectedLanguages: [.english, .arabic],
            dominantLanguage: .arabic,
            meetingOutputPolicy: .dominantLanguage
        )
        let data = Data(SessionTraceSnapshot.languageProfile(
            backend: .whisperTinyEnglish,
            profile: profile
        ).utf8)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["schemaVersion"] as? Int == 3)
        #expect(json["status"] as? String == "frozen")
        #expect(json["selectedLanguages"] as? [String] == ["ar", "en"])
        #expect(json["dominantLanguage"] as? String == "ar")
        #expect(json["meetingOutputPolicy"] as? String == "dominant_language")
        // Reversed under KD2: a fixed-language model now routes to its fixed
        // arm and ignores the foreign selection instead of being incompatible.
        #expect(json["effectiveLanguage"] as? String == "en")
        #expect(json["effectiveBehavior"] as? String == "fixed")
        #expect(json["routingResult"] as? String == "fixed")
        #expect(json["candidateCount"] as? Int == 1)
    }

    @Test("initial profile evidence is ordered before an immediate terminal failure")
    func initialProfileSurvivesImmediateFailure() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabaseFiles(at: databaseURL) }
        let store = try SessionTraceStore(databaseURL: databaseURL)
        let trace = SessionRunTrace(
            store: store,
            kind: .meeting,
            initialArtifacts: [
                SessionTraceInitialArtifact(
                    content: #"{"status":"frozen"}"#,
                    kind: .languageProfile
                ),
            ]
        )

        #expect(await trace.fail(stage: "meeting_start"))

        let detail = try #require(await trace.detail())
        #expect(detail.summary.terminalOutcome == .failed)
        #expect(detail.artifacts.contains { artifact in
            artifact.kinds.contains(.languageProfile)
                && artifact.content == #"{"status":"frozen"}"#
        })
    }

    @Test("normal dictation records ordered evidence and one success")
    func normalDictationTrace() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabaseFiles(at: databaseURL) }
        let store = try SessionTraceStore(databaseURL: databaseURL)
        let trace = SessionRunTrace(
            store: store,
            kind: .dictation,
            backendIdentity: "fluidaudio:parakeet"
        )

        await trace.recordStageStarted("speech_recognition")
        await trace.storeArtifact("raw", kind: .rawASR)
        await trace.recordStageCompleted("speech_recognition", elapsedMilliseconds: 12)
        await trace.recordStageStarted("cleanup")
        await trace.storeArtifact("cleaned", kind: .cleanupResult)
        await trace.storeArtifact(DictationDictionaryTrace.emptyContent, kind: .dictionaryChanges)
        await trace.storeArtifact("cleaned", kind: .finalOutput)
        await trace.storeArtifact(#"{"status":"frozen_placeholder"}"#, kind: .languageProfile)
        await trace.storeArtifact("frontmost_app", kind: .contextSources)
        await trace.recordStageCompleted("cleanup", elapsedMilliseconds: 4)
        #expect(await trace.claimTerminal(.success))

        let detail = try #require(await trace.detail())
        #expect(detail.summary.terminalOutcome == .success)
        #expect(detail.events.map(\.vocabulary) == [
            .sessionStarted,
            .stageStarted,
            .stageCompleted,
            .stageStarted,
            .stageCompleted,
            .terminal,
        ])
        #expect(Set(detail.artifacts.flatMap(\.kinds)) == Set(SessionTraceArtifactKind.allCases))
        #expect(detail.events.filter { $0.vocabulary == .terminal }.count == 1)
    }

    @Test("successful meeting retranscription records every artifact and stage completion")
    func successfulMeetingRetranscriptionTrace() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabaseFiles(at: databaseURL) }
        let store = try SessionTraceStore(databaseURL: databaseURL)
        let trace = SessionRunTrace(
            store: store,
            kind: .meeting,
            initialArtifacts: [
                SessionTraceInitialArtifact(
                    content: #"{"status":"frozen"}"#,
                    kind: .languageProfile
                ),
            ]
        )

        await trace.recordStageStarted("meeting_retranscription")
        await trace.storeArtifact("raw", kind: .rawASR)
        await trace.storeArtifact("cleaned", kind: .cleanupResult)
        await trace.storeArtifact("cleaned", kind: .finalOutput)
        #expect(await MuesliController.completeMeetingRetranscriptionTrace(
            trace,
            elapsedMilliseconds: 42,
            hadExistingNotes: true,
            hadManualNotes: false
        ))

        let detail = try #require(await trace.detail())
        #expect(detail.summary.terminalOutcome == .success)
        #expect(Set(detail.artifacts.flatMap(\.kinds)) == Set(SessionTraceArtifactKind.allCases))
        #expect(detail.events.map(\.vocabulary) == [
            .sessionStarted,
            .stageStarted,
            .stageCompleted,
            .terminal,
        ])
        let context = try #require(detail.artifacts.first {
            $0.kinds.contains(.contextSources)
        })
        let contextContent = try #require(context.content)
        #expect(contextContent.contains(#""existingNotes":true"#))
        #expect(contextContent.contains(#""manualNotes":false"#))
    }

    @Test("fallback terminal prevents an uncooperative cleanup from publishing late")
    func fallbackPreventsLatePublication() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabaseFiles(at: databaseURL) }
        let store = try SessionTraceStore(databaseURL: databaseURL)
        let trace = SessionRunTrace(
            store: store,
            kind: .dictation,
            backendIdentity: "whisper:large-v3",
            fallbackBackendIdentity: "openai:gpt-4.1-mini"
        )

        let cleanupGate = AsyncStream<Void>.makeStream()
        let lateCleanupTask = Task {
            for await _ in cleanupGate.stream { break }
            return await trace.publish(
                "late cleanup",
                outcome: .success,
                metadata: ["source": "uncooperative_cleanup"]
            )
        }
        let fallback = await trace.publish(
            "raw transcript",
            outcome: .fallbackSuccess,
            metadata: ["reason": "cleanup_deadline"]
        )
        cleanupGate.continuation.yield()
        cleanupGate.continuation.finish()
        let lateCleanup = await lateCleanupTask.value
        await trace.storeArtifact("late cleanup", kind: .cleanupResult)

        #expect(fallback == "raw transcript")
        #expect(lateCleanup == nil)
        let detail = try #require(await trace.detail())
        #expect(detail.summary.terminalOutcome == .fallbackSuccess)
        #expect(detail.events.filter { $0.vocabulary == .terminal }.count == 1)
        #expect(detail.artifacts.allSatisfy { $0.content != "late cleanup" })
    }

    @Test("failed before history remains discoverable")
    func failedBeforeHistoryIsDiscoverable() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabaseFiles(at: databaseURL) }
        let store = try SessionTraceStore(databaseURL: databaseURL)
        let trace = SessionRunTrace(
            store: store,
            kind: .dictation,
            backendIdentity: "fluidaudio:parakeet"
        )

        await trace.recordStageStarted("speech_recognition")
        #expect(await trace.claimTerminal(.failed, metadata: ["stage": "speech_recognition"]))
        let independentStore = try SessionTraceStore(databaseURL: databaseURL)
        let summary = try #require(try await independentStore.list().first)
        #expect(summary.dictationID == nil)
        #expect(summary.terminalOutcome == .failed)
    }

    @Test("cancellation and failure each settle exactly once")
    func cancellationAndFailureSettleOnce() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabaseFiles(at: databaseURL) }
        let store = try SessionTraceStore(databaseURL: databaseURL)
        let cancelled = SessionRunTrace(store: store, kind: .dictation)
        let failedMeeting = SessionRunTrace(store: store, kind: .meeting)
        var ownership = TranscriptionActivityOwnership(meetingFinalizations: 1)

        await cancelled.recordCancellationRequested(stage: "recording")
        #expect(await cancelled.claimTerminal(.cancelled))
        #expect(!(await cancelled.claimTerminal(.failed)))

        await failedMeeting.recordStageFailed("meeting_finalization")
        #expect(await failedMeeting.claimTerminal(.failed))
        #expect(!(await failedMeeting.claimTerminal(.success)))
        ownership = TranscriptionActivityOwnership()
        #expect(!ownership.isActive)

        let independentStore = try SessionTraceStore(databaseURL: databaseURL)
        let summaries = try await independentStore.list()
        #expect(summaries.count == 2)
        #expect(Set(summaries.compactMap(\.terminalOutcome)) == [.cancelled, .failed])
        for summary in summaries {
            let detail = try #require(try await store.detail(sessionID: summary.sessionID))
            #expect(detail.events.filter { $0.vocabulary == .terminal }.count == 1)
        }
    }

    @Test("aggregate ownership remains active until dictations and meetings drain")
    func aggregateOwnership() {
        var ownership = TranscriptionActivityOwnership(queuedDictations: 2, meetingFinalizations: 1)
        #expect(ownership.isActive)

        ownership = TranscriptionActivityOwnership(queuedDictations: 1, meetingFinalizations: 1)
        #expect(ownership.isActive)
        ownership = TranscriptionActivityOwnership(meetingFinalizations: 1)
        #expect(ownership.isActive)

        ownership = TranscriptionActivityOwnership()
        #expect(!ownership.isActive)
    }

    @Test("diagnostics outage preserves local exactly-once publication")
    func diagnosticsOutagePreservesPublication() async {
        let trace = SessionRunTrace(store: nil, kind: .dictation)

        #expect(await trace.publish("first", outcome: .success) == "first")
        #expect(await trace.publish("late", outcome: .fallbackSuccess) == nil)
        #expect(await trace.detail() == nil)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-session-runtime-\(UUID().uuidString).sqlite")
    }

    private func removeDatabaseFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
