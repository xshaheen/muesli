import CryptoKit
import Foundation
import SQLite3

private let sessionTraceSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SessionTraceStoreError: Error, LocalizedError, Equatable {
    case sessionAlreadyExists(UUID)
    case sessionNotFound(UUID)
    case artifactDoesNotBelongToSession(Int64)
    case limitReached(SessionTraceLimit)
    case exportLimitExceeded(requiredBytes: Int, maximumBytes: Int)
    case invalidStoredValue(String)

    public var errorDescription: String? {
        switch self {
        case .sessionAlreadyExists(let id):
            return "Session trace \(id.uuidString) already exists."
        case .sessionNotFound(let id):
            return "Session trace \(id.uuidString) does not exist."
        case .artifactDoesNotBelongToSession(let id):
            return "Session trace artifact \(id) belongs to another session or does not exist."
        case .limitReached(let limit):
            return "Session trace limit reached: \(limit.rawValue)."
        case .exportLimitExceeded(let requiredBytes, let maximumBytes):
            return "Diagnostics export requires \(requiredBytes) bytes; the limit is \(maximumBytes) bytes."
        case .invalidStoredValue(let description):
            return "Invalid session trace data: \(description)."
        }
    }
}

/// A local-only, session-keyed diagnostic store.
///
/// The actor serializes callers without using `MainActor`. Each mutation opens a
/// checked SQLite connection and commits exactly one immediate transaction.
public actor SessionTraceStore {
    enum ClearCheckpoint: Equatable, Sendable {
        case generationIncremented(Int64)
        case terminalSessionsDeleted
        case activeSessionsReset
        case willCommit
    }

    typealias ClearCheckpointHook = @Sendable (ClearCheckpoint) throws -> Void

    private let databaseURL: URL
    private let clearCheckpoint: ClearCheckpointHook?
    public let retentionPolicy: SessionTraceRetentionPolicy

    public init(
        databaseURL: URL = MuesliPaths.defaultDatabaseURL(),
        retentionPolicy: SessionTraceRetentionPolicy = .default
    ) throws {
        self.databaseURL = databaseURL
        self.retentionPolicy = retentionPolicy
        self.clearCheckpoint = nil
        try DictationStore(databaseURL: databaseURL).migrateIfNeeded()
    }

    init(
        databaseURL: URL,
        retentionPolicy: SessionTraceRetentionPolicy = .default,
        clearCheckpoint: @escaping ClearCheckpointHook
    ) throws {
        self.databaseURL = databaseURL
        self.retentionPolicy = retentionPolicy
        self.clearCheckpoint = clearCheckpoint
        try DictationStore(databaseURL: databaseURL).migrateIfNeeded()
    }

    @discardableResult
    public func beginSession(
        id sessionID: UUID = UUID(),
        kind: SessionTraceKind,
        backendIdentity: String? = nil,
        fallbackBackendIdentity: String? = nil,
        at date: Date = Date()
    ) throws -> SessionTraceWriterToken {
        try validateIdentifier(backendIdentity)
        try validateIdentifier(fallbackBackendIdentity)
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        return try inTransaction(db) {
            _ = try pruneInternal(now: date, db: db)
            guard try scalarInt("SELECT COUNT(*) FROM session_traces", db: db) < retentionPolicy.maximumSessions else {
                throw SessionTraceStoreError.limitReached(.sessionCount)
            }
            let generation = try scalarInt64(
                "SELECT clear_generation FROM session_trace_settings WHERE singleton_id = 1",
                db: db
            )
            let writerID = UUID()
            var statement: OpaquePointer?
            let sql = """
            INSERT INTO session_traces (
                session_uuid, writer_uuid, clear_generation, kind, created_at, updated_at,
                backend_identity, fallback_backend_identity, rich_content_state, event_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'available', 1)
            """
            try prepare(sql, into: &statement, db: db)
            defer { sqlite3_finalize(statement) }
            bind(sessionID.uuidString, to: statement, at: 1)
            bind(writerID.uuidString, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, generation)
            bind(kind.rawValue, to: statement, at: 4)
            sqlite3_bind_double(statement, 5, date.timeIntervalSince1970)
            sqlite3_bind_double(statement, 6, date.timeIntervalSince1970)
            bindOptional(backendIdentity, to: statement, at: 7)
            bindOptional(fallbackBackendIdentity, to: statement, at: 8)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                if sqlite3_errcode(db) == SQLITE_CONSTRAINT {
                    throw SessionTraceStoreError.sessionAlreadyExists(sessionID)
                }
                throw sqliteError(db)
            }
            try insertEvent(
                sessionID: sessionID,
                sequence: 1,
                vocabulary: .sessionStarted,
                stage: "session",
                elapsedMilliseconds: 0,
                metadataJSON: "{}",
                artifactID: nil,
                date: date,
                db: db
            )
            return SessionTraceWriterToken(
                sessionID: sessionID,
                writerID: writerID,
                clearGeneration: generation
            )
        }
    }

    public func appendEvent(
        _ vocabulary: SessionTraceEventVocabulary,
        stage: String,
        elapsed: TimeInterval? = nil,
        metadata: [String: String] = [:],
        artifactID: Int64? = nil,
        token: SessionTraceWriterToken,
        at date: Date = Date()
    ) throws -> SessionTraceMutationResult {
        guard vocabulary != .terminal else {
            throw SessionTraceStoreError.invalidStoredValue("terminal events must use claimTerminal")
        }
        try validateIdentifier(stage)
        let metadataJSON = try encodeMetadata(metadata)
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        return try inTransaction(db) {
            switch try writerGate(token, db: db) {
            case .cleared: return .clearedByGeneration
            case .mismatch: return .writerMismatch
            case .terminal(let outcome): return .terminalAlreadyDecided(outcome)
            case .open(let eventCount, _):
                guard eventCount < retentionPolicy.maximumNonterminalEvents else {
                    return .limitReached(.eventCount)
                }
                if let artifactID, try !artifactBelongs(artifactID, to: token.sessionID, db: db) {
                    throw SessionTraceStoreError.artifactDoesNotBelongToSession(artifactID)
                }
                let sequence = eventCount + 1
                try insertEvent(
                    sessionID: token.sessionID,
                    sequence: sequence,
                    vocabulary: vocabulary,
                    stage: stage,
                    elapsedMilliseconds: elapsed.map { Int64(($0 * 1_000).rounded()) },
                    metadataJSON: metadataJSON,
                    artifactID: artifactID,
                    date: date,
                    db: db
                )
                try updateEventCount(sequence, date: date, sessionID: token.sessionID, db: db)
                return .appended
            }
        }
    }

    public func storeArtifact(
        _ content: String,
        kind: SessionTraceArtifactKind,
        token: SessionTraceWriterToken,
        at date: Date = Date()
    ) throws -> SessionTraceArtifactWriteResult {
        let payload = Data(content.utf8)
        guard payload.count <= retentionPolicy.maximumArtifactBytes else {
            return SessionTraceArtifactWriteResult(mutation: .limitReached(.artifactBytes), artifactID: nil)
        }
        let fingerprint = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        return try inTransaction(db) {
            let richBytes: Int
            switch try writerGate(token, db: db) {
            case .cleared:
                return SessionTraceArtifactWriteResult(mutation: .clearedByGeneration, artifactID: nil)
            case .mismatch:
                return SessionTraceArtifactWriteResult(mutation: .writerMismatch, artifactID: nil)
            case .terminal(let outcome):
                return SessionTraceArtifactWriteResult(
                    mutation: .terminalAlreadyDecided(outcome),
                    artifactID: nil
                )
            case .open(_, let bytes):
                richBytes = bytes
            }

            let priorReference = try referencedArtifact(
                kind: kind,
                sessionID: token.sessionID,
                db: db
            )
            if let existingID = try matchingArtifact(
                fingerprint: fingerprint,
                payload: payload,
                sessionID: token.sessionID,
                db: db
            ) {
                try upsertReference(
                    kind: kind,
                    artifactID: existingID,
                    sessionID: token.sessionID,
                    date: date,
                    db: db
                )
                try deleteArtifactIfOrphaned(priorReference, db: db)
                try refreshRichByteCount(sessionID: token.sessionID, date: date, db: db)
                return SessionTraceArtifactWriteResult(mutation: .deduplicated, artifactID: existingID)
            }

            let reclaimable = try reclaimableBytes(for: priorReference, db: db)
            guard richBytes - reclaimable + payload.count <= retentionPolicy.maximumSessionRichBytes else {
                return SessionTraceArtifactWriteResult(mutation: .limitReached(.sessionRichBytes), artifactID: nil)
            }
            let projectedGlobal = try scalarInt(
                "SELECT COALESCE(SUM(byte_count), 0) FROM session_trace_artifacts",
                db: db
            ) - reclaimable + payload.count
            if projectedGlobal > retentionPolicy.maximumGlobalRichBytes {
                try pruneRichContentForCapacity(
                    bytesNeeded: projectedGlobal - retentionPolicy.maximumGlobalRichBytes,
                    excluding: token.sessionID,
                    db: db
                )
            }
            let afterPruneGlobal = try scalarInt(
                "SELECT COALESCE(SUM(byte_count), 0) FROM session_trace_artifacts",
                db: db
            ) - reclaimable + payload.count
            guard afterPruneGlobal <= retentionPolicy.maximumGlobalRichBytes else {
                return SessionTraceArtifactWriteResult(mutation: .limitReached(.globalRichBytes), artifactID: nil)
            }

            let artifactID = try insertArtifact(
                fingerprint: fingerprint,
                payload: payload,
                sessionID: token.sessionID,
                date: date,
                db: db
            )
            try upsertReference(
                kind: kind,
                artifactID: artifactID,
                sessionID: token.sessionID,
                date: date,
                db: db
            )
            try deleteArtifactIfOrphaned(priorReference, db: db)
            try refreshRichByteCount(sessionID: token.sessionID, date: date, db: db)
            return SessionTraceArtifactWriteResult(mutation: .appended, artifactID: artifactID)
        }
    }

    public func associate(
        token: SessionTraceWriterToken,
        dictationID: Int64? = nil,
        meetingID: Int64? = nil,
        at date: Date = Date()
    ) throws -> SessionTraceMutationResult {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try inTransaction(db) {
            switch try writerGate(token, db: db) {
            case .cleared: return .clearedByGeneration
            case .mismatch: return .writerMismatch
            case .terminal(let outcome): return .terminalAlreadyDecided(outcome)
            case .open:
                var statement: OpaquePointer?
                try prepare(
                    "UPDATE session_traces SET dictation_id = ?, meeting_id = ?, updated_at = ? WHERE session_uuid = ?",
                    into: &statement,
                    db: db
                )
                defer { sqlite3_finalize(statement) }
                bindOptional(dictationID, to: statement, at: 1)
                bindOptional(meetingID, to: statement, at: 2)
                sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
                bind(token.sessionID.uuidString, to: statement, at: 4)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
                return .appended
            }
        }
    }

    public func claimTerminal(
        _ outcome: SessionTraceTerminalOutcome,
        metadata: [String: String] = [:],
        token: SessionTraceWriterToken,
        at date: Date = Date()
    ) throws -> SessionTraceTerminalClaimResult {
        let metadataJSON = try encodeMetadata(metadata)
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        return try inTransaction(db) {
            switch try writerGate(token, db: db) {
            case .cleared:
                return try claimTerminalAfterDiagnosticsClear(
                    outcome,
                    token: token,
                    date: date,
                    db: db
                )
            case .mismatch:
                throw SessionTraceStoreError.sessionNotFound(token.sessionID)
            case .terminal(let existing):
                return .alreadyDecided(existing)
            case .open(let eventCount, _):
                var statement: OpaquePointer?
                try prepare(
                    """
                    UPDATE session_traces
                    SET terminal_outcome = ?, terminal_at = ?, updated_at = ?, event_count = event_count + 1
                    WHERE session_uuid = ? AND writer_uuid = ? AND clear_generation = ?
                      AND terminal_outcome IS NULL AND event_count < ?
                    """,
                    into: &statement,
                    db: db
                )
                defer { sqlite3_finalize(statement) }
                bind(outcome.rawValue, to: statement, at: 1)
                sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
                sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
                bind(token.sessionID.uuidString, to: statement, at: 4)
                bind(token.writerID.uuidString, to: statement, at: 5)
                sqlite3_bind_int64(statement, 6, token.clearGeneration)
                sqlite3_bind_int(statement, 7, Int32(retentionPolicy.maximumEvents))
                guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
                guard sqlite3_changes(db) == 1 else {
                    let decided = try terminalOutcome(sessionID: token.sessionID, db: db)
                    guard let decided else {
                        throw SessionTraceStoreError.invalidStoredValue("terminal compare-and-set did not decide")
                    }
                    return .alreadyDecided(decided)
                }
                try insertEvent(
                    sessionID: token.sessionID,
                    sequence: eventCount + 1,
                    vocabulary: .terminal,
                    stage: "terminal",
                    elapsedMilliseconds: nil,
                    metadataJSON: metadataJSON,
                    artifactID: nil,
                    date: date,
                    db: db
                )
                return .won
            }
        }
    }

    /// Completes an active session whose diagnostics were cleared while work was running.
    /// This deliberately records only the terminal columns.
    private func claimTerminalAfterDiagnosticsClear(
        _ outcome: SessionTraceTerminalOutcome,
        token: SessionTraceWriterToken,
        date: Date,
        db: OpaquePointer?
    ) throws -> SessionTraceTerminalClaimResult {
        var inspect: OpaquePointer?
        try prepare(
            """
            SELECT writer_uuid, clear_generation, rich_content_state, terminal_outcome
            FROM session_traces WHERE session_uuid = ?
            """,
            into: &inspect,
            db: db
        )
        bind(token.sessionID.uuidString, to: inspect, at: 1)
        let result = sqlite3_step(inspect)
        guard result == SQLITE_ROW else {
            sqlite3_finalize(inspect)
            if result == SQLITE_DONE {
                throw SessionTraceStoreError.sessionNotFound(token.sessionID)
            }
            throw sqliteError(db)
        }
        let writerID = text(inspect, 0)
        let currentGeneration = sqlite3_column_int64(inspect, 1)
        let contentState = text(inspect, 2)
        let existingRaw = optionalText(inspect, 3)
        sqlite3_finalize(inspect)

        guard writerID == token.writerID.uuidString else {
            throw SessionTraceStoreError.sessionNotFound(token.sessionID)
        }
        if let existingRaw {
            guard let existing = SessionTraceTerminalOutcome(rawValue: existingRaw) else {
                throw SessionTraceStoreError.invalidStoredValue("terminal outcome \(existingRaw)")
            }
            return .alreadyDecided(existing)
        }
        guard currentGeneration > token.clearGeneration,
              contentState == SessionTraceContentState.clearedWhileActive.rawValue else {
            throw SessionTraceStoreError.invalidStoredValue(
                "post-clear terminal path requires a cleared active writer"
            )
        }

        var statement: OpaquePointer?
        try prepare(
            """
            UPDATE session_traces
            SET terminal_outcome = ?, terminal_at = ?, updated_at = ?
            WHERE session_uuid = ? AND writer_uuid = ? AND clear_generation = ?
              AND rich_content_state = 'cleared_while_active' AND terminal_outcome IS NULL
            """,
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        bind(outcome.rawValue, to: statement, at: 1)
        sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
        bind(token.sessionID.uuidString, to: statement, at: 4)
        bind(token.writerID.uuidString, to: statement, at: 5)
        sqlite3_bind_int64(statement, 6, currentGeneration)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
        guard sqlite3_changes(db) == 1 else {
            guard let decided = try terminalOutcome(sessionID: token.sessionID, db: db) else {
                throw SessionTraceStoreError.invalidStoredValue(
                    "post-clear terminal compare-and-set did not decide"
                )
            }
            return .alreadyDecided(decided)
        }
        return .won
    }

    /// Deletes diagnostics without touching normal history or retained recordings.
    @discardableResult
    public func clearDiagnostics(at date: Date = Date()) throws -> SessionTraceClearResult {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try inTransaction(db) {
            let nextGeneration = try scalarInt64(
                "SELECT clear_generation + 1 FROM session_trace_settings WHERE singleton_id = 1",
                db: db
            )
            var statement: OpaquePointer?
            try prepare(
                "UPDATE session_trace_settings SET clear_generation = ?, updated_at = ? WHERE singleton_id = 1",
                into: &statement,
                db: db
            )
            sqlite3_bind_int64(statement, 1, nextGeneration)
            sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_finalize(statement)
                throw sqliteError(db)
            }
            sqlite3_finalize(statement)
            try clearCheckpoint?(.generationIncremented(nextGeneration))

            let activeSessions = try scalarInt(
                "SELECT COUNT(*) FROM session_traces WHERE terminal_outcome IS NULL",
                db: db
            )
            let activeSessionsReset = try scalarInt(
                """
                SELECT COUNT(*) FROM session_traces
                WHERE terminal_outcome IS NULL
                  AND (event_count > 0 OR rich_byte_count > 0 OR rich_content_state <> 'cleared_while_active')
                """,
                db: db
            )

            try prepare(
                "DELETE FROM session_traces WHERE terminal_outcome IS NOT NULL",
                into: &statement,
                db: db
            )
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_finalize(statement)
                throw sqliteError(db)
            }
            let terminalDeleted = Int(sqlite3_changes(db))
            sqlite3_finalize(statement)
            try clearCheckpoint?(.terminalSessionsDeleted)

            try prepare(
                """
                DELETE FROM session_trace_events
                WHERE session_uuid IN (SELECT session_uuid FROM session_traces WHERE terminal_outcome IS NULL)
                """,
                into: &statement,
                db: db
            )
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_finalize(statement)
                throw sqliteError(db)
            }
            let eventsDeleted = Int(sqlite3_changes(db))
            sqlite3_finalize(statement)

            try prepare(
                """
                DELETE FROM session_trace_artifacts
                WHERE session_uuid IN (SELECT session_uuid FROM session_traces WHERE terminal_outcome IS NULL)
                """,
                into: &statement,
                db: db
            )
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_finalize(statement)
                throw sqliteError(db)
            }
            let artifactsDeleted = Int(sqlite3_changes(db))
            sqlite3_finalize(statement)

            try prepare(
                """
                UPDATE session_traces
                SET clear_generation = ?, updated_at = ?, event_count = 0, rich_byte_count = 0,
                    rich_content_state = 'cleared_while_active', dictation_id = NULL,
                    meeting_id = NULL, backend_identity = NULL, fallback_backend_identity = NULL
                WHERE terminal_outcome IS NULL
                """,
                into: &statement,
                db: db
            )
            sqlite3_bind_int64(statement, 1, nextGeneration)
            sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_finalize(statement)
                throw sqliteError(db)
            }
            sqlite3_finalize(statement)
            try clearCheckpoint?(.activeSessionsReset)
            try clearCheckpoint?(.willCommit)

            return SessionTraceClearResult(
                clearGeneration: nextGeneration,
                terminalSessionsDeleted: terminalDeleted,
                activeSessionsPreserved: activeSessions,
                activeSessionsReset: activeSessionsReset,
                eventsDeleted: eventsDeleted,
                artifactsDeleted: artifactsDeleted
            )
        }
    }

    public func exportDiagnosticsData(now: Date = Date()) throws -> Data {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try execute("BEGIN", db: db)
        do {
            let estimatedBytes = try estimatedExportBytes(db: db)
            guard estimatedBytes <= retentionPolicy.maximumExportBytes else {
                throw SessionTraceStoreError.exportLimitExceeded(
                    requiredBytes: estimatedBytes,
                    maximumBytes: retentionPolicy.maximumExportBytes
                )
            }
            let summaries = try loadAllSummaries(db: db)
            let details = try summaries.map { summary in
                SessionTraceDetail(
                    summary: summary,
                    events: try loadEvents(sessionID: summary.sessionID, db: db),
                    artifacts: try loadArtifacts(sessionID: summary.sessionID, db: db)
                )
            }
            let payload = SessionTraceDiagnosticsExport(
                schemaVersion: SessionTraceDiagnosticsExport.currentSchemaVersion,
                exportedAt: now,
                provenance: SessionTraceExportProvenance(
                    storageScope: "local-only",
                    contentPolicy: "short-retention-size-bounded",
                    databaseSchemaVersion: DictationStore.currentSchemaVersion
                ),
                policy: retentionPolicy,
                traces: details
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(payload)
            guard data.count <= retentionPolicy.maximumExportBytes else {
                throw SessionTraceStoreError.exportLimitExceeded(
                    requiredBytes: data.count,
                    maximumBytes: retentionPolicy.maximumExportBytes
                )
            }
            try execute("COMMIT", db: db)
            return data
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    @discardableResult
    public func exportDiagnostics(to destination: URL, now: Date = Date()) throws -> Int {
        let data = try exportDiagnosticsData(now: now)
        try data.write(to: destination, options: .atomic)
        return data.count
    }

    public func list(limit: Int = 100) throws -> [SessionTraceSummary] {
        guard limit > 0 else { return [] }
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        try prepare(
            """
            SELECT session_uuid, kind, created_at, updated_at, terminal_outcome,
                   dictation_id, meeting_id, backend_identity, fallback_backend_identity,
                   rich_content_state, event_count, rich_byte_count
            FROM session_traces ORDER BY created_at DESC, session_uuid DESC LIMIT ?
            """,
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(min(limit, retentionPolicy.maximumSessions)))
        var summaries: [SessionTraceSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            summaries.append(try summary(from: statement))
        }
        guard sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE else {
            throw sqliteError(db)
        }
        return summaries
    }

    public func detail(sessionID: UUID) throws -> SessionTraceDetail? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        guard let traceSummary = try loadSummary(sessionID: sessionID, db: db) else { return nil }
        return SessionTraceDetail(
            summary: traceSummary,
            events: try loadEvents(sessionID: sessionID, db: db),
            artifacts: try loadArtifacts(sessionID: sessionID, db: db)
        )
    }

    @discardableResult
    public func prune(now: Date = Date()) throws -> SessionTracePruneResult {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try inTransaction(db) { try pruneInternal(now: now, db: db) }
    }
}

private extension SessionTraceStore {
    enum WriterGate {
        case open(eventCount: Int, richBytes: Int)
        case terminal(SessionTraceTerminalOutcome)
        case cleared
        case mismatch
    }

    func openDatabase() throws -> OpaquePointer? {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw sqliteError(db)
        }
        do {
            guard sqlite3_busy_timeout(db, 5_000) == SQLITE_OK else { throw sqliteError(db) }
            try execute("PRAGMA foreign_keys=ON", db: db)
            try execute("PRAGMA secure_delete=ON", db: db)
            try execute("PRAGMA journal_mode=WAL", db: db)
            return db
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    func inTransaction<T>(_ db: OpaquePointer?, _ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            let result = try body()
            try execute("COMMIT", db: db)
            return result
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    func writerGate(_ token: SessionTraceWriterToken, db: OpaquePointer?) throws -> WriterGate {
        let globalGeneration = try scalarInt64(
            "SELECT clear_generation FROM session_trace_settings WHERE singleton_id = 1",
            db: db
        )
        guard globalGeneration == token.clearGeneration else { return .cleared }
        var statement: OpaquePointer?
        try prepare(
            """
            SELECT writer_uuid, clear_generation, terminal_outcome, event_count, rich_byte_count
            FROM session_traces WHERE session_uuid = ?
            """,
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        bind(token.sessionID.uuidString, to: statement, at: 1)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { return .cleared }
            throw sqliteError(db)
        }
        guard text(statement, 0) == token.writerID.uuidString else { return .mismatch }
        guard sqlite3_column_int64(statement, 1) == token.clearGeneration else { return .cleared }
        if let raw = optionalText(statement, 2) {
            guard let outcome = SessionTraceTerminalOutcome(rawValue: raw) else {
                throw SessionTraceStoreError.invalidStoredValue("terminal outcome \(raw)")
            }
            return .terminal(outcome)
        }
        return .open(
            eventCount: Int(sqlite3_column_int(statement, 3)),
            richBytes: Int(sqlite3_column_int64(statement, 4))
        )
    }

    func encodeMetadata(_ metadata: [String: String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(metadata)
        guard data.count <= retentionPolicy.maximumEventMetadataBytes else {
            throw SessionTraceStoreError.limitReached(.eventMetadataBytes)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func validateIdentifier(_ value: String?) throws {
        guard let value else { return }
        guard value.utf8.count <= retentionPolicy.maximumIdentifierBytes else {
            throw SessionTraceStoreError.limitReached(.identifierBytes)
        }
    }

    func insertEvent(
        sessionID: UUID,
        sequence: Int,
        vocabulary: SessionTraceEventVocabulary,
        stage: String,
        elapsedMilliseconds: Int64?,
        metadataJSON: String,
        artifactID: Int64?,
        date: Date,
        db: OpaquePointer?
    ) throws {
        var statement: OpaquePointer?
        try prepare(
            """
            INSERT INTO session_trace_events (
                session_uuid, sequence, vocabulary, stage, elapsed_milliseconds,
                metadata_json, artifact_id, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        bind(sessionID.uuidString, to: statement, at: 1)
        sqlite3_bind_int(statement, 2, Int32(sequence))
        bind(vocabulary.rawValue, to: statement, at: 3)
        bind(stage, to: statement, at: 4)
        bindOptional(elapsedMilliseconds, to: statement, at: 5)
        bind(metadataJSON, to: statement, at: 6)
        bindOptional(artifactID, to: statement, at: 7)
        sqlite3_bind_double(statement, 8, date.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
    }

    func updateEventCount(_ count: Int, date: Date, sessionID: UUID, db: OpaquePointer?) throws {
        var statement: OpaquePointer?
        try prepare(
            "UPDATE session_traces SET event_count = ?, updated_at = ? WHERE session_uuid = ?",
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(count))
        sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        bind(sessionID.uuidString, to: statement, at: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
    }

    func matchingArtifact(
        fingerprint: String,
        payload: Data,
        sessionID: UUID,
        db: OpaquePointer?
    ) throws -> Int64? {
        var statement: OpaquePointer?
        try prepare(
            "SELECT id, content FROM session_trace_artifacts WHERE session_uuid = ? AND content_fingerprint = ?",
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        bind(sessionID.uuidString, to: statement, at: 1)
        bind(fingerprint, to: statement, at: 2)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw sqliteError(db) }
            if blob(statement, 1) == payload { return sqlite3_column_int64(statement, 0) }
        }
    }

    func insertArtifact(
        fingerprint: String,
        payload: Data,
        sessionID: UUID,
        date: Date,
        db: OpaquePointer?
    ) throws -> Int64 {
        var statement: OpaquePointer?
        try prepare(
            """
            INSERT INTO session_trace_artifacts (
                session_uuid, content_fingerprint, content, byte_count, created_at
            ) VALUES (?, ?, ?, ?, ?)
            """,
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        bind(sessionID.uuidString, to: statement, at: 1)
        bind(fingerprint, to: statement, at: 2)
        bind(payload, to: statement, at: 3)
        sqlite3_bind_int(statement, 4, Int32(payload.count))
        sqlite3_bind_double(statement, 5, date.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
        return sqlite3_last_insert_rowid(db)
    }

    func referencedArtifact(
        kind: SessionTraceArtifactKind,
        sessionID: UUID,
        db: OpaquePointer?
    ) throws -> Int64? {
        var statement: OpaquePointer?
        try prepare(
            "SELECT artifact_id FROM session_trace_artifact_references WHERE session_uuid = ? AND artifact_kind = ?",
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        bind(sessionID.uuidString, to: statement, at: 1)
        bind(kind.rawValue, to: statement, at: 2)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return sqlite3_column_int64(statement, 0)
        case SQLITE_DONE: return nil
        default: throw sqliteError(db)
        }
    }

    func upsertReference(
        kind: SessionTraceArtifactKind,
        artifactID: Int64,
        sessionID: UUID,
        date: Date,
        db: OpaquePointer?
    ) throws {
        var statement: OpaquePointer?
        try prepare(
            """
            INSERT INTO session_trace_artifact_references (
                session_uuid, artifact_kind, artifact_id, created_at
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(session_uuid, artifact_kind) DO UPDATE SET
                artifact_id = excluded.artifact_id,
                created_at = excluded.created_at
            """,
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        bind(sessionID.uuidString, to: statement, at: 1)
        bind(kind.rawValue, to: statement, at: 2)
        sqlite3_bind_int64(statement, 3, artifactID)
        sqlite3_bind_double(statement, 4, date.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
    }

    func reclaimableBytes(for artifactID: Int64?, db: OpaquePointer?) throws -> Int {
        guard let artifactID else { return 0 }
        var statement: OpaquePointer?
        try prepare(
            """
            SELECT byte_count,
                   (SELECT COUNT(*) FROM session_trace_artifact_references WHERE artifact_id = ?),
                   (SELECT COUNT(*) FROM session_trace_events WHERE artifact_id = ?)
            FROM session_trace_artifacts WHERE id = ?
            """,
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, artifactID)
        sqlite3_bind_int64(statement, 2, artifactID)
        sqlite3_bind_int64(statement, 3, artifactID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        let referenceCount = sqlite3_column_int(statement, 1)
        let eventCount = sqlite3_column_int(statement, 2)
        return referenceCount == 1 && eventCount == 0 ? Int(sqlite3_column_int(statement, 0)) : 0
    }

    func deleteArtifactIfOrphaned(_ artifactID: Int64?, db: OpaquePointer?) throws {
        guard let artifactID else { return }
        var statement: OpaquePointer?
        try prepare(
            """
            DELETE FROM session_trace_artifacts
            WHERE id = ?
              AND NOT EXISTS (SELECT 1 FROM session_trace_artifact_references WHERE artifact_id = ?)
              AND NOT EXISTS (SELECT 1 FROM session_trace_events WHERE artifact_id = ?)
            """,
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, artifactID)
        sqlite3_bind_int64(statement, 2, artifactID)
        sqlite3_bind_int64(statement, 3, artifactID)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
    }

    func refreshRichByteCount(sessionID: UUID, date: Date, db: OpaquePointer?) throws {
        var statement: OpaquePointer?
        try prepare(
            """
            UPDATE session_traces
            SET rich_byte_count = (
                    SELECT COALESCE(SUM(byte_count), 0)
                    FROM session_trace_artifacts
                    WHERE session_uuid = ?
                ),
                rich_content_state = 'available',
                updated_at = ?
            WHERE session_uuid = ?
            """,
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        bind(sessionID.uuidString, to: statement, at: 1)
        sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        bind(sessionID.uuidString, to: statement, at: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
    }

    func artifactBelongs(_ artifactID: Int64, to sessionID: UUID, db: OpaquePointer?) throws -> Bool {
        var statement: OpaquePointer?
        try prepare(
            "SELECT 1 FROM session_trace_artifacts WHERE id = ? AND session_uuid = ?",
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, artifactID)
        bind(sessionID.uuidString, to: statement, at: 2)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func terminalOutcome(sessionID: UUID, db: OpaquePointer?) throws -> SessionTraceTerminalOutcome? {
        var statement: OpaquePointer?
        try prepare(
            "SELECT terminal_outcome FROM session_traces WHERE session_uuid = ?",
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        bind(sessionID.uuidString, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = optionalText(statement, 0) else { return nil }
        guard let outcome = SessionTraceTerminalOutcome(rawValue: raw) else {
            throw SessionTraceStoreError.invalidStoredValue("terminal outcome \(raw)")
        }
        return outcome
    }

    func pruneInternal(now: Date, db: OpaquePointer?) throws -> SessionTracePruneResult {
        let richCutoff = now.addingTimeInterval(-retentionPolicy.richContentRetention).timeIntervalSince1970
        let metadataCutoff = now.addingTimeInterval(-retentionPolicy.metadataRetention).timeIntervalSince1970
        let richIDs = try sessionIDs(
            sql: "SELECT session_uuid FROM session_traces WHERE terminal_at IS NOT NULL AND terminal_at < ? AND rich_byte_count > 0",
            value: richCutoff,
            db: db
        )
        for id in richIDs { try pruneRichContent(sessionID: id, db: db) }

        var statement: OpaquePointer?
        try prepare(
            "DELETE FROM session_traces WHERE terminal_at IS NOT NULL AND terminal_at < ?",
            into: &statement,
            db: db
        )
        sqlite3_bind_double(statement, 1, metadataCutoff)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            sqlite3_finalize(statement)
            throw sqliteError(db)
        }
        let expiredCount = Int(sqlite3_changes(db))
        sqlite3_finalize(statement)

        let overflow = max(0, try scalarInt("SELECT COUNT(*) FROM session_traces", db: db) - retentionPolicy.maximumSessions)
        var overflowDeleted = 0
        if overflow > 0 {
            try prepare(
                """
                DELETE FROM session_traces WHERE session_uuid IN (
                    SELECT session_uuid FROM session_traces
                    WHERE terminal_at IS NOT NULL
                    ORDER BY terminal_at ASC, session_uuid ASC LIMIT ?
                )
                """,
                into: &statement,
                db: db
            )
            sqlite3_bind_int(statement, 1, Int32(overflow))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_finalize(statement)
                throw sqliteError(db)
            }
            overflowDeleted = Int(sqlite3_changes(db))
            sqlite3_finalize(statement)
        }
        return SessionTracePruneResult(
            richSessionsPruned: richIDs.count,
            metadataSessionsDeleted: expiredCount + overflowDeleted
        )
    }

    func pruneRichContentForCapacity(bytesNeeded: Int, excluding: UUID, db: OpaquePointer?) throws {
        guard bytesNeeded > 0 else { return }
        var statement: OpaquePointer?
        try prepare(
            """
            SELECT session_uuid FROM session_traces
            WHERE terminal_at IS NOT NULL AND rich_byte_count > 0 AND session_uuid <> ?
            ORDER BY terminal_at ASC, session_uuid ASC
            """,
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        bind(excluding.uuidString, to: statement, at: 1)
        var ids: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = UUID(uuidString: text(statement, 0)) { ids.append(id) }
        }
        var reclaimed = 0
        for id in ids where reclaimed < bytesNeeded {
            reclaimed += try scalarInt(
                "SELECT rich_byte_count FROM session_traces WHERE session_uuid = '\(id.uuidString)'",
                db: db
            )
            try pruneRichContent(sessionID: id, db: db)
        }
    }

    func pruneRichContent(sessionID: UUID, db: OpaquePointer?) throws {
        var statement: OpaquePointer?
        try prepare(
            "DELETE FROM session_trace_artifacts WHERE session_uuid = ?",
            into: &statement,
            db: db
        )
        bind(sessionID.uuidString, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            sqlite3_finalize(statement)
            throw sqliteError(db)
        }
        sqlite3_finalize(statement)
        try prepare(
            "UPDATE session_traces SET rich_byte_count = 0, rich_content_state = 'pruned' WHERE session_uuid = ?",
            into: &statement,
            db: db
        )
        bind(sessionID.uuidString, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            sqlite3_finalize(statement)
            throw sqliteError(db)
        }
        sqlite3_finalize(statement)
    }

    func sessionIDs(sql: String, value: Double, db: OpaquePointer?) throws -> [UUID] {
        var statement: OpaquePointer?
        try prepare(sql, into: &statement, db: db)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, value)
        var ids: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = UUID(uuidString: text(statement, 0)) { ids.append(id) }
        }
        return ids
    }

    func loadSummary(sessionID: UUID, db: OpaquePointer?) throws -> SessionTraceSummary? {
        var statement: OpaquePointer?
        try prepare(
            """
            SELECT session_uuid, kind, created_at, updated_at, terminal_outcome,
                   dictation_id, meeting_id, backend_identity, fallback_backend_identity,
                   rich_content_state, event_count, rich_byte_count
            FROM session_traces WHERE session_uuid = ?
            """,
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        bind(sessionID.uuidString, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try summary(from: statement)
    }

    func loadAllSummaries(db: OpaquePointer?) throws -> [SessionTraceSummary] {
        var statement: OpaquePointer?
        try prepare(
            """
            SELECT session_uuid, kind, created_at, updated_at, terminal_outcome,
                   dictation_id, meeting_id, backend_identity, fallback_backend_identity,
                   rich_content_state, event_count, rich_byte_count
            FROM session_traces ORDER BY created_at ASC, session_uuid ASC
            """,
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        var summaries: [SessionTraceSummary] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return summaries }
            guard result == SQLITE_ROW else { throw sqliteError(db) }
            summaries.append(try summary(from: statement))
        }
    }

    /// Conservatively accounts for JSON escaping before loading rich content
    /// into memory. The final encoded byte count remains the authoritative cap.
    func estimatedExportBytes(db: OpaquePointer?) throws -> Int {
        let sql = """
        SELECT 8192
             + (SELECT COUNT(*) * 2048 FROM session_traces)
             + COALESCE((
                   SELECT SUM((length(stage) + length(metadata_json)) * 6 + 512)
                   FROM session_trace_events
               ), 0)
             + COALESCE((
                   SELECT SUM(byte_count * 6 + 512)
                   FROM session_trace_artifacts
               ), 0)
             + COALESCE((
                   SELECT COUNT(*) * 256
                   FROM session_trace_artifact_references
               ), 0)
        """
        let estimate = try scalarInt64(sql, db: db)
        return estimate > Int64(Int.max) ? Int.max : Int(estimate)
    }

    func summary(from statement: OpaquePointer?) throws -> SessionTraceSummary {
        let sessionRaw = text(statement, 0)
        let kindRaw = text(statement, 1)
        let storedStateRaw = text(statement, 9)
        guard let sessionID = UUID(uuidString: sessionRaw),
              let kind = SessionTraceKind(rawValue: kindRaw),
              let storedState = SessionTraceContentState(rawValue: storedStateRaw) else {
            throw SessionTraceStoreError.invalidStoredValue("session summary")
        }
        let terminal = try optionalText(statement, 4).map {
            guard let outcome = SessionTraceTerminalOutcome(rawValue: $0) else {
                throw SessionTraceStoreError.invalidStoredValue("terminal outcome \($0)")
            }
            return outcome
        }
        let richBytes = Int(sqlite3_column_int64(statement, 11))
        let contentState: SessionTraceContentState
        if storedState != .available {
            contentState = storedState
        } else if terminal == nil {
            contentState = .activeWriter
        } else if richBytes == 0 {
            contentState = .empty
        } else {
            contentState = .available
        }
        return SessionTraceSummary(
            sessionID: sessionID,
            kind: kind,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            terminalOutcome: terminal,
            dictationID: optionalInt64(statement, 5),
            meetingID: optionalInt64(statement, 6),
            backendIdentity: optionalText(statement, 7),
            fallbackBackendIdentity: optionalText(statement, 8),
            contentState: contentState,
            eventCount: Int(sqlite3_column_int(statement, 10)),
            richByteCount: richBytes
        )
    }

    func loadEvents(sessionID: UUID, db: OpaquePointer?) throws -> [SessionTraceEvent] {
        var statement: OpaquePointer?
        try prepare(
            """
            SELECT sequence, vocabulary, stage, elapsed_milliseconds, metadata_json, artifact_id, created_at
            FROM session_trace_events WHERE session_uuid = ? ORDER BY sequence
            """,
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        bind(sessionID.uuidString, to: statement, at: 1)
        var events: [SessionTraceEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let vocabularyRaw = text(statement, 1)
            guard let vocabulary = SessionTraceEventVocabulary(rawValue: vocabularyRaw) else {
                throw SessionTraceStoreError.invalidStoredValue("event vocabulary \(vocabularyRaw)")
            }
            let metadataData = Data(text(statement, 4).utf8)
            let metadata = try JSONDecoder().decode([String: String].self, from: metadataData)
            events.append(SessionTraceEvent(
                sequence: Int(sqlite3_column_int(statement, 0)),
                vocabulary: vocabulary,
                stage: text(statement, 2),
                elapsedMilliseconds: optionalInt64(statement, 3),
                metadata: metadata,
                artifactID: optionalInt64(statement, 5),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            ))
        }
        return events
    }

    func loadArtifacts(sessionID: UUID, db: OpaquePointer?) throws -> [SessionTraceArtifact] {
        var statement: OpaquePointer?
        try prepare(
            """
            SELECT a.id, a.content, a.byte_count, group_concat(r.artifact_kind)
            FROM session_trace_artifacts a
            JOIN session_trace_artifact_references r ON r.artifact_id = a.id
            WHERE a.session_uuid = ?
            GROUP BY a.id, a.content, a.byte_count
            ORDER BY a.id
            """,
            into: &statement,
            db: db
        )
        defer { sqlite3_finalize(statement) }
        bind(sessionID.uuidString, to: statement, at: 1)
        var artifacts: [SessionTraceArtifact] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let payload = blob(statement, 1)
            let content = String(data: payload, encoding: .utf8)
            let kinds = text(statement, 3).split(separator: ",").compactMap {
                SessionTraceArtifactKind(rawValue: String($0))
            }.sorted { $0.rawValue < $1.rawValue }
            artifacts.append(SessionTraceArtifact(
                id: sqlite3_column_int64(statement, 0),
                kinds: kinds,
                content: content,
                byteCount: Int(sqlite3_column_int(statement, 2)),
                state: content == nil ? .unavailable : (payload.isEmpty ? .empty : .available)
            ))
        }
        return artifacts
    }

    func execute(_ sql: String, db: OpaquePointer?) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw sqliteError(db) }
    }

    func prepare(_ sql: String, into statement: inout OpaquePointer?, db: OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqliteError(db) }
    }

    func scalarInt(_ sql: String, db: OpaquePointer?) throws -> Int {
        Int(try scalarInt64(sql, db: db))
    }

    func scalarInt64(_ sql: String, db: OpaquePointer?) throws -> Int64 {
        var statement: OpaquePointer?
        try prepare(sql, into: &statement, db: db)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(db) }
        return sqlite3_column_int64(statement, 0)
    }

    func sqliteError(_ db: OpaquePointer?) -> NSError {
        NSError(
            domain: "MuesliSessionTraceStore",
            code: Int(sqlite3_errcode(db)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
    }

    func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, sessionTraceSQLiteTransient)
    }

    func bind(_ value: Data, to statement: OpaquePointer?, at index: Int32) {
        _ = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), sessionTraceSQLiteTransient)
        }
    }

    func bindOptional(_ value: String?, to statement: OpaquePointer?, at index: Int32) {
        if let value { bind(value, to: statement, at: index) } else { sqlite3_bind_null(statement, index) }
    }

    func bindOptional(_ value: Int64?, to statement: OpaquePointer?, at index: Int32) {
        if let value { sqlite3_bind_int64(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }

    func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    func optionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(statement, index)
    }

    func optionalInt64(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }

    func blob(_ statement: OpaquePointer?, _ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}
