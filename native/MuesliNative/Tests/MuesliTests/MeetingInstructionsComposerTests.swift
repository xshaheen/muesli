import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting instructions composer")
struct MeetingInstructionsComposerTests {

    @Test("a default config carries no custom instructions")
    func defaultConfigIsEmpty() {
        #expect(MeetingInstructionsComposer.customInstructions(for: AppConfig()) == "")
    }

    @Test("config text is normalized before use")
    func configTextIsNormalized() {
        var config = AppConfig()
        config.customInstructions = "  Be concise. \n"

        #expect(MeetingInstructionsComposer.customInstructions(for: config) == "Be concise.")
    }

    @Test("empty instructions reproduce the static cleanup prompt")
    func emptyInstructionsKeepStaticPrompt() {
        #expect(MeetingInstructionsComposer.cleanupSystemPrompt(for: AppConfig()) == MeetingTranscriptCleanupPrompt.systemPrompt)
    }

    @Test("the cleanup prompt for a config carries the block between the core and the marker protocol")
    func cleanupPromptCarriesBlock() throws {
        var config = AppConfig()
        config.customInstructions = "Keep Arabic names in Arabic script."

        let prompt = MeetingInstructionsComposer.cleanupSystemPrompt(for: config)

        #expect(prompt.hasPrefix(MixedLanguageRepairPrompt.core(subject: "transcripts of meetings")))
        let block = try #require(prompt.range(of: CustomInstructions.openingTag))
        let markers = try #require(prompt.range(of: "Each line is preceded by a"))
        #expect(block.lowerBound < markers.lowerBound)
    }
}
