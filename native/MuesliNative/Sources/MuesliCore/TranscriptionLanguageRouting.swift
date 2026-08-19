import Foundation

public enum TranscriptionLanguage: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case arabic = "ar"
    case bengali = "bn"
    case chinese = "zh"
    case dutch = "nl"
    case english = "en"
    case french = "fr"
    case german = "de"
    case greek = "el"
    case hindi = "hi"
    case italian = "it"
    case japanese = "ja"
    case kannada = "kn"
    case korean = "ko"
    case malayalam = "ml"
    case marathi = "mr"
    case polish = "pl"
    case portuguese = "pt"
    case russian = "ru"
    case spanish = "es"
    case tamil = "ta"
    case telugu = "te"
    case vietnamese = "vi"

    public var id: String { rawValue }

    public var label: String {
        Locale.current.localizedString(forLanguageCode: rawValue)?.capitalized
            ?? rawValue.uppercased()
    }

    public static func resolve(_ rawValue: String?) -> Self? {
        guard let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            normalized != "auto"
        else { return nil }
        return Self(rawValue: normalized)
    }
}

public struct DictationLanguageProfile: Codable, Equatable, Sendable {
    public enum ValidationError: Error, LocalizedError {
        case dominantLanguageNotSelected

        public var errorDescription: String? {
            "The dominant language must also be selected."
        }
    }

    public let selectedLanguages: [TranscriptionLanguage]
    public let dominantLanguage: TranscriptionLanguage?

    public static let automatic = DictationLanguageProfile(
        normalizedLanguages: [],
        dominantLanguage: nil
    )

    public init(
        selectedLanguages: [TranscriptionLanguage],
        dominantLanguage: TranscriptionLanguage? = nil
    ) throws {
        let normalized = Array(Set(selectedLanguages)).sorted { $0.rawValue < $1.rawValue }
        if let dominantLanguage, !normalized.contains(dominantLanguage) {
            throw ValidationError.dominantLanguageNotSelected
        }
        self.init(normalizedLanguages: normalized, dominantLanguage: dominantLanguage)
    }

    private init(
        normalizedLanguages: [TranscriptionLanguage],
        dominantLanguage: TranscriptionLanguage?
    ) {
        selectedLanguages = normalizedLanguages
        self.dominantLanguage = dominantLanguage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            selectedLanguages: container.decodeIfPresent(
                [TranscriptionLanguage].self,
                forKey: .selectedLanguages
            ) ?? [],
            dominantLanguage: container.decodeIfPresent(
                TranscriptionLanguage.self,
                forKey: .dominantLanguage
            )
        )
    }

    public var selection: TranscriptionLanguageSelection {
        (try? TranscriptionLanguageSelection(
            selectedLanguages: selectedLanguages,
            dominantLanguage: dominantLanguage
        )) ?? .automatic
    }
}

public enum MeetingSpokenLanguageSelection: Codable, Equatable, Sendable {
    case automatic
    case explicit(TranscriptionLanguage)

    private enum CodingKeys: String, CodingKey { case mode, language }
    private enum Mode: String, Codable { case automatic, explicit }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .automatic:
            self = .automatic
        case .explicit:
            self = .explicit(try container.decode(TranscriptionLanguage.self, forKey: .language))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try container.encode(Mode.automatic, forKey: .mode)
        case .explicit(let language):
            try container.encode(Mode.explicit, forKey: .mode)
            try container.encode(language, forKey: .language)
        }
    }

    public var language: TranscriptionLanguage? {
        guard case .explicit(let language) = self else { return nil }
        return language
    }
}

public struct TranscriptionBackendID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(provider: String, model: String) {
        rawValue = "\(provider):\(model)"
    }
}

public enum TranscriptionWorkload: String, Codable, CaseIterable, Hashable, Sendable {
    case dictation
    case meetingLive = "meeting_live"
    case meetingFinal = "meeting_final"
    case fileImport = "file_import"
    case retranscription
    case cli
}

public struct TranscriptionLanguageSelection: Codable, Equatable, Sendable {
    public enum ValidationError: Error, LocalizedError {
        case dominantLanguageNotSelected

        public var errorDescription: String? {
            "The dominant language must also be selected."
        }
    }

    public let selectedLanguages: [TranscriptionLanguage]
    public let dominantLanguage: TranscriptionLanguage?

    public static let automatic = TranscriptionLanguageSelection(
        normalizedLanguages: [],
        dominantLanguage: nil
    )

    public init(
        selectedLanguages: [TranscriptionLanguage],
        dominantLanguage: TranscriptionLanguage? = nil
    ) throws {
        let normalized = Array(Set(selectedLanguages)).sorted { $0.rawValue < $1.rawValue }
        if let dominantLanguage, !normalized.contains(dominantLanguage) {
            throw ValidationError.dominantLanguageNotSelected
        }
        self.init(normalizedLanguages: normalized, dominantLanguage: dominantLanguage)
    }

    private init(
        normalizedLanguages: [TranscriptionLanguage],
        dominantLanguage: TranscriptionLanguage?
    ) {
        selectedLanguages = normalizedLanguages
        self.dominantLanguage = dominantLanguage
    }

    public var isAutomatic: Bool { selectedLanguages.isEmpty }
}

