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
}
