import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("SpeechSegment")
struct SpeechSegmentTests {

    @Test("stores start, end, text")
    func basicConstruction() {
        let segment = SpeechSegment(start: 1.5, end: 3.0, text: "Hello world")
        #expect(segment.start == 1.5)
        #expect(segment.end == 3.0)
        #expect(segment.text == "Hello world")
    }
}

@Suite("SpeechTranscriptionResult")
struct SpeechTranscriptionResultTests {

    @Test("stores text and segments")
    func basicConstruction() {
        let result = SpeechTranscriptionResult(
            text: "Full text",
            segments: [
                SpeechSegment(start: 0, end: 1, text: "Full"),
                SpeechSegment(start: 1, end: 2, text: "text"),
            ]
        )
        #expect(result.text == "Full text")
        #expect(result.segments.count == 2)
    }

    @Test("empty result")
    func emptyResult() {
        let result = SpeechTranscriptionResult(text: "", segments: [])
        #expect(result.text.isEmpty)
        #expect(result.segments.isEmpty)
    }
}

@Suite("Transcription result cleanup")
struct TranscriptionResultCleanupTests {
    private let segment = SpeechSegment(start: 1, end: 2, text: "Hello world")

    @Test("replacement clears segments only when aggregate text changes")
    func replacementSegmentInvariant() {
        let result = SpeechTranscriptionResult(text: "Hello world", segments: [segment])

        let changed = TranscriptionResultCleanup.replacingText(in: result, with: "Clean world")
        let unchanged = TranscriptionResultCleanup.replacingText(in: result, with: result.text)

        #expect(changed.text == "Clean world")
        #expect(changed.segments.isEmpty)
        #expect(unchanged.segments.count == 1)
    }

    @Test("filler cleanup clears segments when aggregate text changes")
    func changedFillerTextClearsSegments() {
        let result = SpeechTranscriptionResult(text: "Um hello world", segments: [segment])

        let cleaned = TranscriptionResultCleanup.removeFillers(result)

        #expect(cleaned.text == "Hello world")
        #expect(cleaned.segments.isEmpty)
    }

    @Test("filler cleanup retains segments when aggregate text is unchanged")
    func unchangedFillerTextRetainsSegments() {
        let result = SpeechTranscriptionResult(text: "Hello world", segments: [segment])

        let cleaned = TranscriptionResultCleanup.removeFillers(result)

        #expect(cleaned.text == result.text)
        #expect(cleaned.segments.count == 1)
    }

    @Test("artifact cleanup clears segments when aggregate text changes")
    func changedArtifactTextClearsSegments() {
        let result = SpeechTranscriptionResult(
            text: "Hello [blank_audio] world",
            segments: [segment]
        )

        let cleaned = TranscriptionResultCleanup.removeArtifacts(result)

        #expect(cleaned.text == "Hello world")
        #expect(cleaned.segments.isEmpty)
    }

    @Test("artifact cleanup retains segments when aggregate text is unchanged")
    func unchangedArtifactTextRetainsSegments() {
        let result = SpeechTranscriptionResult(text: "Hello world", segments: [segment])

        let cleaned = TranscriptionResultCleanup.removeArtifacts(result)

        #expect(cleaned.text == result.text)
        #expect(cleaned.segments.count == 1)
    }

    @Test("meeting cleanup keeps numeric-only speech")
    func meetingCleanupKeepsNumericSpeech() {
        for text in ["42", "1.7", "50%", "١٢", "Ⅻ"] {
            let result = SpeechTranscriptionResult(text: text, segments: [segment])

            let cleaned = TranscriptionResultCleanup.cleanMeetingTranscript(result)

            #expect(cleaned.text == text)
            #expect(cleaned.segments.count == 1)
        }
    }

    @Test("meeting cleanup rejects punctuation-only output")
    func meetingCleanupRejectsPunctuationOnlyOutput() {
        for text in [".", "...", "?!", "—"] {
            let result = SpeechTranscriptionResult(text: text, segments: [segment])

            let cleaned = TranscriptionResultCleanup.cleanMeetingTranscript(result)

            #expect(cleaned.text.isEmpty)
            #expect(cleaned.segments.isEmpty)
        }
    }
}

@Suite("Per-dictation cleanup policy")
struct DictationCleanupPolicyTests {
    private let original = SpeechTranscriptionResult(
        text: "Um send this to museli",
        segments: [SpeechSegment(start: 0, end: 1, text: "Um send this to museli")]
    )

