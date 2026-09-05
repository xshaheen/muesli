import AppKit
import Foundation
import MuesliCore

struct BackendOption: Equatable {
    struct Catalog {
        let systemManaged: [BackendOption]
        let all: [BackendOption]
        let onboardingDefault: BackendOption
        let onboarding: [BackendOption]
    }

    let backend: String
    let model: String
    let label: String
    let sizeLabel: String
    let description: String
    let recommended: Bool

    static let parakeetUnified = BackendOption(
        backend: "parakeet-unified",
        model: "FluidInference/parakeet-unified-en-0.6b-coreml",
        label: "Parakeet Unified",
        sizeLabel: "~565 MB",
        description: "The newest Parakeet generation and the best choice for English dictation: a lower error rate than Parakeet v3 with a newer architecture. English-focused; pick Parakeet v3 for multilingual needs.",
        recommended: true
    )

    static let parakeetMultilingual = BackendOption(
        backend: "fluidaudio",
        model: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        label: "Parakeet v3",
        sizeLabel: "~450 MB",
        description: "The multilingual Parakeet: quick enough to feel responsive, reliable in normal rooms, and able to follow 25 languages.",
        recommended: false
    )

    static let parakeetEnglish = BackendOption(
        backend: "fluidaudio",
        model: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
        label: "Parakeet v2",
        sizeLabel: "~450 MB",
        description: "A quick, dependable English-only option. Choose it if you mainly dictate in English and prefer the older Parakeet model.",
        recommended: false
    )

    static let whisperSmall = BackendOption(
        backend: "whisper",
        model: "small",
        label: "Whisper Small Multilingual",
        sizeLabel: "~250 MB",
        description: "A balanced multilingual Whisper option for everyday notes. It handles accents and background noise better than Tiny while keeping the download modest. Auto-detect language by default, or choose one yourself.",
        recommended: false
    )

    static let whisperTiny = BackendOption(
        backend: "whisper",
        model: "tiny",
        label: "Whisper Tiny Multilingual",
        sizeLabel: "~153 MB",
        description: "The quickest Whisper download and lightest multilingual option for occasional notes. It gives up some accuracy on accents, noise, and longer speech. Auto-detect language by default, or choose one yourself.",
        recommended: false
    )

    static let whisperLargeTurbo = BackendOption(
        backend: "whisper",
        model: "large-v3-v20240930_626MB",
        label: "Whisper Large Turbo Multilingual",
        sizeLabel: "~626 MB",
        description: "Whisper's strongest multilingual option. It auto-detects language by default, or you can pin one. Better for mixed languages and difficult audio, with a larger download and more processing time than Small.",
        recommended: false
    )

    static let whisperTinyEnglish = BackendOption(
        backend: "whisper",
        model: "tiny.en",
        label: "Whisper Tiny English",
        sizeLabel: "~153 MB",
        description: "The quickest English-only Whisper option for lightweight notes. Choose it when you always speak English and do not need automatic language detection.",
        recommended: false
    )

    static let whisperSmallEnglish = BackendOption(
        backend: "whisper",
        model: "small.en",
        label: "Whisper Small English",
        sizeLabel: "~250 MB",
        description: "A balanced English-only Whisper option for everyday dictation. It handles accents and background noise better than Tiny when you do not need other languages.",
        recommended: false
    )

    static let whisperMediumEnglish = BackendOption(
        backend: "whisper",
        model: "medium.en",
        label: "Whisper Medium English",
        sizeLabel: "~1.5 GB",
        description: "A larger English-only Whisper option for difficult accents and noisier recordings. It favors accuracy over download size and speed.",
        recommended: false
    )

    static let nemotron35Multilingual = BackendOption(
        backend: "nemotron35",
        model: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
        label: "Nemotron 3.5 Multilingual",
        sizeLabel: "~665 MB",
        description: "Live text appears as you speak in more than 100 locales, including Hindi, Chinese, and Japanese, with language auto-detection and punctuation. It works for hold-to-talk, hands-free dictation, and meetings. For meetings, its continuous transcript can also become the final raw transcript or be paired with a separate final model. It only appends words—it does not go back to correct earlier text.",
        recommended: false
    )

    static let cohereTranscribe = BackendOption(
        backend: "cohere",
        model: "phequals/cohere-transcribe-coreml-mixed-precision",
        label: "Cohere Transcribe",
        sizeLabel: "~3.8 GB",
        description: "The most deliberate option for difficult accents and tricky audio. It supports 14 languages and can be more accurate than faster models, but the download is large and you only see the result after you stop speaking.",
        recommended: false
    )

    static let indicASR = BackendOption(
        backend: "indicasr",
        model: "phequals/indic-conformer-600m-multilingual-coreml-rnnt",
        label: "Indic ASR",
        sizeLabel: "~618 MB",
        description: "Built specifically for seven Indian languages. Choose your language before recording; it can help where general multilingual models struggle, but results still vary enough to keep it experimental.",
        recommended: false
    )

    static let senseVoiceSmall = BackendOption(
        backend: "sensevoice",
        model: "FluidInference/sensevoice-small-coreml",
        label: "SenseVoice Small",
        sizeLabel: SenseVoiceTranscriber.downloadedModelSizeLabel,
        description: "A compact option covering more than 50 languages, with punctuation included in the result. Quality varies by language and accent, so try it with your own voice before relying on it.",
        recommended: false
    )

    static let gemma4E2BLiteRT = BackendOption(
        backend: "gemma4-litert",
        model: Gemma4LiteRTModel.e2b.repoID,
        label: Gemma4LiteRTModel.e2b.label,
        sizeLabel: Gemma4LiteRTModel.e2b.sizeLabel,
        description: "A research preview, not a dependable dictation model yet. It is large, slow to get ready, requires macOS 15 or later, and may produce an answer instead of a faithful transcript.",
        recommended: false
    )

    static let gemma4E4BLiteRT = BackendOption(
        backend: "gemma4-litert",
        model: Gemma4LiteRTModel.e4b.repoID,
        label: Gemma4LiteRTModel.e4b.label,
        sizeLabel: Gemma4LiteRTModel.e4b.sizeLabel,
        description: "A larger experimental Gemma 4 model for higher-quality local transcription and rewriting. It requires macOS 15 or later and trades additional download size and memory for stronger instruction following.",
        recommended: false
    )

    static func gemma4LiteRT(_ model: Gemma4LiteRTModel) -> BackendOption {
        switch model {
        case .e2b: .gemma4E2BLiteRT
        case .e4b: .gemma4E4BLiteRT
        }
    }

    static let appleSpeechAnalyzer = BackendOption(
        backend: "apple-speech",
        model: "apple-speech-transcriber",
        label: "Apple Speech",
        sizeLabel: "System managed",
        description: "Apple's private, on-device speech model for macOS 26. It is designed for dictation, meetings, distant speakers, and long recordings, while macOS manages the language assets and updates.",
        recommended: false
    )

    // Default alias
    static let whisper = parakeetMultilingual

    static let parakeetFamily: [BackendOption] = [
        .parakeetUnified, .parakeetMultilingual, .parakeetEnglish,
    ]

    static let whisperFamily: [BackendOption] = [
        .whisperTiny, .whisperTinyEnglish,
        .whisperSmall, .whisperSmallEnglish,
        .whisperMediumEnglish, .whisperLargeTurbo,
    ]

    static let experimental: [BackendOption] = [
        .senseVoiceSmall, .indicASR, .gemma4E2BLiteRT, .gemma4E4BLiteRT,
    ]

    /// Native streaming backends used by low-latency product surfaces.
    /// Meeting-only helpers such as Parakeet Realtime EOU are managed by their
    /// dedicated model store and displayed alongside these options in Models.
    static let streaming: [BackendOption] = [
        .nemotron35Multilingual,
    ]

    static func catalog(appleSpeechAvailable: Bool) -> Catalog {
        let systemManaged: [BackendOption] = appleSpeechAvailable ? [.appleSpeechAnalyzer] : []
        let all = systemManaged
            + parakeetFamily
            + whisperFamily
            + [.cohereTranscribe]
            + streaming
            + experimental
        let onboardingDefault = systemManaged.first ?? .parakeetUnified
        let onboardingCandidates: [BackendOption] = [
            onboardingDefault,
            .parakeetUnified,
            .parakeetMultilingual,
            .whisperTiny,
            .whisperSmall,
            .cohereTranscribe,
            .nemotron35Multilingual,
        ]
        let onboarding = onboardingCandidates.reduce(into: [BackendOption]()) { options, option in
            if !options.contains(option) {
                options.append(option)
            }
        }

        return Catalog(
            systemManaged: systemManaged,
            all: all,
            onboardingDefault: onboardingDefault,
            onboarding: onboarding
        )
    }

    private static let currentCatalog: Catalog = {
        if #available(macOS 26.0, *), AppleSpeechAnalyzerTranscriber.isSupportedOnCurrentSystem {
            return catalog(appleSpeechAvailable: true)
        }
        return catalog(appleSpeechAvailable: false)
    }()

    static let systemManaged = currentCatalog.systemManaged

    /// Models available for download and use.
    static let all = currentCatalog.all

    /// The first-run default uses the system-managed backend when the OS exposes it.
    /// Parakeet remains the deterministic fallback for older or unsupported Macs.
    static let onboardingDefault = currentCatalog.onboardingDefault

    /// Curated first-run choices. Experimental models are excluded by default.
    static let onboarding = currentCatalog.onboarding

    /// Models coming soon — shown greyed out in the Models tab.
    static let comingSoon: [BackendOption] = []

    /// Only models that have been downloaded and are ready for inference.
    static var downloaded: [BackendOption] {
        all.filter { $0.isDownloaded }
    }

    /// Models that can keep up with post-meeting and imported recording transcription.
    static var downloadedMeetingTranscription: [BackendOption] {
        downloaded.filter(\.supportsMeetingTranscription)
    }

    static func resolve(backend: String, model: String) -> BackendOption? {
        all.first {
            $0.backend == backend && $0.model == model
        }
    }

    var isStreamingDictationBackend: Bool {
        Self.streaming.contains(self)
    }

    var supportsMeetingTranscription: Bool {
        !isStreamingDictationBackend
    }

    var isSystemManaged: Bool {
        backend == "apple-speech"
    }

    /// Multilingual WhisperKit models expose language selection (auto-detect or pinned code).
    /// English-only `.en` variants do not.
    var supportsWhisperLanguageSelection: Bool {
        backend == "whisper" && !WhisperKitLanguage.isEnglishOnlyModel(model)
    }

    var transcriptionBackendID: TranscriptionBackendID {
        TranscriptionBackendID(provider: backend, model: model)
    }

    func languageCapabilities(isAvailable: Bool? = nil) -> TranscriptionBackendCapabilities {
        let supported: Set<TranscriptionLanguage>
        let supportsAuto: Bool
        let supportsSingle: Bool
        let fixedLanguage: TranscriptionLanguage?
        var fallbackLanguage: TranscriptionLanguage?

        if self == .parakeetEnglish
            || (backend == "whisper" && WhisperKitLanguage.isEnglishOnlyModel(model)) {
            supported = [.english]
            supportsAuto = false
            supportsSingle = false
            fixedLanguage = .english
        } else {
            fixedLanguage = nil
            switch backend {
            case "whisper":
                supported = Set(TranscriptionLanguage.allCases)
                supportsAuto = true
                supportsSingle = true
            case "nemotron35":
                supported = Set(TranscriptionLanguage.allCases.filter {
                    Nemotron35Language(rawValue: $0.rawValue) != nil
                })
                supportsAuto = true
                supportsSingle = true
            case "cohere":
                supported = Set(TranscriptionLanguage.allCases.filter {
                    CohereTranscribeLanguage(rawValue: $0.rawValue) != nil
                })
                supportsAuto = false
                supportsSingle = true
                fallbackLanguage = .english  // CohereTranscribeLanguage.defaultLanguage
            case "indicasr":
                supported = Set(TranscriptionLanguage.allCases.filter {
                    IndicASRLanguage(rawValue: $0.rawValue) != nil
                })
                supportsAuto = false
                supportsSingle = true
                fallbackLanguage = .hindi  // IndicASRLanguage.defaultLanguage
            default:
                supported = Set(TranscriptionLanguage.allCases)
                supportsAuto = true
                supportsSingle = false
            }
        }

        var workloads: Set<TranscriptionWorkload> = [.dictation, .cli]
        if supportsMeetingTranscription {
            workloads.formUnion([.meetingFinal, .fileImport, .retranscription])
        }
        if isStreamingDictationBackend {
            workloads.insert(.meetingLive)
        }

        return TranscriptionBackendCapabilities(
            backendID: transcriptionBackendID,
            supportedLanguages: supported,
            supportsAutomaticDetection: supportsAuto,
            supportsSingleLanguage: supportsSingle,
            // Whisper candidate decoding stays disabled until the score contract
            // in docs/plans/2026-08-19-002-feat-language-aware-transcription-fluidaudio-upgrade-plan.md
            // is proven; the dominant-pin and automatic arms cover mixed selections.
            constrainedCandidateLanguages: [],
            constrainedCandidateCapacity: 0,
            hasComparableCandidateConfidence: false,
            fixedLanguage: fixedLanguage,
            fallbackLanguage: fallbackLanguage,
            supportsCodeSwitching: supportsAuto,
            maximumSafeDuration: nil,
            supportsStreaming: isStreamingDictationBackend,
            workloads: workloads,
            isAvailable: isAvailable ?? self.isDownloaded
        )
    }

    static func resolveDownloaded(
        backend: String,
        model: String,
        fallback: BackendOption?,
        downloadedOptions: [BackendOption]
    ) -> BackendOption? {
        // Availability must never rewrite a known persisted model identity.
        // Runtime preflight and presentation report the unavailable state.
        if let selected = resolve(backend: backend, model: model) {
            return selected
        }
        if let fallback,
           downloadedOptions.contains(where: { $0.backend == fallback.backend && $0.model == fallback.model }) {
            return fallback
        }
        return downloadedOptions.first
    }

    /// Check if this model's files exist on disk.
    var isDownloaded: Bool {
        let fm = FileManager.default
        switch backend {
        case "whisper":
            return WhisperKitTranscriber.isModelDownloaded(model)
        case "fluidaudio":
            let plan = model.contains("v2")
                ? ManagedASRModelPlans.parakeetV2()
                : ManagedASRModelPlans.parakeetV3()
            return plan.isAvailableLocally(fileManager: fm)
        case "parakeet-unified":
            return ManagedASRModelPlans.parakeetUnified().isAvailableLocally(fileManager: fm)
        case "nemotron35":
            return Nemotron35ModelStore.isModelDownloaded(fileManager: fm)
        case "cohere":
            return CohereTranscribeModelStore.isAvailableLocally()
        case "indicasr":
            return IndicASRModelStore.isAvailableLocally()
        case "sensevoice":
            return SenseVoiceTranscriber.isModelDownloaded(fileManager: fm)
        case "gemma4-litert":
            return Gemma4LiteRTModelStore.isAvailableLocally(model: Gemma4LiteRTModel.resolved(model))
        case "apple-speech":
            if #available(macOS 26.0, *) {
                return AppleSpeechAnalyzerTranscriber.isSupportedOnCurrentSystem
            }
            return false
        default:
            return false
        }
    }
}

struct LanguageSelectionPresentation: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case automatic
        case pinned
        case constrained
        case fixed
        /// The backend runs, but not as the selection asked; `degradation` says how.
        case degraded
        case incompatible
        case unavailable
    }

    let state: State
    let backendID: TranscriptionBackendID
    let selectedLanguageIDs: [String]
    let routingIdentifier: String
    let degradation: LanguageRoutingDegradation?
    let explanation: String
}

