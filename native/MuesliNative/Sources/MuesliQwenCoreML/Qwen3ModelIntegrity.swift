import CryptoKit
import Foundation
import MuesliCore

/// Pinned source identity and digest verification for the Qwen Core ML cache.
///
/// The manifest was reviewed from FluidInference/qwen3-asr-0.6b-coreml at the
/// pinned revision below. It intentionally covers every file consumed by the
/// two compiled Core ML bundles, rather than using file presence or size as a
/// substitute for provenance.
public enum Qwen3ModelIntegrity {
    public static let repository = "FluidInference/qwen3-asr-0.6b-coreml"
    public static let revision = "c081689ec58bcf29c2ef7c474ef78a164bda672b"

    public static let digests: [String: String] = [
        "qwen3_asr_audio_encoder_v2.mlmodelc/analytics/coremldata.bin": "279247406b9e8e33dc1c256d4e2b5488b9a183daf9a8314172dac9e6f64b449a",
        "qwen3_asr_audio_encoder_v2.mlmodelc/coremldata.bin": "b319012fd80686a009585fc87f50d7e683bb4da8b5bd14bd506c53e54e5bfb6f",
        "qwen3_asr_audio_encoder_v2.mlmodelc/metadata.json": "fff797c7966cefa7fa68e8400aac81acd0542ceb5cf5eef3bff8faa373cc6840",
        "qwen3_asr_audio_encoder_v2.mlmodelc/model.mil": "15bc926f1d77c12307fc94178571b95861b385babfaea6f92e071e544abbb647",
        "qwen3_asr_audio_encoder_v2.mlmodelc/weights/weight.bin": "7173c9f195f8fed12354edb5861d041f623ca6dc057dd0f4a3cb436ef38f3141",
        "qwen3_asr_decoder_stateful.mlmodelc/analytics/coremldata.bin": "94f53ae20d39827cba410e845d27deaba7f9f7728d8074a26a1b5f6170405624",
        "qwen3_asr_decoder_stateful.mlmodelc/coremldata.bin": "27ca2172ef8a63b6fc6c5105e501de16f2e2d4f4a0ddef9dd8b37cc26d5675e3",
        "qwen3_asr_decoder_stateful.mlmodelc/metadata.json": "7d59f653586c9ea3059cdb5cf40044d81fb76549a13494ddddcbcd7c251d7e57",
        "qwen3_asr_decoder_stateful.mlmodelc/model.mil": "4a6205cfc691ded83ec354fd8dc758e3d0a8b884249158f4b1e150da91cc71e5",
        "qwen3_asr_decoder_stateful.mlmodelc/weights/weight.bin": "b5bc06697cdcf6ba241feb6f67a0a0b79042c53bc9a5f81a81ae3b8e4d410b69",
        "qwen3_asr_embeddings.bin": "dd1da448e68e0ee14a74f024ebfad964f39c9abcd30ac70632796c7ce76de873",
        "vocab.json": "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
    ]

    public static func plan(modelsRoot: URL? = nil) -> ManagedASRModelPlan {
        let directory = (modelsRoot ?? ManagedASRModelPlans.fluidAudioModelsRoot())
            .appendingPathComponent("qwen3-asr-0.6b/int8", isDirectory: true)
        return ManagedASRModelPlan(
            modelID: repository,
            repository: repository,
            revision: revision,
            cacheDirectory: directory,
            selections: [HuggingFaceModelSelection(
                remoteDirectory: "int8",
                includedPaths: Set(digests.keys),
                recursive: true
            )],
            requiredArtifactAlternatives: digests.keys.map { [$0] },
            integrityValidator: { cacheDirectory in
                try verify(cacheDirectory: cacheDirectory)
            }
        )
    }

    public static func verify(cacheDirectory: URL) throws {
        for (relativePath, expectedDigest) in digests {
            let url = cacheDirectory.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Qwen3ModelIntegrityError.missingArtifact(relativePath)
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == expectedDigest else {
                throw Qwen3ModelIntegrityError.digestMismatch(relativePath)
            }
        }
    }
}

public enum Qwen3ModelIntegrityError: Error, LocalizedError {
    case missingArtifact(String)
    case digestMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .missingArtifact(let path): return "Qwen model artifact is missing: \(path)"
        case .digestMismatch(let path): return "Qwen model artifact failed integrity verification: \(path)"
        }
    }
}
