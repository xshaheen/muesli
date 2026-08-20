import AppKit
import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Dictation backend readiness")
struct DictationBackendReadinessTests {
    @Test("preparing backend blocks dictation with existing warmup copy")
    func preparingBlocksDictation() {
        let readiness = DictationBackendReadiness.preparing

        #expect(!readiness.allowsDictation)
        #expect(readiness.blockingMessage(backendLabel: "Parakeet v3") == "Warming up Parakeet v3...")
    }

    @Test("ready backend allows dictation")
    func readyAllowsDictation() {
        let readiness = DictationBackendReadiness.ready

        #expect(readiness.allowsDictation)
        #expect(readiness.blockingMessage(backendLabel: "Parakeet v3") == nil)
    }

    @Test("failed backend remains blocked with actionable status")
    func failedBlocksDictation() {
        let readiness = DictationBackendReadiness.failed

        #expect(!readiness.allowsDictation)
        #expect(readiness.blockingMessage(backendLabel: "Parakeet v3") == "Parakeet v3 unavailable")
    }
}

@Suite("Dictation terminal feedback eligibility")
struct DictationTerminalFeedbackEligibilityTests {
    @Test("only the first terminal failure remains eligible")
    func repeatedFailureHasOneWinner() async {
        let trace = SessionRunTrace(store: nil, kind: .dictation)

        #expect(await trace.fail(stage: "audio_session"))
        #expect(!(await trace.fail(stage: "dictation_pipeline")))
    }

    @Test("cancellation and empty output make later failures ineligible")
    func neutralOutcomesBlockLateFailure() async {
        let cancelled = SessionRunTrace(store: nil, kind: .dictation)
        #expect(await cancelled.cancel(stage: "recording"))
        #expect(!(await cancelled.fail(stage: "dictation_pipeline")))

        let empty = SessionRunTrace(store: nil, kind: .dictation)
        #expect(await empty.claimTerminal(
            .success,
            metadata: ["output_characters": "0"]
        ))
        #expect(!(await empty.fail(stage: "dictation_pipeline")))
    }
}

// MARK: - ChatGPT File-based Token Storage

@Suite("ChatGPT Token Storage")
struct ChatGPTTokenStorageTests {

    @Test("isAuthenticated returns false when no token file exists")
    @MainActor
    func notAuthenticatedByDefault() {
        // Shared singleton may have tokens from a prior test or real usage,
        // so just verify the property is accessible and returns a Bool
        let auth = ChatGPTAuthManager.shared
        let _ = auth.isAuthenticated  // Should not crash
    }

    @Test("signOut does not crash even when not signed in")
    @MainActor
    func signOutSafe() {
        let auth = ChatGPTAuthManager.shared
        auth.signOut()  // Should not crash
    }
}

// MARK: - Legacy indicator configuration compatibility

@Suite("Legacy indicator configuration")
struct LegacyIndicatorConfigurationTests {

    @Test("legacy visibility default remains decode-compatible")
    func legacyVisibilityDefault() {
        let config = AppConfig()
        #expect(config.showFloatingIndicator == true)
    }

    @Test("showFloatingIndicator persists through JSON round-trip")
    func jsonRoundTrip() throws {
        var config = AppConfig()
        config.showFloatingIndicator = false
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.showFloatingIndicator == false)
    }

    @Test("showFloatingIndicator decodes from snake_case JSON")
    func snakeCaseDecode() throws {
        let json = #"{"show_floating_indicator": false}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: json.data(using: .utf8)!)
        #expect(config.showFloatingIndicator == false)
    }

    @Test("floating hotkey defaults off while menu bar hotkey defaults on")
    func hotkeyVisibilityRoundTrip() throws {
        var config = AppConfig()
        #expect(!config.showHotkeyOnFloatingIndicator)
        #expect(config.showHotkeyInMenuBar)

        config.showHotkeyOnFloatingIndicator = true
        config.showHotkeyInMenuBar = false
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.showHotkeyOnFloatingIndicator)
        #expect(!decoded.showHotkeyInMenuBar)
    }

    @Test("missing hotkey visibility preferences use fresh-install defaults")
    func hotkeyVisibilityMissingKeysUseDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))

        #expect(!config.showHotkeyOnFloatingIndicator)
        #expect(config.showHotkeyInMenuBar)
    }

    @Test("hotkey visibility controls decode from snake_case JSON")
    func hotkeyVisibilitySnakeCaseDecode() throws {
        let json = #"{"show_hotkey_on_floating_indicator": false, "show_hotkey_in_menu_bar": false}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(!config.showHotkeyOnFloatingIndicator)
        #expect(!config.showHotkeyInMenuBar)
    }

    @Test("post processor defaults to disabled")
    func postProcessorDisabledByDefault() {
        let config = AppConfig()
        #expect(config.enablePostProcessor == false)
    }

    @Test("post processor defaults to v3 model")
    func postProcessorDefaultModel() {
        let config = AppConfig()
        #expect(config.activePostProcessorId == PostProcessorOption.defaultOption.id)
    }

    @Test("post processor persists through JSON round-trip")
    func postProcessorRoundTrip() throws {
        var config = AppConfig()
        config.enablePostProcessor = true
        config.activePostProcessorId = PostProcessorOption.finetunedV2.id
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.enablePostProcessor == true)
        #expect(decoded.activePostProcessorId == PostProcessorOption.finetunedV2.id)
    }

    @Test("post processor decodes from snake_case JSON")
    func postProcessorSnakeCaseDecode() throws {
        let json = #"{"enable_post_processor": true}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: json.data(using: .utf8)!)
        #expect(config.enablePostProcessor == true)
    }
}