extension SpokenLanguageProfile {
    func presentation(
        for backend: BackendOption,
        workload: TranscriptionWorkload = .dictation,
        isAvailable: Bool? = nil
    ) -> LanguageSelectionPresentation {
        let capabilities = backend.languageCapabilities(isAvailable: isAvailable)
        let selection = selection
        let decision = TranscriptionLanguageRouter.resolve(
            selection: selection,
            capabilities: capabilities,
            workload: workload
        )
        let degradation = decision.degradation(for: selection)
        let state: LanguageSelectionPresentation.State
        let explanation: String
        switch (decision, degradation) {
        case (_, .notPinned(let language)?):
            state = .degraded
            explanation = "\(backend.label) cannot pin \(language.label), so it will detect the spoken language automatically."
        case (_, .providerFallback(let fallback)?):
            state = .degraded
            if let requested = selection.authoritativeLanguage {
                explanation = "\(backend.label) does not support \(requested.label) and will transcribe in \(fallback.label). Choose a supported language to change this."
            } else {
                explanation = "\(backend.label) cannot detect languages automatically and will transcribe in \(fallback.label). Choose a dominant language to change this."
            }
        case (.fixed(let fixedLanguage), .fixedLanguageIgnoresSelection(let ignored)?):
            state = .degraded
            explanation = "\(backend.label) always transcribes in \(fixedLanguage.label) and ignores \(ignored.label) in this selection."
        case (_, .fixedLanguageIgnoresSelection(let ignored)?):
            state = .degraded
            explanation = "\(backend.label) always transcribes in its fixed language and ignores \(ignored.label) in this selection."
        case (.automatic, nil):
            state = .automatic
            explanation = selectedLanguages.count >= 2
                ? "The selected model will detect the spoken language among \(Self.joinedLabels(selectedLanguages))."
                : "The selected model will detect the spoken language automatically."
        case (.pinned(let language), nil):
            state = .pinned
            let accepted = selectedLanguages.filter { $0 != language }
            explanation = accepted.isEmpty
                ? "The selected model will transcribe in \(language.label)."
                : "The selected model will transcribe in \(language.label); \(Self.joinedLabels(accepted)) also accepted."
        case (.constrainedCandidates(let languages, _), nil):
            state = .constrained
            explanation = "The selected model will consider only \(Self.joinedLabels(languages))."
        case (.fixed(let language), nil):
            state = .fixed
            explanation = "This model always transcribes in \(language.label)."
        case (.incompatible(.backendUnavailable), nil):
            state = .unavailable
            explanation = "\(backend.label) remains selected but is unavailable. Download it before transcribing."
        case (.incompatible(.unsupportedWorkload(let unsupported)), nil):
            state = .incompatible
            explanation = unsupported == .meetingLive
                ? "\(backend.label) does not provide live meeting captions."
                : "\(backend.label) does not transcribe meetings."
        case (.incompatible, nil):
            // Reachable only with capabilities that advertise neither automatic
            // detection nor a fallback language; no app backend does.
            state = .incompatible
            explanation = "\(backend.label) cannot honor this language selection. Choose a compatible model or language setting."
        }
        return LanguageSelectionPresentation(
            state: state,
            backendID: capabilities.backendID,
            selectedLanguageIDs: selectedLanguages.map(\.rawValue),
            routingIdentifier: decision.identifier,
            degradation: degradation,
            explanation: explanation
        )
    }

    private static func joinedLabels(_ languages: [TranscriptionLanguage]) -> String {
        let labels = languages.map(\.label)
        guard labels.count > 2 else { return labels.joined(separator: " and ") }
        return labels.dropLast().joined(separator: ", ") + " and " + labels[labels.count - 1]
    }
}

/// Language selection for the Nemotron 3.5 multilingual backend. Maps to the
/// model's `prompt_id` encoder input (from the FluidInference `metadata.json`
/// `prompt_dictionary`). `auto` (101) lets the model detect the language.
enum Nemotron35Language: String, CaseIterable, Codable, Sendable {
    case auto
    case english = "en"
    case hindi = "hi"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"
    case russian = "ru"
    case arabic = "ar"

    static let defaultLanguage: Self = .auto

    /// `prompt_id` value fed to the encoder. 101 = auto-detect.
    var promptId: Int32 {
        switch self {
        case .auto: return 101
        case .english: return 0
        case .hindi: return 6
        case .spanish: return 3
        case .french: return 8
        case .german: return 9
        case .italian: return 15
        case .portuguese: return 13
        case .chinese: return 4
        case .japanese: return 10
        case .korean: return 14
        case .russian: return 11
        case .arabic: return 7
        }
    }

    var label: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .hindi: return "Hindi"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .chinese: return "Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .russian: return "Russian"
        case .arabic: return "Arabic"
        }
    }

    static func resolved(_ rawValue: String?) -> Self {
        guard let rawValue,
              let language = Self(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return defaultLanguage
        }
        return language
    }

    static func resolvedCode(_ rawValue: String?) -> String {
        resolved(rawValue).rawValue
    }

    /// The single owner of decision-to-`prompt_id`: a pinned or fixed Nemotron
    /// language maps to its id; everything else (automatic detection, a language
    /// Nemotron lacks, candidates, incompatibilities) is auto-detect.
    static func promptId(for decision: LanguageRoutingDecision) -> Int32 {
        switch decision {
        case .pinned(let language), .fixed(let language):
            return (Self(rawValue: language.rawValue) ?? defaultLanguage).promptId
        case .automatic, .constrainedCandidates, .incompatible:
            return defaultLanguage.promptId
        }
    }
}

/// Language selection for multilingual WhisperKit models.
/// `auto` enables WhisperKit `detectLanguage`; explicit codes pin decoding language.
enum WhisperKitLanguage: String, CaseIterable, Codable, Sendable {
    case auto
    case english = "en"
    case hindi = "hi"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"
    case russian = "ru"
    case arabic = "ar"
    // WhisperKit takes the raw ISO code, so every language the app lists
    // (`TranscriptionLanguage`) is pinnable on multilingual checkpoints.
    case bengali = "bn"
    case dutch = "nl"
    case greek = "el"
    case kannada = "kn"
    case malayalam = "ml"
    case marathi = "mr"
    case polish = "pl"
    case tamil = "ta"
    case telugu = "te"
    case vietnamese = "vi"

    static let defaultLanguage: Self = .auto

    var label: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .hindi: return "Hindi"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .chinese: return "Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .russian: return "Russian"
        case .arabic: return "Arabic"
        case .bengali: return "Bengali"
        case .dutch: return "Dutch"
        case .greek: return "Greek"
        case .kannada: return "Kannada"
        case .malayalam: return "Malayalam"
        case .marathi: return "Marathi"
        case .polish: return "Polish"
        case .tamil: return "Tamil"
        case .telugu: return "Telugu"
        case .vietnamese: return "Vietnamese"
        }
    }

    static func resolved(_ rawValue: String?) -> Self {
        guard let rawValue,
              let language = Self(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return defaultLanguage
        }
        return language
    }

    static func resolvedCode(_ rawValue: String?) -> String {
        resolved(rawValue).rawValue
    }

    /// English-only WhisperKit checkpoints (e.g. `tiny.en`) have no multilingual language tokens.
    static func isEnglishOnlyModel(_ modelName: String) -> Bool {
        modelName.hasSuffix(".en")
    }

    /// Preference to apply for a loaded WhisperKit model.
    /// Returns `nil` for English-only variants so callers use default `DecodingOptions`.
    static func preferenceForLoadedModel(
        _ preference: WhisperKitLanguage,
        modelName: String
    ) -> WhisperKitLanguage? {
        isEnglishOnlyModel(modelName) ? nil : preference
    }
}

extension TranscriptionLanguage {
    var supportsMeetingOutputLanguage: Bool {
        self == .english || self == .arabic
    }
}

enum MeetingArtifactLanguagePolicy: String, CaseIterable, Codable, Sendable {
    case automatic
    case english
    case arabic

    var label: String {
        switch self {
        case .automatic: "Automatic from the meeting"
        case .english: "English"
        case .arabic: "Arabic"
        }
    }

    var explicitLanguage: TranscriptionLanguage? {
        switch self {
        case .automatic: nil
        case .english: .english
        case .arabic: .arabic
        }
    }

    /// Single owner of the artifact-policy to output-policy mapping used by the
    /// `languageProfile` and `meetingLanguageProfile` projections.
    var outputPolicy: MeetingOutputLanguagePolicy {
        switch self {
        case .automatic: .automatic
        case .english: .english
        case .arabic: .arabic
        }
    }
}

/// The output-language field of the deprecated combined `LanguageProfile`.
/// It is the artifact policy plus the legacy `dominantLanguage` case, which is
/// only ever produced by decoding the legacy `language_profile` key.
enum MeetingOutputLanguagePolicy: String, Codable, Sendable {
    case automatic
    case english
    case arabic
    @available(*, deprecated, message: "Legacy language_profile only; artifact policies name their language explicitly.")
    case dominantLanguage = "dominant_language"

    var label: String {
        switch self {
        case .automatic: "Automatic from the meeting"
        case .english: "English"
        case .arabic: "Arabic"
        case .dominantLanguage: "Use dominant Arabic or English"
        }
    }

    /// Single owner of the output-policy to artifact-policy mapping. The legacy
    /// dominant case resolves through the dominant language and collapses to
    /// automatic when that language has no meeting-output support.
    func artifactPolicy(dominantLanguage: TranscriptionLanguage?) -> MeetingArtifactLanguagePolicy {
        switch self {
        case .automatic: .automatic
        case .english: .english
        case .arabic: .arabic
        case .dominantLanguage:
            switch dominantLanguage {
            case .arabic: .arabic
            case .english: .english
            default: .automatic
            }
        }
    }
}

struct LanguageProfileEffectiveBehavior: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case automaticDetection = "automatic_detection"
        case pinned
        case providerFallback = "provider_fallback"
        case englishOnlyFallback = "english_only_fallback"
    }

    let kind: Kind
    let effectiveLanguage: TranscriptionLanguage?
    let explanation: String
}

/// The single persisted language authority for dictation and meetings.
/// An empty selection means automatic detection; a dominant language is only
/// valid when it is part of the selected set.
@available(*, deprecated, message: "Use the split dictation, meeting-spoken, and artifact-output authorities.")
struct LanguageProfile: Codable, Equatable, Sendable {
    enum ValidationError: Error, LocalizedError {
        case dominantLanguageNotSelected
        case dominantOutputRequiresDominantLanguage
        case unsupportedDominantOutputLanguage

        var errorDescription: String? {
            switch self {
            case .dominantLanguageNotSelected:
                "The dominant language must also be selected."
            case .dominantOutputRequiresDominantLanguage:
                "Choose a dominant language before using it for meeting output."
            case .unsupportedDominantOutputLanguage:
                "Dominant meeting output currently supports Arabic and English."
            }
        }
    }

    let selectedLanguages: [TranscriptionLanguage]
    let dominantLanguage: TranscriptionLanguage?
    let meetingOutputPolicy: MeetingOutputLanguagePolicy

    static let automatic = LanguageProfile(
        normalizedLanguages: [],
        dominantLanguage: nil,
        meetingOutputPolicy: .automatic
    )

    init(
        selectedLanguages: [TranscriptionLanguage],
        dominantLanguage: TranscriptionLanguage? = nil,
        meetingOutputPolicy: MeetingOutputLanguagePolicy = .automatic
    ) throws {
        let normalized = Array(Set(selectedLanguages)).sorted { $0.rawValue < $1.rawValue }
        if let dominantLanguage, !normalized.contains(dominantLanguage) {
            throw ValidationError.dominantLanguageNotSelected
        }
        if meetingOutputPolicy == .dominantLanguage, dominantLanguage == nil {
            throw ValidationError.dominantOutputRequiresDominantLanguage
        }
        if meetingOutputPolicy == .dominantLanguage,
           dominantLanguage?.supportsMeetingOutputLanguage != true {
            throw ValidationError.unsupportedDominantOutputLanguage
        }
        self.init(
            normalizedLanguages: normalized,
            dominantLanguage: dominantLanguage,
            meetingOutputPolicy: meetingOutputPolicy
        )
    }

    private init(
        normalizedLanguages: [TranscriptionLanguage],
        dominantLanguage: TranscriptionLanguage?,
        meetingOutputPolicy: MeetingOutputLanguagePolicy
    ) {
        selectedLanguages = normalizedLanguages
        self.dominantLanguage = dominantLanguage
        self.meetingOutputPolicy = meetingOutputPolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            selectedLanguages: container.decodeIfPresent(
                [TranscriptionLanguage].self,
                forKey: .selectedLanguages
            ) ?? [],
            dominantLanguage: container.decodeIfPresent(
                TranscriptionLanguage.self,
                forKey: .dominantLanguage
            ),
            meetingOutputPolicy: container.decodeIfPresent(
                MeetingOutputLanguagePolicy.self,
                forKey: .meetingOutputPolicy
            ) ?? .automatic
        )
    }

    var authoritativeLanguage: TranscriptionLanguage? {
        dominantLanguage ?? (selectedLanguages.count == 1 ? selectedLanguages[0] : nil)
    }

    static func migratingLegacyPins(
        cohere: String?,
        indicASR: String?,
        nemotron35: String?,
        whisper: String?
    ) -> (profile: LanguageProfile, needsConfirmation: Bool) {
        let selected = Set([cohere, indicASR, nemotron35, whisper].compactMap(TranscriptionLanguage.resolve))
        guard !selected.isEmpty else { return (.automatic, false) }

        let normalized = selected.sorted { $0.rawValue < $1.rawValue }
        let dominant = normalized.count == 1 ? normalized[0] : nil
        return (
            LanguageProfile(
                normalizedLanguages: normalized,
                dominantLanguage: dominant,
                meetingOutputPolicy: .automatic
            ),
            normalized.count > 1
        )
    }

    static func onboarding(
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage
    ) -> LanguageProfile {
        guard backend.backend == "cohere",
              let language = TranscriptionLanguage(rawValue: cohereLanguage.rawValue) else {
            return .automatic
        }
        return (try? LanguageProfile(
            selectedLanguages: [language],
            dominantLanguage: language
        )) ?? .automatic
    }

    var resolvedWhisperLanguage: WhisperKitLanguage {
        authoritativeLanguage.flatMap { WhisperKitLanguage(rawValue: $0.rawValue) } ?? .auto
    }

    var resolvedNemotron35Language: Nemotron35Language {
        authoritativeLanguage.flatMap { Nemotron35Language(rawValue: $0.rawValue) } ?? .auto
    }

    var resolvedCohereLanguage: CohereTranscribeLanguage {
        authoritativeLanguage.flatMap { CohereTranscribeLanguage(rawValue: $0.rawValue) }
            ?? .defaultLanguage
    }

    var resolvedIndicASRLanguage: IndicASRLanguage {
        authoritativeLanguage.flatMap { IndicASRLanguage(rawValue: $0.rawValue) }
            ?? .defaultLanguage
    }

    func effectiveBehavior(for backend: BackendOption) -> LanguageProfileEffectiveBehavior {
        if backend == .parakeetEnglish || (backend.backend == "whisper" && WhisperKitLanguage.isEnglishOnlyModel(backend.model)) {
            let incompatible = selectedLanguages.contains { $0 != .english }
            return LanguageProfileEffectiveBehavior(
                kind: incompatible ? .englishOnlyFallback : .pinned,
                effectiveLanguage: .english,
                explanation: incompatible
                    ? "This model is English-only, so it cannot honor the selected multilingual profile."
                    : "This model always transcribes in English."
            )
        }

        if let language = authoritativeLanguage {
            switch backend.backend {
            case "whisper" where WhisperKitLanguage(rawValue: language.rawValue) != nil:
                return .init(
                    kind: .pinned,
                    effectiveLanguage: language,
                    explanation: "Transcription is pinned to \(language.label)."
                )
            case "nemotron35" where Nemotron35Language(rawValue: language.rawValue) != nil:
                return .init(
                    kind: .pinned,
                    effectiveLanguage: language,
                    explanation: "Transcription is pinned to \(language.label)."
                )
            case "whisper", "nemotron35":
                return .init(
                    kind: .providerFallback,
                    effectiveLanguage: nil,
                    explanation: "This model cannot pin \(language.label), so it will detect the language automatically."
                )
            case "cohere" where CohereTranscribeLanguage(rawValue: language.rawValue) != nil:
                return .init(
                    kind: .pinned,
                    effectiveLanguage: language,
                    explanation: "Transcription is pinned to \(language.label)."
                )
            case "indicasr" where IndicASRLanguage(rawValue: language.rawValue) != nil:
                return .init(
                    kind: .pinned,
                    effectiveLanguage: language,
                    explanation: "Transcription is pinned to \(language.label)."
                )
            case "cohere":
                return .init(
                    kind: .providerFallback,
                    effectiveLanguage: .english,
                    explanation: "Cohere does not support \(language.label); it will use English."
                )
            case "indicasr":
                return .init(
                    kind: .providerFallback,
                    effectiveLanguage: .hindi,
                    explanation: "Indic ASR does not support \(language.label); it will use Hindi."
                )
            default:
                break
            }
        }

        if backend.backend == "cohere" {
            return .init(
                kind: .providerFallback,
                effectiveLanguage: .english,
                explanation: "Cohere cannot auto-detect this profile, so it will use English."
            )
        }
        if backend.backend == "indicasr" {
            return .init(
                kind: .providerFallback,
                effectiveLanguage: .hindi,
                explanation: "Indic ASR cannot auto-detect this profile, so it will use Hindi."
            )
        }

        return .init(
            kind: .automaticDetection,
            effectiveLanguage: nil,
            explanation: selectedLanguages.isEmpty
                ? "The model will detect the spoken language automatically."
                : "The model will detect between the selected languages automatically."
        )
    }
}

