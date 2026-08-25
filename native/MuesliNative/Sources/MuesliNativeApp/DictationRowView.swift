import SwiftUI
import MuesliCore

struct DictationStyleHistoryBadgeContent: Equatable {
    let label: String
    let accessibilityDescription: String

    static func make(for record: DictationRecord) -> Self? {
        guard let styleName = nonEmpty(record.dictationStyleName),
              let source = sourceLabel(record.dictationStyleSelectionSource),
              let outcome = outcomeLabel(record.dictationCleanupOutcome)
        else {
            return nil
        }
        return Self(
            label: styleName,
            accessibilityDescription: "Dictation style \(styleName). \(source). \(outcome)."
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sourceLabel(_ rawValue: String?) -> String? {
        guard let rawValue, let source = DictationStyleSelectionSource(rawValue: rawValue) else { return nil }
        return switch source {
        case .exception: "Selected by an exact exception"
        case .group: "Selected by a writing style group"
        case .domain:
            "Selected by website rule"
        case .app:
            "Selected by app rule"
        case .category:
            "Selected by category"
        case .global:
            "Selected from the global style"
        case .builtInFallback:
            "Selected as the built-in fallback"
        }
    }

    private static func outcomeLabel(_ rawValue: String?) -> String? {
        guard let rawValue, let outcome = DictationCleanupOutcome(rawValue: rawValue) else { return nil }
        return switch outcome {
        case .applied: "Cleanup applied"
        case .fallbackDeadline: "Original dictation kept because cleanup timed out"
        case .fallbackEmpty: "Original dictation kept because cleanup returned no text"
        case .fallbackRejected: "Original dictation kept because cleanup was rejected"
        case .fallbackError: "Original dictation kept because cleanup failed"
        case .skippedDisabled: "Cleanup skipped because it was disabled"
        case .skippedUnavailable: "Cleanup skipped because it was unavailable"
        case .skippedStreaming: "Cleanup skipped for streaming dictation"
        }
    }
}

struct DictationRowView: View {
    let record: DictationRecord
    let timeOnly: String
    let onCopy: () -> Void
    var onOpen: (() -> Void)? = nil
    var onCopyTrace: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var showDeleteConfirmation = false
    @State private var isExpanded = false

    private var isComputerUseCommand: Bool {
        record.source == "cua"
    }

    private var syncOriginBadgeLabel: String? {
        SyncOriginDisplay.badgeLabel(forDictationSource: record.source)
    }

    private var styleBadge: DictationStyleHistoryBadgeContent? {
        DictationStyleHistoryBadgeContent.make(for: record)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing20) {
                Text(timeOnly)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 80, alignment: .leading)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing8) {
                        if isComputerUseCommand {
                            Text("CUA")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(MuesliTheme.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(MuesliTheme.accentSubtle)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }

                        if let syncOriginBadgeLabel {
                            SyncOriginBadge(label: syncOriginBadgeLabel)
                        }

                        if let styleBadge {
                            Text(styleBadge.label)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(MuesliTheme.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(MuesliTheme.accentSubtle)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .help(styleBadge.accessibilityDescription)
                                .accessibilityLabel(styleBadge.accessibilityDescription)
                        }

                        Text(record.rawText)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(MuesliTheme.textPrimary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let trace = record.computerUseTrace {
                            Text(Self.displayFinalStatus(trace.finalStatus))
                                .font(MuesliTheme.captionMedium())
                                .foregroundStyle(statusColor(trace.finalStatus))
                        }
                    }

                    if isExpanded, let trace = record.computerUseTrace {
                        computerUseTraceView(trace)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    if record.computerUseTrace != nil {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(MuesliTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }

                    if record.computerUseTrace != nil, let onCopyTrace {
                        Button(action: onCopyTrace) {
                            Image(systemName: "list.bullet.clipboard")
                                .font(.system(size: 12))
                                .foregroundStyle(MuesliTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy CUA trace")
                    }

                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    .buttonStyle(.plain)

                    if onDelete != nil {
                        Button { showDeleteConfirmation = true } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(MuesliTheme.danger.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .opacity(isHovered || isExpanded || record.computerUseTrace != nil ? 1 : 0)
            }
        }
        .padding(.horizontal, MuesliTheme.spacing20)
        .padding(.vertical, MuesliTheme.spacing16)
        .background(isHovered ? MuesliTheme.backgroundHover : MuesliTheme.backgroundRaised)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            if let onOpen {
                onOpen()
            } else if record.computerUseTrace != nil {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } else {
                onCopy()
            }
        }
        .alert("Delete Dictation", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this dictation? This cannot be undone.")
        }
    }

    @ViewBuilder
    private func computerUseTraceView(_ trace: ComputerUseTraceRecord) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Divider()
                .opacity(0.5)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                ForEach(trace.events) { event in
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        HStack(spacing: MuesliTheme.spacing8) {
                            Text(event.step.map { "Step \($0)" } ?? "Run")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(MuesliTheme.textTertiary)
                                .frame(width: 48, alignment: .leading)

                            Text(event.title)
                                .font(MuesliTheme.captionMedium())
                                .foregroundStyle(MuesliTheme.textSecondary)

                            if let status = ComputerUseTraceFormatter.displayStatus(for: event) {
                                Text(status)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(statusColor(status))
                            }
                        }

                        Text(event.body)
                            .font(.system(size: 12, weight: .regular, design: event.kind == "model_output" ? .monospaced : .default))
                            .foregroundStyle(MuesliTheme.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 56)
                    }
                }
            }
        }
        .padding(.top, MuesliTheme.spacing4)
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "done", "executed":
            return MuesliTheme.success
        case "confirm", "needsconfirmation":
            return MuesliTheme.transcribing
        case "timed_out", "timedout":
            return MuesliTheme.transcribing
        case "failed", "unsupported":
            return MuesliTheme.danger
        default:
            return MuesliTheme.textTertiary
        }
    }

    private static func displayFinalStatus(_ status: String) -> String {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "done":
            return "Done"
        case "timed_out", "timedout":
            return "Timed out"
        case "failed", "fail":
            return "Failed"
        case "confirm", "needsconfirmation", "needs_confirmation":
            return "Confirm"
        case "cancelled", "canceled":
            return "Cancelled"
        default:
            return status.capitalized
        }
    }
}