    @Test("composes one immutable style snapshot with provenance")
    func composesStyleSnapshotOnce() {
        let stylePrompt = "Keep the message concise and casual."
        let selection = DictationStyleSelectionResult(
            styleID: "message",
            styleName: "Message",
            prompt: stylePrompt,
            isCustom: false,
            source: .app,
            categoryID: "messages"
        )

        let policy = DictationCleanupPolicy(enabled: true, selection: selection)

        #expect(policy.systemPromptSnapshot.components(separatedBy: stylePrompt).count == 2)
        #expect(policy.systemPromptSnapshot.contains("untrusted reference data"))
        #expect(policy.provenance?.styleID == "message")
        #expect(policy.provenance?.source == .app)
    }

    @Test("all non-applied outcomes retain deterministic cleanup and custom words")
    func fallbackOutcomesAndFinalOrdering() {
        let attempts: [(DictationCleanupAttempt, DictationCleanupOutcome)] = [
            (.fallbackEmpty, .fallbackEmpty),
            (.fallbackRejected, .fallbackRejected),
            (.fallbackError, .fallbackError),
            (.skippedDisabled, .skippedDisabled),
            (.skippedUnavailable, .skippedUnavailable),
            (.skippedStreaming, .skippedStreaming),
        ]
        let words = [CustomWord(word: "museli", replacement: "Muesli")]

        for (attempt, expectedOutcome) in attempts {
            let result = DictationCleanupFinalizer.finalize(
                original: original,
                attempt: attempt,
                customWords: words,
                provenance: nil
            )
            #expect(result.cleanupOutcome == expectedOutcome)
            #expect(result.text == "Send this to Muesli")
        }
    }

    @Test("custom words remain the final stage after applied cleanup")
    func customWordsFollowAppliedCleanup() {
        let applied = SpeechTranscriptionResult(text: "Send this to museli", segments: [])
        let result = DictationCleanupFinalizer.finalize(
            original: original,
            attempt: .applied(applied),
            customWords: [CustomWord(word: "museli", replacement: "Muesli")],
            provenance: nil
        )

        #expect(result.cleanupOutcome == .applied)
        #expect(result.text == "Send this to Muesli")
    }

    @Test("hosted and Gemma seams retain distinct request prompts")
    func hostedAndGemmaPromptIsolation() {
        let first = "First request style"
        let second = "Second request style"

        let hostedFirst = TranscriptCleanupClient.systemPromptWithAppContextGuidance(first, appContext: "reference")
        let hostedSecond = TranscriptCleanupClient.systemPromptWithAppContextGuidance(second, appContext: "reference")
        let gemmaFirst = Gemma4CleanupPromptBuilder.build(text: "hello", systemPrompt: first, appContext: "reference")
        let gemmaSecond = Gemma4CleanupPromptBuilder.build(text: "hello", systemPrompt: second, appContext: "reference")

        #expect(hostedFirst.contains(first) && !hostedFirst.contains(second))
        #expect(hostedSecond.contains(second) && !hostedSecond.contains(first))
        #expect(gemmaFirst.systemPrompt.contains(first) && !gemmaFirst.systemPrompt.contains(second))
        #expect(gemmaSecond.systemPrompt.contains(second) && !gemmaSecond.systemPrompt.contains(first))
        #expect(gemmaFirst.userPrompt.contains("untrusted quoted data"))
    }

    @available(macOS 15, *)
    @Test("Qwen request templates reset safely and model reuse keys only on URL")
    func qwenPromptIsolationAndResidency() {
        let first = Qwen3RequestTemplatePlan(requestPrompt: "First request style")
        let second = Qwen3RequestTemplatePlan(requestPrompt: "Second request style")
        let model = URL(fileURLWithPath: "/tmp/model.gguf")

        #expect(first.requestPrompt == "First request style")
        #expect(second.requestPrompt == "Second request style")
        #expect(first.resetPrompt == second.resetPrompt)
        #expect(first.resetPrompt != first.requestPrompt)
        #expect(!Qwen3PostProcessor.requiresModelReload(current: model, next: model))
        #expect(Qwen3PostProcessor.requiresModelReload(
            current: model,
            next: URL(fileURLWithPath: "/tmp/other.gguf")
        ))
    }
}

@Suite("Inference serialization gate")
struct InferenceGateTests {

    @Test("cancelled waiter is removed before next slot")
    func cancelledWaiterDoesNotConsumeSlot() async throws {
        let gate = InferenceGate()
        try await gate.acquire()

        let cancelled = Task {
            try await gate.acquire()
            await gate.release()
            return true
        }

        try await Task.sleep(for: .milliseconds(10))
        #expect(await gate.queuedWaiterCount() == 1)

        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await gate.queuedWaiterCount() == 0)