enum MeetingLiveCaptionBackend: String, CaseIterable, Codable, Sendable {
    case parakeetRealtimeEOU = "parakeet_realtime_eou"
    case nemotron35 = "nemotron35"

    static let defaultBackend: Self = .parakeetRealtimeEOU

    var label: String {
        switch self {
        case .parakeetRealtimeEOU: return MeetingLiveCaptionModelStore.label
        case .nemotron35: return BackendOption.nemotron35Multilingual.label
        }
    }

    var settingsLabel: String {
        switch self {
        case .parakeetRealtimeEOU: return "\(label) (live preview only)"
        case .nemotron35: return "\(label) (live transcript)"
        }
    }

    var isDownloaded: Bool {
        switch self {
        case .parakeetRealtimeEOU: return MeetingLiveCaptionModelStore.isDownloaded()
        case .nemotron35:
            guard #available(macOS 15, *) else { return false }
            return BackendOption.nemotron35Multilingual.isDownloaded
        }
    }

    static func resolved(_ rawValue: String?) -> Self {
        guard let rawValue, let backend = Self(rawValue: rawValue) else {
            return defaultBackend
        }
        return backend
    }
}

struct SummaryModelPreset {
    let id: String
    let label: String

    static let openAIModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "gpt-5.4-mini", label: "GPT-5.4 Mini (default)"),
        SummaryModelPreset(id: "gpt-5.6-sol", label: "GPT-5.6 Sol"),
        SummaryModelPreset(id: "gpt-5.6-terra", label: "GPT-5.6 Terra"),
        SummaryModelPreset(id: "gpt-5.6-luna", label: "GPT-5.6 Luna"),
        SummaryModelPreset(id: "chat-latest", label: "Chat Latest (Instant)"),
        SummaryModelPreset(id: "gpt-5.4-nano", label: "GPT-5.4 Nano"),
        SummaryModelPreset(id: "gpt-5.4", label: "GPT-5.4"),
        SummaryModelPreset(id: "gpt-5.4-pro", label: "GPT-5.4 Pro"),
        SummaryModelPreset(id: "gpt-5-mini", label: "GPT-5 Mini"),
        SummaryModelPreset(id: "gpt-5.2", label: "GPT-5.2"),
    ]

    static let chatGPTModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "gpt-5.4-mini", label: "GPT-5.4 Mini (default)"),
        SummaryModelPreset(id: "gpt-5.6-sol", label: "GPT-5.6 Sol"),
        SummaryModelPreset(id: "gpt-5.6-terra", label: "GPT-5.6 Terra"),
        SummaryModelPreset(id: "gpt-5.6-luna", label: "GPT-5.6 Luna"),
    ]

    static let chatGPTTranscriptCleanupModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "gpt-5.6-terra", label: "GPT-5.6 Terra (default)"),
        SummaryModelPreset(id: "gpt-5.4-mini", label: "GPT-5.4 Mini"),
        SummaryModelPreset(id: "gpt-5.6-sol", label: "GPT-5.6 Sol"),
        SummaryModelPreset(id: "gpt-5.6-luna", label: "GPT-5.6 Luna"),
    ]

    private static let unsupportedChatGPTModelIDs: Set<String> = [
        "chat-latest",
        "gpt-5.4-nano",
    ]

    static let computerUsePlannerModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "gpt-5.6-sol", label: "GPT-5.6 Sol (default)"),
        SummaryModelPreset(id: "gpt-5.6-terra", label: "GPT-5.6 Terra"),
        SummaryModelPreset(id: "gpt-5.6-luna", label: "GPT-5.6 Luna"),
        SummaryModelPreset(id: "gpt-5.4", label: "GPT-5.4"),
        SummaryModelPreset(id: "gpt-5.4-mini", label: "GPT-5.4 Mini"),
        SummaryModelPreset(id: "gpt-5.2", label: "GPT-5.2"),
    ]

    static let openRouterModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "stepfun/step-3.5-flash:free", label: "Step 3.5 Flash (256k ctx)"),
        SummaryModelPreset(id: "nvidia/nemotron-3-super-120b-a12b:free", label: "Nemotron 3 Super 120B (262k ctx)"),
        SummaryModelPreset(id: "nvidia/nemotron-3-nano-30b-a3b:free", label: "Nemotron 3 Nano 30B (256k ctx)"),
        SummaryModelPreset(id: "arcee-ai/trinity-large-preview:free", label: "Trinity Large (131k ctx)"),
    ]

    static func menuPresets(_ presets: [SummaryModelPreset], currentModel: String) -> [SummaryModelPreset] {
        let trimmedModel = currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return presets }
        guard !presets.contains(where: { $0.id == trimmedModel }) else { return presets }
        return presets + [SummaryModelPreset(id: trimmedModel, label: "Custom: \(trimmedModel)")]
    }

    static func supportedChatGPTModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return unsupportedChatGPTModelIDs.contains(trimmed) ? "" : trimmed
    }

    static func reasoningEffort(for model: String) -> String? {
        switch model.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna":
            return "high"
        default:
            return nil
        }
    }

    static func migratedFromGPT55(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines) == "gpt-5.5"
            ? "gpt-5.6-sol"
            : model
    }
}

struct OpenRouterModelCatalog: Decodable {
    let data: [OpenRouterModel]
}

struct OpenRouterModel: Decodable {
    let id: String
    let name: String
    let contextLength: Int?
    let pricing: Pricing
    let architecture: Architecture?

    struct Pricing: Decodable {
        let prompt: String?
        let completion: String?
        let request: String?

        var isFreeForTextGeneration: Bool {
            isExplicitZero(prompt)
                && isExplicitZero(completion)
                && isZeroOrMissing(request)
        }

        private func isExplicitZero(_ value: String?) -> Bool {
            guard let value else { return false }
            return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) == 0
        }

        private func isZeroOrMissing(_ value: String?) -> Bool {
            guard let value else { return true }
            return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) == 0
        }
    }

    struct Architecture: Decodable {
        let outputModalities: [String]?

        enum CodingKeys: String, CodingKey {
            case outputModalities = "output_modalities"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case contextLength = "context_length"
        case pricing
        case architecture
    }
}

extension OpenRouterModel {
    var producesOnlyText: Bool {
        guard let outputModalities = architecture?.outputModalities else {
            return false
        }
        return outputModalities == ["text"]
    }

    var summaryPresetLabel: String {
        if let contextLength, contextLength > 0 {
            return "\(name) (\(Self.formatContextLength(contextLength)) ctx)"
        }
        return name
    }

    private static func formatContextLength(_ value: Int) -> String {
        if value >= 1000 {
            return "\(value / 1000)k"
        }
        return "\(value)"
    }
}

enum OpenRouterModelCatalogFilter {
    private static let minimumSummaryContextLength = 100_000

    static func freeTextSummaryPresets(from models: [OpenRouterModel]) -> [SummaryModelPreset] {
        models
            .filter { model in
                model.producesOnlyText
                    && model.pricing.isFreeForTextGeneration
                    && (model.contextLength ?? 0) >= minimumSummaryContextLength
            }
            .sorted {
                if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                    return $0.id < $1.id
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map { SummaryModelPreset(id: $0.id, label: $0.summaryPresetLabel) }
    }
}

struct MeetingSummaryBackendOption: Equatable {
    let backend: String
    let label: String

    static let openAI = MeetingSummaryBackendOption(
        backend: "openai",
        label: "OpenAI"
    )

    static let openRouter = MeetingSummaryBackendOption(
        backend: "openrouter",
        label: "OpenRouter"
    )

    static let chatGPT = MeetingSummaryBackendOption(
        backend: "chatgpt",
        label: "ChatGPT"
    )

    static let ollama = MeetingSummaryBackendOption(
        backend: "ollama",
        label: "Ollama"
    )

    static let lmStudio = MeetingSummaryBackendOption(
        backend: "lmstudio",
        label: "LM Studio"
    )

    static let customLLM = MeetingSummaryBackendOption(
        backend: "custom_llm",
        label: "Custom LLM"
    )

    static let all: [MeetingSummaryBackendOption] = [.chatGPT, .openAI, .openRouter, .ollama, .lmStudio, .customLLM]

    static func resolved(_ backend: String?) -> MeetingSummaryBackendOption {
        guard let backend, let option = all.first(where: { $0.backend == backend }) else {
            return .chatGPT
        }
        return option
    }
}

enum CustomLLMFormat: String, Codable, CaseIterable {
    case openAI = "openai"
    case anthropic = "anthropic"

    var label: String {
        switch self {
        case .openAI:
            return "OpenAI-compatible"
        case .anthropic:
            return "Anthropic Messages"
        }
    }
}

struct PostProcessorOption: Identifiable, Equatable {
    enum InputFormat: Hashable {
        /// The existing Muesli/Qwen cleanup prompt, which users may customize.
        case configurable
        /// S1-mini is trained on a fixed prompt and control-line contract.
        case s1Mini
    }

    let id: String
    let label: String
    let sizeLabel: String
    let description: String
    let downloadURL: URL
    let filename: String
    let inputFormat: InputFormat

    init(
        id: String,
        label: String,
        sizeLabel: String,
        description: String,
        downloadURL: URL,
        filename: String,
        inputFormat: InputFormat = .configurable
    ) {
        self.id = id
        self.label = label
        self.sizeLabel = sizeLabel
        self.description = description
        self.downloadURL = downloadURL
        self.filename = filename
        self.inputFormat = inputFormat
    }

    var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models/postproc-\(id)", isDirectory: true)
    }

    var modelURL: URL {
        cacheDirectory.appendingPathComponent(filename)
    }

    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    var logoResourceName: String {
        inputFormat == .s1Mini ? "superwhisper-logo" : "qwen-logo"
    }

    /// Quill needs a general instruction-following model. Models fine-tuned for
    /// transcript cleanup can emit their training schema (including JSON)
    /// instead of following an arbitrary rewrite instruction.
    var supportsQuil: Bool {
        self == .qwen35_0_8b
    }

    var quilLabel: String {
        self == .qwen35_0_8b ? "Qwen 3.5 0.8B (General)" : label
    }

    /// S1-mini normalizes English transcripts only. Indic ASR always emits an
    /// Indic-language transcript, so do not offer or run S1-mini for it.
    func isCompatible(with transcriptionBackend: BackendOption) -> Bool {
        inputFormat != .s1Mini || transcriptionBackend != .indicASR
    }

    // Fine-tuned Qwen3-0.6B trained on Muesli dictation correction data.
    // HF repo must be public (or token-gated) before distributing alpha builds.
    static let finetunedV2 = PostProcessorOption(
        id: "qwen3-postproc-v2",
        label: "Muesli Cleanup (Legacy)",
        sizeLabel: "~390 MB",
        description: "An earlier cleanup model for Muesli dictation. It handles filler words, corrections, and spoken lists, but is less consistent than the current model.",
        downloadURL: URL(string: "https://huggingface.co/phequals/qwen3-postproc-v2/resolve/main/qwen3-postproc-v2-q4_k_m.gguf")!,
        filename: "qwen3-postproc-v2-q4_k_m.gguf"
    )

    // Vanilla Qwen3.5-0.8B. Stable for basic cleanup; does not reliably convert spoken list cues.
    static let qwen35_0_8b = PostProcessorOption(
        id: "qwen35-0.8b",
        label: "Qwen Basic Cleanup",
        sizeLabel: "~533 MB",
        description: "A general-purpose option for typos and filler words. It may miss “scratch that” edits and spoken list formatting.",
        downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf")!,
        filename: "Qwen3.5-0.8B-Q4_K_M.gguf"
    )

    // Fine-tuned Qwen3.5-0.8B v3 trained on Muesli dictation correction data.
    static let finetunedV3 = PostProcessorOption(
        id: "qwen35-postproc-v3",
        label: "Muesli Cleanup",
        sizeLabel: "~505 MB",
        description: "The best overall choice for everyday dictation. It removes filler words, follows “scratch that,” and turns spoken list cues into clean formatting.",
        downloadURL: URL(string: "https://huggingface.co/phequals/qwen35-postproc-v3-gguf/resolve/main/qwen35-postproc-v3-Q4_K_M.gguf")!,
        filename: "qwen35-postproc-v3-Q4_K_M.gguf"
    )

    static let s1Mini = PostProcessorOption(
        id: "superwhisper-s1-mini",
        label: "S1-mini by Superwhisper",
        sizeLabel: "~462 MB",
        description: "English-only speech-to-text normalization with reliable filler removal, corrections, punctuation, capitalization, and written numbers, dates, times, currency, and email addresses.",
        downloadURL: URL(string: "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/main/s1-mini-q4_k_m.gguf")!,
        filename: "s1-mini-q4_k_m.gguf",
        inputFormat: .s1Mini
    )

    static let all: [PostProcessorOption] = [.finetunedV3, .s1Mini, .finetunedV2, .qwen35_0_8b]
    static let defaultOption: PostProcessorOption = .finetunedV3
    static let defaultQuilOption: PostProcessorOption = .qwen35_0_8b

    static var downloaded: [PostProcessorOption] {
        all.filter(\.isDownloaded)
    }

    static var downloadedIDs: Set<String> {
        Set(downloaded.map(\.id))
    }

    static func resolve(id: String) -> PostProcessorOption {
        all.first { $0.id == id } ?? defaultOption
    }

    static func firstDownloaded(excluding excludedID: String? = nil) -> PostProcessorOption? {
        firstDownloaded(excluding: excludedID, downloadedIDs: downloadedIDs)
    }

    static func firstDownloaded(excluding excludedID: String? = nil, downloadedIDs: Set<String>) -> PostProcessorOption? {
        all.first { option in
            option.id != excludedID && downloadedIDs.contains(option.id)
        }
    }

    static func resolveDownloaded(id: String) -> PostProcessorOption? {
        resolveDownloaded(id: id, downloadedIDs: downloadedIDs)
    }

    static func resolveDownloaded(id: String, downloadedIDs: Set<String>) -> PostProcessorOption? {
        let resolved = resolve(id: id)
        if downloadedIDs.contains(resolved.id) { return resolved }
        return firstDownloaded(downloadedIDs: downloadedIDs)
    }

    static func runtimeOption(id: String) -> PostProcessorOption? {
        runtimeOption(
            id: id,
            downloadedIDs: downloadedIDs,
            hasDevOverride: Qwen3PostProcessorConfig.devOverrideURL() != nil
        )
    }

    static func runtimeOption(id: String, downloadedIDs: Set<String>, hasDevOverride: Bool) -> PostProcessorOption? {
        let configured = resolve(id: id)
        if downloadedIDs.contains(configured.id) || hasDevOverride { return configured }
        return firstDownloaded(downloadedIDs: downloadedIDs)
    }

    static let defaultSystemPrompt = """
    Clean up speech-to-text transcription. Only make changes when there is a clear error. If the text is already correct, output it exactly as-is.

    The user input may include an <APP-CONTEXT> section with focused app, document, URL, selected text, or OCR screen text. Use it only to resolve obvious transcription errors, names, acronyms, and formatting intent. Never copy app context into the output unless the user dictated it.

    You may: fix obvious misspellings, remove filler words (um, uh, like), apply 'scratch that' deletions, and format numbered or bullet lists when dictated.

    Do not: paraphrase, reword, add words, remove meaningful words, change the meaning in any way, wrap the output in markdown, code fences, tags, labels, or commentary, or repeat the output more than once. Preserve the speaker's original phrasing.
    """

    /// S1-mini was trained on this exact system prompt and rejects prompt customization.
    static let s1MiniSystemPrompt = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."

    func effectiveSystemPrompt(configuredSystemPrompt: String) -> String {
        switch inputFormat {
        case .configurable:
            configuredSystemPrompt
        case .s1Mini:
            Self.s1MiniSystemPrompt
        }
    }
}

struct TranscriptCleanupPromptPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let prompt: String
    let isCustom: Bool
}

struct CustomTranscriptCleanupPrompt: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var prompt: String

    init(id: String = UUID().uuidString, name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }
}

