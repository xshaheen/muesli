import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting session title selection")
struct MeetingSessionTitleTests {
    @Test("calendar event title is used when present")
    func calendarEventTitleCandidate() {
        let title = MeetingSession.calendarTitleCandidate(
            originalTitle: "April Town Hall",
            calendarEventID: "calendar-event-123"
        )

        #expect(title == "April Town Hall")
    }

    @Test("blank calendar event title falls through")
    func blankCalendarEventTitleFallsThrough() {
        let title = MeetingSession.calendarTitleCandidate(
            originalTitle: "  \n\t  ",
            calendarEventID: "calendar-event-123"
        )

        #expect(title == nil)
    }

    @Test("non-calendar meeting does not use original title as a calendar title")
    func nonCalendarMeetingFallsThrough() {
        let title = MeetingSession.calendarTitleCandidate(
            originalTitle: "Quick Note",
            calendarEventID: nil
        )

        #expect(title == nil)
    }
}

@Suite("Meeting session recovery policy")
struct MeetingSessionRecoveryPolicyTests {
    @Test("active session final authority follows source transitions")
    func activeSessionFinalAuthorityFollowsSourceTransitions() {
        var config = AppConfig()
        config.enableLiveStreamingPartials = true
        config.meetingLiveCaptionBackend = MeetingLiveCaptionBackend.nemotron35.rawValue
        let session = MeetingSession(
            title: "Authority transition",
            calendarEventID: nil,
            backend: .whisperLargeTurbo,
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            config: config,
            templateSnapshot: MeetingTemplates.auto.snapshot,
            transcriptionCoordinator: TranscriptionCoordinator()
        )

        #expect(session.usesLiveNemotronTranscriptAsFinal())

        session.updateTranscriptionAuthority(
            backend: .whisperLargeTurbo,
            usesUnifiedNemotronTranscript: false
        )
        #expect(!session.usesLiveNemotronTranscriptAsFinal())

        session.updateTranscriptionAuthority(
            backend: .whisperLargeTurbo,
            usesUnifiedNemotronTranscript: true
        )
        #expect(session.usesLiveNemotronTranscriptAsFinal())
    }

    @Test("legacy Nemotron configuration keeps the unified final transcript")
    func legacyNemotronConfigurationKeepsUnifiedFinalTranscript() {
        var config = AppConfig()
        config.enableLiveStreamingPartials = true
        config.meetingLiveCaptionBackend = MeetingLiveCaptionBackend.nemotron35.rawValue

        #expect(config.usesUnifiedNemotronMeetingTranscript)
    }

    @Test("a selected batch model makes Nemotron preview-only")
    func selectedBatchModelMakesNemotronPreviewOnly() {
        var config = AppConfig()
        config.enableLiveStreamingPartials = true
        config.meetingLiveCaptionBackend = MeetingLiveCaptionBackend.nemotron35.rawValue
        config.useLiveMeetingTranscriptAsFinal = false

        #expect(!config.usesUnifiedNemotronMeetingTranscript)
    }

    @Test("Nemotron falls back to system audio when streaming produced no segments")
    func unifiedNemotronRecoversEmptySystemTranscript() {
        #expect(MeetingSession.shouldAttemptSystemRecovery(
            usesUnifiedNemotronTranscript: true,
            hasSystemSegments: false
        ))
    }

    @Test("Nemotron skips redundant system recovery when streaming produced segments")
    func unifiedNemotronKeepsStreamingSystemTranscript() {
        #expect(!MeetingSession.shouldAttemptSystemRecovery(
            usesUnifiedNemotronTranscript: true,
            hasSystemSegments: true
        ))
    }

    @Test("batch meeting paths retain their existing system recovery behavior")
    func batchPathStillAttemptsSystemRecovery() {
        #expect(MeetingSession.shouldAttemptSystemRecovery(
            usesUnifiedNemotronTranscript: false,
            hasSystemSegments: true
        ))
    }

    @Test("batch meeting paths recover when no system segments exist")
    func batchPathRecoversEmptySystemTranscript() {
        #expect(MeetingSession.shouldAttemptSystemRecovery(
            usesUnifiedNemotronTranscript: false,
            hasSystemSegments: false
        ))
    }
}
