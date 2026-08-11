import Foundation

struct DictationStyleObservabilityInput {
    let selectionSource: DictationStyleSelectionSource?
    let isCustomStyle: Bool?
    let cleanupOutcome: DictationCleanupOutcome
    let cleanupBackend: TranscriptCleanupBackendOption
}

enum DictationStyleObservability {
    private enum Key {
        static let selectionSource = "style_selection_source"
        static let styleClass = "style_class"
        static let cleanupOutcome = "cleanup_outcome"
        static let cleanupBackend = "cleanup_backend"
    }

    static let parameterKeys: Set<String> = [
        Key.selectionSource,
        Key.styleClass,
        Key.cleanupOutcome,
        Key.cleanupBackend,
    ]

    static func parameters(for input: DictationStyleObservabilityInput) -> [String: String] {
        [
            Key.selectionSource: input.selectionSource?.rawValue ?? "none",
            Key.styleClass: input.isCustomStyle.map { $0 ? "custom" : "built_in" } ?? "none",
            Key.cleanupOutcome: input.cleanupOutcome.rawValue,
            Key.cleanupBackend: input.cleanupBackend.backend,
        ]
    }
}