enum DictationStyleCategory: String, Codable, CaseIterable, Identifiable {
    case messages
    case email
    case writing
    case code

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .messages: "Messages"
        case .email: "Email"
        case .writing: "Writing"
        case .code: "Code"
        }
    }

    var defaultStyleID: String {
        switch self {
        case .messages: TranscriptCleanupPrompts.messageID
        case .email: TranscriptCleanupPrompts.emailID
        case .writing: TranscriptCleanupPrompts.writingID
        case .code: TranscriptCleanupPrompts.codeID
        }
    }
}

struct DictationStyleAppRule: Codable, Equatable, Identifiable {
    var bundleID: String
    var displayName: String
    var categoryID: String?
    var styleID: String?

    var id: String { bundleID }

    init(bundleID: String, displayName: String = "", categoryID: String? = nil, styleID: String? = nil) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.categoryID = categoryID
        self.styleID = styleID
    }

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case displayName = "display_name"
        case categoryID = "category_id"
        case styleID = "style_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = (try? container.decode(String.self, forKey: .bundleID)) ?? ""
        displayName = (try? container.decode(String.self, forKey: .displayName)) ?? ""
        categoryID = try? container.decode(String.self, forKey: .categoryID)
        styleID = try? container.decode(String.self, forKey: .styleID)
    }
}

struct DictationStyleDomainRule: Codable, Equatable, Identifiable {
    var hostname: String
    var categoryID: String?
    var styleID: String?

    var id: String { hostname }

    init(hostname: String, categoryID: String? = nil, styleID: String? = nil) {
        self.hostname = hostname
        self.categoryID = categoryID
        self.styleID = styleID
    }

    enum CodingKeys: String, CodingKey {
        case hostname
        case categoryID = "category_id"
        case styleID = "style_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostname = (try? container.decode(String.self, forKey: .hostname)) ?? ""
        categoryID = try? container.decode(String.self, forKey: .categoryID)
        styleID = try? container.decode(String.self, forKey: .styleID)
    }
}

enum DictationStyleMatcherKind: String, Codable, CaseIterable, Sendable {
    case bundleID = "bundle_id"
    case hostname
}

/// An exact or full-value wildcard target matcher. The resolver owns
/// normalization so persisted values are portable and deterministic.
struct DictationStyleMatcher: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: DictationStyleMatcherKind
    var pattern: String

    init(id: String, kind: DictationStyleMatcherKind, pattern: String) {
        self.id = id
        self.kind = kind
        self.pattern = pattern
    }

    enum CodingKeys: String, CodingKey { case id; case kind; case pattern }
}

struct DictationStyleGroup: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var styleID: String
    var matchers: [DictationStyleMatcher]

    init(id: String, name: String, styleID: String, matchers: [DictationStyleMatcher] = []) {
        self.id = id
        self.name = name
        self.styleID = styleID
        self.matchers = matchers
    }

    enum CodingKeys: String, CodingKey {
        case id, name, matchers
        case styleID = "style_id"
    }
}

struct DictationStyleExactException: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: DictationStyleMatcherKind
    var target: String
    var styleID: String

    init(id: String, kind: DictationStyleMatcherKind, target: String, styleID: String) {
        self.id = id
        self.kind = kind
        self.target = target
        self.styleID = styleID
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, target
        case styleID = "style_id"
    }
}

enum DictationStyleSelectionSource: String, Codable, Equatable, Sendable {
    case exception
    case group
    case domain
    case app
    case category
    case global
    case builtInFallback = "built_in_fallback"
}

struct DictationStyleSelectionResult: Equatable {
    let styleID: String
    let styleName: String
    let prompt: String
    let isCustom: Bool
    let source: DictationStyleSelectionSource
    let categoryID: String?
    let groupID: String?

    init(
        styleID: String,
        styleName: String,
        prompt: String,
        isCustom: Bool,
        source: DictationStyleSelectionSource,
        categoryID: String?,
        groupID: String? = nil
    ) {
        self.styleID = styleID
        self.styleName = styleName
        self.prompt = prompt
        self.isCustom = isCustom
        self.source = source
        self.categoryID = categoryID
        self.groupID = groupID
    }
}

struct DictationStyleTarget: Equatable {
    let bundleID: String?
    let hostname: String?

    init(bundleID: String?, hostname: String?) {
        self.bundleID = DictationStyleResolver.normalizeBundleID(bundleID)
        self.hostname = DictationStyleResolver.normalizeHostname(hostname)
    }
}

enum TranscriptCleanupPrompts {
    static let defaultID = "default"
    static let messageID = "message"
    static let emailID = "email"
    static let writingID = "writing"
    static let codeID = "code"
    static let mixedLanguageRepairID = "mixed-language-repair"

    static let builtIns: [TranscriptCleanupPromptPreset] = [
        TranscriptCleanupPromptPreset(
            id: defaultID,
            name: "Default Cleanup",
            prompt: PostProcessorOption.defaultSystemPrompt,
            isCustom: false
        ),
        TranscriptCleanupPromptPreset(
            id: messageID,
            name: "Message",
            prompt: """
            Clean up the dictated message while preserving its meaning, facts, names, wording, and deletion intent. Keep it concise and casual, use light punctuation, and never invent content.
            """,
            isCustom: false
        ),
        TranscriptCleanupPromptPreset(
            id: emailID,
            name: "Email",
            prompt: """
            Clean up the dictated email while preserving its meaning, facts, names, wording, and deletion intent. Use complete sentences, clear paragraphs, and a professional neutral register. Include a greeting or sign-off only when the user dictated one, and never invent content.
            """,
            isCustom: false
        ),
        TranscriptCleanupPromptPreset(
            id: writingID,
            name: "Writing",
            prompt: """
            Clean up the dictated writing while preserving its meaning, facts, names, wording, and deletion intent. Use polished paragraphs and dictated structure, but never invent headings, facts, or other content.
            """,
            isCustom: false
        ),
        TranscriptCleanupPromptPreset(
            id: codeID,
            name: "Code",
            prompt: """
            Clean up the dictated technical prose while preserving its meaning, facts, names, wording, deletion intent, identifiers, and code terms. Format prose compactly. Never convert spoken syntax into executable code unless the user explicitly dictated code.
            """,
            isCustom: false
        ),
        // Selectable because the default forbids the word changes this needs. Someone
        // dictating Arabic with English technical terms gets the same phonetic
        // mangling a meeting does, and the same repair fixes it.
        TranscriptCleanupPromptPreset(
            id: mixedLanguageRepairID,
            name: "Mixed-Language Repair (Arabic + English)",
            prompt: MixedLanguageRepairPrompt.dictation,
            isCustom: false
        ),
    ]

    static func presets(custom: [CustomTranscriptCleanupPrompt]) -> [TranscriptCleanupPromptPreset] {
        builtIns + custom.map {
            TranscriptCleanupPromptPreset(id: $0.id, name: $0.name, prompt: $0.prompt, isCustom: true)
        }
    }

    static var reservedIDs: Set<String> {
        Set(builtIns.map(\.id))
    }

    static func resolveOptional(
        id: String?,
        custom: [CustomTranscriptCleanupPrompt]
    ) -> TranscriptCleanupPromptPreset? {
        guard let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return presets(custom: custom).first {
            $0.id == id && !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func resolve(id: String, custom: [CustomTranscriptCleanupPrompt]) -> TranscriptCleanupPromptPreset {
        presets(custom: custom).first { $0.id == id } ?? builtIns[0]
    }
}

/// Cleanup instructions for a finalized meeting transcript.
///
/// Deliberately not a `TranscriptCleanupPrompts` preset. The dictation default
/// forbids paraphrasing, rewording, and adding words -- correct for a sentence
/// someone just spoke into their own machine, and fatal here, because restoring
/// `primary key` from البرايمريكية *is* changing the words. Keeping the two
/// separate also means editing the dictation preset cannot silently change what
/// meetings send.
///
/// It carries no `<APP-CONTEXT>` block: focused app, URL, and OCR text are
/// dictation concepts with no meaning during a meeting.
/// Instructions for repairing a transcript whose speech recognizer was monolingual.
///
/// Deliberately not a `TranscriptCleanupPrompts` default. The dictation default
/// forbids paraphrasing, rewording, and adding words -- correct when the recognizer
/// heard the right language, and fatal here, because restoring `primary key` from
/// البرايمريكية *is* changing the words.
enum MixedLanguageRepairPrompt {

    /// Delimiters for the dictation block. The dictation prompt already carries a
    /// custom-instructions block, so this one is bounded the same way rather than
    /// running loose into whatever follows it.
    static let openingTag = "<MIXED-LANGUAGE-REPAIR>"
    static let closingTag = "</MIXED-LANGUAGE-REPAIR>"

    /// Names the exception the surrounding prompt would otherwise forbid.
    ///
    /// The dictation base prompt says never to paraphrase or change words, and the
    /// model sees both blocks in one system prompt. Without this sentence the two
    /// read as a contradiction, and the safest reading -- change nothing -- is the
    /// one that makes the repair a no-op.
    private static let restorationAllowance = """
    Restoring a term the recognizer wrote in the wrong script is not paraphrasing; \
    it is the correction this block asks for. Every word the recognizer heard \
    correctly stays exactly as the speaker said it.
    """

    private static let rules = """
    You MUST:
    - Change words when the recognizer misheard them. This is the entire task.
    - Keep every other word as the speaker said it, in the language they said it.
    - Return every line you were given, in the same order.
    - Return the full text of every line, however long.

    You MUST NOT:
    - Summarize, shorten, or omit anything.
    - Translate the text into another language.
    - Add commentary, headings, or content nobody said.
    """

    /// The repair instructions themselves, shared by dictation and meetings.
    ///
    /// Carries no `<APP-CONTEXT>` block: it is about the words, not about what was
    /// on screen when they were spoken.
    static func core(subject: String) -> String {
        """
        You repair \(subject) that mix Arabic and English.

        The speech recognizer was monolingual, so foreign-language terms were \
        transcribed phonetically into the text's own script and are now nonsense. \
        Your job is to restore them.

        Restore technical terms, product names, and borrowed words to their correct \
        original spelling. For example, Arabic text reading "البرايمريكية" is the \
        English term "primary key" written phonetically, and "وأنتو مين" in a \
        technical discussion is "one-to-many", not the Arabic question it looks like. \
        Use the surrounding context to decide which reading is meant.

        \(restorationAllowance)

        Add sentence punctuation where it is missing.

        \(rules)
        """
    }

    /// The same repair for a bilingual pair we carry no worked examples for.
    ///
    /// Examples in a script the user never selected would teach the wrong lesson,
    /// so this variant states the rule and lets the model apply it to the pair in
    /// front of it.
    static func neutral(subject: String) -> String {
        """
        You repair \(subject) that mix two languages.

        The speech recognizer was monolingual, so terms from the other language were \
        transcribed phonetically into the text's own script and are now nonsense. \
        Restore technical terms, product names, and borrowed words to their correct \
        original spelling, using the surrounding context to decide which reading is \
        meant.

        \(restorationAllowance)

        Add sentence punctuation where it is missing.

        \(rules)
        """
    }

    /// The on-device variant.
    ///
    /// `Qwen3PostProcessor.maxContextTokens` is 1024 for the prompt, the dictated
    /// text, and the output together, so the full block would crowd out the words
    /// it is meant to repair. This keeps the instruction and the prohibitions and
    /// drops the worked examples.
    static func compact(subject: String) -> String {
        """
        You repair \(subject) that mix two languages. The recognizer was monolingual, \
        so foreign terms were written phonetically in the wrong script. Restore them \
        to their correct original spelling.

        \(restorationAllowance)

        Do not translate, summarize, omit, reorder, or add anything.
        """
    }

    /// The dictation block for a profile, or nil when the profile is not bilingual.
    ///
    /// The profile is the only input: repair follows the languages the user selected
    /// rather than a stored preference (KTD1).
    static func block(for profile: SpokenLanguageProfile, compact useCompact: Bool) -> String? {
        guard profile.isBilingual else { return nil }
        let subject = "dictated text"
        let body: String
        if useCompact {
            body = compact(subject: subject)
        } else {
            body = hasArabicEnglishPair(profile) ? core(subject: subject) : neutral(subject: subject)
        }
        return "\(openingTag)\n\(body)\n\(closingTag)"
    }

    /// Whether the worked Arabic examples apply to this selection.
    static func hasArabicEnglishPair(_ profile: SpokenLanguageProfile) -> Bool {
        let selected = Set(profile.selectedLanguages)
        return selected.contains(.arabic) && selected.contains(.english)
    }

    /// The dictation preset: one snippet in, one snippet out, no wire protocol.
    static let dictation = core(subject: "dictated text")
}

enum MeetingTranscriptCleanupPrompt {
    /// Marker delimiting each unit on the wire.
    ///
    /// Unit correspondence has to be exact rather than inferred: the model returns
    /// free-form text, so without a marker to echo there is nothing to map output
    /// units back to input units, and a merged or dropped line becomes invisible.
    /// The sequence is chosen not to occur naturally in Arabic or English prose.
    static let unitMarker = "<<<U"

    static func marker(for index: Int) -> String { "\(unitMarker)\(index)>>>" }

    /// The chunking protocol only meetings use. Always last, so it stays
    /// authoritative over anything the user's preferences say.
    private static let markerProtocol = """


        Each line is preceded by a <<<U…>>> marker. Copy every marker exactly as it \
        appears. Markers are structure, not content: never translate, renumber, \
        reorder, merge, or drop one.
        """

    /// The shared repair instructions plus the chunking protocol, with no
    /// custom instructions. Byte-identical to `systemPrompt(customInstructions: "")`.
    static let systemPrompt = systemPrompt(customInstructions: "")

    /// Repair core, then the user's preferences when they set any, then the
    /// marker protocol.
    static func systemPrompt(customInstructions: String) -> String {
        MixedLanguageRepairPrompt.core(subject: "transcripts of meetings")
            + CustomInstructions.promptSuffix(customInstructions, preamble: CustomInstructions.meetingCleanupPreamble)
            + markerProtocol
    }
}
struct DictionarySuggestion: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var observed: String
    var replacement: String
    var appContext: String
    var occurrenceCount: Int = 1
    var createdAt: String = DictionarySuggestion.timestamp()
    var lastSeenAt: String = DictionarySuggestion.timestamp()

    enum CodingKeys: String, CodingKey {
        case id
        case observed
        case replacement
        case appContext = "app_context"
        case occurrenceCount = "occurrence_count"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }

    init(
        id: UUID = UUID(),
        observed: String,
        replacement: String,
        appContext: String = "",
        occurrenceCount: Int = 1,
        createdAt: String = DictionarySuggestion.timestamp(),
        lastSeenAt: String = DictionarySuggestion.timestamp()
    ) {
        self.id = id
        self.observed = observed
        self.replacement = replacement
        self.appContext = appContext
        self.occurrenceCount = max(occurrenceCount, 1)
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        observed = try c.decode(String.self, forKey: .observed)
        replacement = try c.decode(String.self, forKey: .replacement)
        appContext = (try? c.decode(String.self, forKey: .appContext)) ?? ""
        occurrenceCount = max((try? c.decode(Int.self, forKey: .occurrenceCount)) ?? 1, 1)
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? DictionarySuggestion.timestamp()
        lastSeenAt = (try? c.decode(String.self, forKey: .lastSeenAt)) ?? DictionarySuggestion.timestamp()
    }

    var key: String {
        Self.key(observed: observed, replacement: replacement)
    }

    var customWord: CustomWord {
        // Auto-learned corrections come from one observed edit pair, so keep
        // them stricter than manually configured words to avoid broad rewrites.
        CustomWord(word: observed, replacement: replacement, matchingThreshold: 0.92)
    }

    var appDisplayName: String {
        let name = appContext
            .split(separator: "|", omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? appContext : name
    }

    static func key(observed: String, replacement: String) -> String {
        "\(normalize(observed))->\(normalize(replacement))"
    }

    static func timestamp() -> String {
        iso8601Lock.lock()
        defer { iso8601Lock.unlock() }
        return iso8601.string(from: Date())
    }

    private static let iso8601 = ISO8601DateFormatter()
    private static let iso8601Lock = NSLock()

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}

enum IndicatorHoverStyle: String, Codable, CaseIterable {
    case classic = "classic"
    case shortcutPill = "shortcut_pill"

    var label: String {
        switch self {
        case .classic: return "Classic"
        case .shortcutPill: return "Shortcut pill"
        }
    }
}

enum IndicatorAnchor: String, Codable, CaseIterable {
    case topLeading = "top_leading"
    case topCenter = "top_center"
    case topTrailing = "top_trailing"
    case midLeading = "mid_leading"
    case midTrailing = "mid_trailing"
    case bottomLeading = "bottom_leading"
    case bottomCenter = "bottom_center"
    case bottomTrailing = "bottom_trailing"
    case custom = "custom"

    var label: String {
        switch self {
        case .topLeading: return "Top Left"
        case .topCenter: return "Top Center"
        case .topTrailing: return "Top Right"
        case .midLeading: return "Middle Left"
        case .midTrailing: return "Middle Right"
        case .bottomLeading: return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomTrailing: return "Bottom Right"
        case .custom: return "Custom"
        }
    }
}

struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt16 = 61
    var label: String = "Right Option"

    // Key combination support (e.g. Cmd+Shift+R).
    // When set, the hotkey fires on keyDown with these modifiers held.
    // When nil, the hotkey is a single modifier key (existing behavior).
    var combinationModifiers: UInt? = nil
    var combinationKeyCode: UInt16? = nil

    var isCombination: Bool {
        combinationModifiers != nil && combinationKeyCode != nil
    }

    var displayLabel: String {
        if isCombination { return label }
        return Self.symbolLabel(for: keyCode) ?? label
    }

    static func label(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 55: return "Left Cmd"
        case 54: return "Right Cmd"
        case 63: return "Fn"
        case 59: return "Left Ctrl"
        case 62: return "Right Ctrl"
        case 58: return "Left Option"
        case 61: return "Right Option"
        case 56: return "Left Shift"
        case 60: return "Right Shift"
        default: return nil
        }
    }

