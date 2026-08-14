import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@MainActor
@Suite("Meeting finalization rollback")
struct MeetingFinalizationRollbackTests {
    @Test("losing the terminal race removes a new meeting and its unreferenced recording")
    func losingTerminalRemovesNewMeeting() throws {
        let fixture = try makeFixture()
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let meetingID = try fixture.store.createLiveMeeting(
            title: "Provisional Meeting",
            calendarEventID: nil,
            startTime: start
        )
        let priorRecord = try #require(try fixture.store.meeting(id: meetingID))
        let recordingURL = try makeRecording(in: fixture.supportDirectory, name: "new-terminal-loser.m4a")
        let result = makeResult(start: start, transcript: "Final transcript")
        let preparedSave = PreparedMeetingRecordingSave(path: recordingURL.path, error: nil)

        let persistence = try fixture.controller.persistCompletedMeetingResult(
            result,
            existingMeetingID: meetingID,
            preparedRecordingSave: preparedSave,
            preserveRecoveryMetadata: true
        )
        #expect(try fixture.store.meeting(id: meetingID)?.status == .completed)

        #expect(fixture.controller.rollbackProvisionalCompletedMeeting(
            persistenceResult: persistence,
            originalMeetingID: meetingID,
            priorMeetingRecord: priorRecord,
            preparedRecordingSave: preparedSave
        ))

        #expect(try fixture.store.meeting(id: meetingID) == nil)
        #expect(!FileManager.default.fileExists(atPath: recordingURL.path))
    }

    @Test("losing the terminal race restores a resumed meeting and preserves recovery metadata until rollback")
    func losingTerminalRestoresResumedMeeting() throws {
        let fixture = try makeFixture()
        let start = Date(timeIntervalSince1970: 1_720_100_000)
        let oldRecordingURL = try makeRecording(in: fixture.supportDirectory, name: "prior-recording.m4a")
        let meetingID = try fixture.store.insertMeeting(
            title: "Prior Meeting",
            calendarEventID: "prior-event",
            startTime: start,
            endTime: start.addingTimeInterval(60),
            rawTranscript: "Prior transcript",
            formattedNotes: "Prior notes",
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: oldRecordingURL.path,
            selectedTemplateID: "prior-template",
            selectedTemplateName: "Prior Template",
            selectedTemplateKind: .custom,
            selectedTemplatePrompt: "Prior prompt"
        )
        _ = try fixture.store.prepareMeetingForResume(id: meetingID)
        try fixture.store.appendLiveTranscriptCheckpoints(
            meetingID: meetingID,
            entries: [LiveTranscriptCheckpointEntry(
                timestampLabel: "00:01:00",
                speaker: "You",
                startSeconds: 60,
                endSeconds: 65,
                text: "Resume checkpoint"
            )]
        )
        let priorRecord = try #require(try fixture.store.meeting(id: meetingID))

        let newRecordingURL = try makeRecording(in: fixture.supportDirectory, name: "resume-terminal-loser.m4a")
        let preparedSave = PreparedMeetingRecordingSave(path: newRecordingURL.path, error: nil)
        let persistence = try fixture.controller.persistCompletedMeetingResult(
            makeResult(start: start, transcript: "Prior transcript\n\n— Resumed —\n\nNew transcript"),
            existingMeetingID: meetingID,
            preparedRecordingSave: preparedSave,
            preserveRecoveryMetadata: true
        )

        let provisional = try #require(try fixture.store.meeting(id: meetingID))
        #expect(provisional.rawTranscript.contains("New transcript"))
        #expect(provisional.savedRecordingPath == newRecordingURL.path)
        #expect(try fixture.store.liveTranscriptCheckpointText(meetingID: meetingID) != nil)

        #expect(fixture.controller.rollbackProvisionalCompletedMeeting(
            persistenceResult: persistence,
            originalMeetingID: meetingID,
            priorMeetingRecord: priorRecord,
            preparedRecordingSave: preparedSave
        ))

        let restored = try #require(try fixture.store.meeting(id: meetingID))
        #expect(restored.title == "Prior Meeting")
        #expect(restored.calendarEventID == "prior-event")
        #expect(restored.rawTranscript == "Prior transcript")
        #expect(restored.formattedNotes == "Prior notes")
        #expect(restored.durationSeconds == 60)
        #expect(restored.status == .completed)
        #expect(restored.savedRecordingPath == oldRecordingURL.path)
        #expect(restored.selectedTemplateID == "prior-template")
        #expect(try fixture.store.liveTranscriptCheckpointText(meetingID: meetingID) == nil)
        #expect(try !fixture.store.restoreResumedMeetingIfNeeded(id: meetingID))
        #expect(FileManager.default.fileExists(atPath: oldRecordingURL.path))
        #expect(!FileManager.default.fileExists(atPath: newRecordingURL.path))
    }

    @Test("losing the terminal race preserves a manual-note draft as failed without late transcript output")
    func losingTerminalPreservesManualNoteDraft() throws {
        let fixture = try makeFixture()
        let start = Date(timeIntervalSince1970: 1_720_200_000)
        let meetingID = try fixture.store.createLiveMeeting(
            title: "Manual Note Meeting",
            calendarEventID: nil,
            startTime: start
        )
        try fixture.store.updateMeetingManualNotes(id: meetingID, manualNotes: "Keep this decision")
        let priorRecord = try #require(try fixture.store.meeting(id: meetingID))
        let recordingURL = try makeRecording(in: fixture.supportDirectory, name: "manual-note-loser.m4a")
        let preparedSave = PreparedMeetingRecordingSave(path: recordingURL.path, error: nil)
        let persistence = try fixture.controller.persistCompletedMeetingResult(
            makeResult(start: start, transcript: "Late transcript must not publish"),
            existingMeetingID: meetingID,
            preparedRecordingSave: preparedSave,
            preserveRecoveryMetadata: true
        )

        #expect(fixture.controller.rollbackProvisionalCompletedMeeting(
            persistenceResult: persistence,
            originalMeetingID: meetingID,
            priorMeetingRecord: priorRecord,
            preparedRecordingSave: preparedSave
        ))

        let failed = try #require(try fixture.store.meeting(id: meetingID))
        #expect(failed.status == .failed)
        #expect(failed.manualNotes == "Keep this decision")
        #expect(failed.rawTranscript.isEmpty)
        #expect(failed.formattedNotes.isEmpty)
        #expect(failed.savedRecordingPath == nil)
        #expect(!FileManager.default.fileExists(atPath: recordingURL.path))
    }

    @Test("winner recovery cleanup is idempotent and does not mutate completed output")
    func winnerRecoveryCleanupIsIdempotent() throws {
        let fixture = try makeFixture()
        let start = Date(timeIntervalSince1970: 1_720_300_000)
        let meetingID = try fixture.store.createLiveMeeting(
            title: "Winner",
            calendarEventID: nil,
            startTime: start
        )
        try fixture.store.appendLiveTranscriptCheckpoints(
            meetingID: meetingID,
            entries: [LiveTranscriptCheckpointEntry(
                timestampLabel: "00:00:01",
                speaker: "You",
                startSeconds: 1,
                endSeconds: 2,
                text: "Checkpoint"
            )]
        )
        let result = makeResult(start: start, transcript: "Durable winner transcript")
        _ = try fixture.controller.persistCompletedMeetingResult(
            result,
            existingMeetingID: meetingID,
            preparedRecordingSave: PreparedMeetingRecordingSave(path: nil, error: nil),
            preserveRecoveryMetadata: true
        )

        try fixture.store.finalizeCompletedMeetingRecoveryMetadata(id: meetingID)
        try fixture.store.finalizeCompletedMeetingRecoveryMetadata(id: meetingID)

        let completed = try #require(try fixture.store.meeting(id: meetingID))
        #expect(completed.status == .completed)
        #expect(completed.rawTranscript == "Durable winner transcript")
        #expect(try fixture.store.liveTranscriptCheckpointText(meetingID: meetingID) == nil)
    }

    private func makeResult(start: Date, transcript: String) -> MeetingSessionResult {
        MeetingSessionResult(
            title: "Final Meeting",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(90),
            durationSeconds: 90,
            rawTranscript: transcript,
            formattedNotes: "Final notes",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )
    }

    private func makeFixture() throws -> (
        store: DictationStore,
        controller: MuesliController,
        supportDirectory: URL
    ) {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-finalization-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let store = DictationStore(databaseURL: supportDirectory.appendingPathComponent("history.db"))
        try store.migrateIfNeeded()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: supportDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store,
            configStore: ConfigStore(supportDirectory: supportDirectory)
        )
        return (store, controller, supportDirectory)
    }

    private func makeRecording(in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("recording".utf8).write(to: url)
        return url
    }
}
