import Testing
import Foundation
import MuesliCore

@Suite("MeetingRecord.displayTranscript")
struct MeetingTranscriptAccessorTests {

    private func makeMeeting(raw: String, cleaned: String) -> MeetingRecord {
        MeetingRecord(
            id: 1,
            title: "Meeting",
            startTime: "2026-07-31T10:00:00Z",
            durationSeconds: 442,
            rawTranscript: raw,
            formattedNotes: "",
            wordCount: 0,
            folderID: nil,
            cleanedTranscript: cleaned
        )
    }

    @Test("a cleaned transcript is what readers get")
    func cleanedWins() {
        let meeting = makeMeeting(
            raw: "[10:00:00] Speaker 1: البرايمريكية",
            cleaned: "[10:00:00] Speaker 1: primary key"
        )

        #expect(meeting.displayTranscript == "[10:00:00] Speaker 1: primary key")
    }

    @Test("without a cleaned transcript, readers get the raw one")
    func fallsBackToRaw() {
        // Every meeting recorded before this feature, and every meeting whose
        // cleanup failed, lands here — which is why they keep working untouched.
        let meeting = makeMeeting(raw: "[10:00:00] Speaker 1: hello", cleaned: "")

        #expect(meeting.displayTranscript == "[10:00:00] Speaker 1: hello")
    }

    @Test("a whitespace-only cleaned transcript is not a transcript")
    func whitespaceCleanedFallsBackToRaw() {
        // A model can return blank output and still report success. Serving that
        // would blank the transcript everywhere while the real one sat in the row.
        let meeting = makeMeeting(raw: "[10:00:00] Speaker 1: hello", cleaned: "   \n\t  ")

        #expect(meeting.displayTranscript == "[10:00:00] Speaker 1: hello")
    }

    @Test("a meeting with neither transcript reads empty rather than crashing")
    func bothEmpty() {
        let meeting = makeMeeting(raw: "", cleaned: "")

        #expect(meeting.displayTranscript.isEmpty)
    }

    @Test("the accessor never invents text the raw transcript does not have")
    func emptyRawWithCleanedStillPrefersCleaned() {
        // Storage forbids this state (the trigger clears cleaned when raw changes,
        // and cleanup is never attempted on an empty transcript), but the accessor
        // should be total rather than rely on that.
        let meeting = makeMeeting(raw: "", cleaned: "recovered text")

        #expect(meeting.displayTranscript == "recovered text")
    }
}