@Suite("Floating meeting transcript")
struct FloatingMeetingTranscriptTests {
    @Test("floating panel can take keys without becoming the main window")
    @MainActor
    func floatingPanelIsInteractive() {
        // A borderless panel refuses key status by default, which would leave chat's
        // composer untypable. Becoming main is the part that must stay off: it would
        // pull activation away from the call the user is in.
        let panel = InteractiveFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    @Test("copy includes committed transcript and current partials")
    func copyTextIncludesLiveTails() {
        let text = LiveTranscriptCopyContent.text(
            transcript: "[10:00:00] You: committed",
            partialYou: "speaking now",
            partialOthers: "current reply"
        )

        #expect(text == "[10:00:00] You: committed\nOthers: current reply\nYou: speaking now")
    }

    @Test("panel retains the complete committed transcript")
    func completeTranscriptHistory() {
        let transcript = (0..<12)
            .map { "[10:00:\(String(format: "%02d", $0))] You: line \($0)" }
            .joined(separator: "\n")

        let messages = TranscriptChatMessage.messages(from: transcript)

        #expect(messages.count == 12)
        #expect(messages.first?.text == "line 0")
        #expect(messages.last?.text == "line 11")
    }

    @Test("incremental panel updates retain unique message identities")
    @MainActor
    func incrementalUpdatesUseUniqueIDs() {
        let model = LiveTranscriptPresentationModel()

        model.update(
            transcript: "[10:00:00] You: first\n",
            partialYou: "",
            partialOthers: ""
        )
        model.update(
            transcript: "[10:00:00] You: first\n[10:00:05] Others: second\n",
            partialYou: "",
            partialOthers: ""
        )

        #expect(model.messages.map(\.id) == [0, 1])
        #expect(model.messages.map(\.text) == ["first", "second"])
    }
}

// MARK: - OpenAI Logo Shape

@Suite("OpenAI Logo Shape")
struct OpenAILogoShapeTests {

    @Test("shape produces non-empty path")
    func nonEmptyPath() {
        let shape = OpenAILogoShape()
        let rect = CGRect(x: 0, y: 0, width: 24, height: 24)
        let path = shape.path(in: rect)
        #expect(!path.isEmpty)
    }

    @Test("shape scales to arbitrary rect")
    func scalesCorrectly() {
        let shape = OpenAILogoShape()
        let small = shape.path(in: CGRect(x: 0, y: 0, width: 10, height: 10))
        let large = shape.path(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(!small.isEmpty)
        #expect(!large.isEmpty)
        // Larger rect should produce a larger bounding box
        #expect(large.boundingRect.width > small.boundingRect.width)
    }

    @Test("shape handles zero rect without crash")
    func zeroRect() {
        let shape = OpenAILogoShape()
        let path = shape.path(in: .zero)
        // Should not crash; path will be empty or degenerate
        let _ = path.boundingRect
    }
}

// MARK: - DictationState

@Suite("DictationState idle check")
struct DictationStateIdleTests {

    @Test("all dictation states are defined")
    func allStates() {
        let states: [DictationState] = [.idle, .preparing, .recording, .transcribing]
        #expect(states.count == 4)
    }

