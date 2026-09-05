import Foundation

/// The content-free shape of one dictation's cleanup outcome.
///
/// `modeClass` replaces the old custom-vs-built-in split: what matters now is
/// whether a mode applied at all, and the mode's own id and name never leave
/// the device, so nothing here can carry a user-authored string.
struct DictationModeObservabilityInput {
    let selectionSource: DictationStyleSelectionSource?
    let usedMode: Bool?
    let cleanupOutcome: DictationCleanupOutcome
    let cleanupBackend: TranscriptCleanupBackendOption
}

enum DictationModeObservability {
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

    static func parameters(for input: DictationModeObservabilityInput) -> [String: String] {
        [
            Key.selectionSource: input.selectionSource?.rawValue ?? "none",
            Key.styleClass: input.usedMode.map { $0 ? "mode" : "default" } ?? "none",
            Key.cleanupOutcome: input.cleanupOutcome.rawValue,
            Key.cleanupBackend: input.cleanupBackend.backend,
        ]
    }
}