        let next = Task {
            try await gate.acquire()
            await gate.release()
            return true
        }

        try await Task.sleep(for: .milliseconds(10))
        await gate.release()
        #expect(try await next.value)

        do {
            _ = try await cancelled.value
            Issue.record("Cancelled waiter unexpectedly acquired the inference slot")
        } catch is CancellationError {
            // Expected path.
        } catch {
            Issue.record("Cancelled waiter failed with unexpected error: \(error)")
        }
    }
}

@Suite("TranscriptionCoordinator routing")
struct TranscriptionCoordinatorTests {

    @Test("coordinator initializes without crash")
    func initDoesNotCrash() {
        let _ = TranscriptionCoordinator()
    }

    @Test("backend routing covers all known backends")
    func allBackendsCovered() {
        let backends = Set(BackendOption.all.map(\.backend))
        #expect(backends == TranscriptionCoordinator.explicitlyRoutedBackendIdentifiers.union(["fluidaudio"]))
    }
}

@Suite("CohereTranscribeLanguage")
struct CohereTranscribeLanguageTests {

    @Test("english prompt ids match the current default prompt")
    func englishPromptIds() {
        #expect(
            CohereTranscribeLanguage.english.promptIds == [13764, 7, 4, 16, 62, 62, 5, 9, 11, 13]
        )
    }

    @Test("german prompt ids swap in the german language token")
    func germanPromptIds() {
        #expect(
            CohereTranscribeLanguage.german.promptIds == [13764, 7, 4, 16, 76, 76, 5, 9, 11, 13]
        )
    }

    @Test("unset and unsupported codes fall back to english")
    func resolvedFallbacks() {
        #expect(CohereTranscribeLanguage.resolved(nil) == .english)
        #expect(CohereTranscribeLanguage.resolved("xx") == .english)
    }
}

@Suite("CohereTranscribeUtils")
struct CohereTranscribeUtilsTests {

    @Test("single transcript returns unchanged")
    func singleTranscript() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts(["Hello world"])
        #expect(result == "Hello world")
    }

    @Test("empty list returns empty string")
    func emptyList() {
        #expect(CohereTranscribeUtils.mergeOverlappingTranscripts([]) == "")
    }

    @Test("no overlap joins with space")
    func noOverlap() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts([
            "The quick brown fox",
            "jumped over the lazy dog",
        ])
        #expect(result == "The quick brown fox jumped over the lazy dog")
    }

    @Test("exact trigram overlap deduplicates")
    func exactOverlap() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts([
            "I went to the store and bought some milk",
            "and bought some milk then came home",
        ])
        #expect(result == "I went to the store and bought some milk then came home")
    }

    @Test("case-insensitive trigram matching")
    func caseInsensitive() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts([
            "The Model Works well",
            "the model works well on device",
        ])
        #expect(result == "The Model Works well on device")
    }

    @Test("cleanTranscript strips endoftext token")
    func stripsEndOfText() {
        let result = CohereTranscribeUtils.cleanTranscript("Hello world<|endoftext|>garbage after")
        #expect(result == "Hello world")
    }

    @Test("cleanTranscript strips special tokens")
    func stripsSpecialTokens() {
        let result = CohereTranscribeUtils.cleanTranscript("Hello<|nospeech|> world<|pnc|>")
        #expect(result == "Hello world")
    }

    @Test("cleanTranscript trims a repeated tail loop to one instance")
    func trimsRepeatedTailLoop() {
        // Five consecutive "Thank you." sentences run to the end — a decoder repetition loop.
        let result = CohereTranscribeUtils.cleanTranscript(
            "Let's wrap up here. Thank you. Thank you. Thank you. Thank you. Thank you."
        )
        #expect(result == "Let's wrap up here. Thank you.")
    }

    @Test("cleanTranscript keeps a natural repeated interjection")
    func keepsNaturalRepetition() {
        // Two consecutive "Okay." sentences are natural speech, and the repetition does not
        // run to the end of the transcript.
        let result = CohereTranscribeUtils.cleanTranscript("Okay. Okay. Sounds good. Thanks.")
        #expect(result == "Okay. Okay. Sounds good. Thanks.")
    }

    @Test("cleanTranscript keeps a repeated sentence that is not at the tail")
    func keepsNonTailRepetition() {
        let result = CohereTranscribeUtils.cleanTranscript(
            "First. Second. Third. Fourth. Second. more text"
        )
        #expect(result == "First. Second. Third. Fourth. Second. more text")
    }

    @Test("cleanTranscript passes normal text unchanged")
    func normalTextUnchanged() {
        #expect(CohereTranscribeUtils.cleanTranscript("Normal transcription text.") == "Normal transcription text.")
    }
}

