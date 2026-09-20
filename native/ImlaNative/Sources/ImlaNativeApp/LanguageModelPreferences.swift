import Foundation
import ImlaCore
import os

enum AppleSpeechModelLanguages {
    private struct Catalog {
        var supported: Set<TranscriptionLanguage> = []
        var installed: Set<TranscriptionLanguage> = []
        var isLoaded = false
    }
    private static let storage = OSAllocatedUnfairLock(initialState: Catalog())
    static var supported: Set<TranscriptionLanguage> { storage.withLock { $0.supported } }
    static var installed: Set<TranscriptionLanguage> { storage.withLock { $0.installed } }
    static var isLoaded: Bool { storage.withLock { $0.isLoaded } }
    static func update(_ localeIdentifiers: [String], installed installedIdentifiers: [String]) {
        let languages = Set(localeIdentifiers.compactMap { KeyboardLanguageSnapshot.resolve([$0]) })
        let installed = Set(installedIdentifiers.compactMap { KeyboardLanguageSnapshot.resolve([$0]) })
        storage.withLock { $0 = Catalog(supported: languages, installed: installed, isLoaded: true) }
    }
    static func markInstalled(_ locale: Locale) {
        guard let language = KeyboardLanguageSnapshot.resolve([locale.identifier]) else { return }
        storage.withLock { $0.installed.insert(language) }
    }
}

struct SpeechModelReference: Codable, Equatable, Sendable {
    let backend: String
    let model: String

    init(_ option: BackendOption) {
        backend = option.backend
        model = option.model
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        backend = try values.decode(String.self, forKey: .backend)
        model = try values.decode(String.self, forKey: .model)
        guard !backend.isEmpty, backend.count <= 128, !model.isEmpty, model.count <= 1024 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid model reference"))
        }
    }

    var option: BackendOption? { BackendOption.resolve(backend: backend, model: model) }
}

struct LanguageModelAssignment: Codable, Equatable, Sendable {
    var dictation: SpeechModelReference?
    /// Nil inherits the dictation choice, when that model can handle meetings.
    var meeting: SpeechModelReference?

    init(dictation: SpeechModelReference? = nil, meeting: SpeechModelReference? = nil) {
        self.dictation = dictation
        self.meeting = meeting
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dictation = try? values.decode(SpeechModelReference.self, forKey: .dictation)
        meeting = try? values.decode(SpeechModelReference.self, forKey: .meeting)
    }
}

/// Decode entries separately: a corrupt choice must not discard other languages.
/// The shared language catalog bounds the map; unknown model references survive
/// so temporarily unavailable models can be selected again without reconfiguration.
struct LanguageModelPreferences: Codable, Equatable, Sendable {
    private var assignments: [String: LanguageModelAssignment] = [:]

    init() {}

    var languages: [TranscriptionLanguage] {
        assignments.keys.compactMap(TranscriptionLanguage.init(rawValue:)).sorted { $0.rawValue < $1.rawValue }
    }

    subscript(language: TranscriptionLanguage) -> LanguageModelAssignment {
        get { assignments[language.rawValue] ?? LanguageModelAssignment() }
        set { assignments[language.rawValue] = newValue }
    }

    mutating func remove(_ language: TranscriptionLanguage) { assignments.removeValue(forKey: language.rawValue) }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        for key in values.allKeys {
            guard let language = TranscriptionLanguage.resolve(key.stringValue),
                  let assignment = try? values.decode(LanguageModelAssignment.self, forKey: key) else { continue }
            assignments[language.rawValue] = assignment
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        for (language, assignment) in assignments {
            if let key = Key(stringValue: language) { try values.encode(assignment, forKey: key) }
        }
    }
}

enum LanguageModelRouting {
    enum Workload: Equatable { case dictation, meeting }

    struct Resolution: Equatable {
        let backend: BackendOption
        let usedFallback: Bool
        var isUsable = true
    }

    static func supports(_ option: BackendOption, language: TranscriptionLanguage, workload: Workload) -> Bool {
        guard workload != .meeting || option.supportsMeetingTranscription else { return false }
        if option.backend == "apple-speech", !AppleSpeechModelLanguages.installed.contains(language) { return false }
        if workload == .meeting {
            guard let selection = try? TranscriptionLanguageSelection(selectedLanguages: [language]) else { return false }
            let decision = TranscriptionLanguageRouter.resolve(
                selection: selection, capabilities: option.languageCapabilities(isAvailable: true), workload: .meetingFinal
            )
            guard decision == .pinned(language) || decision == .fixed(language) else { return false }
        }
        if option == .parakeetUnified || option == .parakeetEnglish { return language == .english }
        if option == .parakeetMultilingual { return ParakeetLanguage(rawValue: language.rawValue) != nil }
        return option.languageCapabilities(isAvailable: true).supportedLanguages.contains(language)
    }

    /// Availability is supplied by the caller's cache, never read from disk on
    /// the hotkey path. All candidates are local models; provider consent is separate.
    static func resolve(
        language: TranscriptionLanguage?,
        preferences: LanguageModelPreferences,
        dictationDefault: BackendOption,
        meetingDefault: BackendOption,
        available: [BackendOption],
        workload: Workload
    ) -> Resolution {
        let defaultBackend = workload == .dictation ? dictationDefault : meetingDefault
        guard let language else {
            let candidates = available.filter { workload != .meeting || $0.supportsMeetingTranscription }
            let backend = candidates.contains(defaultBackend) ? defaultBackend : (candidates.first ?? defaultBackend)
            return Resolution(backend: backend, usedFallback: backend != defaultBackend, isUsable: !candidates.isEmpty)
        }
        let assignment = preferences[language]
        let explicit = workload == .dictation ? assignment.dictation : assignment.meeting
        func usable(_ option: BackendOption) -> Bool {
            available.contains(option) && supports(option, language: language, workload: workload)
        }
        if let option = explicit?.option, usable(option) {
            return Resolution(backend: option, usedFallback: false)
        }
        var couldNotInherit = false
        if workload == .meeting, explicit == nil {
            let inherited = resolve(
                language: language, preferences: preferences,
                dictationDefault: dictationDefault, meetingDefault: meetingDefault,
                available: available, workload: .dictation
            )
            if usable(inherited.backend) { return inherited }
            couldNotInherit = true
        }
        if usable(defaultBackend) {
            return Resolution(backend: defaultBackend, usedFallback: explicit != nil || couldNotInherit)
        }
        return Resolution(
            backend: available.first(where: usable) ?? defaultBackend,
            usedFallback: true,
            isUsable: available.contains(where: usable)
        )
    }
}
