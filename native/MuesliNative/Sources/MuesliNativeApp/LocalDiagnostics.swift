import Foundation
import MuesliCore

enum LocalDiagnosticsError: Error, LocalizedError, Equatable {
    case unavailable
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Local diagnostics are unavailable."
        case .exportFailed:
            return "Diagnostics could not be exported."
        }
    }
}

struct LocalDiagnosticsMeetingSummary: Codable {
    let id: String
    let modifiedAt: Date
    let summary: MeetingSessionDiagnostics.Summary

    init(_ stored: MeetingSessionDiagnostics.StoredSummary) {
        id = stored.id
        modifiedAt = stored.modifiedAt
        summary = stored.summary
    }
}

struct LocalDiagnosticsExportEnvelope: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let exportedAt: Date
    let storageScope: String
    let contentPolicy: String
    let sessionTraces: SessionTraceDiagnosticsExport
    let meetingSummaries: [LocalDiagnosticsMeetingSummary]
    let incidents: [DiagnosticIncident]
}

enum LocalDiagnosticsCleanupTarget: String, Codable, Equatable, Sendable {
    case sessionTraces = "session_traces"
    case recordingAssociations = "recording_associations"
    case meetingSummaries = "meeting_summaries"
    case incidentHistory = "incident_history"

    var displayName: String {
        switch self {
        case .sessionTraces: return "session traces"
        case .recordingAssociations: return "recording associations"
        case .meetingSummaries: return "meeting summaries"
        case .incidentHistory: return "incident history"
        }
    }
}

struct LocalDiagnosticsClearResult: Equatable, Sendable {
    let traces: SessionTraceClearResult?
    let meetingDiagnostics: MeetingSessionDiagnostics.ClearResult?
    let failedTargets: [LocalDiagnosticsCleanupTarget]

    var isComplete: Bool { failedTargets.isEmpty }
    var activeRunsPreserved: Int {
        (traces?.activeSessionsPreserved ?? 0)
            + (meetingDiagnostics?.activeRunsPreserved ?? 0)
    }
}

enum LocalDiagnosticsListState: Equatable, Sendable {
    case available([SessionTraceSummary])
    case unavailable

    var summaries: [SessionTraceSummary]? {
        guard case .available(let summaries) = self else { return nil }
        return summaries
    }
}

enum LocalDiagnosticsDetailState: Equatable, Sendable {
    case available(SessionTraceDetail)
    case missing
    case unavailable
}

