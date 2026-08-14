import AppKit
import MuesliCore
import SwiftUI
import UniformTypeIdentifiers

enum SessionDiagnosticsPresentation {
    static func associationLabel(for summary: SessionTraceSummary) -> String {
        if let dictationID = summary.dictationID { return "Dictation #\(dictationID)" }
        if let meetingID = summary.meetingID { return "Meeting #\(meetingID)" }
        return "Unattached session"
    }

    static func outcomeLabel(for summary: SessionTraceSummary) -> String {
        guard let outcome = summary.terminalOutcome else { return "In progress" }
        switch outcome {
        case .success: return "Success"
        case .fallbackSuccess: return "Fallback success"
        case .cancelled: return "Cancelled"
        case .timedOut: return "Timed out"
        case .failed: return "Failed"
        }
    }

    static func contentStateLabel(_ state: SessionTraceContentState) -> String {
        switch state {
        case .available: return "Available"
        case .pruned: return "Pruned"
        case .empty: return "Empty"
        case .activeWriter: return "Active writer"
        case .unavailable: return "Unavailable"
        case .clearedWhileActive: return "Cleared while active"
        }
    }

    static func contentStateDescription(_ state: SessionTraceContentState) -> String {
        switch state {
        case .available:
            return "Short-retention session content is available on this Mac."
        case .pruned:
            return "Rich content expired or was removed; content-free session metadata remains."
        case .empty:
            return "The session recorded no rich diagnostic content."
        case .activeWriter:
            return "This session is still writing diagnostics. Refresh to see later evidence."
        case .unavailable:
            return "The diagnostic content could not be read."
        case .clearedWhileActive:
            return "Diagnostics were cleared while this session was active; later writes from that writer are rejected."
        }
    }

    static func artifactLabel(_ kinds: [SessionTraceArtifactKind]) -> String {
        kinds.map { kind in
            switch kind {
            case .rawASR: return "Raw ASR"
            case .cleanupResult: return "Cleanup result"
            case .dictionaryChanges: return "Dictionary changes"
            case .finalOutput: return "Final output"
            case .languageProfile: return "Language profile"
            case .contextSources: return "Context sources"
            }
        }.joined(separator: ", ")
    }
}

struct SessionDiagnosticsView: View {
    private enum LoadState {
        case loading
        case available([SessionTraceSummary])
        case unavailable
    }

    private enum DetailState {
        case none
        case loading
        case available(SessionTraceDetail)
        case missing
        case unavailable
    }

    let service: LocalDiagnosticsService
    let onClose: () -> Void

