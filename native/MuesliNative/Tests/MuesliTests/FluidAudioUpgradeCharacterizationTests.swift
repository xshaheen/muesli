import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

/// What a FluidAudio version bump is allowed to change, and what it is not.
///
/// A dependency upgrade that merely compiles has proved almost nothing. The failure this
/// suite exists to catch is the silent one: an upstream release moves a model to a new
/// repository or revision, Muesli goes on offering it under the same label, and a user
/// who chose a model quietly receives a different one — or keeps the label and loses the
/// download, because `Repo.folderName` derives the on-disk cache path from exactly these
/// identifiers.
///
/// Recorded against FluidAudio 0.15.1 *before* the pin moved to 0.15.6, per the plan's
/// R7/KTD4 and its execution note: without a baseline taken first, a post-upgrade failure
/// cannot be attributed to the upgrade. Every expectation is a value that must survive
/// unchanged, so a failure here is a report about the upgrade, not a test to update.
/// Change one only alongside a deliberate migration that says why the identity moved.
@Suite("FluidAudio upgrade characterization")
struct FluidAudioUpgradeCharacterizationTests {

    /// Every managed model's repository and revision, frozen.
    @Test("managed model repositories and revisions are unchanged by the upgrade")
    func managedModelIdentitiesAreFrozen() {
        let plans: [(String, ManagedASRModelPlan)] = [
            ("parakeet v2", ManagedASRModelPlans.parakeetV2()),
            ("parakeet v3", ManagedASRModelPlans.parakeetV3()),
            ("sensevoice", ManagedASRModelPlans.senseVoice()),
            ("parakeet realtime EOU", ManagedASRModelPlans.parakeetRealtimeEOU320()),
        ]
        let expectedRepositories = [
            "parakeet v2": "FluidInference/parakeet-tdt-0.6b-v2-coreml",
            "parakeet v3": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            "sensevoice": "FluidInference/sensevoice-small-coreml",
            "parakeet realtime EOU": "FluidInference/parakeet-realtime-eou-120m-coreml",
        ]
        for (label, plan) in plans {
            #expect(plan.repository == expectedRepositories[label], "\(label) changed repository")
            #expect(plan.revision == "main", "\(label) changed revision")
        }

        let whisper = ManagedASRModelPlans.whisperKit(modelName: "large-v3-v20240930_626MB")
        #expect(whisper.repository == "argmaxinc/whisperkit-coreml")
    }

    /// The catalogue's model strings are a stronger contract than the download plan:
    /// a config persists them, so a changed value invalidates a saved selection rather
    /// than merely re-downloading it.
    @Test("catalogue model identifiers are unchanged by the upgrade")
    func catalogueModelIdentifiersAreFrozen() {
        let expected: Set<String> = [
            "FluidInference/parakeet-tdt-0.6b-v2-coreml",
            "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            "FluidInference/sensevoice-small-coreml",
            "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
            "phequals/cohere-transcribe-coreml-mixed-precision",
            "phequals/indic-conformer-600m-multilingual-coreml-rnnt",
        ]
        let present = Set(BackendOption.all.map(\.model))
        for model in expected {
            #expect(present.contains(model), "the catalogue no longer offers \(model)")
        }
    }

    /// R8: readiness must mean the same thing after the upgrade as before it. An empty
    /// root is the half that a stale-cache bug breaks — it starts reporting ready — and
    /// the required-artifact list is what readiness is actually judged against, so a
    /// release that renames an artifact silently invalidates every existing install.
    @Test("cache readiness is judged the same way after the upgrade")
    func cacheReadinessIsUnchanged() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("muesli-fluidaudio-char-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = ManagedASRModelPlans.parakeetV3(modelsRoot: root)
        #expect(!plan.isComplete(), "an empty cache root reported itself complete")
        #expect(!plan.isAvailableLocally(), "an empty cache root reported itself available")
        #expect(!plan.requiredArtifactAlternatives.isEmpty, "parakeet v3 stopped requiring any artifact")

        let whisper = ManagedASRModelPlans.whisperKit(
            modelName: "large-v3-v20240930_626MB",
            downloadRoot: root
        )
        #expect(!whisper.isComplete())
        // Readiness is judged on files *inside* each compiled bundle, not on the bundle
        // directory: a `.mlmodelc` can exist as an empty or half-written directory after
        // an interrupted download, so requiring the directory would call that install
        // complete. This is exactly why the measurement harness refuses a partial
        // tiny.en that has an `AudioEncoder.mlpackage` but no compiled weights.
        let whisperRequired = Set(whisper.requiredArtifactAlternatives.flatMap { $0 })
        #expect(whisperRequired.contains("TextDecoder.mlmodelc/weights/weight.bin"))
        #expect(whisperRequired.contains("TextDecoder.mlmodelc/coremldata.bin"))
        #expect(whisperRequired.contains("generation_config.json"))
    }

    /// FluidAudio owns `NemotronRNNTConfig`, so a release that renames or retypes one of
    /// its geometry fields changes Muesli's streaming contract. **Compiling is the
    /// assertion here** — this initialiser names every field Muesli depends on, so a
    /// field that is renamed, removed, or retyped upstream breaks the build rather than
    /// passing quietly.
    ///
    /// Deliberately no `#expect` on the values that were just passed in: asserting
    /// `config.chunkSamples == 35840` after constructing it with `chunkSamples: 35840`
    /// only proves the struct stores its arguments, and would read as upgrade safety it
    /// does not provide. The values themselves (2240 ms at 16 kHz = 35,840 samples, and
    /// the cache geometry from the model's metadata.json) are Muesli's own constants and
    /// are covered where the backend declares them.
    @Test("Nemotron's FluidAudio config surface is unchanged by the upgrade")
    func nemotronStreamingConfigSurfaceIsFrozen() {
        _ = NemotronRNNTConfig(
            chunkSamples: 35840,
            cacheChannelFrames: 42,
            totalMelFrames: 233,
            encoderDim: 1024,
            decoderHiddenSize: 640,
            blankTokenId: 13087,
            promptId: 101,
            stripAngleBracketTags: true
        )
    }
}
