import Foundation
import TelemetryDeck

@MainActor
final class DiagnosticIncidentReporter {
    typealias TelemetrySink = @MainActor (DiagnosticIncident) -> Void
    typealias PromptHandler = @MainActor (DiagnosticIncident) -> Void

    private let defaults: UserDefaults
    private let appState: AppState
    private let telemetrySink: TelemetrySink
    private let automaticPromptEnabled: @MainActor () -> Bool
    private let onPrompt: PromptHandler
    private let calendar: Calendar
    private static let incidentHistoryKey = "diagnosticIncidentHistory.v1"
    private static let maximumIncidentHistoryCount = 50

    init(
        appState: AppState,
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        telemetrySink: @escaping TelemetrySink = DiagnosticIncidentReporter.sendTelemetry,
        automaticPromptEnabled: @escaping @MainActor () -> Bool = { false },
        onPrompt: @escaping PromptHandler = { _ in }
    ) {
        self.appState = appState
        self.defaults = defaults
        self.calendar = calendar
        self.telemetrySink = telemetrySink
        self.automaticPromptEnabled = automaticPromptEnabled
        self.onPrompt = onPrompt
    }

    @discardableResult
    func record(
        kind: DiagnosticIncidentKind,
        severity: DiagnosticIncidentSeverity = .error,
        stage: DiagnosticIncidentStage,
        backend: BackendOption? = nil,
        error: Error? = nil,
        promptUser: Bool = true
    ) -> DiagnosticIncident {
        let incident = DiagnosticIncident(
            kind: kind,
            severity: severity,
            stage: stage,
            backendOption: backend,
            error: error
        )
        persist(incident)
        telemetrySink(incident)
        if promptUser, automaticPromptEnabled(), shouldPrompt(for: incident) {
            markPrompted(for: incident)
            onPrompt(incident)
            appState.pendingDiagnosticIncident = incident
        }
        return incident
    }

    func recordManualReport() {
        let incident = DiagnosticIncident(
            kind: .manualReport,
            severity: .info,
            stage: .manualReport,
            backendOption: nil,
            error: nil
        )
        persist(incident)
        appState.pendingDiagnosticIncident = incident
    }

    /// Returns the bounded, privacy-safe incident envelopes retained locally.
    /// DiagnosticIncident encoding excludes arbitrary error descriptions.
    func recentIncidents() -> [DiagnosticIncident] {
        guard let data = defaults.data(forKey: Self.incidentHistoryKey),
              let incidents = try? JSONDecoder().decode([DiagnosticIncident].self, from: data)
        else { return [] }
        return incidents
    }

    func dismissCurrentPrompt() {
        appState.pendingDiagnosticIncident = nil
    }

    private func shouldPrompt(for incident: DiagnosticIncident) -> Bool {
        let key = promptThrottleKey(for: incident)
        return defaults.string(forKey: key) != dayBucket(for: incident.occurredAt)
    }

    private func markPrompted(for incident: DiagnosticIncident) {
        defaults.set(dayBucket(for: incident.occurredAt), forKey: promptThrottleKey(for: incident))
    }

    private func promptThrottleKey(for incident: DiagnosticIncident) -> String {
        "diagnosticIncidentPrompt.\(incident.kind.rawValue).\(incident.metadata.appVersion).\(incident.metadata.buildNumber)"
    }

    private func dayBucket(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private func persist(_ incident: DiagnosticIncident) {
        let incidents = Array((recentIncidents() + [incident]).suffix(Self.maximumIncidentHistoryCount))
        guard let data = try? JSONEncoder().encode(incidents) else { return }
        defaults.set(data, forKey: Self.incidentHistoryKey)
    }

    private static func sendTelemetry(_ incident: DiagnosticIncident) {
        let category: ErrorCategory = incident.telemetryCategory == .appState ? .appState : .thrownException
        TelemetryDeck.errorOccurred(
            id: incident.telemetryErrorID,
            category: category,
            message: nil,
            parameters: incident.telemetryParameters
        )
    }
}
