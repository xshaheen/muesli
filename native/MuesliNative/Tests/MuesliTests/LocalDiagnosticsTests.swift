import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Local diagnostics", .serialized)
struct LocalDiagnosticsTests {
    @Test("an available empty store and a missing detail remain distinct from outage")
    func emptyAndMissingStates() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabaseFiles(at: databaseURL) }
        let service = LocalDiagnosticsService(
            store: try SessionTraceStore(databaseURL: databaseURL)
        )

        #expect(await service.list() == .available([]))
        #expect(await service.detail(sessionID: UUID()) == .missing)
    }

    @Test("failed and cancelled sessions are listed without history associations")
    func listsUnattachedTerminalSessions() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabaseFiles(at: databaseURL) }
        let store = try SessionTraceStore(databaseURL: databaseURL)

        for outcome in [SessionTraceTerminalOutcome.failed, .cancelled] {
            let token = try await store.beginSession(kind: .dictation)
            _ = try await store.claimTerminal(outcome, token: token)
        }

        let service = LocalDiagnosticsService(store: store)
        let summaries = try #require(await service.list().summaries)
        let outcomes = Set(summaries.compactMap { $0.terminalOutcome })
        let allUnattached = summaries.allSatisfy {
            $0.dictationID == nil && $0.meetingID == nil
        }

        #expect(outcomes == Set([SessionTraceTerminalOutcome.failed, .cancelled]))
        #expect(allUnattached)
    }

    @Test("unavailable trace storage is explicit while auxiliary cleanup still runs")
    func unavailableStorage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-unavailable-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let meetingRoot = root.appendingPathComponent("MeetingDiagnostics/run", isDirectory: true)
        let incidentClearMarker = root.appendingPathComponent("incident-history-cleared")
        let exportURL = temporaryExportURL()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: exportURL)
        }
        try FileManager.default.createDirectory(at: meetingRoot, withIntermediateDirectories: true)
        let service = LocalDiagnosticsService(
            store: nil,
            diagnosticsRootURL: root,
            clearIncidentHistory: {
                try Data().write(to: incidentClearMarker, options: .atomic)
            }
        )

        #expect(await service.list() == .unavailable)
        #expect(await service.detail(sessionID: UUID()) == .unavailable)
        await #expect(throws: LocalDiagnosticsError.unavailable) {
            try await service.export(to: exportURL)
        }
        let clearResult = await service.clear()
        #expect(clearResult.traces == nil)
        #expect(clearResult.meetingDiagnostics?.activeRunsPreserved == 0)
        #expect(clearResult.failedTargets == [.sessionTraces])
        #expect(!FileManager.default.fileExists(atPath: meetingRoot.path))
        #expect(FileManager.default.fileExists(atPath: incidentClearMarker.path))
    }

    @Test("clear flushes active writers and preserves history and retained recordings")
    func clearIsWriterSafeAndDiagnosticsOnly() async throws {
        let databaseURL = temporaryDatabaseURL()
        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-retained-recording-\(UUID().uuidString).m4a")
        defer {
            removeDatabaseFiles(at: databaseURL)
            try? FileManager.default.removeItem(at: recordingURL)
        }
        let history = DictationStore(databaseURL: databaseURL)
        try history.migrateIfNeeded()
        let dictationID = try history.insertDictation(
            text: "keep normal history",
            durationSeconds: 1,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11)
        )
        try Data("recording".utf8).write(to: recordingURL)

        let store = try SessionTraceStore(databaseURL: databaseURL)
        let trace = SessionRunTrace(store: store, kind: .meeting)
        await trace.recordStageStarted("finalization")
        let diagnosticsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-active-meeting-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: diagnosticsRoot) }
        let now = Date()
        let meetingDiagnostics = MeetingSessionDiagnostics(
            startedAt: now.addingTimeInterval(-30),
            rootURL: diagnosticsRoot,
            enabledOverride: true
        )
        let service = LocalDiagnosticsService(store: store, diagnosticsRootURL: diagnosticsRoot) {
            await trace.flush()
        }

        let result = await service.clear()

        #expect(result.activeRunsPreserved == 2)
        #expect(result.isComplete)
        #expect(try history.dictation(id: dictationID)?.rawText == "keep normal history")
        #expect(FileManager.default.fileExists(atPath: recordingURL.path))
        let detail = try #require(try await store.detail(sessionID: trace.sessionID))
        #expect(detail.summary.contentState == .clearedWhileActive)
        #expect(detail.events.isEmpty)
        #expect(detail.artifacts.isEmpty)
        meetingDiagnostics.writeFinalReport(
            startedAt: now.addingTimeInterval(-30),
            endedAt: now,
            systemCapture: nil,
            micRecorder: nil,
            micHealth: nil,
            aec: emptyAecSnapshot,
            micChunks: emptyChunkSnapshot,
            systemChunks: emptyChunkSnapshot,
            diarizationSegments: nil,
            protectedSystemSegmentCount: 0,
            retentionReferenceDate: now
        )
        #expect(MeetingSessionDiagnostics.loadStoredSummaries(rootURL: diagnosticsRoot).count == 1)
    }

    @Test("export is a bounded decodable snapshot taken after active writes flush")
    func exportIsBoundedSnapshot() async throws {
        let databaseURL = temporaryDatabaseURL()
        let exportURL = temporaryExportURL()
        let diagnosticsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-local-diagnostics-root-\(UUID().uuidString)", isDirectory: true)
        defer {
            removeDatabaseFiles(at: databaseURL)
            try? FileManager.default.removeItem(at: exportURL)
            try? FileManager.default.removeItem(at: diagnosticsRoot)
        }
        let store = try SessionTraceStore(databaseURL: databaseURL)
        let trace = SessionRunTrace(store: store, kind: .dictation)
        await trace.storeArtifact("local transcript", kind: .rawASR)
        let now = Date()
        let meetingDiagnostics = MeetingSessionDiagnostics(
            startedAt: now.addingTimeInterval(-30),
            rootURL: diagnosticsRoot,
            enabledOverride: true
        )
        meetingDiagnostics.writeFinalReport(
            startedAt: now.addingTimeInterval(-30),
            endedAt: now,
            systemCapture: nil,
            micRecorder: nil,
            micHealth: nil,
            aec: emptyAecSnapshot,
            micChunks: emptyChunkSnapshot,
            systemChunks: emptyChunkSnapshot,
            diarizationSegments: nil,
            protectedSystemSegmentCount: 0,
            retentionReferenceDate: now
        )
        let incident = DiagnosticIncident(
            kind: .dictationTranscriptionFailed,
            stage: .standardDictationTranscribe,
            error: NSError(domain: "Fixture", code: 7)
        )
        let service = LocalDiagnosticsService(
            store: store,
            diagnosticsRootURL: diagnosticsRoot,
            flushActiveWriters: { await trace.flush() },
            loadIncidentHistory: { [incident] in [incident] }
        )

        let byteCount = try await service.export(to: exportURL, now: now)
        let data = try Data(contentsOf: exportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(LocalDiagnosticsExportEnvelope.self, from: data)

        #expect(byteCount == data.count)
        #expect(byteCount <= LocalDiagnosticsService.maximumExportBytes)
        #expect(payload.sessionTraces.traces.count == 1)
        #expect(payload.sessionTraces.traces[0].artifacts.first?.content == "local transcript")
        #expect(payload.meetingSummaries.count == 1)
        #expect(payload.incidents.map(\.id) == [incident.id])
        #expect(payload.incidents.map(\.kind) == [incident.kind])
    }

    @Test("partial auxiliary cleanup is reported and can be retried idempotently")
    func partialCleanupCanRetry() async throws {
        struct CleanupFailure: Error {}

        let databaseURL = temporaryDatabaseURL()
        let diagnosticsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-local-diagnostics-retry-\(UUID().uuidString)", isDirectory: true)
        defer {
            removeDatabaseFiles(at: databaseURL)
            try? FileManager.default.removeItem(at: diagnosticsRoot)
        }
        let store = try SessionTraceStore(databaseURL: databaseURL)
        let token = try await store.beginSession(kind: .dictation)
        _ = try await store.claimTerminal(.success, token: token)
        let first = LocalDiagnosticsService(
            store: store,
            diagnosticsRootURL: diagnosticsRoot,
            clearMeetingSummaries: { _ in throw CleanupFailure() }
        )

        let partial = await first.clear()

        #expect(partial.failedTargets == [.meetingSummaries])
        #expect(try await store.list().isEmpty)

        let retry = LocalDiagnosticsService(
            store: store,
            diagnosticsRootURL: diagnosticsRoot
        )
        let completed = await retry.clear()

        #expect(completed.isComplete)
        #expect(completed.traces?.terminalSessionsDeleted == 0)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-local-diagnostics-\(UUID().uuidString).sqlite")
    }

    private func temporaryExportURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-diagnostics-\(UUID().uuidString).json")
    }

    private func removeDatabaseFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private var emptyAecSnapshot: MeetingAecDiagnosticsSnapshot {
        MeetingAecDiagnosticsSnapshot(
            ready: false,
            processor: nil,
            frameSize: 0,
            processedFrames: 0,
            fullReferenceFrames: 0,
            partialReferenceFrames: 0,
            missingReferenceFrames: 0,
            systemSamplesReceived: 0,
            micSamplesReceived: 0,
            bufferedSystemSamples: 0,
            bufferedMicSamples: 0,
            currentDelayMs: 0,
            delayHistory: [],
            delaySkipHistory: []
        )
    }

    private var emptyChunkSnapshot: MeetingTranscriptChunkHealthSnapshot {
        MeetingTranscriptChunkHealthSnapshot(
            successfulChunkCount: 0,
            emptyChunkCount: 0,
            failedChunkCount: 0
        )
    }
}
