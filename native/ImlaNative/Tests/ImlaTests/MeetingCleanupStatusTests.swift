import Foundation
import Testing

@testable import ImlaCore
@testable import ImlaNativeApp

/// The Meetings pane's disclosure line for mixed-language repair: present exactly when
/// repair will run, and naming where the transcript goes.
@Suite("Meeting cleanup status")
struct MeetingCleanupStatusTests {

    private func bilingual() throws -> SpokenLanguageProfile {
        try SpokenLanguageProfile(selectedLanguages: [.arabic, .english])
    }

    @Test("a bilingual selection on a configured backend names the destination")
    func onNamesDestination() throws {
        var config = AppConfig()
        config.meetingSpokenLanguage = try bilingual()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.openAI.backend
        config.openAIAPIKey = "sk-test"

        let disclosure = MeetingCleanupStatus.activeDisclosure(config: config, isChatGPTAuthenticated: false)

        #expect(disclosure?.contains("OpenAI") == true)
    }

    @Test("a monolingual selection shows no disclosure because nothing is sent")
    func monolingualIsSilent() throws {
        var config = AppConfig()
        config.meetingSpokenLanguage = try SpokenLanguageProfile(selectedLanguages: [.english])
        config.meetingSummaryBackend = MeetingSummaryBackendOption.openAI.backend
        config.openAIAPIKey = "sk-test"

        #expect(MeetingCleanupStatus.activeDisclosure(config: config, isChatGPTAuthenticated: false) == nil)
    }

    @Test("an unconfigured backend shows no disclosure because nothing is sent")
    func unconfiguredIsSilent() throws {
        var config = AppConfig()
        config.meetingSpokenLanguage = try bilingual()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.chatGPT.backend

        #expect(MeetingCleanupStatus.activeDisclosure(config: config, isChatGPTAuthenticated: false) == nil)
    }

    @Test("a loopback destination is described as staying on this machine")
    func loopbackStaysLocal() throws {
        var config = AppConfig()
        config.meetingSpokenLanguage = try bilingual()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.ollama.backend
        config.ollamaURL = "http://localhost:11434"

        let disclosure = MeetingCleanupStatus.activeDisclosure(config: config, isChatGPTAuthenticated: false)

        #expect(disclosure?.contains("Nothing leaves your Mac") == true)
    }

    @Test("a LAN destination is not described as local")
    func lanIsNotLocal() throws {
        var config = AppConfig()
        config.meetingSpokenLanguage = try bilingual()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.ollama.backend
        config.ollamaURL = "http://192.168.1.50:11434"

        let disclosure = try #require(
            MeetingCleanupStatus.activeDisclosure(config: config, isChatGPTAuthenticated: false)
        )

        #expect(!disclosure.contains("Nothing leaves your Mac"))
    }
}
