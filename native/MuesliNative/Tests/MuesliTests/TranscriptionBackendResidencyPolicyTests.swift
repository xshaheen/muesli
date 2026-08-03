import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("TranscriptionBackendResidencyPolicy")
struct TranscriptionBackendResidencyPolicyTests {
    private func designation(
        dictation: String? = nil,
        meetingTranscription: String? = nil,
        meetingLiveCaption: String? = nil,
        postProcessor: String? = nil
    ) -> TranscriptionBackendResidencyPolicy.Designation {
        TranscriptionBackendResidencyPolicy.Designation(
            dictation: dictation,
            meetingTranscription: meetingTranscription,
            meetingLiveCaption: meetingLiveCaption,
            postProcessor: postProcessor
        )
    }

    @Test("unloads backends left over from earlier selections")
    func unloadsUndesignatedBackends() {
        let unloadable = TranscriptionBackendResidencyPolicy.backendsToUnload(
            loaded: ["whisper", "qwen", "fluidaudio"],
            designation: designation(dictation: "fluidaudio")
        )

        #expect(unloadable == ["qwen", "whisper"])
    }

    @Test("keeps every designated slot resident")
    func keepsDesignatedSlots() {
        let unloadable = TranscriptionBackendResidencyPolicy.backendsToUnload(
            loaded: ["fluidaudio", "whisper", "nemotron35", "cohere"],
            designation: designation(
                dictation: "fluidaudio",
                meetingTranscription: "whisper",
                meetingLiveCaption: "nemotron35"
            )
        )

        #expect(unloadable == ["cohere"])
    }

    @Test("keeps a Gemma cleanup engine that ASR no longer designates")
    func keepsGemmaWhenItServesCleanupOnly() {
        let unloadable = TranscriptionBackendResidencyPolicy.backendsToUnload(
            loaded: ["fluidaudio", "gemma4-litert"],
            designation: designation(dictation: "fluidaudio", postProcessor: "gemma4-litert")
        )

        #expect(unloadable.isEmpty)
    }

    @Test("releases the Gemma engine once cleanup moves off it")
    func releasesGemmaAfterCleanupSwitchesAway() {
        let unloadable = TranscriptionBackendResidencyPolicy.backendsToUnload(
            loaded: ["fluidaudio", "gemma4-litert"],
            designation: designation(dictation: "fluidaudio")
        )

        #expect(unloadable == ["gemma4-litert"])
    }

    @Test("never unloads a backend that is mid-transcription")
    func skipsInFlightBackends() {
        let unloadable = TranscriptionBackendResidencyPolicy.backendsToUnload(
            loaded: ["fluidaudio", "whisper", "qwen"],
            designation: designation(dictation: "fluidaudio"),
            inFlight: ["whisper"]
        )

        #expect(unloadable == ["qwen"])
    }

    @Test("one backend serving several slots is designated once")
    func sharedBackendAcrossSlots() {
        let sharedDesignation = designation(
            dictation: "nemotron35",
            meetingTranscription: "nemotron35",
            meetingLiveCaption: "nemotron35"
        )

        #expect(sharedDesignation.backendIdentifiers == ["nemotron35"])
        #expect(
            TranscriptionBackendResidencyPolicy.backendsToUnload(
                loaded: ["nemotron35"],
                designation: sharedDesignation
            ).isEmpty
        )
    }

    @Test("an empty designation releases everything loaded")
    func emptyDesignationReleasesEverything() {
        let unloadable = TranscriptionBackendResidencyPolicy.backendsToUnload(
            loaded: ["fluidaudio", "whisper"],
            designation: designation()
        )

        #expect(unloadable == ["fluidaudio", "whisper"])
    }

    @Test("nothing loaded means nothing to unload")
    func nothingLoaded() {
        #expect(
            TranscriptionBackendResidencyPolicy.backendsToUnload(
                loaded: [],
                designation: designation(dictation: "fluidaudio")
            ).isEmpty
        )
    }
}
