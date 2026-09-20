import Foundation
import ImlaCore
import Testing
@testable import ImlaNativeApp

@Suite("Meeting session language authority")
struct MeetingSessionLanguageAuthorityTests {
    private func makeSession(
        config: AppConfig,
        backend: BackendOption = .whisperLargeTurbo,
        liveCaptionAvailability: (MeetingLiveCaptionBackend) -> Bool = { $0.isDownloaded }
    ) -> MeetingSession {
        MeetingSession(
            title: "Language authority",
            calendarEventID: nil,
            backend: backend,
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            config: config,
            templateSnapshot: MeetingTemplates.auto.snapshot,
            transcriptionCoordinator: TranscriptionCoordinator(),
            liveCaptionAvailability: liveCaptionAvailability,
            availableLanguageModels: [backend, .whisperLargeTurbo, .cohereArabic, .nemotron35Multilingual]
        )
    }

    /// Mirrors the throw sites of `TranscriptionRuntime.routeToBackend`
    /// (`TranscriptionRuntime.swift:2484-2626`). `route` is private, so the
    /// forwarding itself is compile-proven; this predicate is the executable
    /// form of "the decision we hand it never throws".
    private func routeAccepts(
        decision: LanguageRoutingDecision?,
        backend: BackendOption
    ) -> Bool {
        guard let decision else { return true }
        if case .incompatible = decision { return false }
        switch backend.backend {
        case "whisper":
            switch decision {
            case .pinned(let language), .fixed(let language):
                return WhisperKitLanguage(rawValue: language.rawValue) != nil
            default:
                return true
            }
        case "nemotron35":
            switch decision {
            case .pinned(let language), .fixed(let language):
                return Nemotron35Language(rawValue: language.rawValue) != nil
            case .constrainedCandidates:
                return false
            default:
                return true
            }
        case "cohere-arabic":
            switch decision {
            case .pinned(let language), .fixed(let language):
                return language == .arabic || language == .english
            default:
                return false
            }
        case "cohere":
            switch decision {
            case .pinned(let language), .fixed(let language):
                return CohereTranscribeLanguage(rawValue: language.rawValue) != nil
            default:
                return false
            }
        case "bodhan":
            switch decision {
            case .pinned(let language), .fixed(let language):
                return BodhanLanguage(rawValue: language.rawValue) != nil
            default:
                return false
            }
        case "apple-speech":
            if case .constrainedCandidates = decision { return false }
            return true
        default:
            // parakeet-unified, sensevoice, gemma4-litert and FluidAudio all
            // throw on a pin and ignore every other decision.
            if case .pinned = decision { return false }
            return true
        }
    }

    private func selectionShapes(
        for backend: BackendOption
    ) throws -> [(label: String, selection: TranscriptionLanguageSelection)] {
        let capabilities = backend.languageCapabilities(isAvailable: true)
        let supported = capabilities.supportedLanguages
            .sorted { $0.rawValue < $1.rawValue }
        var shapes: [(String, TranscriptionLanguageSelection)] = [
            ("automatic", .automatic),
        ]
        if let first = supported.first {
            shapes.append(("one supported", try TranscriptionLanguageSelection(
                selectedLanguages: [first]
            )))
        }
        if let unsupported = TranscriptionLanguage.allCases
            .first(where: { !capabilities.supportedLanguages.contains($0) }) {
            shapes.append(("one unsupported", try TranscriptionLanguageSelection(
                selectedLanguages: [unsupported]
            )))
        }
        if supported.count >= 2 {
            let pair = Array(supported.prefix(2))
            shapes.append(("two with dominant", try TranscriptionLanguageSelection(
                selectedLanguages: pair,
                dominantLanguage: pair[0]
            )))
            shapes.append(("two without dominant", try TranscriptionLanguageSelection(
                selectedLanguages: pair
            )))
        }
        return shapes
    }

