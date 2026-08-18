import Foundation
import MuesliCore

struct SessionTraceInitialArtifact: Sendable {
    let content: String
    let kind: SessionTraceArtifactKind
}

/// Owns one product run's terminal decision and mirrors diagnostic evidence to
/// the local trace store. The in-memory decision is made before awaiting SQLite,
/// so product publication remains exactly-once even when diagnostics are
/// unavailable. Nonterminal evidence stays off the product hot path; terminal
/// callers wait for the ordered durable attempt before publishing or releasing
/// the session.
actor SessionRunTrace {
    nonisolated let sessionID: UUID

    private let store: SessionTraceStore?
    private let onTerminalWriteFinished: (@Sendable (UUID) -> Void)?
    private let tokenTask: Task<SessionTraceWriterToken?, Never>
    private var writeTail: Task<Void, Never>?
    private var terminalOutcome: SessionTraceTerminalOutcome?

    init(
        id sessionID: UUID = UUID(),
        store: SessionTraceStore?,
        kind: SessionTraceKind,
        backendIdentity: String? = nil,
        fallbackBackendIdentity: String? = nil,
        startedAt: Date = Date(),
        initialArtifacts: [SessionTraceInitialArtifact] = [],
        onTerminalWriteFinished: (@Sendable (UUID) -> Void)? = nil
    ) {
        self.sessionID = sessionID
        self.store = store
        self.onTerminalWriteFinished = onTerminalWriteFinished
        tokenTask = Task.detached(priority: .utility) {
            guard let store else { return nil }
            return try? await store.beginSession(
                id: sessionID,
                kind: kind,
                backendIdentity: backendIdentity,
                fallbackBackendIdentity: fallbackBackendIdentity,
                at: startedAt
            )
        }
        if let store, !initialArtifacts.isEmpty {
            let initialTokenTask = tokenTask
            writeTail = Task.detached(priority: .utility) {
                guard let token = await initialTokenTask.value else { return }
                for artifact in initialArtifacts {
                    _ = try? await store.storeArtifact(
                        artifact.content,
                        kind: artifact.kind,
                        token: token
                    )
                }
            }
        }
    }

    func recordStageStarted(
        _ stage: String,
        metadata: [String: String] = [:]
    ) async {
        await appendEvent(.stageStarted, stage: stage, metadata: metadata)
    }

    func recordStageCompleted(
        _ stage: String,
        elapsedMilliseconds: Int? = nil,
        metadata: [String: String] = [:]
    ) async {
        await appendEvent(
            .stageCompleted,
            stage: stage,
            elapsed: elapsedMilliseconds.map { TimeInterval($0) / 1_000 },
            metadata: metadata
        )
    }

    func recordStageFailed(
        _ stage: String,
        elapsedMilliseconds: Int? = nil,
        metadata: [String: String] = [:]
    ) async {
        await appendEvent(
            .stageFailed,
            stage: stage,
            elapsed: elapsedMilliseconds.map { TimeInterval($0) / 1_000 },
            metadata: metadata
        )
    }

    func recordFallbackStarted(
        _ stage: String,
        metadata: [String: String] = [:]
    ) async {
        await appendEvent(.fallbackStarted, stage: stage, metadata: metadata)
    }

    func recordCancellationRequested(
        stage: String,
        metadata: [String: String] = [:]
    ) async {
        await appendEvent(.cancellationRequested, stage: stage, metadata: metadata)
    }

    @discardableResult
    func cancel(stage: String, metadata: [String: String] = [:]) async -> Bool {
        await appendEvent(.cancellationRequested, stage: stage, metadata: metadata)
        var terminalMetadata = metadata
        terminalMetadata["stage"] = stage
        return await claimTerminal(.cancelled, metadata: terminalMetadata)
    }

    @discardableResult
    func fail(stage: String, metadata: [String: String] = [:]) async -> Bool {
        await appendEvent(.stageFailed, stage: stage, metadata: metadata)
        var terminalMetadata = metadata
        terminalMetadata["stage"] = stage
        return await claimTerminal(.failed, metadata: terminalMetadata)
    }

    func storeArtifact(_ content: String, kind: SessionTraceArtifactKind) async {
        guard terminalOutcome == nil else { return }
        enqueueWrite { store, token in
            _ = try? await store.storeArtifact(content, kind: kind, token: token)
        }
    }

    func associate(dictationID: Int64? = nil, meetingID: Int64? = nil) async {
        guard terminalOutcome == nil else { return }
        enqueueWrite { store, token in
            _ = try? await store.associate(
                token: token,
                dictationID: dictationID,
                meetingID: meetingID
            )
        }
    }

    /// Returns true only to the first local claimant. The local decision is made
    /// before suspension so late work is rejected immediately, then the ordered
    /// durable write is attempted before publication can continue.
    @discardableResult
    func claimTerminal(
        _ outcome: SessionTraceTerminalOutcome,
        metadata: [String: String] = [:]
    ) async -> Bool {
        guard terminalOutcome == nil else { return false }
        terminalOutcome = outcome
        enqueueWrite { store, token in
            _ = try? await store.claimTerminal(outcome, metadata: metadata, token: token)
        }
        await writeTail?.value
        onTerminalWriteFinished?(sessionID)
        return true
    }

    func publish<Value: Sendable>(
        _ value: Value,
        outcome: SessionTraceTerminalOutcome,
        metadata: [String: String] = [:]
    ) async -> Value? {
        await claimTerminal(outcome, metadata: metadata) ? value : nil
    }

    func detail() async -> SessionTraceDetail? {
        await flush()
        guard let store else { return nil }
        return try? await store.detail(sessionID: sessionID)
    }

    func flush() async {
        _ = await tokenTask.value
        await writeTail?.value
    }

    private func appendEvent(
        _ vocabulary: SessionTraceEventVocabulary,
        stage: String,
        elapsed: TimeInterval? = nil,
        metadata: [String: String]
    ) async {
        guard terminalOutcome == nil else { return }
        enqueueWrite { store, token in
            _ = try? await store.appendEvent(
                vocabulary,
                stage: stage,
                elapsed: elapsed,
                metadata: metadata,
                token: token
            )
        }
    }

    private func enqueueWrite(
        _ operation: @escaping @Sendable (SessionTraceStore, SessionTraceWriterToken) async -> Void
    ) {
        guard let store else { return }
        let predecessor = writeTail
        let tokenTask = tokenTask
        writeTail = Task.detached(priority: .utility) {
            await predecessor?.value
            guard let token = await tokenTask.value else { return }
            await operation(store, token)
        }
    }
}

