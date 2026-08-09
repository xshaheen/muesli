import Foundation
import MuesliCore

/// A value-only description of model files to remove. Building the plan on the
/// main actor is cheap; resolving directories and touching disk happens only in
/// `ModelDeletionExecutor`'s detached utility task.
enum ModelDeletionPlan: Sendable, Equatable {
    case backend(backend: String, model: String)
    case postProcessor(cacheDirectory: URL)
    case liveCaption

    static func backend(_ option: BackendOption) -> Self {
        .backend(backend: option.backend, model: option.model)
    }

    static func postProcessor(_ option: PostProcessorOption) -> Self {
        .postProcessor(cacheDirectory: option.cacheDirectory)
    }

    fileprivate func execute() throws {
        let fileManager = FileManager.default
        switch self {
        case .backend(let backend, let model):
            try Self.deleteBackend(
                backend: backend,
                model: model,
                fileManager: fileManager
            )
        case .postProcessor(let cacheDirectory):
            // Preserve the post-processor flow's best-effort deletion behavior.
            try? fileManager.removeItem(at: cacheDirectory)
        case .liveCaption:
            try MeetingLiveCaptionModelStore.delete(fileManager: fileManager)
        }
    }

    private static func deleteBackend(
        backend: String,
        model: String,
        fileManager: FileManager
    ) throws {
        switch backend {
        case "whisper":
            WhisperKitTranscriber.deleteModel(model)
        case "nemotron35":
            try removeItemIfPresent(
                at: Nemotron35ModelStore.cacheDirectory(fileManager: fileManager),
                fileManager: fileManager
            )
        case "cohere":
            try removeItemIfPresent(
                at: CohereTranscribeModelStore.cacheDirectory(),
                fileManager: fileManager
            )
        case "indicasr":
            if IndicASRModelStore.localOverrideDirectory() == nil {
                try removeItemIfPresent(
                    at: IndicASRModelStore.cacheDirectory(),
                    fileManager: fileManager
                )
            }
        case "sensevoice":
            SenseVoiceTranscriber.deleteModelFiles(fileManager: fileManager)
        case "gemma4-litert":
            try Gemma4LiteRTModelStore.deleteModelFiles(fileManager: fileManager)
        case "fluidaudio":
            let supportDirectory = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models")
            if model.contains("parakeet") {
                let version = model.contains("v2") ? "v2" : "v3"
                if let contents = try? fileManager.contentsOfDirectory(
                    at: supportDirectory,
                    includingPropertiesForKeys: nil
                ) {
                    for directory in contents
                    where directory.lastPathComponent.contains("parakeet")
                        && directory.lastPathComponent.contains(version) {
                        try removeItemIfPresent(at: directory, fileManager: fileManager)
                    }
                }
            }
        case "qwen":
            let path = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models/qwen3-asr-0.6b-coreml")
            try removeItemIfPresent(at: path, fileManager: fileManager)
        default:
            break
        }
    }

    private static func removeItemIfPresent(
        at url: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}

enum ModelDeletionExecutor {
    static func execute(_ plan: ModelDeletionPlan) async throws {
        try await runDetached {
            try plan.execute()
        }
    }

    /// Kept internal so tests can assert the executor boundary without touching
    /// any real model directories.
    static func runDetached<Result: Sendable>(
        _ operation: @escaping @Sendable () throws -> Result
    ) async throws -> Result {
        try await Task.detached(priority: .utility, operation: operation).value
    }
}
