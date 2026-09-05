import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Meeting cleanup prompt and eligibility")
struct MeetingCleanupPromptTests {

    // MARK: - Prompt

    @Test("the meeting prompt permits the word changes repair requires")
    func promptPermitsWordChanges() {
        // The dictation default forbids paraphrasing, rewording, and adding words.
        // Restoring `primary key` from البرايمريكية is changing the words, so that
        // prompt would correctly refuse the entire job.
        let prompt = MeetingTranscriptCleanupPrompt.systemPrompt

        #expect(prompt.contains("Change words when the recognizer misheard them"))
        #expect(prompt.lowercased().contains("do not: paraphrase") == false)
    }

    @Test("the meeting prompt forbids summarizing and translating")
    func promptForbidsSummarizing() {
        let prompt = MeetingTranscriptCleanupPrompt.systemPrompt

        #expect(prompt.contains("Summarize, shorten, or omit anything"))
        #expect(prompt.contains("Translate the text into another language"))
    }

    @Test("the meeting prompt says nothing about app context")
    func promptHasNoAppContext() {
        // Focused app, URL, and OCR text are dictation concepts. During a meeting
        // there is no such thing, and referencing it would invite invention.
        #expect(MeetingTranscriptCleanupPrompt.systemPrompt.contains("APP-CONTEXT") == false)
    }

    @Test("the meeting prompt requires every line back, markers intact")
    func promptRequiresCompleteness() {
        let prompt = MeetingTranscriptCleanupPrompt.systemPrompt

        #expect(prompt.contains("Return every line you were given, in the same order"))
        #expect(prompt.contains("never translate, renumber, reorder, merge, or drop one"))
    }

    @Test("the meeting prompt is not itself a dictation preset")
    func promptIsNotADictationPreset() {
        // Dictation can select the same *repair*, but not the meeting prompt: that
        // one carries a chunking protocol dictation has no use for.
        let presets = TranscriptCleanupPrompts.presets(custom: [])

        #expect(presets.contains { $0.prompt == MeetingTranscriptCleanupPrompt.systemPrompt } == false)
    }

    @Test("dictation can select the same mixed-language repair")
    func dictationOffersTheRepairPreset() {
        // Dictating Arabic with English technical terms mangles them exactly as a
        // meeting does, and the default preset forbids the fix.
        let presets = TranscriptCleanupPrompts.presets(custom: [])

        let repair = presets.first { $0.id == TranscriptCleanupPrompts.mixedLanguageRepairID }
        #expect(repair != nil)
        #expect(repair?.prompt.contains("Change words when the recognizer misheard them") == true)
        #expect(repair?.isCustom == false)
    }

    @Test("the dictation preset carries no chunking protocol")
    func dictationPresetHasNoMarkers() {
        // Markers exist because meetings are split across requests. Dictation sends
        // one snippet, so instructions about echoing markers would be noise at best.
        #expect(MixedLanguageRepairPrompt.dictation.contains("<<<U") == false)
        #expect(MeetingTranscriptCleanupPrompt.systemPrompt.contains("<<<U"))
    }

