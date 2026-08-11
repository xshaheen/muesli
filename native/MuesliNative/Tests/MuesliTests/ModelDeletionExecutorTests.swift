import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Model deletion executor")
struct ModelDeletionExecutorTests {
    @Test("backend plans contain only immutable backend identity")
    func backendPlanExtraction() {
        #expect(
            ModelDeletionPlan.backend(.nemotron35Multilingual)
                == .backend(
                    backend: "nemotron35",
                    model: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
                )
        )
    }

    @Test("filesystem work runs outside the main thread")
    @MainActor
    func filesystemWorkRunsOffMainThread() async throws {
        let ranOnMainThread = try await ModelDeletionExecutor.runDetached {
            Thread.isMainThread
        }

        #expect(!ranOnMainThread)
    }
}
