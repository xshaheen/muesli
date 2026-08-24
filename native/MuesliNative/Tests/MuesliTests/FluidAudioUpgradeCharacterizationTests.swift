import FluidAudio
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
/// download when the path a model lands in moves.
///
/// Recorded against FluidAudio 0.15.1 *before* the pin moved to 0.15.6, per the plan's
/// R7/KTD4 and its execution note: without a baseline taken first, a post-upgrade failure
/// cannot be attributed to the upgrade. Every expectation is a value that must survive
/// unchanged, so a failure here is a report about the upgrade, not a test to update.
/// Change one only alongside a deliberate migration that says why the identity moved.
@Suite("FluidAudio upgrade characterization")
struct FluidAudioUpgradeCharacterizationTests {

    /// The one cross-boundary contract in this suite: Muesli hardcodes each repository
    /// string in `ManagedASRModelDownloads` (a module with no FluidAudio dependency at
    /// all), and FluidAudio independently declares the same model in its own `Repo` enum.
    /// Those two must agree. If an upstream release moves a model, `Repo`'s raw value
    /// changes, this breaks, and the upgrade stops rather than shipping a Muesli that
    /// downloads from a repository FluidAudio no longer serves.
    ///
    /// Everything below this case compares Muesli values to Muesli values. That is worth
    /// pinning against accidental edits, but it cannot fail when the *dependency* moves —
    /// an earlier version of this suite had only those cases while claiming to guard the
    /// upgrade, which is a guard that cannot fire.
    @Test("Muesli's repository identifiers still match FluidAudio's own")
    func repositoryIdentifiersMatchFluidAudio() {
        #expect(ManagedASRModelPlans.parakeetV3().repository == Repo.parakeetV3.rawValue)
        #expect(ManagedASRModelPlans.parakeetV2().repository == Repo.parakeetV2.rawValue)
        #expect(ManagedASRModelPlans.senseVoice().repository == Repo.senseVoiceSmall.rawValue)
        #expect(
            BackendOption.nemotron35Multilingual.model == Repo.nemotronMultilingual.rawValue,
            "the catalogue and FluidAudio disagree about the Nemotron multilingual repository"
        )
    }

    /// A release can keep a repository string identical and still relocate the directory
    /// its files land in, because FluidAudio derives that from `folderName` rather than
    /// from the repository. `parakeetEou320` is the case that shows the two differ: its
    /// repository ends `/320ms` while its folder is `parakeet-eou-streaming/320ms`.
    @Test("FluidAudio's cache-path derivation is unchanged by the upgrade")
    func cachePathDerivationIsUnchanged() {
        #expect(Repo.parakeetV3.folderName == "parakeet-tdt-0.6b-v3")
        #expect(Repo.parakeetEou320.folderName == "parakeet-eou-streaming/320ms")
        #expect(Repo.senseVoiceSmall.folderName == "sensevoice-small")
        // The `-coreml` strip is the behaviour the retired-cache cleanup relies on when it
        // looks for both `qwen3-asr-0.6b` and `qwen3-asr-0.6b-coreml`.
        #expect(!Repo.parakeetV3.folderName.hasSuffix("-coreml"))
    }

    /// Every managed model's repository and revision, frozen. Muesli values on both
    /// sides: this pins the catalogue against an accidental local edit and does **not**
    /// detect an upstream move — `repositoryIdentifiersMatchFluidAudio` is that case.
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

    /// `NemotronRNNTConfig` is **Muesli's own** type (`NemotronRNNTEngine.swift`), not
    /// FluidAudio's — an earlier comment here claimed the opposite, which made this read
    /// as upgrade protection it never provided. No FluidAudio release can rename these
    /// fields; the app runs its own Nemotron engine.
    ///
    /// It still earns a place pinning the geometry Muesli feeds the model (2240 ms at
    /// 16 kHz = 35,840 samples, cache shape from the checkpoint's metadata.json) against
    /// an accidental edit, with compilation covering the field names. No `#expect` on
    /// values just passed in — that would only prove the struct stores its arguments.
    @Test("Nemotron's streaming geometry is pinned against accidental edits")
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
