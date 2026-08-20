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

public enum LanguageRoutingIncompatibility: Codable, Equatable, Sendable, LocalizedError {
    case backendUnavailable(TranscriptionBackendID)
    case unsupportedWorkload(TranscriptionWorkload)
    case automaticDetectionUnsupported
    case languageUnsupported(TranscriptionLanguage)
    case constrainedCandidatesUnsupported
    case tooManyLanguages(requested: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .backendUnavailable(let backend):
            "The selected transcription model is unavailable (\(backend.rawValue))."
        case .unsupportedWorkload(let workload):
            "The selected transcription model does not support \(workload.rawValue)."
        case .automaticDetectionUnsupported:
            "The selected transcription model does not support automatic language detection."
        case .languageUnsupported(let language):
            "The selected transcription model does not support \(language.label) (\(language.rawValue))."
        case .constrainedCandidatesUnsupported:
            "The selected transcription model cannot reliably choose among the requested languages."
        case .tooManyLanguages(let requested, let maximum):
            "The selected transcription model supports at most \(maximum) candidate languages, but \(requested) were requested."
        }
    }
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

/// One complete, same-backend transcription candidate. Scores are comparable
/// only within the request that produced them; callers must never mix backend
/// families, models, or audio inputs.
public struct TranscriptionLanguageCandidate<Value: Sendable>: Sendable {
    public let language: TranscriptionLanguage
    public let value: Value
    public let normalizedScore: Double

    public init(language: TranscriptionLanguage, value: Value, normalizedScore: Double) {
        self.language = language
        self.value = value
        self.normalizedScore = normalizedScore
    }
}

public enum TranscriptionCandidateSelectionError: Error, LocalizedError, Equatable, Sendable {
    case noCandidates
    case duplicateLanguage(TranscriptionLanguage)
    case invalidScore(TranscriptionLanguage)
    case incompleteCandidates(expected: [TranscriptionLanguage], received: [TranscriptionLanguage])

    public var errorDescription: String? {
        switch self {
        case .noCandidates:
            "No language candidates completed."
        case .duplicateLanguage(let language):
            "The \(language.rawValue) language candidate completed more than once."
        case .invalidScore(let language):
            "The \(language.rawValue) language candidate did not produce a finite comparable score."
        case .incompleteCandidates(let expected, let received):
            "Candidate transcription was incomplete (expected \(expected.map(\.rawValue).joined(separator: ",")); received \(received.map(\.rawValue).joined(separator: ",")))."
        }
    }
}

/// Deterministic all-or-nothing candidate selection for app and CLI.
public enum TranscriptionLanguageCandidateSelector {
    public static let scoreEpsilon = 0.0001

    public static func select<Value: Sendable>(
        _ candidates: [TranscriptionLanguageCandidate<Value>],
        expectedLanguages: [TranscriptionLanguage],
        dominantLanguage: TranscriptionLanguage?,
        epsilon: Double = scoreEpsilon
    ) throws -> TranscriptionLanguageCandidate<Value> {
        guard !candidates.isEmpty else { throw TranscriptionCandidateSelectionError.noCandidates }
        let expected = Array(Set(expectedLanguages)).sorted { $0.rawValue < $1.rawValue }
        let received = candidates.map(\.language).sorted { $0.rawValue < $1.rawValue }
        guard expected == received else {
            let duplicates = Dictionary(grouping: received, by: { $0 }).first { $0.value.count > 1 }?.key
            if let duplicates { throw TranscriptionCandidateSelectionError.duplicateLanguage(duplicates) }
            throw TranscriptionCandidateSelectionError.incompleteCandidates(
                expected: expected,
                received: received
            )
        }
        for candidate in candidates where !candidate.normalizedScore.isFinite {
            throw TranscriptionCandidateSelectionError.invalidScore(candidate.language)
        }

        let bestScore = candidates.map(\.normalizedScore).max()!
        let tied = candidates.filter { bestScore - $0.normalizedScore <= epsilon }
        if let dominantLanguage,
           let dominant = tied.first(where: { $0.language == dominantLanguage }) {
            return dominant
        }
        return tied.min { $0.language.rawValue < $1.language.rawValue }!
    }
}

/// WhisperKit exposes one average log probability per segment. Weighting by
/// emitted token count makes complete-request scores comparable without giving
/// short segments disproportionate influence.
public enum WhisperSegmentConfidenceAdapter {
    public static func normalizedScore(
        _ segments: [(averageLogProbability: Double, tokenCount: Int)]
    ) -> Double? {
        var weighted = 0.0
        var totalTokens = 0
        for segment in segments {
            guard segment.tokenCount > 0, segment.averageLogProbability.isFinite else {
                return nil
            }
            weighted += segment.averageLogProbability * Double(segment.tokenCount)
            totalTokens += segment.tokenCount
        }
        guard totalTokens > 0 else { return nil }
        let score = weighted / Double(totalTokens)
        return score.isFinite ? score : nil
    }
}
