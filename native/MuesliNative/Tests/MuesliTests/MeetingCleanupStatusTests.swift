import Foundation
import Testing

@testable import MuesliCore
@testable import MuesliNativeApp

/// The Meetings pane's read-only status line (R11).
@Suite("Meeting cleanup status")
struct MeetingCleanupStatusTests {

    private func bilingual() throws -> SpokenLanguageProfile {
        try SpokenLanguageProfile(selectedLanguages: [.arabic, .english])
    }

    @Test("a bilingual selection on a configured backend reads as on and names the destination")
    func onNamesDestination() throws {
        var config = AppConfig()
        config.meetingSpokenLanguage = try bilingual()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.openAI.backend
        config.openAIAPIKey = "sk-test"

        let status = MeetingCleanupStatus.describe(config: config, isChatGPTAuthenticated: false)

        #expect(status.state == "On")
        #expect(status.detail.contains("OpenAI"))
    }

    @Test("a monolingual selection reads as off and names the language selection")
    func offNamesLanguages() throws {
        var config = AppConfig()
        config.meetingSpokenLanguage = try SpokenLanguageProfile(selectedLanguages: [.english])
        config.meetingSummaryBackend = MeetingSummaryBackendOption.openAI.backend
        config.openAIAPIKey = "sk-test"

        let status = MeetingCleanupStatus.describe(config: config, isChatGPTAuthenticated: false)

        #expect(status.state == "Off")
        #expect(status.detail.lowercased().contains("meeting languages"))
    }

    @Test("an unconfigured backend reads as off and names the backend")
    func offNamesBackend() throws {
        var config = AppConfig()
        config.meetingSpokenLanguage = try bilingual()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.chatGPT.backend

        let status = MeetingCleanupStatus.describe(config: config, isChatGPTAuthenticated: false)

        #expect(status.state == "Off")
        #expect(status.detail.lowercased().contains("backend"))
    }

    @Test("a loopback destination is described as staying on this machine")
    func loopbackStaysLocal() throws {
        var config = AppConfig()
        config.meetingSpokenLanguage = try bilingual()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.ollama.backend
        config.ollamaURL = "http://localhost:11434"

        let status = MeetingCleanupStatus.describe(config: config, isChatGPTAuthenticated: false)

        #expect(status.state == "On")
        #expect(status.detail.contains("Nothing leaves your Mac"))
    }

    @Test("a LAN destination is not described as local")
    func lanIsNotLocal() throws {
        var config = AppConfig()
        config.meetingSpokenLanguage = try bilingual()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.ollama.backend
        config.ollamaURL = "http://192.168.1.50:11434"

        let status = MeetingCleanupStatus.describe(config: config, isChatGPTAuthenticated: false)

        #expect(!status.detail.contains("Nothing leaves your Mac"))
    }
}
