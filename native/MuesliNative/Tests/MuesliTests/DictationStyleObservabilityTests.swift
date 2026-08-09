import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Dictation style observability")
struct DictationStyleObservabilityTests {
    private let sources: [DictationStyleSelectionSource] = [
        .domain, .app, .category, .global, .builtInFallback,
    ]

    @Test("telemetry uses one coarse allowlist for every style and outcome")
    func exhaustiveAllowlist() {
        for source in sources {
            for isCustom in [false, true] {
                for outcome in DictationCleanupOutcome.allCases {
                    for backend in TranscriptCleanupBackendOption.all {
                        let parameters = DictationStyleObservability.parameters(
                            for: DictationStyleObservabilityInput(
                                selectionSource: source,
                                isCustomStyle: isCustom,
                                cleanupOutcome: outcome,
                                cleanupBackend: backend
                            )
                        )

                        #expect(Set(parameters.keys) == DictationStyleObservability.parameterKeys)
                        #expect(parameters["style_selection_source"] == source.rawValue)
                        #expect(parameters["style_class"] == (isCustom ? "custom" : "built_in"))
                        #expect(parameters["cleanup_outcome"] == outcome.rawValue)
                        #expect(parameters["cleanup_backend"] == backend.backend)
                    }
                }
            }
        }
    }

    @Test("telemetry ignores every identity and content field")
    func excludesSensitiveInput() {
        let secret = "must-not-leave-device"
        let parameters = DictationStyleObservability.parameters(
            for: DictationStyleObservabilityInput(
                selectionSource: .domain,
                isCustomStyle: true,
                cleanupOutcome: .fallbackError,
                cleanupBackend: .hosted(.openAI),
                bundleID: secret,
                hostname: secret,
                appName: secret,
                styleID: secret,
                styleName: secret,
                prompt: secret,
                transcript: secret,
                url: secret,
                selectedText: secret,
                ocrText: secret
            )
        )

        #expect(Set(parameters.keys) == DictationStyleObservability.parameterKeys)
        #expect(!parameters.keys.contains { $0.contains("bundle") || $0.contains("host") })
        #expect(!parameters.values.contains(secret))
    }

    @Test("missing style provenance stays coarse")
    func missingProvenance() {
        let parameters = DictationStyleObservability.parameters(
            for: DictationStyleObservabilityInput(
                selectionSource: nil,
                isCustomStyle: nil,
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
            source: .app,
            categoryID: "messages"
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
        #expect(entries.allSatisfy { $0.styleSelectionSource == "app" })
        #expect(entries.allSatisfy { $0.styleCategoryID == "messages" })
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
