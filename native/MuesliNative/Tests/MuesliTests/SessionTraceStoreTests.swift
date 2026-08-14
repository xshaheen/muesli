import Foundation
import SQLite3
import Testing
@testable import MuesliCore

@Suite("SessionTraceStore", .serialized)
struct SessionTraceStoreTests {
    @Test("a session is discoverable before a history row exists and records ordered evidence")
    func unattachedSessionAndOrderedEvents() async throws {
        let (store, url) = try makeStore()
        defer { removeDatabase(url) }
        let sessionID = UUID()
        let token = try await store.beginSession(
            id: sessionID,
            kind: .dictation,
            backendIdentity: "whisperkit-large-v3"
        )

        #expect(try await store.appendEvent(
            .stageStarted,
            stage: "asr",
            metadata: ["language_profile": "frozen-placeholder"],
            token: token
        ) == .appended)
        #expect(try await store.appendEvent(
            .stageCompleted,
            stage: "asr",
            elapsed: 0.125,
            token: token
        ) == .appended)

        let summary = try #require(try await store.list().first)
        #expect(summary.sessionID == sessionID)
        #expect(summary.dictationID == nil)
        #expect(summary.meetingID == nil)
        #expect(summary.contentState == .activeWriter)
        let detail = try #require(try await store.detail(sessionID: sessionID))
        #expect(detail.events.map(\.sequence) == [1, 2, 3])
        #expect(detail.events.map(\.stage) == ["session", "asr", "asr"])
        #expect(detail.events.last?.elapsedMilliseconds == 125)
    }

    @Test("identical transcript content is stored once and referenced by multiple semantic kinds")
    func artifactsAreNormalizedPerSession() async throws {
        let (store, url) = try makeStore()
        defer { removeDatabase(url) }
        let token = try await store.beginSession(kind: .dictation)
        let raw = try await store.storeArtifact("same transcript", kind: .rawASR, token: token)
        let final = try await store.storeArtifact("same transcript", kind: .finalOutput, token: token)

        #expect(raw.mutation == .appended)
        #expect(final.mutation == .deduplicated)
        #expect(raw.artifactID == final.artifactID)
        let detail = try #require(try await store.detail(sessionID: token.sessionID))
        #expect(detail.artifacts.count == 1)
        #expect(detail.artifacts[0].kinds == [.finalOutput, .rawASR])
        #expect(detail.artifacts[0].content == "same transcript")
        #expect(try scalar(url, "SELECT COUNT(*) FROM session_trace_artifacts") == 1)
        #expect(try scalar(url, "SELECT COUNT(*) FROM session_trace_artifact_references") == 2)
    }

    @Test("terminal arbitration has one winner and rejects all late publishing")
    func exactlyOnceTerminalAndLateWriteRejection() async throws {
        let (store, url) = try makeStore()
        defer { removeDatabase(url) }
        let token = try await store.beginSession(kind: .dictation)

        let results = await withTaskGroup(of: SessionTraceTerminalClaimResult?.self) { group in
            for outcome in SessionTraceTerminalOutcome.allCases {
                group.addTask { try? await store.claimTerminal(outcome, token: token) }
            }
            var values: [SessionTraceTerminalClaimResult] = []
            for await result in group {
                if let result { values.append(result) }
            }
            return values
        }

        #expect(results.filter { $0 == .won }.count == 1)
        let detail = try #require(try await store.detail(sessionID: token.sessionID))
        let outcome = try #require(detail.summary.terminalOutcome)
        #expect(detail.events.filter { $0.vocabulary == .terminal }.count == 1)
        #expect(try await store.appendEvent(.stageCompleted, stage: "cleanup", token: token)
            == .terminalAlreadyDecided(outcome))
        #expect(try await store.storeArtifact("late", kind: .finalOutput, token: token).mutation
            == .terminalAlreadyDecided(outcome))
        #expect(try await store.associate(token: token, dictationID: 1)
            == .terminalAlreadyDecided(outcome))
    }

    @Test("oversized terminal metadata is truncated without blocking arbitration")
    func oversizedTerminalMetadataCannotBlockCAS() async throws {
        let (store, url) = try makeStore()
        defer { removeDatabase(url) }
        let token = try await store.beginSession(kind: .dictation)

        #expect(try await store.claimTerminal(
            .fallbackSuccess,
            metadata: ["detail": String(repeating: "private", count: 100)],
            token: token
        ) == .won)
        let detail = try #require(try await store.detail(sessionID: token.sessionID))
        #expect(detail.summary.terminalOutcome == .fallbackSuccess)
        #expect(detail.events.last?.metadata == ["metadata_state": "truncated"])
        #expect(detail.events.filter { $0.vocabulary == .terminal }.count == 1)
    }

    @Test("all terminal outcomes round-trip")
    func terminalOutcomesRoundTrip() async throws {
        let (store, url) = try makeStore()
        defer { removeDatabase(url) }
        for outcome in SessionTraceTerminalOutcome.allCases {
            let token = try await store.beginSession(kind: .meeting)
            #expect(try await store.claimTerminal(outcome, token: token) == .won)
            #expect(try await store.detail(sessionID: token.sessionID)?.summary.terminalOutcome == outcome)
        }
    }

    @Test("nonterminal limits reserve one event for the terminal result")
    func eventAndArtifactLimits() async throws {
        var policy = SessionTraceRetentionPolicy.default
        policy = SessionTraceRetentionPolicy(
            richContentRetention: policy.richContentRetention,
            metadataRetention: policy.metadataRetention,
            maximumArtifactBytes: 8,
            maximumSessionRichBytes: 12,
            maximumEvents: 3,
            maximumGlobalRichBytes: 16,
            maximumSessions: policy.maximumSessions,
            maximumExportBytes: policy.maximumExportBytes,
            maximumEventMetadataBytes: policy.maximumEventMetadataBytes,
            maximumIdentifierBytes: policy.maximumIdentifierBytes
        )
        let (store, url) = try makeStore(policy: policy)
        defer { removeDatabase(url) }
        let token = try await store.beginSession(kind: .dictation)

        #expect(try await store.appendEvent(.stageStarted, stage: "asr", token: token) == .appended)
        #expect(try await store.appendEvent(.stageCompleted, stage: "asr", token: token)
            == .limitReached(.eventCount))
        #expect(try await store.storeArtifact("123456789", kind: .rawASR, token: token).mutation
            == .limitReached(.artifactBytes))
        #expect(try await store.claimTerminal(.success, token: token) == .won)
        #expect(try await store.detail(sessionID: token.sessionID)?.summary.eventCount == 3)
    }

    @Test("optional history associations become null when normal history is deleted")
    func associationsUseDeleteSetNull() async throws {
        let (store, url) = try makeStore()
        defer { removeDatabase(url) }
        let history = DictationStore(databaseURL: url)
        let dictationID = try history.insertDictation(
            text: "history",
            durationSeconds: 1,
            appContext: "tests",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101)
        )
        let token = try await store.beginSession(kind: .dictation)
        #expect(try await store.associate(token: token, dictationID: dictationID) == .appended)
        #expect(try await store.detail(sessionID: token.sessionID)?.summary.dictationID == dictationID)

        try execute(url, "PRAGMA foreign_keys=ON; DELETE FROM dictations WHERE id = \(dictationID)")

        #expect(try await store.detail(sessionID: token.sessionID)?.summary.dictationID == nil)
        #expect(try await store.detail(sessionID: token.sessionID) != nil)
    }

    @Test("failed and cancelled unattached traces prune rich data before metadata")
    func unattachedTraceRetention() async throws {
        let (store, url) = try makeStore()
        defer { removeDatabase(url) }
        let start = Date(timeIntervalSince1970: 1_000_000)
        var sessionIDs: [UUID] = []
        for outcome in [SessionTraceTerminalOutcome.failed, .cancelled] {
            let token = try await store.beginSession(kind: .dictation, at: start)
            _ = try await store.storeArtifact("private transcript", kind: .rawASR, token: token, at: start)
            _ = try await store.claimTerminal(outcome, token: token, at: start)
            sessionIDs.append(token.sessionID)
        }

        _ = try await store.prune(now: start.addingTimeInterval(8 * 24 * 60 * 60))
        for sessionID in sessionIDs {
            let detail = try #require(try await store.detail(sessionID: sessionID))
            #expect(detail.summary.contentState == .pruned)
            #expect(detail.artifacts.isEmpty)
            #expect(detail.events.map(\.vocabulary) == [.sessionStarted, .terminal])
        }

        _ = try await store.prune(now: start.addingTimeInterval(91 * 24 * 60 * 60))
        #expect(try await store.list().isEmpty)
    }

    @Test("stale writers time out exactly once while live writers remain active")
    func abandonedWriterTimeout() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(url) }
        let first = try SessionTraceStore(databaseURL: url)
        let second = try SessionTraceStore(databaseURL: url)
        let start = Date(timeIntervalSince1970: 1_500_000)
        let abandoned = try await first.beginSession(kind: .dictation, at: start)
        let live = try await first.beginSession(kind: .meeting, at: start)
        #expect(try await first.appendEvent(
            .stageCompleted,
            stage: "heartbeat",
            token: live,
            at: start.addingTimeInterval(23 * 60 * 60)
        ) == .appended)

        _ = try await second.prune(now: start.addingTimeInterval(25 * 60 * 60))

        let timedOut = try #require(try await first.detail(sessionID: abandoned.sessionID))
        #expect(timedOut.summary.terminalOutcome == .timedOut)
        #expect(timedOut.events.filter { $0.vocabulary == .terminal }.count == 1)
        #expect(try await first.appendEvent(.stageCompleted, stage: "late", token: abandoned)
            == .terminalAlreadyDecided(.timedOut))
        #expect(try await first.claimTerminal(.success, token: abandoned)
            == .alreadyDecided(.timedOut))
        #expect(try await first.detail(sessionID: live.sessionID)?.summary.terminalOutcome == nil)

        _ = try await first.prune(now: start.addingTimeInterval(26 * 60 * 60))
        #expect(try scalar(
            url,
            "SELECT COUNT(*) FROM session_trace_events WHERE session_uuid = '\(abandoned.sessionID.uuidString)' AND vocabulary = 'terminal'"
        ) == 1)
    }

    @Test("session capacity evicts the oldest terminal trace and rejects an all-active set")
    func sessionCapacityReservation() async throws {
        let basePolicy = SessionTraceRetentionPolicy.default
        let policy = replacing(basePolicy, maximumSessions: 2)
        let (store, url) = try makeStore(policy: policy)
        defer { removeDatabase(url) }
        let start = Date(timeIntervalSince1970: 1_700_000)
        let terminal = try await store.beginSession(kind: .dictation, at: start)
        _ = try await store.claimTerminal(.success, token: terminal, at: start)
        let active = try await store.beginSession(kind: .meeting, at: start.addingTimeInterval(1))

        let replacement = try await store.beginSession(
            kind: .dictation,
            at: start.addingTimeInterval(2)
        )
        #expect(try await store.detail(sessionID: terminal.sessionID) == nil)
        #expect(try await store.detail(sessionID: active.sessionID) != nil)
        #expect(try await store.detail(sessionID: replacement.sessionID) != nil)

        await #expect(throws: SessionTraceStoreError.limitReached(.sessionCount)) {
            _ = try await store.beginSession(kind: .meeting, at: start.addingTimeInterval(3))
        }
    }

    @Test("a current v1 database upgrades additively to v2 with valid foreign keys")
    func currentV1Upgrade() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(url) }
        let history = DictationStore(databaseURL: url)
        try history.migrateIfNeeded()
        let dictationID = try history.insertDictation(
            text: "preserved through v2",
            durationSeconds: 2,
            appContext: "tests",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 102)
        )
        try execute(
            url,
            """
            DROP TABLE session_trace_events;
            DROP TABLE session_trace_artifact_references;
            DROP TABLE session_trace_artifacts;
            DROP TABLE session_traces;
            DROP TABLE session_trace_settings;
            PRAGMA user_version = 1;
            """
        )

        let store = try SessionTraceStore(databaseURL: url)
        let token = try await store.beginSession(kind: .dictation)

        #expect(try scalar(url, "PRAGMA user_version") == 2)
        #expect(try scalar(url, "SELECT COUNT(*) FROM dictations WHERE id = \(dictationID)") == 1)
        #expect(try scalar(url, "SELECT COUNT(*) FROM pragma_foreign_key_check") == 0)
        #expect(try await store.detail(sessionID: token.sessionID) != nil)
    }

    @Test("clear preserves active writers and history while invalidating rich writes")
    func clearDuringActiveWriterIsDiagnosticsOnlyAndIdempotent() async throws {
        let (store, url) = try makeStore()
        defer { removeDatabase(url) }
        let history = DictationStore(databaseURL: url)
        let meetingID = try history.insertMeeting(
            title: "Retained meeting",
            calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 100),
            endTime: Date(timeIntervalSince1970: 200),
            rawTranscript: "normal history",
            formattedNotes: "normal notes",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        try execute(url, "UPDATE meetings SET saved_recording_path = '/retained/meeting.m4a' WHERE id = \(meetingID)")

        let active = try await store.beginSession(
            kind: .meeting,
            backendIdentity: "primary-backend",
            fallbackBackendIdentity: "fallback-backend"
        )
        _ = try await store.associate(token: active, meetingID: meetingID)
        _ = try await store.storeArtifact("private trace", kind: .rawASR, token: active)
        _ = try await store.appendEvent(.stageStarted, stage: "asr", token: active)
        let terminal = try await store.beginSession(kind: .dictation)
        _ = try await store.claimTerminal(.success, token: terminal)

        let first = try await store.clearDiagnostics(at: Date(timeIntervalSince1970: 300))

        #expect(first.terminalSessionsDeleted == 1)
        #expect(first.activeSessionsPreserved == 1)
        #expect(first.activeSessionsReset == 1)
        #expect(first.eventsDeleted == 2)
        #expect(first.artifactsDeleted == 1)
        #expect(try scalar(url, "SELECT COUNT(*) FROM meetings WHERE id = \(meetingID)") == 1)
        #expect(try textScalar(url, "SELECT saved_recording_path FROM meetings WHERE id = \(meetingID)")
            == "/retained/meeting.m4a")

        let cleared = try #require(try await store.detail(sessionID: active.sessionID))
        #expect(cleared.summary.contentState == .clearedWhileActive)
        #expect(cleared.summary.meetingID == nil)
        #expect(cleared.summary.backendIdentity == nil)
        #expect(cleared.summary.fallbackBackendIdentity == nil)
        #expect(cleared.events.isEmpty)
        #expect(cleared.artifacts.isEmpty)
        #expect(try await store.appendEvent(.stageCompleted, stage: "asr", token: active) == .clearedByGeneration)
        #expect(try await store.storeArtifact("late", kind: .finalOutput, token: active).mutation
            == .clearedByGeneration)
        #expect(try await store.associate(token: active, meetingID: meetingID) == .clearedByGeneration)
        #expect(try await store.claimTerminal(.cancelled, token: active) == .won)
        #expect(try await store.claimTerminal(.failed, token: active)
            == .alreadyDecided(.cancelled))
        #expect(try await store.detail(sessionID: active.sessionID)?.events.isEmpty == true)

        let second = try await store.clearDiagnostics(at: Date(timeIntervalSince1970: 301))
        #expect(second.terminalSessionsDeleted == 1)
        #expect(second.activeSessionsPreserved == 0)
        #expect(second.activeSessionsReset == 0)
        #expect(try await store.list().isEmpty)
        let third = try await store.clearDiagnostics(at: Date(timeIntervalSince1970: 302))
        #expect(third.terminalSessionsDeleted == 0)
        #expect(third.activeSessionsPreserved == 0)
        #expect(third.eventsDeleted == 0)
        #expect(third.artifactsDeleted == 0)

        let postClear = try await store.beginSession(kind: .dictation)
        #expect(try await store.appendEvent(.stageStarted, stage: "asr", token: postClear) == .appended)
    }

    @Test("a failed clear rolls back its generation and all trace mutations before retry")
    func clearRollbackAndRetry() async throws {
        enum InjectedFailure: Error { case stop }
        let url = temporaryDatabaseURL()
        defer { removeDatabase(url) }
        let setup = try SessionTraceStore(databaseURL: url)
        let active = try await setup.beginSession(kind: .dictation)
        _ = try await setup.storeArtifact("private", kind: .rawASR, token: active)
        let terminal = try await setup.beginSession(kind: .meeting)
        _ = try await setup.claimTerminal(.failed, token: terminal)
        let generationBefore = try scalar(
            url,
            "SELECT clear_generation FROM session_trace_settings WHERE singleton_id = 1"
        )

        let failing = try SessionTraceStore(databaseURL: url) { checkpoint in
            if checkpoint == .activeSessionsReset { throw InjectedFailure.stop }
        }
        await #expect(throws: InjectedFailure.self) {
            _ = try await failing.clearDiagnostics()
        }
        #expect(try scalar(url, "SELECT clear_generation FROM session_trace_settings WHERE singleton_id = 1")
            == generationBefore)
        #expect(try scalar(url, "SELECT COUNT(*) FROM session_traces") == 2)
        #expect(try scalar(url, "SELECT COUNT(*) FROM session_trace_artifacts") == 1)

        let retry = try SessionTraceStore(databaseURL: url)
        let result = try await retry.clearDiagnostics()
        #expect(result.clearGeneration == generationBefore + 1)
        #expect(result.terminalSessionsDeleted == 1)
        #expect(result.activeSessionsPreserved == 1)
    }

    @Test("diagnostics export is deterministic bounded and excludes history paths")
    func exportSnapshotAndLimit() async throws {
        let (store, url) = try makeStore()
        defer { removeDatabase(url) }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let history = DictationStore(databaseURL: url)
        let meetingID = try history.insertMeeting(
            title: "Secret title",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "history must not export",
            formattedNotes: "notes must not export",
            micAudioPath: "/audio/mic.wav",
            systemAudioPath: "/audio/system.wav"
        )
        try execute(url, "UPDATE meetings SET saved_recording_path = '/recordings/secret.m4a' WHERE id = \(meetingID)")
        let active = try await store.beginSession(kind: .meeting, at: now)
        _ = try await store.associate(token: active, meetingID: meetingID, at: now)
        let empty = try await store.beginSession(kind: .dictation, at: now.addingTimeInterval(1))
        _ = try await store.claimTerminal(.success, token: empty, at: now.addingTimeInterval(2))
        let pruned = try await store.beginSession(kind: .meeting, at: now.addingTimeInterval(3))
        _ = try await store.storeArtifact("expiring rich content", kind: .rawASR, token: pruned, at: now)
        _ = try await store.claimTerminal(.failed, token: pruned, at: now)
        _ = try await store.prune(now: now.addingTimeInterval(8 * 24 * 60 * 60))

        let exportedAt = now.addingTimeInterval(9 * 24 * 60 * 60)
        let recentActive = try await store.beginSession(kind: .meeting, at: exportedAt)
        let first = try await store.exportDiagnosticsData(now: exportedAt)
        let second = try await store.exportDiagnosticsData(now: exportedAt)
        #expect(first == second)
        #expect(first.count <= SessionTraceRetentionPolicy.default.maximumExportBytes)
        let decoded = try exportDecoder().decode(SessionTraceDiagnosticsExport.self, from: first)
        #expect(decoded.schemaVersion == SessionTraceDiagnosticsExport.currentSchemaVersion)
        #expect(decoded.provenance.storageScope == "local-only")
        #expect(decoded.traces.map(\.summary.contentState).contains(.activeWriter))
        #expect(decoded.traces.map(\.summary.contentState).contains(.empty))
        #expect(decoded.traces.map(\.summary.contentState).contains(.pruned))
        let json = String(decoding: first, as: UTF8.self)
        for forbidden in ["Secret title", "history must not export", "/audio/", "/recordings/"] {
            #expect(!json.contains(forbidden))
        }
        #expect(json.contains("\(meetingID)"))

        _ = try await store.clearDiagnostics(at: exportedAt)
        let afterClear = try await store.exportDiagnosticsData(now: exportedAt)
        let cleared = try exportDecoder().decode(SessionTraceDiagnosticsExport.self, from: afterClear)
        #expect(cleared.traces.map(\.summary.contentState) == [.clearedWhileActive])
        #expect(cleared.traces.first?.summary.sessionID == recentActive.sessionID)

        let tinyPolicy = policy(replacingExportBytes: 16)
        let tinyURL = temporaryDatabaseURL()
        let tiny = try SessionTraceStore(databaseURL: tinyURL, retentionPolicy: tinyPolicy)
        defer { removeDatabase(tinyURL) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-export-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: destination) }
        try Data("sentinel".utf8).write(to: destination)
        await #expect(throws: SessionTraceStoreError.self) {
            _ = try await tiny.exportDiagnostics(to: destination, now: now)
        }
        #expect(try Data(contentsOf: destination) == Data("sentinel".utf8))
    }

    @Test("two independent stores arbitrate one terminal result")
    func independentStoreTerminalCAS() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(url) }
        let first = try SessionTraceStore(databaseURL: url)
        let second = try SessionTraceStore(databaseURL: url)
        let token = try await first.beginSession(kind: .dictation)

        async let success = first.claimTerminal(.success, token: token)
        async let failure = second.claimTerminal(.failed, token: token)
        let results = try await [success, failure]

        #expect(results.filter { $0 == .won }.count == 1)
        let outcome = try #require(try await first.detail(sessionID: token.sessionID)?.summary.terminalOutcome)
        #expect(results.contains(.alreadyDecided(outcome)))
        #expect(try scalar(url, "SELECT COUNT(*) FROM session_trace_events WHERE vocabulary = 'terminal'") == 1)
    }

    @Test("detail returns one snapshot while an independent store clears diagnostics")
    func detailUsesReadTransaction() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(url) }
        let setup = try SessionTraceStore(databaseURL: url)
        let token = try await setup.beginSession(kind: .dictation)
        let artifact = try await setup.storeArtifact("snapshot", kind: .rawASR, token: token)
        #expect(artifact.mutation == .appended)
        _ = try await setup.claimTerminal(.success, token: token)

        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let reader = try SessionTraceStore(databaseURL: url) { checkpoint in
            if checkpoint == .summaryLoaded {
                entered.signal()
                _ = resume.wait(timeout: .now() + 5)
            }
        }
        let clearer = try SessionTraceStore(databaseURL: url)
        let read = Task { try await reader.detail(sessionID: token.sessionID) }
        let enteredResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 5))
            }
        }
        #expect(enteredResult == .success)
        _ = try await clearer.clearDiagnostics()
        resume.signal()

        let snapshot = try #require(try await read.value)
        #expect(snapshot.summary.terminalOutcome == .success)
        #expect(snapshot.events.map(\.vocabulary) == [.sessionStarted, .terminal])
        #expect(snapshot.artifacts.first?.content == "snapshot")
        #expect(try await clearer.detail(sessionID: token.sessionID) == nil)
    }

    @Test("invalid retention policies fail before creating or migrating a database")
    func invalidPoliciesFailBeforeStorage() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(url) }
        let invalidEvents = replacing(SessionTraceRetentionPolicy.default, maximumEvents: 1)
        #expect(throws: SessionTraceStoreError.invalidPolicy(
            "event count must be between 2 and 512 to reserve a terminal event"
        )) {
            _ = try SessionTraceStore(databaseURL: url, retentionPolicy: invalidEvents)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let invalidWriterAge = replacing(
            SessionTraceRetentionPolicy.default,
            abandonedWriterRetention: 8 * 60 * 60
        )
        #expect(throws: SessionTraceStoreError.self) {
            _ = try SessionTraceStore(databaseURL: url, retentionPolicy: invalidWriterAge)
        }

        let boundary = replacing(SessionTraceRetentionPolicy.default, maximumEvents: 2)
        _ = try SessionTraceStore(databaseURL: url, retentionPolicy: boundary)
    }

    @Test("physical high-water includes SQLite sidecars and never evicts normal history")
    func physicalHighWaterStopsDiagnosticGrowth() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(url) }
        let history = DictationStore(databaseURL: url)
        try history.migrateIfNeeded()
        let historyID = try history.insertDictation(
            text: String(repeating: "retained history ", count: 512),
            durationSeconds: 1,
            appContext: "tests",
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2)
        )
        let physicalLimit = fileFootprint(url) + 72 * 1_024
        let policy = replacing(
            SessionTraceRetentionPolicy.default,
            maximumPhysicalBytes: physicalLimit
        )
        let store = try SessionTraceStore(databaseURL: url, retentionPolicy: policy)
        let token = try await store.beginSession(kind: .dictation)
        let artifact = try await store.storeArtifact(
            String(repeating: "x", count: 128 * 1_024),
            kind: .rawASR,
            token: token
        )
        #expect(artifact.mutation == .limitReached(.physicalDatabaseBytes))
        #expect(fileFootprint(url) <= physicalLimit)
        #expect(try scalar(url, "SELECT COUNT(*) FROM dictations WHERE id = \(historyID)") == 1)
        // Terminal ownership is never hostage to the diagnostics high-water.
        #expect(try await store.claimTerminal(.success, token: token) == .won)
        #expect(fileFootprint(url) <= physicalLimit)
    }

    @Test("history above the diagnostics high-water still permits a terminal trace shell")
    func physicalHighWaterNeverBlocksTerminalOwnership() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(url) }
        let history = DictationStore(databaseURL: url)
        try history.migrateIfNeeded()
        _ = try history.insertDictation(
            text: String(repeating: "retained history ", count: 512),
            durationSeconds: 1,
            appContext: "tests",
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2)
        )
        let policy = replacing(SessionTraceRetentionPolicy.default, maximumPhysicalBytes: 1)
        let store = try SessionTraceStore(databaseURL: url, retentionPolicy: policy)

        let token = try await store.beginSession(kind: .dictation)
        #expect(try await store.claimTerminal(.failed, token: token) == .won)
        let detail = try #require(try await store.detail(sessionID: token.sessionID))
        #expect(detail.summary.terminalOutcome == .failed)
        #expect(detail.events.map(\.vocabulary) == [.sessionStarted, .terminal])
    }

    @Test("an eight-hour synthetic workload stays within every frozen resource cap")
    func eightHourResourceBounds() async throws {
        let base = Date(timeIntervalSince1970: 3_000_000)
        let policy = SessionTraceRetentionPolicy(
            richContentRetention: 7 * 24 * 60 * 60,
            metadataRetention: 90 * 24 * 60 * 60,
            maximumArtifactBytes: 128,
            maximumSessionRichBytes: 256,
            maximumEvents: 8,
            maximumGlobalRichBytes: 512,
            maximumSessions: 8,
            maximumExportBytes: 1 * 1_024 * 1_024,
            maximumEventMetadataBytes: 256,
            maximumIdentifierBytes: 128
        )
        let (store, url) = try makeStore(policy: policy)
        defer { removeDatabase(url) }

        for hour in 0 ..< 8 {
            let time = base.addingTimeInterval(Double(hour) * 60 * 60)
            let token = try await store.beginSession(kind: .meeting, at: time)
            for event in 0 ..< 6 {
                #expect(try await store.appendEvent(
                    .stageCompleted,
                    stage: "chunk-\(event)",
                    elapsed: 0.01,
                    token: token,
                    at: time
                ) == .appended)
            }
            let artifact = try await store.storeArtifact(
                String(repeating: Character(String(hour)), count: 128),
                kind: .rawASR,
                token: token,
                at: time
            )
            #expect(artifact.mutation == .appended)
            #expect(try await store.claimTerminal(.success, token: token, at: time) == .won)
        }

        #expect(try scalar(url, "SELECT COUNT(*) FROM session_traces") <= Int64(policy.maximumSessions))
        #expect(try scalar(url, "SELECT COALESCE(MAX(event_count), 0) FROM session_traces")
            <= Int64(policy.maximumEvents))
        #expect(try scalar(url, "SELECT COALESCE(MAX(byte_count), 0) FROM session_trace_artifacts")
            <= Int64(policy.maximumArtifactBytes))
        #expect(try scalar(url, "SELECT COALESCE(MAX(rich_byte_count), 0) FROM session_traces")
            <= Int64(policy.maximumSessionRichBytes))
        #expect(try scalar(url, "SELECT COALESCE(SUM(byte_count), 0) FROM session_trace_artifacts")
            <= Int64(policy.maximumGlobalRichBytes))
        #expect(fileFootprint(url) <= policy.maximumPhysicalBytes)
    }

    private func makeStore(
        policy: SessionTraceRetentionPolicy = .default
    ) throws -> (SessionTraceStore, URL) {
        let url = temporaryDatabaseURL()
        return (try SessionTraceStore(databaseURL: url, retentionPolicy: policy), url)
    }

    private func policy(replacingExportBytes exportBytes: Int) -> SessionTraceRetentionPolicy {
        replacing(SessionTraceRetentionPolicy.default, maximumExportBytes: exportBytes)
    }

    private func replacing(
        _ value: SessionTraceRetentionPolicy,
        maximumEvents: Int? = nil,
        maximumSessions: Int? = nil,
        abandonedWriterRetention: TimeInterval? = nil,
        maximumExportBytes: Int? = nil,
        maximumPhysicalBytes: Int? = nil
    ) -> SessionTraceRetentionPolicy {
        SessionTraceRetentionPolicy(
            richContentRetention: value.richContentRetention,
            metadataRetention: value.metadataRetention,
            maximumArtifactBytes: value.maximumArtifactBytes,
            maximumSessionRichBytes: value.maximumSessionRichBytes,
            maximumEvents: maximumEvents ?? value.maximumEvents,
            maximumGlobalRichBytes: value.maximumGlobalRichBytes,
            maximumSessions: maximumSessions ?? value.maximumSessions,
            maximumExportBytes: maximumExportBytes ?? value.maximumExportBytes,
            maximumEventMetadataBytes: value.maximumEventMetadataBytes,
            maximumIdentifierBytes: value.maximumIdentifierBytes,
            abandonedWriterRetention: abandonedWriterRetention ?? value.abandonedWriterRetention,
            maximumPhysicalBytes: maximumPhysicalBytes ?? value.maximumPhysicalBytes
        )
    }

    private func exportDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-session-trace-\(UUID().uuidString).db")
    }

    private func removeDatabase(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private func fileFootprint(_ url: URL) -> Int {
        [url.path, url.path + "-wal", url.path + "-shm"].reduce(0) { total, path in
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?
                .intValue ?? 0
            return total + size
        }
    }

    private func execute(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw sqliteError(db) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw sqliteError(db) }
    }

    private func scalar(_ url: URL, _ sql: String) throws -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw sqliteError(db) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqliteError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(db) }
        return sqlite3_column_int64(statement, 0)
    }

    private func textScalar(_ url: URL, _ sql: String) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw sqliteError(db) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqliteError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { throw sqliteError(db) }
        return String(cString: value)
    }

    private func sqliteError(_ db: OpaquePointer?) -> NSError {
        NSError(
            domain: "SessionTraceStoreTests",
            code: Int(sqlite3_errcode(db)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
    }
}
