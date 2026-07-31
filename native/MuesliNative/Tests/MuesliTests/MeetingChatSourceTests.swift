import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("MeetingChatSource — which transcript chat reads")
struct MeetingChatSourceTests {
    private func meeting(rawTranscript: String) -> MeetingRecord {
        MeetingRecord(
            id: 1,
            title: "Test",
            startTime: "2026-07-31T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: rawTranscript,
            formattedNotes: "",
            wordCount: 0,
            folderID: nil
        )
    }

    private func makeMeeting(rawTranscript: String, cleanedTranscript: String) -> MeetingRecord {
        MeetingRecord(
            id: 1,
            title: "Test",
            startTime: "2026-07-31T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: rawTranscript,
            formattedNotes: "",
            wordCount: 0,
            folderID: nil,
            cleanedTranscript: cleanedTranscript
        )
    }

    @Test("a completed meeting reads the finalized transcript")
    func completedReadsRawTranscript() {
        let record = meeting(rawTranscript: "[10:00:00] Speaker 1: final record")

        let transcript = MeetingChatSource.transcript(
            for: record,
            live: "ignored while not recording",
            isRecording: false
        )

        #expect(transcript == "[10:00:00] Speaker 1: final record")
        #expect(transcript.contains("ignored") == false)
    }

    @Test("a recording combines the prior transcript with the live one")
    func recordingCombinesPriorAndLive() {
        // The regression this guards: on a resumed meeting, liveMeetingTranscript holds only
        // the newly recorded portion. Reading it alone would answer from less than the Live
        // tab visibly shows, because that tab combines the same two sources.
        let record = meeting(rawTranscript: "[09:00:00] You: before the resume")

        let transcript = MeetingChatSource.transcript(
            for: record,
            live: "[10:00:00] You: after the resume",
            isRecording: true
        )

        #expect(transcript.contains("before the resume"))
        #expect(transcript.contains("after the resume"))
    }

    @Test("a fresh recording with no prior transcript reads the live transcript")
    func freshRecordingReadsLive() {
        let record = meeting(rawTranscript: "")

        let transcript = MeetingChatSource.transcript(
            for: record,
            live: "[10:00:00] You: hello",
            isRecording: true
        )

        #expect(transcript.contains("hello"))
    }

    @Test("chat's combined transcript matches what the Live tab renders")
    func matchesLiveTabCombination() {
        let prior = "[09:00:00] You: earlier"
        let live = "[10:00:00] You: now"
        let record = meeting(rawTranscript: prior)

        let chatTranscript = MeetingChatSource.transcript(for: record, live: live, isRecording: true)
        let liveTabTranscript = MeetingResumePolicy.combinedResumeTranscript(prior: prior, new: live)

        #expect(chatTranscript == liveTabTranscript)
    }

    @Test("the prompt follows the meeting state")
    func promptFollowsMeetingState() {
        #expect(MeetingChatSource.systemPrompt(isRecording: true) == MeetingChatPrompts.live)
        #expect(MeetingChatSource.systemPrompt(isRecording: false) == MeetingChatPrompts.completed)
    }

    @Test("only the completed prompt describes speaker labels")
    func onlyCompletedPromptDescribesSpeakers() {
        // The finalized transcript is diarized; the live one is not. Telling the model to
        // reason about speaker labels it cannot see would invite invention.
        let completed = MeetingChatSource.systemPrompt(isRecording: false)
        let live = MeetingChatSource.systemPrompt(isRecording: true)

        #expect(completed.contains("Speaker 1"))
        #expect(live.contains("Speaker 1") == false)
    }

    @Test("an empty finalized transcript yields an empty source rather than live content")
    func emptyCompletedTranscriptStaysEmpty() {
        let record = meeting(rawTranscript: "")

        let transcript = MeetingChatSource.transcript(for: record, live: "leftover", isRecording: false)

        #expect(transcript.isEmpty)
    }

    // MARK: - Cleaned transcript

    @Test("a completed meeting hands chat its cleaned transcript")
    func completedMeetingUsesCleanedTranscript() {
        let meeting = makeMeeting(
            rawTranscript: "[10:00:00] Speaker 1: البرايمريكية",
            cleanedTranscript: "[10:00:00] Speaker 1: primary key"
        )

        let transcript = MeetingChatSource.transcript(for: meeting, live: "", isRecording: false)

        #expect(transcript == "[10:00:00] Speaker 1: primary key")
    }

    @Test("a completed meeting without cleanup still hands chat the raw transcript")
    func completedMeetingFallsBackToRaw() {
        let meeting = makeMeeting(rawTranscript: "[10:00:00] Speaker 1: hello", cleanedTranscript: "")

        let transcript = MeetingChatSource.transcript(for: meeting, live: "", isRecording: false)

        #expect(transcript == "[10:00:00] Speaker 1: hello")
    }

    @Test("a recording meeting ignores any cleaned transcript and combines live text")
    func recordingMeetingCombinesRaw() {
        // Cleanup only runs at finalization, so a cleaned transcript on a recording
        // meeting would be stale by definition — the live session is still appending.
        let meeting = makeMeeting(
            rawTranscript: "[09:00:00] You: before the resume",
            cleanedTranscript: "[09:00:00] You: stale cleaned copy"
        )

        let transcript = MeetingChatSource.transcript(
            for: meeting,
            live: "[10:00:00] You: after the resume",
            isRecording: true
        )

        #expect(transcript.contains("before the resume"))
        #expect(transcript.contains("after the resume"))
        #expect(transcript.contains("stale cleaned copy") == false)
    }
}
