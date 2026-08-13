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
            maximumNonterminalEvents: 2,
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
        }

        _ = try await store.prune(now: start.addingTimeInterval(91 * 24 * 60 * 60))
        #expect(try await store.list().isEmpty)
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

    private func makeStore(
        policy: SessionTraceRetentionPolicy = .default
    ) throws -> (SessionTraceStore, URL) {
        let url = temporaryDatabaseURL()
        return (try SessionTraceStore(databaseURL: url, retentionPolicy: policy), url)
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

    private func sqliteError(_ db: OpaquePointer?) -> NSError {
        NSError(
            domain: "SessionTraceStoreTests",
            code: Int(sqlite3_errcode(db)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
    }
}