@Suite("TranscriptionEngineArtifactsFilter")
struct TranscriptionEngineArtifactsFilterTests {

    @Test("returns empty string for known artifact")
    func blankAudioArtifact() {
        #expect(TranscriptionEngineArtifactsFilter.apply("[blank_audio]") == "")
    }

    @Test("punctuation and symbols are non-speech artifacts")
    func nonSpeechArtifacts() {
        #expect(TranscriptionEngineArtifactsFilter.isNonSpeechArtifact("."))
        #expect(TranscriptionEngineArtifactsFilter.isNonSpeechArtifact("..."))
        #expect(TranscriptionEngineArtifactsFilter.isNonSpeechArtifact("?!"))
        #expect(TranscriptionEngineArtifactsFilter.isNonSpeechArtifact("—"))
    }

    @Test("letters and Unicode numbers are never non-speech artifacts")
    func realSpeechIsKept() {
        #expect(!TranscriptionEngineArtifactsFilter.isNonSpeechArtifact("ok"))
        #expect(!TranscriptionEngineArtifactsFilter.isNonSpeechArtifact("مرحبا"))
        #expect(!TranscriptionEngineArtifactsFilter.isNonSpeechArtifact("1.7 يعني"))
        #expect(!TranscriptionEngineArtifactsFilter.isNonSpeechArtifact(""))
        #expect(!TranscriptionEngineArtifactsFilter.isNonSpeechArtifact("42"))
        #expect(!TranscriptionEngineArtifactsFilter.isNonSpeechArtifact("1.7..."))
        #expect(!TranscriptionEngineArtifactsFilter.isNonSpeechArtifact("50%"))
        #expect(!TranscriptionEngineArtifactsFilter.isNonSpeechArtifact("١٢"))
        #expect(!TranscriptionEngineArtifactsFilter.isNonSpeechArtifact("Ⅻ"))
        #expect(!TranscriptionEngineArtifactsFilter.isNonSpeechArtifact("2026-08-03"))
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        #expect(TranscriptionEngineArtifactsFilter.apply("[BLANK_AUDIO]") == "")
    }

    @Test("trims surrounding whitespace before matching")
    func trailingWhitespace() {
        #expect(TranscriptionEngineArtifactsFilter.apply("  [blank_audio]  \n") == "")
    }

    @Test("passes through normal transcription unchanged")
    func normalTextUnchanged() {
        #expect(TranscriptionEngineArtifactsFilter.apply("Hello world") == "Hello world")
    }

    @Test("passes through empty string unchanged")
    func emptyTextUnchanged() {
        #expect(TranscriptionEngineArtifactsFilter.apply("") == "")
    }

    @Test("strips artifact when it appears mid-sentence")
    func midSentenceArtifact() {
        let text = "Hello [blank_audio] world"
        #expect(TranscriptionEngineArtifactsFilter.apply(text) == "Hello world")
    }

    @Test("strips decorated streaming blank-audio artifact")
    func decoratedStreamingArtifact() {
        #expect(TranscriptionEngineArtifactsFilter.apply(">> [BLANK_AUDIO]") == "")
        #expect(TranscriptionEngineArtifactsFilter.apply(">> [BLANK_AUDIO] Hello") == "Hello")
        #expect(TranscriptionEngineArtifactsFilter.apply(">> Hello") == ">> Hello")
    }