public struct TranscriptionBackendCapabilities: Codable, Equatable, Sendable {
    public let backendID: TranscriptionBackendID
    public let supportedLanguages: Set<TranscriptionLanguage>
    public let supportsAutomaticDetection: Bool
    public let supportsSingleLanguage: Bool
    public let constrainedCandidateLanguages: Set<TranscriptionLanguage>
    public let constrainedCandidateCapacity: Int
    public let hasComparableCandidateConfidence: Bool
    public let fixedLanguage: TranscriptionLanguage?
    public let supportsCodeSwitching: Bool
    public let maximumSafeDuration: TimeInterval?
    public let supportsStreaming: Bool
    public let workloads: Set<TranscriptionWorkload>
    public let isAvailable: Bool

    public init(
        backendID: TranscriptionBackendID,
        supportedLanguages: Set<TranscriptionLanguage>,
        supportsAutomaticDetection: Bool,
        supportsSingleLanguage: Bool,
        constrainedCandidateLanguages: Set<TranscriptionLanguage> = [],
        constrainedCandidateCapacity: Int = 0,
        hasComparableCandidateConfidence: Bool = false,
        fixedLanguage: TranscriptionLanguage? = nil,
        supportsCodeSwitching: Bool = false,
        maximumSafeDuration: TimeInterval? = nil,
        supportsStreaming: Bool = false,
        workloads: Set<TranscriptionWorkload>,
        isAvailable: Bool = true
    ) {
        self.backendID = backendID
        self.supportedLanguages = supportedLanguages
        self.supportsAutomaticDetection = supportsAutomaticDetection
        self.supportsSingleLanguage = supportsSingleLanguage
        self.constrainedCandidateLanguages = constrainedCandidateLanguages
        self.constrainedCandidateCapacity = max(constrainedCandidateCapacity, 0)
        self.hasComparableCandidateConfidence = hasComparableCandidateConfidence
        self.fixedLanguage = fixedLanguage
        self.supportsCodeSwitching = supportsCodeSwitching
        self.maximumSafeDuration = maximumSafeDuration
        self.supportsStreaming = supportsStreaming
        self.workloads = workloads
        self.isAvailable = isAvailable
    }
}

public enum LanguageRoutingIncompatibility: Codable, Equatable, Sendable {
    case backendUnavailable(TranscriptionBackendID)
    case unsupportedWorkload(TranscriptionWorkload)
    case automaticDetectionUnsupported
    case languageUnsupported(TranscriptionLanguage)
    case constrainedCandidatesUnsupported
    case tooManyLanguages(requested: Int, maximum: Int)
}

public enum LanguageRoutingDecision: Codable, Equatable, Sendable {
    case automatic
    case pinned(TranscriptionLanguage)
    case constrainedCandidates(
        languages: [TranscriptionLanguage],
        dominantLanguage: TranscriptionLanguage?
    )
    case fixed(TranscriptionLanguage)
    case incompatible(LanguageRoutingIncompatibility)

    public var identifier: String {
        switch self {
        case .automatic: "auto"
        case .pinned: "pinned"
        case .constrainedCandidates: "constrained"
        case .fixed: "fixed"
        case .incompatible: "incompatible"
        }
    }
}

public enum TranscriptionLanguageRouter {
    public static func resolve(
        selection: TranscriptionLanguageSelection,
        capabilities: TranscriptionBackendCapabilities,
        workload: TranscriptionWorkload
    ) -> LanguageRoutingDecision {
        guard capabilities.isAvailable else {
            return .incompatible(.backendUnavailable(capabilities.backendID))
        }
        guard capabilities.workloads.contains(workload) else {
            return .incompatible(.unsupportedWorkload(workload))
        }

        if let fixedLanguage = capabilities.fixedLanguage {
            guard selection.isAutomatic
                || selection.selectedLanguages.allSatisfy({ $0 == fixedLanguage })
            else {
                return .incompatible(.languageUnsupported(
                    selection.selectedLanguages.first { $0 != fixedLanguage } ?? fixedLanguage
                ))
            }
            return .fixed(fixedLanguage)
        }

        guard !selection.isAutomatic else {
            return capabilities.supportsAutomaticDetection
                ? .automatic
                : .incompatible(.automaticDetectionUnsupported)
        }

        if selection.selectedLanguages.count == 1,
           let language = selection.selectedLanguages.first {
            guard capabilities.supportedLanguages.contains(language) else {
                return .incompatible(.languageUnsupported(language))
            }
            return capabilities.supportsSingleLanguage
                ? .pinned(language)
                : .incompatible(.languageUnsupported(language))
        }

        if let unsupported = selection.selectedLanguages.first(where: {
            !capabilities.supportedLanguages.contains($0)
        }) {
            return .incompatible(.languageUnsupported(unsupported))
        }
        guard selection.selectedLanguages.count <= capabilities.constrainedCandidateCapacity else {
            return .incompatible(.tooManyLanguages(
                requested: selection.selectedLanguages.count,
                maximum: capabilities.constrainedCandidateCapacity
            ))
        }
        let requested = Set(selection.selectedLanguages)
        guard capabilities.hasComparableCandidateConfidence,
              requested == capabilities.constrainedCandidateLanguages
        else {
            return .incompatible(.constrainedCandidatesUnsupported)
        }
        return .constrainedCandidates(
            languages: selection.selectedLanguages,
            dominantLanguage: selection.dominantLanguage
        )
    }
}
