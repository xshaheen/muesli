import Foundation
import Testing
@testable import MuesliQwenCoreML

@Suite("Muesli Qwen3 Core ML")
struct Qwen3CoreMLTests {
    @Test("derived runtime preserves pinned architecture constants")
    func preservesPinnedArchitectureConstants() {
        #expect(MuesliQwen3AsrConfig.sampleRate == 16_000)
        #expect(MuesliQwen3AsrConfig.maxCacheSeqLen == 512)
        #expect(MuesliQwen3AsrConfig.audioTokenId == 151_676)
        #expect(MuesliQwen3AsrConfig.Language(from: "Arabic") == .arabic)
    }

    @Test("RoPE preserves the pinned head dimension and positions")
    func ropePreservesPinnedGeometry() {
        let rope = MuesliQwen3RoPE()
        let range = rope.computeRange(startPosition: 0, count: 2)
        #expect(rope.headDim == MuesliQwen3AsrConfig.headDim)
        #expect(range.cos.count == 2 * MuesliQwen3AsrConfig.headDim)
        #expect(range.sin.count == 2 * MuesliQwen3AsrConfig.headDim)
        #expect(range.cos.allSatisfy { $0.isFinite })
        #expect(range.sin.allSatisfy { $0.isFinite })
    }

    @Test("pinned integrity rejects missing artifacts")
    func integrityRejectsMissingArtifacts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-qwen-integrity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: Qwen3ModelIntegrityError.self) {
            try Qwen3ModelIntegrity.verify(cacheDirectory: directory)
        }
    }
}
