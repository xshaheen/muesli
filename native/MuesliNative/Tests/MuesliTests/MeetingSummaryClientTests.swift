import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("MeetingSummaryClient")
struct MeetingSummaryClientTests {
    private let customTemplate = MeetingTemplateSnapshot(
        id: "custom-follow-up",
        name: "Customer Follow-Up",
        kind: .custom,
        prompt: """
        Use this structure exactly:

        ## Follow-Up Summary
        - Main takeaways

        ## Risks
        - Any risks
        """
    )

    @Test("summarize returns raw transcript fallback when no API key")
    func fallbackWithoutKey() async throws {
        var config = AppConfig()
        config.openAIAPIKey = ""
        config.meetingSummaryBackend = "openai"

        let result = try await MeetingSummaryClient.summarize(
            transcript: "Hello world",
            meetingTitle: "Test",
            config: config
        )

        #expect(result.contains("## Raw Transcript"))
        #expect(result.contains("Hello world"))
    }

    @Test("summary instructions include built-in template structure")
    func promptIncludesBuiltInTemplate() {
        let instructions = MeetingSummaryClient.summaryInstructions(
            for: MeetingTemplates.auto.snapshot,
            transcript: ""
        )

        #expect(instructions.contains("You are a meeting notes assistant"))
        #expect(instructions.contains("## Meeting Summary"))
        #expect(instructions.contains("## Action Items"))
    }

    @Test("summary instructions include custom template prompt verbatim")
    func promptIncludesCustomTemplate() {
        let instructions = MeetingSummaryClient.summaryInstructions(
            for: customTemplate,
            transcript: ""
        )

        #expect(instructions.contains("## Follow-Up Summary"))
        #expect(instructions.contains("## Risks"))
        #expect(instructions.contains("Do not invent facts"))
    }

    @Test("predominantly Arabic transcripts require Arabic meeting notes")
    func arabicTranscriptRequiresArabicSummary() {
        let instructions = MeetingSummaryClient.summaryInstructions(
            for: MeetingTemplates.auto.snapshot,
            transcript: "ناقشنا خطة إطلاق المنتج ومهام الفريق القادمة مع API الجديد"
        )

        #expect(instructions.contains("predominantly Arabic"))
        #expect(instructions.contains("Write the entire output in Arabic"))
        #expect(instructions.contains("Translate template section headings"))
    }

    @Test("predominantly Arabic transcripts require Arabic meeting titles")
    func arabicTranscriptRequiresArabicTitle() {
        let instructions = MeetingSummaryClient.titleInstructions(
            transcript: "راجعنا نتائج الربع وخطة تحسين تجربة المستخدم",
            manualNotes: nil
        )

        #expect(instructions.contains("predominantly Arabic"))
        #expect(instructions.contains("Return the title in Arabic"))
    }

