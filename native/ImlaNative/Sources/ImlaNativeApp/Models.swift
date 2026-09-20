import AppKit
import Foundation
import ImlaCore

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
        description: "The best English dictation. Lowest error rate, newest architecture, instant. For other languages, choose Parakeet v3.",
        recommended: true
    )

    static let parakeetMultilingual = BackendOption(
        backend: "fluidaudio",
        model: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        label: "Parakeet v3",
        sizeLabel: "~450 MB",
        description: "Fast, reliable dictation in 25 languages.",
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

    static let cohereArabic = BackendOption(
        backend: "cohere-arabic",
        model: CohereArabicModelStore.repository,
        label: "Cohere Transcribe Arabic",
        sizeLabel: "~2.4 GB",
        description: "Local transcription for Arabic dialects and Arabic–English speech. Choose Arabic or English; automatic selection uses Arabic. Results appear after you stop speaking. Also supports meeting recordings.",
        recommended: false
    )

    static let bodhanCore = BackendOption(
        backend: "bodhan", model: BodhanModel.core.rawValue,
        label: "Bodhan Core FP16", sizeLabel: "~2.46 GB FP16",
        description: "Indian-language speech in its native script. English words within Hindi or Tamil are written in that script too. Detects the language automatically, or use the language picker.", recommended: false
    )
    static let bodhanFlex = BackendOption(
        backend: "bodhan", model: BodhanModel.flex.rawValue,
        label: "Bodhan Flex FP16", sizeLabel: "~2.46 GB FP16",
        description: "For mixed-language dictation: keeps Hindi or Tamil in its own script and English words in Latin letters. Also formats spoken numbers. Try both models to compare accuracy.", recommended: false
    )

    static let bodhanCoreInt8 = BackendOption(
        backend: "bodhan", model: BodhanModel.coreInt8.rawValue,
        label: "Bodhan Core INT8", sizeLabel: "~1.27 GB",
        description: "A smaller download of Core for Indian-language speech in its native script. Detects language automatically. Uses less space; transcription can differ slightly from FP16.", recommended: false
    )
    static let bodhanFlexInt8 = BackendOption(
        backend: "bodhan", model: BodhanModel.flexInt8.rawValue,
        label: "Bodhan Flex INT8", sizeLabel: "~1.27 GB",
        description: "A smaller download of Flex for mixed-language dictation and spoken numbers. Keeps English words in Latin letters. Uses less space; transcription can differ slightly from FP16.", recommended: false
    )
    static let bodhanFamily: [BackendOption] = [.bodhanCore, .bodhanCoreInt8, .bodhanFlex, .bodhanFlexInt8]

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
        .senseVoiceSmall, .gemma4E2BLiteRT, .gemma4E4BLiteRT,
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
            + [.cohereTranscribe, .cohereArabic]
            + streaming
            + bodhanFamily
            + experimental
        // Parakeet Unified (English) and v3 (multilingual) are the preferred
        // onboarding models; Apple Speech remains available in the catalog.
        let onboardingDefault: BackendOption = .parakeetUnified
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

    /// The first-run default is Parakeet Unified (English), with Parakeet v3
    /// (multilingual) as the second candidate; Apple Speech remains available
    /// in the catalog but is not the onboarding default.
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
        // Compatibility for saved selections from the retired Indic backend.
        if backend == "indicasr" {
            return all.first { $0.backend == "bodhan" && $0.model == model } ?? .bodhanFlex
        }
        return all.first { $0.backend == backend && $0.model == model }
    }

    var isStreamingDictationBackend: Bool {
        Self.streaming.contains(self)
    }

    var supportsHostedDictationFallback: Bool {
        !isStreamingDictationBackend
    }

    static func resolveHostedDictationFallback(
        selected: BackendOption,
        available: [BackendOption]
    ) -> BackendOption? {
        let compatible = available.filter(\.supportsHostedDictationFallback)
        return compatible.contains(selected) ? selected : compatible.first
    }

    var supportsMeetingTranscription: Bool {
        !isStreamingDictationBackend
    }

    var isSystemManaged: Bool {
        backend == "apple-speech"
    }

    /// Shared OS requirements for model selection in onboarding and the library.
    /// Native `#available` checks still protect calls into newer system APIs.
    var minimumOSVersion: OperatingSystemVersion {
        switch backend {
        case "nemotron35", "qwen", "cohere", "bodhan", "gemma4-litert":
            return OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        case "apple-speech":
            return OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        default:
            return OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)
        }
    }

    func isCompatible(currentOSVersion: OperatingSystemVersion = Self.currentOSVersion) -> Bool {
        let minimum = minimumOSVersion
        return (currentOSVersion.majorVersion, currentOSVersion.minorVersion, currentOSVersion.patchVersion)
            >= (minimum.majorVersion, minimum.minorVersion, minimum.patchVersion)
    }

    /// Applies even to installed models; download state does not establish OS compatibility.
    func incompatibilityReason(currentOSVersion: OperatingSystemVersion = Self.currentOSVersion) -> String? {
        guard !isCompatible(currentOSVersion: currentOSVersion) else { return nil }
        let minimum = minimumOSVersion
        let required = minimum.minorVersion == 0 ? "\(minimum.majorVersion)" : Self.label(for: minimum)
        return "\(label) requires macOS \(required) or later (you're on macOS \(Self.label(for: currentOSVersion)))."
    }

    /// Restore only selectable, supported onboarding models (including after an OS downgrade).
    static func resolvedOnboardingBackend(
        _ preferred: BackendOption,
        currentOSVersion: OperatingSystemVersion = Self.currentOSVersion
    ) -> BackendOption {
        onboarding.contains(preferred) && preferred.isCompatible(currentOSVersion: currentOSVersion)
            ? preferred : onboardingDefault
    }

    /// Resolve once per launch, including the optional `MUESLI_DEBUG_OS_VERSION=14.8`
    /// UI preview. This does not override native API availability checks.
    static let currentOSVersion: OperatingSystemVersion = {
        if let raw = ProcessInfo.processInfo.environment["MUESLI_DEBUG_OS_VERSION"] {
            let parts = raw.split(separator: ".").compactMap { Int($0) }
            if parts.count >= 2 {
                return OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts[1], patchVersion: 0)
            }
        }
        return ProcessInfo.processInfo.operatingSystemVersion
    }()

    private static func label(for version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion)"
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
            case "cohere-arabic":
                supported = [.arabic, .english]
                supportsAuto = false
                supportsSingle = true
                fallbackLanguage = .arabic
            case "cohere":
                supported = Set(TranscriptionLanguage.allCases.filter {
                    CohereTranscribeLanguage(rawValue: $0.rawValue) != nil
                })
                supportsAuto = false
                supportsSingle = true
                fallbackLanguage = .english  // CohereTranscribeLanguage.defaultLanguage
            case "bodhan":
                supported = Set(TranscriptionLanguage.allCases.filter {
                    BodhanLanguage(rawValue: $0.rawValue) != nil
                })
                supportsAuto = false
                supportsSingle = true
                fallbackLanguage = .hindi  // BodhanLanguage.defaultLanguage
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
        case "cohere-arabic":
            return CohereArabicModelStore.isAvailable()
        case "bodhan":
            return BodhanModel(rawValue: model)?.isDownloaded ?? false
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

