import Foundation
import LLM

enum Qwen3PostProcessorLogging {
    private static let verboseEnv = "MUESLI_DEBUG_POSTPROC_LOGS"
    private static let pairLogEnv = "MUESLI_LOG_POSTPROC_PAIRS"

    static var isVerboseEnabled: Bool {
        let raw = ProcessInfo.processInfo.environment[verboseEnv]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    static var isPairLoggingEnabled: Bool {
        guard isVerboseEnabled else { return false }
        let raw = ProcessInfo.processInfo.environment[pairLogEnv]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    static func logVerbose(_ message: @autoclosure () -> String) {
        guard isVerboseEnabled else { return }
        fputs("[muesli-native] \(message())\n", stderr)
    }
}

enum Qwen3DeletionCueDetector {
    private static let deletionCues: [String] = [
        "scratch that", "delete that", "forget that", "never mind",
    ]

    static func containsDeletionCue(_ text: String) -> Bool {
        let lower = text.lowercased()
        return deletionCues.contains { lower.contains($0) }
    }
}

enum Qwen3PostProcessorOutputCleaner {
    static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text
        result = result.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?is)<think\b[^>]*>[\s\S]*$"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"<\|im_(?:start|end)\|>"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"```[A-Za-z0-9_-]*\s*"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"```"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"^`+|`+$"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\[end of text\]"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?im)^\s*(?:[#>*-]+\s*)?(?:\*\*|__)?(?:transcription|cleaned transcription|output|response)(?:\*\*|__)?\s*:\s*"#,
            with: "",
            options: .regularExpression
        )
        // Observed model leakage from earlier prompt variants. Keep narrow so normal transcript text is not rewritten.
        result = result.replacingOccurrences(
            of: #"(?im)^\s*when the speaker is dictating a numbered list or bullet list,\s*format each item on its own line\.?\s*"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?im)^\s*if the speaker is dictating a list, such as saying ["“”]?first point["“”]?[,]?\s*["“”]?second point["“”]?[,]?\s*or ["“”]?bullet point["“”]?[,]?\s*format each item on its own line\.?\s*"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?im)^\s*(?:\*\*|__)([^*\n_]{1,80})(?:\*\*|__)\s*$"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s{2,}"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shouldFallbackToInput(cleaned: String, input: String) -> Bool {
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let lower = trimmed.lowercased()
        if isPlaceholderOutput(trimmed) {
            return true
        }

        let assistantMarkers = [
            "the user is asking",
            "**analysis:**",
            "analysis:",
            "**action plan:**",
            "action plan:",
            "grammar/spelling:",
            "meaning:",
            "remove the filler word",
        ]
        if assistantMarkers.contains(where: { lower.contains($0) }) {
            return true
        }

        let inputLength = max(input.trimmingCharacters(in: .whitespacesAndNewlines).count, 1)
        // Cleanup should usually compress text. Treat expansion as a hallucination signal,
        // with a lower absolute floor for short dictations.
        let expansion = Double(trimmed.count) / Double(inputLength)
        if inputLength < 50 {
            return expansion > 4.0 && trimmed.count > 80
        }
        if inputLength < 150 {
            return expansion > 2.5 && trimmed.count > 150
        }
        return expansion > 2.0 && trimmed.count > 200
    }

    private static func isPlaceholderOutput(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: "…", with: "...")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "..." || normalized == ". . ." {
            return true
        }
        let punctuationOnly = normalized.allSatisfy { character in
            character.isWhitespace || ".…-_,;:!?()[]{}".contains(character)
        }
        return punctuationOnly && normalized.count <= 8
    }
}

enum Qwen3PostProcessorConfig {
    // Local development override — takes precedence over the UI-selected model when set.
    static let envOverride = "MUESLI_QWEN3_POSTPROC_GGUF"
    static let legacyDirectoryEnvOverride = "MUESLI_QWEN3_POSTPROC_DIR"
    // Dictation-only cleanup cap. Keep bounded to avoid slow local inference; long dictations may be truncated by LLM.swift.
    static let maxContextTokens: Int32 = 1024
    static let defaultAppContextCharacterLimit = 1_200
    static let safeSystemPromptFallback = PostProcessorOption.defaultSystemPrompt

    static func formatInput(
        _ text: String,
        appContext: String? = nil,
        maxAppContextCharacters: Int = defaultAppContextCharacterLimit
    ) -> String {
        var parts = ""
        if let appContext, !appContext.isEmpty {
            parts += "<APP-CONTEXT>\n\(String(appContext.prefix(maxAppContextCharacters)))\n</APP-CONTEXT>\n\n"
        }
        parts += "<USER-INPUT>\n\(text)\n</USER-INPUT>"
        return parts
    }