    static func symbolLabel(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 55: return "Left ⌘"
        case 54: return "Right ⌘"
        case 63: return "fn"
        case 59: return "Left ⌃"
        case 62: return "Right ⌃"
        case 58: return "Left ⌥"
        case 61: return "Right ⌥"
        case 56: return "Left ⇧"
        case 60: return "Right ⇧"
        default: return nil
        }
    }

    static func letterLabel(for keyCode: UInt16) -> String? {
        let letters: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
        ]
        return letters[keyCode]
    }

    static func combinationLabel(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> String {
        let modifiers = supportedCombinationModifiers(from: modifiers)
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        parts.append(letterLabel(for: keyCode) ?? "?")
        return parts.joined()
    }

    static func combination(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> HotkeyConfig {
        let supportedModifiers = supportedCombinationModifiers(from: modifiers)
        let lbl = combinationLabel(modifiers: supportedModifiers, keyCode: keyCode)
        return HotkeyConfig(
            keyCode: UInt16.max,
            label: lbl,
            combinationModifiers: UInt(supportedModifiers.rawValue),
            combinationKeyCode: keyCode
        )
    }

    static func supportedCombinationModifiers(from modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifiers.intersection([.command, .control, .option, .shift])
    }

    var resolvedCombinationModifiers: NSEvent.ModifierFlags? {
        guard let raw = combinationModifiers else { return nil }
        return Self.supportedCombinationModifiers(from: NSEvent.ModifierFlags(rawValue: raw))
    }

    static let `default` = HotkeyConfig()
    static let quilDefault = HotkeyConfig(keyCode: 63, label: "Fn")
    static let computerUseDefault = HotkeyConfig(keyCode: 54, label: "Right Cmd")
    static let meetingRecordingDefault = HotkeyConfig(
        keyCode: UInt16.max,
        label: "⌘⇧R",
        combinationModifiers: UInt(NSEvent.ModifierFlags([.command, .shift]).rawValue),
        combinationKeyCode: 15
    )

    static func computerUseDefault(avoiding dictationHotkey: HotkeyConfig) -> HotkeyConfig {
        dictationHotkey.keyCode == computerUseDefault.keyCode ? .default : .computerUseDefault
    }
}

enum OnboardingUseCase: String, Codable, CaseIterable {
    case voiceNotes = "voice_notes"
    case dictation = "dictation"
    case meetings = "meetings"
    case dictationAndMeetings = "dictation_and_meetings"

    var includesDictation: Bool {
        self == .dictation || self == .dictationAndMeetings
    }

    var includesVoiceNotes: Bool {
        self == .voiceNotes
    }

    var includesPushToTalk: Bool {
        includesVoiceNotes || includesDictation
    }

    var includesMeetings: Bool {
        self == .meetings || self == .dictationAndMeetings
    }

    var canSwitchToVoiceNotesOnly: Bool {
        self == .dictation
    }

    static func resolved(_ rawValue: String?) -> OnboardingUseCase {
        guard let rawValue, let useCase = OnboardingUseCase(rawValue: rawValue) else {
            return .dictation
        }
        return useCase
    }
}

enum DictationRecordingSavePolicy: String, Codable, CaseIterable {
    case never
    case prompt
    case always

    var retainsCapture: Bool {
        self != .never
    }
}

struct AppConfig: Codable {
    /// Stored in `recording_color_hex` to mean "use the product default accent". Deliberately
    /// not a hex value so it can never collide with a selectable preset.
    static let defaultAccentMarker = "default"
    /// The pre-Spark default, which doubled as the "Dark" preset.
    static let legacyDefaultAccentHex = "1e1e2e"

    /// The user's accent choice, or `nil` when they are on the product default.
    var accentOverrideHex: String? {
        recordingColorHex == AppConfig.defaultAccentMarker ? nil : recordingColorHex
    }

    var dictationHotkey: HotkeyConfig = .default
    var quilHotkey: HotkeyConfig = .quilDefault
    var enableQuilMode: Bool = false
    var computerUseHotkey: HotkeyConfig = .computerUseDefault
    var enableComputerUseHotkey: Bool = false
    var meetingRecordingHotkey: HotkeyConfig = .meetingRecordingDefault
    var enableMeetingRecordingHotkey: Bool = false
    var computerUseHotkeyDefaultDisabledMigrationApplied: Bool = true
    var enableComputerUsePlanner: Bool = true
    var computerUsePlannerModel: String = ""
    var computerUseTimeoutSeconds: Int = 120
    var sttBackend: String = BackendOption.parakeetUnified.backend
    var sttModel: String = BackendOption.parakeetUnified.model
    var dictationInputDeviceUID: String? = nil
    var meetingInputDeviceUID: String? = nil
    var cohereLanguage: String = CohereTranscribeLanguage.defaultLanguage.rawValue
    var indicASRLanguage: String = IndicASRLanguage.defaultLanguage.rawValue
    var nemotron35Language: String = Nemotron35Language.defaultLanguage.rawValue
    var whisperLanguage: String = WhisperKitLanguage.defaultLanguage.rawValue
    var dictationLanguageProfile: SpokenLanguageProfile = .automatic
    var meetingSpokenLanguage: SpokenLanguageProfile = .automatic
    var meetingArtifactLanguagePolicy: MeetingArtifactLanguagePolicy = .automatic
    var languageProfileNeedsConfirmation: Bool = false
    /// Set when a persisted selection named a removed backend, and cleared once the
    /// user acknowledges it. Persisted so the announcement survives the launch it
    /// happened on.
    var retiredASRBackendNotice: RetiredASRBackendNotice? = nil
    /// Decode-only state, deliberately outside `CodingKeys`: it tells `ConfigStore`
    /// that this particular decode rewrote a selection and the result has to reach
    /// disk. Persisting it would make every later load look like a fresh migration.
    var retiredASRBackendMigrationApplied: Bool = false
    var appleSpeechLanguage: String = AppleSpeechLanguageOption.systemIdentifier
    var meetingTranscriptionBackend: String = BackendOption.whisper.backend
    var meetingTranscriptionModel: String = BackendOption.whisper.model
    var meetingSummaryBackend: String = MeetingSummaryBackendOption.chatGPT.backend
    var defaultMeetingTemplateID: String = MeetingTemplates.autoID
    var whisperModel: String = BackendOption.whisper.model
    var idleTimeout: Double = 120
    var autoRecordMeetings: Bool = false
    var upcomingMeetingsDayCount: Int = UpcomingMeetingsWindow.defaultDayCount
    var showScheduledMeetingNotifications: Bool = true
    var scheduledMeetingNotificationLeadTime: ScheduledMeetingNotificationLeadTime = .atStart
    var meetingJoinDefaultAction: MeetingJoinDefaultAction = .fallback
    var showMeetingDetectionNotification: Bool = true
    var mutedMeetingDetectionAppBundleIDs: [String] = []
    var dictationRecordingSavePolicy: DictationRecordingSavePolicy = .never
    var meetingRecordingSavePolicy: MeetingRecordingSavePolicy = .never
    var meetingRecordingFileFormat: String = MeetingRecordingFileFormat.m4a.rawValue
    var waveformCacheOrphanCleanupMigrationApplied: Bool = false
    var darkMode: Bool = true
    var enableDoubleTapDictation: Bool = true
    var hotkeyTriggerThresholdMS: Int = HotkeyTriggerTiming.defaultThresholdMilliseconds
    var quilHotkeyTriggerThresholdMS: Int = HotkeyTriggerTiming.defaultThresholdMilliseconds
    var computerUseHotkeyTriggerThresholdMS: Int = HotkeyTriggerTiming.defaultThresholdMilliseconds
    var meetingRecordingHotkeyTriggerThresholdMS: Int = HotkeyTriggerTiming.defaultMeetingThresholdMilliseconds
    var launchAtLogin: Bool = false
    var openDashboardOnLaunch: Bool = true
    var showFloatingIndicator: Bool = true
    /// Keeps the Dictation Mini's idle dot near the focused text context while not dictating.
    var showDictationIdleDot: Bool = true
    /// Floating Record pill shown while a meeting app is active (requires meeting detection).
    var showMeetingRecordButton: Bool = true
    var showHotkeyOnFloatingIndicator: Bool = false
    var indicatorHoverStyle: IndicatorHoverStyle = .classic
    var indicatorAnchor: IndicatorAnchor = .midTrailing
    var dashboardWindowFrame: WindowFrame? = nil
    var indicatorOrigin: CGPointCodable? = nil
    /// Stable center of the independent compact meeting recording controller.
    /// This is intentionally separate from the legacy dictation indicator origin.
    var meetingRecordingPanelCenter: CGPointCodable? = nil
    /// Whether the meeting object rests open as the panel or minimized as the pill.
    /// nil until the user opens or minimizes it once; while nil the start entry
    /// point decides, so a fresh install keeps today's per-entry-point behaviour.
    var meetingPanelOpen: Bool? = nil
    var openAIAPIKey: String = ""
    var openRouterAPIKey: String = ""
    var openAIModel: String = ""
    var openRouterModel: String = ""
    var chatGPTModel: String = ""
    var meetingSummaryRetryCount: Int = MeetingSummaryRetryPolicy.defaultRetryCount
    var ollamaURL: String = "http://localhost:11434"
    var ollamaModel: String = "qwen3.5"
    var lmStudioURL: String = "http://localhost:1234"
    var lmStudioModel: String = ""
    var customLLMURL: String = ""
    var customLLMAPIKey: String = ""
    var customLLMModel: String = ""
    var customLLMFormat: String = CustomLLMFormat.openAI.rawValue
    var summaryModel: String = ""
    var meetingSummaryModel: String = ""
    var hasCompletedOnboarding: Bool = false
    var onboardingUseCase: String = OnboardingUseCase.dictation.rawValue
    var userName: String = ""
    var customMeetingTemplates: [CustomMeetingTemplate] = []
    var customWords: [CustomWord] = [
        CustomWord(word: "muesli", replacement: "muesli"),
    ]
    var dictionarySuggestions: [DictionarySuggestion] = []
    var dismissedDictionarySuggestionKeys: [String] = []
    var enableDictionaryCorrectionPrompts: Bool = false
    var enableAutomaticDiagnosticIssuePrompts: Bool = false
    var folderOrder: [Int64] = []
    var soundEnabled: Bool = true
    var quilSoundEnabled: Bool = true
    var pauseMediaDuringDictation: Bool = false
    var muteSystemAudioDuringDictation: Bool = false
    /// `defaultAccentMarker` rather than a colour: the old default `1e1e2e` was also a
    /// selectable preset, so a deliberate Dark pick and an untouched default were the same
    /// bytes and could not be told apart. The marker is not a valid hex, so it can never
    /// collide with a preset again.
    var recordingColorHex: String = AppConfig.defaultAccentMarker
    /// One-time gate for the `1e1e2e` migration below. Without it the migration re-fires on
    /// every launch and erases a Dark selection made after the upgrade.
    var accentSelectionMigrated: Bool = false
    var menuBarIcon: String = "muesli"
    var showHotkeyInMenuBar: Bool = true
    var showNextMeetingInMenuBar: Bool = true
    var maraudersMapUnlocked: Bool = false
    var maraudersMapAudioClip: String = "bbc_world_news"
    var maraudersMapCustomAudioPath: String?
    var hiddenCalendarEventIDs: [String] = []
    var hiddenCalendarEventSourceHints: [String: String] = [:]
    var disabledCalendarIDs: [String] = []
    var enablePostProcessor: Bool = false
    /// The user's standing preferences for every LLM rewrite of their words:
    /// dictation cleanup, meeting transcript cleanup, and meeting notes.
    /// Stored trimmed; `CustomInstructions` owns the cap and the prompt block.
    var customInstructions: String = ""
    /// Whether finalized meeting transcripts get an AI cleanup pass.
    ///
    /// Off by default: it costs a model pass per meeting, and depending on the
    /// configured endpoint it may send the full transcript of a private
    /// conversation to a third party.
    var enableMeetingTranscriptCleanup: Bool = false
    /// SHA-256 identity of the backend and resolved destination the user approved.
    /// Nil means there is no consent, including configs saved before this field.
    var meetingTranscriptCleanupConsentFingerprint: String?
    var quilBackend: String = TranscriptCleanupBackendOption.local.backend
    var quilModel: String = PostProcessorOption.defaultQuilOption.id
    var postProcessorBackend: String = TranscriptCleanupBackendOption.local.backend
    /// Minutes of dictation-cleanup inactivity before an on-device cleanup model is
    /// released from memory. 0 keeps it resident for the life of the process.
    var postProcessorIdleUnloadMinutes: Int = PostProcessorIdleUnloadPolicy.defaultIdleMinutes
    var postProcessorGemmaModel: String = Gemma4LiteRTModel.e2b.repoID
    var activePostProcessorId: String = PostProcessorOption.defaultOption.id
    var postProcessorChatGPTModel: String = ""
    var postProcessorOpenAIModel: String = ""
    var postProcessorOpenRouterModel: String = ""
    var postProcessorOllamaModel: String = ""
    var postProcessorLMStudioModel: String = ""
    var postProcessorCustomLLMModel: String = ""
    var activeTranscriptCleanupPromptId: String = TranscriptCleanupPrompts.defaultID
    var customTranscriptCleanupPrompts: [CustomTranscriptCleanupPrompt] = []
    var postProcessorSystemPrompt: String = PostProcessorOption.defaultSystemPrompt
    var adaptiveDictationStylesEnabled: Bool = false
    /// The only authority for deciding whether starter groups may be seeded.
    var dictationStyleRulesetInitialized: Bool = false
    var dictationStyleGroups: [DictationStyleGroup] = []
    var dictationStyleExactExceptions: [DictationStyleExactException] = []
    /// Decode/load-only state. It is intentionally outside CodingKeys so a bad
    /// on-disk canonical ruleset can never be overwritten by an unrelated save.
    var dictationStyleRulesetQuarantineReason: String? = nil
    var dictationStyleCategoryAssignments: [String: String] = [:]
    var dictationStyleAppRules: [DictationStyleAppRule] = []
    var dictationStyleDomainRules: [DictationStyleDomainRule] = []
    var enableScreenContext: Bool = false
    var enableDictationOCRContext: Bool = false
    var useCoreAudioTap: Bool = true
    /// Enables the explicitly selected live meeting transcription mode.
    var enableLiveStreamingPartials: Bool = false
    var meetingLiveCaptionBackend: String = MeetingLiveCaptionBackend.defaultBackend.rawValue
    /// Preserves the original unified Nemotron behavior unless the user explicitly
    /// chooses a separate downloaded model for the final transcript.
    var useLiveMeetingTranscriptAsFinal: Bool = true
    var meetingHookEnabled: Bool = false
    var meetingHookPath: String = ""
    var meetingHookTimeoutSeconds: Int = 30
    var autoExportMarkdownEnabled: Bool = false
    var autoExportMarkdownFolderPath: String = ""
    var autoExportMarkdownContent: String = MeetingExportContent.notes.rawValue
    var autoExportFileFormat: String = MeetingAutoExportFileFormat.markdown.rawValue
    var iCloudSyncEnabled: Bool = false
    var showIOSCompanionPrompt: Bool = true
    var contributionPromptNextWordCount: Int?
    var contributionPromptNextMeetingCount: Int?
    var contributionGitHubStarClicked: Bool = false
    var contributionBuyMeCoffeeClicked: Bool = false
    var contributionTweetClicked: Bool = false
    var contributionLinkedInClicked: Bool = false

    enum CodingKeys: String, CodingKey {
        case dictationHotkey = "dictation_hotkey"
        case quilHotkey = "quil_hotkey"
        case enableQuilMode = "enable_quil_mode"
        case computerUseHotkey = "computer_use_hotkey"
        case enableComputerUseHotkey = "enable_computer_use_hotkey"
        case meetingRecordingHotkey = "meeting_recording_hotkey"
        case enableMeetingRecordingHotkey = "enable_meeting_recording_hotkey"
        case computerUseHotkeyDefaultDisabledMigrationApplied = "computer_use_hotkey_default_disabled_migration_applied"
        case enableComputerUsePlanner = "enable_computer_use_planner"
        case computerUsePlannerModel = "computer_use_planner_model"
        case computerUseTimeoutSeconds = "computer_use_timeout_seconds"
        case sttBackend = "stt_backend"
        case sttModel = "stt_model"
        case dictationInputDeviceUID = "dictation_input_device_uid"
        case meetingInputDeviceUID = "meeting_input_device_uid"
        case cohereLanguage = "cohere_language"
        case indicASRLanguage = "indic_asr_language"
        case nemotron35Language = "nemotron35_language"
        case whisperLanguage = "whisper_language"
        case dictationLanguageProfile = "dictation_language_profile"
        case meetingSpokenLanguage = "meeting_spoken_language"
        case meetingArtifactLanguagePolicy = "meeting_artifact_language_policy"
        case languageProfileNeedsConfirmation = "language_profile_needs_confirmation"
        case retiredASRBackendNotice = "retired_asr_backend_notice"
        case appleSpeechLanguage = "apple_speech_language"
        case meetingTranscriptionBackend = "meeting_transcription_backend"
        case meetingTranscriptionModel = "meeting_transcription_model"
        case meetingSummaryBackend = "meeting_summary_backend"
        case defaultMeetingTemplateID = "default_meeting_template_id"
        case whisperModel = "whisper_model"
        case idleTimeout = "idle_timeout"
        case autoRecordMeetings = "auto_record_meetings"
        case upcomingMeetingsDayCount = "upcoming_meetings_day_count"
        case showScheduledMeetingNotifications = "show_scheduled_meeting_notifications"
        case scheduledMeetingNotificationLeadTime = "scheduled_meeting_notification_lead_time"
        case meetingJoinDefaultAction = "meeting_join_default_action"
        case showMeetingDetectionNotification = "show_meeting_detection_notification"
        case mutedMeetingDetectionAppBundleIDs = "muted_meeting_detection_app_bundle_ids"
        case dictationRecordingSavePolicy = "dictation_recording_save_policy"
        case meetingRecordingSavePolicy = "meeting_recording_save_policy"
        case meetingRecordingFileFormat = "meeting_recording_file_format"
        case waveformCacheOrphanCleanupMigrationApplied = "waveform_cache_orphan_cleanup_migration_applied"
        case darkMode = "dark_mode"
        case enableDoubleTapDictation = "enable_double_tap_dictation"
        case hotkeyTriggerThresholdMS = "hotkey_trigger_threshold_ms"
        case quilHotkeyTriggerThresholdMS = "quil_hotkey_trigger_threshold_ms"
        case computerUseHotkeyTriggerThresholdMS = "computer_use_hotkey_trigger_threshold_ms"
        case meetingRecordingHotkeyTriggerThresholdMS = "meeting_recording_hotkey_trigger_threshold_ms"
        case launchAtLogin = "launch_at_login"
        case openDashboardOnLaunch = "open_dashboard_on_launch"
        case showFloatingIndicator = "show_floating_indicator"
        case showDictationIdleDot = "show_dictation_idle_dot"
        case showMeetingRecordButton = "show_meeting_record_button"
        case showHotkeyOnFloatingIndicator = "show_hotkey_on_floating_indicator"
        case indicatorHoverStyle = "indicator_hover_style"
        case indicatorAnchor = "indicator_anchor"
        case dashboardWindowFrame = "dashboard_window_frame"
        case indicatorOrigin = "indicator_origin"
        case meetingRecordingPanelCenter = "meeting_recording_panel_center"
        case meetingPanelOpen = "meeting_panel_open"
        case openAIAPIKey = "openai_api_key"
        case openRouterAPIKey = "openrouter_api_key"
        case openAIModel = "openai_model"
        case openRouterModel = "openrouter_model"
        case chatGPTModel = "chatgpt_model"
        case meetingSummaryRetryCount = "meeting_summary_retry_count"
        case ollamaURL = "ollama_url"
        case ollamaModel = "ollama_model"
        case lmStudioURL = "lmstudio_url"
        case lmStudioModel = "lmstudio_model"
        case customLLMURL = "custom_llm_url"
        case customLLMAPIKey = "custom_llm_api_key"
        case customLLMModel = "custom_llm_model"
        case customLLMFormat = "custom_llm_format"
        case summaryModel = "summary_model"
        case meetingSummaryModel = "meeting_summary_model"
        case hasCompletedOnboarding = "has_completed_onboarding"
        case onboardingUseCase = "onboarding_use_case"
        case userName = "user_name"
        case customMeetingTemplates = "custom_meeting_templates"
        case customWords = "custom_words"
        case dictionarySuggestions = "dictionary_suggestions"
        case dismissedDictionarySuggestionKeys = "dismissed_dictionary_suggestion_keys"
        case enableDictionaryCorrectionPrompts = "enable_dictionary_correction_prompts"
        case enableAutomaticDiagnosticIssuePrompts = "enable_automatic_diagnostic_issue_prompts"
        case folderOrder = "folder_order"
        case soundEnabled = "sound_enabled"
        case quilSoundEnabled = "quil_sound_enabled"
        case pauseMediaDuringDictation = "pause_media_during_dictation"
        case muteSystemAudioDuringDictation = "mute_system_audio_during_dictation"
        case recordingColorHex = "recording_color_hex"
        case accentSelectionMigrated = "accent_selection_migrated"
        case menuBarIcon = "menu_bar_icon"
        case showHotkeyInMenuBar = "show_hotkey_in_menu_bar"
        case showNextMeetingInMenuBar = "show_next_meeting_in_menu_bar"
        case maraudersMapUnlocked = "marauders_map_unlocked"
        case maraudersMapAudioClip = "marauders_map_audio_clip"
        case maraudersMapCustomAudioPath = "marauders_map_custom_audio_path"
        case hiddenCalendarEventIDs = "hidden_calendar_event_ids"
        case hiddenCalendarEventSourceHints = "hidden_calendar_event_source_hints"
        case disabledCalendarIDs = "disabled_calendar_ids"
        case enablePostProcessor = "enable_post_processor"
        case customInstructions = "custom_instructions"
        case enableMeetingTranscriptCleanup = "enable_meeting_transcript_cleanup"
        case meetingTranscriptCleanupConsentFingerprint = "meeting_transcript_cleanup_consent_fingerprint"
        case quilBackend = "quil_backend"
        case quilModel = "quil_model"
        case postProcessorBackend = "post_processor_backend"
        case postProcessorIdleUnloadMinutes = "post_processor_idle_unload_minutes"
        case postProcessorGemmaModel = "post_processor_gemma_model"
        case activePostProcessorId = "active_post_processor_id"
        case postProcessorChatGPTModel = "post_processor_chatgpt_model"
        case postProcessorOpenAIModel = "post_processor_openai_model"
        case postProcessorOpenRouterModel = "post_processor_openrouter_model"
        case postProcessorOllamaModel = "post_processor_ollama_model"
        case postProcessorLMStudioModel = "post_processor_lmstudio_model"
        case postProcessorCustomLLMModel = "post_processor_custom_llm_model"
        case activeTranscriptCleanupPromptId = "active_transcript_cleanup_prompt_id"
        case customTranscriptCleanupPrompts = "custom_transcript_cleanup_prompts"
        case postProcessorSystemPrompt = "post_processor_system_prompt"
        case adaptiveDictationStylesEnabled = "adaptive_dictation_styles_enabled"
        case dictationStyleRulesetInitialized = "dictation_style_ruleset_initialized"
        case dictationStyleGroups = "dictation_style_groups"
        case dictationStyleExactExceptions = "dictation_style_exact_exceptions"
        case enableScreenContext = "enable_screen_context"
        case enableDictationOCRContext = "enable_dictation_ocr_context"
        case useCoreAudioTap = "use_core_audio_tap"
        case enableLiveStreamingPartials = "enable_live_streaming_partials"
        case meetingLiveCaptionBackend = "meeting_live_caption_backend"
        case useLiveMeetingTranscriptAsFinal = "use_live_meeting_transcript_as_final"
        case meetingHookEnabled = "meeting_hook_enabled"
        case meetingHookPath = "meeting_hook_path"
        case meetingHookTimeoutSeconds = "meeting_hook_timeout_seconds"
        case autoExportMarkdownEnabled = "auto_export_markdown_enabled"
        case autoExportMarkdownFolderPath = "auto_export_markdown_folder_path"
        case autoExportMarkdownContent = "auto_export_markdown_content"
        case autoExportFileFormat = "auto_export_file_format"
        case iCloudSyncEnabled = "icloud_sync_enabled"
        case showIOSCompanionPrompt = "show_ios_companion_prompt"
        case contributionPromptNextWordCount = "contribution_prompt_next_word_count"
        case contributionPromptNextMeetingCount = "contribution_prompt_next_meeting_count"
        case contributionGitHubStarClicked = "contribution_github_star_clicked"
        case contributionBuyMeCoffeeClicked = "contribution_buy_me_coffee_clicked"
        case contributionTweetClicked = "contribution_tweet_clicked"
        case contributionLinkedInClicked = "contribution_linkedin_clicked"
    }

    private enum LegacyDictationStyleCodingKeys: String, CodingKey {
        case dictationStyleCategoryAssignments = "dictation_style_category_assignments"
        case dictationStyleAppRules = "dictation_style_app_rules"
        case dictationStyleDomainRules = "dictation_style_domain_rules"
        case showDictationFocusReminder = "show_dictation_focus_reminder"
    }

    private enum LegacyLanguageCodingKeys: String, CodingKey {
        case languageProfile = "language_profile"
    }

    /// Decode precedence for `meeting_spoken_language`. The legacy probe runs
    /// first because the profile decoder's keys are optional, so `{}` and
    /// `{"mode":"automatic"}` would both read as a valid automatic profile.
    /// A legacy `{mode, language}` object was never user-authored and copies
    /// the already-migrated dictation profile; a valid profile shape wins;
    /// anything else (absent, non-object, unknown code, dominant outside the
    /// set) also copies dictation. `{}` is the profile decoder's empty case.
    private static func decodeMeetingSpokenLanguage(
        from container: KeyedDecodingContainer<CodingKeys>,
        dictation: SpokenLanguageProfile
    ) -> SpokenLanguageProfile {
        if let legacy = try? container.nestedContainer(
            keyedBy: LegacyMeetingSpokenLanguageSelection.CodingKeys.self,
            forKey: .meetingSpokenLanguage
        ), legacy.contains(.mode) {
            fputs("[muesli-native] meeting_spoken_language uses the legacy mode shape; copying the dictation languages\n", stderr)
            return dictation
        }
        return (try? container.decode(
            SpokenLanguageProfile.self,
            forKey: .meetingSpokenLanguage
        )) ?? dictation
    }

    /// Decode-only adapter naming the legacy `{mode, language}` shape that
    /// `meeting_spoken_language` carried before it became a `SpokenLanguageProfile`.
    /// Legacy-ness is decided by the presence of the `mode` key, never by whether
    /// this adapter decodes; it exists so the keys have one named owner.
    enum LegacyMeetingSpokenLanguageSelection: Decodable, Equatable {
        case automatic
        case explicit(TranscriptionLanguage)

        enum CodingKeys: String, CodingKey { case mode, language }
        private enum Mode: String, Decodable { case automatic, explicit }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Mode.self, forKey: .mode) {
            case .automatic:
                self = .automatic
            case .explicit:
                self = .explicit(try container.decode(TranscriptionLanguage.self, forKey: .language))
            }
        }
    }

    struct RetiredASRBackendMigrationOutcome {
        let dictation: BackendOption?
        let meetingTranscription: BackendOption?
        let notice: RetiredASRBackendNotice
    }

    /// Maps every persisted selection of a removed backend onto its measured
    /// replacement, and describes the result for the user.
    ///
    /// `meeting_live_caption_backend` never admitted `qwen` as a value, so there is
    /// nothing to rewrite there — `MeetingLiveCaptionBackend.resolved` already coerces
    /// an unknown value to the default. A hand-edited config that names a removed
    /// backend is still reported, because the user's live captions did change model.
    static func migratingRetiredASRBackends(
        dictationBackend: String,
        meetingBackend: String,
        liveCaptionBackend: String?,
        languageProfile: LanguageProfile
    ) -> RetiredASRBackendMigrationOutcome? {
        let retiredDictation = RetiredASRBackend.resolve(backend: dictationBackend)
        let retiredMeeting = RetiredASRBackend.resolve(backend: meetingBackend)
        let retiredLiveCaption = RetiredASRBackend.resolve(backend: liveCaptionBackend)
        guard let retired = retiredDictation ?? retiredMeeting ?? retiredLiveCaption else {
            return nil
        }

        let replacement = RetiredASRBackendMigration.replacement(for: languageProfile)
        var changes: [RetiredASRBackendNotice.Change] = []
        if retiredDictation != nil {
            changes.append(.init(surface: "Dictation", replacementLabel: replacement.label))
        }
        if retiredMeeting != nil {
            changes.append(.init(surface: "Meeting transcription", replacementLabel: replacement.label))
        }
        if retiredLiveCaption != nil {
            changes.append(.init(
                surface: "Live meeting captions",
                replacementLabel: MeetingLiveCaptionBackend.defaultBackend.label
            ))
        }

        return RetiredASRBackendMigrationOutcome(
            dictation: retiredDictation == nil ? nil : replacement,
            meetingTranscription: retiredMeeting == nil ? nil : replacement,
            notice: RetiredASRBackendNotice(
                retiredLabel: retired.label,
                reason: retired.removalReason,
                changes: changes
            )
        )
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyDictationStyleCodingKeys.self)
        let legacyLanguage = try decoder.container(keyedBy: LegacyLanguageCodingKeys.self)
        let defaults = AppConfig()
        dictationHotkey = (try? c.decode(HotkeyConfig.self, forKey: .dictationHotkey)) ?? defaults.dictationHotkey
        quilHotkey = (try? c.decode(HotkeyConfig.self, forKey: .quilHotkey)) ?? defaults.quilHotkey
        enableQuilMode = (try? c.decode(Bool.self, forKey: .enableQuilMode)) ?? defaults.enableQuilMode
        computerUseHotkey = (try? c.decode(HotkeyConfig.self, forKey: .computerUseHotkey))
            ?? HotkeyConfig.computerUseDefault(avoiding: dictationHotkey)
        let hasAppliedComputerUseHotkeyDefaultMigration = c.contains(.computerUseHotkeyDefaultDisabledMigrationApplied)
        enableComputerUseHotkey = hasAppliedComputerUseHotkeyDefaultMigration
            ? ((try? c.decode(Bool.self, forKey: .enableComputerUseHotkey)) ?? defaults.enableComputerUseHotkey)
            : false
        computerUseHotkeyDefaultDisabledMigrationApplied = true
        meetingRecordingHotkey = (try? c.decode(HotkeyConfig.self, forKey: .meetingRecordingHotkey)) ?? defaults.meetingRecordingHotkey
        enableMeetingRecordingHotkey = (try? c.decode(Bool.self, forKey: .enableMeetingRecordingHotkey)) ?? defaults.enableMeetingRecordingHotkey
        enableComputerUsePlanner = (try? c.decode(Bool.self, forKey: .enableComputerUsePlanner)) ?? defaults.enableComputerUsePlanner
        computerUsePlannerModel = SummaryModelPreset.migratedFromGPT55(
            (try? c.decode(String.self, forKey: .computerUsePlannerModel)) ?? defaults.computerUsePlannerModel
        )
        computerUseTimeoutSeconds = (try? c.decode(Int.self, forKey: .computerUseTimeoutSeconds)) ?? defaults.computerUseTimeoutSeconds
        sttBackend = (try? c.decode(String.self, forKey: .sttBackend)) ?? defaults.sttBackend
        sttModel = (try? c.decode(String.self, forKey: .sttModel)) ?? defaults.sttModel
        dictationInputDeviceUID = try? c.decode(String.self, forKey: .dictationInputDeviceUID)
        meetingInputDeviceUID = try? c.decode(String.self, forKey: .meetingInputDeviceUID)
        appleSpeechLanguage = AppleSpeechLanguageOption.normalize(try? c.decode(String.self, forKey: .appleSpeechLanguage))
        let legacyCohereLanguage = try? c.decode(String.self, forKey: .cohereLanguage)
        let legacyIndicASRLanguage = try? c.decode(String.self, forKey: .indicASRLanguage)
        let legacyNemotron35Language = try? c.decode(String.self, forKey: .nemotron35Language)
        let legacyWhisperLanguage = try? c.decode(String.self, forKey: .whisperLanguage)
        cohereLanguage = CohereTranscribeLanguage.resolvedCode(legacyCohereLanguage)
        indicASRLanguage = IndicASRLanguage.resolvedCode(legacyIndicASRLanguage)
        nemotron35Language = Nemotron35Language.resolvedCode(legacyNemotron35Language)
        whisperLanguage = WhisperKitLanguage.resolvedCode(legacyWhisperLanguage)
        let legacyMigration: (profile: LanguageProfile, needsConfirmation: Bool)
        if let decodedProfile = try? legacyLanguage.decode(
            LanguageProfile.self,
            forKey: .languageProfile
        ) {
            legacyMigration = (decodedProfile, false)
        } else {
            legacyMigration = LanguageProfile.migratingLegacyPins(
                cohere: legacyCohereLanguage,
                indicASR: legacyIndicASRLanguage,
                nemotron35: legacyNemotron35Language,
                whisper: legacyWhisperLanguage
            )
        }
        let legacyProfile = legacyMigration.profile
        dictationLanguageProfile = (try? c.decode(
            SpokenLanguageProfile.self,
            forKey: .dictationLanguageProfile
        )) ?? (try? SpokenLanguageProfile(
            selectedLanguages: legacyProfile.selectedLanguages,
            dominantLanguage: legacyProfile.dominantLanguage
        )) ?? .automatic
        meetingSpokenLanguage = Self.decodeMeetingSpokenLanguage(
            from: c,
            dictation: dictationLanguageProfile
        )
        meetingArtifactLanguagePolicy = (try? c.decode(
            MeetingArtifactLanguagePolicy.self,
            forKey: .meetingArtifactLanguagePolicy
        )) ?? legacyProfile.meetingOutputPolicy.artifactPolicy(
            dominantLanguage: legacyProfile.dominantLanguage
        )
        languageProfileNeedsConfirmation =
            (try? c.decode(Bool.self, forKey: .languageProfileNeedsConfirmation))
            ?? legacyMigration.needsConfirmation
        meetingTranscriptionBackend = (try? c.decode(String.self, forKey: .meetingTranscriptionBackend)) ?? sttBackend
        meetingTranscriptionModel = (try? c.decode(String.self, forKey: .meetingTranscriptionModel)) ?? sttModel
        retiredASRBackendNotice = try? c.decode(RetiredASRBackendNotice.self, forKey: .retiredASRBackendNotice)
        // R3. Every persisted selection that still names a removed backend is rewritten
        // here, before anything downstream can read it, and the rewrite is recorded so
        // the user is told rather than quietly moved.
        if let migration = Self.migratingRetiredASRBackends(
            dictationBackend: sttBackend,
            meetingBackend: meetingTranscriptionBackend,
            liveCaptionBackend: try? c.decode(String.self, forKey: .meetingLiveCaptionBackend),
            languageProfile: languageProfile
        ) {
            if let replacement = migration.dictation {
                sttBackend = replacement.backend
                sttModel = replacement.model
            }
            if let replacement = migration.meetingTranscription {
                meetingTranscriptionBackend = replacement.backend
                meetingTranscriptionModel = replacement.model
            }
            retiredASRBackendNotice = migration.notice
            retiredASRBackendMigrationApplied = true
        }
        meetingSummaryBackend = (try? c.decode(String.self, forKey: .meetingSummaryBackend)) ?? defaults.meetingSummaryBackend
        defaultMeetingTemplateID = (try? c.decode(String.self, forKey: .defaultMeetingTemplateID)) ?? defaults.defaultMeetingTemplateID
        whisperModel = (try? c.decode(String.self, forKey: .whisperModel)) ?? defaults.whisperModel
        idleTimeout = (try? c.decode(Double.self, forKey: .idleTimeout)) ?? defaults.idleTimeout
        autoRecordMeetings = (try? c.decode(Bool.self, forKey: .autoRecordMeetings)) ?? defaults.autoRecordMeetings
        if c.contains(.upcomingMeetingsDayCount) {
            upcomingMeetingsDayCount = UpcomingMeetingsWindow
                .resolve(dayCount: try? c.decode(Int.self, forKey: .upcomingMeetingsDayCount))
                .dayCount
        } else {
            upcomingMeetingsDayCount = UpcomingMeetingsWindow.threeDays.dayCount
        }
        let decodedShowMeetingDetectionNotification = try? c.decode(Bool.self, forKey: .showMeetingDetectionNotification)
        showScheduledMeetingNotifications =
            (try? c.decode(Bool.self, forKey: .showScheduledMeetingNotifications))
            ?? decodedShowMeetingDetectionNotification
            ?? defaults.showScheduledMeetingNotifications
        scheduledMeetingNotificationLeadTime =
            (try? c.decode(ScheduledMeetingNotificationLeadTime.self, forKey: .scheduledMeetingNotificationLeadTime))
            ?? defaults.scheduledMeetingNotificationLeadTime
        meetingJoinDefaultAction =
            (try? c.decode(MeetingJoinDefaultAction.self, forKey: .meetingJoinDefaultAction))
            ?? defaults.meetingJoinDefaultAction
        showMeetingDetectionNotification = decodedShowMeetingDetectionNotification ?? defaults.showMeetingDetectionNotification
        mutedMeetingDetectionAppBundleIDs = (try? c.decode([String].self, forKey: .mutedMeetingDetectionAppBundleIDs)) ?? defaults.mutedMeetingDetectionAppBundleIDs
        dictationRecordingSavePolicy =
            (try? c.decode(DictationRecordingSavePolicy.self, forKey: .dictationRecordingSavePolicy))
            ?? defaults.dictationRecordingSavePolicy
        meetingRecordingSavePolicy = (try? c.decode(MeetingRecordingSavePolicy.self, forKey: .meetingRecordingSavePolicy)) ?? defaults.meetingRecordingSavePolicy
        let decodedMeetingRecordingFileFormat = (try? c.decode(String.self, forKey: .meetingRecordingFileFormat))
            ?? defaults.meetingRecordingFileFormat
        meetingRecordingFileFormat = MeetingRecordingFileFormat(rawValue: decodedMeetingRecordingFileFormat)?.rawValue
            ?? defaults.meetingRecordingFileFormat
        waveformCacheOrphanCleanupMigrationApplied =
            (try? c.decode(Bool.self, forKey: .waveformCacheOrphanCleanupMigrationApplied))
            ?? defaults.waveformCacheOrphanCleanupMigrationApplied
        darkMode = (try? c.decode(Bool.self, forKey: .darkMode)) ?? defaults.darkMode
        iCloudSyncEnabled = (try? c.decode(Bool.self, forKey: .iCloudSyncEnabled)) ?? defaults.iCloudSyncEnabled
        showIOSCompanionPrompt = (try? c.decode(Bool.self, forKey: .showIOSCompanionPrompt)) ?? defaults.showIOSCompanionPrompt
        enableDoubleTapDictation = (try? c.decode(Bool.self, forKey: .enableDoubleTapDictation)) ?? defaults.enableDoubleTapDictation
        hotkeyTriggerThresholdMS = HotkeyTriggerTiming.clampedMilliseconds(
            (try? c.decode(Int.self, forKey: .hotkeyTriggerThresholdMS)) ?? defaults.hotkeyTriggerThresholdMS
        )
        quilHotkeyTriggerThresholdMS = HotkeyTriggerTiming.clampedMilliseconds(
            (try? c.decode(Int.self, forKey: .quilHotkeyTriggerThresholdMS)) ?? defaults.quilHotkeyTriggerThresholdMS
        )
        computerUseHotkeyTriggerThresholdMS = HotkeyTriggerTiming.clampedMilliseconds(
            (try? c.decode(Int.self, forKey: .computerUseHotkeyTriggerThresholdMS)) ?? hotkeyTriggerThresholdMS
        )
        meetingRecordingHotkeyTriggerThresholdMS = HotkeyTriggerTiming.clampedMilliseconds(
            (try? c.decode(Int.self, forKey: .meetingRecordingHotkeyTriggerThresholdMS))
                ?? defaults.meetingRecordingHotkeyTriggerThresholdMS
        )
        launchAtLogin = (try? c.decode(Bool.self, forKey: .launchAtLogin)) ?? defaults.launchAtLogin
        openDashboardOnLaunch = (try? c.decode(Bool.self, forKey: .openDashboardOnLaunch)) ?? defaults.openDashboardOnLaunch
        showFloatingIndicator = (try? c.decode(Bool.self, forKey: .showFloatingIndicator)) ?? defaults.showFloatingIndicator
        showDictationIdleDot =
            (try? c.decode(Bool.self, forKey: .showDictationIdleDot))
            ?? (try? legacy.decode(Bool.self, forKey: .showDictationFocusReminder))
            ?? defaults.showDictationIdleDot
        showMeetingRecordButton =
            (try? c.decode(Bool.self, forKey: .showMeetingRecordButton))
            ?? defaults.showMeetingRecordButton
        showHotkeyOnFloatingIndicator =
            (try? c.decode(Bool.self, forKey: .showHotkeyOnFloatingIndicator))
            ?? defaults.showHotkeyOnFloatingIndicator
        indicatorHoverStyle =
            (try? c.decode(IndicatorHoverStyle.self, forKey: .indicatorHoverStyle))
            ?? defaults.indicatorHoverStyle
        indicatorAnchor = (try? c.decode(IndicatorAnchor.self, forKey: .indicatorAnchor))
            ?? ((try? c.decodeIfPresent(CGPointCodable.self, forKey: .indicatorOrigin)) != nil ? .custom : .midTrailing)
        dashboardWindowFrame = try? c.decode(WindowFrame.self, forKey: .dashboardWindowFrame)
        indicatorOrigin = try? c.decode(CGPointCodable.self, forKey: .indicatorOrigin)
        meetingRecordingPanelCenter = try? c.decode(CGPointCodable.self, forKey: .meetingRecordingPanelCenter)
        meetingPanelOpen = try? c.decode(Bool.self, forKey: .meetingPanelOpen)
        openAIAPIKey = (try? c.decode(String.self, forKey: .openAIAPIKey)) ?? defaults.openAIAPIKey
        openRouterAPIKey = (try? c.decode(String.self, forKey: .openRouterAPIKey)) ?? defaults.openRouterAPIKey
        openAIModel = SummaryModelPreset.migratedFromGPT55(
            (try? c.decode(String.self, forKey: .openAIModel)) ?? defaults.openAIModel
        )
        openRouterModel = (try? c.decode(String.self, forKey: .openRouterModel)) ?? defaults.openRouterModel
        chatGPTModel = SummaryModelPreset.supportedChatGPTModel(
            SummaryModelPreset.migratedFromGPT55(
                (try? c.decode(String.self, forKey: .chatGPTModel)) ?? defaults.chatGPTModel
            )
        )
        meetingSummaryRetryCount = MeetingSummaryRetryPolicy.clampedRetryCount(
            (try? c.decode(Int.self, forKey: .meetingSummaryRetryCount)) ?? defaults.meetingSummaryRetryCount
        )
        ollamaURL = (try? c.decode(String.self, forKey: .ollamaURL)) ?? defaults.ollamaURL
        ollamaModel = (try? c.decode(String.self, forKey: .ollamaModel)) ?? defaults.ollamaModel
        lmStudioURL = (try? c.decode(String.self, forKey: .lmStudioURL)) ?? defaults.lmStudioURL
        lmStudioModel = (try? c.decode(String.self, forKey: .lmStudioModel)) ?? defaults.lmStudioModel
        customLLMURL = (try? c.decode(String.self, forKey: .customLLMURL)) ?? defaults.customLLMURL
        customLLMAPIKey = (try? c.decode(String.self, forKey: .customLLMAPIKey)) ?? defaults.customLLMAPIKey
        customLLMModel = (try? c.decode(String.self, forKey: .customLLMModel)) ?? defaults.customLLMModel
        let decodedCustomLLMFormat = (try? c.decode(String.self, forKey: .customLLMFormat)) ?? defaults.customLLMFormat
        customLLMFormat = CustomLLMFormat(rawValue: decodedCustomLLMFormat)?.rawValue ?? defaults.customLLMFormat
        summaryModel = (try? c.decode(String.self, forKey: .summaryModel)) ?? defaults.summaryModel
        meetingSummaryModel = (try? c.decode(String.self, forKey: .meetingSummaryModel)) ?? defaults.meetingSummaryModel
        hasCompletedOnboarding = (try? c.decode(Bool.self, forKey: .hasCompletedOnboarding)) ?? defaults.hasCompletedOnboarding
        let decodedOnboardingUseCase = try? c.decode(String.self, forKey: .onboardingUseCase)
        if let decodedOnboardingUseCase,
           OnboardingUseCase(rawValue: decodedOnboardingUseCase) != nil {
            onboardingUseCase = decodedOnboardingUseCase
        } else if hasCompletedOnboarding {
            onboardingUseCase = OnboardingUseCase.dictationAndMeetings.rawValue
        } else {
            onboardingUseCase = defaults.onboardingUseCase
        }
        userName = (try? c.decode(String.self, forKey: .userName)) ?? defaults.userName
        customMeetingTemplates = (try? c.decode([CustomMeetingTemplate].self, forKey: .customMeetingTemplates)) ?? defaults.customMeetingTemplates
        customWords = (try? c.decode([CustomWord].self, forKey: .customWords)) ?? defaults.customWords
        dictionarySuggestions = (try? c.decode([DictionarySuggestion].self, forKey: .dictionarySuggestions)) ?? defaults.dictionarySuggestions
        dismissedDictionarySuggestionKeys = (try? c.decode([String].self, forKey: .dismissedDictionarySuggestionKeys)) ?? defaults.dismissedDictionarySuggestionKeys
        enableDictionaryCorrectionPrompts = (try? c.decode(Bool.self, forKey: .enableDictionaryCorrectionPrompts)) ?? defaults.enableDictionaryCorrectionPrompts
        enableAutomaticDiagnosticIssuePrompts = (try? c.decode(Bool.self, forKey: .enableAutomaticDiagnosticIssuePrompts)) ?? defaults.enableAutomaticDiagnosticIssuePrompts
        folderOrder = (try? c.decode([Int64].self, forKey: .folderOrder)) ?? defaults.folderOrder
        soundEnabled = (try? c.decode(Bool.self, forKey: .soundEnabled)) ?? defaults.soundEnabled
        quilSoundEnabled = (try? c.decode(Bool.self, forKey: .quilSoundEnabled)) ?? defaults.quilSoundEnabled
        pauseMediaDuringDictation = (try? c.decode(Bool.self, forKey: .pauseMediaDuringDictation)) ?? defaults.pauseMediaDuringDictation
        muteSystemAudioDuringDictation = (try? c.decode(Bool.self, forKey: .muteSystemAudioDuringDictation)) ?? defaults.muteSystemAudioDuringDictation
        recordingColorHex = (try? c.decode(String.self, forKey: .recordingColorHex)) ?? defaults.recordingColorHex
        accentSelectionMigrated =
            (try? c.decode(Bool.self, forKey: .accentSelectionMigrated)) ?? defaults.accentSelectionMigrated
        if !accentSelectionMigrated {
            // The legacy value meant "no override" to every shipping build, so mapping it to
            // the marker keeps existing installs rendering exactly as they do today.
            if recordingColorHex == AppConfig.legacyDefaultAccentHex {
                recordingColorHex = AppConfig.defaultAccentMarker
            }
            accentSelectionMigrated = true
        }
        menuBarIcon = (try? c.decode(String.self, forKey: .menuBarIcon)) ?? defaults.menuBarIcon
        showHotkeyInMenuBar =
            (try? c.decode(Bool.self, forKey: .showHotkeyInMenuBar))
            ?? defaults.showHotkeyInMenuBar
        showNextMeetingInMenuBar = (try? c.decode(Bool.self, forKey: .showNextMeetingInMenuBar)) ?? defaults.showNextMeetingInMenuBar
        maraudersMapUnlocked = (try? c.decode(Bool.self, forKey: .maraudersMapUnlocked)) ?? defaults.maraudersMapUnlocked
        maraudersMapAudioClip = (try? c.decode(String.self, forKey: .maraudersMapAudioClip)) ?? defaults.maraudersMapAudioClip
        maraudersMapCustomAudioPath = try? c.decode(String.self, forKey: .maraudersMapCustomAudioPath)
        hiddenCalendarEventIDs = (try? c.decode([String].self, forKey: .hiddenCalendarEventIDs)) ?? defaults.hiddenCalendarEventIDs
        hiddenCalendarEventSourceHints = (try? c.decode(
            [String: String].self,
            forKey: .hiddenCalendarEventSourceHints
        )) ?? defaults.hiddenCalendarEventSourceHints
        disabledCalendarIDs = (try? c.decode([String].self, forKey: .disabledCalendarIDs)) ?? defaults.disabledCalendarIDs
        enablePostProcessor = (try? c.decode(Bool.self, forKey: .enablePostProcessor)) ?? defaults.enablePostProcessor
        customInstructions = (try? c.decode(String.self, forKey: .customInstructions)) ?? defaults.customInstructions
        enableMeetingTranscriptCleanup = (try? c.decode(Bool.self, forKey: .enableMeetingTranscriptCleanup))
            ?? defaults.enableMeetingTranscriptCleanup
        meetingTranscriptCleanupConsentFingerprint = try? c.decode(
            String.self,
            forKey: .meetingTranscriptCleanupConsentFingerprint
        )
        quilBackend = TranscriptCleanupBackendOption
            .resolved(try? c.decode(String.self, forKey: .quilBackend))
            .backend
        let decodedQuilModel = (try? c.decode(String.self, forKey: .quilModel)) ?? defaults.quilModel
        quilModel = quilBackend == TranscriptCleanupBackendOption.local.backend
            && !PostProcessorOption.resolve(id: decodedQuilModel).supportsQuil
            ? PostProcessorOption.defaultQuilOption.id
            : decodedQuilModel
        postProcessorBackend = TranscriptCleanupBackendOption
            .resolved(try? c.decode(String.self, forKey: .postProcessorBackend))
            .backend
        postProcessorIdleUnloadMinutes = PostProcessorIdleUnloadPolicy.resolvedIdleMinutes(
            (try? c.decode(Int.self, forKey: .postProcessorIdleUnloadMinutes)) ?? defaults.postProcessorIdleUnloadMinutes
        )
        postProcessorGemmaModel = Gemma4LiteRTModel
            .resolved(try? c.decode(String.self, forKey: .postProcessorGemmaModel))
            .repoID
        activePostProcessorId = (try? c.decode(String.self, forKey: .activePostProcessorId)) ?? defaults.activePostProcessorId
        postProcessorChatGPTModel = SummaryModelPreset.supportedChatGPTModel(
            SummaryModelPreset.migratedFromGPT55(
                (try? c.decode(String.self, forKey: .postProcessorChatGPTModel)) ?? defaults.postProcessorChatGPTModel
            )
        )
        postProcessorOpenAIModel = SummaryModelPreset.migratedFromGPT55(
            (try? c.decode(String.self, forKey: .postProcessorOpenAIModel)) ?? defaults.postProcessorOpenAIModel
        )
        postProcessorOpenRouterModel = (try? c.decode(String.self, forKey: .postProcessorOpenRouterModel)) ?? defaults.postProcessorOpenRouterModel
        postProcessorOllamaModel = (try? c.decode(String.self, forKey: .postProcessorOllamaModel)) ?? defaults.postProcessorOllamaModel
        postProcessorLMStudioModel = (try? c.decode(String.self, forKey: .postProcessorLMStudioModel)) ?? defaults.postProcessorLMStudioModel
        postProcessorCustomLLMModel = (try? c.decode(String.self, forKey: .postProcessorCustomLLMModel)) ?? defaults.postProcessorCustomLLMModel
        customTranscriptCleanupPrompts = (try? c.decode([CustomTranscriptCleanupPrompt].self, forKey: .customTranscriptCleanupPrompts)) ?? defaults.customTranscriptCleanupPrompts
        activeTranscriptCleanupPromptId = (try? c.decode(String.self, forKey: .activeTranscriptCleanupPromptId)) ?? defaults.activeTranscriptCleanupPromptId
        postProcessorSystemPrompt = (try? c.decode(String.self, forKey: .postProcessorSystemPrompt)) ?? defaults.postProcessorSystemPrompt
        adaptiveDictationStylesEnabled = (try? c.decode(Bool.self, forKey: .adaptiveDictationStylesEnabled)) ?? defaults.adaptiveDictationStylesEnabled
        dictationStyleRulesetInitialized = (try? c.decode(Bool.self, forKey: .dictationStyleRulesetInitialized)) ?? false
        if c.contains(.dictationStyleGroups) {
            do { dictationStyleGroups = try c.decode([DictationStyleGroup].self, forKey: .dictationStyleGroups) }
            catch { dictationStyleGroups = []; dictationStyleRulesetQuarantineReason = "Invalid dictation_style_groups: \(error.localizedDescription)" }
        }
        if c.contains(.dictationStyleExactExceptions) {
            do { dictationStyleExactExceptions = try c.decode([DictationStyleExactException].self, forKey: .dictationStyleExactExceptions) }
            catch { dictationStyleExactExceptions = []; dictationStyleRulesetQuarantineReason = "Invalid dictation_style_exact_exceptions: \(error.localizedDescription)" }
        }
        dictationStyleCategoryAssignments = (try? legacy.decode([String: String].self, forKey: .dictationStyleCategoryAssignments)) ?? defaults.dictationStyleCategoryAssignments
        dictationStyleAppRules = (try? legacy.decode([DictationStyleAppRule].self, forKey: .dictationStyleAppRules)) ?? defaults.dictationStyleAppRules
        dictationStyleDomainRules = (try? legacy.decode([DictationStyleDomainRule].self, forKey: .dictationStyleDomainRules)) ?? defaults.dictationStyleDomainRules
        enableScreenContext = (try? c.decode(Bool.self, forKey: .enableScreenContext)) ?? defaults.enableScreenContext
        enableDictationOCRContext = (try? c.decode(Bool.self, forKey: .enableDictationOCRContext)) ?? defaults.enableDictationOCRContext
        useCoreAudioTap = (try? c.decode(Bool.self, forKey: .useCoreAudioTap)) ?? defaults.useCoreAudioTap
        enableLiveStreamingPartials = (try? c.decode(Bool.self, forKey: .enableLiveStreamingPartials)) ?? defaults.enableLiveStreamingPartials
        meetingLiveCaptionBackend = MeetingLiveCaptionBackend
            .resolved(try? c.decode(String.self, forKey: .meetingLiveCaptionBackend))
            .rawValue
        useLiveMeetingTranscriptAsFinal = (try? c.decode(Bool.self, forKey: .useLiveMeetingTranscriptAsFinal))
            ?? defaults.useLiveMeetingTranscriptAsFinal
        meetingHookEnabled = (try? c.decode(Bool.self, forKey: .meetingHookEnabled)) ?? defaults.meetingHookEnabled
        meetingHookPath = (try? c.decode(String.self, forKey: .meetingHookPath)) ?? defaults.meetingHookPath
        meetingHookTimeoutSeconds = (try? c.decode(Int.self, forKey: .meetingHookTimeoutSeconds)) ?? defaults.meetingHookTimeoutSeconds
        autoExportMarkdownEnabled = (try? c.decode(Bool.self, forKey: .autoExportMarkdownEnabled)) ?? defaults.autoExportMarkdownEnabled
        autoExportMarkdownFolderPath = (try? c.decode(String.self, forKey: .autoExportMarkdownFolderPath)) ?? defaults.autoExportMarkdownFolderPath
        let decodedAutoExportMarkdownContent = (try? c.decode(String.self, forKey: .autoExportMarkdownContent)) ?? defaults.autoExportMarkdownContent
        autoExportMarkdownContent = MeetingExportContent(rawValue: decodedAutoExportMarkdownContent)?.rawValue ?? defaults.autoExportMarkdownContent
        let decodedAutoExportFileFormat = (try? c.decode(String.self, forKey: .autoExportFileFormat)) ?? defaults.autoExportFileFormat
        autoExportFileFormat = MeetingAutoExportFileFormat(rawValue: decodedAutoExportFileFormat)?.rawValue ?? defaults.autoExportFileFormat
        contributionPromptNextWordCount = try? c.decode(Int.self, forKey: .contributionPromptNextWordCount)
        contributionPromptNextMeetingCount = try? c.decode(Int.self, forKey: .contributionPromptNextMeetingCount)
        contributionGitHubStarClicked = (try? c.decode(Bool.self, forKey: .contributionGitHubStarClicked)) ?? defaults.contributionGitHubStarClicked
        contributionBuyMeCoffeeClicked = (try? c.decode(Bool.self, forKey: .contributionBuyMeCoffeeClicked)) ?? defaults.contributionBuyMeCoffeeClicked
        contributionTweetClicked = (try? c.decode(Bool.self, forKey: .contributionTweetClicked)) ?? defaults.contributionTweetClicked
        contributionLinkedInClicked = (try? c.decode(Bool.self, forKey: .contributionLinkedInClicked)) ?? defaults.contributionLinkedInClicked
        let sanitizedStyles = DictationStyleResolver.sanitizeConfiguration(self)
        customTranscriptCleanupPrompts = sanitizedStyles.customTranscriptCleanupPrompts
        dictationStyleCategoryAssignments = sanitizedStyles.dictationStyleCategoryAssignments
        dictationStyleAppRules = sanitizedStyles.dictationStyleAppRules
        dictationStyleDomainRules = sanitizedStyles.dictationStyleDomainRules
        if !dictationStyleRulesetInitialized,
           dictationStyleGroups.isEmpty,
           dictationStyleExactExceptions.isEmpty {
            let migration = DictationStyleResolver.projectLegacyConfiguration(self)
            dictationStyleRulesetInitialized = migration.initialized
            dictationStyleGroups = migration.groups
            dictationStyleExactExceptions = migration.exceptions
        }
        if TranscriptCleanupPrompts.resolveOptional(
            id: activeTranscriptCleanupPromptId,
            custom: customTranscriptCleanupPrompts
        ) == nil {
            activeTranscriptCleanupPromptId = defaults.activeTranscriptCleanupPromptId
            postProcessorSystemPrompt = defaults.postProcessorSystemPrompt
        }
        MeetingTranscriptCleanupPolicy.reconcileConsent(in: &self)
    }

    /// Read-only hybrid projection onto the combined `LanguageProfile` for
    /// consumers that still take one. Selected and dominant languages come from
    /// the dictation authority; `meetingOutputPolicy` is derived one-to-one from
    /// `meetingArtifactLanguagePolicy` and is shared with `meetingLanguageProfile`.
    /// It never produces the legacy `dominantLanguage` case.
    @available(*, deprecated, message: "Use the split language authorities.")
    var languageProfile: LanguageProfile {
        Self.projectedLanguageProfile(
            spoken: dictationLanguageProfile,
            artifactPolicy: meetingArtifactLanguagePolicy
        )
    }

    /// Read-only projection for meeting consumers: the meeting selection plus the
    /// same artifact-derived `meetingOutputPolicy` as `languageProfile`.
    @available(*, deprecated, message: "Meeting selection plus the artifact policy; use for meeting transcription and result freezing.")
    var meetingLanguageProfile: LanguageProfile {
        Self.projectedLanguageProfile(
            spoken: meetingSpokenLanguage,
            artifactPolicy: meetingArtifactLanguagePolicy
        )
    }

    /// The `try?` fallback is unreachable from validated inputs: the spoken
    /// profile already guarantees the dominant language is selected, and the
    /// explicit policies carry no validation. It stays so an explicit policy can
    /// never be silently collapsed by a future validation arm without a test failing.
    @available(*, deprecated, message: "Projection onto the combined LanguageProfile.")
    private static func projectedLanguageProfile(
        spoken: SpokenLanguageProfile,
        artifactPolicy: MeetingArtifactLanguagePolicy
    ) -> LanguageProfile {
        (try? LanguageProfile(
            selectedLanguages: spoken.selectedLanguages,
            dominantLanguage: spoken.dominantLanguage,
            meetingOutputPolicy: artifactPolicy.outputPolicy
        )) ?? .automatic
    }

    /// Apply a finished meeting's frozen profile to the MEETING authority only.
    /// The resume merge summarizes with the languages the meeting recorded
    /// under, so it must not touch `dictationLanguageProfile`, the legacy pins,
    /// or the confirmation flag the dictation card owns (R22).
    mutating func applyFrozenMeetingLanguageProfile(_ profile: LanguageProfile) {
        meetingSpokenLanguage = (try? SpokenLanguageProfile(
            selectedLanguages: profile.selectedLanguages,
            dominantLanguage: profile.dominantLanguage
        )) ?? .automatic
        meetingArtifactLanguagePolicy = profile.meetingOutputPolicy.artifactPolicy(
            dominantLanguage: profile.dominantLanguage
        )
    }

    mutating func applyLegacyLanguageProfile(_ profile: LanguageProfile) {
        dictationLanguageProfile = (try? SpokenLanguageProfile(
            selectedLanguages: profile.selectedLanguages,
            dominantLanguage: profile.dominantLanguage
        )) ?? .automatic
        meetingSpokenLanguage = dictationLanguageProfile
        meetingArtifactLanguagePolicy = profile.meetingOutputPolicy.artifactPolicy(
            dominantLanguage: profile.dominantLanguage
        )
    }

    var resolvedCohereLanguage: CohereTranscribeLanguage {
        languageProfile.resolvedCohereLanguage
    }

    var resolvedIndicASRLanguage: IndicASRLanguage {
        languageProfile.resolvedIndicASRLanguage
    }

    var resolvedNemotron35Language: Nemotron35Language {
        languageProfile.resolvedNemotron35Language
    }

    var resolvedWhisperLanguage: WhisperKitLanguage {
        languageProfile.resolvedWhisperLanguage
    }

    mutating func mirrorLanguageProfileToLegacyPins() {
        cohereLanguage = resolvedCohereLanguage.rawValue
        indicASRLanguage = resolvedIndicASRLanguage.rawValue
        nemotron35Language = resolvedNemotron35Language.rawValue
        whisperLanguage = resolvedWhisperLanguage.rawValue
    }

    var resolvedAppleSpeechLanguage: String {
        AppleSpeechLanguageOption.normalize(appleSpeechLanguage)
    }

    var resolvedMeetingLiveCaptionBackend: MeetingLiveCaptionBackend {
        MeetingLiveCaptionBackend.resolved(meetingLiveCaptionBackend)
    }

    var resolvedOnboardingUseCase: OnboardingUseCase {
        OnboardingUseCase.resolved(onboardingUseCase)
    }

    var resolvedAutoExportMarkdownContent: MeetingExportContent {
        MeetingExportContent.resolved(autoExportMarkdownContent)
    }

    var resolvedAutoExportFileFormat: MeetingAutoExportFileFormat {
        MeetingAutoExportFileFormat.resolved(autoExportFileFormat)
    }

    var resolvedMeetingRecordingFileFormat: MeetingRecordingFileFormat {
        MeetingRecordingFileFormat.resolved(meetingRecordingFileFormat)
    }
}

extension AppConfig {
    var usesNemotronLiveMeetingTranscript: Bool {
        enableLiveStreamingPartials
            && resolvedMeetingLiveCaptionBackend == .nemotron35
    }

    var usesUnifiedNemotronMeetingTranscript: Bool {
        usesNemotronLiveMeetingTranscript && useLiveMeetingTranscriptAsFinal
    }
}

struct WindowFrame: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct CGPointCodable: Codable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(from decoder: Decoder) throws {
        if var arrayContainer = try? decoder.unkeyedContainer() {
            let x = try arrayContainer.decode(Double.self)
            let y = try arrayContainer.decode(Double.self)
            self.init(x: x, y: y)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.decode(Double.self, forKey: .x),
            y: try container.decode(Double.self, forKey: .y)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
    }

    enum CodingKeys: String, CodingKey {
        case x, y
    }
}

enum DictationState: String {
    case idle
    case preparing
    case recording
    case transcribing
}