/// Language selection for Parakeet TDT v2/v3.
/// `auto` leaves decoding unfiltered; explicit codes enable FluidAudio's
/// script-level token filter (v3 joint decoder; v2 ignores the hint).
enum ParakeetLanguage: String, CaseIterable, Codable, Sendable {
    case auto = "auto"
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case romanian = "ro"
    case dutch = "nl"
    case danish = "da"
    case swedish = "sv"
    case finnish = "fi"
    case hungarian = "hu"
    case estonian = "et"
    case latvian = "lv"
    case lithuanian = "lt"
    case maltese = "mt"
    case polish = "pl"
    case czech = "cs"
    case slovak = "sk"
    case slovenian = "sl"
    case croatian = "hr"
    case bosnian = "bs"
    case russian = "ru"
    case ukrainian = "uk"
    case belarusian = "be"
    case bulgarian = "bg"
    case serbian = "sr"
    case greek = "el"

    static let defaultLanguage: Self = .auto

    var label: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .romanian: return "Romanian"
        case .dutch: return "Dutch"
        case .danish: return "Danish"
        case .swedish: return "Swedish"
        case .finnish: return "Finnish"
        case .hungarian: return "Hungarian"
        case .estonian: return "Estonian"
        case .latvian: return "Latvian"
        case .lithuanian: return "Lithuanian"
        case .maltese: return "Maltese"
        case .polish: return "Polish"
        case .czech: return "Czech"
        case .slovak: return "Slovak"
        case .slovenian: return "Slovenian"
        case .croatian: return "Croatian"
        case .bosnian: return "Bosnian"
        case .russian: return "Russian"
        case .ukrainian: return "Ukrainian"
        case .belarusian: return "Belarusian"
        case .bulgarian: return "Bulgarian"
        case .serbian: return "Serbian"
        case .greek: return "Greek"
        }
    }

    /// ISO code passed to FluidAudio's token language filter, or nil for auto.
    var isoCode: String? {
        switch self {
        case .auto: return nil
        default: return rawValue
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
        bodhan: String?,
        nemotron35: String?,
        whisper: String?
    ) -> (profile: LanguageProfile, needsConfirmation: Bool) {
        let selected = Set([cohere, bodhan, nemotron35, whisper].compactMap(TranscriptionLanguage.resolve))
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

    var resolvedBodhanLanguage: BodhanLanguage {
        authoritativeLanguage.flatMap { BodhanLanguage(rawValue: $0.rawValue) }
            ?? .defaultLanguage
    }

    /// Parakeet's selection is a script filter rather than a spoken-language pin,
    /// but it is still chosen from the same authority; an unrepresented language
    /// leaves it on the default rather than silently narrowing the script set.
    var resolvedParakeetLanguage: ParakeetLanguage {
        authoritativeLanguage.flatMap { ParakeetLanguage(rawValue: $0.rawValue) }
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
            case "cohere-arabic" where language == .arabic || language == .english:
                return .init(
                    kind: .pinned,
                    effectiveLanguage: language,
                    explanation: "Transcription is pinned to \(language.label)."
                )
            case "cohere-arabic":
                return .init(
                    kind: .providerFallback,
                    effectiveLanguage: .arabic,
                    explanation: "Cohere Transcribe Arabic does not support \(language.label); it will use Arabic."
                )
            case "cohere" where CohereTranscribeLanguage(rawValue: language.rawValue) != nil:
                return .init(
                    kind: .pinned,
                    effectiveLanguage: language,
                    explanation: "Transcription is pinned to \(language.label)."
                )
            case "bodhan" where BodhanLanguage(rawValue: language.rawValue) != nil:
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
            case "bodhan":
                return .init(
                    kind: .providerFallback,
                    effectiveLanguage: .hindi,
                    explanation: "Bodhan does not support \(language.label); it will use Hindi."
                )
            default:
                break
            }
        }

        if backend.backend == "cohere-arabic" {
            return .init(
                kind: .providerFallback,
                effectiveLanguage: .arabic,
                explanation: "Cohere Transcribe Arabic cannot auto-detect this profile, so it will use Arabic."
            )
        }
        if backend.backend == "cohere" {
            return .init(
                kind: .providerFallback,
                effectiveLanguage: .english,
                explanation: "Cohere cannot auto-detect this profile, so it will use English."
            )
        }
        if backend.backend == "bodhan" {
            return .init(
                kind: .providerFallback,
                effectiveLanguage: .hindi,
                explanation: "Bodhan cannot auto-detect this profile, so it will use Hindi."
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
    case appleSpeech = "apple-speech"
    case nemotron35 = "nemotron35"

    static let defaultBackend: Self = .parakeetRealtimeEOU

    var label: String {
        switch self {
        case .parakeetRealtimeEOU: return MeetingLiveCaptionModelStore.label
        case .appleSpeech: return BackendOption.appleSpeechAnalyzer.label
        case .nemotron35: return BackendOption.nemotron35Multilingual.label
        }
    }

    var settingsLabel: String {
        switch self {
        case .parakeetRealtimeEOU: return "\(label) (live preview only)"
        case .appleSpeech: return "\(label) (live + final)"
        case .nemotron35: return "\(label) (live transcript)"
        }
    }

    var producesFinalTranscript: Bool { self == .nemotron35 || self == .appleSpeech }

    var isDownloaded: Bool {
        switch self {
        case .parakeetRealtimeEOU: return MeetingLiveCaptionModelStore.isDownloaded()
        case .appleSpeech:
            if #available(macOS 26.0, *) {
                return AppleSpeechAnalyzerTranscriber.isSupportedOnCurrentSystem
            }
            return false
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

enum ReasoningEffort: String, CaseIterable, Codable, Sendable {
    case off = "none"
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var label: String {
        switch self {
        case .off: return "None"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        case .max: return "Maximum"
        }
    }
}

/// Centralizes the reasoning capabilities shared by OpenAI API and ChatGPT
/// account-backed requests. Unsupported preferences fall back to the selected
/// model's default rather than sending an invalid API value.
enum ReasoningEffortPolicy {
    private struct Capabilities {
        let efforts: [ReasoningEffort]
        let defaultEffort: ReasoningEffort
    }

    static func selectableEfforts(for model: String) -> [ReasoningEffort] {
        capabilities(for: model)?.efforts ?? []
    }

    static func defaultEffort(for model: String) -> ReasoningEffort? {
        capabilities(for: model)?.defaultEffort
    }

    static func resolvedEffort(
        for model: String,
        preferred: ReasoningEffort?
    ) -> ReasoningEffort? {
        guard let capabilities = capabilities(for: model) else { return nil }
        if let preferred, capabilities.efforts.contains(preferred) {
            return preferred
        }
        return capabilities.defaultEffort
    }

    static func apiValue(for model: String, preferred: ReasoningEffort? = nil) -> String? {
        resolvedEffort(for: model, preferred: preferred)?.rawValue
    }

    private static func capabilities(for model: String) -> Capabilities? {
        switch model.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "gpt-5.4-mini", "gpt-5.4", "gpt-5.4-nano", "gpt-5.2":
            return Capabilities(
                efforts: [.off, .low, .medium, .high, .xhigh],
                defaultEffort: .off
            )
        case "gpt-5.4-pro":
            return Capabilities(efforts: [.medium, .high, .xhigh], defaultEffort: .medium)
        case "gpt-6-astra":
            return Capabilities(
                efforts: [.low, .medium, .high, .xhigh, .max],
                defaultEffort: .high
            )
        case "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna":
            return Capabilities(
                efforts: [.off, .low, .medium, .high, .xhigh, .max],
                defaultEffort: .high
            )
        case "gpt-5-mini":
            return Capabilities(efforts: [.minimal, .low, .medium, .high], defaultEffort: .medium)
        default:
            return nil
        }
    }
}

struct SummaryModelPreset {
    let id: String
    let label: String

    static let openAIModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "gpt-5.4-mini", label: "GPT-5.4 Mini (default)"),
        SummaryModelPreset(id: "gpt-6-astra", label: "GPT-6 Astra"),
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
        SummaryModelPreset(id: "gpt-6-astra", label: "GPT-6 Astra"),
        SummaryModelPreset(id: "gpt-5.6-sol", label: "GPT-5.6 Sol"),
        SummaryModelPreset(id: "gpt-5.6-terra", label: "GPT-5.6 Terra"),
        SummaryModelPreset(id: "gpt-5.6-luna", label: "GPT-5.6 Luna"),
    ]

    static let chatGPTTranscriptCleanupModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "gpt-5.6-terra", label: "GPT-5.6 Terra (default)"),
        SummaryModelPreset(id: "gpt-6-astra", label: "GPT-6 Astra"),
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
        SummaryModelPreset(id: "gpt-6-astra", label: "GPT-6 Astra"),
        SummaryModelPreset(id: "gpt-5.6-terra", label: "GPT-5.6 Terra"),
        SummaryModelPreset(id: "gpt-5.6-luna", label: "GPT-5.6 Luna"),
        SummaryModelPreset(id: "gpt-5.4", label: "GPT-5.4"),
        SummaryModelPreset(id: "gpt-5.4-mini", label: "GPT-5.4 Mini"),
        SummaryModelPreset(id: "gpt-5.2", label: "GPT-5.2"),
    ]

    static let openRouterModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "openrouter/free", label: "OpenRouter Free (default)"),
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

    static func migratedFromGPT55(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines) == "gpt-5.5"
            ? "gpt-5.6-sol"
            : model
    }
}

