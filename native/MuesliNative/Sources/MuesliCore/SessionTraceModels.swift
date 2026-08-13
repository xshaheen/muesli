import Foundation

public struct SessionTraceRetentionPolicy: Equatable, Sendable {
    public static let `default` = SessionTraceRetentionPolicy(
        richContentRetention: 7 * 24 * 60 * 60,
        metadataRetention: 90 * 24 * 60 * 60,
        maximumArtifactBytes: 1 * 1_024 * 1_024,
        maximumSessionRichBytes: 4 * 1_024 * 1_024,
        maximumNonterminalEvents: 511,
        maximumEvents: 512,
        maximumGlobalRichBytes: 128 * 1_024 * 1_024,
        maximumSessions: 1_000,
        maximumExportBytes: 32 * 1_024 * 1_024,
        maximumEventMetadataBytes: 16 * 1_024,
        maximumIdentifierBytes: 256
    )

    public let richContentRetention: TimeInterval
    public let metadataRetention: TimeInterval
    public let maximumArtifactBytes: Int
    public let maximumSessionRichBytes: Int
    public let maximumNonterminalEvents: Int
    public let maximumEvents: Int
    public let maximumGlobalRichBytes: Int
    public let maximumSessions: Int
    public let maximumExportBytes: Int
    public let maximumEventMetadataBytes: Int
    public let maximumIdentifierBytes: Int

    public init(
        richContentRetention: TimeInterval,
        metadataRetention: TimeInterval,
        maximumArtifactBytes: Int,
        maximumSessionRichBytes: Int,
        maximumNonterminalEvents: Int,
        maximumEvents: Int,
        maximumGlobalRichBytes: Int,
        maximumSessions: Int,
        maximumExportBytes: Int,
        maximumEventMetadataBytes: Int,
        maximumIdentifierBytes: Int
    ) {
        self.richContentRetention = richContentRetention
        self.metadataRetention = metadataRetention
        self.maximumArtifactBytes = maximumArtifactBytes
        self.maximumSessionRichBytes = maximumSessionRichBytes
        self.maximumNonterminalEvents = maximumNonterminalEvents
        self.maximumEvents = maximumEvents
        self.maximumGlobalRichBytes = maximumGlobalRichBytes
        self.maximumSessions = maximumSessions
        self.maximumExportBytes = maximumExportBytes
        self.maximumEventMetadataBytes = maximumEventMetadataBytes
        self.maximumIdentifierBytes = maximumIdentifierBytes
    }
}

public enum SessionTraceKind: String, Codable, CaseIterable, Sendable {
    case dictation
    case meeting
}

public enum SessionTraceTerminalOutcome: String, Codable, CaseIterable, Sendable {
    case success
    case fallbackSuccess = "fallback_success"
    case cancelled
    case timedOut = "timed_out"
    case failed
}

public enum SessionTraceArtifactKind: String, Codable, CaseIterable, Sendable {
    case rawASR = "raw_asr"
    case cleanupResult = "cleanup_result"
    case dictionaryChanges = "dictionary_changes"
    case finalOutput = "final_output"
    case languageProfile = "language_profile"
    case contextSources = "context_sources"
}

public enum SessionTraceContentState: String, Codable, Sendable {
    case available
    case pruned
    case empty
    case activeWriter = "active_writer"
    case unavailable
    case clearedWhileActive = "cleared_while_active"
}

public enum SessionTraceEventVocabulary: String, Codable, Sendable {
    case sessionStarted = "session_started"
    case stageStarted = "stage_started"
    case stageCompleted = "stage_completed"
    case stageFailed = "stage_failed"
    case fallbackStarted = "fallback_started"
    case cancellationRequested = "cancellation_requested"
    case timeoutRequested = "timeout_requested"
    case terminal
}

public enum SessionTraceLimit: String, Codable, Sendable {
    case artifactBytes = "artifact_bytes"
    case sessionRichBytes = "session_rich_bytes"
    case eventCount = "event_count"
    case globalRichBytes = "global_rich_bytes"
    case sessionCount = "session_count"
    case eventMetadataBytes = "event_metadata_bytes"
    case identifierBytes = "identifier_bytes"
}

public struct SessionTraceWriterToken: Equatable, Hashable, Sendable {
    public let sessionID: UUID
    public let writerID: UUID
    public let clearGeneration: Int64

    public init(sessionID: UUID, writerID: UUID, clearGeneration: Int64) {
        self.sessionID = sessionID
        self.writerID = writerID
        self.clearGeneration = clearGeneration
    }
}

public enum SessionTraceMutationResult: Equatable, Sendable {
    case appended
    case deduplicated
    case terminalAlreadyDecided(SessionTraceTerminalOutcome)
    case clearedByGeneration
    case writerMismatch
    case limitReached(SessionTraceLimit)
}

public enum SessionTraceTerminalClaimResult: Equatable, Sendable {
    case won
    case alreadyDecided(SessionTraceTerminalOutcome)
}

public struct SessionTraceArtifactWriteResult: Equatable, Sendable {
    public let mutation: SessionTraceMutationResult
    public let artifactID: Int64?

    public init(mutation: SessionTraceMutationResult, artifactID: Int64?) {
        self.mutation = mutation
        self.artifactID = artifactID
    }
}

public struct SessionTraceEvent: Equatable, Sendable {
    public let sequence: Int
    public let vocabulary: SessionTraceEventVocabulary
    public let stage: String
    public let elapsedMilliseconds: Int64?
    public let metadata: [String: String]
    public let artifactID: Int64?
    public let createdAt: Date
}

public struct SessionTraceArtifact: Equatable, Sendable {
    public let id: Int64
    public let kinds: [SessionTraceArtifactKind]
    public let content: String?
    public let byteCount: Int
    public let state: SessionTraceContentState
}

public struct SessionTraceSummary: Equatable, Sendable {
    public let sessionID: UUID
    public let kind: SessionTraceKind
    public let createdAt: Date
    public let updatedAt: Date
    public let terminalOutcome: SessionTraceTerminalOutcome?
    public let dictationID: Int64?
    public let meetingID: Int64?
    public let backendIdentity: String?
    public let fallbackBackendIdentity: String?
    public let contentState: SessionTraceContentState
    public let eventCount: Int
    public let richByteCount: Int
}

public struct SessionTraceDetail: Equatable, Sendable {
    public let summary: SessionTraceSummary
    public let events: [SessionTraceEvent]
    public let artifacts: [SessionTraceArtifact]
}

public struct SessionTracePruneResult: Equatable, Sendable {
    public let richSessionsPruned: Int
    public let metadataSessionsDeleted: Int
}