    /// Checks for a local development env-var override and returns the resolved GGUF URL if present.
    static func devOverrideURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        for key in [envOverride, legacyDirectoryEnvOverride] {
            guard let raw = env[key], !raw.isEmpty else { continue }
            let url = URL(fileURLWithPath: raw)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let found = firstGGUF(in: url) { return found }
            } else if url.pathExtension.lowercased() == "gguf" {
                return url
            }
        }
        return nil
    }

    private static func firstGGUF(in directory: URL) -> URL? {
        guard let e = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let f as URL in e where f.pathExtension.lowercased() == "gguf" { return f }
        return nil
    }
}

enum Qwen3PostProcessorError: LocalizedError {
    case unavailable(String)
    case emptyOutput
    case rejectedOutput

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            message
        case .emptyOutput:
            "Qwen3 GGUF returned an empty transcript cleanup response."
        case .rejectedOutput:
            "Qwen3 GGUF output was rejected by transcript safety checks."
        }
    }
}

struct Qwen3RequestTemplatePlan: Equatable {
    let requestPrompt: String
    let resetPrompt: String

    init(requestPrompt: String) {
        let trimmed = requestPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestPrompt = trimmed.isEmpty ? Qwen3PostProcessorConfig.safeSystemPromptFallback : requestPrompt
        resetPrompt = Qwen3PostProcessorConfig.safeSystemPromptFallback
    }
}