    @State private var loadState: LoadState = .loading
    @State private var detailState: DetailState = .none
    @State private var selectedSessionID: UUID?
    @State private var isConfirmingClear = false
    @State private var isOperating = false
    @State private var reloadGeneration = 0
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            NavigationSplitView {
                sessionList
                    .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 420)
            } detail: {
                detailPane
            }
        }
        .frame(minWidth: 880, idealWidth: 980, minHeight: 560, idealHeight: 660)
        .background(MuesliTheme.backgroundBase)
        .task { await reload() }
        .onChange(of: selectedSessionID) { _, sessionID in
            Task { await loadDetail(sessionID: sessionID) }
        }
        .alert("Clear diagnostics?", isPresented: $isConfirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Diagnostics", role: .destructive) {
                Task { await clearDiagnostics() }
            }
        } message: {
            Text("This removes local diagnostic artifacts only. Normal dictation and meeting history, and intentionally retained recordings, are not deleted. Active writers are safely reset.")
        }
        .alert(
            "Diagnostics",
            isPresented: Binding(
                get: { statusMessage != nil },
                set: { if !$0 { statusMessage = nil } }
            )
        ) {
            Button("OK") { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text("Session Diagnostics")
                    .font(MuesliTheme.title2())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Local-only, short-retention evidence for dictation and meeting sessions.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            Spacer()
            Button("Refresh") { Task { await reload() } }
                .disabled(isOperating)
            Button("Export…") { presentExportPanel() }
                .disabled(isOperating || isUnavailable)
            Button("Clear…", role: .destructive) { isConfirmingClear = true }
                .disabled(isOperating)
            Button("Done", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(MuesliTheme.spacing16)
    }

    @ViewBuilder
    private var sessionList: some View {
        switch loadState {
        case .loading:
            ProgressView("Loading diagnostics…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView(
                "Diagnostics Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("The local trace store could not be opened or read.")
            )
        case .available(let summaries) where summaries.isEmpty:
            ContentUnavailableView(
                "No Session Diagnostics",
                systemImage: "waveform.badge.magnifyingglass",
                description: Text("New dictation and meeting sessions will appear here even when no history row is created.")
            )
        case .available(let summaries):
            List(summaries, id: \.sessionID, selection: $selectedSessionID) { summary in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(summary.kind == .dictation ? "Dictation" : "Meeting")
                            .font(.headline)
                        Spacer()
                        Text(SessionDiagnosticsPresentation.outcomeLabel(for: summary))
                            .font(.caption)
                    }
                    Text(SessionDiagnosticsPresentation.associationLabel(for: summary))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(SessionDiagnosticsPresentation.contentStateLabel(summary.contentState))
                        Spacer()
                        Text(summary.createdAt, style: .relative)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .tag(summary.sessionID)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch detailState {
        case .none:
            ContentUnavailableView("Select a Session", systemImage: "list.bullet.rectangle")
        case .loading:
            ProgressView("Loading session…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            ContentUnavailableView(
                "Session No Longer Available",
                systemImage: "clock.arrow.circlepath",
                description: Text("It may have expired or been cleared. Refresh the list.")
            )
        case .unavailable:
            ContentUnavailableView(
                "Details Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("This local session trace could not be read.")
            )
        case .available(let detail):
            traceDetail(detail)
        }
    }

    private func traceDetail(_ detail: SessionTraceDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(SessionDiagnosticsPresentation.associationLabel(for: detail.summary))
                        .font(MuesliTheme.title2())
                    Text(detail.summary.sessionID.uuidString)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text(SessionDiagnosticsPresentation.contentStateDescription(detail.summary.contentState))
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }

                metadata(detail.summary)

                diagnosticsGroup("Stage Evidence") {
                    if detail.events.isEmpty {
                        Text("No events remain for this session.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(detail.events, id: \.sequence) { event in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("#\(event.sequence) \(event.vocabulary.rawValue)")
                                        .font(.system(.body, design: .monospaced))
                                    Spacer()
                                    if let elapsed = event.elapsedMilliseconds {
                                        Text("\(elapsed) ms")
                                            .font(.caption)
                                    }
                                }
                                Text(event.stage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !event.metadata.isEmpty {
                                    Text(event.metadata.sorted { $0.key < $1.key }
                                        .map { "\($0.key)=\($0.value)" }
                                        .joined(separator: "  "))
                                        .font(.system(.caption2, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                            if event.sequence != detail.events.last?.sequence { Divider() }
                        }
                    }
                }

                diagnosticsGroup("Local Content") {
                    if detail.artifacts.isEmpty {
                        Text("No rich diagnostic content remains.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(detail.artifacts, id: \.id) { artifact in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(SessionDiagnosticsPresentation.artifactLabel(artifact.kinds))
                                        .font(.headline)
                                    Spacer()
                                    Text("\(artifact.byteCount) bytes · \(SessionDiagnosticsPresentation.contentStateLabel(artifact.state))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let content = artifact.content {
                                    Text(content)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    Text(SessionDiagnosticsPresentation.contentStateDescription(artifact.state))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if artifact.id != detail.artifacts.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(MuesliTheme.spacing24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metadata(_ summary: SessionTraceSummary) -> some View {
        diagnosticsGroup("Session") {
            diagnosticValue("Outcome", SessionDiagnosticsPresentation.outcomeLabel(for: summary))
            diagnosticValue("Content", SessionDiagnosticsPresentation.contentStateLabel(summary.contentState))
            diagnosticValue("Backend", summary.backendIdentity ?? "Not recorded")
            diagnosticValue("Fallback", summary.fallbackBackendIdentity ?? "None")
            diagnosticValue("Events", String(summary.eventCount))
            diagnosticValue("Rich content", "\(summary.richByteCount) bytes")
        }
    }

    private func diagnosticsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(MuesliTheme.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
    }

    private func diagnosticValue(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).textSelection(.enabled)
        }
        .font(.caption)
    }

    private var isUnavailable: Bool {
        if case .unavailable = loadState { return true }
        return false
    }

    @MainActor
    private func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        loadState = .loading
        let result = await service.list()
        guard generation == reloadGeneration else { return }
        switch result {
        case .available(let summaries):
            loadState = .available(summaries)
            if let selectedSessionID,
               !summaries.contains(where: { $0.sessionID == selectedSessionID }) {
                self.selectedSessionID = nil
                detailState = .none
            }
        case .unavailable:
            loadState = .unavailable
            selectedSessionID = nil
            detailState = .unavailable
        }
    }

    @MainActor
    private func loadDetail(sessionID: UUID?) async {
        guard let sessionID else {
            detailState = .none
            return
        }
        detailState = .loading
        let result = await service.detail(sessionID: sessionID)
        guard selectedSessionID == sessionID else { return }
        switch result {
        case .available(let detail): detailState = .available(detail)
        case .missing: detailState = .missing
        case .unavailable: detailState = .unavailable
        }
    }

    @MainActor
    private func clearDiagnostics() async {
        isOperating = true
        defer { isOperating = false }
        let result = await service.clear()
        if result.isComplete {
            let activeSessions = result.activeRunsPreserved
            statusMessage = activeSessions > 0
                ? "Diagnostics cleared. \(activeSessions) active session(s) were safely reset. History and retained recordings were not changed."
                : "Diagnostics cleared. History and retained recordings were not changed."
        } else {
            let targets = result.failedTargets.map(\.displayName).joined(separator: ", ")
            statusMessage = "Cleanup of \(targets) did not finish. Retry Clear Diagnostics to complete it. History and retained recordings were not changed."
        }
        selectedSessionID = nil
        detailState = .none
        await reload()
    }

    @MainActor
    private func presentExportPanel() {
        let panel = NSSavePanel()
        panel.title = "Export Session Diagnostics"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "muesli-session-diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        NSApp.activate()

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in await exportDiagnostics(to: destination) }
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            statusMessage = "Diagnostics export needs an active app window."
            return
        }
        panel.beginSheetModal(for: window, completionHandler: completion)
    }

    @MainActor
    private func exportDiagnostics(to destination: URL) async {
        isOperating = true
        defer { isOperating = false }
        do {
            let byteCount = try await service.export(to: destination)
            statusMessage = "Exported \(byteCount) bytes of local diagnostics."
        } catch let error as LocalDiagnosticsError {
            statusMessage = error.localizedDescription
        } catch {
            statusMessage = LocalDiagnosticsError.exportFailed.localizedDescription
        }
    }
}
