import Foundation
import SQLite3
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let recordingSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum RecordingArtifactStoreError: Error, LocalizedError, Equatable {
    case unsupportedFileExtension(String)
    case unsafeRecordingRoot
    case unsafeSource
    case artifactNotFound
    case artifactUnavailable(RecordingArtifactLifecycleState)
    case destinationAlreadyExists

    public var errorDescription: String? {
        switch self {
        case .unsupportedFileExtension(let value): "Unsupported recording file extension: \(value)."
        case .unsafeRecordingRoot: "The recording storage root is not a safe app-owned directory."
        case .unsafeSource: "The recording file is outside the allowed root or is not a safe regular file."
        case .artifactNotFound: "The retained recording no longer exists."
        case .artifactUnavailable(let state): "The retained recording is unavailable (\(state.rawValue))."
        case .destinationAlreadyExists: "A recording already exists for that artifact identity."
        }
    }
}

/// Owns local recording files and their local-only relational metadata.
///
/// Files are named only from opaque UUIDs. Diagnostics may reference an artifact but
/// never own it; normal history and audio-only dictation history are the owners.
public final class RecordingArtifactStore: @unchecked Sendable {
    private static let supportedExtensions: Set<String> = ["wav", "m4a", "caf", "aiff", "aif", "mp3"]
    private let lifecycleLock = NSRecursiveLock()

    public let databaseURL: URL
    public let recordingsRootURL: URL
    public let legacyMeetingRootURL: URL
    public let retentionPolicy: RecordingArtifactRetentionPolicy

    public init(
        databaseURL: URL,
        recordingsRootURL: URL,
        legacyMeetingRootURL: URL,
        retentionPolicy: RecordingArtifactRetentionPolicy = .default,
        migrateDatabase: Bool = true
    ) throws {
        self.databaseURL = databaseURL
        self.recordingsRootURL = recordingsRootURL.standardizedFileURL
        self.legacyMeetingRootURL = legacyMeetingRootURL.standardizedFileURL
        self.retentionPolicy = retentionPolicy
        if migrateDatabase {
            try DictationStore(databaseURL: databaseURL).migrateIfNeeded()
        }
        try ensureSecureRoot()
        try validateConfiguredDirectory(legacyMeetingRootURL, allowMissing: true)
    }

    @discardableResult
    public func adoptCapture(
        at sourceURL: URL,
        artifactID: RecordingArtifactID = RecordingArtifactID(),
        sessionID: UUID,
        captureKind: RecordingCaptureKind,
        savePolicy: RecordingSavePolicySnapshot,
        terminalAt: Date? = nil,
        now: Date = Date()
    ) throws -> RecordingArtifact {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let ext = try normalizedExtension(sourceURL.pathExtension)
        try validateRegularSingleLinkFile(sourceURL)
        let byteCount = try fileByteCount(sourceURL)
        let destination = artifactURL(id: artifactID, fileExtension: ext)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RecordingArtifactStoreError.destinationAlreadyExists
        }

        let initialState: RecordingArtifactLifecycleState = captureKind == .dictation && savePolicy == .prompt
            ? .pending
            : .retained
        let expiry = captureKind == .dictation && savePolicy == .prompt
            ? (terminalAt ?? now).addingTimeInterval(retentionPolicy.dictationAskLease)
            : nil
        try insertArtifact(
            id: artifactID,
            sessionID: sessionID,
            captureKind: captureKind,
            fileExtension: ext,
            savePolicy: savePolicy,
            state: .staging,
            byteCount: byteCount,
            terminalAt: terminalAt,
            pendingExpiresAt: expiry,
            now: now
        )

        do {
            try FileManager.default.moveItem(at: sourceURL, to: destination)
            // Revalidate the moved inode before changing permissions. If the source
            // was replaced between the initial lstat and rename, chmod must never
            // follow a substituted symlink outside the app-owned root.
            try validateRegularSingleLinkFile(destination, confinedTo: recordingsRootURL)
            guard chmod(destination.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try validateRegularSingleLinkFile(destination, confinedTo: recordingsRootURL)
            try updateArtifactState(id: artifactID, state: initialState, now: now)
            return try artifact(id: artifactID)
        } catch {
            try? updateArtifactState(id: artifactID, state: .deleting, now: now)
            try? deleteFileAndMetadataIfPossible(id: artifactID)
            throw error
        }
    }

    /// Migrates an eligible legacy meeting recording by rename; it never copies audio.
    @discardableResult
    public func migrateLegacyMeetingRecording(
        meetingID: Int64,
        legacyURL: URL,
        artifactID: RecordingArtifactID = RecordingArtifactID(),
        sessionID: UUID,
        savePolicy: RecordingSavePolicySnapshot,
        now: Date = Date()
    ) throws -> RecordingArtifact {
        if let existing = try artifactForSession(id: sessionID) {
            try attachMigratedMeeting(
                meetingID: meetingID, artifactID: existing.id, now: now
            )
            return existing
        }
        try validateRegularSingleLinkFile(legacyURL, confinedTo: legacyMeetingRootURL)
        let artifact = try adoptCapture(
            at: legacyURL,
            artifactID: artifactID,
            sessionID: sessionID,
            captureKind: .meeting,
            savePolicy: savePolicy,
            now: now
        )
        try attachMigratedMeeting(meetingID: meetingID, artifactID: artifact.id, now: now)
        return artifact
    }