    @Test("English transcript speaker labels do not override Arabic speech")
    func speakerLabelsDoNotOverrideArabicSpeech() {
        let transcript = "[10:00:00] Speaker 1: نعم"

        #expect(MeetingOutputLanguage.detect(transcript: transcript) == .arabic)
        #expect(MeetingSummaryClient.titleInstructions(
            transcript: transcript,
            manualNotes: nil
        ).contains("Return the title in Arabic"))
    }

    @Test("Arabic technical meetings tolerate conventional English terms")
    func arabicTechnicalMeetingsTolerateEnglishTerms() {
        let transcript = "ناقشنا API Kubernetes staging وخطة الإطلاق والمهام القادمة"

        #expect(MeetingOutputLanguage.detect(transcript: transcript) == .arabic)
    }

    @Test("Persian text is not classified as Arabic")
    func persianTextIsNotClassifiedAsArabic() {
        let transcript = "من گفتم که این طرح خوب است و فردا شروع می‌کنیم"

        #expect(MeetingOutputLanguage.detect(transcript: transcript) == .unspecified)
    }

    @Test("English transcripts keep the default output-language behavior")
    func englishTranscriptKeepsDefaultOutputLanguage() {
        let summaryInstructions = MeetingSummaryClient.summaryInstructions(
            for: MeetingTemplates.auto.snapshot,
            transcript: "We reviewed the launch plan and assigned the next actions."
        )
        let titleInstructions = MeetingSummaryClient.titleInstructions(
            transcript: "We reviewed the launch plan and assigned the next actions.",
            manualNotes: nil
        )

        #expect(!summaryInstructions.contains("Write the entire output in Arabic"))
        #expect(!titleInstructions.contains("Return the title in Arabic"))
    }

    @Test("dominant Arabic policy overrides English transcript detection")
    func dominantArabicPolicyControlsMeetingOutput() throws {
        let profile = try LanguageProfile(
            selectedLanguages: [.english, .arabic],
            dominantLanguage: .arabic,
            meetingOutputPolicy: .dominantLanguage
        )
        let transcript = "We reviewed the API rollout and assigned next steps."
        let summaryInstructions = MeetingSummaryClient.summaryInstructions(
            for: MeetingTemplates.auto.snapshot,
            transcript: transcript,
            languageProfile: profile
        )
        let titleInstructions = MeetingSummaryClient.titleInstructions(
            transcript: transcript,
            manualNotes: nil,
            languageProfile: profile
        )
        let fallback = MeetingSummaryClient.summaryFailureNotes(
            transcript: transcript,
            meetingTitle: "API rollout",
            error: MeetingSummaryError.emptyResponse(backend: "Test"),
            languageProfile: profile
        )

        #expect(summaryInstructions.contains("Write the entire output in Arabic"))
        #expect(titleInstructions.contains("Return the title in Arabic"))
        #expect(fallback.contains("## تعذر إنشاء الملخص"))
        #expect(fallback.contains("## النص الخام"))
    }

    @Test("dominant English policy overrides Arabic transcript detection")
    func dominantEnglishPolicyControlsMeetingOutput() throws {
        let profile = try LanguageProfile(
            selectedLanguages: [.english, .arabic],
            dominantLanguage: .english,
            meetingOutputPolicy: .dominantLanguage
        )
        let transcript = "ناقشنا خطة إطلاق المنتج ومهام الفريق القادمة"

        #expect(!MeetingSummaryClient.summaryInstructions(
            for: MeetingTemplates.auto.snapshot,
            transcript: transcript,
            languageProfile: profile
        ).contains("Write the entire output in Arabic"))
        #expect(!MeetingSummaryClient.titleInstructions(
            transcript: transcript,
            manualNotes: nil,
            languageProfile: profile
        ).contains("Return the title in Arabic"))
    }

    @Test("summary instructions mention preserving current notes when provided")
    func promptMentionsPreservingCurrentNotes() {
        let instructions = MeetingSummaryClient.summaryInstructions(
            for: customTemplate,
            transcript: "",
            existingNotes: "## Notes\n- Generated follow-up detail",
            manualNotes: "- User added follow-up detail"
        )

        #expect(instructions.contains("Protected written notes"))
        #expect(instructions.contains("Place each written note near the most relevant section"))
        #expect(instructions.contains("Do not rewrite, polish, summarize away, or omit"))
    }

    @Test("summary user prompt includes existing notes context when provided")
    func userPromptIncludesExistingNotes() {
        let prompt = MeetingSummaryClient.summaryUserPrompt(
            transcript: "Transcript body",
            meetingTitle: "Customer Call",
            existingNotes: "## Notes\n- User added detail"
        )

        #expect(prompt.contains("Current generated notes to preserve and reformat:"))
        #expect(prompt.contains("User added detail"))
        #expect(prompt.contains("Raw transcript:\nTranscript body"))
    }

    @Test("summary user prompt includes protected written notes separately")
    func userPromptIncludesProtectedWrittenNotes() {
        let prompt = MeetingSummaryClient.summaryUserPrompt(
            transcript: "Transcript body",
            meetingTitle: "Customer Call",
            existingNotes: "## Notes\n- Generated detail",
            manualNotes: "- User typed decision"
        )

        #expect(prompt.contains("Current generated notes to preserve and reformat:"))
        #expect(prompt.contains("First-class meeting context from written notes typed by the user during the meeting"))
        #expect(prompt.contains("identify the meeting's topic, decisions, action items, risks, and outcomes"))
        #expect(prompt.contains("- User typed decision"))
    }

    @Test("title prompt includes written notes as meeting context")
    func titlePromptIncludesWrittenNotes() {
        let prompt = MeetingSummaryClient.titlePrompt(
            transcript: "Transcript body",
            manualNotes: "Decision: launch the new workflow"
        )

        #expect(prompt.contains("Meeting transcript excerpts:"))
        #expect(prompt.contains("Transcript body"))
        #expect(prompt.contains("Written notes captured by the user during the meeting"))
        #expect(prompt.contains("Decision: launch the new workflow"))
    }

    @Test("title prompt bounds oversized written notes")
    func titlePromptBoundsOversizedWrittenNotes() {
        let prompt = MeetingSummaryClient.titlePrompt(
            transcript: "Transcript body",
            manualNotes: String(repeating: "Decision: launch the new workflow\n", count: 1_000)
        )

        #expect(prompt.contains("Transcript body"))
        #expect(prompt.count <= 6_000)
    }

    @Test("ChatGPT WHAM requests fix GPT-5.6 reasoning to High")
    func chatGPTWHAMRequestUsesHighReasoningForGPT56() {
        for model in ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] {
            let body = ChatGPTResponsesClient.requestBody(
                systemPrompt: "System",
                userPrompt: "User",
                model: model
            )
            let reasoning = body["reasoning"] as? [String: String]

            #expect(reasoning?["effort"] == "high")
        }
    }

    @Test("ChatGPT WHAM requests preserve GPT-5.4 Mini reasoning behavior")
    func chatGPTWHAMRequestPreservesGPT54MiniReasoning() {
        let body = ChatGPTResponsesClient.requestBody(
            systemPrompt: "System",
            userPrompt: "User",
            model: "gpt-5.4-mini"
        )

        #expect(body["reasoning"] == nil)
    }

    @Test("ChatGPT WHAM parser reads top-level output text")
    func chatGPTWHAMParserReadsTopLevelOutputText() {
        let payload: [String: Any] = [
            "output_text": "Cleaned dictation text",
        ]

        #expect(ChatGPTResponsesClient.extractOutputText(from: payload) == "Cleaned dictation text")
    }

    @Test("ChatGPT WHAM parser reads streaming deltas")
    func chatGPTWHAMParserReadsStreamingDeltas() {
        let payload: [String: Any] = [
            "type": "response.output_text.delta",
            "delta": "streamed text",
        ]

        #expect(ChatGPTResponsesClient.extractOutputTextDelta(from: payload) == "streamed text")
    }

    @Test("ChatGPT WHAM parser rejects malformed stream payloads")
    func chatGPTWHAMParserRejectsMalformedStreamPayloads() {
        #expect(throws: ChatGPTResponsesError.self) {
            _ = try ChatGPTResponsesClient.decodeStreamPayload("{", httpStatus: 200)
        }
    }

    @Test("ChatGPT WHAM parser ignores heartbeat stream payloads")
    func chatGPTWHAMParserIgnoresHeartbeatPayloads() throws {
        #expect(try ChatGPTResponsesClient.decodeStreamPayload("ping", httpStatus: 200) == nil)
    }

    @Test("ChatGPT WHAM parser ignores blank stream payloads")
    func chatGPTWHAMParserIgnoresBlankStreamPayloads() throws {
        #expect(try ChatGPTResponsesClient.decodeStreamPayload("   ", httpStatus: 200) == nil)
    }

    @Test("ChatGPT WHAM parser ignores valid unknown stream events")
    func chatGPTWHAMParserIgnoresValidUnknownStreamEvents() throws {
        var deltaText = "partial"
        var finalText = ""
        let decoded = try ChatGPTResponsesClient.decodeStreamPayload(
            #"{"type":"response.created","response":{"id":"resp_1"}}"#,
            httpStatus: 200
        )
        let payload = try #require(decoded)

        ChatGPTResponsesClient.applyStreamPayload(
            payload,
            deltaText: &deltaText,
            finalText: &finalText
        )

        #expect(deltaText == "partial")
        #expect(finalText.isEmpty)
    }

    @Test("ChatGPT WHAM parser prefers final output over streamed deltas")
    func chatGPTWHAMParserPrefersFinalOutputOverDeltas() {
        var deltaText = ""
        var finalText = ""

        ChatGPTResponsesClient.applyStreamPayload(
            [
                "type": "response.output_text.delta",
                "delta": "partial ",
            ],
            deltaText: &deltaText,
            finalText: &finalText
        )
        ChatGPTResponsesClient.applyStreamPayload(
            [
                "type": "response.completed",
                "response": [
                    "output_text": "final cleaned text",
                ],
            ],
            deltaText: &deltaText,
            finalText: &finalText
        )

        #expect(deltaText == "partial ")
        #expect(finalText == "final cleaned text")
        #expect(ChatGPTResponsesClient.accumulatedOutputText(deltaText: deltaText, finalText: finalText) == "final cleaned text")
    }

    @Test("ChatGPT WHAM parser reads nested final response payload")
    func chatGPTWHAMParserReadsNestedFinalResponsePayload() {
        let payload: [String: Any] = [
            "type": "response.completed",
            "response": [
                "output": [
                    [
                        "content": [
                            [
                                "type": "output_text",
                                "text": [
                                    "value": "Nested final response text",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        #expect(ChatGPTResponsesClient.extractOutputText(from: payload) == "Nested final response text")
    }

    @Test("ChatGPT WHAM parser reads output content text")
    func chatGPTWHAMParserReadsOutputContentText() {
        let payload: [String: Any] = [
            "output": [
                [
                    "content": [
                        [
                            "type": "output_text",
                            "text": "Part one ",
                        ],
                        [
                            "type": "output_text",
                            "text": "part two",
                        ],
                    ],
                ],
            ],
        ]

        #expect(ChatGPTResponsesClient.extractOutputText(from: payload) == "Part one part two")
    }

    @Test("final notes retain manual notes verbatim")
    func finalNotesRetainManualNotesVerbatim() {
        let result = MeetingSummaryClient.notesByRetainingManualNotes(
            generatedNotes: "## Summary\n- Shipped the plan",
            manualNotes: "- Decision: ship today\n- [ ] Follow up with Priy",
            outputLanguage: .unspecified
        )

        #expect(result.contains("## Summary"))
        #expect(result.contains("### Written notes"))
        #expect(result.contains("- Decision: ship today"))
        #expect(result.contains("- [ ] Follow up with Priy"))
    }

    @Test("Arabic final notes use an Arabic heading for retained written notes")
    func arabicFinalNotesUseArabicWrittenNotesHeading() {
        let result = MeetingSummaryClient.notesByRetainingManualNotes(
            generatedNotes: "## ملخص الاجتماع\n- تم اعتماد خطة الإطلاق",
            manualNotes: "- متابعة موعد الإطلاق",
            outputLanguage: .arabic
        )

        #expect(result.contains("### ملاحظات مكتوبة"))
        #expect(!result.contains("### Written notes"))
    }

    @Test("final notes do not append written notes already placed in summary")
    func finalNotesSkipAlreadyPlacedManualNotes() {
        let result = MeetingSummaryClient.notesByRetainingManualNotes(
            generatedNotes: "## Decisions\n- Decision: ship today",
            manualNotes: "- Decision: ship today",
            outputLanguage: .unspecified
        )

        #expect(result == "## Decisions\n- Decision: ship today")
    }

    @Test("final notes retain missing numbered written notes without duplicating placed ones")
    func finalNotesRetainMissingNumberedManualNotes() {
        let result = MeetingSummaryClient.notesByRetainingManualNotes(
            generatedNotes: "## Decisions\n1. First decision",
            manualNotes: "1. First decision\n2. Second decision",
            outputLanguage: .unspecified
        )

        #expect(result == "## Decisions\n1. First decision\n\n### Written notes\n\n2. Second decision")
    }

    @Test("final notes match manual notes across list marker changes")
    func finalNotesMatchManualNotesAcrossListMarkers() {
        let result = MeetingSummaryClient.notesByRetainingManualNotes(
            generatedNotes: """
            ## Decisions
            - Decision: ship today
            - Follow up with Priy
            1. First decision
            """,
            manualNotes: """
            • Decision: ship today
            - [ ] Follow up with Priy
            1) First decision
            2) Second decision
            """,
            outputLanguage: .unspecified
        )

        #expect(result == "## Decisions\n- Decision: ship today\n- Follow up with Priy\n1. First decision\n\n### Written notes\n\n2) Second decision")
    }

    @Test("short written notes are not dropped by section title substring matches")
    func shortManualNotesDoNotFalseMatchSectionTitles() {
        let result = MeetingSummaryClient.notesByRetainingManualNotes(
            generatedNotes: "## Next steps\n- Follow up with Priy",
            manualNotes: "Next steps",
            outputLanguage: .unspecified
        )

        #expect(result == "## Next steps\n- Follow up with Priy\n\n### Written notes\n\nNext steps")
    }

    @Test("fallback summary retains manual notes")
    func fallbackSummaryRetainsManualNotes() async throws {
        var config = AppConfig()
        config.openAIAPIKey = ""
        config.meetingSummaryBackend = "openai"

        let result = try await MeetingSummaryClient.summarize(
            transcript: "Hello world",
            meetingTitle: "Test",
            config: config,
            existingNotes: "- Manual decision",
            manualNotesToRetain: "- Manual decision"
        )

        #expect(result.contains("## Raw Transcript"))
        #expect(result.contains("### Written notes"))
        #expect(result.contains("- Manual decision"))
    }

    @Test("Arabic manual notes localize a letterless raw-transcript fallback")
    func arabicManualNotesLocalizeRawTranscriptFallback() async throws {
        var config = AppConfig()
        config.openAIAPIKey = ""
        config.meetingSummaryBackend = "openai"

        let result = try await MeetingSummaryClient.summarize(
            transcript: "[10:00:00] Speaker 1: 123",
            meetingTitle: "اجتماع",
            config: config,
            manualNotesToRetain: "- متابعة خطة الإطلاق"
        )

        #expect(result.contains("## النص الخام"))
        #expect(result.contains("### ملاحظات مكتوبة"))
        #expect(!result.contains("## Raw Transcript"))
    }

    @Test("summary user prompt includes meeting context when provided")
    func userPromptIncludesMeetingContext() {
        let prompt = MeetingSummaryClient.summaryUserPrompt(
            transcript: "Transcript body",
            meetingTitle: "Customer Call",
            visualContext: """
            [10:30:00] Google Chrome:
            App context:
            App: Google Chrome (example.com/customer)

            OCR visual text:
            Renewal risk
            """
        )

        #expect(prompt.contains("Meeting context captured during the meeting:"))
        #expect(prompt.contains("App context:"))
        #expect(prompt.contains("OCR visual text:"))
        #expect(prompt.contains("Raw transcript:\nTranscript body"))
    }

    @Test("summarize routes to OpenRouter when configured")
    func routesToOpenRouter() async throws {
        var config = AppConfig()
        config.openRouterAPIKey = ""
        config.meetingSummaryBackend = "openrouter"

        let result = try await MeetingSummaryClient.summarize(
            transcript: "Test transcript",
            meetingTitle: "My Meeting",
            config: config
        )

        // No key → falls back to raw transcript
        #expect(result.contains("## Raw Transcript"))
    }

    @Test("summary failure notes make backend failure visible")
    func summaryFailureNotesAreExplicit() {
        let error = MeetingSummaryError.backendFailed(
            backend: "OpenRouter",
            statusCode: 400,
            message: "No endpoints found for model retired/example"
        )

        let result = MeetingSummaryClient.summaryFailureNotes(
            transcript: "Raw words",
            meetingTitle: "Customer Review",
            error: error,
            manualNotes: "- User typed this during the meeting"
        )

        #expect(result.contains("## Summary failed"))
        #expect(result.contains("OpenRouter could not generate meeting notes."))
        #expect(result.contains("Status 400"))
        #expect(result.contains("selected model may be unavailable or retired"))
        #expect(result.contains("### Written notes"))
        #expect(result.contains("- User typed this during the meeting"))
        #expect(result.contains("## Raw Transcript"))
        #expect(result.contains("Raw words"))
    }

    @Test("Arabic summary failure notes localize fallback headings")
    func arabicSummaryFailureNotesUseArabicHeadings() {
        let error = MeetingSummaryError.emptyResponse(backend: "OpenRouter")

        let result = MeetingSummaryClient.summaryFailureNotes(
            transcript: "[10:00:00] Speaker 1: نعم سنبدأ غداً",
            meetingTitle: "خطة الإطلاق",
            error: error,
            manualNotes: "- متابعة موعد الإطلاق"
        )

        #expect(result.contains("## تعذر إنشاء الملخص"))
        #expect(result.contains("الاجتماع: خطة الإطلاق"))
        #expect(result.contains("### ملاحظات مكتوبة"))
        #expect(result.contains("## النص الخام"))
        #expect(!result.contains("## Raw Transcript"))
    }

    @Test("summary backend errors describe retired or unavailable models")
    func summaryBackendErrorDescriptionMentionsModelAvailability() {
        let error = MeetingSummaryError.emptyResponse(backend: "OpenRouter")

        #expect(error.localizedDescription.contains("OpenRouter returned an empty response"))
        #expect(error.localizedDescription.contains("unavailable or incompatible"))
    }

    @Test("summary retries transient failures until success")
    func summaryRetriesTransientFailuresUntilSuccess() async throws {
        var attempts = 0

        let result = try await MeetingSummaryClient.withSummaryRetries(
            maxRetries: 3,
            sleep: { _ in }
        ) {
            attempts += 1
            if attempts < 3 {
                throw MeetingSummaryError.requestFailed(
                    backend: "OpenAI",
                    underlying: URLError(.cannotConnectToHost)
                )
            }
            return "Recovered summary"
        }

        #expect(result == "Recovered summary")
        #expect(attempts == 3)
    }

    @Test("summary retries stop after configured retry count")
    func summaryRetriesStopAfterConfiguredRetryCount() async {
        var attempts = 0

        do {
            _ = try await MeetingSummaryClient.withSummaryRetries(
                maxRetries: 2,
                sleep: { _ in }
            ) {
                attempts += 1
                throw MeetingSummaryError.emptyResponse(backend: "OpenRouter")
            }
            #expect(Bool(false), "Expected summary retries to exhaust and throw")
        } catch {
            #expect(attempts == 3)
            guard case .emptyResponse(let backend) = error as? MeetingSummaryError else {
                #expect(Bool(false), "Expected emptyResponse, got \(String(describing: error))")
                return
            }
            #expect(backend == "OpenRouter")
        }
    }

    @Test("summary retries cap local transient failures")
    func summaryRetriesCapLocalTransientFailures() async {
        var attempts = 0

        do {
            _ = try await MeetingSummaryClient.withSummaryRetries(
                maxRetries: 5,
                sleep: { _ in }
            ) {
                attempts += 1
                throw MeetingSummaryError.emptyResponse(backend: "Ollama")
            }
            #expect(Bool(false), "Expected local summary retries to exhaust and throw")
        } catch {
            #expect(attempts == 2)
            guard case .emptyResponse(let backend) = error as? MeetingSummaryError else {
                #expect(Bool(false), "Expected emptyResponse, got \(String(describing: error))")
                return
            }
            #expect(backend == "Ollama")
        }
    }

    @Test("summary retries skip local endpoint unavailable failures")
    func summaryRetriesSkipLocalEndpointUnavailableFailures() async {
        var attempts = 0

        do {
            _ = try await MeetingSummaryClient.withSummaryRetries(
                maxRetries: 5,
                sleep: { _ in }
            ) {
                attempts += 1
                throw MeetingSummaryError.requestFailed(
                    backend: "LM Studio",
                    underlying: URLError(.cannotConnectToHost)
                )
            }
            #expect(Bool(false), "Expected local endpoint failure to throw without retries")
        } catch {
            #expect(attempts == 1)
            guard case .requestFailed(let backend, _) = error as? MeetingSummaryError else {
                #expect(Bool(false), "Expected requestFailed, got \(String(describing: error))")
                return
            }
            #expect(backend == "LM Studio")
        }
    }

    @Test("summary retry policy skips cancellation and permanent backend failures")
    func summaryRetryPolicySkipsCancellationAndPermanentBackendFailures() {
        #expect(!MeetingSummaryRetryPolicy.shouldRetry(CancellationError()))
        #expect(!MeetingSummaryRetryPolicy.shouldRetry(
            MeetingSummaryError.requestFailed(backend: "OpenAI", underlying: URLError(.cancelled))
        ))
        #expect(!MeetingSummaryRetryPolicy.shouldRetry(
            MeetingSummaryError.requestFailed(backend: "ChatGPT", underlying: ChatGPTAuthError.notAuthenticated)
        ))
        #expect(!MeetingSummaryRetryPolicy.shouldRetry(
            MeetingSummaryError.requestFailed(backend: "Ollama", underlying: URLError(.unsupportedURL))
        ))
        #expect(!MeetingSummaryRetryPolicy.shouldRetry(
            MeetingSummaryError.backendFailed(backend: "Custom LLM", statusCode: nil, message: "No model selected")
        ))
        #expect(!MeetingSummaryRetryPolicy.shouldRetry(
            MeetingSummaryError.backendFailed(backend: "OpenRouter", statusCode: 400, message: "Bad request")
        ))
        #expect(!MeetingSummaryRetryPolicy.shouldRetry(
            MeetingSummaryError.requestFailed(backend: "Ollama", underlying: URLError(.cannotConnectToHost))
        ))
        #expect(!MeetingSummaryRetryPolicy.shouldRetry(
            MeetingSummaryError.requestFailed(backend: "LM Studio", underlying: URLError(.dnsLookupFailed))
        ))
        #expect(MeetingSummaryRetryPolicy.shouldRetry(
            MeetingSummaryError.requestFailed(backend: "OpenAI", underlying: URLError(.cannotConnectToHost))
        ))
        #expect(MeetingSummaryRetryPolicy.shouldRetry(
            MeetingSummaryError.backendFailed(backend: "OpenRouter", statusCode: 429, message: "Rate limited")
        ))
        #expect(MeetingSummaryRetryPolicy.shouldRetry(
            MeetingSummaryError.backendFailed(backend: "OpenAI", statusCode: 503, message: "Unavailable")
        ))
    }

    @Test("summary retry policy uses backend-aware retry budgets")
    func summaryRetryPolicyUsesBackendAwareRetryBudgets() {
        #expect(MeetingSummaryRetryPolicy.effectiveRetryCount(
            configuredCount: 5,
            after: MeetingSummaryError.backendFailed(backend: "OpenAI", statusCode: 503, message: "Unavailable")
        ) == 5)
        #expect(MeetingSummaryRetryPolicy.effectiveRetryCount(
            configuredCount: 5,
            after: MeetingSummaryError.emptyResponse(backend: "Ollama")
        ) == 1)
        #expect(MeetingSummaryRetryPolicy.effectiveRetryCount(
            configuredCount: 5,
            after: MeetingSummaryError.requestFailed(
                backend: "LM Studio",
                underlying: URLError(.cannotConnectToHost)
            )
        ) == 0)
        #expect(MeetingSummaryRetryPolicy.effectiveRetryCount(
            configuredCount: 99,
            after: MeetingSummaryError.backendFailed(backend: "OpenRouter", statusCode: 429, message: "Rate limited")
        ) == MeetingSummaryRetryPolicy.maximumRetryCount)
    }

    @Test("generateTitle returns nil without API key")
    func titleWithoutKey() async {
        var config = AppConfig()
        config.openAIAPIKey = ""
        config.meetingSummaryBackend = "openai"

        let title = await MeetingSummaryClient.generateTitle(
            transcript: "We discussed the quarterly review",
            config: config
        )

        #expect(title == nil)
    }

    @Test("title excerpt samples opening middle and closing transcript")
    func titleExcerptSamplesMeetingBreadth() {
        let transcript = [
            String(repeating: "opening setup ", count: 80),
            String(repeating: "middle product strategy ", count: 80),
            String(repeating: "closing storage roadmap ", count: 80),
        ].joined(separator: "\n\n")

        let excerpt = MeetingSummaryClient.titleTranscriptExcerpt(from: transcript, segmentLength: 120)

        #expect(excerpt.contains("Opening excerpt:"))
        #expect(excerpt.contains("Middle excerpt:"))
        #expect(excerpt.contains("Closing excerpt:"))
        #expect(excerpt.contains("opening setup"))
        #expect(excerpt.contains("middle product strategy"))
        #expect(excerpt.contains("closing storage roadmap"))
    }

    @Test("short title excerpt keeps full transcript")
    func shortTitleExcerptKeepsFullTranscript() {
        let transcript = "Short discussion about customer onboarding"

        let excerpt = MeetingSummaryClient.titleTranscriptExcerpt(from: transcript, segmentLength: 120)

        #expect(excerpt == transcript)
    }

    @Test("generateTitle returns nil for OpenRouter without key")
    func titleOpenRouterWithoutKey() async {
        var config = AppConfig()
        config.openRouterAPIKey = ""
        config.meetingSummaryBackend = "openrouter"

        let title = await MeetingSummaryClient.generateTitle(
            transcript: "Sprint planning discussion",
            config: config
        )

        #expect(title == nil)
    }

    @Test("empty summary backend resolves to ChatGPT")
    func defaultsToChatGPT() {
        var config = AppConfig()
        config.meetingSummaryBackend = ""

        let backend = MeetingSummaryBackendOption.resolved(
            config.meetingSummaryBackend.isEmpty ? nil : config.meetingSummaryBackend
        )

        #expect(backend == .chatGPT)
    }

    @Test("summarize routes to Ollama when configured")
    func routesToOllama() async throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "ollama"
        config.ollamaURL = "http://localhost:1" // invalid port to force connection failure
        config.meetingSummaryRetryCount = 0

        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "Test transcript",
                meetingTitle: "My Meeting",
                config: config
            )
            #expect(Bool(false), "Expected error to be thrown")
        } catch {
            let summaryError = error as? MeetingSummaryError
            #expect(summaryError != nil)
            if case .requestFailed(let backend, _) = summaryError! {
                #expect(backend == "Ollama")
            } else {
                #expect(Bool(false), "Expected requestFailed error, got \(String(describing: error))")
            }
        }
    }

    @Test("generateTitle returns nil for Ollama when unreachable")
    func titleOllamaUnreachable() async {
        var config = AppConfig()
        config.meetingSummaryBackend = "ollama"
        config.ollamaURL = "http://localhost:1"

        let title = await MeetingSummaryClient.generateTitle(
            transcript: "Sprint planning discussion",
            config: config
        )

        #expect(title == nil)
    }

    @Test("generateTitle returns nil for Ollama with invalid URL")
    func titleOllamaInvalidURL() async {
        var config = AppConfig()
        config.meetingSummaryBackend = "ollama"
        config.ollamaURL = "not a valid url"

        let title = await MeetingSummaryClient.generateTitle(
            transcript: "Sprint planning discussion",
            config: config
        )

        #expect(title == nil)
    }

    @Test("summarize with Ollama uses default model when none configured")
    func ollamaUsesDefaultModel() async throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "ollama"
        config.ollamaModel = ""
        config.ollamaURL = "http://localhost:1"
        config.meetingSummaryRetryCount = 0

        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "Test",
                meetingTitle: "Title",
                config: config
            )
        } catch {
            // The request fails because port 1 is invalid, but the model
            // defaulting is tested by the fact that no empty-model error is thrown
            let summaryError = error as? MeetingSummaryError
            #expect(summaryError != nil)
        }
    }

    @Test("resolveCustomLLMURL expands OpenAI-compatible endpoints")
    func resolveCustomLLMOpenAIURL() {
        var config = AppConfig()

        config.customLLMURL = ""
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)?.absoluteString ==
                "http://localhost:8080/v1/chat/completions"
        )

        config.customLLMURL = "https://models.example.com"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)?.absoluteString ==
                "https://models.example.com/v1/chat/completions"
        )

        config.customLLMURL = "https://models.example.com/v1/"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)?.absoluteString ==
                "https://models.example.com/v1/chat/completions"
        )

        config.customLLMURL = "https://models.example.com/openai/v1"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)?.absoluteString ==
                "https://models.example.com/openai/v1/chat/completions"
        )

        config.customLLMURL = "https://models.example.com/llm/v2/chat/completions"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)?.absoluteString ==
                "https://models.example.com/llm/v2/chat/completions"
        )

        config.customLLMURL = "https://models.example.com/llm/v2/completions"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)?.absoluteString ==
                "https://models.example.com/llm/v2/completions/v1/chat/completions"
        )

        config.customLLMURL = "https://models.example.com/openai/deployments/my-model/chat/completions?api-version=2024-10-21"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)?.absoluteString ==
                "https://models.example.com/openai/deployments/my-model/chat/completions?api-version=2024-10-21"
        )

        config.customLLMURL = "https://models.example.com/v1/chat/completions/"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)?.absoluteString ==
                "https://models.example.com/v1/chat/completions"
        )
    }

    @Test("resolveLMStudioURL expands chat completion endpoints")
    func resolveLMStudioURL() {
        var config = AppConfig()

        config.lmStudioURL = ""
        #expect(
            MeetingSummaryClient.resolveLMStudioURL(config: config)?.absoluteString ==
                "http://localhost:1234/v1/chat/completions"
        )

        config.lmStudioURL = "http://localhost:1234/v1"
        #expect(
            MeetingSummaryClient.resolveLMStudioURL(config: config)?.absoluteString ==
                "http://localhost:1234/v1/chat/completions"
        )

        config.lmStudioURL = "http://localhost:1234/proxy/v1"
        #expect(
            MeetingSummaryClient.resolveLMStudioURL(config: config)?.absoluteString ==
                "http://localhost:1234/proxy/v1/chat/completions"
        )

        config.lmStudioURL = "http://localhost:1234/v1/chat/completions"
        #expect(
            MeetingSummaryClient.resolveLMStudioURL(config: config)?.absoluteString ==
                "http://localhost:1234/v1/chat/completions"
        )
    }

    @Test("resolveCustomLLMURL expands Anthropic endpoints")
    func resolveCustomLLMAnthropicURL() {
        var config = AppConfig()

        config.customLLMURL = ""
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .anthropic)?.absoluteString ==
                "https://api.anthropic.com/v1/messages"
        )

        config.customLLMURL = "https://models.example.com/anthropic"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .anthropic)?.absoluteString ==
                "https://models.example.com/anthropic/v1/messages"
        )

        config.customLLMURL = "https://models.example.com/anthropic/v1"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .anthropic)?.absoluteString ==
                "https://models.example.com/anthropic/v1/messages"
        )

        config.customLLMURL = "https://models.example.com/anthropic/v2/messages"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .anthropic)?.absoluteString ==
                "https://models.example.com/anthropic/v2/messages"
        )

        config.customLLMURL = "https://models.example.com/messages"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .anthropic)?.absoluteString ==
                "https://models.example.com/messages/v1/messages"
        )

        config.customLLMURL = "https://models.example.com/v1/messages/"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .anthropic)?.absoluteString ==
                "https://models.example.com/v1/messages"
        )
    }

    @Test("extractAnthropicText joins text blocks")
    func extractAnthropicText() {
        let payload: [String: Any] = [
            "content": [
                ["type": "text", "text": "First"],
                ["type": "text", "text": "Second"],
            ],
        ]

        #expect(MeetingSummaryClient.extractAnthropicText(from: payload) == "First\nSecond")
        #expect(MeetingSummaryClient.extractAnthropicText(from: [:]) == nil)
    }

    @Test("summarize routes to LM Studio when configured")
    func routesToLMStudio() async throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "lmstudio"
        config.lmStudioURL = "http://localhost:1"
        config.lmStudioModel = "local-model"
        config.meetingSummaryRetryCount = 0

        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "Test transcript",
                meetingTitle: "My Meeting",
                config: config
            )
            #expect(Bool(false), "Expected error to be thrown")
        } catch {
            let summaryError = error as? MeetingSummaryError
            #expect(summaryError != nil)
            if case .requestFailed(let backend, _) = summaryError! {
                #expect(backend == "LM Studio")
            } else {
                #expect(Bool(false), "Expected requestFailed error, got \(String(describing: error))")
            }
        }
    }

    @Test("summarize routes to custom LLM without requiring an API key")
    func routesToCustomLLMWithoutKey() async throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "custom_llm"
        config.customLLMFormat = "openai"
        config.customLLMURL = "http://localhost:1"
        config.customLLMAPIKey = ""
        config.customLLMModel = "local-model"
        config.meetingSummaryRetryCount = 0

        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "Test transcript",
                meetingTitle: "My Custom Meeting",
                config: config
            )
            #expect(Bool(false), "Expected error to be thrown")
        } catch {
            let summaryError = error as? MeetingSummaryError
            #expect(summaryError != nil)
            if case .requestFailed(let backend, _) = summaryError! {
                #expect(backend == "Custom LLM")
            } else {
                #expect(Bool(false), "Expected requestFailed error, got \(String(describing: error))")
            }
        }
    }

    @Test("custom LLM summary requires explicit model")
    func customLLMRequiresModel() async throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "custom_llm"
        config.customLLMFormat = "openai"
        config.customLLMURL = "http://localhost:1"
        config.customLLMModel = ""

        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "Test transcript",
                meetingTitle: "My Custom Meeting",
                config: config
            )
            #expect(Bool(false), "Expected error to be thrown")
        } catch {
            guard case .backendFailed(let backend, _, let message) = error as? MeetingSummaryError else {
                #expect(Bool(false), "Expected backendFailed error, got \(String(describing: error))")
                return
            }
            #expect(backend == "Custom LLM")
            #expect(message.contains("No model selected"))
        }
    }

    @Test("Anthropic custom LLM requires API key")
    func anthropicCustomLLMRequiresAPIKey() async throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "custom_llm"
        config.customLLMFormat = "anthropic"
        config.customLLMAPIKey = ""
        config.customLLMModel = "claude-test"

        #expect(MeetingSummaryClient.customLLMRequiresAPIKey(config: config))

        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "Test transcript",
                meetingTitle: "My Custom Meeting",
                config: config
            )
            #expect(Bool(false), "Expected error to be thrown")
        } catch {
            guard case .backendFailed(let backend, _, let message) = error as? MeetingSummaryError else {
                #expect(Bool(false), "Expected backendFailed error, got \(String(describing: error))")
                return
            }
            #expect(backend == "Custom LLM")
            #expect(message.contains("API key"))
        }
    }

    @Test("OpenAI-compatible custom LLM does not require API key")
    func openAICustomLLMDoesNotRequireAPIKey() {
        var config = AppConfig()
        config.customLLMFormat = "openai"
        config.customLLMAPIKey = ""

        #expect(!MeetingSummaryClient.customLLMRequiresAPIKey(config: config))
    }

    @Test("LM Studio readiness requires model")
    func lmStudioReadinessRequiresModel() {
        var config = AppConfig()

        config.lmStudioModel = ""
        #expect(!MeetingSummaryClient.lmStudioHasRequiredSettings(config: config))

        config.lmStudioModel = "   "
        #expect(!MeetingSummaryClient.lmStudioHasRequiredSettings(config: config))

        config.lmStudioModel = "local-model"
        #expect(MeetingSummaryClient.lmStudioHasRequiredSettings(config: config))
    }

    @Test("Custom LLM readiness requires model and Anthropic key")
    func customLLMReadinessRequiresModelAndAnthropicKey() {
        var config = AppConfig()

        config.customLLMFormat = "openai"
        config.customLLMModel = ""
        config.customLLMAPIKey = ""
        #expect(!MeetingSummaryClient.customLLMHasRequiredSettings(config: config))

        config.customLLMModel = "   "
        #expect(!MeetingSummaryClient.customLLMHasRequiredSettings(config: config))

        config.customLLMModel = "local-model"
        #expect(MeetingSummaryClient.customLLMHasRequiredSettings(config: config))

        config.customLLMFormat = "anthropic"
        config.customLLMAPIKey = ""
        #expect(!MeetingSummaryClient.customLLMHasRequiredSettings(config: config))

        config.customLLMAPIKey = "   "
        #expect(!MeetingSummaryClient.customLLMHasRequiredSettings(config: config))

        config.customLLMAPIKey = "sk-ant-test"
        #expect(MeetingSummaryClient.customLLMHasRequiredSettings(config: config))
    }

    @Test("generateTitle returns nil for LM Studio when unreachable")
    func titleLMStudioUnreachable() async {
        var config = AppConfig()
        config.meetingSummaryBackend = "lmstudio"
        config.lmStudioURL = "http://localhost:1"
        config.lmStudioModel = "local-model"

        let title = await MeetingSummaryClient.generateTitle(
            transcript: "Sprint planning discussion",
            config: config
        )

        #expect(title == nil)
    }

    @Test("OpenAI summary request opts out of server-side storage")
    func openAISummaryBodyDisablesStorage() {
        let body = MeetingSummaryClient.openAISummaryBody(
            instructions: "Summarize.",
            userPrompt: "Transcript here",
            model: "gpt-5-mini"
        )

        #expect(body["store"] as? Bool == false)
        #expect(body["model"] as? String == "gpt-5-mini")
        let input = body["input"] as? [[String: String]]
        #expect(input?.count == 2)
        #expect(input?.first?["role"] == "system")
    }
}
