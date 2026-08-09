import Foundation

struct DictationStyleObservabilityInput {
    let selectionSource: DictationStyleSelectionSource?
    let isCustomStyle: Bool?
    let cleanupOutcome: DictationCleanupOutcome
    let cleanupBackend: TranscriptCleanupBackendOption

    // Deliberately accepted so the allowlist boundary can prove these values are
    // ignored even when a caller has them in scope.
    let bundleID: String?
    let hostname: String?
    let appName: String?
    let styleID: String?
    let styleName: String?
    let prompt: String?
    let transcript: String?
    let url: String?
    let selectedText: String?
    let ocrText: String?

    init(
        selectionSource: DictationStyleSelectionSource?,
        isCustomStyle: Bool?,
        cleanupOutcome: DictationCleanupOutcome,
        cleanupBackend: TranscriptCleanupBackendOption,
        bundleID: String? = nil,
        hostname: String? = nil,
        appName: String? = nil,
        styleID: String? = nil,
        styleName: String? = nil,
        prompt: String? = nil,
        transcript: String? = nil,
        url: String? = nil,
        selectedText: String? = nil,
        ocrText: String? = nil
    ) {
        self.selectionSource = selectionSource
        self.isCustomStyle = isCustomStyle
        self.cleanupOutcome = cleanupOutcome
        self.cleanupBackend = cleanupBackend
        self.bundleID = bundleID
        self.hostname = hostname
        self.appName = appName
        self.styleID = styleID
        self.styleName = styleName
        self.prompt = prompt
        self.transcript = transcript
        self.url = url
        self.selectedText = selectedText
        self.ocrText = ocrText
    }
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
