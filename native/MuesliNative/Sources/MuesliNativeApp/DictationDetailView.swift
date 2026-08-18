import MuesliCore
import SwiftUI

struct DictationDetailView: View {
    let record: DictationRecord
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    var recordingCoordinator: RecordingArtifactPlaybackCoordinator = .shared

    @State private var isConfirmingHistoryDeletion = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Dictation")
                        .font(MuesliTheme.title2())
                    Text(MeetingBrowserLogic.formatStartTime(record.timestamp))
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                Spacer()
                Button("Copy", action: onCopy)
                Button("Delete Dictation", role: .destructive) {
                    isConfirmingHistoryDeletion = true
                }
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(MuesliTheme.spacing20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        Text("Transcript")
                            .font(MuesliTheme.headline())
                        Text(record.rawText.isEmpty ? "No transcript was produced." : record.rawText)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(record.rawText.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()

                    RecordingArtifactSection(
                        owner: .dictation(record.id),
                        coordinator: recordingCoordinator
                    )
                }
                .padding(MuesliTheme.spacing24)
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 420, idealHeight: 560)
        .background(MuesliTheme.backgroundBase)
        .alert("Delete Dictation?", isPresented: $isConfirmingHistoryDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Dictation", role: .destructive) {
                onDelete()
                onClose()
            }
        } message: {
            Text("This removes the dictation history entry. Its retained recording is removed only when this is its last owning history entry.")
        }
    }
}

struct AudioOnlyDictationDetailView: View {
    let record: DictationAudioHistoryRecord
    let onDelete: () -> Void
    let onClose: () -> Void
    var recordingCoordinator: RecordingArtifactPlaybackCoordinator = .shared

    @State private var isConfirmingHistoryDeletion = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(record.terminalOutcome.detailTitle)
                        .font(MuesliTheme.title2())
                    Text(record.capturedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                Spacer()
                Button("Delete History Entry", role: .destructive) {
                    isConfirmingHistoryDeletion = true
                }
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(MuesliTheme.spacing20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        Text("Capture Result")
                            .font(MuesliTheme.headline())
                        Text(record.terminalOutcome.detailDescription)
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textSecondary)
                        Text(record.durationSeconds.formattedDuration)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }

                    Divider()

                    RecordingArtifactSection(
                        owner: .session(record.sessionID),
                        coordinator: recordingCoordinator
                    )
                }
                .padding(MuesliTheme.spacing24)
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 360, idealHeight: 480)
        .background(MuesliTheme.backgroundBase)
        .alert("Delete Recording History?", isPresented: $isConfirmingHistoryDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete History Entry", role: .destructive) {
                onDelete()
                onClose()
            }
        } message: {
            Text("This removes the local recording history entry and its recording when no other history entry owns it. Diagnostic text and metadata are preserved.")
        }
    }
}

extension DictationAudioTerminalOutcome {
    var detailTitle: String {
        switch self {
        case .cancelled: "Cancelled Dictation"
        case .timedOut: "Timed-Out Dictation"
        case .failed: "Failed Dictation"
        case .empty: "Empty Dictation"
        }
    }

    var detailDescription: String {
        switch self {
        case .cancelled: "The dictation was cancelled before text history was created."
        case .timedOut: "The dictation timed out before text history was created."
        case .failed: "The dictation failed before text history was created."
        case .empty: "The dictation ended without producing transcript text."
        }
    }
}

private extension Double {
    var formattedDuration: String {
        let totalSeconds = max(Int(rounded()), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "Duration \(minutes):\(String(format: "%02d", seconds))"
    }
}