    @Test("the frozen meeting selection outlives a backend swap and follows the new backend")
    func frozenSelectionFollowsBackendSwap() throws {
        var config = AppConfig()
        config.meetingSpokenLanguage = try SpokenLanguageProfile(selectedLanguages: [.arabic])
        let session = makeSession(config: config)

        #expect(session.recognitionLanguageSwitcher.current.selection.selectedLanguages == [.arabic])
        #expect(MeetingSession.meetingLanguageDecision(
            selection: session.recognitionLanguageSwitcher.current.selection,
            backend: .whisperLargeTurbo,
            workload: .meetingFinal
        ) == .pinned(.arabic))

        // AE5: the model is deleted mid-meeting and the authority swaps to
        // Parakeet v3, which cannot pin. The selection is untouched; only the
        // decision moves, because it is resolved per call.
        session.updateTranscriptionAuthority(
            backend: .parakeetMultilingual,
            usesUnifiedNemotronTranscript: false
        )
        #expect(session.recognitionLanguageSwitcher.current.selection.selectedLanguages == [.arabic])
        #expect(MeetingSession.meetingLanguageDecision(
            selection: session.recognitionLanguageSwitcher.current.selection,
            backend: .parakeetMultilingual,
            workload: .meetingFinal
        ) == .automatic)
    }

    @Test("the frozen legacy profile carries the meeting selection, not the dictation one")
    func frozenProfileCarriesMeetingSelection() throws {
        var config = AppConfig()
        config.dictationLanguageProfile = try SpokenLanguageProfile(
            selectedLanguages: [.english],
            dominantLanguage: .english
        )
        config.meetingSpokenLanguage = try SpokenLanguageProfile(
            selectedLanguages: [.arabic],
            dominantLanguage: .arabic
        )
        let session = makeSession(config: config)

        #expect(session.frozenMeetingProfile.selectedLanguages == [.arabic])
        #expect(session.frozenMeetingProfile.dominantLanguage == .arabic)
        // The nil-decision branch reads these legacy arguments; a dictation-derived
        // profile would keep pinning Cohere and Indic to the dictation language.
        #expect(session.frozenMeetingProfile.resolvedCohereLanguage == .arabic)
    }

    @Test("updating the transcription authority flips the unified flag and leaves the selection frozen")
    func updatingAuthorityLeavesSelectionFrozen() throws {
        var config = AppConfig()
        config.enableLiveStreamingPartials = true
        config.meetingLiveCaptionBackend = MeetingLiveCaptionBackend.nemotron35.rawValue
        config.meetingSpokenLanguage = try SpokenLanguageProfile(selectedLanguages: [.german])
        let session = makeSession(config: config, backend: .nemotron35Multilingual)

        #expect(session.usesLiveNemotronTranscriptAsFinal())
        session.updateTranscriptionAuthority(
            backend: .whisperLargeTurbo,
            usesUnifiedNemotronTranscript: false
        )
        #expect(!session.usesLiveNemotronTranscriptAsFinal())
        #expect(session.recognitionLanguageSwitcher.current.selection.selectedLanguages == [.german])
        #expect(session.frozenMeetingProfile.selectedLanguages == [.german])
    }

    @Test("every meeting backend and selection shape resolves to a decision the runtime accepts")
    func everyBackendAndShapeResolvesToAnAcceptedDecision() throws {
        let backends = BackendOption.all.filter(\.supportsMeetingTranscription)
        #expect(!backends.isEmpty)
        for backend in backends {
            for shape in try selectionShapes(for: backend) {
                for workload in [
                    TranscriptionWorkload.meetingFinal,
                    .retranscription,
                    .fileImport,
                ] {
                    let decision = MeetingSession.meetingLanguageDecision(
                        selection: shape.selection,
                        backend: backend,
                        workload: workload
                    )
                    #expect(
                        decision != nil,
                        "\(backend.label) / \(shape.label) / \(workload.rawValue) lost its decision"
                    )
                    #expect(
                        routeAccepts(decision: decision, backend: backend),
                        "\(backend.label) / \(shape.label) / \(workload.rawValue) resolved \(String(describing: decision))"
                    )
                }
            }
        }
    }

    @Test("a switch pins new speech without changing earlier snapshots or meeting defaults")
    func switchPreservesEarlierSpeech() throws {
        let profile = try LanguageProfile(selectedLanguages: [.arabic, .english])
        var switcher = MeetingLanguageSwitcher(defaultProfile: profile, appleSpeechLanguage: "en-US")
        let before = switcher.current
        switcher.select(.arabic, systemSampleOffset: 16000)
        let arabic = switcher.current
        switcher.select(.english, systemSampleOffset: 32000)

        #expect(before.selection.selectedLanguages == [.arabic, .english])
        #expect(before.selection.authoritativeLanguage == nil)
        #expect(arabic.selection.authoritativeLanguage == .arabic)
        #expect(arabic.profile.resolvedWhisperLanguage == .arabic)
        #expect(arabic.appleSpeechLanguage == "ar")
        #expect(switcher.current.selection.authoritativeLanguage == .english)
        #expect(switcher.defaultProfile == profile)

        let spans = switcher.systemSpans(in: 8000..<40000)
        #expect(spans.map(\.samples) == [8000..<16000, 16000..<32000, 32000..<40000])
        #expect(spans.map { $0.snapshot.selection.authoritativeLanguage } == [nil, .arabic, .english])
    }

    @Test("returning to the meeting default restores its original selection and Apple locale")
    func restoreDefault() throws {
        let profile = try LanguageProfile(selectedLanguages: [.arabic, .english])
        var switcher = MeetingLanguageSwitcher(defaultProfile: profile, appleSpeechLanguage: "en-US")
        switcher.select(.arabic, systemSampleOffset: 0)
        switcher.select(nil, systemSampleOffset: 0)
        #expect(switcher.current.profile == profile)
        #expect(switcher.current.appleSpeechLanguage == "en-US")
        #expect(switcher.systemSpans(in: 0..<16000).count == 1)
        #expect(switcher.systemSpans(in: 0..<0).isEmpty)
    }

    @Test("the switcher only enables languages the final and live recognizers can honor")
    func switchRequiresLanguageSupport() {
        #expect(MeetingLanguageSwitcher.canSelect(.arabic, backend: .whisperLargeTurbo, liveBackend: .nemotron35))
        #expect(!MeetingLanguageSwitcher.canSelect(.arabic, backend: .parakeetMultilingual, liveBackend: nil))
        #expect(!MeetingLanguageSwitcher.canSelect(.arabic, backend: .whisperLargeTurbo, liveBackend: .parakeetRealtimeEOU))
        #expect(!MeetingLanguageSwitcher.canSelect(.dutch, backend: .whisperLargeTurbo, liveBackend: .nemotron35))
    }

    @Test("unavailable or disabled captions do not restrict the final recognizer's languages")
    func inactiveCaptionsDoNotRestrictLanguages() {
        var config = AppConfig()
        config.enableLiveStreamingPartials = true
        config.meetingLiveCaptionBackend = MeetingLiveCaptionBackend.parakeetRealtimeEOU.rawValue
        let unavailable = makeSession(config: config, liveCaptionAvailability: { _ in false })
        #expect(unavailable.canSelectRecognitionLanguage(.arabic))

        let available = makeSession(config: config, liveCaptionAvailability: { _ in true })
        #expect(available.canSelectRecognitionLanguage(.arabic))
        available.stopStreamingPartials()
        #expect(available.canSelectRecognitionLanguage(.arabic))
    }

    @Test("the menu shows only meeting languages, marks the selection and disables unsupported choices")
    @MainActor
    func menuReflectsSessionSelection() throws {
        let profile = try LanguageProfile(selectedLanguages: [.arabic, .english])
        var switcher = MeetingLanguageSwitcher(defaultProfile: profile, appleSpeechLanguage: "system")
        switcher.select(.arabic, systemSampleOffset: 0)
        let session = makeSession(config: AppConfig())
        let menu = StatusBarController.meetingLanguageMenu(
            switcher: switcher,
            sessionID: ObjectIdentifier(session),
            target: nil,
            canSelect: { $0 == .arabic }
        )
        let choices = menu.items.filter { $0.representedObject is MeetingLanguageMenuPayload }
        #expect(choices.count == 3)
        #expect(choices[0].state == .off)
        #expect(choices[1].state == .on)
        #expect(choices[1].isEnabled)
        #expect(!choices[2].isEnabled)
        #expect((choices[1].representedObject as? MeetingLanguageMenuPayload)?.sessionID == ObjectIdentifier(session))
        #expect(switcher.label == "AR")
    }

    @Test("a queued chunk retains its model and uses its own language if that model disappears")
    func queuedModelSnapshot() throws {
        var config = AppConfig()
        config.meetingSpokenLanguage = try SpokenLanguageProfile(selectedLanguages: [.arabic])
        let session = makeSession(config: config)
        let queued = session.recognitionLanguageSwitcher.current
        session.updateTranscriptionAuthority(backend: .cohereArabic, usesUnifiedNemotronTranscript: false)
        #expect(try session.transcriptionBackend(for: queued) == .whisperLargeTurbo)
        session.updateAvailableLanguageModels([.cohereArabic])
        #expect(try session.transcriptionBackend(for: queued) == .cohereArabic)
        session.updateAvailableLanguageModels([.parakeetUnified])
        #expect(throws: LanguageRoutingIncompatibility.self) { try session.transcriptionBackend(for: queued) }
    }

    @Test("language changes are rejected outside an active recording")
    func rejectsInactiveSwitch() async {
        let session = makeSession(config: AppConfig())
        #expect(await !session.selectRecognitionLanguage(.arabic))
        #expect(session.recognitionLanguageSwitcher.selectedLanguage == nil)
    }

    @Test("live captions take the Nemotron prompt id from the meeting selection")
    func liveCaptionPromptIdFollowsMeetingSelection() throws {
        let dominant = try TranscriptionLanguageSelection(
            selectedLanguages: [.arabic, .english],
            dominantLanguage: .arabic
        )
        #expect(
            MeetingSession.liveCaptionNemotronPromptId(selection: dominant)
                == Nemotron35Language.arabic.promptId
        )

        let noDominant = try TranscriptionLanguageSelection(
            selectedLanguages: [.english, .french]
        )
        #expect(
            MeetingSession.liveCaptionNemotronPromptId(selection: noDominant)
                == Nemotron35Language.defaultLanguage.promptId
        )

        // Dutch is outside Nemotron's prompt table, so it detects instead.
        let unsupported = try TranscriptionLanguageSelection(selectedLanguages: [.dutch])
        #expect(
            MeetingSession.liveCaptionNemotronPromptId(selection: unsupported)
                == Nemotron35Language.defaultLanguage.promptId
        )
    }
}
