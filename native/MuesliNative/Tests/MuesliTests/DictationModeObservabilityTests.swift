import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Dictation style observability")
struct DictationModeObservabilityTests {
    private let sources: [DictationStyleSelectionSource] = [
        .exception, .group, .global, .builtInFallback,
    ]

    @Test("telemetry uses one coarse allowlist for every style and outcome")
    func exhaustiveAllowlist() {
        for source in sources {
            for isCustom in [false, true] {
                for outcome in DictationCleanupOutcome.allCases {
                    for backend in TranscriptCleanupBackendOption.all {
                        let parameters = DictationModeObservability.parameters(
                            for: DictationModeObservabilityInput(
                                selectionSource: source,
                                usedMode: isCustom,
                                cleanupOutcome: outcome,
                                cleanupBackend: backend
                            )
                        )

                        #expect(Set(parameters.keys) == DictationModeObservability.parameterKeys)
                        #expect(parameters["style_selection_source"] == source.rawValue)
                        #expect(parameters["style_class"] == (isCustom ? "mode" : "default"))
                        #expect(parameters["cleanup_outcome"] == outcome.rawValue)
                        #expect(parameters["cleanup_backend"] == backend.backend)
                    }
                }
            }
        }
    }

    @Test("telemetry allowlist has no identity or content keys")
    func excludesSensitiveKeys() {
        let parameters = DictationModeObservability.parameters(
            for: DictationModeObservabilityInput(
                selectionSource: .exception,
                usedMode: true,
                cleanupOutcome: .fallbackError,
                cleanupBackend: .hosted(.openAI)
            )
        )

        #expect(Set(parameters.keys) == DictationModeObservability.parameterKeys)
        let prohibitedFragments = [
            "bundle", "host", "app_name", "style_id", "style_name", "prompt",
            "transcript", "url", "selected_text", "ocr", "context",
        ]
        #expect(!parameters.keys.contains { key in prohibitedFragments.contains { key.contains($0) } })
    }

    @Test("missing style provenance stays coarse")
    func missingProvenance() {
        let parameters = DictationModeObservability.parameters(
            for: DictationModeObservabilityInput(
                selectionSource: nil,
                usedMode: nil,
                cleanupOutcome: .skippedStreaming,
                cleanupBackend: .local
            )
        )

        #expect(parameters["style_selection_source"] == "none")
        #expect(parameters["style_class"] == "none")
        #expect(parameters["cleanup_outcome"] == "skipped_streaming")
    }

    @Test("local debug log remains opt-in, bounded, and provenance-rich")
    func localDebugLogContract() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-observability-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("cleanup.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let selection = DictationStyleSelectionResult(
            styleID: "private-style-id",
            styleName: "Private Style Name",
            prompt: "private prompt",
            isCustom: true,
            source: .group,
            categoryID: "messages",
            groupID: "stable-group-id"
        )
        let provenance = DictationCleanupStyleProvenance(selection: selection)
        let longText = String(repeating: "x", count: TranscriptCleanupDebugLogger.maxLoggedTextCharacters + 10)

        TranscriptCleanupDebugLogger.append(
            status: "applied",
            cleanupBackend: .local,
            cleanupModel: "model",
            asrBackend: "fluidaudio",
            cleanupOutcome: .applied,
            styleProvenance: provenance,
            rawASRText: longText,
            environment: [:],
            logURL: logURL
        )
        #expect(!FileManager.default.fileExists(atPath: logURL.path))

        let enabled = ["MUESLI_LOG_TRANSCRIPT_CLEANUP_DEBUG": "1"]
        TranscriptCleanupDebugLogger.append(
            status: "applied",
            cleanupBackend: .local,
            cleanupModel: "model",
            asrBackend: "fluidaudio",
            cleanupOutcome: .applied,
            styleProvenance: provenance,
            appContextText: "private context",
            rawASRText: longText,
            cleanupOutputText: "cleaned",
            environment: enabled,
            logURL: logURL
        )
        TranscriptCleanupDebugLogger.append(
            status: "fallback_error",
            cleanupBackend: .local,
            cleanupModel: "model",
            asrBackend: "fluidaudio",
            cleanupOutcome: .fallbackError,
            styleProvenance: provenance,
            rawASRText: "raw",
            errorDescription: "provider failed",
            environment: enabled,
            logURL: logURL
        )

        let entries = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(TranscriptCleanupDebugLogger.Entry.self, from: Data($0.utf8)) }
        #expect(entries.map(\.cleanupOutcome) == ["applied", "fallback_error"])
        #expect(entries.allSatisfy { $0.selectedStyleID == "private-style-id" })
        #expect(entries.allSatisfy { $0.styleSelectionSource == "group" })
        #expect(entries.allSatisfy { $0.styleModeID == "stable-group-id" })
        #expect(entries[0].rawASRText.hasSuffix("...[truncated]"))
    }

    @Test("debug log keeps the existing five megabyte rotation threshold")
    func rotationThreshold() {
        #expect(!TranscriptCleanupDebugLogger.shouldRotate(
            fileSize: TranscriptCleanupDebugLogger.maxLogFileBytes
        ))
        #expect(TranscriptCleanupDebugLogger.shouldRotate(
            fileSize: TranscriptCleanupDebugLogger.maxLogFileBytes + 1
        ))
    }
}
