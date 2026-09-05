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

    @Test("meeting transcription evidence preserves recognizer text separately")
    func meetingEvidencePreservesRawRecognizerText() {
        let raw = SpeechTranscriptionResult(
            text: "Hello [blank_audio] world",
            segments: [segment]
        )

        let evidence = MeetingTranscriptionEvidence(raw: raw)

        #expect(evidence.raw.text == "Hello [blank_audio] world")
        #expect(evidence.raw.segments.count == 1)
        #expect(evidence.cleaned.text == "Hello world")
        #expect(evidence.cleaned.segments.isEmpty)
    }
}

@Suite("Meeting raw transcript evidence")
struct MeetingRawTranscriptAccumulatorTests {
    @Test("orders concurrent channel evidence by timeline and retains raw text")
    func ordersEvidenceByTimeline() {
        let accumulator = MeetingRawTranscriptAccumulator()
        accumulator.appendBatch(
            SpeechTranscriptionResult(text: "system [blank_audio]", segments: []),
            start: 8,
            end: 9,
            source: .system
        )
        accumulator.appendBatch(
            SpeechTranscriptionResult(text: "mic um", segments: []),
            start: 2,
            end: 3,
            source: .microphone
        )

        #expect(accumulator.transcript() == "mic um\nsystem [blank_audio]")
    }

    @Test("uses unified streaming text only for channels without batch evidence")
    func usesStreamingFallbackPerChannel() {
        let accumulator = MeetingRawTranscriptAccumulator()
        accumulator.appendBatch(
            SpeechTranscriptionResult(text: "batch system", segments: []),
            start: 4,
            end: 5,
            source: .system
        )
        accumulator.appendStreamingSegmentsOutsideBatchEvidence(
            [SpeechSegment(start: 1, end: 2, text: "streaming mic")],
            source: .microphone
        )
        accumulator.appendStreamingSegmentsOutsideBatchEvidence(
            [
                SpeechSegment(start: 1, end: 2, text: "earlier streaming system"),
                SpeechSegment(start: 4.25, end: 4.75, text: "covered streaming system"),
            ],
            source: .system
        )

        #expect(
            accumulator.transcript()
                == "streaming mic\nearlier streaming system\nbatch system"
        )
    }

    @Test("bounds accumulated recognizer evidence by the artifact cap")
    func boundsEvidence() {
        let accumulator = MeetingRawTranscriptAccumulator()
        let oversized = String(
            repeating: "a",
            count: SessionTraceRetentionPolicy.default.maximumArtifactBytes + 100
        )

        accumulator.appendBatch(
            SpeechTranscriptionResult(text: oversized, segments: []),
            start: 0,
            end: 1,
            source: .microphone
        )

        #expect(
            accumulator.transcript().utf8.count
                == SessionTraceRetentionPolicy.default.maximumArtifactBytes
        )
    }
}

@Suite("Meeting fallback classification")
struct MeetingFallbackClassificationTests {
    @Test("classifies every live fallback while retaining summary compatibility")
    func classifiesFallbackReasons() {
        let now = Date(timeIntervalSince1970: 1_000)
        let base = MeetingSessionResult(
            title: "Meeting",
            originalTitle: "Meeting",
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            durationSeconds: 60,
            rawTranscript: "Transcript",
            formattedNotes: "Notes",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )
        #expect(!base.usedFallback)

        var legacySummaryFallback = base
        legacySummaryFallback.usedSummaryFallback = true
        #expect(legacySummaryFallback.usedFallback)

        var titleFallback = base
        titleFallback.fallbackReasons = [.titleGeneration]
        #expect(titleFallback.usedFallback)
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
            source: .group,
            categoryID: nil,
            groupID: "messages"
        )

        let policy = DictationCleanupPolicy(enabled: true, selection: selection)