struct TranscriptionActivityOwnership: Equatable {
    let queuedDictations: Int
    let meetingFinalizations: Int

    init(queuedDictations: Int = 0, meetingFinalizations: Int = 0) {
        self.queuedDictations = max(queuedDictations, 0)
        self.meetingFinalizations = max(meetingFinalizations, 0)
    }

    var isActive: Bool {
        queuedDictations > 0 || meetingFinalizations > 0
    }
}

enum SessionTraceSnapshot {
    private struct EncodedLanguageProfile: Encodable {
        let schemaVersion = 2
        let status = "frozen"
        let backend: String
        let selectedLanguages: [String]
        let dominantLanguage: String?
        let meetingOutputPolicy: String
        let effectiveLanguage: String?
        let effectiveBehavior: String
    }

    private struct EncodedRetranscriptionContext: Encodable {
        let scope = "meeting_retranscription"
        let existingNotes: Bool
        let manualNotes: Bool
    }

    static func backendIdentity(_ backend: BackendOption) -> String {
        boundedIdentifier("\(backend.backend):\(backend.model)")
    }

    static func cleanupIdentity(_ backend: TranscriptCleanupBackendOption) -> String {
        boundedIdentifier("cleanup:\(backend.backend)")
    }

    static func fallbackIdentity(kind: String, value: String) -> String {
        boundedIdentifier("\(kind):\(value)")
    }

    static func languageProfile(
        backend: BackendOption,
        profile: LanguageProfile
    ) -> String {
        let behavior = profile.effectiveBehavior(for: backend)
        return encode(EncodedLanguageProfile(
            backend: backend.backend,
            selectedLanguages: profile.selectedLanguages.map(\.rawValue),
            dominantLanguage: profile.dominantLanguage?.rawValue,
            meetingOutputPolicy: profile.meetingOutputPolicy.rawValue,
            effectiveLanguage: behavior.effectiveLanguage?.rawValue,
            effectiveBehavior: behavior.kind.rawValue
        ))
    }

    static func retranscriptionContext(
        hadExistingNotes: Bool,
        hadManualNotes: Bool
    ) -> String {
        encode(EncodedRetranscriptionContext(
            existingNotes: hadExistingNotes,
            manualNotes: hadManualNotes
        ))
    }

    private static func encode<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func boundedIdentifier(_ value: String) -> String {
        String(value.prefix(SessionTraceRetentionPolicy.default.maximumIdentifierBytes))
    }
}

extension DictationCleanupOutcome {
    var terminalTraceOutcome: SessionTraceTerminalOutcome {
        switch self {
        case .fallbackDeadline, .fallbackEmpty, .fallbackRejected, .fallbackError:
            return .fallbackSuccess
        case .applied, .skippedDisabled, .skippedUnavailable, .skippedStreaming:
            return .success
        }
    }
}