struct OpenRouterModelCatalog: Decodable {
    let data: [OpenRouterModel]
}

enum OpenRouterModelSelection {
    static func persistedModelID(for selectedID: String) -> String {
        selectedID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func presetsIncludingConfiguredModel(
        _ presets: [SummaryModelPreset],
        configuredModel: String
    ) -> [SummaryModelPreset] {
        let model = persistedModelID(for: configuredModel)
        guard !model.isEmpty, !presets.contains(where: { $0.id == model }) else {
            return presets
        }
        return presets + [SummaryModelPreset(id: model, label: "Custom: \(model)")]
    }
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

    var producesTranscription: Bool {
        architecture?.outputModalities?.contains("transcription") == true
    }

    var summaryPresetLabel: String {
        if let contextLength, contextLength > 0 {
            return "\(name) (\(Self.formatContextLength(contextLength)) ctx)"
        }
        return name
    }

    var transcriptionPresetLabel: String { name }

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

    static func transcriptionPresets(from models: [OpenRouterModel]) -> [SummaryModelPreset] {
        models
            .filter(\.producesTranscription)
            .sorted {
                if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                    return $0.id < $1.id
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map { SummaryModelPreset(id: $0.id, label: $0.transcriptionPresetLabel) }
    }
}

extension MeetingSummaryBackendOption {
    var modelKeyPath: WritableKeyPath<AppConfig, String> {
        switch self {
        case .chatGPT: return \.chatGPTModel
        case .openAI: return \.openAIModel
        case .openRouter: return \.openRouterModel
        case .ollama: return \.ollamaModel
        case .lmStudio: return \.lmStudioModel
        default: return \.customLLMModel
        }
    }

    /// Copies the settings for one request without persisting a new default.
    func summaryConfiguration(from config: AppConfig, model: String) -> AppConfig {
        var snapshot = config
        snapshot.meetingSummaryBackend = backend
        snapshot[keyPath: modelKeyPath] = model
        return snapshot
    }

    func summaryModels(config: AppConfig, openRouterModels: [SummaryModelPreset]) -> [SummaryModelPreset] {
        let presets: [SummaryModelPreset]
        switch self {
        case .chatGPT: presets = SummaryModelPreset.chatGPTModels
        case .openAI: presets = SummaryModelPreset.openAIModels
        case .openRouter:
            presets = [SummaryModelPreset.openRouterModels[0]]
                + openRouterModels.filter { $0.id != "openrouter/free" }
        case .ollama: presets = [SummaryModelPreset(id: "qwen3.5", label: "qwen3.5 (default)")]
        default: presets = []
        }
        return SummaryModelPreset.menuPresets(presets, currentModel: config[keyPath: modelKeyPath])
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
        /// The existing Imla/Qwen cleanup prompt, which users may customize.
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
    let isDownloadable: Bool

    init(
        id: String,
        label: String,
        sizeLabel: String,
        description: String,
        downloadURL: URL,
        filename: String,
        inputFormat: InputFormat = .configurable,
        isDownloadable: Bool = true
    ) {
        self.id = id
        self.label = label
        self.sizeLabel = sizeLabel
        self.description = description
        self.downloadURL = downloadURL
        self.filename = filename
        self.inputFormat = inputFormat
        self.isDownloadable = isDownloadable
    }

    var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/imla/models/postproc-\(id)", isDirectory: true)
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

    /// S1-mini normalizes English transcripts only. Bodhan can emit an
    /// Indic-language transcript, so do not offer or run S1-mini for it.
    func isCompatible(with transcriptionBackend: BackendOption) -> Bool {
        inputFormat != .s1Mini || transcriptionBackend.backend != "bodhan"
    }

    /// Retained only so existing installs keep working. This option is not in
    /// the download catalogue; once its local cache is deleted, it cannot be
    /// downloaded again.
    static let legacyV2 = PostProcessorOption(
        id: "qwen3-postproc-v2",
        label: "Imla Cleanup (Legacy)",
        sizeLabel: "~390 MB",
        description: "An earlier cleanup model for Imla dictation. It handles filler words, corrections, and spoken lists, but is less consistent than the current model.",
        downloadURL: URL(string: "https://huggingface.co/phequals/qwen3-postproc-v2/resolve/main/qwen3-postproc-v2-q4_k_m.gguf")!,
        filename: "qwen3-postproc-v2-q4_k_m.gguf",
        isDownloadable: false
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

    // Fine-tuned Qwen3.5-0.8B v3 trained on Imla dictation correction data.
    static let finetunedV3 = PostProcessorOption(
        id: "qwen35-postproc-v3",
        label: "Imla Cleanup",
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

    static let all: [PostProcessorOption] = [.finetunedV3, .s1Mini, .qwen35_0_8b]
    static let defaultOption: PostProcessorOption = .finetunedV3
    static let defaultQuilOption: PostProcessorOption = .qwen35_0_8b

    /// Includes retired options that remain runnable when they are already
    /// cached locally. Keep this separate from `all` so retired models never
    /// appear as downloadable catalogue entries.
    private static let knownOptions: [PostProcessorOption] = all + [.legacyV2]

    static var downloaded: [PostProcessorOption] {
        knownOptions.filter(\.isDownloaded)
    }

    static var downloadedIDs: Set<String> {
        Set(downloaded.map(\.id))
    }

    static func resolve(id: String) -> PostProcessorOption {
        knownOptions.first { $0.id == id } ?? defaultOption
    }

    static func firstDownloaded(excluding excludedID: String? = nil) -> PostProcessorOption? {
        firstDownloaded(excluding: excludedID, downloadedIDs: downloadedIDs)
    }

    static func firstDownloaded(excluding excludedID: String? = nil, downloadedIDs: Set<String>) -> PostProcessorOption? {
        knownOptions.first { option in
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

/// How a dictation's cleanup prompt was chosen, as stored in history rows.
///
/// The first seven cases are only ever read back now: rows written before Modes
/// still carry them, and `DictationRowView` parses the stored string, so removing
/// one would blank the badge on a user's existing history.
enum DictationStyleSelectionSource: String, Codable, Equatable, Sendable {
    case exception
    case group
    case domain
    case app
    case category
    case global
    case builtInFallback = "built_in_fallback"
    case modeApp = "mode_app"
    case modeWebsite = "mode_website"
    case defaultInstructions = "default"
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

/// The key pressed once in the destination after a successful paste.
///
/// Decoded leniently: an unknown value means "no key", never a decode failure,
/// so a hand-edited or newer config can never cost the user their mode list.
enum DictationModeAutoEnter: String, Codable, CaseIterable, Sendable {
    case `return`
    case commandReturn = "command_return"
}

/// One destination-scoped dictation behavior: what to tell the cleanup model and
/// which apps and websites it applies to.
///
/// Every field decodes independently with a default (the `DictationStyleAppRule`
/// precedent). An element is lost only when it is not a JSON object at all, so a
/// single bad field can never quarantine the config or drop a user's mode.
/// `DictationModes.sanitized(_:)` owns identity, naming, and target normalization.
struct DictationMode: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var isEnabled: Bool
    var instructions: String
    var overrideDefaultInstructions: Bool
    var appBundleIDs: [String]
    var websiteHostnames: [String]
    var autoEnter: DictationModeAutoEnter?

    init(
        id: String,
        name: String,
        isEnabled: Bool = false,
        instructions: String = "",
        overrideDefaultInstructions: Bool = false,
        appBundleIDs: [String] = [],
        websiteHostnames: [String] = [],
        autoEnter: DictationModeAutoEnter? = nil
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.instructions = instructions
        self.overrideDefaultInstructions = overrideDefaultInstructions
        self.appBundleIDs = appBundleIDs
        self.websiteHostnames = websiteHostnames
        self.autoEnter = autoEnter
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isEnabled = "is_enabled"
        case instructions
        case overrideDefaultInstructions = "override_default_instructions"
        case appBundleIDs = "app_bundle_ids"
        case websiteHostnames = "website_hostnames"
        case autoEnter = "auto_enter"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? false
        instructions = (try? container.decode(String.self, forKey: .instructions)) ?? ""
        overrideDefaultInstructions =
            (try? container.decode(Bool.self, forKey: .overrideDefaultInstructions)) ?? false
        appBundleIDs = (try? container.decode([String].self, forKey: .appBundleIDs)) ?? []
        websiteHostnames = (try? container.decode([String].self, forKey: .websiteHostnames)) ?? []
        autoEnter = try? container.decode(DictationModeAutoEnter.self, forKey: .autoEnter)
    }
}

struct DictationStyleTarget: Equatable {
    let bundleID: String?
    let hostname: String?

    init(bundleID: String?, hostname: String?) {
        self.bundleID = DictationModes.normalizedBundleID(bundleID)
        self.hostname = DictationModes.normalizedHostname(hostname)
    }
}

enum TranscriptCleanupPrompts {
    static let defaultID = "default"
    static let messageID = "message"
    static let emailID = "email"
    static let writingID = "writing"
    static let codeID = "code"
    /// The retired hand-picked repair preset.
    ///
    /// Repair is now derived from the spoken-language selection, so the preset is
    /// gone; the id survives only to migrate a config that still names it (R13).
    static let legacyMixedLanguageRepairID = "mixed-language-repair"

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
            body = usesArabicExamples(profile) ? core(subject: subject) : neutral(subject: subject)
        }
        return "\(openingTag)\n\(body)\n\(closingTag)"
    }

    /// Whether the worked Arabic examples apply to this selection.
    static func hasArabicEnglishPair(_ profile: SpokenLanguageProfile) -> Bool {
        let selected = Set(profile.selectedLanguages)
        return selected.contains(.arabic) && selected.contains(.english)
    }

    /// Whether a prompt built for this profile should carry the Arabic examples.
    ///
    /// The neutral variant exists to avoid teaching examples from a script the user
    /// did not choose, so it applies only when the profile names a different
    /// bilingual pair. A profile that says nothing keeps the historical text.
    static func usesArabicExamples(_ profile: SpokenLanguageProfile) -> Bool {
        !profile.isBilingual || hasArabicEnglishPair(profile)
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

    /// Repair instructions, then the user's preferences when they set any, then the
    /// marker protocol.
    ///
    /// The marker protocol stays last so it outranks anything the preferences say:
    /// a response whose markers drifted is rejected, and a rejection discards the
    /// whole transcript (KTD7).
    static func systemPrompt(customInstructions: String, usesArabicExamples: Bool = true) -> String {
        let subject = "transcripts of meetings"
        let repair = usesArabicExamples
            ? MixedLanguageRepairPrompt.core(subject: subject)
            : MixedLanguageRepairPrompt.neutral(subject: subject)
        return repair
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

enum OnboardingCapability: String, Codable, CaseIterable, Hashable {
    case voiceNotes = "voice_notes"
    case dictation
    case meetings
}

enum OnboardingUseCase: String, Codable, CaseIterable {
    case voiceNotes = "voice_notes"
    case dictation = "dictation"
    case meetings = "meetings"
    case voiceNotesAndDictation = "voice_notes_and_dictation"
    case voiceNotesAndMeetings = "voice_notes_and_meetings"
    case dictationAndMeetings = "dictation_and_meetings"
    case everything = "everything"

    static let allCapabilities = Set(OnboardingCapability.allCases)

    var capabilities: Set<OnboardingCapability> {
        switch self {
        case .voiceNotes:
            [.voiceNotes]
        case .dictation:
            [.dictation]
        case .meetings:
            [.meetings]
        case .voiceNotesAndDictation:
            [.voiceNotes, .dictation]
        case .voiceNotesAndMeetings:
            [.voiceNotes, .meetings]
        case .dictationAndMeetings:
            [.dictation, .meetings]
        case .everything:
            Self.allCapabilities
        }
    }

    var includesDictation: Bool {
        capabilities.contains(.dictation)
    }

    var includesVoiceNotes: Bool {
        capabilities.contains(.voiceNotes)
    }

    var includesPushToTalk: Bool {
        includesVoiceNotes || includesDictation
    }

    var includesMeetings: Bool {
        capabilities.contains(.meetings)
    }

    var canSwitchToVoiceNotesOnly: Bool {
        includesDictation && !includesVoiceNotes
    }

    func toggling(_ capability: OnboardingCapability) -> OnboardingUseCase {
        var updated = capabilities
        if updated.contains(capability) {
            guard updated.count > 1 else { return self }
            updated.remove(capability)
        } else {
            updated.insert(capability)
        }
        return Self.from(capabilities: updated)
    }

    var replacingDictationWithVoiceNotes: OnboardingUseCase {
        var updated = capabilities
        updated.remove(.dictation)
        updated.insert(.voiceNotes)
        return Self.from(capabilities: updated)
    }

    static func from(capabilities: Set<OnboardingCapability>) -> OnboardingUseCase {
        let normalized = capabilities.isEmpty ? Set([OnboardingCapability.dictation]) : capabilities
        if normalized == [.voiceNotes] { return .voiceNotes }
        if normalized == [.dictation] { return .dictation }
        if normalized == [.meetings] { return .meetings }
        if normalized == [.voiceNotes, .dictation] { return .voiceNotesAndDictation }
        if normalized == [.voiceNotes, .meetings] { return .voiceNotesAndMeetings }
        if normalized == [.dictation, .meetings] { return .dictationAndMeetings }
        return .everything
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
    var enablePushToTalk: Bool = true
    var quilHotkey: HotkeyConfig = .quilDefault
    var enableQuilMode: Bool = false
    var computerUseHotkey: HotkeyConfig = .computerUseDefault
    var enableComputerUseHotkey: Bool = false
    var meetingRecordingHotkey: HotkeyConfig = .meetingRecordingDefault
    var enableMeetingRecordingHotkey: Bool = false
    var computerUseHotkeyDefaultDisabledMigrationApplied: Bool = true
    var enableComputerUsePlanner: Bool = true
    var computerUsePlannerModel: String = ""
    var computerUseReasoningEffort: ReasoningEffort?
    var computerUseTimeoutSeconds: Int = 120
    var sttBackend: String = BackendOption.parakeetUnified.backend
    var sttModel: String = BackendOption.parakeetUnified.model
    var dictationProvider: String = DictationProvider.defaultProvider.rawValue
    var openaiDictationModel: String = OpenAITranscriptionClient.defaultModel
    var openRouterDictationModel: String = ""
    var dictationInputDeviceUID: String? = nil
    var meetingInputDeviceUID: String? = nil
    var cohereLanguage: String = CohereTranscribeLanguage.defaultLanguage.rawValue
    var bodhanLanguage: String = BodhanLanguage.defaultLanguage.rawValue
    var nemotron35Language: String = Nemotron35Language.defaultLanguage.rawValue
    var whisperLanguage: String = WhisperKitLanguage.defaultLanguage.rawValue
    var parakeetLanguage: String = ParakeetLanguage.defaultLanguage.rawValue
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
    /// A menu-bar app that opens a window at login is a window the user did not
    /// ask for; the dashboard is one click away in the menu. Settings turns it
    /// back on.
    var openDashboardOnLaunch: Bool = false
    var showFloatingIndicator: Bool = true
    /// Keeps the Dictation Mini's idle dot near the focused text context while not dictating.
    var showDictationIdleDot: Bool = true
    var dictationIdleDotExcludedApps: [String] = [] {
        didSet { dictationIdleDotExcludedApps = Self.normalizedIdleDotExcludedApps(dictationIdleDotExcludedApps) }
    }

    static func normalizedIdleDotExcludedApps(_ apps: [String]) -> [String] {
        // Preferences are user-controlled input; cap both collection and identifier sizes.
        var seen = Set<String>()
        var result: [String] = []
        for raw in apps {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.count <= 255, seen.insert(id).inserted else { continue }
            result.append(id)
            if result.count == 128 { break }
        }
        return result
    }

    func allowsDictationIdleDot(in bundleID: String?) -> Bool {
        showDictationIdleDot && !dictationIdleDotExcludedApps.contains(bundleID ?? "")
    }
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
    var meetingSummaryReasoningEffort: ReasoningEffort?
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
        CustomWord(word: "imla", replacement: "imla"),
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
    var menuBarIcon: String = "imla"
    var showHotkeyInMenuBar: Bool = true
    var showNextMeetingInMenuBar: Bool = true
    var maraudersMapUnlocked: Bool = false
    var maraudersMapAudioClip: String = "bbc_world_news"
    var maraudersMapCustomAudioPath: String?
    var hiddenCalendarEventIDs: [String] = []
    var hiddenCalendarEventSourceHints: [String: String] = [:]
    var disabledCalendarIDs: [String] = []
    var enablePostProcessor: Bool = false
    /// Whether the one-time bilingual auto-enable already ran (KTD6).
    ///
    /// A latch, not a standing rule: repair turns cleanup on once for a bilingual
    /// profile, and a user who then turns it off keeps it off.
    var bilingualRepairAutoEnableApplied: Bool = false
    /// The user's standing preferences for every LLM rewrite of their words:
    /// dictation cleanup, meeting transcript cleanup, and meeting notes.
    /// Stored trimmed; `CustomInstructions` owns the cap and the prompt block.
    var customInstructions: String = ""
    /// Whether finalized meeting transcripts get an AI cleanup pass.
    ///
    /// Off by default: it costs a model pass per meeting, and depending on the
    /// configured endpoint it may send the full transcript of a private
    /// conversation to a third party.
// Retired: meeting cleanup now follows the meeting language selection (R10).
    // `enable_meeting_transcript_cleanup` and the consent fingerprint decode as
    // legacy keys and are no longer written.
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
    var transcriptCleanupReasoningEffort: ReasoningEffort?
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
    /// Destination-scoped dictation behavior, always encoded.
    ///
    /// Seeded disabled here on purpose: this memberwise default is what test
    /// fixtures and in-memory callers get, and an enabled built-in would silently
    /// change the composed prompt for anything targeting a shipped app. The
    /// fresh-install seed that turns them on lives in `ConfigStore`.
    var dictationModes: [DictationMode] = DictationModes.builtInModes(isEnabled: false)
    /// Decode-only state, deliberately outside `CodingKeys`: it tells `ConfigStore`
    /// that this decode built the mode list out of the legacy Writing Styles keys, so
    /// the result has to reach disk once. Persisting it would make every later load
    /// look like a fresh migration.
    var dictationModesMigrationApplied: Bool = false
    /// The `logMigration` messages the migration above produced, one per dropped
    /// matcher/group/exception it could not carry over losslessly (e.g. a wildcard
    /// app-bundle or hostname matcher, which the new exact-match model cannot
    /// represent). Decode-only like `dictationModesMigrationApplied` above and for
    /// the same reason: it is derived once from the legacy keys and never encoded,
    /// so persisting it would make a later load look like a fresh migration. The
    /// Modes screen shows it once and clears it in memory (`updateConfig { $0
    /// .dictationModesMigrationNotes = [] }`) when the user dismisses it; because it
    /// is never written to disk, a later reload always starts from `[]` regardless.
    var dictationModesMigrationNotes: [String] = []
    /// Lets a mode match the browser page the user is dictating into.
    ///
    /// Separate from `enableScreenContext` because the two read different things:
    /// this reads only the address to pick a mode and keeps it in memory, while
    /// screen context puts page text into the prompt and the database.
    var matchModesByWebsite: Bool = true
    var enableScreenContext: Bool = false
    var enableDictationOCRContext: Bool = false
    var useCoreAudioTap: Bool = true
    /// Gates leaked local speech out of the meeting system track before the
    /// system VAD, chunk recorder and live captions consume it.
    var meetingReverseLeakSuppression: Bool = true
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
        case enablePushToTalk = "enable_push_to_talk"
        case quilHotkey = "quil_hotkey"
        case enableQuilMode = "enable_quil_mode"
        case computerUseHotkey = "computer_use_hotkey"
        case enableComputerUseHotkey = "enable_computer_use_hotkey"
        case meetingRecordingHotkey = "meeting_recording_hotkey"
        case enableMeetingRecordingHotkey = "enable_meeting_recording_hotkey"
        case computerUseHotkeyDefaultDisabledMigrationApplied = "computer_use_hotkey_default_disabled_migration_applied"
        case enableComputerUsePlanner = "enable_computer_use_planner"
        case computerUsePlannerModel = "computer_use_planner_model"
        case computerUseReasoningEffort = "computer_use_reasoning_effort"
        case computerUseTimeoutSeconds = "computer_use_timeout_seconds"
        case sttBackend = "stt_backend"
        case sttModel = "stt_model"
        case dictationProvider = "dictation_provider"
        case openaiDictationModel = "openai_dictation_model"
        case openRouterDictationModel = "openrouter_dictation_model"
        case dictationInputDeviceUID = "dictation_input_device_uid"
        case meetingInputDeviceUID = "meeting_input_device_uid"
        case cohereLanguage = "cohere_language"
        // Retained wire key for existing language preferences and synced configs.
        case bodhanLanguage = "indic_asr_language"
        case nemotron35Language = "nemotron35_language"
        case whisperLanguage = "whisper_language"
        case parakeetLanguage = "parakeet_language"
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
        case dictationIdleDotExcludedApps = "dictation_idle_dot_excluded_apps"
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
        case meetingSummaryReasoningEffort = "meeting_summary_reasoning_effort"
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
        case bilingualRepairAutoEnableApplied = "bilingual_repair_auto_enable_applied"
        case customInstructions = "custom_instructions"
        case quilBackend = "quil_backend"
        case quilModel = "quil_model"
        case postProcessorBackend = "post_processor_backend"
        case postProcessorIdleUnloadMinutes = "post_processor_idle_unload_minutes"
        case postProcessorGemmaModel = "post_processor_gemma_model"
        case activePostProcessorId = "active_post_processor_id"
        case postProcessorChatGPTModel = "post_processor_chatgpt_model"
        case postProcessorOpenAIModel = "post_processor_openai_model"
        case transcriptCleanupReasoningEffort = "transcript_cleanup_reasoning_effort"
        case postProcessorOpenRouterModel = "post_processor_openrouter_model"
        case postProcessorOllamaModel = "post_processor_ollama_model"
        case postProcessorLMStudioModel = "post_processor_lmstudio_model"
        case postProcessorCustomLLMModel = "post_processor_custom_llm_model"
        case postProcessorSystemPrompt = "post_processor_system_prompt"
        case dictationModes = "dictation_modes"
        case matchModesByWebsite = "match_modes_by_website"
        case enableScreenContext = "enable_screen_context"
        case enableDictationOCRContext = "enable_dictation_ocr_context"
        case useCoreAudioTap = "use_core_audio_tap"
        case meetingReverseLeakSuppression = "meeting_reverse_leak_suppression"
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

    /// Decode-only keys. `AppConfig` has no custom `encode(to:)`, so a key that lives
    /// here and not in `CodingKeys` is read from an existing file and never written back.
    private enum LegacyDictationStyleCodingKeys: String, CodingKey {
        case activeTranscriptCleanupPromptId = "active_transcript_cleanup_prompt_id"
        case customTranscriptCleanupPrompts = "custom_transcript_cleanup_prompts"
        case adaptiveDictationStylesEnabled = "adaptive_dictation_styles_enabled"
        case dictationStyleRulesetInitialized = "dictation_style_ruleset_initialized"
        case dictationStyleGroups = "dictation_style_groups"
        case dictationStyleExactExceptions = "dictation_style_exact_exceptions"
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
            fputs("[imla-native] meeting_spoken_language uses the legacy mode shape; copying the dictation languages\n", stderr)
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
        dictationModel: String,
        meetingBackend: String,
        meetingModel: String,
        liveCaptionBackend: String?,
        languageProfile: LanguageProfile
    ) -> RetiredASRBackendMigrationOutcome? {
        let retiredDictation = RetiredASRBackend.resolve(backend: dictationBackend)
        let retiredMeeting = RetiredASRBackend.resolve(backend: meetingBackend)
        let retiredLiveCaption = RetiredASRBackend.resolve(backend: liveCaptionBackend)
        guard let retired = retiredDictation ?? retiredMeeting ?? retiredLiveCaption else {
            return nil
        }

        // Resolved per surface: the two can name different removed backends, and a
        // successor-based replacement depends on the model that surface had pinned.
        let dictationReplacement = RetiredASRBackendMigration.replacement(
            for: languageProfile, retired: retiredDictation, model: dictationModel
        )
        let meetingReplacement = RetiredASRBackendMigration.replacement(
            for: languageProfile, retired: retiredMeeting, model: meetingModel
        )
        var changes: [RetiredASRBackendNotice.Change] = []
        if retiredDictation != nil {
            changes.append(.init(surface: "Dictation", replacementLabel: dictationReplacement.label))
        }
        if retiredMeeting != nil {
            changes.append(.init(surface: "Meeting transcription", replacementLabel: meetingReplacement.label))
        }
        if retiredLiveCaption != nil {
            changes.append(.init(
                surface: "Live meeting captions",
                replacementLabel: MeetingLiveCaptionBackend.defaultBackend.label
            ))
        }

        return RetiredASRBackendMigrationOutcome(
            dictation: retiredDictation == nil ? nil : dictationReplacement,
            meetingTranscription: retiredMeeting == nil ? nil : meetingReplacement,
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
        let decodedEnablePushToTalk = try? c.decode(Bool.self, forKey: .enablePushToTalk)
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
        computerUseReasoningEffort = try? c.decode(
            ReasoningEffort.self,
            forKey: .computerUseReasoningEffort
        )
        computerUseTimeoutSeconds = (try? c.decode(Int.self, forKey: .computerUseTimeoutSeconds)) ?? defaults.computerUseTimeoutSeconds
        sttBackend = (try? c.decode(String.self, forKey: .sttBackend)) ?? defaults.sttBackend
        sttModel = (try? c.decode(String.self, forKey: .sttModel)) ?? defaults.sttModel
        dictationProvider = DictationProvider.resolved(try? c.decode(String.self, forKey: .dictationProvider)).rawValue
        openaiDictationModel = (try? c.decode(String.self, forKey: .openaiDictationModel)) ?? defaults.openaiDictationModel
        openRouterDictationModel = (try? c.decode(String.self, forKey: .openRouterDictationModel))
            ?? defaults.openRouterDictationModel
        dictationInputDeviceUID = try? c.decode(String.self, forKey: .dictationInputDeviceUID)
        meetingInputDeviceUID = try? c.decode(String.self, forKey: .meetingInputDeviceUID)
        appleSpeechLanguage = AppleSpeechLanguageOption.normalize(try? c.decode(String.self, forKey: .appleSpeechLanguage))
        let legacyCohereLanguage = try? c.decode(String.self, forKey: .cohereLanguage)
        let legacyBodhanLanguage = try? c.decode(String.self, forKey: .bodhanLanguage)
        let legacyNemotron35Language = try? c.decode(String.self, forKey: .nemotron35Language)
        let legacyWhisperLanguage = try? c.decode(String.self, forKey: .whisperLanguage)
        cohereLanguage = CohereTranscribeLanguage.resolvedCode(legacyCohereLanguage)
        bodhanLanguage = BodhanLanguage.resolvedCode(legacyBodhanLanguage)
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
                bodhan: legacyBodhanLanguage,
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
            dictationModel: sttModel,
            meetingBackend: meetingTranscriptionBackend,
            meetingModel: meetingTranscriptionModel,
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
        dictationIdleDotExcludedApps = Self.normalizedIdleDotExcludedApps(
            (try? c.decode([String].self, forKey: .dictationIdleDotExcludedApps)) ?? []
        )
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
        meetingSummaryReasoningEffort = try? c.decode(
            ReasoningEffort.self,
            forKey: .meetingSummaryReasoningEffort
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
        // Existing installs used the onboarding selection as runtime state. Preserve that
        // behavior once, then persist future Push to Talk changes independently.
        enablePushToTalk = decodedEnablePushToTalk
            ?? OnboardingUseCase.resolved(onboardingUseCase).includesPushToTalk
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
        bilingualRepairAutoEnableApplied = (try? c.decode(Bool.self, forKey: .bilingualRepairAutoEnableApplied))
            ?? defaults.bilingualRepairAutoEnableApplied
        customInstructions = (try? c.decode(String.self, forKey: .customInstructions)) ?? defaults.customInstructions
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
        transcriptCleanupReasoningEffort = try? c.decode(
            ReasoningEffort.self,
            forKey: .transcriptCleanupReasoningEffort
        )
        postProcessorOpenRouterModel = (try? c.decode(String.self, forKey: .postProcessorOpenRouterModel)) ?? defaults.postProcessorOpenRouterModel
        postProcessorOllamaModel = (try? c.decode(String.self, forKey: .postProcessorOllamaModel)) ?? defaults.postProcessorOllamaModel
        postProcessorLMStudioModel = (try? c.decode(String.self, forKey: .postProcessorLMStudioModel)) ?? defaults.postProcessorLMStudioModel
        postProcessorCustomLLMModel = (try? c.decode(String.self, forKey: .postProcessorCustomLLMModel)) ?? defaults.postProcessorCustomLLMModel
        // Legacy Writing Styles state: read from the decode-only container so an
        // existing file still migrates, and never written back (R3).
        customTranscriptCleanupPrompts = (try? legacy.decode([CustomTranscriptCleanupPrompt].self, forKey: .customTranscriptCleanupPrompts)) ?? defaults.customTranscriptCleanupPrompts
        activeTranscriptCleanupPromptId = (try? legacy.decode(String.self, forKey: .activeTranscriptCleanupPromptId)) ?? defaults.activeTranscriptCleanupPromptId
        postProcessorSystemPrompt = (try? c.decode(String.self, forKey: .postProcessorSystemPrompt)) ?? defaults.postProcessorSystemPrompt
        adaptiveDictationStylesEnabled = (try? legacy.decode(Bool.self, forKey: .adaptiveDictationStylesEnabled)) ?? defaults.adaptiveDictationStylesEnabled
        dictationStyleRulesetInitialized = (try? legacy.decode(Bool.self, forKey: .dictationStyleRulesetInitialized)) ?? false
        // A malformed legacy array is simply empty now: the quarantine that used to
        // block every unrelated save is gone (R2), and the migration reads whatever survives.
        dictationStyleGroups = (try? legacy.decode([DictationStyleGroup].self, forKey: .dictationStyleGroups)) ?? defaults.dictationStyleGroups
        dictationStyleExactExceptions = (try? legacy.decode([DictationStyleExactException].self, forKey: .dictationStyleExactExceptions)) ?? defaults.dictationStyleExactExceptions
        // Decoded ahead of `matchModesByWebsite` below: that migration falls back to
        // this value, and reading the not-yet-assigned `enableScreenContext` property
        // there would silently observe its declared default instead of the stored one.
        let decodedEnableScreenContext = (try? c.decode(Bool.self, forKey: .enableScreenContext)) ?? defaults.enableScreenContext
        // A config migrated from a build without website matching keeps the read off
        // when the user had screen context off: they never opted into an address read.
        matchModesByWebsite = (try? c.decode(Bool.self, forKey: .matchModesByWebsite))
            ?? (c.contains(.dictationModes) ? defaults.matchModesByWebsite : decodedEnableScreenContext)
        // Modes decode per field; only a non-object element is dropped (R2). Only a
        // valid array counts as present: `null`, an object, or any other malformed
        // value migrates instead, so a hand-edited key cannot discard legacy data (R9).
        let decodedModes = (try? c.decode(DictationModes.DecodedArray.self, forKey: .dictationModes))?.modes
        dictationModes = decodedModes ?? []
        dictationStyleCategoryAssignments = (try? legacy.decode([String: String].self, forKey: .dictationStyleCategoryAssignments)) ?? defaults.dictationStyleCategoryAssignments
        dictationStyleAppRules = (try? legacy.decode([DictationStyleAppRule].self, forKey: .dictationStyleAppRules)) ?? defaults.dictationStyleAppRules
        dictationStyleDomainRules = (try? legacy.decode([DictationStyleDomainRule].self, forKey: .dictationStyleDomainRules)) ?? defaults.dictationStyleDomainRules
        enableScreenContext = decodedEnableScreenContext
        enableDictationOCRContext = (try? c.decode(Bool.self, forKey: .enableDictationOCRContext)) ?? defaults.enableDictationOCRContext
        useCoreAudioTap = (try? c.decode(Bool.self, forKey: .useCoreAudioTap)) ?? defaults.useCoreAudioTap
        meetingReverseLeakSuppression = (try? c.decode(Bool.self, forKey: .meetingReverseLeakSuppression)) ?? defaults.meetingReverseLeakSuppression
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
        // Modes are normalized at the end of decode as well as on save, so what is
        // in memory always equals what is on disk (R4).
        dictationModes = DictationModes.sanitized(modes: dictationModes)
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
        // R5-R9. Absent modes mean this file predates them, so the legacy keys become
        // the mode list once. The flag is decode-only and tells `ConfigStore` that this
        // result has to reach disk on the launch that derived it.
        if decodedModes == nil {
            let migration = DictationModes.migratedModes(from: self)
            dictationModes = migration.modes
            dictationModesMigrationApplied = true
            dictationModesMigrationNotes = migration.notes
        }
        // The repair preset is retired: repair now follows the language selection.
        // Runs after the mode migration above, so that migration still sees the
        // user's original selection rather than a value this rewrote (R13).
        if activeTranscriptCleanupPromptId == TranscriptCleanupPrompts.legacyMixedLanguageRepairID {
            activeTranscriptCleanupPromptId = defaults.activeTranscriptCleanupPromptId
            postProcessorSystemPrompt = defaults.postProcessorSystemPrompt
        }
        if TranscriptCleanupPrompts.resolveOptional(
            id: activeTranscriptCleanupPromptId,
            custom: customTranscriptCleanupPrompts
        ) == nil {
            activeTranscriptCleanupPromptId = defaults.activeTranscriptCleanupPromptId
            postProcessorSystemPrompt = defaults.postProcessorSystemPrompt
        }
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

    var resolvedDictationProvider: DictationProvider {
        DictationProvider.resolved(dictationProvider)
    }

    /// The profile is the language authority, but it can only express languages
    /// the shared catalogue knows. Bodhan's own languages — Chhattisgarhi and
    /// Haryanvi among them — have no catalogue entry, so a pin the user already
    /// saved survives instead of silently resetting to the default.
    var resolvedBodhanLanguage: BodhanLanguage {
        if languageProfile.authoritativeLanguage != nil {
            return languageProfile.resolvedBodhanLanguage
        }
        return BodhanLanguage(rawValue: bodhanLanguage) ?? languageProfile.resolvedBodhanLanguage
    }

    var resolvedNemotron35Language: Nemotron35Language {
        languageProfile.resolvedNemotron35Language
    }

    var resolvedWhisperLanguage: WhisperKitLanguage {
        languageProfile.resolvedWhisperLanguage
    }

    mutating func mirrorLanguageProfileToLegacyPins() {
        cohereLanguage = resolvedCohereLanguage.rawValue
        bodhanLanguage = resolvedBodhanLanguage.rawValue
        nemotron35Language = resolvedNemotron35Language.rawValue
        whisperLanguage = resolvedWhisperLanguage.rawValue
    }

    var resolvedParakeetLanguage: ParakeetLanguage {
        languageProfile.resolvedParakeetLanguage
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