actor InferenceGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isProcessing = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !isProcessing {
            isProcessing = true
            return
        }

        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        guard acquired else { throw CancellationError() }
    }

    func release() {
        if waiters.isEmpty {
            isProcessing = false
            return
        }

        waiters.removeFirst().continuation.resume(returning: true)
    }

    func queuedWaiterCount() -> Int {
        waiters.count
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

@available(macOS 15, *)
private actor Qwen3PostProcessorManager {
    private let modelURL: URL
    private var bot: LLM?
    private let inferenceGate = InferenceGate()

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    func warm() throws {
        _ = try loadBot()
    }

    func process(
        _ text: String,
        systemPrompt: String,
        appContext: String? = nil
    ) async throws -> String {
        // Actors can re-enter while respond() awaits; serialize access to the cached mutable LLM.
        try await inferenceGate.acquire()
        // Reset the cached LLM before releasing the gate; a queued waiter starts
        // generating the moment release() hands it over.
        var loadedBot: LLM?
        do {
            try Task.checkCancellation()
            let bot = try loadBot()
            loadedBot = bot
            let templatePlan = Qwen3RequestTemplatePlan(requestPrompt: systemPrompt)
            bot.useResolvedTemplate(systemPrompt: templatePlan.requestPrompt)
            let formattedInput = Qwen3PostProcessorConfig.formatInput(text, appContext: appContext)
            await bot.respond(to: formattedInput, thinking: .suppressed)
            let raw = bot.output
            let cleaned = Qwen3PostProcessorOutputCleaner.clean(raw)
            Qwen3PostProcessorLogging.logVerbose("Qwen3 GGUF prompt chars=\(bot.preprocess(formattedInput, [], .suppressed).count)")
            Qwen3PostProcessorLogging.logVerbose("Qwen3 GGUF raw output: \(raw)")
            Qwen3PostProcessorLogging.logVerbose("Qwen3 GGUF cleaned output: \(cleaned)")
            let result: String
            if cleaned.isEmpty, !Qwen3DeletionCueDetector.containsDeletionCue(text) {
                throw Qwen3PostProcessorError.emptyOutput
            } else if !cleaned.isEmpty,
                      Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(cleaned: cleaned, input: text) {
                Qwen3PostProcessorLogging.logVerbose("Qwen3 GGUF output rejected; falling back to deterministic cleanup")
                throw Qwen3PostProcessorError.rejectedOutput
            } else {
                result = cleaned
            }
            bot.reset()
            bot.useResolvedTemplate(systemPrompt: templatePlan.resetPrompt)
            await inferenceGate.release()
            return result
        } catch {
            loadedBot?.reset()
            loadedBot?.useResolvedTemplate(systemPrompt: Qwen3PostProcessorConfig.safeSystemPromptFallback)
            await inferenceGate.release()
            throw error
        }
    }

    private func loadBot() throws -> LLM {
        if let bot { return bot }
        guard let loaded = LLM(
            from: modelURL,
            seed: 7,
            topK: 1,
            topP: 1.0,
            temp: 0.0,
            repeatPenalty: 1.0,
            repetitionLookback: 64,
            historyLimit: 0,
            maxTokenCount: Qwen3PostProcessorConfig.maxContextTokens
        ) else {
            throw Qwen3PostProcessorError.unavailable(
                "Failed to load Qwen3 GGUF model at \(modelURL.path)"
            )
        }
        loaded.useResolvedTemplate(systemPrompt: Qwen3PostProcessorConfig.safeSystemPromptFallback)
        bot = loaded
        return loaded
    }
}

@available(macOS 15, *)
actor Qwen3PostProcessor {
    private struct LoadTaskState {
        let id = UUID()
        let modelURL: URL
        let task: Task<Qwen3PostProcessorManager, Error>
    }

    private var modelURL: URL
    private var systemPrompt: String
    private var manager: Qwen3PostProcessorManager?
    private var loadTask: LoadTaskState?

    init(modelURL: URL, systemPrompt: String) {
        // Local development env-var override takes precedence.
        self.modelURL = Qwen3PostProcessorConfig.devOverrideURL() ?? modelURL
        self.systemPrompt = systemPrompt
    }

    /// Update global defaults. Only a model URL change discards resident weights;
    /// prompt changes are request-scoped and applied inside the inference gate.
    func reconfigure(modelURL: URL, systemPrompt: String) {
        let resolved = Qwen3PostProcessorConfig.devOverrideURL() ?? modelURL
        let shouldReload = Self.requiresModelReload(current: self.modelURL, next: resolved)
        self.modelURL = resolved
        self.systemPrompt = systemPrompt
        guard shouldReload else { return }
        manager = nil
        loadTask?.task.cancel()
        loadTask = nil
    }

    /// Whether the GGUF weights are resident (or on their way in). Lets the idle
    /// unload skip — and stay silent about — a model that was never loaded.
    var isLoaded: Bool {
        manager != nil || loadTask != nil
    }

    func prepare() async throws {
        _ = try await loadManager()
    }

    func process(
        _ text: String,
        modelURL requestedModelURL: URL? = nil,
        systemPrompt: String? = nil,
        appContext: String? = nil
    ) async throws -> String {
        let requestPrompt = systemPrompt ?? self.systemPrompt
        let manager = if let requestedModelURL {
            try await loadManager(for: requestedModelURL)
        } else {
            try await loadManager()
        }
        return try await manager.process(
            text,
            systemPrompt: requestPrompt,
            appContext: appContext
        )
    }

    static func requiresModelReload(current: URL, next: URL) -> Bool {
        current != next
    }

    static func resolvedRequestModelURL(
        requested: URL,
        devOverride: URL? = Qwen3PostProcessorConfig.devOverrideURL()
    ) -> URL {
        devOverride ?? requested
    }

    func shutdown() {
        manager = nil
        loadTask?.task.cancel()
        loadTask = nil
    }

    private func loadManager() async throws -> Qwen3PostProcessorManager {
        if let manager { return manager }
        if let loadTask { return try await finishLoad(loadTask) }

        let url = modelURL
        let task = makeLoadTask(modelURL: url)
        let state = LoadTaskState(modelURL: url, task: task)
        loadTask = state
        return try await finishLoad(state)
    }

    /// Returns a manager bound to the request's model even if settings reconfigure
    /// the global default while ASR or model loading is suspended. A request for
    /// the current model still reuses its resident weights.
    private func loadManager(for requestedModelURL: URL) async throws -> Qwen3PostProcessorManager {
        let requestedModelURL = Self.resolvedRequestModelURL(requested: requestedModelURL)
        if requestedModelURL == modelURL {
            if let loadTask, loadTask.modelURL == requestedModelURL {
                do {
                    return try await finishRequestLoad(loadTask, cacheIfCurrent: true)
                } catch is CancellationError {
                    // A concurrent settings change cancelled the global preload.
                    // Retry below against the request's URL, not the new default.
                    return try await loadManager(for: requestedModelURL)
                }
            }
            return try await loadManager()
        }

        let url = requestedModelURL
        let task = makeLoadTask(modelURL: url)
        let state = LoadTaskState(modelURL: url, task: task)
        return try await finishRequestLoad(state, cacheIfCurrent: url == modelURL)
    }

    private func finishLoad(_ state: LoadTaskState) async throws -> Qwen3PostProcessorManager {
        do {
            let loaded = try await state.task.value
            guard state.modelURL == modelURL else {
                if loadTask?.id == state.id {
                    loadTask = nil
                }
                return try await loadManager()
            }
            if let manager { return manager }
            guard loadTask?.id == state.id else { throw CancellationError() }
            manager = loaded
            loadTask = nil
            return loaded
        } catch {
            if loadTask?.id == state.id {
                loadTask = nil
            }
            throw error
        }
    }

    private func makeLoadTask(modelURL: URL) -> Task<Qwen3PostProcessorManager, Error> {
        Task<Qwen3PostProcessorManager, Error> {
            guard FileManager.default.fileExists(atPath: modelURL.path) else {
                throw Qwen3PostProcessorError.unavailable(
                    "Post-processor model not found at \(modelURL.path). Download it from the Models tab."
                )
            }
            let manager = Qwen3PostProcessorManager(modelURL: modelURL)
            try await manager.warm()
            return manager
        }
    }

    private func finishRequestLoad(
        _ state: LoadTaskState,
        cacheIfCurrent: Bool
    ) async throws -> Qwen3PostProcessorManager {
        do {
            let loaded = try await state.task.value
            if cacheIfCurrent, state.modelURL == modelURL {
                if let manager { return manager }
                manager = loaded
            }
            return loaded
        } catch {
            if loadTask?.id == state.id {
                loadTask = nil
            }
            throw error
        }
    }
}
