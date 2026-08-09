import Foundation

struct DictationStyleObservabilityInput {
    let selectionSource: DictationStyleSelectionSource?
    let isCustomStyle: Bool?
    let cleanupOutcome: DictationCleanupOutcome
    let cleanupBackend: TranscriptCleanupBackendOption
}

enum DictationStyleObservability {
    static let parameterKeys: Set<String> = [
        "style_selection_source",
        "style_class",
        "cleanup_outcome",
        "cleanup_backend",
    ]

    static func parameters(for input: DictationStyleObservabilityInput) -> [String: String] {
        [
            "style_selection_source": input.selectionSource?.rawValue ?? "none",
            "style_class": input.isCustomStyle.map { $0 ? "custom" : "built_in" } ?? "none",
            "cleanup_outcome": input.cleanupOutcome.rawValue,
            "cleanup_backend": input.cleanupBackend.backend,
        ]
    }
}
