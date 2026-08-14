import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Session diagnostics presentation")
struct SessionDiagnosticsPresentationTests {
    @Test("unattached failed and cancelled sessions stay identifiable")
    func unattachedTerminalLabels() throws {
        let failed = try summary(outcome: .failed)
        let cancelled = try summary(outcome: .cancelled)

        #expect(SessionDiagnosticsPresentation.associationLabel(for: failed) == "Unattached session")
        #expect(SessionDiagnosticsPresentation.outcomeLabel(for: failed) == "Failed")
        #expect(SessionDiagnosticsPresentation.outcomeLabel(for: cancelled) == "Cancelled")
    }

    @Test("all content lifecycle states have explicit copy")
    func contentStateCopy() {
        let expected: [SessionTraceContentState: String] = [
            .available: "Available",
            .pruned: "Pruned",
            .empty: "Empty",
            .activeWriter: "Active writer",
            .unavailable: "Unavailable",
            .clearedWhileActive: "Cleared while active",
        ]

        for (state, label) in expected {
            #expect(SessionDiagnosticsPresentation.contentStateLabel(state) == label)
            #expect(!SessionDiagnosticsPresentation.contentStateDescription(state).isEmpty)
        }
    }

    @Test("history associations are described without transcript content")
    func associationLabels() throws {
        #expect(SessionDiagnosticsPresentation.associationLabel(
            for: try summary(dictationID: 41)
        ) == "Dictation #41")
        #expect(SessionDiagnosticsPresentation.associationLabel(
            for: try summary(meetingID: 72)
        ) == "Meeting #72")
    }

    @Test("identical transcript versions stay separately identified")
    func identicalTranscriptVersions() throws {
        let shared = try artifact(
            id: 7,
            kinds: [.rawASR, .cleanupResult, .finalOutput],
            content: "Hi. This is Shane."
        )

        let items = SessionDiagnosticsPresentation.artifactItems(in: [shared])

        #expect(items.map(\.kind) == [.rawASR, .cleanupResult, .finalOutput])
        #expect(items[0].relationship == nil)
        #expect(items[1].relationship == .unchangedFrom(.rawASR))
        #expect(items[2].relationship == .unchangedFrom(.cleanupResult))
        #expect(items.allSatisfy { $0.artifact.id == 7 })
    }

    @Test("dictation content is attached to its pipeline stages")
    func dictationPipelineAttachments() throws {
        let events = try [
            event(sequence: 1, vocabulary: .sessionStarted, stage: "session"),
            event(sequence: 2, vocabulary: .stageCompleted, stage: "speech_recognition"),
            event(sequence: 3, vocabulary: .stageCompleted, stage: "transcript_cleanup"),
            event(sequence: 4, vocabulary: .stageCompleted, stage: "finalization"),
            event(sequence: 5, vocabulary: .terminal, stage: "terminal"),
        ]
        let shared = try artifact(
            id: 9,
            kinds: [.rawASR, .cleanupResult, .finalOutput],
            content: "same"
        )
        let dictionary = try artifact(
            id: 10,
            kinds: [.dictionaryChanges],
            content: #"{"changed":false,"changes":[]}"#
        )

        let layout = SessionDiagnosticsPresentation.evidenceLayout(
            events: events,
            artifacts: [shared, dictionary]
        )

        #expect(layout.attachmentsBySequence[2]?.map(\.kind) == [.rawASR])
        #expect(layout.attachmentsBySequence[3]?.map(\.kind) == [.cleanupResult])
        #expect(layout.attachmentsBySequence[4]?.map(\.kind) == [.dictionaryChanges, .finalOutput])
        #expect(layout.unattachedArtifacts.isEmpty)
    }

    @Test("meeting and import output uses available pipeline stages")
    func meetingAndImportPipelineAttachments() throws {
        let meetingEvents = try [
            event(sequence: 1, vocabulary: .stageCompleted, stage: "transcribing_audio"),
            event(sequence: 2, vocabulary: .stageCompleted, stage: "meeting_finalization"),
        ]
        let importEvents = try [
            event(sequence: 1, vocabulary: .stageCompleted, stage: "transcribing_audio"),
            event(sequence: 2, vocabulary: .stageCompleted, stage: "speaker_diarization"),
            event(sequence: 3, vocabulary: .stageCompleted, stage: "meeting_persistence"),
        ]
        let artifacts = try [
            artifact(id: 1, kinds: [.rawASR], content: "raw"),
            artifact(id: 2, kinds: [.cleanupResult], content: "cleaned"),
            artifact(id: 3, kinds: [.dictionaryChanges], content: "{}"),
            artifact(id: 4, kinds: [.finalOutput], content: "final"),
        ]

        let meeting = SessionDiagnosticsPresentation.evidenceLayout(
            events: meetingEvents,
            artifacts: artifacts
        )
        #expect(meeting.attachmentsBySequence[1]?.map(\.kind)
            == [.rawASR, .cleanupResult, .dictionaryChanges, .finalOutput])
        #expect(meeting.attachmentsBySequence[2] == nil)

        let audioImport = SessionDiagnosticsPresentation.evidenceLayout(
            events: importEvents,
            artifacts: artifacts
        )
        #expect(audioImport.attachmentsBySequence[1]?.map(\.kind) == [.rawASR, .cleanupResult])
        #expect(audioImport.attachmentsBySequence[2]?.map(\.kind) == [.dictionaryChanges, .finalOutput])
    }

    @Test("language and context stay in session inputs")
    func sessionInputs() throws {
        let artifacts = try [
            artifact(id: 1, kinds: [.languageProfile], content: "{}"),
            artifact(id: 2, kinds: [.contextSources], content: "App: ChatGPT"),
            artifact(id: 3, kinds: [.rawASR], content: "hello"),
        ]

        #expect(SessionDiagnosticsPresentation.evidenceLayout(
            events: [],
            artifacts: artifacts
        ).sessionInputs.map(\.kind)
            == [.languageProfile, .contextSources])
    }

    @Test("content survives when a future stage cannot be mapped")
    func unmappedContent() throws {
        let events = try [
            event(sequence: 1, vocabulary: .sessionStarted, stage: "session"),
            event(sequence: 2, vocabulary: .stageCompleted, stage: "future_pipeline_stage"),
            event(sequence: 3, vocabulary: .terminal, stage: "terminal"),
        ]
        let raw = try artifact(id: 1, kinds: [.rawASR], content: "hello")

        let layout = SessionDiagnosticsPresentation.evidenceLayout(
            events: events,
            artifacts: [raw]
        )
        #expect(layout.attachmentsBySequence.isEmpty)
        #expect(layout.unattachedArtifacts.map(\.kind) == [.rawASR])
    }

    @Test("streaming content attaches to the started stage")
    func streamingStartPipelineAttachments() throws {
        let events = try [
            event(sequence: 1, vocabulary: .sessionStarted, stage: "session"),
            event(sequence: 2, vocabulary: .stageStarted, stage: "nemotron_streaming"),
            event(sequence: 3, vocabulary: .terminal, stage: "terminal"),
        ]
        let artifacts = try [
            artifact(id: 1, kinds: [.rawASR], content: "raw"),
            artifact(id: 2, kinds: [.cleanupResult], content: "cleaned"),
            artifact(id: 3, kinds: [.dictionaryChanges], content: "{}"),
            artifact(id: 4, kinds: [.finalOutput], content: "final"),
        ]

        let layout = SessionDiagnosticsPresentation.evidenceLayout(
            events: events,
            artifacts: artifacts
        )

        #expect(layout.attachmentsBySequence[2]?.map(\.kind)
            == [.rawASR, .cleanupResult, .dictionaryChanges, .finalOutput])
        #expect(layout.unattachedArtifacts.isEmpty)
    }

    private func summary(
        outcome: SessionTraceTerminalOutcome? = nil,
        dictationID: Int64? = nil,
        meetingID: Int64? = nil
    ) throws -> SessionTraceSummary {
        var payload: [String: Any] = [
            "sessionID": UUID().uuidString,
            "kind": "dictation",
            "createdAt": 10.0,
            "updatedAt": 20.0,
            "contentState": "empty",
            "eventCount": 0,
            "richByteCount": 0,
        ]
        payload["terminalOutcome"] = outcome?.rawValue
        payload["dictationID"] = dictationID
        payload["meetingID"] = meetingID
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(SessionTraceSummary.self, from: data)
    }

    private func event(
        sequence: Int,
        vocabulary: SessionTraceEventVocabulary,
        stage: String
    ) throws -> SessionTraceEvent {
        let payload: [String: Any] = [
            "sequence": sequence,
            "vocabulary": vocabulary.rawValue,
            "stage": stage,
            "metadata": [:],
            "createdAt": 10.0,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(SessionTraceEvent.self, from: data)
    }

    private func artifact(
        id: Int64,
        kinds: [SessionTraceArtifactKind],
        content: String
    ) throws -> SessionTraceArtifact {
        let payload: [String: Any] = [
            "id": id,
            "kinds": kinds.map(\.rawValue),
            "content": content,
            "byteCount": content.utf8.count,
            "state": SessionTraceContentState.available.rawValue,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(SessionTraceArtifact.self, from: data)
    }
}
