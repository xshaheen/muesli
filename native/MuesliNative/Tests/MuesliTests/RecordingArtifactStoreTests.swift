import Foundation
import SQLite3
import Testing
@testable import MuesliCore

@Suite("RecordingArtifactStore", .serialized)
struct RecordingArtifactStoreTests {
    private struct Fixture {
        let root: URL
        let database: URL
        let recordings: URL
        let legacy: URL
        let store: RecordingArtifactStore
    }

    private func makeFixture(
        retention: RecordingArtifactRetentionPolicy = .default
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-recording-tests-\(UUID().uuidString)", isDirectory: true)
        let database = root.appendingPathComponent("muesli.sqlite")
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        let legacy = root.appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try DictationStore(databaseURL: database).migrateIfNeeded()
        let store = try RecordingArtifactStore(
            databaseURL: database,
            recordingsRootURL: recordings,
            legacyMeetingRootURL: legacy,
            retentionPolicy: retention
        )
        return Fixture(root: root, database: database, recordings: recordings, legacy: legacy, store: store)
    }

    private func writeSource(in root: URL, name: String = "capture.wav", bytes: Int = 32) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0x2a, count: bytes).write(to: url, options: .withoutOverwriting)
        return url
    }

    @Test("the current schema has local-only ownership tables and valid foreign keys")
    func currentSchemaPostconditions() throws {
        let fixture = try makeFixture()
        #expect(try scalar(fixture.database, "PRAGMA user_version") == Int(DictationStore.currentSchemaVersion))
        #expect(try scalar(
            fixture.database,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('recording_artifacts','dictation_recording_links','meeting_recording_links','dictation_audio_history','recording_diagnostic_links')"
        ) == 5)
        #expect(try scalar(fixture.database, "SELECT COUNT(*) FROM pragma_foreign_key_check") == 0)
    }

    @Test("adoption moves one UUID-named file with private permissions")
    func adoptionIsPrivateAndSingleCopy() throws {
        let fixture = try makeFixture()
        let source = try writeSource(in: fixture.root)
        let artifact = try fixture.store.adoptCapture(
            at: source,
            sessionID: UUID(),
            captureKind: .dictation,
            savePolicy: .always
        )
        let playable = try fixture.store.playableURL(id: artifact.id)

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(playable.lastPathComponent == "\(artifact.id.storedValue).wav")
        #expect(try permissions(fixture.recordings) == 0o700)
        #expect(try permissions(playable) == 0o600)
        #expect(artifact.lifecycleState == .retained)
    }

    @Test("history insertion and artifact ownership commit or roll back together")
    func historyAndOwnershipAreAtomic() throws {
        let fixture = try makeFixture()
        let historyStore = DictationStore(databaseURL: fixture.database)
        let artifact = try fixture.store.adoptCapture(
            at: try writeSource(in: fixture.root), sessionID: UUID(),
            captureKind: .dictation, savePolicy: .always
        )
        let validID = try historyStore.insertDictation(
            text: "Atomic", durationSeconds: 1, startedAt: Date(), endedAt: Date(),
            recording: RecordingArtifactReference(artifactID: artifact.id, availability: .available)
        )
        #expect(try fixture.store.recordingForDictation(id: validID)?.artifactID == artifact.id)

        #expect(throws: Error.self) {
            try historyStore.insertDictation(
                text: "Must roll back", durationSeconds: 1, startedAt: Date(), endedAt: Date(),
                recording: RecordingArtifactReference(artifactID: RecordingArtifactID(), availability: .available)
            )
        }
        #expect(try scalar(fixture.database, "SELECT COUNT(*) FROM dictations") == 1)
    }

    @Test("unsafe symlink, hard link, traversal, and unsupported legacy targets are rejected")
    func unsafeInputsAreRejected() throws {
        let fixture = try makeFixture()
        let outside = try writeSource(in: fixture.root, name: "outside.wav")
        let symlink = fixture.legacy.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        #expect(throws: RecordingArtifactStoreError.self) {
            try fixture.store.migrateLegacyMeetingRecording(
                meetingID: 1, legacyURL: symlink, sessionID: UUID(), savePolicy: .always
            )
        }

        let legacy = try writeSource(in: fixture.legacy, name: "legacy.wav")
        let hardLink = fixture.legacy.appendingPathComponent("hard.wav")
        try FileManager.default.linkItem(at: legacy, to: hardLink)
        #expect(throws: RecordingArtifactStoreError.self) {
            try fixture.store.migrateLegacyMeetingRecording(
                meetingID: 1, legacyURL: legacy, sessionID: UUID(), savePolicy: .always
            )
        }
        #expect(throws: RecordingArtifactStoreError.self) {
            try fixture.store.migrateLegacyMeetingRecording(
                meetingID: 1, legacyURL: outside, sessionID: UUID(), savePolicy: .always
            )
        }
        let unsupported = try writeSource(in: fixture.legacy, name: "legacy.txt")
        #expect(throws: RecordingArtifactStoreError.self) {
            try fixture.store.migrateLegacyMeetingRecording(
                meetingID: 1, legacyURL: unsupported, sessionID: UUID(), savePolicy: .always
            )
        }
    }

    @Test("symlinked recording roots are rejected before use")
    func symlinkedRecordingRootIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-recording-root-link-\(UUID().uuidString)", isDirectory: true)
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        let linked = root.appendingPathComponent("recordings", isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)
        let database = root.appendingPathComponent("muesli.sqlite")
        try DictationStore(databaseURL: database).migrateIfNeeded()

        #expect(throws: RecordingArtifactStoreError.self) {
            try RecordingArtifactStore(
                databaseURL: database,
                recordingsRootURL: linked,
                legacyMeetingRootURL: legacy
            )
        }
    }

    @Test("unsafe legacy meeting paths are quarantined and never retried")
    func invalidLegacyMeetingIsQuarantined() throws {
        let fixture = try makeFixture()
        let historyStore = DictationStore(databaseURL: fixture.database)
        let outside = try writeSource(in: fixture.root, name: "outside-legacy.wav")
        let meetingID = try historyStore.insertMeeting(
            title: "Unsafe legacy", calendarEventID: nil, startTime: Date(), endTime: Date(),
            rawTranscript: "", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil,
            savedRecordingPath: outside.path
        )
        #expect(throws: RecordingArtifactStoreError.self) {
            try fixture.store.migrateLegacyMeetingRecording(
                meetingID: meetingID, legacyURL: outside, sessionID: UUID(), savePolicy: .always
            )
        }

        try fixture.store.markLegacyMeetingRecordingInvalid(meetingID: meetingID)
        #expect(try fixture.store.recordingForMeeting(id: meetingID) == .init(
            artifactID: nil,
            availability: .invalidLegacy
        ))
        #expect(try historyStore.meeting(id: meetingID)?.savedRecordingPath == nil)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("dictation Ask expires after its frozen lease and leaves durable history metadata")
    func askLeaseExpires() throws {
        let fixture = try makeFixture()
        let terminal = Date(timeIntervalSince1970: 10_000)
        let sessionID = UUID()
        let artifact = try fixture.store.adoptCapture(
            at: try writeSource(in: fixture.root),
            sessionID: sessionID,
            captureKind: .dictation,
            savePolicy: .prompt,
            terminalAt: terminal,
            now: terminal
        )
        try fixture.store.insertAudioOnlyDictationHistory(
            sessionID: sessionID,
            capturedAt: terminal,
            durationSeconds: 4,
            terminalOutcome: .cancelled,
            artifactID: artifact.id,
            availability: .pending,
            now: terminal
        )
        #expect(try fixture.store.recordingForAudioOnlyDictation(sessionID: sessionID) == .init(
            artifactID: artifact.id,
            availability: .pending
        ))
        try fixture.store.recoverAndPrune(now: terminal.addingTimeInterval(15 * 60 + 1))

        #expect(throws: RecordingArtifactStoreError.self) { try fixture.store.artifact(id: artifact.id) }
        let history = try fixture.store.audioOnlyDictationHistory()
        #expect(history.count == 1)
        #expect(history[0].artifactID == nil)
        #expect(history[0].availability == .expired)
    }

    @Test("an Ask decision cannot retain an artifact after its deadline")
    func lateAskAcceptanceIsRejected() throws {
        let fixture = try makeFixture()
        let terminal = Date(timeIntervalSince1970: 20_000)
        let artifact = try fixture.store.adoptCapture(
            at: try writeSource(in: fixture.root), sessionID: UUID(),
            captureKind: .dictation, savePolicy: .prompt,
            terminalAt: terminal, now: terminal
        )

        #expect(throws: RecordingArtifactStoreError.self) {
            try fixture.store.retainPendingArtifact(
                id: artifact.id,
                now: terminal.addingTimeInterval(15 * 60 + 1)
            )
        }
        #expect(try fixture.store.expirePendingArtifactIfNeeded(
            id: artifact.id,
            now: terminal.addingTimeInterval(15 * 60 + 1)
        ))
    }

    @Test("pending cap evicts oldest capture first")
    func pendingCapIsBounded() throws {
        let fixture = try makeFixture(retention: RecordingArtifactRetentionPolicy(
            dictationAskLease: 900,
            pendingByteCap: 40,
            orphanGrace: 86_400
        ))
        let first = try fixture.store.adoptCapture(
            at: try writeSource(in: fixture.root, name: "one.wav", bytes: 24),
            sessionID: UUID(), captureKind: .dictation, savePolicy: .prompt,
            terminalAt: Date(timeIntervalSince1970: 1), now: Date(timeIntervalSince1970: 1)
        )
        let second = try fixture.store.adoptCapture(
            at: try writeSource(in: fixture.root, name: "two.wav", bytes: 24),
            sessionID: UUID(), captureKind: .dictation, savePolicy: .prompt,
            terminalAt: Date(timeIntervalSince1970: 2), now: Date(timeIntervalSince1970: 2)
        )
        try fixture.store.enforcePendingCapacity(now: Date(timeIntervalSince1970: 2))
        #expect(throws: RecordingArtifactStoreError.self) { try fixture.store.artifact(id: first.id) }
        #expect(try fixture.store.artifact(id: second.id).lifecycleState == .pending)
    }

    @Test("oversized Ask capture becomes an explicit expired history entry")
    func oversizedPendingCaptureExpiresAfterOwnership() throws {
        let fixture = try makeFixture(retention: RecordingArtifactRetentionPolicy(
            dictationAskLease: 900,
            pendingByteCap: 16,
            orphanGrace: 86_400
        ))
        let sessionID = UUID()
        let artifact = try fixture.store.adoptCapture(
            at: try writeSource(in: fixture.root, bytes: 24),
            sessionID: sessionID,
            captureKind: .dictation,
            savePolicy: .prompt,
            terminalAt: Date(timeIntervalSince1970: 3),
            now: Date(timeIntervalSince1970: 3)
        )
        try fixture.store.insertAudioOnlyDictationHistory(
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: 3),
            durationSeconds: 1,
            terminalOutcome: .cancelled,
            artifactID: artifact.id,
            availability: .pending,
            now: Date(timeIntervalSince1970: 3)
        )

        try fixture.store.enforcePendingCapacity(now: Date(timeIntervalSince1970: 3))

        let history = try #require(fixture.store.audioOnlyDictationHistory().first)
        #expect(history.artifactID == nil)
        #expect(history.availability == .expired)
        #expect(throws: RecordingArtifactStoreError.self) { try fixture.store.artifact(id: artifact.id) }
    }

    @Test("startup discards prior-process Ask artifacts and updates every lookup")
    func startupDiscardsPendingArtifacts() throws {
        let fixture = try makeFixture()
        let historyStore = DictationStore(databaseURL: fixture.database)
        let dictationID = try historyStore.insertDictation(
            text: "Pending", durationSeconds: 1, startedAt: Date(), endedAt: Date()
        )
        let artifact = try fixture.store.adoptCapture(
            at: try writeSource(in: fixture.root), sessionID: UUID(),
            captureKind: .dictation, savePolicy: .prompt, terminalAt: Date(), now: Date()
        )
        try fixture.store.attachDictation(
            dictationID: dictationID, artifactID: artifact.id, availability: .pending
        )
        try fixture.store.discardPendingArtifacts()

        let reference = try fixture.store.recordingForDictation(id: dictationID)
        #expect(reference == RecordingArtifactReference(artifactID: nil, availability: .deleted))
        #expect(throws: RecordingArtifactStoreError.self) { try fixture.store.artifact(id: artifact.id) }
    }

    @Test("dictation startup cleanup does not change meeting Ask semantics")
    func startupPreservesMeetingPromptArtifact() throws {
        let fixture = try makeFixture()
        let artifact = try fixture.store.adoptCapture(
            at: try writeSource(in: fixture.root), sessionID: UUID(),
            captureKind: .meeting, savePolicy: .prompt, terminalAt: Date(), now: Date()
        )
        try fixture.store.discardPendingArtifacts()
        #expect(try fixture.store.artifact(id: artifact.id).lifecycleState == .retained)
    }

    @Test("ownerless retained artifacts observe the full orphan grace")
    func orphanGraceIsEnforced() throws {
        let grace: TimeInterval = 86_400
        let fixture = try makeFixture(retention: RecordingArtifactRetentionPolicy(
            dictationAskLease: 900,
            pendingByteCap: 2 * 1_024 * 1_024 * 1_024,
            orphanGrace: grace
        ))
        let adoptedAt = Date(timeIntervalSince1970: 30_000)
        let artifact = try fixture.store.adoptCapture(
            at: try writeSource(in: fixture.root), sessionID: UUID(),
            captureKind: .dictation, savePolicy: .always, now: adoptedAt
        )

        let firstRecovery = adoptedAt.addingTimeInterval(60)
        try fixture.store.recoverAndPrune(now: firstRecovery)
        #expect(try fixture.store.artifact(id: artifact.id).orphanedAt == firstRecovery)
        try fixture.store.recoverAndPrune(now: firstRecovery.addingTimeInterval(grace - 1))
        #expect(try fixture.store.artifact(id: artifact.id).lifecycleState == .retained)
        try fixture.store.recoverAndPrune(now: firstRecovery.addingTimeInterval(grace + 1))
        #expect(throws: RecordingArtifactStoreError.self) { try fixture.store.artifact(id: artifact.id) }
    }

    @Test("crash-staged files recover before orphan aging begins")
    func crashStagingRecovers() throws {
        let fixture = try makeFixture()
        let artifact = try fixture.store.adoptCapture(
            at: try writeSource(in: fixture.root), sessionID: UUID(),
            captureKind: .meeting, savePolicy: .always
        )
        try rawExec(
            fixture.database,
            "UPDATE recording_artifacts SET lifecycle_state='staging', orphaned_at=NULL WHERE artifact_uuid='\(artifact.id.storedValue)'"
        )

        let recovery = Date(timeIntervalSince1970: 40_000)
        try fixture.store.recoverAndPrune(now: recovery)
        let recovered = try fixture.store.artifact(id: artifact.id)
        #expect(recovered.lifecycleState == .retained)
        #expect(recovered.orphanedAt == recovery)
    }

    @Test("soft history deletion detaches ownership and deletes only the last owner's file")
    func softDeletionHonorsLastOwner() throws {
        let fixture = try makeFixture()
        let historyStore = DictationStore(databaseURL: fixture.database)
        let sessionID = UUID()
        let artifact = try fixture.store.adoptCapture(
            at: try writeSource(in: fixture.root), sessionID: sessionID,
            captureKind: .dictation, savePolicy: .always
        )
        let dictationID = try historyStore.insertDictation(
            text: "Owned", durationSeconds: 1, startedAt: Date(), endedAt: Date(),
            recording: RecordingArtifactReference(artifactID: artifact.id, availability: .available)
        )
        try fixture.store.insertAudioOnlyDictationHistory(
            sessionID: sessionID, capturedAt: Date(), durationSeconds: 1,
            terminalOutcome: .failed, artifactID: artifact.id, availability: .available
        )

        #expect(try !fixture.store.isLastOwningHistoryReference(artifactID: artifact.id))
        #expect(try historyStore.deleteDictation(id: dictationID) == nil)
        #expect(try fixture.store.artifact(id: artifact.id).lifecycleState == .retained)
        #expect(try fixture.store.isLastOwningHistoryReference(artifactID: artifact.id))
        let deletingID = try fixture.store.deleteAudioOnlyDictationHistory(sessionID: sessionID)
        #expect(deletingID == artifact.id)
        #expect(try fixture.store.artifact(id: artifact.id).lifecycleState == .deleting)
        try fixture.store.finishDurableDeletion(id: artifact.id)
        #expect(throws: RecordingArtifactStoreError.self) { try fixture.store.artifact(id: artifact.id) }
    }

    @Test("clear Dictations returns durable deletion work without touching diagnostic text")
    func clearDictationsMarksOwnedAudioDeleting() throws {
        let fixture = try makeFixture()
        let historyStore = DictationStore(databaseURL: fixture.database)
        let artifact = try fixture.store.adoptCapture(
            at: try writeSource(in: fixture.root), sessionID: UUID(),
            captureKind: .dictation, savePolicy: .always
        )
        _ = try historyStore.insertDictation(
            text: "Clear", durationSeconds: 1, startedAt: Date(), endedAt: Date(),
            recording: RecordingArtifactReference(artifactID: artifact.id, availability: .available)
        )

        #expect(try historyStore.clearDictations() == [artifact.id])
        #expect(try fixture.store.artifact(id: artifact.id).lifecycleState == .deleting)
        try fixture.store.finishDurableDeletion(id: artifact.id)
        #expect(throws: RecordingArtifactStoreError.self) { try fixture.store.artifact(id: artifact.id) }
    }

    @Test("diagnostic association is not an owner and trace deletion does not remove owned audio")
    func diagnosticsAreNonOwning() async throws {
        let fixture = try makeFixture()
        let dictionaryStore = DictationStore(databaseURL: fixture.database)
        let dictationID = try dictionaryStore.insertDictation(
            text: "Retained", durationSeconds: 1, startedAt: Date(), endedAt: Date()
        )
        let sessionID = UUID()
        let traceStore = try SessionTraceStore(databaseURL: fixture.database)
        _ = try await traceStore.beginSession(id: sessionID, kind: .dictation)
        #expect(try await traceStore.detail(sessionID: sessionID) != nil)
        let artifact = try fixture.store.adoptCapture(
            at: try writeSource(in: fixture.root), sessionID: sessionID,
            captureKind: .dictation, savePolicy: .always
        )
        try fixture.store.attachDictation(
            dictationID: dictationID, artifactID: artifact.id, availability: .available
        )
        #expect(try fixture.store.recordingForDictation(id: dictationID)?.artifactID == artifact.id)
        try fixture.store.attachDiagnostic(
            sessionID: sessionID, artifactID: artifact.id, availability: .available
        )
        #expect(try fixture.store.recordingForDiagnostic(sessionID: sessionID)?.artifactID == artifact.id)

        // Removing diagnostics never touches the owning history link or file.
        try fixture.store.clearDiagnosticAssociations()
        _ = try await traceStore.clearDiagnostics()
        #expect(try fixture.store.recordingForDiagnostic(sessionID: sessionID) == nil)
        #expect(try fixture.store.recordingForDictation(id: dictationID)?.artifactID == artifact.id)
        #expect(FileManager.default.fileExists(atPath: try fixture.store.playableURL(id: artifact.id).path))

        // A writer finishing after Clear Diagnostics cannot recreate the association.
        try fixture.store.attachDiagnostic(
            sessionID: sessionID,
            artifactID: artifact.id,
            availability: .available
        )
        #expect(try fixture.store.recordingForDiagnostic(sessionID: sessionID) == nil)
    }

    @Test("legacy meeting migration renames without copying and clears the raw path")
    func legacyMigrationPreservesInode() throws {
        let fixture = try makeFixture()
        let dictionaryStore = DictationStore(databaseURL: fixture.database)
        let meetingID = try dictionaryStore.insertMeeting(
            title: "Legacy", calendarEventID: nil, startTime: Date(), endTime: Date(),
            rawTranscript: "", formattedNotes: "", micAudioPath: nil,
            systemAudioPath: nil, savedRecordingPath: nil
        )
        let source = try writeSource(in: fixture.legacy, name: "legacy.m4a")
        let before = try inode(source)
        let artifact = try fixture.store.migrateLegacyMeetingRecording(
            meetingID: meetingID, legacyURL: source, sessionID: UUID(), savePolicy: .always
        )
        let destination = try fixture.store.playableURL(id: artifact.id)
        #expect(try inode(destination) == before)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("legacy move retries by session after owner transaction failure")
    func legacyMigrationRetriesAfterLinkFailure() throws {
        let fixture = try makeFixture()
        let sessionID = UUID()
        let source = try writeSource(in: fixture.legacy, name: "retry.m4a")
        #expect(throws: Error.self) {
            try fixture.store.migrateLegacyMeetingRecording(
                meetingID: 999_999, legacyURL: source, sessionID: sessionID, savePolicy: .always
            )
        }
        #expect(!FileManager.default.fileExists(atPath: source.path))

        let historyStore = DictationStore(databaseURL: fixture.database)
        let meetingID = try historyStore.insertMeeting(
            title: "Retry", calendarEventID: nil, startTime: Date(), endTime: Date(),
            rawTranscript: "", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil
        )
        let recovered = try fixture.store.migrateLegacyMeetingRecording(
            meetingID: meetingID, legacyURL: source, sessionID: sessionID, savePolicy: .always
        )
        #expect(try fixture.store.recordingForMeeting(id: meetingID)?.artifactID == recovered.id)
        #expect(FileManager.default.fileExists(atPath: try fixture.store.playableURL(id: recovered.id).path))
    }


    @Test("provisional rollback restores prior ownership and deletes replacement ownership")
    func provisionalRollbackRestoresRecordingOwnership() throws {
        let fixture = try makeFixture()
        let historyStore = DictationStore(databaseURL: fixture.database)
        let start = Date(timeIntervalSince1970: 1_720_100_000)
        let priorArtifact = try fixture.store.adoptCapture(
            at: try writeSource(in: fixture.root, name: "prior.wav"), sessionID: UUID(),
            captureKind: .meeting, savePolicy: .always
        )
        let priorReference = RecordingArtifactReference(
            artifactID: priorArtifact.id,
            availability: .available
        )
        let meetingID = try historyStore.insertMeeting(
            title: "Prior", calendarEventID: nil, startTime: start,
            endTime: start.addingTimeInterval(60), rawTranscript: "Prior transcript",
            formattedNotes: "Prior notes", micAudioPath: nil, systemAudioPath: nil,
            recording: priorReference
        )
        _ = try historyStore.prepareMeetingForResume(id: meetingID)
        let priorRecord = try #require(try historyStore.meeting(id: meetingID))
        let provisionalArtifact = try fixture.store.adoptCapture(
            at: try writeSource(in: fixture.root, name: "replacement.wav"), sessionID: UUID(),
            captureKind: .meeting, savePolicy: .always
        )
        try historyStore.completeLiveMeeting(
            id: meetingID, title: "Prior", calendarEventID: nil, startTime: start,
            endTime: start.addingTimeInterval(120), rawTranscript: "Prior plus resumed",
            formattedNotes: "New notes", micAudioPath: nil, systemAudioPath: nil,
            preserveRecoveryMetadata: true,
            recording: .init(artifactID: provisionalArtifact.id, availability: .available)
        )

        #expect(try historyStore.rollbackProvisionalLiveMeeting(
            id: meetingID,
            priorRecord: priorRecord,
            priorRecording: priorReference
        ))
        #expect(try fixture.store.recordingForMeeting(id: meetingID) == priorReference)
        #expect(try fixture.store.artifact(id: priorArtifact.id).lifecycleState == .retained)
        #expect(try fixture.store.artifact(id: provisionalArtifact.id).lifecycleState == .deleting)
        try fixture.store.finishDurableDeletion(id: provisionalArtifact.id)

        for manualNotes in [nil, "Keep this decision"] as [String?] {
            let draftID = try historyStore.createLiveMeeting(
                title: "Draft", calendarEventID: nil, startTime: start
            )
            if let manualNotes {
                try historyStore.updateMeetingManualNotes(id: draftID, manualNotes: manualNotes)
            }
            let draft = try #require(try historyStore.meeting(id: draftID))
            let replacement = try fixture.store.adoptCapture(
                at: try writeSource(in: fixture.root, name: "draft-\(UUID().uuidString).wav"),
                sessionID: UUID(), captureKind: .meeting, savePolicy: .always
            )
            try historyStore.completeLiveMeeting(
                id: draftID, title: "Draft", calendarEventID: nil, startTime: start,
                endTime: start.addingTimeInterval(30), rawTranscript: "Late output",
                formattedNotes: "Late notes", micAudioPath: nil, systemAudioPath: nil,
                preserveRecoveryMetadata: true,
                recording: .init(artifactID: replacement.id, availability: .available)
            )
            #expect(try !historyStore.rollbackProvisionalLiveMeeting(
                id: draftID,
                priorRecord: draft,
                priorRecording: nil
            ))
            #expect(try fixture.store.recordingForMeeting(id: draftID) == nil)
            #expect(try fixture.store.artifact(id: replacement.id).lifecycleState == .deleting)
            try fixture.store.finishDurableDeletion(id: replacement.id)
        }
    }

    private func scalar(_ database: URL, _ sql: String) throws -> Int64 {
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
        return sqlite3_column_int64(statement, 0)
    }

    private func rawExec(_ database: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func inode(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}
