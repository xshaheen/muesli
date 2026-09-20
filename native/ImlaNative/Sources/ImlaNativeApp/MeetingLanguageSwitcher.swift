import Foundation
import ImlaCore

/// A value captured with an audio chunk, so queued recognition never reads a
/// language chosen after that audio was recorded.
struct MeetingRecognitionSnapshot: Equatable, Sendable {
    let profile: LanguageProfile
    let appleSpeechLanguage: String

    var selection: TranscriptionLanguageSelection {
        (try? TranscriptionLanguageSelection(
            selectedLanguages: profile.selectedLanguages,
            dominantLanguage: profile.dominantLanguage
        )) ?? .automatic
    }

    func decision(backend: BackendOption) -> LanguageRoutingDecision? {
        MeetingSession.meetingLanguageDecision(
            selection: selection, backend: backend, workload: .meetingFinal
        )
    }
}

/// Owned by one meeting. The raw-system-file offsets also preserve language
/// boundaries when finalization recovers speech that live chunks missed.
struct MeetingLanguageSwitcher: Sendable {
    struct SystemSpan: Sendable {
        let samples: Range<Int>
        let snapshot: MeetingRecognitionSnapshot
    }

    let defaultProfile: LanguageProfile
    private let defaultAppleSpeechLanguage: String
    private(set) var selectedLanguage: TranscriptionLanguage?
    private var systemHistory: [(offset: Int, snapshot: MeetingRecognitionSnapshot)]

    init(defaultProfile: LanguageProfile, appleSpeechLanguage: String) {
        self.defaultProfile = defaultProfile
        defaultAppleSpeechLanguage = appleSpeechLanguage
        systemHistory = [(0, MeetingRecognitionSnapshot(
            profile: defaultProfile, appleSpeechLanguage: appleSpeechLanguage
        ))]
    }

    var current: MeetingRecognitionSnapshot { systemHistory[systemHistory.count - 1].snapshot }
    var requiresSystemSplitting: Bool { systemHistory.count > 1 }

    var languages: [TranscriptionLanguage] {
        defaultProfile.selectedLanguages.isEmpty
            ? TranscriptionLanguage.allCases : defaultProfile.selectedLanguages
    }

    var label: String {
        if let language = current.selection.authoritativeLanguage { return language.rawValue.uppercased() }
        return current.selection.isAutomatic ? "Auto" : "Multi"
    }

    mutating func select(_ language: TranscriptionLanguage?, systemSampleOffset: Int) {
        guard language != selectedLanguage else { return }
        selectedLanguage = language
        let profile = language.flatMap { try? LanguageProfile(selectedLanguages: [$0]) } ?? defaultProfile
        let snapshot = MeetingRecognitionSnapshot(
            profile: profile,
            appleSpeechLanguage: language?.rawValue ?? defaultAppleSpeechLanguage
        )
        let offset = max(systemSampleOffset, systemHistory.last?.offset ?? 0)
        if systemHistory.last?.offset == offset { systemHistory.removeLast() }
        systemHistory.append((offset, snapshot))
    }

    func systemSpans(in samples: Range<Int>) -> [SystemSpan] {
        guard !samples.isEmpty else { return [] }
        return systemHistory.indices.compactMap { index in
            let start = max(samples.lowerBound, systemHistory[index].offset)
            let next = index + 1 < systemHistory.count ? systemHistory[index + 1].offset : samples.upperBound
            let end = min(samples.upperBound, next)
            guard end > start else { return nil }
            return SystemSpan(samples: start..<end, snapshot: systemHistory[index].snapshot)
        }
    }

    static func canSelect(
        _ language: TranscriptionLanguage,
        backend: BackendOption,
        liveBackend: MeetingLiveCaptionBackend?
    ) -> Bool {
        guard let selection = try? TranscriptionLanguageSelection(selectedLanguages: [language]) else { return false }
        func honors(_ backend: BackendOption, workload: TranscriptionWorkload) -> Bool {
            let decision = MeetingSession.meetingLanguageDecision(selection: selection, backend: backend, workload: workload)
            return decision == .pinned(language) || decision == .fixed(language)
        }
        guard honors(backend, workload: .meetingFinal) else { return false }
        switch liveBackend {
        case nil: return true
        case .nemotron35: return honors(.nemotron35Multilingual, workload: .meetingLive)
        case .parakeetRealtimeEOU: return language == .english
        case .appleSpeech: return honors(.appleSpeechAnalyzer, workload: .meetingLive)
        }
    }
}