    @Test("strips model control tokens and non-speech annotations")
    func controlTokens() {
        #expect(
            TranscriptionEngineArtifactsFilter.apply("<EOU> Hello <EOB> [silence]") ==
                "Hello"
        )
    }

    @Test("strips foreign-language placeholders without removing ordinary sentences")
    func foreignLanguagePlaceholder() {
        #expect(TranscriptionEngineArtifactsFilter.apply("[SPEAKING IN FOREIGN LANGUAGE]") == "")
        #expect(
            TranscriptionEngineArtifactsFilter.apply("Speaking in a foreign language.") ==
                "Speaking in a foreign language."
        )
        #expect(TranscriptionEngineArtifactsFilter.apply("Hello [speaking in foreign language] world") == "Hello world")
        #expect(TranscriptionEngineArtifactsFilter.apply("[screaming]") == "")
        #expect(
            TranscriptionEngineArtifactsFilter.apply("We discussed speaking in foreign language classes.") ==
                "We discussed speaking in foreign language classes."
        )
    }

    @Test("strips leaked prompt suffix from transcript")
    func stripsLeakedPromptSuffix() {
        let text = """
        I'm testing local dictation. If a word is unclear, use the most likely word that fits well within the context of the overall sentence transcription.
        """
        #expect(
            TranscriptionEngineArtifactsFilter.apply(text) ==
                "I'm testing local dictation."
        )
    }

    @Test("strips leaked prompt prefix from transcript")
    func stripsLeakedPromptPrefix() {
        let text = "Transcribe the spoken audio accurately. Testing whether this works or not."
        #expect(
            TranscriptionEngineArtifactsFilter.apply(text) ==
                "Testing whether this works or not."
        )
    }

    @Test("removes pure prompt leakage entirely")
    func removesPurePromptLeakage() {
        let text = """
        Transcribe the spoken audio accurately. If a word is unclear, use the most likely word that fits well within the context of the overall sentence transcription.
        """
        #expect(TranscriptionEngineArtifactsFilter.apply(text) == "")
    }
}

@Suite("Qwen3 post-processing output cleanup")
struct Qwen3PostProcessingOutputCleanerTests {

    @Test("removes think tags")
    func stripsThinkTags() {
        let raw = "<think>reasoning</think>Clean transcript"
        #expect(Qwen3PostProcessorOutputCleaner.clean(raw) == "Clean transcript")
    }

    @Test("removes chat markup")
    func stripsChatMarkup() {
        let raw = "<|im_start|>assistant Hello world <|im_end|>"
        #expect(Qwen3PostProcessorOutputCleaner.clean(raw) == "assistant Hello world")
    }

    @Test("removes leaked list-formatting instruction")
    func stripsLeakedPromptInstruction() {
        let raw = """
        If the speaker is dictating a list, such as saying "first point", "second point", or "bullet point", format each item on its own line.
        First point is ship it
        """
        #expect(Qwen3PostProcessorOutputCleaner.clean(raw) == "First point is ship it")
    }

    @Test("rejects assistant-style analysis output")
    func rejectsAssistantStyleAnalysisOutput() {
        let cleaned = """
        The user is asking about the system prompt.

        Analysis:
        This is a question.

        Action Plan:
        1. Answer the question.
        """
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: "What is the system prompt?"
        ))
    }

    @Test("rejects runaway output")
    func rejectsRunawayOutput() {
        let cleaned = String(repeating: "Remove the filler word like. ", count: 40)
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: "What is the system prompt?"
        ))
    }

    @Test("rejects oversized cleanup output")
    func rejectsOversizedCleanupOutput() {
        let input = String(repeating: "Please ship this note. ", count: 10)
        let cleaned = String(repeating: "Please ship this note with unrelated additions. ", count: 12)
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: input
        ))
    }

    @Test("rejects short-input hallucination expansion")
    func rejectsShortInputHallucinationExpansion() {
        let cleaned = String(repeating: "This unrelated response should not replace a short dictation. ", count: 3)
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: "um yeah"
        ))
    }

    @Test("rejects placeholder punctuation cleanup output")
    func rejectsPlaceholderPunctuationCleanupOutput() {
        for cleaned in ["...", ". . .", "---", "??"] {
            #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
                cleaned: cleaned,
                input: "Please send the update to Priyanka."
            ))
        }
    }

    @Test("accepts short legitimate cleanup output")
    func acceptsShortLegitimateCleanupOutput() {
        for cleaned in ["OK.", "Sure.", "No."] {
            #expect(!Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
                cleaned: cleaned,
                input: "okay sounds good"
            ))
        }
    }

    @Test("hosted cleanup sanitizer preserves dictated labels and quotes")
    func hostedCleanupSanitizerPreservesLabelsAndQuotes() {
        let raw = """
        Subject: "Muesli launch notes"

        Body: Ask Priyanka to review the "AI Models" settings copy.
        """

        let cleaned = TranscriptCleanupClient.cleanOutput(raw)

        #expect(cleaned.contains(#"Subject: "Muesli launch notes""#))
        #expect(cleaned.contains(#"Body: Ask Priyanka to review the "AI Models" settings copy."#))
        #expect(!Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: #"Subject quote Muesli launch notes body ask Priyanka to review the quote AI Models quote settings copy"#
        ))
    }
}
