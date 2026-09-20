import SwiftUI
import ImlaCore

private enum MeetingDocumentMode: Hashable {
    case notes
    case transcript
    case chat
}

private enum RecordingContentMode: Hashable {
    case notes
    case live
    case chat
}

private enum ManualNotesSaveStatus {
    case saved
    case saving

    var label: String {
        switch self {
        case .saved: return "Saved"
        case .saving: return "Saving..."
        }
    }
}

struct MeetingDetailFlowLayout: Layout {
    let spacing: CGFloat

    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func updateCache(_ cache: inout [CGSize], subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
        layout(proposal: proposal, sizes: cache).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout [CGSize]
    ) {
        let result = layout(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            sizes: cache
        )
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }

    func layout(sizes: [CGSize], width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var points = Array(repeating: CGPoint.zero, count: sizes.count)
        var rowStart = 0
        var rowY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var x: CGFloat = 0

        for (index, size) in sizes.enumerated() {
            if x > 0, x + size.width > width {
                for rowIndex in rowStart..<index {
                    points[rowIndex].y = rowY + (rowHeight - sizes[rowIndex].height) / 2
                }
                rowY += rowHeight + spacing
                rowStart = index
                rowHeight = 0
                x = 0
            }

            points[index].x = x
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        for rowIndex in rowStart..<sizes.count {
            points[rowIndex].y = rowY + (rowHeight - sizes[rowIndex].height) / 2
        }

        return (CGSize(width: width, height: rowY + rowHeight), points)
    }

    private func layout(
        proposal: ProposedViewSize,
        sizes: [CGSize]
    ) -> (size: CGSize, points: [CGPoint]) {
        let idealWidth = sizes.reduce(CGFloat.zero) { $0 + $1.width }
            + spacing * CGFloat(max(sizes.count - 1, 0))
        return layout(sizes: sizes, width: proposal.width ?? idealWidth)
    }
}

struct MeetingDetailHeaderBarLayout: Layout {
    let spacing: CGFloat

    struct Geometry: Equatable {
        let size: CGSize
        let leadingPoint: CGPoint
        let trailingPoint: CGPoint
        let isStacked: Bool
    }

    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func updateCache(_ cache: inout [CGSize], subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout [CGSize]
    ) -> CGSize {
        guard subviews.count == 2, cache.count == 2 else { return .zero }
        let width = proposal.width ?? cache[0].width + spacing + cache[1].width
        let constrainedTrailingSize = shouldStack(sizes: cache, width: width)
            ? subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
            : nil
        return layout(
            leadingSize: cache[0],
            trailingSize: cache[1],
            constrainedTrailingSize: constrainedTrailingSize,
            width: width
        ).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout [CGSize]
    ) {
        guard subviews.count == 2, cache.count == 2 else { return }
        let isStacked = shouldStack(sizes: cache, width: bounds.width)
        let trailingProposal = isStacked
            ? ProposedViewSize(width: bounds.width, height: nil)
            : .unspecified
        let constrainedTrailingSize = isStacked
            ? subviews[1].sizeThatFits(trailingProposal)
            : nil
        let geometry = layout(
            leadingSize: cache[0],
            trailingSize: cache[1],
            constrainedTrailingSize: constrainedTrailingSize,
            width: bounds.width
        )
        subviews[0].place(
            at: CGPoint(x: bounds.minX + geometry.leadingPoint.x, y: bounds.minY + geometry.leadingPoint.y),
            anchor: .topLeading,
            proposal: .unspecified
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + geometry.trailingPoint.x, y: bounds.minY + geometry.trailingPoint.y),
            anchor: .topLeading,
            proposal: trailingProposal
        )
    }

    func layout(
        leadingSize: CGSize,
        trailingSize: CGSize,
        constrainedTrailingSize: CGSize? = nil,
        width: CGFloat
    ) -> Geometry {
        guard shouldStack(sizes: [leadingSize, trailingSize], width: width) else {
            let height = max(leadingSize.height, trailingSize.height)
            return Geometry(
                size: CGSize(width: width, height: height),
                leadingPoint: CGPoint(x: 0, y: (height - leadingSize.height) / 2),
                trailingPoint: CGPoint(x: width - trailingSize.width, y: (height - trailingSize.height) / 2),
                isStacked: false
            )
        }

        let wrappedTrailingSize = constrainedTrailingSize ?? trailingSize
        return Geometry(
            size: CGSize(width: width, height: leadingSize.height + spacing + wrappedTrailingSize.height),
            leadingPoint: .zero,
            trailingPoint: CGPoint(x: 0, y: leadingSize.height + spacing),
            isStacked: true
        )
    }

    private func shouldStack(sizes: [CGSize], width: CGFloat) -> Bool {
        sizes[0].width + spacing + sizes[1].width > width
    }
}

enum MeetingHeaderLayout {
    static let contextControlHeight: CGFloat = 28
}

enum CompactMeetingFormattingPolicy {
    static func showsFormattingControls(for status: MeetingStatus, isPreparing: Bool) -> Bool {
        switch status {
        case .recording:
            return !isPreparing
        case .noteOnly:
            return true
        case .processing, .completed, .failed:
            return false
        }
    }
}

struct ResponsiveHorizontalLayout<Wide: View, Compact: View>: View {
    let wideIdentifier: String
    let compactIdentifier: String
    @ViewBuilder let wide: () -> Wide
    @ViewBuilder let compact: () -> Compact

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wide()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(wideIdentifier)
            compact()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(compactIdentifier)
        }
    }
}

// Wrapper views that isolate observation of liveMeetingTranscript.
// Without these, MeetingDetailView.body would observe the property and
// re-evaluate on every chunk (every ~5s), re-rendering the entire detail view.
// Each wrapper is the sole observer — MeetingDetailView passes appState by
// reference and never reads liveMeetingTranscript in its own body.
private struct LiveTranscriptSection: View {
    let appState: AppState
    let transcriptPrefix: String

    var body: some View {
        LiveTranscriptView(
            transcript: MeetingResumePolicy.combinedResumeTranscript(
                prior: transcriptPrefix,
                new: appState.liveMeetingTranscript
            ),
            partialYou: appState.liveMeetingPartialYou,
            partialOthers: appState.liveMeetingPartialOthers
        )
    }
}

/// Live chat is a wrapper for the same reason `LiveTranscriptSection` is: it must be the
/// sole observer of `liveMeetingTranscript`. Reading that property in `MeetingDetailView.body`
/// to pass a transcript into chat would re-render the whole detail view on every chunk.
private struct LiveChatSection: View {
    let appState: AppState
    let meeting: MeetingRecord
    let conversation: MeetingChatConversation
    let manualNotes: String
    let config: AppConfig
    @State private var draft = ""

    /// Fresh on every call: the send-time resolver below reaches through `appState`,
    /// so a question asked minutes into the recording sees the transcript up to now.
    private var currentTranscript: String {
        MeetingChatSource.transcript(
            for: meeting,
            live: appState.liveMeetingTranscript,
            isRecording: true
        )
    }

    var body: some View {
        MeetingChatView(
            conversation: conversation,
            draft: $draft,
            transcript: { currentTranscript },
            hasTranscript: !currentTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            systemPrompt: MeetingChatSource.systemPrompt(isRecording: true),
            manualNotes: { manualNotes },
            config: { config }
        )
    }
}

/// Which transcript chat reads, and how the model is told to interpret it.
///
/// A recording combines the prior transcript with the live one exactly as the Live tab does:
/// on a resumed meeting `liveMeetingTranscript` holds only the newly recorded portion, so
/// reading it alone would answer from less than the user can plainly see on screen.
enum MeetingChatSource {
    /// What chat should read for a meeting.
    ///
    /// A completed meeting gets `displayTranscript`, so chat reasons over repaired
    /// text once cleanup has succeeded and over the raw text otherwise. A recording
    /// meeting has no cleaned transcript yet and combines its pre-resume text with
    /// the live one, or a resumed meeting would lose everything before the resume.
    static func transcript(for meeting: MeetingRecord, live: String, isRecording: Bool) -> String {
        isRecording
            ? liveTranscript(prior: meeting.rawTranscript, live: live)
            : meeting.displayTranscript
    }

    /// The same combination for a surface that holds its prior transcript as a plain string
    /// rather than a record — the floating panel, which only ever shows a recording meeting.
    static func liveTranscript(prior: String, live: String) -> String {
        MeetingResumePolicy.combinedResumeTranscript(prior: prior, new: live)
    }

    static func systemPrompt(isRecording: Bool) -> String {
        isRecording ? MeetingChatPrompts.live : MeetingChatPrompts.completed
    }
}

struct MeetingDetailView: View {
    let meeting: MeetingRecord?
    let controller: ImlaController
    let appState: AppState
    let onBack: (() -> Void)?
    let backLabel: String
    var recordingCoordinator: RecordingArtifactPlaybackCoordinator = .shared
    @Environment(\.usesCompactQuickNotes) private var usesCompactQuickNotes
    @State private var isSummarizing = false
    @State private var isRetranscribing = false
    @State private var isEditingNotes = false
    @State private var isEditingTranscript = false
    @State private var editableTitle: String
    @State private var editableNotes: String
    @State private var editableTranscript: String
    @State private var editableManualNotes: String
    @State private var chatDraft = ""
    @State private var loadedMeetingID: Int64?
    @State private var manualNotesSaveStatus: ManualNotesSaveStatus = .saved
    @State private var manualEditorCommand: MarkdownEditorCommand?
    @State private var pendingTemplateID: String
    @State private var documentMode: MeetingDocumentMode
    @State private var recordingMode: RecordingContentMode = .notes
    @State private var titleSaveTask: DispatchWorkItem?
    @State private var notesSaveTask: DispatchWorkItem?
    @State private var transcriptSaveTask: DispatchWorkItem?
    @State private var manualNotesSaveStatusTask: DispatchWorkItem?
    @State private var summaryErrorMessage: String?
    @State private var retranscriptionErrorMessage: String?
    @State private var showDeleteConfirmation = false
    @State private var transcriptResummaryPromptMeetingID: Int64?
    @State private var transcriptEditOriginalTranscript: String?
    @State private var transcriptEditHadStructuredNotes = false
    @State private var showFolderPopover = false
    @State private var showNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var threadContext: MeetingThreadContext?

