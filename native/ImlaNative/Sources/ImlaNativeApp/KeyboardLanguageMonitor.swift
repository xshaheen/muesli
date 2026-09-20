import AppKit
import Carbon
import ImlaCore

struct KeyboardLanguageSnapshot: Equatable, Sendable {
    let language: TranscriptionLanguage?
    let enabledLanguages: [TranscriptionLanguage]

    static func resolve(_ identifiers: [String]) -> TranscriptionLanguage? {
        let languages = Set(identifiers.compactMap { identifier in
            guard let code = Locale(identifier: identifier).language.languageCode?.identifier else { return nil as TranscriptionLanguage? }
            return TranscriptionLanguage(rawValue: code)
        })
        return languages.count == 1 ? languages.first : nil
    }

    func spokenProfile(additionalLanguages: [TranscriptionLanguage] = []) -> SpokenLanguageProfile {
        guard let language else { return .automatic }
        return (try? SpokenLanguageProfile(
            selectedLanguages: enabledLanguages + additionalLanguages + [language],
            dominantLanguage: language
        )) ?? .automatic
    }

    func applying(to base: AppConfig, backend: BackendOption) -> AppConfig {
        var snapshot = base
        snapshot.sttBackend = backend.backend
        snapshot.sttModel = backend.model
        snapshot.dictationLanguageProfile = spokenProfile(additionalLanguages: base.languageModels.languages)
        if let language { snapshot.appleSpeechLanguage = language.rawValue }
        return snapshot
    }
}

/// Input-source notifications keep the language cached. Dictation reads a value
/// at the hotkey boundary without querying the OS or reading preferences there.
@MainActor
final class KeyboardLanguageMonitor {
    private(set) var snapshot: KeyboardLanguageSnapshot
    var onChange: ((KeyboardLanguageSnapshot) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() { snapshot = Self.readSnapshot() }

    func start() {
        guard observers.isEmpty else { return }
        let names = [
            Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
        ]
        for name in names {
            observers.append(DistributedNotificationCenter.default().addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func stop() {
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        observers.removeAll()
        onChange = nil
    }

    deinit {
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    private func refresh() {
        let updated = Self.readSnapshot()
        guard updated != snapshot else { return }
        snapshot = updated
        onChange?(updated)
    }

    private static func languageIdentifiers(_ source: TISInputSource) -> [String] {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        return Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String] ?? []
    }

    private static func readSnapshot() -> KeyboardLanguageSnapshot {
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let language = current.flatMap { KeyboardLanguageSnapshot.resolve(languageIdentifiers($0)) }
        let filter = [
            kTISPropertyInputSourceIsEnabled as String: true,
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
        ] as [String: Any] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        let enabled = Set(sources.compactMap { KeyboardLanguageSnapshot.resolve(languageIdentifiers($0)) })
            .union(language.map { [$0] } ?? [])
            .sorted { $0.rawValue < $1.rawValue }
        return KeyboardLanguageSnapshot(language: language, enabledLanguages: enabled)
    }
}