struct AudioOnlyDictationRowView: View {
    let record: DictationAudioHistoryRecord
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var isConfirmingDeletion = false

    var body: some View {
        HStack(alignment: .center, spacing: MuesliTheme.spacing20) {
            Text(record.capturedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(MuesliTheme.textTertiary)
                .frame(width: 80, alignment: .leading)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text(record.terminalOutcome.detailTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Recording-only local history · \(RecordingArtifactAvailability(record.availability).displaySummary)")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }

            Spacer()

            RecordingArtifactAvailabilityBadge(owner: .session(record.sessionID))

            Button {
                isConfirmingDeletion = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(MuesliTheme.danger.opacity(0.6))
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .help("Delete recording history")
        }
        .padding(.horizontal, MuesliTheme.spacing20)
        .padding(.vertical, MuesliTheme.spacing16)
        .background(isHovered ? MuesliTheme.backgroundHover : MuesliTheme.backgroundRaised)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
        .alert("Delete Recording History", isPresented: $isConfirmingDeletion) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local history entry and its retained recording when it is the last owner.")
        }
    }
}

private extension RecordingArtifactAvailability {
    var displaySummary: String {
        switch self {
        case .available: "available"
        case .pendingDecision: "waiting for save decision"
        case .notRetained: "not retained"
        case .declined: "discarded"
        case .deleting: "deleting"
        case .missing: "missing"
        case .expired: "expired"
        case .deleted: "deleted"
        case .invalidLegacy: "invalid legacy file"
        case .saveFailed: "save failed"
        }
    }
}