    /// Reuses an already migrated artifact for another legacy history row that
    /// referenced the same source file. No audio bytes are copied.
    public func attachExistingLegacyMeetingRecording(
        meetingID: Int64,
        artifactID: RecordingArtifactID,
        now: Date = Date()
    ) throws {
        try attachMigratedMeeting(meetingID: meetingID, artifactID: artifactID, now: now)
    }

    /// Quarantines an unsafe legacy path without ever resolving or following it.
    public func markLegacyMeetingRecordingInvalid(
        meetingID: Int64,
        now: Date = Date()
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            var linkStatement: OpaquePointer?
            let linkSQL = "INSERT INTO meeting_recording_links (meeting_id, artifact_uuid, availability, updated_at) VALUES (?, NULL, 'invalid_legacy', ?) ON CONFLICT(meeting_id) DO UPDATE SET artifact_uuid=NULL, availability='invalid_legacy', updated_at=excluded.updated_at"
            guard sqlite3_prepare_v2(db, linkSQL, -1, &linkStatement, nil) == SQLITE_OK else { throw lastError(db) }
            sqlite3_bind_int64(linkStatement, 1, meetingID)
            sqlite3_bind_double(linkStatement, 2, now.timeIntervalSince1970)
            guard sqlite3_step(linkStatement) == SQLITE_DONE else {
                sqlite3_finalize(linkStatement)
                throw lastError(db)
            }
            sqlite3_finalize(linkStatement)

            var meetingStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE meetings SET saved_recording_path=NULL WHERE id=? AND deleted_at IS NULL", -1, &meetingStatement, nil) == SQLITE_OK else { throw lastError(db) }
            sqlite3_bind_int64(meetingStatement, 1, meetingID)
            guard sqlite3_step(meetingStatement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                sqlite3_finalize(meetingStatement)
                throw DictationStoreError.meetingNotFound(id: meetingID)
            }
            sqlite3_finalize(meetingStatement)
            try execute("COMMIT", db: db)
        } catch {
            try? execute("ROLLBACK", db: db)
            throw error
        }
    }

    public func artifact(id: RecordingArtifactID) throws -> RecordingArtifact {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        SELECT session_uuid, capture_kind, file_extension, frozen_save_policy, lifecycle_state,
               byte_count, created_at, terminal_at, pending_expires_at, orphaned_at
        FROM recording_artifacts WHERE artifact_uuid = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        bind(id.storedValue, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let sessionID = UUID(uuidString: text(statement, 0)),
              let kind = RecordingCaptureKind(rawValue: text(statement, 1)),
              let policy = RecordingSavePolicySnapshot(rawValue: text(statement, 3)),
              let state = RecordingArtifactLifecycleState(rawValue: text(statement, 4))
        else { throw RecordingArtifactStoreError.artifactNotFound }
        return RecordingArtifact(
            id: id,
            sessionID: sessionID,
            captureKind: kind,
            fileExtension: text(statement, 2),
            frozenSavePolicy: policy,
            lifecycleState: state,
            byteCount: sqlite3_column_int64(statement, 5),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            terminalAt: optionalDate(statement, 7),
            pendingExpiresAt: optionalDate(statement, 8),
            orphanedAt: optionalDate(statement, 9)
        )
    }

    /// Resolves only a retained or pending safe file. No stored raw path is accepted.
    public func playableURL(id: RecordingArtifactID) throws -> URL {
        let record = try artifact(id: id)
        guard record.lifecycleState == .retained || record.lifecycleState == .pending else {
            throw RecordingArtifactStoreError.artifactUnavailable(record.lifecycleState)
        }
        let url = artifactURL(id: id, fileExtension: record.fileExtension)
        do {
            try validateRegularSingleLinkFile(url, confinedTo: recordingsRootURL)
            return url
        } catch {
            try? markUnavailable(id: id, availability: .missing, now: Date())
            throw RecordingArtifactStoreError.artifactUnavailable(.missing)
        }
    }

    public func retainPendingArtifact(id: RecordingArtifactID, now: Date = Date()) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            var statement: OpaquePointer?
            let sql = "UPDATE recording_artifacts SET lifecycle_state='retained', pending_expires_at=NULL, updated_at=? WHERE artifact_uuid=? AND lifecycle_state='pending' AND (pending_expires_at IS NULL OR pending_expires_at > ?)"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
            sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
            bind(id.storedValue, at: 2, to: statement)
            sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                sqlite3_finalize(statement)
                throw RecordingArtifactStoreError.artifactNotFound
            }
            sqlite3_finalize(statement)
            for table in ["dictation_recording_links", "meeting_recording_links", "dictation_audio_history", "recording_diagnostic_links"] {
                try execute(
                    "UPDATE \(table) SET availability='available', updated_at=\(now.timeIntervalSince1970) WHERE artifact_uuid='\(id.storedValue)'",
                    db: db
                )
            }
            try execute("COMMIT", db: db)
        } catch {
            try? execute("ROLLBACK", db: db)
            throw error
        }
    }

    public func declinePendingArtifact(id: RecordingArtifactID, now: Date = Date()) throws {
        try deleteArtifact(id: id, now: now)
    }

    /// Enforces one persisted Ask deadline without relying on process restart.
    /// The guarded transition cannot delete an artifact accepted concurrently.
    @discardableResult
    public func expirePendingArtifactIfNeeded(
        id: RecordingArtifactID,
        now: Date = Date()
    ) throws -> Bool {
        let marked = try requestPendingDeletion(
            ids: [id],
            availability: .expired,
            now: now,
            requireExpired: true
        )
        guard marked.contains(id) else { return false }
        try deleteFileAndMetadataIfPossible(id: id)
        return true
    }

    public func recordingForDictation(id: Int64) throws -> RecordingArtifactReference? {
        try recordingReference(
            table: "dictation_recording_links", ownerColumn: "dictation_id", ownerValue: String(id)
        )
    }

    public func recordingForMeeting(id: Int64) throws -> RecordingArtifactReference? {
        try recordingReference(
            table: "meeting_recording_links", ownerColumn: "meeting_id", ownerValue: String(id)
        )
    }

    public func recordingForDiagnostic(sessionID: UUID) throws -> RecordingArtifactReference? {
        try recordingReference(
            table: "recording_diagnostic_links", ownerColumn: "session_uuid",
            ownerValue: sessionID.uuidString
        )
    }

    public func recordingForAudioOnlyDictation(sessionID: UUID) throws -> RecordingArtifactReference? {
        try recordingReference(
            table: "dictation_audio_history", ownerColumn: "session_uuid",
            ownerValue: sessionID.uuidString
        )
    }

    public func artifactForSession(id sessionID: UUID) throws -> RecordingArtifact? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT artifact_uuid FROM recording_artifacts WHERE session_uuid=?", -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        bind(sessionID.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let id = RecordingArtifactID(storedValue: text(statement, 0)) else { return nil }
        return try artifact(id: id)
    }

    /// Diagnostics are references, not owners, and are deliberately excluded.
    public func isLastOwningHistoryReference(artifactID: RecordingArtifactID) throws -> Bool {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try ownerCount(id: artifactID, db: db) == 1
    }

    public func attachDictation(
        dictationID: Int64,
        artifactID: RecordingArtifactID?,
        availability: RecordingAvailability,
        now: Date = Date()
    ) throws {
        try upsertLink(
            table: "dictation_recording_links", ownerColumn: "dictation_id",
            ownerValue: dictationID, artifactID: artifactID, availability: availability, now: now
        )
    }

    public func attachMeeting(
        meetingID: Int64,
        artifactID: RecordingArtifactID?,
        availability: RecordingAvailability,
        now: Date = Date()
    ) throws {
        try upsertLink(
            table: "meeting_recording_links", ownerColumn: "meeting_id",
            ownerValue: meetingID, artifactID: artifactID, availability: availability, now: now
        )
    }

    public func attachDiagnostic(
        sessionID: UUID,
        artifactID: RecordingArtifactID?,
        availability: RecordingAvailability,
        now: Date = Date()
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        INSERT INTO recording_diagnostic_links (session_uuid, artifact_uuid, availability, updated_at)
        SELECT ?, ?, ?, ?
        WHERE EXISTS (
            SELECT 1 FROM session_traces
            WHERE session_uuid = ? AND rich_content_state != 'cleared_while_active'
        )
        ON CONFLICT(session_uuid) DO UPDATE SET
            artifact_uuid=excluded.artifact_uuid,
            availability=excluded.availability,
            updated_at=excluded.updated_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        bind(sessionID.uuidString, at: 1, to: statement)
        bindOptional(artifactID?.storedValue, at: 2, to: statement)
        bind(availability.rawValue, at: 3, to: statement)
        sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
        bind(sessionID.uuidString, at: 5, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(db) }
    }

    /// Diagnostic links never own recordings, so clearing them is metadata-only.
    public func clearDiagnosticAssociations() throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            try execute("DELETE FROM recording_diagnostic_links", db: db)
            try execute("COMMIT", db: db)
        } catch {
            try? execute("ROLLBACK", db: db)
            throw error
        }
    }

    public func insertAudioOnlyDictationHistory(
        sessionID: UUID,
        capturedAt: Date,
        durationSeconds: Double,
        terminalOutcome: DictationAudioTerminalOutcome,
        artifactID: RecordingArtifactID?,
        availability: RecordingAvailability,
        now: Date = Date()
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        INSERT INTO dictation_audio_history (
            session_uuid, captured_at, duration_seconds, terminal_outcome,
            artifact_uuid, availability, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(session_uuid) DO UPDATE SET
            captured_at = excluded.captured_at,
            duration_seconds = excluded.duration_seconds,
            terminal_outcome = excluded.terminal_outcome,
            artifact_uuid = excluded.artifact_uuid,
            availability = excluded.availability,
            updated_at = excluded.updated_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        bind(sessionID.uuidString, at: 1, to: statement)
        sqlite3_bind_double(statement, 2, capturedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, max(0, durationSeconds))
        bind(terminalOutcome.rawValue, at: 4, to: statement)
        bindOptional(artifactID?.storedValue, at: 5, to: statement)
        bind(availability.rawValue, at: 6, to: statement)
        sqlite3_bind_double(statement, 7, now.timeIntervalSince1970)
        sqlite3_bind_double(statement, 8, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(db) }
    }

    public func audioOnlyDictationHistory() throws -> [DictationAudioHistoryRecord] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        SELECT session_uuid, captured_at, duration_seconds, terminal_outcome, artifact_uuid, availability
        FROM dictation_audio_history ORDER BY captured_at DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        var values: [DictationAudioHistoryRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionID = UUID(uuidString: text(statement, 0)),
                  let outcome = DictationAudioTerminalOutcome(rawValue: text(statement, 3)),
                  let availability = RecordingAvailability(rawValue: text(statement, 5)) else { continue }
            values.append(DictationAudioHistoryRecord(
                sessionID: sessionID,
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                durationSeconds: sqlite3_column_double(statement, 2),
                terminalOutcome: outcome,
                artifactID: optionalText(statement, 4).flatMap(RecordingArtifactID.init(storedValue:)),
                availability: availability
            ))
        }
        return values
    }

    @discardableResult
    public func deleteAudioOnlyDictationHistory(
        sessionID: UUID,
        now: Date = Date()
    ) throws -> RecordingArtifactID? {
        try removeOwner(
            table: "dictation_audio_history", ownerColumn: "session_uuid",
            ownerValue: sessionID.uuidString, now: now
        )
    }

    /// Clears all owning and diagnostic associations transactionally, then removes the file.
    /// A failed removal leaves the artifact in durable `deleting` state for retry.
    public func deleteArtifact(id: RecordingArtifactID, now: Date = Date()) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            try execute(
                "UPDATE recording_artifacts SET lifecycle_state='deleting', deletion_requested_at=\(now.timeIntervalSince1970), updated_at=\(now.timeIntervalSince1970) WHERE artifact_uuid='\(id.storedValue)'",
                db: db
            )
            for table in ["dictation_recording_links", "meeting_recording_links", "dictation_audio_history", "recording_diagnostic_links"] {
                try execute(
                    "UPDATE \(table) SET artifact_uuid=NULL, availability='deleted', updated_at=\(now.timeIntervalSince1970) WHERE artifact_uuid='\(id.storedValue)'",
                    db: db
                )
            }
            try execute("COMMIT", db: db)
        } catch {
            try? execute("ROLLBACK", db: db)
            throw error
        }
        try deleteFileAndMetadataIfPossible(id: id)
    }

    /// Completes a deletion already committed by owner-aware history deletion.
    public func finishDurableDeletion(id: RecordingArtifactID) throws {
        let record = try artifact(id: id)
        guard record.lifecycleState == .deleting else {
            throw RecordingArtifactStoreError.artifactUnavailable(record.lifecycleState)
        }
        try deleteFileAndMetadataIfPossible(id: id)
    }

    /// Retries durable deletions, expires dictation Ask leases, enforces the pending cap,
    /// and removes ownerless recordings after the 24-hour grace period.
    public func recoverAndPrune(now: Date = Date()) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        for id in try artifactIDs(inState: .staging) {
            let record = try artifact(id: id)
            let url = artifactURL(id: id, fileExtension: record.fileExtension)
            if (try? validateRegularSingleLinkFile(url, confinedTo: recordingsRootURL)) != nil {
                let state: RecordingArtifactLifecycleState = record.captureKind == .dictation
                    && record.frozenSavePolicy == .prompt ? .pending : .retained
                try updateArtifactState(id: id, state: state, now: now)
            } else {
                try updateArtifactState(id: id, state: .deleting, now: now)
            }
        }
        try markExpiredPendingAsDeleting(now: now)
        try enforcePendingCap(now: now)
        try markAndDeleteOrphans(now: now)
        for id in try artifactIDs(inState: .deleting) {
            try? deleteFileAndMetadataIfPossible(id: id)
        }
    }

    /// Enforces the global Ask-recording cap after the history owner has been
    /// committed, so a newly adopted oversized recording becomes an explicit
    /// expired history entry instead of an ambiguous save failure.
    public func enforcePendingCapacity(now: Date = Date()) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        try enforcePendingCap(now: now)
    }

    /// Pending Ask leases belong to the process that can present the decision. A new
    /// process cannot restore that prompt, so startup durably discards all of them.
    public func discardPendingArtifacts(now: Date = Date()) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let ids = try dictationAskArtifactIDsForStartupDiscard()
        try requestDeletion(ids: ids, availability: .deleted, now: now)
        for id in try artifactIDs(inState: .deleting) {
            try? deleteFileAndMetadataIfPossible(id: id)
        }
    }

    private func dictationAskArtifactIDsForStartupDiscard() throws -> [RecordingArtifactID] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT artifact_uuid FROM recording_artifacts WHERE capture_kind='dictation' AND frozen_save_policy='prompt' AND lifecycle_state IN ('staging','pending')"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        var ids: [RecordingArtifactID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = RecordingArtifactID(storedValue: text(statement, 0)) { ids.append(id) }
        }
        return ids
    }

    // MARK: - File safety

    private func ensureSecureRoot() throws {
        let manager = FileManager.default
        try validateConfiguredDirectory(recordingsRootURL.deletingLastPathComponent(), allowMissing: false)
        if manager.fileExists(atPath: recordingsRootURL.path) {
            try validateConfiguredDirectory(recordingsRootURL, allowMissing: false)
        } else {
            try manager.createDirectory(at: recordingsRootURL, withIntermediateDirectories: true)
        }
        guard chmod(recordingsRootURL.path, mode_t(S_IRWXU)) == 0 else {
            throw RecordingArtifactStoreError.unsafeRecordingRoot
        }
        guard recordingsRootURL.resolvingSymlinksInPath().standardizedFileURL.path == recordingsRootURL.path else {
            throw RecordingArtifactStoreError.unsafeRecordingRoot
        }
    }

    private func validateConfiguredDirectory(_ url: URL, allowMissing: Bool) throws {
        guard url.isFileURL else { throw RecordingArtifactStoreError.unsafeRecordingRoot }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if allowMissing, errno == ENOENT { return }
            throw RecordingArtifactStoreError.unsafeRecordingRoot
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & S_IFMT) != S_IFLNK else {
            throw RecordingArtifactStoreError.unsafeRecordingRoot
        }
    }

    private func artifactURL(id: RecordingArtifactID, fileExtension: String) -> URL {
        recordingsRootURL.appendingPathComponent("\(id.storedValue).\(fileExtension)", isDirectory: false)
    }

    private func normalizedExtension(_ value: String) throws -> String {
        let ext = value.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw RecordingArtifactStoreError.unsupportedFileExtension(value)
        }
        return ext
    }

    private func validateRegularSingleLinkFile(_ url: URL, confinedTo root: URL? = nil) throws {
        let candidate = url.standardizedFileURL
        if let root {
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard root.standardizedFileURL == resolvedRoot,
                  resolvedCandidate.deletingLastPathComponent() == resolvedRoot else {
                throw RecordingArtifactStoreError.unsafeSource
            }
        }
        var info = stat()
        guard lstat(candidate.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & S_IFMT) != S_IFLNK,
              info.st_nlink == 1 else {
            throw RecordingArtifactStoreError.unsafeSource
        }
    }

    private func fileByteCount(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    // MARK: - Database state

    private func insertArtifact(
        id: RecordingArtifactID,
        sessionID: UUID,
        captureKind: RecordingCaptureKind,
        fileExtension: String,
        savePolicy: RecordingSavePolicySnapshot,
        state: RecordingArtifactLifecycleState,
        byteCount: Int64,
        terminalAt: Date?,
        pendingExpiresAt: Date?,
        now: Date
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        INSERT INTO recording_artifacts (
            artifact_uuid, session_uuid, capture_kind, file_extension, frozen_save_policy,
            lifecycle_state, byte_count, created_at, terminal_at, pending_expires_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        bind(id.storedValue, at: 1, to: statement)
        bind(sessionID.uuidString, at: 2, to: statement)
        bind(captureKind.rawValue, at: 3, to: statement)
        bind(fileExtension, at: 4, to: statement)
        bind(savePolicy.rawValue, at: 5, to: statement)
        bind(state.rawValue, at: 6, to: statement)
        sqlite3_bind_int64(statement, 7, byteCount)
        sqlite3_bind_double(statement, 8, now.timeIntervalSince1970)
        bindOptional(terminalAt?.timeIntervalSince1970, at: 9, to: statement)
        bindOptional(pendingExpiresAt?.timeIntervalSince1970, at: 10, to: statement)
        sqlite3_bind_double(statement, 11, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(db) }
    }

    private func updateArtifactState(
        id: RecordingArtifactID,
        state: RecordingArtifactLifecycleState,
        clearPendingExpiry: Bool = false,
        now: Date
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE recording_artifacts SET lifecycle_state=?, pending_expires_at=CASE WHEN ? THEN NULL ELSE pending_expires_at END, updated_at=? WHERE artifact_uuid=?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        bind(state.rawValue, at: 1, to: statement)
        sqlite3_bind_int(statement, 2, clearPendingExpiry ? 1 : 0)
        sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
        bind(id.storedValue, at: 4, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
            throw RecordingArtifactStoreError.artifactNotFound
        }
    }

    private func upsertLink(
        table: String,
        ownerColumn: String,
        ownerValue: Int64,
        artifactID: RecordingArtifactID?,
        availability: RecordingAvailability,
        now: Date
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO \(table) (\(ownerColumn), artifact_uuid, availability, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(\(ownerColumn)) DO UPDATE SET artifact_uuid=excluded.artifact_uuid, availability=excluded.availability, updated_at=excluded.updated_at"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, ownerValue)
        bindOptional(artifactID?.storedValue, at: 2, to: statement)
        bind(availability.rawValue, at: 3, to: statement)
        sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(db) }
    }

    private func upsertTextLink(
        table: String,
        ownerColumn: String,
        ownerValue: String,
        artifactID: RecordingArtifactID?,
        availability: RecordingAvailability,
        now: Date
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO \(table) (\(ownerColumn), artifact_uuid, availability, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(\(ownerColumn)) DO UPDATE SET artifact_uuid=excluded.artifact_uuid, availability=excluded.availability, updated_at=excluded.updated_at"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        bind(ownerValue, at: 1, to: statement)
        bindOptional(artifactID?.storedValue, at: 2, to: statement)
        bind(availability.rawValue, at: 3, to: statement)
        sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(db) }
    }

    private func recordingReference(
        table: String,
        ownerColumn: String,
        ownerValue: String
    ) throws -> RecordingArtifactReference? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "SELECT artifact_uuid, availability FROM \(table) WHERE \(ownerColumn)=?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        bind(ownerValue, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let availability = RecordingAvailability(rawValue: text(statement, 1)) else { return nil }
        return RecordingArtifactReference(
            artifactID: optionalText(statement, 0).flatMap(RecordingArtifactID.init(storedValue:)),
            availability: availability
        )
    }

    private func removeOwner(
        table: String,
        ownerColumn: String,
        ownerValue: String,
        now: Date
    ) throws -> RecordingArtifactID? {
        let db = try openDatabase()
        var statement: OpaquePointer?
        let lookupSQL = "SELECT artifact_uuid FROM \(table) WHERE \(ownerColumn)=?"
        guard sqlite3_prepare_v2(db, lookupSQL, -1, &statement, nil) == SQLITE_OK else {
            let error = lastError(db); sqlite3_close(db); throw error
        }
        bind(ownerValue, at: 1, to: statement)
        let artifactID = sqlite3_step(statement) == SQLITE_ROW
            ? optionalText(statement, 0).flatMap(RecordingArtifactID.init(storedValue:))
            : nil
        sqlite3_finalize(statement)
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            var deleteStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE \(ownerColumn)=?", -1, &deleteStatement, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            bind(ownerValue, at: 1, to: deleteStatement)
            guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
                sqlite3_finalize(deleteStatement)
                throw lastError(db)
            }
            sqlite3_finalize(deleteStatement)
            if let artifactID, try ownerCount(id: artifactID, db: db) == 0 {
                try execute(
                    "UPDATE recording_artifacts SET lifecycle_state='deleting', deletion_requested_at=\(now.timeIntervalSince1970), updated_at=\(now.timeIntervalSince1970) WHERE artifact_uuid='\(artifactID.storedValue)'",
                    db: db
                )
                try execute(
                    "UPDATE recording_diagnostic_links SET artifact_uuid=NULL, availability='deleted', updated_at=\(now.timeIntervalSince1970) WHERE artifact_uuid='\(artifactID.storedValue)'",
                    db: db
                )
            }
            try execute("COMMIT", db: db)
        } catch {
            try? execute("ROLLBACK", db: db)
            sqlite3_close(db)
            throw error
        }
        sqlite3_close(db)
        let deletingID = artifactID.flatMap { id in
            (try? artifact(id: id).lifecycleState) == .deleting ? id : nil
        }
        return deletingID
    }

    private func ownerCount(id: RecordingArtifactID, db: OpaquePointer?) throws -> Int64 {
        try scalarInt64(
            """
            SELECT
                (SELECT COUNT(*) FROM dictation_recording_links WHERE artifact_uuid='\(id.storedValue)') +
                (SELECT COUNT(*) FROM meeting_recording_links WHERE artifact_uuid='\(id.storedValue)') +
                (SELECT COUNT(*) FROM dictation_audio_history WHERE artifact_uuid='\(id.storedValue)')
            """,
            db: db
        )
    }

    private func attachMigratedMeeting(
        meetingID: Int64,
        artifactID: RecordingArtifactID,
        now: Date
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            var linkStatement: OpaquePointer?
            let linkSQL = "INSERT INTO meeting_recording_links (meeting_id, artifact_uuid, availability, updated_at) VALUES (?, ?, 'available', ?) ON CONFLICT(meeting_id) DO UPDATE SET artifact_uuid=excluded.artifact_uuid, availability='available', updated_at=excluded.updated_at"
            guard sqlite3_prepare_v2(db, linkSQL, -1, &linkStatement, nil) == SQLITE_OK else { throw lastError(db) }
            sqlite3_bind_int64(linkStatement, 1, meetingID)
            bind(artifactID.storedValue, at: 2, to: linkStatement)
            sqlite3_bind_double(linkStatement, 3, now.timeIntervalSince1970)
            guard sqlite3_step(linkStatement) == SQLITE_DONE else {
                sqlite3_finalize(linkStatement)
                throw lastError(db)
            }
            sqlite3_finalize(linkStatement)

            var meetingStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE meetings SET saved_recording_path=NULL WHERE id=? AND deleted_at IS NULL", -1, &meetingStatement, nil) == SQLITE_OK else { throw lastError(db) }
            sqlite3_bind_int64(meetingStatement, 1, meetingID)
            guard sqlite3_step(meetingStatement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                sqlite3_finalize(meetingStatement)
                throw DictationStoreError.meetingNotFound(id: meetingID)
            }
            sqlite3_finalize(meetingStatement)
            try execute("COMMIT", db: db)
        } catch {
            try? execute("ROLLBACK", db: db)
            throw error
        }
    }

    private func markExpiredPendingAsDeleting(now: Date) throws {
        let db = try openDatabase()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT artifact_uuid FROM recording_artifacts WHERE lifecycle_state='pending' AND pending_expires_at IS NOT NULL AND pending_expires_at <= ?", -1, &statement, nil) == SQLITE_OK else {
            let error = lastError(db); sqlite3_close(db); throw error
        }
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
        var ids: [RecordingArtifactID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = RecordingArtifactID(storedValue: text(statement, 0)) { ids.append(id) }
        }
        sqlite3_finalize(statement)
        sqlite3_close(db)
        _ = try requestPendingDeletion(
            ids: ids,
            availability: .expired,
            now: now,
            requireExpired: true
        )
    }

    private func enforcePendingCap(now: Date) throws {
        let db = try openDatabase()
        let total = try scalarInt64("SELECT COALESCE(SUM(byte_count), 0) FROM recording_artifacts WHERE lifecycle_state='pending'", db: db)
        var excess = total - retentionPolicy.pendingByteCap
        guard excess > 0 else {
            sqlite3_close(db)
            return
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT artifact_uuid, byte_count FROM recording_artifacts WHERE lifecycle_state='pending' ORDER BY created_at, artifact_uuid", -1, &statement, nil) == SQLITE_OK else {
            let error = lastError(db)
            sqlite3_close(db)
            throw error
        }
        var ids: [RecordingArtifactID] = []
        while excess > 0, sqlite3_step(statement) == SQLITE_ROW {
            if let id = RecordingArtifactID(storedValue: text(statement, 0)) {
                ids.append(id)
                excess -= sqlite3_column_int64(statement, 1)
            }
        }
        sqlite3_finalize(statement)
        sqlite3_close(db)
        let markedIDs = try requestPendingDeletion(
            ids: ids,
            availability: .expired,
            now: now,
            requireExpired: false
        )
        for id in markedIDs {
            try? deleteFileAndMetadataIfPossible(id: id)
        }
    }

    private func markAndDeleteOrphans(now: Date) throws {
        let db = try openDatabase()
        let cutoff = now.addingTimeInterval(-retentionPolicy.orphanGrace).timeIntervalSince1970
        do {
            try execute(
                """
                UPDATE recording_artifacts AS a
                SET orphaned_at = COALESCE(orphaned_at, \(now.timeIntervalSince1970)), updated_at = \(now.timeIntervalSince1970)
                WHERE lifecycle_state = 'retained'
                  AND NOT EXISTS (SELECT 1 FROM dictation_recording_links d WHERE d.artifact_uuid = a.artifact_uuid)
                  AND NOT EXISTS (SELECT 1 FROM meeting_recording_links m WHERE m.artifact_uuid = a.artifact_uuid)
                  AND NOT EXISTS (SELECT 1 FROM dictation_audio_history h WHERE h.artifact_uuid = a.artifact_uuid);
                """,
                db: db
            )
        } catch {
            sqlite3_close(db)
            throw error
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT artifact_uuid FROM recording_artifacts WHERE lifecycle_state='retained' AND orphaned_at IS NOT NULL AND orphaned_at <= ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            let error = lastError(db)
            sqlite3_close(db)
            throw error
        }
        sqlite3_bind_double(statement, 1, cutoff)
        var expiredOrphans: [RecordingArtifactID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = RecordingArtifactID(storedValue: text(statement, 0)) {
                expiredOrphans.append(id)
            }
        }
        sqlite3_finalize(statement)
        sqlite3_close(db)
        try requestOrphanDeletion(ids: expiredOrphans, cutoff: cutoff, now: now)
    }

    @discardableResult
    private func requestPendingDeletion(
        ids: [RecordingArtifactID],
        availability: RecordingAvailability,
        now: Date,
        requireExpired: Bool
    ) throws -> [RecordingArtifactID] {
        guard !ids.isEmpty else { return [] }
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try execute("BEGIN IMMEDIATE", db: db)
        var marked: [RecordingArtifactID] = []
        do {
            for id in ids {
                let expiryPredicate = requireExpired
                    ? " AND pending_expires_at IS NOT NULL AND pending_expires_at <= \(now.timeIntervalSince1970)"
                    : ""
                try execute(
                    "UPDATE recording_artifacts SET lifecycle_state='deleting', deletion_requested_at=\(now.timeIntervalSince1970), updated_at=\(now.timeIntervalSince1970) WHERE artifact_uuid='\(id.storedValue)' AND lifecycle_state='pending'\(expiryPredicate)",
                    db: db
                )
                guard sqlite3_changes(db) == 1 else { continue }
                marked.append(id)
                for table in ["dictation_recording_links", "meeting_recording_links", "dictation_audio_history", "recording_diagnostic_links"] {
                    try execute(
                        "UPDATE \(table) SET artifact_uuid=NULL, availability='\(availability.rawValue)', updated_at=\(now.timeIntervalSince1970) WHERE artifact_uuid='\(id.storedValue)'",
                        db: db
                    )
                }
            }
            try execute("COMMIT", db: db)
            return marked
        } catch {
            try? execute("ROLLBACK", db: db)
            throw error
        }
    }

    private func requestOrphanDeletion(
        ids: [RecordingArtifactID],
        cutoff: TimeInterval,
        now: Date
    ) throws {
        guard !ids.isEmpty else { return }
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            for id in ids {
                try execute(
                    """
                    UPDATE recording_artifacts AS a
                    SET lifecycle_state='deleting', deletion_requested_at=\(now.timeIntervalSince1970), updated_at=\(now.timeIntervalSince1970)
                    WHERE artifact_uuid='\(id.storedValue)'
                      AND lifecycle_state='retained'
                      AND orphaned_at IS NOT NULL AND orphaned_at <= \(cutoff)
                      AND NOT EXISTS (SELECT 1 FROM dictation_recording_links d WHERE d.artifact_uuid = a.artifact_uuid)
                      AND NOT EXISTS (SELECT 1 FROM meeting_recording_links m WHERE m.artifact_uuid = a.artifact_uuid)
                      AND NOT EXISTS (SELECT 1 FROM dictation_audio_history h WHERE h.artifact_uuid = a.artifact_uuid)
                    """,
                    db: db
                )
                guard sqlite3_changes(db) == 1 else { continue }
                try execute(
                    "UPDATE recording_diagnostic_links SET artifact_uuid=NULL, availability='deleted', updated_at=\(now.timeIntervalSince1970) WHERE artifact_uuid='\(id.storedValue)'",
                    db: db
                )
            }
            try execute("COMMIT", db: db)
        } catch {
            try? execute("ROLLBACK", db: db)
            throw error
        }
    }

    private func requestDeletion(
        ids: [RecordingArtifactID],
        availability: RecordingAvailability,
        now: Date
    ) throws {
        guard !ids.isEmpty else { return }
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            for id in ids {
                try execute(
                    "UPDATE recording_artifacts SET lifecycle_state='deleting', deletion_requested_at=\(now.timeIntervalSince1970), updated_at=\(now.timeIntervalSince1970) WHERE artifact_uuid='\(id.storedValue)'",
                    db: db
                )
                for table in ["dictation_recording_links", "meeting_recording_links", "dictation_audio_history", "recording_diagnostic_links"] {
                    try execute(
                        "UPDATE \(table) SET artifact_uuid=NULL, availability='\(availability.rawValue)', updated_at=\(now.timeIntervalSince1970) WHERE artifact_uuid='\(id.storedValue)'",
                        db: db
                    )
                }
            }
            try execute("COMMIT", db: db)
        } catch {
            try? execute("ROLLBACK", db: db)
            throw error
        }
    }

    private func markUnavailable(
        id: RecordingArtifactID,
        availability: RecordingAvailability,
        now: Date
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            try execute(
                "UPDATE recording_artifacts SET lifecycle_state='missing', updated_at=\(now.timeIntervalSince1970) WHERE artifact_uuid='\(id.storedValue)'",
                db: db
            )
            for table in ["dictation_recording_links", "meeting_recording_links", "dictation_audio_history", "recording_diagnostic_links"] {
                try execute(
                    "UPDATE \(table) SET availability='\(availability.rawValue)', updated_at=\(now.timeIntervalSince1970) WHERE artifact_uuid='\(id.storedValue)'",
                    db: db
                )
            }
            try execute("COMMIT", db: db)
        } catch {
            try? execute("ROLLBACK", db: db)
            throw error
        }
    }

    private func artifactIDs(inState state: RecordingArtifactLifecycleState) throws -> [RecordingArtifactID] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT artifact_uuid FROM recording_artifacts WHERE lifecycle_state=?", -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        bind(state.rawValue, at: 1, to: statement)
        var result: [RecordingArtifactID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = RecordingArtifactID(storedValue: text(statement, 0)) { result.append(id) }
        }
        return result
    }

    private func deleteFileAndMetadataIfPossible(id: RecordingArtifactID) throws {
        let record = try artifact(id: id)
        let url = artifactURL(id: id, fileExtension: record.fileExtension)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            try validateRegularSingleLinkFile(url, confinedTo: recordingsRootURL)
            try FileManager.default.removeItem(at: url)
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM recording_artifacts WHERE artifact_uuid=?", -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        bind(id.storedValue, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(db) }
    }

    private func openDatabase() throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw lastError(db) }
        guard sqlite3_busy_timeout(db, 5_000) == SQLITE_OK,
              sqlite3_exec(db, "PRAGMA foreign_keys=ON", nil, nil, nil) == SQLITE_OK else {
            let error = lastError(db)
            sqlite3_close(db)
            throw error
        }
        return db
    }

    private func execute(_ sql: String, db: OpaquePointer?) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError(db) }
    }

    private func scalarInt64(_ sql: String, db: OpaquePointer?) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError(db) }
        return sqlite3_column_int64(statement, 0)
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, recordingSQLiteTransient)
    }

    private func bindOptional(_ value: String?, at index: Int32, to statement: OpaquePointer?) {
        if let value { bind(value, at: index, to: statement) } else { sqlite3_bind_null(statement, index) }
    }

    private func bindOptional(_ value: Double?, at index: Int32, to statement: OpaquePointer?) {
        if let value { sqlite3_bind_double(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return text(statement, index)
    }

    private func optionalDate(_ statement: OpaquePointer?, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func lastError(_ db: OpaquePointer?) -> NSError {
        NSError(
            domain: "MuesliRecordingDB",
            code: Int(sqlite3_errcode(db)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
    }
}
