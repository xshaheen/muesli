import Foundation
import Testing
@testable import ImlaNativeApp

@Suite("Speech model idle unload policy")
struct SpeechModelIdleUnloadPolicyTests {
    @Test("waits the configured number of minutes")
    func waitsConfiguredMinutes() {
        #expect(SpeechModelIdleUnloadPolicy.unloadDelaySeconds(
            idleMinutes: 15,
            isDictationActive: false,
            isMeetingActive: false
        ) == 900)
    }

    @Test("zero minutes keeps the models resident")
    func zeroMinutesNeverUnloads() {
        #expect(SpeechModelIdleUnloadPolicy.unloadDelaySeconds(
            idleMinutes: 0,
            isDictationActive: false,
            isMeetingActive: false
        ) == nil)
    }

    @Test("a live dictation keeps the models resident")
    func activeDictationNeverArms() {
        #expect(SpeechModelIdleUnloadPolicy.unloadDelaySeconds(
            idleMinutes: 15,
            isDictationActive: true,
            isMeetingActive: false
        ) == nil)
        #expect(!SpeechModelIdleUnloadPolicy.mayUnload(isDictationActive: true, isMeetingActive: false))
    }

    @Test("an active meeting keeps the models resident")
    func activeMeetingNeverArms() {
        #expect(SpeechModelIdleUnloadPolicy.unloadDelaySeconds(
            idleMinutes: 15,
            isDictationActive: false,
            isMeetingActive: true
        ) == nil)
        #expect(!SpeechModelIdleUnloadPolicy.mayUnload(isDictationActive: false, isMeetingActive: true))
        #expect(SpeechModelIdleUnloadPolicy.mayUnload(isDictationActive: false, isMeetingActive: false))
    }

    @Test("negative minutes resolve to never")
    func negativeMinutesResolveToNever() {
        #expect(SpeechModelIdleUnloadPolicy.resolvedIdleMinutes(-5) == 0)
        #expect(SpeechModelIdleUnloadPolicy.resolvedIdleMinutes(30) == 30)
    }

    @Test("releases designated models but never in-flight ones")
    func releasesIdleBackendsRegardlessOfDesignation() {
        let unloadable = SpeechModelIdleUnloadPolicy.backendsToUnload(
            loaded: ["cohere-arabic", "nemotron35", "fluidaudio"],
            inFlight: ["nemotron35"]
        )
        #expect(unloadable == ["cohere-arabic", "fluidaudio"])
        #expect(SpeechModelIdleUnloadPolicy.backendsToUnload(loaded: [], inFlight: []).isEmpty)
    }

    @Test("config defaults, decodes, and clamps the idle window")
    func configRoundTrip() throws {
        #expect(AppConfig().speechModelIdleUnloadMinutes == 15)

        let json = Data(#"{"speech_model_idle_unload_minutes": 45}"#.utf8)
        #expect(try JSONDecoder().decode(AppConfig.self, from: json).speechModelIdleUnloadMinutes == 45)

        let negative = Data(#"{"speech_model_idle_unload_minutes": -1}"#.utf8)
        #expect(try JSONDecoder().decode(AppConfig.self, from: negative).speechModelIdleUnloadMinutes == 0)

        // Configs written before the key existed must keep loading with the default.
        let legacy = Data(#"{"post_processor_idle_unload_minutes": 10}"#.utf8)
        #expect(try JSONDecoder().decode(AppConfig.self, from: legacy).speechModelIdleUnloadMinutes == 15)
    }
}