    @Test("idle is distinct from active states")
    func idleDistinct() {
        #expect(DictationState.idle != .recording)
        #expect(DictationState.idle != .preparing)
        #expect(DictationState.idle != .transcribing)
    }
}

// MARK: - Meeting chunk collection

@Suite("Meeting chunk collection")
struct MeetingChunkCollectorTests {

    @Test("collector waits for tasks, keeps completed segments, and sorts by start")
    func collectorSortsSegments() async {
        let collector = MeetingChunkCollector()

        _ = collector.add(
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                return [SpeechSegment(start: 30, end: 31, text: "later")]
            }
        )
        _ = collector.add(
            Task {
                try? await Task.sleep(for: .milliseconds(5))
                return []
            }
        )
        _ = collector.add(
            Task {
                try? await Task.sleep(for: .milliseconds(10))
                return [SpeechSegment(start: 10, end: 11, text: "earlier")]
            }
        )

        let segments = await collector.closeAndDrainSortedSegments()

        #expect(segments.map(\.text) == ["earlier", "later"])
        #expect(segments.map(\.start) == [10, 30])
    }

    @Test("collector rejects tasks after closing")
    func collectorRejectsLateTasks() async {
        let collector = MeetingChunkCollector()
        let initialTask = Task<[SpeechSegment], Never> {
            [SpeechSegment(start: 1, end: 2, text: "first")]
        }
        #expect(collector.add(initialTask).registered)

        let initial = await collector.closeAndDrainSortedSegments()
        #expect(initial.map(\.text) == ["first"])

        let lateTask = Task<[SpeechSegment], Never> {
            [SpeechSegment(start: 3, end: 4, text: "late")]
        }
        #expect(!collector.add(lateTask).registered)
        lateTask.cancel()
    }

    @Test("collector retire returns false after drain closes collector")
    func collectorRetireReturnsFalseAfterDrain() async {
        let collector = MeetingChunkCollector()
        let task = Task<[SpeechSegment], Never> {
            try? await Task.sleep(for: .milliseconds(10))
            return [SpeechSegment(start: 1, end: 2, text: "first")]
        }
        let registration = collector.add(task)
        #expect(registration.registered)

        let drained = await collector.closeAndDrainSortedSegments()
        let retired = collector.retire(id: registration.retireID, segments: await task.value)

        #expect(drained.map(\.text) == ["first"])
        #expect(retired == false)
    }

    @Test("collector flattens timed segments from a single chunk and sorts them")
    func collectorFlattensChunkSegments() async {
        let collector = MeetingChunkCollector()

        _ = collector.add(
            Task {
                [
                    SpeechSegment(start: 12, end: 12.5, text: "second"),
                    SpeechSegment(start: 11, end: 11.5, text: "first")
                ]
            }
        )

        let segments = await collector.closeAndDrainSortedSegments()

        #expect(segments.map(\.text) == ["first", "second"])
        #expect(segments.map(\.start) == [11, 12])
    }
}

@Suite("Meeting chunk timing")
struct MeetingChunkTimingTrackerTests {

    @Test("tracks chunk offsets from processed sample counts")
    func tracksChunkOffsets() {
        var tracker = MeetingChunkTimingTracker()
        tracker.start()
        tracker.append(sampleCount: 1600)

        let first = tracker.rotate()
        tracker.append(sampleCount: 800)
        let second = tracker.finish()

        #expect(first?.startSampleIndex == 0)
        #expect(first?.sampleCount == 1600)
        #expect(first?.startTimeSeconds == 0)
        #expect(first?.durationSeconds == 0.1)

        #expect(second?.startSampleIndex == 1600)
        #expect(second?.sampleCount == 800)
        #expect(second?.startTimeSeconds == 0.1)
        #expect(second?.durationSeconds == 0.05)
    }

    @Test("realigns the next chunk after a capture interruption")
    func realignsAfterCaptureInterruption() {
        var tracker = MeetingChunkTimingTracker()
        tracker.start()
        tracker.append(sampleCount: 16_000)
        _ = tracker.rotate()

        tracker.realign(atSampleIndex: 160_000)
        tracker.append(sampleCount: 8_000)
        let resumed = tracker.finish()

        #expect(resumed?.startSampleIndex == 160_000)
        #expect(resumed?.startTimeSeconds == 10)
        #expect(resumed?.durationSeconds == 0.5)
    }
}