    init(
        meeting: MeetingRecord?,
        controller: ImlaController,
        appState: AppState,
        onBack: (() -> Void)? = nil,
        backLabel: String = "Back to Meetings"
    ) {
        self.meeting = meeting
        self.controller = controller
        self.appState = appState
        self.onBack = onBack
        self.backLabel = backLabel
        let initialTemplateID = meeting.map { controller.meetingTemplateSnapshot(for: $0).id } ?? controller.defaultMeetingTemplate().id
        _editableTitle = State(initialValue: meeting?.title ?? "")
        _editableNotes = State(initialValue: meeting.map { Self.notesContent(for: $0) } ?? "")
        _editableTranscript = State(initialValue: meeting?.rawTranscript ?? "")
        _editableManualNotes = State(initialValue: meeting?.manualNotes ?? "")
        _loadedMeetingID = State(initialValue: meeting?.id)
        _pendingTemplateID = State(initialValue: initialTemplateID)
        _documentMode = State(initialValue: meeting.map(Self.defaultDocumentMode(for:)) ?? .notes)
    }

    var body: some View {
        Group {
            if let meeting {
                VStack(alignment: .leading, spacing: 0) {
                    header(meeting)

                    Divider()
                        .background(ImlaTheme.surfaceBorder)

                    content(for: meeting)
                }
                .background(ImlaTheme.backgroundBase)
                .onAppear {
                    threadContext = controller.meetingThreadContext(for: meeting.id)
                    resetChatModeIfUnavailable()
                    if controller.canUseSummaryProvider(.openRouter) {
                        controller.loadOpenRouterModels(.text)
                    }
                }
                .onChange(of: isChatAvailable) { _, _ in
                    resetChatModeIfUnavailable()
                }
                .onChange(of: meeting.id) { _, _ in
                    syncLocalState(with: meeting)
                }
                .onChange(of: meeting.status) { _, _ in
                    syncLocalState(with: meeting)
                }
                .onChange(of: appState.meetingNotesFocusRequest) { _, _ in
                    recordingMode = .notes
                }
                .onChange(of: meeting.manualNotes) { _, _ in
                    syncManualNotesState(with: meeting)
                }
                .onChange(of: appState.config.customMeetingTemplates) { _, _ in
                    syncPendingTemplateSelectionIfNeeded(for: meeting)
                }
            } else {
                VStack(spacing: ImlaTheme.spacing12) {
                    Text("No meeting selected")
                        .font(ImlaTheme.title3())
                        .foregroundStyle(ImlaTheme.textSecondary)
                    Text("Choose a meeting from the Meetings browser to open it here.")
                        .font(ImlaTheme.callout())
                        .foregroundStyle(ImlaTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ImlaTheme.backgroundBase)
            }
        }
        .alert("Couldn't Save Summary", isPresented: summaryErrorBinding) {
            Button("OK", role: .cancel) {
                summaryErrorMessage = nil
            }
        } message: {
            Text(summaryErrorMessage ?? "The updated meeting notes could not be saved.")
        }
        .alert("Couldn't Re-transcribe Meeting", isPresented: retranscriptionErrorBinding) {
            Button("OK", role: .cancel) {
                retranscriptionErrorMessage = nil
            }
        } message: {
            Text(retranscriptionErrorMessage ?? "The saved recording could not be re-transcribed.")
        }
        .alert("Re-summarize Notes?", isPresented: transcriptResummaryPromptBinding) {
            Button("Re-summarize") {
                resummarizeAfterTranscriptEdit()
            }
            Button("Not Now", role: .cancel) {
                transcriptResummaryPromptMeetingID = nil
            }
        } message: {
            Text("Your transcript edits may change the generated notes. Re-summarize now to update them from the edited transcript.")
        }
        .alert("Delete Meeting", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let meeting {
                    controller.deleteMeeting(id: meeting.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this meeting? Saved notes, transcript, and any retained recording will be removed.")
        }
    }

    @ViewBuilder
    private func header(_ meeting: MeetingRecord) -> some View {
        if usesCompactQuickNotes {
            compactQuickNotesHeader(meeting)
        } else {
            standardHeader(meeting)
        }
    }

    private func standardHeader(_ meeting: MeetingRecord) -> some View {
        let appliedTemplate = controller.meetingTemplateSnapshot(for: meeting)
        return VStack(alignment: .leading, spacing: ImlaTheme.spacing16) {
            adaptiveHeaderContent(for: meeting, appliedTemplate: appliedTemplate)

            RecordingArtifactSection(
                owner: .meeting(meeting.id),
                coordinator: recordingCoordinator
            )

            activeMeetingAudioWarningBanner(for: meeting)

            if !showsManualNotesEditor(for: meeting), isRawTranscript(meeting), documentMode == .notes {
                transcriptCTA
            }
        }
        .frame(maxWidth: ImlaTheme.contentMaxWidth, alignment: .leading)
        .padding(.horizontal, ImlaTheme.pageHorizontalInset)
        .padding(.top, ImlaTheme.spacing16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.header.standard")
    }

    private func compactQuickNotesHeader(_ meeting: MeetingRecord) -> some View {
        let appliedTemplate = controller.meetingTemplateSnapshot(for: meeting)
        return VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
            HStack(alignment: .center, spacing: ImlaTheme.spacing8) {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ImlaTheme.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(ImlaTheme.backgroundRaised)
                            .clipShape(Circle())
                            .overlay {
                                Circle().strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(backLabel)
                    .accessibilityLabel(backLabel)
                }

                VStack(alignment: .leading, spacing: 2) {
                    MarqueeTitleTextField(
                        text: $editableTitle,
                        titleSize: 24,
                        onSubmit: {
                            controller.updateMeetingTitle(id: meeting.id, title: editableTitle)
                        },
                        onTextChange: {
                            debounceSaveTitle(meetingID: meeting.id)
                        }
                    )

                    HStack(spacing: 6) {
                        metadataItem(
                            systemImage: "calendar",
                            text: MeetingBrowserLogic.formatStartTime(meeting.startTime)
                        )
                        metadataDivider
                        metadataItem(systemImage: "clock", text: formatDuration(meeting.durationSeconds))
                    }
                    .lineLimit(1)
                }
                .layoutPriority(1)

                if showsManualNotesEditor(for: meeting) {
                    compactRecordingControls(for: meeting)
                } else {
                    compactHeaderActions(for: meeting, appliedTemplate: appliedTemplate)
                }
            }

            HStack(alignment: .center, spacing: ImlaTheme.spacing8) {
                folderPill(for: meeting)
                    .frame(maxWidth: 150)
                if CompactMeetingFormattingPolicy.showsFormattingControls(
                    for: meeting.status,
                    isPreparing: isPreparingThisMeeting(meeting)
                ) {
                    compactFormattingToolbar
                        .disabled(!canEditManualNotes(for: meeting))
                } else {
                    MeetingParticipantsView(meetingID: meeting.id, controller: controller)
                        .frame(maxWidth: 150)
                }
                Spacer(minLength: 0)
                detailModePicker(for: meeting)
            }

            threadBreadcrumb

            activeMeetingAudioWarningBanner(for: meeting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.header.compact")
    }

    @ViewBuilder
    private func compactRecordingControls(for meeting: MeetingRecord) -> some View {
        if meeting.status == .recording, !isPreparingThisMeeting(meeting) {
            HStack(spacing: 5) {
                Circle()
                    .fill(appState.isMeetingRecordingPaused ? ImlaTheme.transcribing : ImlaTheme.recording)
                    .frame(width: 7, height: 7)
                    .help(appState.isMeetingRecordingPaused ? "Recording paused" : "Recording")
                pauseResumeRecordingButton
                    .fixedSize()
                stopRecordingButton
                    .fixedSize()
                MeetingParticipantsView(
                    meetingID: meeting.id,
                    controller: controller,
                    compactDiscardAction: {
                        controller.discardMeetingWithConfirmation()
                    }
                )
            }
        } else {
            recordingControlGroup(for: meeting)
        }
    }

    private var compactFormattingToolbar: some View {
        HStack(spacing: 4) {
            markdownToolbarButton(systemImage: "textformat.size", label: "Heading") {
                manualEditorCommand = MarkdownEditorCommand(kind: .heading)
            }
            markdownToolbarButton(systemImage: "bold", label: "Bold") {
                manualEditorCommand = MarkdownEditorCommand(kind: .bold)
            }
            markdownToolbarButton(systemImage: "list.bullet", label: "Bullet") {
                manualEditorCommand = MarkdownEditorCommand(kind: .bullet)
            }
            markdownToolbarButton(systemImage: "checklist", label: "Checkbox") {
                manualEditorCommand = MarkdownEditorCommand(kind: .checkbox)
            }
        }
        .fixedSize()
    }

    private func meetingIdentity(for meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing8) {
            MarqueeTitleTextField(
                text: $editableTitle,
                onSubmit: {
                    controller.updateMeetingTitle(id: meeting.id, title: editableTitle)
                },
                onTextChange: {
                    debounceSaveTitle(meetingID: meeting.id)
                }
            )

            HStack(spacing: ImlaTheme.spacing8) {
                metadataItem(systemImage: "calendar", text: MeetingBrowserLogic.formatStartTime(meeting.startTime))
                metadataDivider
                metadataItem(systemImage: "clock", text: formatDuration(meeting.durationSeconds))
                metadataDivider
                metadataItem(systemImage: "doc.text", text: "\(meeting.wordCount) words")
                if let label = SyncOriginDisplay.badgeLabel(forMeetingSource: meeting.source) {
                    SyncOriginBadge(label: label)
                }
            }
        }
    }

    @ViewBuilder
    private func meetingHeaderActions(
        for meeting: MeetingRecord,
        appliedTemplate: MeetingTemplateSnapshot
    ) -> some View {
        if showsManualNotesEditor(for: meeting) {
            recordingControlGroup(for: meeting)
        } else {
            compactHeaderActions(for: meeting, appliedTemplate: appliedTemplate)
        }
    }

    /// The wide dashboard keeps identity and recording actions on one row. In
    /// a side-by-side call layout, stack the actions below the title instead of
    /// forcing the window back to its old 900pt minimum.
    private func responsiveTitleAndActions(
        for meeting: MeetingRecord,
        appliedTemplate: MeetingTemplateSnapshot
    ) -> some View {
        ResponsiveHorizontalLayout(
            wideIdentifier: "meeting.header.wide",
            compactIdentifier: "meeting.header.compact"
        ) {
            HStack(alignment: .top, spacing: ImlaTheme.spacing24) {
                meetingIdentity(for: meeting)
                    .frame(minWidth: 260)

                Spacer(minLength: ImlaTheme.spacing16)

                VStack(alignment: .trailing, spacing: 10) {
                    meetingHeaderActions(for: meeting, appliedTemplate: appliedTemplate)
                }
            }
        } compact: {
            VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
                meetingIdentity(for: meeting)
                meetingHeaderActions(for: meeting, appliedTemplate: appliedTemplate)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Folder/people controls and the Notes/Live picker share a row when space
    /// permits, then split into two rows for the compact meeting-notes window.
    private func responsiveContextControls(for meeting: MeetingRecord) -> some View {
        ResponsiveHorizontalLayout(
            wideIdentifier: "meeting.context.wide",
            compactIdentifier: "meeting.context.compact"
        ) {
            HStack(alignment: .center, spacing: ImlaTheme.spacing12) {
                meetingContextStrip(for: meeting)
                    .frame(minWidth: 280, alignment: .leading)
                    .layoutPriority(1)
                Spacer(minLength: ImlaTheme.spacing12)
                detailModePicker(for: meeting)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } compact: {
            VStack(alignment: .leading, spacing: ImlaTheme.spacing8) {
                meetingContextStrip(for: meeting)
                    .frame(maxWidth: .infinity, alignment: .leading)
                detailModePicker(for: meeting)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func meetingContextStrip(for meeting: MeetingRecord) -> some View {
        HStack(alignment: .center, spacing: ImlaTheme.spacing16) {
            folderPill(for: meeting)
            Divider()
                .frame(height: 20)
            MeetingParticipantsView(
                meetingID: meeting.id,
                controller: controller
            )
        }
    }

    private func metadataItem(systemImage: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(ImlaTheme.callout())
        }
        .foregroundStyle(ImlaTheme.textSecondary)
    }

    private var metadataDivider: some View {
        Text("·")
            .font(ImlaTheme.callout())
            .foregroundStyle(ImlaTheme.textTertiary)
    }

    @ViewBuilder
    private func detailModePicker(for meeting: MeetingRecord) -> some View {
        if meeting.status == .recording, showsManualNotesEditor(for: meeting) {
            recordingModePicker
        } else if !showsManualNotesEditor(for: meeting) {
            documentModePicker
        }
    }

    @ViewBuilder
    private func adaptiveHeaderContent(
        for meeting: MeetingRecord,
        appliedTemplate: MeetingTemplateSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing16) {
            if let onBack {
                MeetingDetailHeaderBarLayout(spacing: ImlaTheme.spacing8) {
                    Button(action: onBack) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                            Text(backLabel)
                                .font(ImlaTheme.callout())
                        }
                        .foregroundStyle(ImlaTheme.textSecondary)
                    }
                    .buttonStyle(ImlaActionButtonStyle(tone: .quiet, compact: true))

                    headerUtilityBand(for: meeting, appliedTemplate: appliedTemplate)
                }
            } else {
                headerUtilityBand(for: meeting, appliedTemplate: appliedTemplate)
            }
            headerTitleContent(for: meeting, appliedTemplate: appliedTemplate)
                .fixedSize(horizontal: false, vertical: true)
            threadBreadcrumb
        }
    }

    private func headerTitleContent(
        for meeting: MeetingRecord,
        appliedTemplate: MeetingTemplateSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing8) {
            MarqueeTitleTextField(
                text: $editableTitle,
                onSubmit: {
                    controller.updateMeetingTitle(id: meeting.id, title: editableTitle)
                },
                onTextChange: {
                    debounceSaveTitle(meetingID: meeting.id)
                }
            )

            HStack(spacing: ImlaTheme.spacing8) {
                // One row: the date/duration/word-count string reads as a single
                // fact, and letting it wrap splits "786 words" onto its own line
                // while the template chip drifts away from it.
                Text(formatMeta(meeting))
                    .font(ImlaTheme.callout())
                    .foregroundStyle(ImlaTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let label = SyncOriginDisplay.badgeLabel(forMeetingSource: meeting.source) {
                    SyncOriginBadge(label: label)
                }
                templateChip(for: appliedTemplate)
                Spacer(minLength: 0)
            }

        }
    }

    @ViewBuilder
    private func headerUtilityBand(
        for meeting: MeetingRecord,
        appliedTemplate: MeetingTemplateSnapshot
    ) -> some View {
        MeetingDetailFlowLayout(spacing: ImlaTheme.spacing8) {
            folderPill(for: meeting)
            if showsManualNotesEditor(for: meeting) {
                recordingControlGroup(for: meeting)
            } else {
                if canShowResumeChooser(for: meeting) {
                    actionRailContainer {
                        resumeRecordingButton(for: meeting)
                    }
                }
                actionRailContainer {
                    templateAndExportActionRailContent(for: meeting, appliedTemplate: appliedTemplate)
                }
                utilityActionRail(for: meeting)
            }
        }
    }

    @ViewBuilder
    private func content(for meeting: MeetingRecord) -> some View {
        if showsManualNotesEditor(for: meeting) {
            if meeting.status == .recording {
                let isManualNotesEditable = canEditManualNotes(for: meeting)
                let persistedNotes = Self.notesContent(for: meeting)
                let hasPersistedNotes = !meeting.formattedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !meeting.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                // The picker sits above the panes it switches, matching the completed-meeting
                // layout. It cannot live in manualNotesToolbar — that is markdown-editing
                // controls inside the Notes pane, so it would vanish on the Live and Chat tabs.
                HStack {
                    recordingModePicker
                    Spacer()
                }
                .frame(maxWidth: ImlaTheme.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, ImlaTheme.pageHorizontalInset)
                .padding(.top, 12)

                ZStack {
                    VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
                        if hasPersistedNotes {
                            MeetingNotesView(markdown: persistedNotes)
                                .frame(maxWidth: ImlaTheme.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
                                .background(ImlaTheme.backgroundBase)
                                .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                                        .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
                                )
                        }

                        VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
                            if !usesCompactQuickNotes {
                                manualNotesToolbar(for: meeting)
                                    .disabled(!isManualNotesEditable)
                            }
                            MarkdownRichTextEditor(
                                text: $editableManualNotes,
                                command: $manualEditorCommand,
                                shouldFocus: isManualNotesEditable,
                                isEditable: isManualNotesEditable,
                                onTextChange: { notes in
                                    guard isManualNotesEditable else { return }
                                    saveManualNotes(meetingID: meeting.id, notes: notes)
                                }
                            )
                            .background(ImlaTheme.backgroundBase)
                            .manualNotesEditorChrome(compact: usesCompactQuickNotes)
                            .frame(maxHeight: hasPersistedNotes ? 260 : .infinity)
                        }
                        .frame(maxWidth: ImlaTheme.contentMaxWidth, maxHeight: hasPersistedNotes ? nil : .infinity, alignment: .topLeading)
                    }
                    .padding(.horizontal, ImlaTheme.pageHorizontalInset)
                    .padding(.top, usesCompactQuickNotes ? 0 : 12)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .opacity(recordingMode == .notes ? 1 : 0)
                    .allowsHitTesting(recordingMode == .notes)
                    .accessibilityHidden(recordingMode != .notes)

                    LiveTranscriptSection(appState: appState, transcriptPrefix: meeting.rawTranscript)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(recordingMode == .live ? 1 : 0)
                        .allowsHitTesting(recordingMode == .live)
                        .accessibilityHidden(recordingMode != .live)

                    if isChatAvailable {
                        LiveChatSection(
                            appState: appState,
                            meeting: meeting,
                            conversation: MeetingChatConversations.shared.conversation(for: meeting.id),
                            manualNotes: meeting.manualNotes,
                            config: appState.config
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(recordingMode == .chat ? 1 : 0)
                        .allowsHitTesting(recordingMode == .chat)
                        .accessibilityHidden(recordingMode != .chat)
                    }
                }
            } else {
                let isManualNotesEditable = canEditManualNotes(for: meeting)
                VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
                    if !usesCompactQuickNotes {
                        manualNotesToolbar(for: meeting)
                            .disabled(!isManualNotesEditable)
                    }

                    MarkdownRichTextEditor(
                        text: $editableManualNotes,
                        command: $manualEditorCommand,
                        shouldFocus: false,
                        isEditable: isManualNotesEditable,
                        onTextChange: { notes in
                            guard isManualNotesEditable else { return }
                            saveManualNotes(meetingID: meeting.id, notes: notes)
                        }
                    )
                    .frame(maxWidth: ImlaTheme.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
                    .background(ImlaTheme.backgroundBase)
                    .manualNotesEditorChrome(compact: usesCompactQuickNotes)
                }
                .padding(.horizontal, ImlaTheme.pageHorizontalInset)
                .padding(.top, usesCompactQuickNotes ? 0 : 12)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } else if isEditingNotes {
            VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
                contentToolbar(for: meeting)

                TextEditor(text: $editableNotes)
                    .font(ImlaTheme.mono(size: 13))
                    .foregroundStyle(ImlaTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(ImlaTheme.spacing24)
                    .background(ImlaTheme.backgroundBase)
                    .frame(maxWidth: ImlaTheme.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
                    .onChange(of: editableNotes) { _, _ in
                        debounceSaveNotes(meetingID: meeting.id)
                    }
            }
            .padding(.horizontal, ImlaTheme.pageHorizontalInset)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if isEditingTranscript {
            VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
                contentToolbar(for: meeting)

                TextEditor(text: $editableTranscript)
                    .font(ImlaTheme.font(size: 14))
                    .foregroundStyle(ImlaTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(ImlaTheme.spacing24)
                    .background(ImlaTheme.backgroundBase)
                    .frame(maxWidth: ImlaTheme.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
                    .onChange(of: editableTranscript) { _, _ in
                        debounceSaveTranscript(meetingID: meeting.id)
                    }
            }
            .padding(.horizontal, ImlaTheme.pageHorizontalInset)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
                contentToolbar(for: meeting)

                readOnlyDocumentContent(for: meeting)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: ImlaTheme.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, ImlaTheme.pageHorizontalInset)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private func readOnlyDocumentContent(for meeting: MeetingRecord) -> some View {
        switch documentMode {
        case .notes:
            MeetingNotesView(markdown: Self.notesContent(for: meeting))
        case .transcript:
            MeetingTranscriptView(transcript: meeting.displayTranscript)
        case .chat:
            if isChatAvailable {
                MeetingChatView(
                    conversation: MeetingChatConversations.shared.conversation(for: meeting.id),
                    draft: $chatDraft,
                    transcript: { MeetingChatSource.transcript(
                        for: meeting,
                        live: "",
                        isRecording: false
                    ) },
                    hasTranscript: !meeting.displayTranscript
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    systemPrompt: MeetingChatSource.systemPrompt(isRecording: false),
                    manualNotes: { meeting.manualNotes },
                    config: { appState.config }
                )
            } else {
                MeetingNotesView(markdown: Self.notesContent(for: meeting))
            }
        }
    }

    /// Chat needs a backend that is actually usable, not merely selected. `resolvedBackend`
    /// always returns something (it defaults to ChatGPT), so gating on it would show the tab
    /// to users with no credentials and fail on first use. This reuses the same readiness
    /// test the summary action already applies.
    private var isChatAvailable: Bool { hasApiKey }

    /// If credentials disappear while Chat is the selected segment, the picker item and its
    /// content both vanish and every remaining view sits at zero opacity — a blank pane with
    /// nothing selected. Fall back to a segment that still exists.
    private func resetChatModeIfUnavailable() {
        guard !isChatAvailable else { return }
        if documentMode == .chat { documentMode = .notes }
        if recordingMode == .chat { recordingMode = .notes }
    }

    private var documentModePicker: some View {
        Picker("", selection: $documentMode) {
            Text("Notes").tag(MeetingDocumentMode.notes)
            Text("Transcript").tag(MeetingDocumentMode.transcript)
            if isChatAvailable {
                Text("Chat").tag(MeetingDocumentMode.chat)
            }
        }
        .pickerStyle(.segmented)
        .tint(ImlaTheme.accent)
        .frame(width: isChatAvailable ? 300 : 220)
        .disabled(isEditingNotes || isEditingTranscript)
    }

    private var recordingModePicker: some View {
        Picker("", selection: $recordingMode) {
            Text("Notes").tag(RecordingContentMode.notes)
            Text("Live").tag(RecordingContentMode.live)
            if isChatAvailable {
                Text("Chat").tag(RecordingContentMode.chat)
            }
        }
        .pickerStyle(.segmented)
        .tint(ImlaTheme.accent)
        // The compact quick-notes window cannot fit the Chat segment, so the
        // narrow width wins over the wider three-segment layout.
        .frame(width: usesCompactQuickNotes ? 124 : (isChatAvailable ? 260 : 180))
    }

    private func showsManualNotesEditor(for meeting: MeetingRecord) -> Bool {
        switch meeting.status {
        case .recording, .processing, .noteOnly, .failed:
            return true
        case .completed:
            return false
        }
    }

    private func canEditManualNotes(for meeting: MeetingRecord) -> Bool {
        meeting.status == .recording || meeting.status == .noteOnly || meeting.status == .failed
    }

    private func isPreparingThisMeeting(_ meeting: MeetingRecord) -> Bool {
        meeting.status == .recording
            && appState.isMeetingStarting
            && !appState.isMeetingRecording
    }

    private func utilityActionRail(for meeting: MeetingRecord) -> some View {
        actionRailContainer {
            utilityActionRailContent(for: meeting)
        }
    }

    @ViewBuilder
    private func templateAndExportActionRailContent(
        for meeting: MeetingRecord,
        appliedTemplate: MeetingTemplateSnapshot
    ) -> some View {
        templateMenu(for: meeting, appliedTemplate: appliedTemplate)
        railDivider
        exportMenu(for: meeting)
    }

    @ViewBuilder
    private func utilityActionRailContent(for meeting: MeetingRecord) -> some View {
        summaryAction(for: meeting)
        railDivider
        editButton(for: meeting)
        if hasMoreActions(for: meeting) {
            railDivider
            moreActionsMenu(for: meeting)
        }
    }

    private func actionRailContainer<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 2) {
            content()
        }
        .fixedSize()
        .padding(2)
        .background(ImlaTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var railDivider: some View {
        Rectangle()
            .fill(ImlaTheme.surfaceBorder)
            .frame(width: 1, height: 18)
    }

    @ViewBuilder
    private func summaryAction(for meeting: MeetingRecord) -> some View {
        if isSummarizing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 36, height: ImlaTheme.controlHeight)
                .accessibilityLabel("Summarizing meeting")
                .help("Summarizing meeting")
        } else {
            // Clicking summarizes with the configured provider; the menu overrides
            // provider and model for this meeting alone, without changing settings.
            Menu {
                Button("Use Settings (\(appState.selectedMeetingSummaryBackend.label))") {
                    beginSummary(for: meeting)
                }
                Divider()
                ForEach(MeetingSummaryBackendOption.all, id: \.backend) { provider in
                    if controller.canUseSummaryProvider(provider) {
                        Menu(provider.label) {
                            ForEach(provider.summaryModels(
                                config: appState.config,
                                openRouterModels: appState.openRouterSummaryModels
                            ), id: \.id) { model in
                                Button(model.label) {
                                    beginSummary(
                                        for: meeting,
                                        summaryConfig: provider.summaryConfiguration(
                                            from: appState.config,
                                            model: model.id
                                        )
                                    )
                                }
                            }
                            if provider == .openRouter {
                                if case .failed = appState.openRouterSummaryCatalogState {
                                    Divider()
                                    Button("Retry Loading Models") {
                                        controller.loadOpenRouterModels(.text, force: true)
                                    }
                                } else if appState.openRouterSummaryCatalogState == .loading {
                                    Text("Loading models…")
                                }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ImlaTheme.textSecondary)
                    .frame(width: 36, height: ImlaTheme.controlHeight)
                    .contentShape(Rectangle())
            } primaryAction: {
                beginSummary(for: meeting)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(primarySummaryActionLabel(for: meeting))
            .help(primarySummaryActionLabel(for: meeting))
        }
    }

    private func beginSummary(for meeting: MeetingRecord, summaryConfig: AppConfig? = nil) {
        guard !isSummarizing else { return }
        isSummarizing = true
        let completion: (Result<Void, Error>) -> Void = { [meeting] result in
            isSummarizing = false
            switch result {
            case .success:
                if let updated = controller.meeting(id: meeting.id) {
                    syncLocalState(with: updated)
                }
            case .failure(let error):
                syncPendingTemplateSelectionIfNeeded(
                    for: controller.meeting(id: meeting.id) ?? meeting
                )
                summaryErrorMessage = error.localizedDescription
            }
        }
        if hasPendingTemplateChange(for: meeting) {
            controller.applyMeetingTemplate(
                id: pendingTemplateID,
                to: meeting,
                summaryConfig: summaryConfig,
                completion: completion
            )
        } else {
            controller.resummarize(meeting: meeting, summaryConfig: summaryConfig, completion: completion)
        }
    }

    @ViewBuilder
    private func editButton(for meeting: MeetingRecord) -> some View {
        railIconButton(
            isEditingNotes || isEditingTranscript ? "checkmark.circle" : "pencil",
            label: editButtonLabel
        ) {
            if isEditingNotes {
                notesSaveTask?.cancel()
                notesSaveTask = nil
                controller.updateMeetingNotes(id: meeting.id, notes: editableNotes)
                isEditingNotes = false
            } else if isEditingTranscript {
                guard !isRetranscribing else { return }
                transcriptSaveTask?.cancel()
                transcriptSaveTask = nil
                let shouldPromptForResummary = Self.shouldPromptForTranscriptResummary(
                    hadStructuredNotes: transcriptEditHadStructuredNotes,
                    originalTranscript: transcriptEditOriginalTranscript,
                    editedTranscript: editableTranscript
                )
                controller.updateMeetingTranscript(id: meeting.id, transcript: editableTranscript)
                isEditingTranscript = false
                transcriptEditOriginalTranscript = nil
                transcriptEditHadStructuredNotes = false
                if shouldPromptForResummary {
                    transcriptResummaryPromptMeetingID = meeting.id
                }
            } else if documentMode == .transcript {
                // Editing targets the raw transcript, not the displayed one. Saving a
                // cleaned transcript back over raw would make the model's guesses the
                // durable record, and the store's trigger discards the cleaned copy on
                // save anyway -- so the user's edit becomes the new source of truth.
                editableTranscript = meeting.rawTranscript
                transcriptEditOriginalTranscript = meeting.rawTranscript
                transcriptEditHadStructuredNotes = meeting.notesState == .structuredNotes
                isEditingTranscript = true
            } else {
                documentMode = .notes
                editableNotes = Self.notesContent(for: meeting)
                isEditingNotes = true
            }
        }
        .disabled(isRetranscribing && !isEditingNotes && !isEditingTranscript)
    }

    private func railIconButton(
        _ systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ImlaTheme.textSecondary)
                .frame(width: 36, height: ImlaTheme.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    @ViewBuilder
    private func retranscribeAction(for meeting: MeetingRecord) -> some View {
        if recordingCoordinator.resolution(for: .meeting(meeting.id)).availability == .available {
            if isRetranscribing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Re-transcribing...")
                        .font(ImlaTheme.font(size: 11))
                        .foregroundStyle(ImlaTheme.textTertiary)
                }
                .padding(.horizontal, ImlaTheme.spacing8)
            } else {
                iconButton("arrow.clockwise", label: "Re-transcribe") {
                    startRetranscription(for: meeting)
                }
                .disabled(meeting.status == .recording || meeting.status == .processing || isEditingNotes || isEditingTranscript)
            }
        }
    }

    private func startRetranscription(for meeting: MeetingRecord) {
        isRetranscribing = true
        controller.retranscribe(meeting: meeting) { [meeting] result in
            isRetranscribing = false
            switch result {
            case .success:
                if let updated = controller.meeting(id: meeting.id) {
                    syncLocalState(with: updated)
                }
            case .failure(let error):
                retranscriptionErrorMessage = error.localizedDescription
            }
        }
    }

    /// The compact quick-notes header has room for a single row, so it carries
    /// the action rail's controls without the rail's divider chrome.
    @ViewBuilder
    private func compactHeaderActions(
        for meeting: MeetingRecord,
        appliedTemplate: MeetingTemplateSnapshot
    ) -> some View {
        HStack(spacing: ImlaTheme.spacing8) {
            templateMenu(for: meeting, appliedTemplate: appliedTemplate)
            exportMenu(for: meeting)
            summaryAction(for: meeting)
            editButton(for: meeting)
            moreActionsMenu(for: meeting)
        }
    }

    @ViewBuilder
    private func templateMenu(for meeting: MeetingRecord, appliedTemplate: MeetingTemplateSnapshot) -> some View {
        let templateLabel = labelForSelection(on: meeting, appliedTemplate: appliedTemplate)
        let templateAccessibilityLabel = "Summary template: \(templateLabel)"
        Menu {
            Button {
                pendingTemplateID = MeetingTemplates.autoID
            } label: {
                templateMenuItem(
                    title: MeetingTemplates.auto.title,
                    systemImage: MeetingTemplates.auto.icon,
                    isSelected: pendingTemplateID == MeetingTemplates.autoID
                )
            }

            Section("Built-in Templates") {
                ForEach(controller.builtInMeetingTemplates()) { template in
                    Button {
                        pendingTemplateID = template.id
                    } label: {
                        templateMenuItem(
                            title: template.title,
                            systemImage: template.icon,
                            isSelected: pendingTemplateID == template.id
                        )
                    }
                }
            }

            if !controller.customMeetingTemplates().isEmpty {
                Section("Custom Templates") {
                    ForEach(controller.customMeetingTemplates()) { template in
                        Button {
                            pendingTemplateID = template.id
                        } label: {
                            let resolved = MeetingTemplates.customDefinition(from: template)
                            templateMenuItem(
                                title: template.name,
                                systemImage: resolved.icon,
                                isSelected: pendingTemplateID == template.id
                            )
                        }
                    }
                }
            }

            Divider()

            Button("Manage Templates…") {
                controller.showMeetingTemplatesManager()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconName(forSelectionOn: meeting, appliedTemplate: appliedTemplate))
                    .font(.system(size: 10, weight: .semibold))
                Text(templateLabel)
                    .font(ImlaTheme.font(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(ImlaTheme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: ImlaTheme.controlHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .frame(height: ImlaTheme.controlHeight)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(templateAccessibilityLabel)
        .help(templateAccessibilityLabel)
    }

    @ViewBuilder
    private func contentToolbar(for meeting: MeetingRecord) -> some View {
        HStack {
            documentModePicker

            Spacer()

            retranscribeAction(for: meeting)

            Button(action: {
                controller.copyToClipboard(activeCopyText(for: meeting))
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                    Text(copyButtonLabel)
                        .font(ImlaTheme.font(size: 12, weight: .semibold))
                }
                .foregroundStyle(ImlaTheme.textPrimary)
                .padding(.horizontal, ImlaTheme.spacing12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                        .fill(ImlaTheme.accent.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                        .strokeBorder(ImlaTheme.accent.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        // Matches the content container's cap. At 980 the toolbar stopped 100pt short of the
        // content's right edge, so Copy floated inward instead of aligning with it.
        .frame(maxWidth: ImlaTheme.contentMaxWidth, alignment: .leading)
    }

    @ViewBuilder
    private func manualNotesToolbar(for meeting: MeetingRecord) -> some View {
        HStack(spacing: ImlaTheme.spacing8) {
            if canEditManualNotes(for: meeting) {
                Text(manualNotesSaveStatus.label)
                    .font(ImlaTheme.font(size: 12, weight: .medium))
                    .foregroundStyle(ImlaTheme.textTertiary)
            }

            Spacer()

            markdownToolbarButton(systemImage: "textformat.size", label: "Heading") {
                manualEditorCommand = MarkdownEditorCommand(kind: .heading)
            }
            markdownToolbarButton(systemImage: "bold", label: "Bold") {
                manualEditorCommand = MarkdownEditorCommand(kind: .bold)
            }
            markdownToolbarButton(systemImage: "list.bullet", label: "Bullet") {
                manualEditorCommand = MarkdownEditorCommand(kind: .bullet)
            }
            markdownToolbarButton(systemImage: "checklist", label: "Checkbox") {
                manualEditorCommand = MarkdownEditorCommand(kind: .checkbox)
            }
        }
        .frame(maxWidth: ImlaTheme.contentMaxWidth, alignment: .leading)
    }

    @ViewBuilder
    private func statusChip(for meeting: MeetingRecord) -> some View {
        let isPreparing = isPreparingThisMeeting(meeting)
        let isPaused = meeting.status == .recording && appState.isMeetingRecordingPaused
        let label = isPreparing ? "Preparing" : isPaused ? "Paused" : meeting.status.displayLabel
        let color = isPreparing || isPaused ? ImlaTheme.transcribing : meeting.status.displayColor
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(ImlaTheme.font(size: 12, weight: .semibold))
                .foregroundStyle(ImlaTheme.textSecondary)
        }
        .padding(.horizontal, ImlaTheme.spacing8)
        .padding(.vertical, 6)
        .background(ImlaTheme.surfacePrimary)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func recordingControlGroup(for meeting: MeetingRecord) -> some View {
        if meeting.status == .recording {
            if isPreparingThisMeeting(meeting) {
                meetingPreparationControlGroup(for: meeting)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: ImlaTheme.spacing8) {
                        statusChip(for: meeting)
                        pauseResumeRecordingButton
                        stopRecordingButton
                        discardRecordingButton
                    }
                    .recordingControlsBackground()

                    VStack(alignment: .trailing, spacing: ImlaTheme.spacing8) {
                        statusChip(for: meeting)
                        HStack(spacing: ImlaTheme.spacing8) {
                            pauseResumeRecordingButton
                            stopRecordingButton
                            discardRecordingButton
                        }
                        .recordingControlsBackground()
                    }
                }
            }
        } else if controller.canDeleteMeeting(meeting), meeting.status == .noteOnly || meeting.status == .failed {
            HStack(spacing: ImlaTheme.spacing8) {
                statusChip(for: meeting)
                deleteButton
            }
        } else {
            statusChip(for: meeting)
        }
    }

    /// The resume control only makes sense on a finished meeting when no other
    /// recording/editing workflow is active.
    private func canShowResumeChooser(for meeting: MeetingRecord) -> Bool {
        controller.canResumeFinishedMeeting(meeting)
            && !appState.isMeetingRecording
            && !appState.isMeetingStarting
            && !isEditingNotes
            && !isEditingTranscript
            && !isSummarizing
            && !isRetranscribing
    }

    @ViewBuilder
    private func meetingPreparationControlGroup(for meeting: MeetingRecord) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ImlaTheme.spacing8) {
                statusChip(for: meeting)
                meetingPreparationStatus
                cancelMeetingPreparationButton
            }
            .recordingControlsBackground()

            VStack(alignment: .trailing, spacing: ImlaTheme.spacing8) {
                statusChip(for: meeting)
                HStack(spacing: ImlaTheme.spacing8) {
                    meetingPreparationStatus
                    cancelMeetingPreparationButton
                }
                .recordingControlsBackground()
            }
        }
    }

    @ViewBuilder
    private func markdownToolbarButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 14)
        }
        .buttonStyle(ImlaActionButtonStyle(compact: true))
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func exportMenu(for meeting: MeetingRecord) -> some View {
        let currentContent: MeetingExportContent = documentMode == .transcript ? .transcript : .notes
        let currentLabel = documentMode == .transcript ? "Export Transcript" : "Export Notes"
        Menu {
            Button {
                MeetingExporter.export(meeting: meeting, content: currentContent)
            } label: {
                Label(currentLabel, systemImage: documentMode == .transcript ? "text.quote" : "doc.text")
            }
            Button {
                MeetingExporter.export(meeting: meeting, content: .fullMeeting)
            } label: {
                Label("Export Full Meeting", systemImage: "doc.on.doc")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ImlaTheme.textSecondary)
                .frame(width: 36, height: ImlaTheme.controlHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .frame(height: ImlaTheme.controlHeight)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isEditingNotes || isEditingTranscript)
        .accessibilityLabel("Export meeting")
        .help("Export meeting")
    }

    private func hasMoreActions(for meeting: MeetingRecord) -> Bool {
        controller.canDeleteMeeting(meeting)
    }

    @ViewBuilder
    private func moreActionsMenu(for meeting: MeetingRecord) -> some View {
        if hasMoreActions(for: meeting) {
            Menu {
                if controller.canDeleteMeeting(meeting) {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Meeting", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ImlaTheme.textSecondary)
                    .frame(width: 36, height: ImlaTheme.controlHeight)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")
            .help("More actions")
        }
    }

    private func templateMenuItem(title: String, systemImage: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark" : systemImage)
                .frame(width: 12)
            Text(title)
        }
    }

    @ViewBuilder
    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: ImlaTheme.spacing8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                Text(label)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .buttonStyle(ImlaActionButtonStyle(compact: true))
    }

    private var deleteButton: some View {
        iconButton("trash", label: "Delete") {
            showDeleteConfirmation = true
        }
    }

    private var meetingPreparationStatus: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
                .accessibilityLabel("Preparing transcription")
            Text(appState.meetingStartStatus ?? "Meeting transcription will start shortly.")
                .font(ImlaTheme.font(size: 12, weight: .semibold))
                .foregroundStyle(ImlaTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, ImlaTheme.spacing12)
        .padding(.vertical, 7)
        .background(ImlaTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var cancelMeetingPreparationButton: some View {
        iconButton("xmark", label: "Cancel") {
            controller.cancelMeetingPreparation()
        }
        .help("Cancel meeting preparation")
    }

    private var pauseResumeRecordingButton: some View {
        let isPaused = appState.isMeetingRecordingPaused
        return Button {
            controller.toggleMeetingRecordingPause()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(isPaused ? "Resume" : "Pause")
                    .font(ImlaTheme.font(size: 12, weight: .semibold))
            }
            .foregroundStyle(isPaused ? Color.white : ImlaTheme.textPrimary)
            .padding(.horizontal, ImlaTheme.spacing12)
            .padding(.vertical, 7)
            .background(isPaused ? ImlaTheme.accent : ImlaTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                    .strokeBorder(isPaused ? ImlaTheme.accent.opacity(0.35) : ImlaTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!appState.isMeetingRecording)
        .help(isPaused ? "Resume recording" : "Pause recording")
    }

    /// Shown on a finished meeting when no recording is active. A split control:
    /// the left segment resumes recording into this meeting artifact; the right
    /// chevron opens a menu that also offers starting a linked follow-up meeting.
    /// (Not `Menu(primaryAction:)` — with a plain custom label on macOS the
    /// chevron segment doesn't render, leaving the menu unreachable.)
    @ViewBuilder
    private func resumeRecordingButton(for meeting: MeetingRecord) -> some View {
        HStack(spacing: 0) {
            Button {
                controller.resumeFinishedMeeting(meetingID: meeting.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Resume")
                        .font(ImlaTheme.font(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, ImlaTheme.spacing12)
                .frame(height: ImlaTheme.controlHeight)
                .background(ImlaTheme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Resume recording")

            Menu {
                Button {
                    controller.resumeFinishedMeeting(meetingID: meeting.id)
                } label: {
                    Label("Resume recording", systemImage: "record.circle")
                }
                Button {
                    controller.startFollowUpMeeting(fromMeetingID: meeting.id)
                } label: {
                    Label("Start a follow-up", systemImage: "arrow.turn.down.right")
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 28, height: ImlaTheme.controlHeight)
                    .background(ImlaTheme.accent)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(ImlaTheme.backgroundBase.opacity(0.25))
                            .frame(width: 1, height: 18)
                    }
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("More resume options")
            .help("Resume recording, or start a follow-up meeting")
        }
        .fixedSize()
    }

    private var stopRecordingButton: some View {
        Button {
            if let meeting {
                flushTitleSave(meetingID: meeting.id)
            }
            controller.stopMeetingRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Stop")
                    .font(ImlaTheme.font(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, ImlaTheme.spacing12)
            .padding(.vertical, 7)
            .background(ImlaTheme.recording)
            .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!appState.isMeetingRecording)
        .help("Stop recording")
    }

    private var discardRecordingButton: some View {
        iconButton("xmark", label: "Discard") {
            controller.discardMeetingWithConfirmation()
        }
    }

    @ViewBuilder
    private func templateChip(for snapshot: MeetingTemplateSnapshot) -> some View {
        HStack(spacing: 5) {
            Image(systemName: iconName(for: snapshot))
                .font(.system(size: 10))
            Text(snapshot.name)
                .font(ImlaTheme.font(size: 11, weight: .medium))
                .lineLimit(1)
        }
        // Without this the chip is the flexible element beside a fixed-width metadata
        // string, so it collapses to just its icon when the row is tight.
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(ImlaTheme.accent)
        .padding(.horizontal, ImlaTheme.spacing8)
        .padding(.vertical, 4)
        .background(ImlaTheme.accentSubtle)
        .clipShape(Capsule())
    }

    /// Breadcrumb strip shown when this meeting is part of a follow-up thread:
    /// a link to the direct predecessor, total thread size, and direct follow-ups
    /// in chronological order. Root meetings show no predecessor link.
    @ViewBuilder
    private var threadBreadcrumb: some View {
        if let threadContext {
            VStack(alignment: .leading, spacing: 4) {
                if let predecessor = threadContext.predecessor {
                    threadLink(
                        icon: "arrow.turn.left.up",
                        text: "Follow-up to: \(predecessor.title) \u{00B7} \(MeetingBrowserLogic.formatStartTime(predecessor.startTime))",
                        targetID: predecessor.id
                    )
                }
                Text("Thread \u{00B7} \(threadContext.count) meetings")
                    .font(ImlaTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(ImlaTheme.textTertiary)
                switch threadContext.successors.count {
                case 0:
                    EmptyView()
                case 1:
                    if let successor = threadContext.successors.first {
                        threadLink(
                            icon: "arrow.turn.left.down",
                            text: "Followed by: \(successor.title) \u{00B7} \(MeetingBrowserLogic.formatStartTime(successor.startTime))",
                            targetID: successor.id
                        )
                    }
                default:
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Follow-ups (\(threadContext.successors.count))")
                            .font(ImlaTheme.font(size: 11, weight: .medium))
                            .foregroundStyle(ImlaTheme.textTertiary)
                        ForEach(threadContext.successors) { successor in
                            threadLink(
                                icon: "arrow.turn.left.down",
                                text: "\(successor.title) \u{00B7} \(MeetingBrowserLogic.formatStartTime(successor.startTime))",
                                targetID: successor.id
                            )
                        }
                    }
                }
            }
        }
    }

    private func threadLink(icon: String, text: String, targetID: Int64) -> some View {
        Button {
            if appState.meetingDetailReturnDestination == .timeline {
                controller.showTimelineMeetingDocument(id: targetID)
            } else {
                controller.showMeetingDocument(id: targetID)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(text)
                    .font(ImlaTheme.font(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(ImlaTheme.accent)
        }
        .buttonStyle(.plain)
        .help("Open this meeting")
    }

    @ViewBuilder
    private func folderPill(for meeting: MeetingRecord) -> some View {
        let currentFolder = meeting.folderID.flatMap { fid in
            appState.folders.first(where: { $0.id == fid })
        }
        let hasFolder = currentFolder != nil
        Button {
            showFolderPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: hasFolder ? "folder.fill" : "folder.badge.plus")
                    .font(.system(size: 10))
                Text(currentFolder?.name ?? "Add to folder")
                    .font(ImlaTheme.font(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(hasFolder ? ImlaTheme.accent : ImlaTheme.textSecondary)
            .padding(.horizontal, ImlaTheme.spacing8)
            .frame(height: ImlaTheme.controlHeight)
            .background(hasFolder ? ImlaTheme.accentSubtle : ImlaTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                    .strokeBorder(hasFolder ? Color.clear : ImlaTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(hasFolder ? "Change folder" : "Add to folder")
        .popover(isPresented: $showFolderPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if !appState.folders.isEmpty {
                    ForEach(appState.folders) { folder in
                        let isActive = meeting.folderID == folder.id
                        folderPopoverRow(icon: "folder", label: folder.name, isActive: isActive) {
                            controller.moveMeeting(id: meeting.id, toFolder: isActive ? nil : folder.id)
                            showFolderPopover = false
                        }
                    }
                    Divider().padding(.vertical, 4)
                }
                folderPopoverRow(icon: "folder.badge.plus", label: "New Folder...") {
                    showFolderPopover = false
                    newFolderName = ""
                    showNewFolderPrompt = true
                }
            }
            .padding(8)
            .frame(minWidth: 200)
        }
        .alert("New Folder", isPresented: $showNewFolderPrompt) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                controller.createFolderAndMoveMeeting(name: trimmed, meetingID: meeting.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a new folder and move this meeting into it.")
        }
    }

    @ViewBuilder
    private func folderPopoverRow(icon: String, label: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(label)
                    .font(ImlaTheme.callout())
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ImlaTheme.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var transcriptCTA: some View {
        HStack(spacing: ImlaTheme.spacing8) {
            if hasApiKey {
                Image(systemName: "sparkles")
                    .foregroundStyle(ImlaTheme.accent)
                Text("Use \(primarySummaryActionLabel) to turn this raw transcript into AI meeting notes and a cleaned-up title.")
                    .font(ImlaTheme.callout())
                    .foregroundStyle(ImlaTheme.textSecondary)
            } else {
                Image(systemName: "key.fill")
                    .foregroundStyle(ImlaTheme.accent)
                Text("Add your API key in Settings to generate meeting notes")
                    .font(ImlaTheme.callout())
                    .foregroundStyle(ImlaTheme.textSecondary)
                Spacer()
                Button("Open Settings") {
                    controller.openHistoryWindow(tab: .settings)
                }
                .font(ImlaTheme.font(size: 12, weight: .medium))
                .foregroundStyle(ImlaTheme.accent)
                .buttonStyle(.plain)
            }
        }
        .padding(ImlaTheme.spacing12)
        .background(ImlaTheme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
    }

    @ViewBuilder
    private func activeMeetingAudioWarningBanner(for meeting: MeetingRecord) -> some View {
        if meeting.status == .recording,
           let warning = appState.activeMeetingAudioWarning,
           warning.meetingID == meeting.id {
            HStack(alignment: .top, spacing: ImlaTheme.spacing8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.orange)
                Text(warning.message)
                    .font(ImlaTheme.callout())
                    .foregroundStyle(ImlaTheme.textPrimary)
                Spacer(minLength: ImlaTheme.spacing8)
            }
            .padding(ImlaTheme.spacing12)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private var hasApiKey: Bool {
        let config = appState.config
        if appState.selectedMeetingSummaryBackend == .chatGPT {
            return appState.isChatGPTAuthenticated
        } else if appState.selectedMeetingSummaryBackend == .openAI {
            return !config.openAIAPIKey.isEmpty || ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil
        } else if appState.selectedMeetingSummaryBackend == .ollama {
            return true
        } else if appState.selectedMeetingSummaryBackend == .lmStudio {
            return MeetingSummaryClient.lmStudioHasRequiredSettings(config: config)
        } else if appState.selectedMeetingSummaryBackend == .customLLM {
            return MeetingSummaryClient.customLLMHasRequiredSettings(config: config)
        } else {
            return !OpenRouterCredentialResolver.resolvedAPIKey(
                legacyAPIKey: config.openRouterAPIKey
            ).isEmpty
        }
    }

    private var primarySummaryActionLabel: String {
        guard let meeting else { return "Re-summarize" }
        return primarySummaryActionLabel(for: meeting)
    }

    private var copyButtonLabel: String {
        "Copy"
    }

    private var editButtonLabel: String {
        if isEditingNotes || isEditingTranscript {
            return "Done"
        }
        return documentMode == .transcript ? "Edit Transcript" : "Edit Notes"
    }

    private func primarySummaryActionLabel(for meeting: MeetingRecord) -> String {
        hasPendingTemplateChange(for: meeting) ? "Apply Template" : "Re-summarize"
    }

    private func activeCopyText(for meeting: MeetingRecord) -> String {
        switch documentMode {
        case .notes:
            return isEditingNotes ? editableNotes : Self.notesContent(for: meeting)
        case .transcript:
            return isEditingTranscript ? editableTranscript : meeting.displayTranscript
        case .chat:
            // Chat bubbles are individually selectable; copying the whole meeting from the
            // chat tab should still yield the transcript, which is what a user means here.
            return meeting.displayTranscript
        }
    }

    private func isRawTranscript(_ meeting: MeetingRecord) -> Bool {
        meeting.notesState != .structuredNotes
    }

    private func hasPendingTemplateChange(for meeting: MeetingRecord) -> Bool {
        resolvedPendingTemplateDefinition(for: meeting).id != controller.meetingTemplateSnapshot(for: meeting).id
    }

    private func labelForSelection(on meeting: MeetingRecord, appliedTemplate: MeetingTemplateSnapshot) -> String {
        if pendingTemplateID == appliedTemplate.id {
            return appliedTemplate.name
        }
        return resolvedPendingTemplateDefinition(for: meeting).title
    }

    private func iconName(forSelectionOn meeting: MeetingRecord, appliedTemplate: MeetingTemplateSnapshot) -> String {
        if pendingTemplateID == appliedTemplate.id {
            return iconName(for: appliedTemplate)
        }
        return resolvedPendingTemplateDefinition(for: meeting).icon
    }

    private func iconName(for snapshot: MeetingTemplateSnapshot) -> String {
        switch snapshot.kind {
        case .auto:
            return MeetingTemplates.auto.icon
        case .builtin, .custom:
            return MeetingTemplates.resolveDefinition(
                id: snapshot.id,
                customTemplates: appState.config.customMeetingTemplates
            ).icon
        }
    }

    static func notesContent(for meeting: MeetingRecord) -> String {
        if meeting.status == .noteOnly {
            return meeting.manualNotes
        }
        if meeting.notesState != .structuredNotes {
            return "# \(meeting.title)\n\n## Raw Transcript\n\n\(meeting.rawTranscript)"
        }
        return meeting.formattedNotes
    }

    private static func defaultDocumentMode(for meeting: MeetingRecord) -> MeetingDocumentMode {
        if meeting.status == .noteOnly || meeting.status == .recording || meeting.status == .processing || meeting.status == .failed {
            return .notes
        }
        return meeting.notesState == .structuredNotes
            ? MeetingDocumentMode.notes
            : MeetingDocumentMode.transcript
    }

    private func debounceSaveTitle(meetingID: Int64) {
        titleSaveTask?.cancel()
        let title = editableTitle
        let c = controller
        c.cacheMeetingTitle(id: meetingID, title: title)
        let item = DispatchWorkItem { c.updateMeetingTitle(id: meetingID, title: title) }
        titleSaveTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func flushTitleSave(meetingID: Int64) {
        titleSaveTask?.cancel()
        titleSaveTask = nil
        controller.updateMeetingTitle(id: meetingID, title: editableTitle)
    }

    private func debounceSaveNotes(meetingID: Int64) {
        notesSaveTask?.cancel()
        let notes = editableNotes
        let c = controller
        let item = DispatchWorkItem { c.updateMeetingNotes(id: meetingID, notes: notes) }
        notesSaveTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func debounceSaveTranscript(meetingID: Int64) {
        transcriptSaveTask?.cancel()
        let transcript = editableTranscript
        let c = controller
        let item = DispatchWorkItem { c.updateMeetingTranscript(id: meetingID, transcript: transcript) }
        transcriptSaveTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func saveManualNotes(meetingID: Int64, notes: String) {
        manualNotesSaveStatus = .saving
        controller.cacheMeetingManualNotes(id: meetingID, notes: notes)
        scheduleManualNotesSaveStatusCheck(meetingID: meetingID, notes: notes)
    }

    private func scheduleManualNotesSaveStatusCheck(meetingID: Int64, notes: String) {
        manualNotesSaveStatusTask?.cancel()
        let item = DispatchWorkItem {
            guard loadedMeetingID == meetingID else { return }
            guard editableManualNotes == notes else { return }
            if controller.hasPersistedMeetingManualNotes(id: meetingID, notes: notes) {
                manualNotesSaveStatus = .saved
            }
        }
        manualNotesSaveStatusTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: item)
    }

    private var summaryErrorBinding: Binding<Bool> {
        Binding(
            get: { summaryErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    summaryErrorMessage = nil
                }
            }
        )
    }

    private var retranscriptionErrorBinding: Binding<Bool> {
        Binding(
            get: { retranscriptionErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    retranscriptionErrorMessage = nil
                }
            }
        )
    }

    private var transcriptResummaryPromptBinding: Binding<Bool> {
        Binding(
            get: { transcriptResummaryPromptMeetingID != nil },
            set: { isPresented in
                if !isPresented {
                    transcriptResummaryPromptMeetingID = nil
                }
            }
        )
    }

    private static func shouldPromptForTranscriptResummary(
        hadStructuredNotes: Bool,
        originalTranscript: String?,
        editedTranscript: String
    ) -> Bool {
        guard hadStructuredNotes, let originalTranscript else { return false }
        return originalTranscript != editedTranscript
    }

    private func resummarizeAfterTranscriptEdit() {
        guard let meetingID = transcriptResummaryPromptMeetingID else { return }
        transcriptResummaryPromptMeetingID = nil
        guard let updatedMeeting = controller.meeting(id: meetingID) else { return }
        isSummarizing = true
        controller.resummarize(meeting: updatedMeeting) { [meetingID] result in
            isSummarizing = false
            switch result {
            case .success:
                if let refreshed = controller.meeting(id: meetingID) {
                    syncLocalState(with: refreshed)
                }
            case .failure(let error):
                summaryErrorMessage = error.localizedDescription
            }
        }
    }

    private func resolvedPendingTemplateDefinition(for meeting: MeetingRecord) -> MeetingTemplateDefinition {
        if let resolved = MeetingTemplates.resolveExactDefinition(
            id: pendingTemplateID,
            customTemplates: appState.config.customMeetingTemplates
        ) {
            return resolved
        }
        return MeetingTemplates.resolveDefinition(
            id: controller.meetingTemplateSnapshot(for: meeting).id,
            customTemplates: appState.config.customMeetingTemplates
        )
    }

    private func syncPendingTemplateSelectionIfNeeded(for meeting: MeetingRecord?) {
        guard let meeting else { return }
        guard MeetingTemplates.resolveExactDefinition(
            id: pendingTemplateID,
            customTemplates: appState.config.customMeetingTemplates
        ) == nil else {
            return
        }
        pendingTemplateID = controller.meetingTemplateSnapshot(for: meeting).id
    }

    private func syncLocalState(with meeting: MeetingRecord?) {
        let previousMeetingID = loadedMeetingID
        let meetingChanged = previousMeetingID != meeting?.id
        loadedMeetingID = meeting?.id
        threadContext = meeting.flatMap { controller.meetingThreadContext(for: $0.id) }
        editableTitle = meeting?.title ?? ""
        if meetingChanged || !isEditingNotes {
            editableNotes = meeting.map { Self.notesContent(for: $0) } ?? ""
        }
        if meetingChanged || !isEditingTranscript {
            editableTranscript = meeting?.rawTranscript ?? ""
        }
        if meetingChanged {
            editableManualNotes = meeting?.manualNotes ?? ""
            chatDraft = ""
            manualNotesSaveStatus = .saved
            transcriptResummaryPromptMeetingID = nil
            transcriptEditOriginalTranscript = nil
            transcriptEditHadStructuredNotes = false
        } else {
            syncManualNotesState(with: meeting)
        }
        pendingTemplateID = meeting.map { controller.meetingTemplateSnapshot(for: $0).id } ?? controller.defaultMeetingTemplate().id
        if meetingChanged {
            documentMode = meeting.map(Self.defaultDocumentMode(for:)) ?? .notes
            isEditingNotes = false
            isEditingTranscript = false
            showFolderPopover = false
            showNewFolderPrompt = false
            newFolderName = ""
        }
    }

    private func syncManualNotesState(with meeting: MeetingRecord?) {
        let persistedManualNotes = meeting?.manualNotes ?? ""
        if manualNotesSaveStatus == .saving, editableManualNotes != persistedManualNotes {
            return
        }
        editableManualNotes = persistedManualNotes
        manualNotesSaveStatus = .saved
    }

    private func formatMeta(_ meeting: MeetingRecord) -> String {
        let time = MeetingBrowserLogic.formatStartTime(meeting.startTime)
        let duration = formatDuration(meeting.durationSeconds)
        return "\(time)  \u{2022}  \(duration)  \u{2022}  \(meeting.wordCount) words"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        if rounded >= 3600 {
            return "\(rounded / 3600)h \((rounded % 3600) / 60)m"
        }
        if rounded >= 60 {
            let m = rounded / 60
            let s = rounded % 60
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        return "\(rounded)s"
    }
}

private extension View {
    func recordingControlsBackground() -> some View {
        padding(5)
            .background(ImlaTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                    .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
            )
    }

    @ViewBuilder
    func manualNotesEditorChrome(compact: Bool) -> some View {
        if compact {
            self
        } else {
            clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                        .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
                )
        }
    }
}

enum MeetingTitlePresentation {
    static func marqueeOffset(for text: String, distance: CGFloat) -> CGFloat {
        NaturalTextDirection.resolve(text) == .rightToLeft ? distance : -distance
    }
}

private struct MarqueeTitleTextField: View {
    @Binding var text: String
    var titleSize: CGFloat = 30
    let onSubmit: () -> Void
    let onTextChange: () -> Void

    @State private var isHovering = false
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var marqueeOffset: CGFloat = 0
    @State private var marqueeRunID = UUID()
    @FocusState private var isTitleFocused: Bool

    private var titleFont: Font { ImlaTheme.font(size: titleSize, weight: .bold) }

    private var displayText: String {
        text.isEmpty ? "Meeting Title" : text
    }

    var body: some View {
        let direction = NaturalTextDirection.resolve(displayText)

        ZStack(alignment: direction.frameAlignment) {
            TextField("Meeting Title", text: $text)
                .font(titleFont)
                .foregroundStyle(ImlaTheme.textPrimary)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .multilineTextAlignment(.leading)
                .environment(\.layoutDirection, direction.layoutDirection)
                .opacity(shouldShowMarquee ? 0 : 1)
                .focused($isTitleFocused)
                .onSubmit(onSubmit)
                .onChange(of: text) { _, _ in
                    onTextChange()
                    restartMarqueeIfNeeded()
                }
                .onChange(of: isTitleFocused) { _, _ in
                    restartMarqueeIfNeeded()
                }

            Text(displayText)
                .font(titleFont)
                .fontWeight(.bold)
                .foregroundStyle(ImlaTheme.textPrimary)
                .lineLimit(1)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: marqueeOffset)
                .opacity(shouldShowMarquee ? 1 : 0)
                .allowsHitTesting(false)
                .environment(\.layoutDirection, direction.layoutDirection)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: max(38, ceil(titleSize * 1.5)),
            alignment: direction.frameAlignment
        )
        .clipped()
        .contentShape(Rectangle())
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TitleContainerWidthPreferenceKey.self, value: proxy.size.width)
            }
        )
        .overlay(
            Text(displayText)
                .font(titleFont)
                .fontWeight(.bold)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .hidden()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: TitleContentWidthPreferenceKey.self, value: proxy.size.width)
                    }
                )
                .allowsHitTesting(false)
        )
        .onTapGesture {
            isTitleFocused = true
        }
        .onPreferenceChange(TitleContainerWidthPreferenceKey.self) { width in
            guard abs(containerWidth - width) > 0.5 else { return }
            containerWidth = width
            restartMarqueeIfNeeded()
        }
        .onPreferenceChange(TitleContentWidthPreferenceKey.self) { width in
            guard abs(contentWidth - width) > 0.5 else { return }
            contentWidth = width
            restartMarqueeIfNeeded()
        }
        .onHover { hovering in
            isHovering = hovering
            restartMarqueeIfNeeded()
        }
    }

    private var overflowDistance: CGFloat {
        max(contentWidth - containerWidth, 0)
    }

    private var shouldShowMarquee: Bool {
        containerWidth > 0 && isHovering && !isTitleFocused && overflowDistance > 24
    }

    private func restartMarqueeIfNeeded() {
        guard shouldShowMarquee else {
            if marqueeOffset != 0 {
                let runID = UUID()
                marqueeRunID = runID
                withAnimation(ImlaTheme.Motion.easedOut(0.18)) {
                    marqueeOffset = 0
                }
            }
            return
        }

        let runID = UUID()
        marqueeRunID = runID

        marqueeOffset = 0
        let distance = overflowDistance + 28
        let duration = min(max(Double(distance) / 42.0, 3.0), 12.0)
        // A marquee is pure movement, so Reduce Motion stops it rather than shortening it.
        // The title stays at its start offset and truncates, which is the still equivalent.
        guard !ImlaTheme.Motion.reduceMotion else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard marqueeRunID == runID, shouldShowMarquee else { return }
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                marqueeOffset = MeetingTitlePresentation.marqueeOffset(for: displayText, distance: distance)
            }
        }
    }
}

private struct TitleContainerWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TitleContentWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct TranscriptChatMessage: Identifiable, Equatable {
    let id: Int
    let timestamp: String?
    let speaker: String?
    let text: String

    var isUser: Bool {
        speaker?.localizedCaseInsensitiveCompare("You") == .orderedSame
    }

    var textDirection: NaturalTextDirection {
        NaturalTextDirection.resolve(text)
    }

    static func messages(from transcript: String, startingAt firstID: Int = 0) -> [TranscriptChatMessage] {
        let normalized = transcript.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var messages: [TranscriptChatMessage] = []
        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parsed = parseLine(line, id: firstID + messages.count)
            messages.append(parsed)
        }

        return messages
    }

    private static func parseLine(_ line: String, id: Int) -> TranscriptChatMessage {
        if line.hasPrefix("["),
           let timestampEnd = line.firstIndex(of: "]") {
            let timestamp = String(line[line.index(after: line.startIndex)..<timestampEnd])
            let remainderStart = line.index(after: timestampEnd)
            let remainder = line[remainderStart...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let speakerText = splitSpeakerAndText(remainder)
            return TranscriptChatMessage(
                id: id,
                timestamp: timestamp.isEmpty ? nil : timestamp,
                speaker: speakerText.speaker,
                text: speakerText.text
            )
        }

        let speakerText = splitSpeakerAndText(line)
        return TranscriptChatMessage(
            id: id,
            timestamp: nil,
            speaker: speakerText.speaker,
            text: speakerText.text
        )
    }

    private static func splitSpeakerAndText(_ text: String) -> (speaker: String?, text: String) {
        guard let separator = text.firstIndex(of: ":") else {
            return (nil, text)
        }

        let candidate = text[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLikelySpeakerLabel(candidate) else {
            return (nil, text)
        }

        let bodyStart = text.index(after: separator)
        let body = text[bodyStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (candidate, body.isEmpty ? text : body)
    }

    private static func isLikelySpeakerLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 32 else { return false }
        if label.localizedCaseInsensitiveCompare("You") == .orderedSame { return true }
        if label.localizedCaseInsensitiveCompare("Others") == .orderedSame { return true }
        if label.range(of: #"^Speaker\s+\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }
}

private struct MeetingTranscriptView: View {
    let transcript: String
    @State private var messages: [TranscriptChatMessage]

    init(transcript: String) {
        self.transcript = transcript
        _messages = State(initialValue: TranscriptChatMessage.messages(from: transcript))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ImlaTheme.spacing8) {
                if messages.isEmpty {
                    Text("No transcript available")
                        .font(ImlaTheme.body())
                        .foregroundStyle(ImlaTheme.textTertiary)
                        .frame(maxWidth: 860, alignment: .leading)
                        .padding(ImlaTheme.spacing24)
                } else {
                    ForEach(messages) { message in
                        TranscriptChatBubble(message: message)
                    }
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, ImlaTheme.spacing24)
            .padding(.vertical, ImlaTheme.spacing16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onChange(of: transcript) { _, newTranscript in
            messages = TranscriptChatMessage.messages(from: newTranscript)
        }
    }
}

struct TranscriptChatBubble: View {
    let message: TranscriptChatMessage

    var body: some View {
        let textDirection = message.textDirection

        HStack(alignment: .bottom, spacing: ImlaTheme.spacing8) {
            if message.isUser {
                Spacer(minLength: 80)
            }

            MeetingSelectableText(attributedText: MeetingSelectableTextContent.transcript(
                metadata: metadata,
                body: message.text,
                bodyPointSize: 14,
                isPartial: false
            ))
            .environment(\.layoutDirection, textDirection.layoutDirection)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, ImlaTheme.spacing12)
            .padding(.vertical, 8)
            .background(message.isUser ? ImlaTheme.accent.opacity(0.18) : ImlaTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous)
                    .strokeBorder(message.isUser ? ImlaTheme.accent.opacity(0.25) : ImlaTheme.surfaceBorder, lineWidth: 1)
            )
            .frame(maxWidth: 680, alignment: message.isUser ? .trailing : .leading)

            if !message.isUser {
                Spacer(minLength: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }

    private var metadata: String? {
        switch (message.speaker, message.timestamp) {
        case let (speaker?, timestamp?):
            return "\(speaker) \(timestamp)"
        case let (speaker?, nil):
            return speaker
        case let (nil, timestamp?):
            return timestamp
        case (nil, nil):
            return nil
        }
    }
}