/// The local-only boundary used by diagnostics UI. The trace store owns the
/// bounded snapshot and writer-generation transactions; this service first
/// drains writes already accepted by the runtime so clear/export has an explicit
/// ordering point without blocking transcription work on UI I/O.
actor LocalDiagnosticsService {
    static let maximumListCount = SessionTraceRetentionPolicy.default.maximumSessions
    static let maximumAuxiliaryExportBytes = MeetingSessionDiagnostics.maximumStoredTotalBytes
        + 256 * 1_024
    static let maximumExportBytes = SessionTraceRetentionPolicy.default.maximumExportBytes
        + maximumAuxiliaryExportBytes

    private let store: SessionTraceStore?
    private let diagnosticsRootURL: URL
    private let flushActiveWriters: @Sendable () async -> Void
    private let loadMeetingSummaries: @Sendable (URL, Date) -> [LocalDiagnosticsMeetingSummary]
    private let clearMeetingSummaries: @Sendable (URL) throws -> MeetingSessionDiagnostics.ClearResult
    private let clearRecordingAssociations: @Sendable () throws -> Void
    private let loadIncidentHistory: @MainActor @Sendable () -> [DiagnosticIncident]
    private let clearIncidentHistory: @MainActor @Sendable () throws -> Void

    init(
        store: SessionTraceStore?,
        diagnosticsRootURL: URL = AppIdentity.supportDirectoryURL,
        flushActiveWriters: @escaping @Sendable () async -> Void = {},
        loadMeetingSummaries: @escaping @Sendable (URL, Date) -> [LocalDiagnosticsMeetingSummary] = {
            rootURL, now in
            MeetingSessionDiagnostics.loadStoredSummaries(rootURL: rootURL, now: now)
                .map(LocalDiagnosticsMeetingSummary.init)
        },
        clearMeetingSummaries: @escaping @Sendable (URL) throws -> MeetingSessionDiagnostics.ClearResult = {
            try MeetingSessionDiagnostics.clearStoredRuns(rootURL: $0)
        },
        clearRecordingAssociations: @escaping @Sendable () throws -> Void = {},
        loadIncidentHistory: @escaping @MainActor @Sendable () -> [DiagnosticIncident] = { [] },
        clearIncidentHistory: @escaping @MainActor @Sendable () throws -> Void = {}
    ) {
        self.store = store
        self.diagnosticsRootURL = diagnosticsRootURL
        self.flushActiveWriters = flushActiveWriters
        self.loadMeetingSummaries = loadMeetingSummaries
        self.clearMeetingSummaries = clearMeetingSummaries
        self.clearRecordingAssociations = clearRecordingAssociations
        self.loadIncidentHistory = loadIncidentHistory
        self.clearIncidentHistory = clearIncidentHistory
    }

    func list(limit: Int = maximumListCount) async -> LocalDiagnosticsListState {
        guard let store else { return .unavailable }
        do {
            return .available(try await store.list(limit: min(max(limit, 0), Self.maximumListCount)))
        } catch {
            return .unavailable
        }
    }

    func detail(sessionID: UUID) async -> LocalDiagnosticsDetailState {
        guard let store else { return .unavailable }
        do {
            guard let detail = try await store.detail(sessionID: sessionID) else {
                return .missing
            }
            return .available(detail)
        } catch {
            return .unavailable
        }
    }

    @discardableResult
    func export(to destination: URL, now: Date = Date()) async throws -> Int {
        await flushActiveWriters()
        guard let store else { throw LocalDiagnosticsError.unavailable }
        do {
            let traces = try await store.diagnosticsExport(now: now)
            let payload = LocalDiagnosticsExportEnvelope(
                schemaVersion: LocalDiagnosticsExportEnvelope.currentSchemaVersion,
                exportedAt: now,
                storageScope: "local-only",
                contentPolicy: "rich-content-short-retention; auxiliary-metadata-content-free",
                sessionTraces: traces,
                meetingSummaries: loadMeetingSummaries(diagnosticsRootURL, now),
                incidents: await loadIncidentHistory()
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(payload)
            guard data.count <= Self.maximumExportBytes else {
                throw LocalDiagnosticsError.exportFailed
            }
            try data.write(to: destination, options: .atomic)
            return data.count
        } catch let error as LocalDiagnosticsError {
            throw error
        } catch {
            throw LocalDiagnosticsError.exportFailed
        }
    }

    @discardableResult
    func clear(at date: Date = Date()) async -> LocalDiagnosticsClearResult {
        await flushActiveWriters()
        var traces: SessionTraceClearResult?
        var meetingDiagnostics: MeetingSessionDiagnostics.ClearResult?
        var failedTargets: [LocalDiagnosticsCleanupTarget] = []
        if let store {
            do {
                traces = try await store.clearDiagnostics(at: date)
            } catch {
                failedTargets.append(.sessionTraces)
            }
        } else {
            failedTargets.append(.sessionTraces)
        }
        do {
            try clearRecordingAssociations()
        } catch {
            failedTargets.append(.recordingAssociations)
        }

        // Auxiliary stores contain metadata only and are intentionally cleaned
        // independently of the trace database. A retry can finish partial
        // cleanup without restoring diagnostics that were already deleted.
        do {
            meetingDiagnostics = try clearMeetingSummaries(diagnosticsRootURL)
        } catch {
            failedTargets.append(.meetingSummaries)
        }
        do {
            try await clearIncidentHistory()
        } catch {
            failedTargets.append(.incidentHistory)
        }
        return LocalDiagnosticsClearResult(
            traces: traces,
            meetingDiagnostics: meetingDiagnostics,
            failedTargets: failedTargets
        )
    }
}
