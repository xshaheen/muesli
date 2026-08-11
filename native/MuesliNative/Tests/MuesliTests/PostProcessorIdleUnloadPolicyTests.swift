import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Post-processor idle unload policy")
struct PostProcessorIdleUnloadPolicyTests {
    @Test("waits the configured number of minutes")
    func waitsConfiguredMinutes() {
        #expect(PostProcessorIdleUnloadPolicy.unloadDelaySeconds(
            idleMinutes: 15,
            isMeetingActive: false
        ) == 900)
    }

    @Test("zero minutes keeps the model resident")
    func zeroMinutesNeverUnloads() {
        #expect(PostProcessorIdleUnloadPolicy.unloadDelaySeconds(
            idleMinutes: 0,
            isMeetingActive: false
        ) == nil)
    }

    @Test("an active meeting keeps the model resident")
    func activeMeetingNeverUnloads() {
        #expect(PostProcessorIdleUnloadPolicy.unloadDelaySeconds(
            idleMinutes: 15,
            isMeetingActive: true
        ) == nil)
    }

    @Test("a negative configured value is treated as never unload")
    func negativeMinutesClampToNever() {
        #expect(PostProcessorIdleUnloadPolicy.resolvedIdleMinutes(-5) == 0)
        #expect(PostProcessorIdleUnloadPolicy.unloadDelaySeconds(
            idleMinutes: PostProcessorIdleUnloadPolicy.resolvedIdleMinutes(-5),
            isMeetingActive: false
        ) == nil)
    }

    @Test("a valid configured value is preserved")
    func validMinutesPreserved() {
        #expect(PostProcessorIdleUnloadPolicy.resolvedIdleMinutes(30) == 30)
        #expect(PostProcessorIdleUnloadPolicy.resolvedIdleMinutes(0) == 0)
    }

    @Test("Gemma stays loaded while it is the active dictation backend")
    func gemmaStaysLoadedWhileTranscribing() {
        #expect(!PostProcessorIdleUnloadPolicy.canUnloadGemma4Engine(
            activeTranscriptionBackend: BackendOption.gemma4E2BLiteRT.backend
        ))
    }

    @Test("Gemma may be unloaded when another backend transcribes")
    func gemmaUnloadableUnderOtherBackends() {
        #expect(PostProcessorIdleUnloadPolicy.canUnloadGemma4Engine(activeTranscriptionBackend: "fluidaudio"))
        #expect(PostProcessorIdleUnloadPolicy.canUnloadGemma4Engine(activeTranscriptionBackend: nil))
    }

    @Test("config defaults to 15 minutes and round-trips the snake_case key")
    func configRoundTripsIdleUnloadMinutes() throws {
        #expect(AppConfig().postProcessorIdleUnloadMinutes == 15)

        let json = Data(#"{"post_processor_idle_unload_minutes": 45}"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.postProcessorIdleUnloadMinutes == 45)

        let negative = Data(#"{"post_processor_idle_unload_minutes": -1}"#.utf8)
        #expect(try JSONDecoder().decode(AppConfig.self, from: negative).postProcessorIdleUnloadMinutes == 0)
    }
}