    @Test("both prompts share one set of repair instructions")
    func promptsShareRepairCore() {
        // One place to improve the repair, rather than two that drift.
        #expect(MeetingTranscriptCleanupPrompt.systemPrompt
            .hasPrefix(MixedLanguageRepairPrompt.core(subject: "transcripts of meetings")))
    }

    @Test("unit markers are distinct per index")
    func markersAreDistinct() {
        #expect(MeetingTranscriptCleanupPrompt.marker(for: 0) != MeetingTranscriptCleanupPrompt.marker(for: 1))
        #expect(MeetingTranscriptCleanupPrompt.marker(for: 3).contains("3"))
    }

    @Test("custom instructions sit between the repair core and the marker protocol")
    func customInstructionsSitBeforeMarkers() throws {
        let prompt = MeetingTranscriptCleanupPrompt.systemPrompt(customInstructions: "Keep Arabic names in Arabic script.")

        #expect(prompt.hasPrefix(MixedLanguageRepairPrompt.core(subject: "transcripts of meetings")))
        let block = try #require(prompt.range(of: CustomInstructions.openingTag))
        let markers = try #require(prompt.range(of: "Each line is preceded by a"))
        #expect(block.lowerBound < markers.lowerBound)
        #expect(prompt.hasSuffix("reorder, merge, or drop one."))
        #expect(prompt.contains("Keep Arabic names in Arabic script."))
    }

    @Test("empty custom instructions reproduce the static prompt byte for byte")
    func emptyCustomInstructionsKeepStaticPrompt() {
        #expect(MeetingTranscriptCleanupPrompt.systemPrompt(customInstructions: "") == MeetingTranscriptCleanupPrompt.systemPrompt)
        #expect(MeetingTranscriptCleanupPrompt.systemPrompt(customInstructions: "  \n") == MeetingTranscriptCleanupPrompt.systemPrompt)
    }

    @Test("a unit marker prefix inside the instructions never reaches the block")
    func markerPrefixIsStrippedFromInstructions() throws {
        let prompt = MeetingTranscriptCleanupPrompt.systemPrompt(customInstructions: "Never touch <<<U markers, keep names.")
        let opening = try #require(prompt.range(of: CustomInstructions.openingTag))
        let closing = try #require(prompt.range(of: CustomInstructions.closingTag))
        let body = prompt[opening.upperBound..<closing.lowerBound]

        #expect(!body.contains("<<<U"))
        #expect(body.contains("keep names."))
        #expect(prompt.hasSuffix("reorder, merge, or drop one."))
    }

    @Test("the block preamble tells the model preferences never change structure")
    func preambleForbidsStructuralChanges() {
        let prompt = MeetingTranscriptCleanupPrompt.systemPrompt(customInstructions: "Be concise.")

        #expect(prompt.contains("do not change the number of lines, the markers"))
    }

    // MARK: - Backend eligibility

    @Test("the on-device post-processors cannot serve meeting cleanup")
    func onDeviceBackendsAreIneligible() {
        // Both have no llmBackend, so TranscriptCleanupClient.clean throws for them,
        // and Qwen3's 1024-token total context fits no useful chunk of a meeting.
        #expect(MeetingTranscriptCleanupPolicy.isEligible(.local) == false)
        #expect(MeetingTranscriptCleanupPolicy.isEligible(.gemma4LiteRT) == false)
        #expect(MeetingTranscriptCleanupPolicy.ineligibilityReason(.local) != nil)
    }

    @Test("every HTTP LLM backend is eligible, local ones included")
    func httpBackendsAreEligible() {
        // Eligibility is about having an HTTP endpoint, not about where it lives.
        for option in LLMBackendOption.all {
            #expect(MeetingTranscriptCleanupPolicy.isEligible(.hosted(option)))
        }
        #expect(MeetingTranscriptCleanupPolicy.ineligibilityReason(.hosted(.ollama)) == nil)
    }

    // MARK: - Locality disclosure

    @Test("cloud backends are disclosed by name")
    func cloudBackendsNameTheThirdParty() {
        let config = AppConfig()

        #expect(MeetingTranscriptCleanupPolicy.disclosure(for: .hosted(.openAI), config: config).contains("OpenAI"))
        #expect(MeetingTranscriptCleanupPolicy.disclosure(for: .hosted(.openRouter), config: config).contains("OpenRouter"))
    }

    @Test("a local endpoint is disclosed as staying on this machine")
    func localEndpointsSayNothingLeaves() {
        // Claiming a cloud upload that does not happen would push people away from
        // the most private option they have.
        var config = AppConfig()
        config.ollamaURL = "http://localhost:11434"
        config.lmStudioURL = "http://127.0.0.1:1234"

        #expect(MeetingTranscriptCleanupPolicy.locality(for: .hosted(.ollama), config: config) == .onThisMachine)
        #expect(MeetingTranscriptCleanupPolicy.locality(for: .hosted(.lmStudio), config: config) == .onThisMachine)
        #expect(MeetingTranscriptCleanupPolicy.disclosure(for: .hosted(.ollama), config: config)
            .contains("Nothing leaves your Mac"))
    }

    @Test("an unset local backend URL falls back to its localhost default")
    func emptyURLUsesLocalhostDefault() {
        var config = AppConfig()
        config.ollamaURL = ""
        config.lmStudioURL = ""

        #expect(MeetingTranscriptCleanupPolicy.locality(for: .hosted(.ollama), config: config) == .onThisMachine)
        #expect(MeetingTranscriptCleanupPolicy.locality(for: .hosted(.lmStudio), config: config) == .onThisMachine)
    }

    @Test("a LAN address is not this machine")
    func lanAddressIsRemote() {
        // The transcript crosses the network. Telling someone it stayed on their Mac
        // would be exactly the wrong reassurance.
        var config = AppConfig()
        config.ollamaURL = "http://192.168.1.50:11434"

        #expect(
            MeetingTranscriptCleanupPolicy.locality(for: .hosted(.ollama), config: config)
                == .offThisMachine(destination: "192.168.1.50")
        )
        #expect(MeetingTranscriptCleanupPolicy.disclosure(for: .hosted(.ollama), config: config)
            .contains("Nothing leaves your Mac") == false)
    }

    @Test("a custom endpoint is judged by its configured host")
    func customEndpointFollowsItsURL() {
        var config = AppConfig()
        config.customLLMURL = "http://localhost:8080/v1/chat/completions"
        #expect(MeetingTranscriptCleanupPolicy.locality(for: .hosted(.customLLM), config: config) == .onThisMachine)

        config.customLLMURL = "https://api.example.com/v1/chat/completions"
        #expect(
            MeetingTranscriptCleanupPolicy.locality(for: .hosted(.customLLM), config: config)
                == .offThisMachine(destination: "api.example.com")
        )
    }

    @Test("an unconfigured custom endpoint claims nothing")
    func unconfiguredCustomEndpointStaysSilent() {
        var config = AppConfig()
        config.customLLMURL = ""

        #expect(MeetingTranscriptCleanupPolicy.locality(for: .hosted(.customLLM), config: config) == nil)
        #expect(MeetingTranscriptCleanupPolicy.disclosure(for: .hosted(.customLLM), config: config)
            .contains("Configure a cleanup backend"))
    }

    @Test("an ineligible backend has no locality to report")
    func ineligibleBackendHasNoLocality() {
        #expect(MeetingTranscriptCleanupPolicy.locality(for: .local, config: AppConfig()) == nil)
    }

    // MARK: - Setting

    @Test("meeting cleanup is off by default")
    func settingDefaultsOff() {
        #expect(AppConfig().enableMeetingTranscriptCleanup == false)
    }

    @Test("a config saved before this feature decodes as off, not on")
    func absentKeyDecodesOff() throws {
        let json = Data(#"{"enable_post_processor": true}"#.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: json)

        #expect(config.enableMeetingTranscriptCleanup == false)
    }

    @Test("legacy cleanup consent without a destination fingerprint fails closed")
    func legacyConsentWithoutFingerprintFailsClosed() throws {
        let json = Data(#"{"enable_meeting_transcript_cleanup": true,"post_processor_backend":"ollama"}"#.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: json)

        #expect(config.enableMeetingTranscriptCleanup == false)
        #expect(config.meetingTranscriptCleanupConsentFingerprint == nil)
    }

    @Test("the setting round-trips through encoding")
    func settingRoundTrips() throws {
        var config = AppConfig()
        config.postProcessorBackend = TranscriptCleanupBackendOption.hosted(.ollama).backend
        #expect(MeetingTranscriptCleanupPolicy.grantConsent(
            for: .hosted(.ollama),
            config: &config
        ))

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.enableMeetingTranscriptCleanup)
        #expect(MeetingTranscriptCleanupPolicy.hasCurrentConsent(
            for: .hosted(.ollama),
            config: decoded
        ))
    }

    @Test("equivalent endpoint spellings keep the same consent fingerprint")
    func consentFingerprintNormalizesDestination() {
        var first = AppConfig()
        first.ollamaURL = "HTTPS://EXAMPLE.COM:443/"
        var second = first
        second.ollamaURL = "https://example.com"

        let firstFingerprint = MeetingTranscriptCleanupPolicy.consentFingerprint(
            for: .hosted(.ollama),
            config: first
        )
        let secondFingerprint = MeetingTranscriptCleanupPolicy.consentFingerprint(
            for: .hosted(.ollama),
            config: second
        )

        #expect(firstFingerprint != nil)
        #expect(firstFingerprint == secondFingerprint)
    }
}
