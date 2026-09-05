import Foundation
import Testing

@testable import MuesliCore
@testable import MuesliNativeApp

/// Meeting cleanup rides the summary backend (KTD3, R9).
@Suite("Meeting cleanup transport")
struct MeetingCleanupTransportTests {

    private func config(summaryBackend: String) -> AppConfig {
        var config = AppConfig()
        config.meetingSummaryBackend = summaryBackend
        return config
    }

    @Test("every summary backend resolves to a cleanup backend that can serve it")
    func everySummaryBackendIsEligible() {
        for option in MeetingSummaryBackendOption.all {
            let resolved = MeetingCleanupTransport.backend(for: config(summaryBackend: option.backend))
            #expect(resolved.llmBackend != nil, "\(option.backend) should be cleanup-eligible")
            #expect(MeetingTranscriptCleanupPolicy.isEligible(resolved))
        }
    }

    @Test("an empty stored summary backend resolves to the default, not the on-device option")
    func emptyBackendFallsBackToDefault() {
        let resolved = MeetingCleanupTransport.backend(for: config(summaryBackend: ""))
        // The regression this guards: routing "" straight through the cleanup
        // resolver yields .local, which is ineligible, so cleanup would silently
        // never run for a default-config user.
        #expect(resolved != .local)
        #expect(resolved.llmBackend != nil)
        #expect(resolved.backend == MeetingSummaryBackendOption.chatGPT.backend)
    }

    @Test("an unknown stored summary backend also resolves to the default")
    func unknownBackendFallsBackToDefault() {
        let resolved = MeetingCleanupTransport.backend(for: config(summaryBackend: "not-a-backend"))
        #expect(resolved.llmBackend != nil)
    }

    @Test("the model comes from the summary side, and empty values take a default where one exists")
    func modelComesFromSummaryKeys() {
        var openAI = config(summaryBackend: MeetingSummaryBackendOption.openAI.backend)
        openAI.openAIModel = "gpt-custom"
        #expect(MeetingCleanupTransport.model(for: openAI) == "gpt-custom")
        #expect(!MeetingCleanupTransport.model(for: config(summaryBackend: MeetingSummaryBackendOption.openAI.backend)).isEmpty)

        var chatGPT = config(summaryBackend: MeetingSummaryBackendOption.chatGPT.backend)
        chatGPT.chatGPTModel = ""
        #expect(!MeetingCleanupTransport.model(for: chatGPT).isEmpty)

        var lmStudio = config(summaryBackend: MeetingSummaryBackendOption.lmStudio.backend)
        lmStudio.lmStudioModel = "local-llm"
        #expect(MeetingCleanupTransport.model(for: lmStudio) == "local-llm")

        var router = config(summaryBackend: MeetingSummaryBackendOption.openRouter.backend)
        router.openRouterModel = "some/model"
        #expect(MeetingCleanupTransport.model(for: router) == "some/model")
    }

    @Test("the post-processor model does not leak into the meeting request")
    func postProcessorModelIsNotUsed() {
        var config = config(summaryBackend: MeetingSummaryBackendOption.openAI.backend)
        config.openAIModel = "summary-model"
        config.postProcessorOpenAIModel = "dictation-model"
        #expect(MeetingCleanupTransport.model(for: config) == "summary-model")
    }

    @Test("readiness is false without a credential and true once supplied")
    func readinessFollowsCredentials() {
        var config = config(summaryBackend: MeetingSummaryBackendOption.openRouter.backend)
        config.openRouterAPIKey = ""
        let before = MeetingCleanupTransport.isConfigured(config: config, isChatGPTAuthenticated: false)
        config.openRouterAPIKey = "key"
        let after = MeetingCleanupTransport.isConfigured(config: config, isChatGPTAuthenticated: false)
        #expect(after)
        // Only assert the negative when the environment is not supplying a key.
        if ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] == nil {
            #expect(!before)
        }
    }

    @Test("ChatGPT readiness follows authentication")
    func chatGPTReadinessFollowsAuth() {
        let config = config(summaryBackend: MeetingSummaryBackendOption.chatGPT.backend)
        #expect(!MeetingCleanupTransport.isConfigured(config: config, isChatGPTAuthenticated: false))
        #expect(MeetingCleanupTransport.isConfigured(config: config, isChatGPTAuthenticated: true))
    }

    @Test("the marker protocol stays last with both instructions and neutral repair")
    func markerProtocolStaysLast() throws {
        var config = AppConfig()
        config.customInstructions = "Prefer British spelling."
        config.meetingSpokenLanguage = try SpokenLanguageProfile(selectedLanguages: [.french, .english])

        let prompt = MeetingInstructionsComposer.cleanupSystemPrompt(for: config)
        let instructions = try #require(prompt.range(of: CustomInstructions.openingTag))
        let marker = try #require(prompt.range(of: MeetingTranscriptCleanupPrompt.unitMarker))
        #expect(instructions.lowerBound < marker.lowerBound)
        #expect(!prompt.contains("البرايمريكية"))
    }

    @Test("an Arabic and English meeting keeps the worked examples")
    func arabicEnglishMeetingKeepsExamples() throws {
        var config = AppConfig()
        config.meetingSpokenLanguage = try SpokenLanguageProfile(selectedLanguages: [.arabic, .english])
        #expect(MeetingInstructionsComposer.cleanupSystemPrompt(for: config).contains("البرايمريكية"))
    }
}