        #expect(policy.systemPromptSnapshot.components(separatedBy: stylePrompt).count == 2)
        #expect(policy.systemPromptSnapshot.contains("untrusted reference data"))
        #expect(policy.provenance?.styleID == "message")
        #expect(policy.provenance?.source == .group)
        #expect(policy.provenance?.modeID == "messages")
    }

    @Test("custom instructions sit between the style block and the speaker vocabulary")
    func customInstructionsSitBetweenStyleAndVocabulary() throws {
        let base = DictationCleanupPromptComposer.compose(styleInstructions: "Keep it casual.")
        let prompt = DictationCleanupPromptComposer.systemPrompt(
            base: base,
            customInstructions: "Use British English.",
            customWords: [CustomWord(word: "muesli", replacement: "Muesli")]
        )

        let style = try #require(prompt.range(of: "<STYLE-INSTRUCTIONS>"))
        let block = try #require(prompt.range(of: CustomInstructions.openingTag))
        let vocabulary = try #require(prompt.range(of: "Speaker vocabulary"))
        #expect(style.lowerBound < block.lowerBound)
        #expect(block.lowerBound < vocabulary.lowerBound)
        #expect(prompt.contains("Use British English."))
    }

    @Test("empty custom instructions leave the prompt byte-identical")
    func emptyCustomInstructionsKeepBytes() {
        let words = [CustomWord(word: "muesli", replacement: "Muesli")]
        let raw = "Legacy prompt bytes"
        let expected = DictationCleanupPromptComposer.appendingSpeakerVocabulary(to: raw, customWords: words)

        #expect(DictationCleanupPromptComposer.systemPrompt(base: raw, customInstructions: "", customWords: words) == expected)
        #expect(DictationCleanupPromptComposer.systemPrompt(base: raw, customInstructions: " \n ", customWords: words) == expected)
        let styled = DictationCleanupPromptComposer.compose(styleInstructions: "Style")
        #expect(DictationCleanupPromptComposer.systemPrompt(base: styled, customWords: words)
            == DictationCleanupPromptComposer.appendingSpeakerVocabulary(to: styled, customWords: words))
    }

    @Test("the on-device backend budgets the block and other backends keep it")
    func backendBudgetBoundsBlock() {
        var config = AppConfig()
        config.customInstructions = String(repeating: "x", count: 1_500)

        let local = DictationCleanupPromptComposer.systemPrompt(config: config, mode: nil, cleanupBackend: .local)
        let gemma = DictationCleanupPromptComposer.systemPrompt(config: config, mode: nil, cleanupBackend: .gemma4LiteRT)

        #expect(DictationCleanupPromptComposer.customInstructionsLimit(for: .local) == 500)
        #expect(local.contains(String(repeating: "x", count: 500)))
        #expect(!local.contains(String(repeating: "x", count: 501)))
        #expect(gemma.contains(String(repeating: "x", count: 1_500)))
    }

    @Test("the runtime preload prompt matches the session prompt for the same config")
    func preloadMatchesSessionWithoutAdaptiveStyles() throws {
        var config = AppConfig()
        config.enablePostProcessor = true
        config.adaptiveDictationStylesEnabled = false
        config.customInstructions = "Be concise."
        config.customWords = [CustomWord(word: "muesli", replacement: "Muesli")]
        let snapshot = DictationStyleSessionSnapshot(target: nil, config: config, mode: .standard)

        let policy = try #require(snapshot.cleanupPolicy(enabled: true, context: nil))
        let preload = DictationCleanupPromptComposer.systemPrompt(config: config, mode: nil, cleanupBackend: .local)
        #expect(policy.systemPromptSnapshot == preload)
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

    @Test("deadline fallback preserves the recognizer transcript")
    func deadlineFallbackPreservesRawTranscript() {
        let result = DictationCleanupFinalizer.finalize(
            original: original,
            attempt: .fallbackDeadline,
            customWords: [CustomWord(word: "museli", replacement: "Muesli")],
            provenance: nil,
            fallbackResult: original
        )

        #expect(result.cleanupOutcome == .fallbackDeadline)
        #expect(result.text == "Um send this to Muesli")
        #expect(DictationCleanupAttempt.fallbackDeadline.stageOutcome == .deadlineExceeded)
    }

    @Test("readiness distinguishes user-disabled from unavailable before invocation")
    func readinessOutcomes() {
        let cases: [(DictationCleanupReadiness, DictationCleanupOutcome?)] = [
            (.disabled, .skippedDisabled),
            (.unavailable, .skippedUnavailable),
            (.ready, nil),
        ]

        for (readiness, outcome) in cases {
            #expect(readiness.skippedAttempt?.outcome == outcome)
        }
        #expect(DictationCleanupReadiness.resolve(isEnabled: false, isAvailable: true) == .disabled)
        #expect(DictationCleanupReadiness.resolve(isEnabled: true, isAvailable: false) == .unavailable)
        #expect(DictationCleanupReadiness.resolve(isEnabled: true, isAvailable: true) == .ready)
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

    @available(macOS 15, *)
    @Test("concurrent Qwen requests retain their pinned model URLs")
    func concurrentQwenModelSelection() async {
        let first = URL(fileURLWithPath: "/tmp/first.gguf")
        let second = URL(fileURLWithPath: "/tmp/second.gguf")

        let resolved = await withTaskGroup(of: URL.self, returning: Set<URL>.self) { group in
            group.addTask {
                Qwen3PostProcessor.resolvedRequestModelURL(requested: first, devOverride: nil)
            }
            group.addTask {
                Qwen3PostProcessor.resolvedRequestModelURL(requested: second, devOverride: nil)
            }
            var values = Set<URL>()
            for await value in group {
                values.insert(value)
            }
            return values
        }

        #expect(resolved == [first, second])
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
        var backends = Set(BackendOption.all.map(\.backend))
        backends.insert(BackendOption.appleSpeechAnalyzer.backend)
        #expect(backends == TranscriptionCoordinator.explicitlyRoutedBackendIdentifiers.union(["fluidaudio"]))
    }

    @Test("Apple Speech cleanup waits for an active use")
    func appleSpeechCleanupWaitsForActiveUse() async {
        let lifecycle = AppleSpeechUseLifecycle()
        let cleanupCount = TranscriptionLifecycleTestCounter()

        await lifecycle.beginUse()
        await lifecycle.requestCleanup {
            await cleanupCount.increment()
        }

        #expect(await lifecycle.snapshot() == .init(
            activeUseCount: 1,
            hasDeferredCleanup: true,
            isCleaningUp: false
        ))
        #expect(await cleanupCount.value == 0)

        await lifecycle.endUse()
        #expect(await cleanupCount.value == 1)
    }

    @Test("Apple Speech cleanup waits for dictation and meeting uses")
    func appleSpeechCleanupWaitsForCombinedUses() async {
        let lifecycle = AppleSpeechUseLifecycle()
        let cleanupCount = TranscriptionLifecycleTestCounter()

        await lifecycle.beginUse()
        await lifecycle.beginUse()
        await lifecycle.requestCleanup {
            await cleanupCount.increment()
        }

        await lifecycle.endUse()
        #expect(await cleanupCount.value == 0)
        await lifecycle.endUse()
        #expect(await cleanupCount.value == 1)
    }

    @Test("a newer Apple Speech use cancels a deferred stale cleanup")
    func newerAppleSpeechUseCancelsDeferredCleanup() async {
        let lifecycle = AppleSpeechUseLifecycle()
        let cleanupCount = TranscriptionLifecycleTestCounter()

        await lifecycle.beginUse()
        await lifecycle.requestCleanup {
            await cleanupCount.increment()
        }
        await lifecycle.beginUse()

        await lifecycle.endUse()
        await lifecycle.endUse()

        #expect(await cleanupCount.value == 0)
        #expect(await lifecycle.snapshot() == .init(
            activeUseCount: 0,
            hasDeferredCleanup: false,
            isCleaningUp: false
        ))
    }

    @Test("a new Apple Speech use waits for in-flight cleanup")
    func appleSpeechUseWaitsForCleanup() async {
        let lifecycle = AppleSpeechUseLifecycle()
        let cleanupStarted = TranscriptionLifecycleTestLatch()
        let allowCleanup = TranscriptionLifecycleTestLatch()
        let useStarted = TranscriptionLifecycleTestCounter()

        let cleanupTask = Task {
            await lifecycle.requestCleanup {
                await cleanupStarted.signal()
                await allowCleanup.wait()
            }
        }
        await cleanupStarted.wait()

        let useTask = Task {
            await lifecycle.beginUse()
            await useStarted.increment()
        }
        for _ in 0..<100 {
            if (await lifecycle.snapshot()).activeUseCount > 0 { break }
            await Task.yield()
        }

        #expect((await lifecycle.snapshot()).activeUseCount == 1)
        #expect(await useStarted.value == 0)
        #expect((await lifecycle.snapshot()).isCleaningUp)

        await allowCleanup.signal()
        await cleanupTask.value
        await useTask.value

        #expect(await useStarted.value == 1)
        await lifecycle.endUse()
    }

    @Test("a newer cleanup request survives an older in-flight cleanup")
    func newerAppleSpeechCleanupIsNotDropped() async {
        let lifecycle = AppleSpeechUseLifecycle()
        let firstCleanupStarted = TranscriptionLifecycleTestLatch()
        let allowFirstCleanup = TranscriptionLifecycleTestLatch()
        let secondCleanupCount = TranscriptionLifecycleTestCounter()

        let firstCleanupTask = Task {
            await lifecycle.requestCleanup {
                await firstCleanupStarted.signal()
                await allowFirstCleanup.wait()
            }
        }
        await firstCleanupStarted.wait()

        let useTask = Task {
            await lifecycle.beginUse()
        }
        for _ in 0..<100 {
            if (await lifecycle.snapshot()).activeUseCount > 0 { break }
            await Task.yield()
        }
        #expect((await lifecycle.snapshot()).activeUseCount == 1)

        let secondCleanupTask = Task {
            await lifecycle.requestCleanup {
                await secondCleanupCount.increment()
            }
        }
        for _ in 0..<100 {
            if (await lifecycle.snapshot()).hasDeferredCleanup { break }
            await Task.yield()
        }
        #expect((await lifecycle.snapshot()).hasDeferredCleanup)

        await allowFirstCleanup.signal()
        await firstCleanupTask.value
        await useTask.value
        await secondCleanupTask.value

        #expect(await secondCleanupCount.value == 0)
        #expect((await lifecycle.snapshot()).hasDeferredCleanup)

        await lifecycle.endUse()
        #expect(await secondCleanupCount.value == 1)
    }
}

private actor TranscriptionLifecycleTestCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor TranscriptionLifecycleTestLatch {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        isSignaled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

@Suite("Hosted dictation cleanup deadline")
struct HostedDictationCleanupDeadlineTests {
    @Test("uses a short five-second production deadline")
    func productionDeadline() {
        #expect(HostedDictationCleanupDeadline.defaultTimeout == .seconds(5))
    }

    @Test("normalizes provider timeout errors to the deadline fallback")
    func providerTimeoutClassification() {
        #expect(HostedDictationCleanupDeadline.isDeadlineError(URLError(.timedOut)))
        #expect(!HostedDictationCleanupDeadline.isDeadlineError(URLError(.notConnectedToInternet)))
    }

    @Test("returns cleanup completed before the deadline")
    func cleanupWins() async throws {
        let value = try await HostedDictationCleanupDeadline.run(timeout: .milliseconds(100)) {
            "cleaned"
        }

        #expect(value == "cleaned")
    }

    @Test("expires slow cleanup instead of blocking dictation")
    func deadlineWins() async {
        do {
            let _: String = try await HostedDictationCleanupDeadline.run(timeout: .milliseconds(10)) {
                try await Task.sleep(for: .seconds(1))
                return "too late"
            }
            Issue.record("Expected hosted cleanup to exceed its deadline")
        } catch let error as HostedDictationCleanupDeadlineError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("returns on time when cleanup ignores task cancellation")
    func deadlineDoesNotAwaitUncooperativeCleanup() async {
        let completion = AsyncCompletionProbe()

        do {
            let _: String = try await HostedDictationCleanupDeadline.run(timeout: .milliseconds(10)) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                        continuation.resume(returning: ())
                    }
                }
                await completion.markCompleted()
                return "too late"
            }
            Issue.record("Expected hosted cleanup to exceed its deadline")
        } catch is HostedDictationCleanupDeadlineError {
            let cleanupCompleted = await completion.isCompleted
            #expect(!cleanupCompleted)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private actor AsyncCompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

@Suite("Dictation transcription stage diagnostics")
struct DictationTranscriptionStageDiagnosticsTests {
    @Test("stage events include outcome, duration, and output size")
    func eventDescription() {
        let event = DictationTranscriptionStageEvent(
            stage: .speechRecognition,
            outcome: .completed,
            elapsedMilliseconds: 237,
            outputCharacterCount: 42
        )

        #expect(event.latencyEvent == "stage:speech_recognition:completed stage_ms:237 chars:42")
    }

    @Test("only completed empty speech-recognition stages qualify as empty results")
    func emptyCompletedSpeechRecognitionClassification() {
        let completedEmpty = DictationTranscriptionStageEvent(
            stage: .speechRecognition,
            outcome: .completed,
            elapsedMilliseconds: 10,
            outputCharacterCount: 0
        )
        let skippedEmpty = DictationTranscriptionStageEvent(
            stage: .speechRecognition,
            outcome: .skipped,
            elapsedMilliseconds: 10,
            outputCharacterCount: 0
        )
        let completedText = DictationTranscriptionStageEvent(
            stage: .speechRecognition,
            outcome: .completed,
            elapsedMilliseconds: 10,
            outputCharacterCount: 1
        )

        #expect(completedEmpty.isEmptyCompletedSpeechRecognition)
        #expect(!skippedEmpty.isEmptyCompletedSpeechRecognition)
        #expect(!completedText.isEmptyCompletedSpeechRecognition)
    }

    @Test("cleanup stage uses the applied transcript character count")
    func appliedCleanupCharacterCount() {
        let attempt = DictationCleanupAttempt.applied(
            SpeechTranscriptionResult(text: "short", segments: [])
        )

        #expect(attempt.outputCharacterCount(fallback: 200) == 5)
        #expect(DictationCleanupAttempt.fallbackDeadline.outputCharacterCount(fallback: 200) == 200)
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

    @Test("recognizes LLM.swift's empty-generation placeholder for S1-mini")
    func recognizesS1MiniEmptyOutput() {
        #expect(Qwen3PostProcessorOutputCleaner.isS1MiniEmptyOutput("..."))
        #expect(Qwen3PostProcessorOutputCleaner.isS1MiniEmptyOutput(". . ."))
        #expect(Qwen3PostProcessorOutputCleaner.isS1MiniEmptyOutput("…"))
        #expect(!Qwen3PostProcessorOutputCleaner.isS1MiniEmptyOutput("Okay."))
    }

    @available(macOS 15, *)
    @Test("local cleanup keeps the captured configuration across model switches")
    func localCleanupKeepsCapturedConfigurationAcrossModelSwitches() async {
        let configurableURL = URL(fileURLWithPath: "/tmp/muesli-configurable-cleanup-test.gguf")
        let s1MiniURL = URL(fileURLWithPath: "/tmp/muesli-s1-mini-cleanup-test.gguf")
        let configurable = Qwen3PostProcessor.Configuration(
            modelURL: configurableURL,
            systemPrompt: "Configurable prompt",
            inputFormat: .configurable
        )
        let s1Mini = Qwen3PostProcessor.Configuration(
            modelURL: s1MiniURL,
            systemPrompt: PostProcessorOption.s1MiniSystemPrompt,
            inputFormat: .s1Mini
        )
        let processor = Qwen3PostProcessor(
            modelURL: configurable.modelURL,
            systemPrompt: configurable.systemPrompt,
            inputFormat: configurable.inputFormat
        )

        // Configurable -> S1-mini: the active configuration changes, but the
        // already captured configurable request must still use its own model.
        await processor.reconfigure(
            modelURL: s1Mini.modelURL,
            systemPrompt: s1Mini.systemPrompt,
            inputFormat: s1Mini.inputFormat
        )
        await assertMissingModel(
            processor: processor,
            configuration: configurable,
            expectedPath: configurableURL.path
        )

        // S1-mini -> configurable follows the same rule in the other direction.
        await processor.reconfigure(
            modelURL: configurable.modelURL,
            systemPrompt: configurable.systemPrompt,
            inputFormat: configurable.inputFormat
        )
        await assertMissingModel(
            processor: processor,
            configuration: s1Mini,
            expectedPath: s1MiniURL.path
        )
    }

    @available(macOS 15, *)
    @Test("effective local generation configuration preserves the token budget")
    func effectiveConfigurationPreservesTokenBudget() {
        let configuration = Qwen3PostProcessor.Configuration(
            modelURL: URL(fileURLWithPath: "/tmp/muesli-quill-budget-test.gguf"),
            systemPrompt: QuilTransformationPrompt.system,
            inputFormat: .configurable,
            maxTokenCount: Qwen3PostProcessorConfig.quilMaxContextTokens
        )

        let effective = Qwen3PostProcessor.effectiveConfiguration(for: configuration)

        #expect(effective.maxTokenCount == Qwen3PostProcessorConfig.quilMaxContextTokens)
    }

    @available(macOS 15, *)
    private func assertMissingModel(
        processor: Qwen3PostProcessor,
        configuration: Qwen3PostProcessor.Configuration,
        expectedPath: String
    ) async {
        do {
            _ = try await processor.process("test", configuration: configuration)
            Issue.record("Expected the test-only missing cleanup model to fail loading")
        } catch {
            #expect(error.localizedDescription.contains(expectedPath))
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

@Suite("Dictation mode prompt composition")
struct DictationModePromptCompositionTests {

    /// Any hosted backend: what matters is that it is not the on-device budget.
    private let hostedBackend = TranscriptCleanupBackendOption.all.first { $0 != .local && $0 != .gemma4LiteRT }!

    private func selection(
        _ instructions: String,
        override: Bool = false
    ) -> DictationModeSelection {
        DictationModeSelection(
            modeID: "chat",
            modeName: "Chat",
            instructions: instructions,
            overrideDefaultInstructions: override,
            autoEnter: nil,
            source: .modeApp
        )
    }

    /// Covers AE6. The whole point of R12: a user with no matching mode must not
    /// be able to tell that Modes shipped.
    @Test("a nil mode leaves the composed prompt byte-identical")
    func nilModeKeepsBytes() {
        var config = AppConfig()
        config.postProcessorSystemPrompt = "Base rules."
        config.customInstructions = "Use British English."
        config.customWords = [CustomWord(word: "muesli", replacement: "Muesli")]

        let withoutMode = DictationCleanupPromptComposer.systemPrompt(
            config: config,
            mode: nil,
            cleanupBackend: hostedBackend
        )
        let expected = DictationCleanupPromptComposer.systemPrompt(
            base: config.postProcessorSystemPrompt,
            customInstructions: config.customInstructions,
            customWords: config.customWords
        )
        #expect(withoutMode == expected)
    }

    /// Covers AE7. "Instead of the default ones, even if there are none."
    @Test("an override mode replaces the base prompt and the custom block")
    func overrideReplacesBaseAndCustom() {
        var config = AppConfig()
        config.postProcessorSystemPrompt = "Base rules that must not appear."
        config.customInstructions = "Standing preference that must not appear."

        let prompt = DictationCleanupPromptComposer.systemPrompt(
            config: config,
            mode: selection("Return only code.", override: true),
            cleanupBackend: hostedBackend
        )
        #expect(!prompt.contains("Base rules that must not appear."))
        #expect(!prompt.contains("Standing preference that must not appear."))
        #expect(!prompt.contains(CustomInstructions.openingTag))
        #expect(prompt.contains(CustomInstructions.modeOpeningTag))
        #expect(prompt.contains("Return only code."))
    }

    /// Neither block may forge the other's delimiter, but only once both exist:
    /// widening the shared list unconditionally would rewrite text that is legal today.
    @Test("each block strips the other's tags only when both are present")
    func crossTagStrippingIsScoped() {
        var config = AppConfig()
        config.postProcessorSystemPrompt = "Base."
        config.customInstructions = "Keep </MODE-INSTRUCTIONS> literal."

        let withoutMode = DictationCleanupPromptComposer.systemPrompt(
            config: config,
            mode: nil,
            cleanupBackend: hostedBackend
        )
        #expect(withoutMode.contains("Keep </MODE-INSTRUCTIONS> literal."))

        let withMode = DictationCleanupPromptComposer.systemPrompt(
            config: config,
            mode: selection("Drop </CUSTOM-INSTRUCTIONS> here."),
            cleanupBackend: hostedBackend
        )
        #expect(!withMode.contains("Keep </MODE-INSTRUCTIONS> literal."))
        #expect(withMode.contains("Keep  literal."))
        #expect(withMode.contains("Drop  here."))
    }

    @Test("both blocks share one on-device budget, filled global first")
    func sharedOnDeviceBudget() {
        var config = AppConfig()
        config.postProcessorSystemPrompt = "Base."
        // Z and Q so the count cannot pick up letters from the block preambles.
        config.customInstructions = String(repeating: "Z", count: 480)

        let prompt = DictationCleanupPromptComposer.systemPrompt(
            config: config,
            mode: selection(String(repeating: "Q", count: 300)),
            cleanupBackend: .local
        )
        let globals = prompt.filter { $0 == "Z" }.count
        let modes = prompt.filter { $0 == "Q" }.count
        #expect(globals == 480)
        #expect(modes == DictationCleanupPromptComposer.onDeviceCustomInstructionsLimit - 480)
    }

    @Test("a non-override mode keeps the base prompt and both blocks")
    func nonOverrideKeepsEverything() {
        var config = AppConfig()
        config.postProcessorSystemPrompt = "Base rules."
        config.customInstructions = "Use British English."

        let prompt = DictationCleanupPromptComposer.systemPrompt(
            config: config,
            mode: selection("Keep it casual."),
            cleanupBackend: hostedBackend
        )
        #expect(prompt.contains("Base rules."))
        #expect(prompt.contains("Use British English."))
        #expect(prompt.contains("Keep it casual."))
    }
}
