import SwiftUI
import MuesliCore

struct DictationsView: View {
    let appState: AppState
    let controller: MuesliController
    @State private var selectedFilter: HistoryDateFilter = .all
    @State private var selectedDictation: DictationRecord?
    @State private var audioOnlyDictations: [DictationAudioHistoryRecord] = []
    @State private var selectedAudioOnlySessionID: UUID?

    private var visibleAudioOnlyDictations: [DictationAudioHistoryRecord] {
        guard let cutoff = selectedFilter.fromDate() else { return audioOnlyDictations }
        return audioOnlyDictations.filter { $0.capturedAt >= cutoff }
    }

    private var groupedDictations: [(id: Date, header: String, records: [DictationRecord])] {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let dateHeaderFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale.current
            f.dateFormat = "EEE, d MMM"
            return f
        }()

        var groups: [(key: Date, header: String, records: [DictationRecord])] = []
        var currentDayStart: Date?
        var currentRecords: [DictationRecord] = []
        var currentHeader = ""

        for record in appState.dictationRows {
            let date = parseDate(record.timestamp) ?? now
            let dayStart = calendar.startOfDay(for: date)

            if dayStart != currentDayStart {
                if !currentRecords.isEmpty, let key = currentDayStart {
                    groups.append((key: key, header: currentHeader, records: currentRecords))
                }
                currentDayStart = dayStart
                currentRecords = []

                if dayStart == today {
                    currentHeader = "TODAY"
                } else if dayStart == yesterday {
                    currentHeader = "YESTERDAY"
                } else {
                    currentHeader = dateHeaderFormatter.string(from: date).uppercased()
                }
            }
            currentRecords.append(record)
        }
        if !currentRecords.isEmpty, let key = currentDayStart {
            groups.append((key: key, header: currentHeader, records: currentRecords))
        }

        return groups.map { (id: $0.key, header: $0.header, records: $0.records) }
    }

    var body: some View {
        VStack(spacing: 0) {
            StatsHeaderView(
                dictationStats: appState.filteredDictationStats,
                meetingStats: appState.meetingStats,
                showsMeetingStat: false,
                onSelect: { controller.openInsights(section: $0) }
            )

            if appState.config.showIOSCompanionPrompt {
                IPhoneBridgeCard(appState: appState, controller: controller)
                    .padding(.horizontal, MuesliTheme.spacing24)
                    .padding(.bottom, MuesliTheme.spacing12)
            }

            if appState.config.resolvedOnboardingUseCase.includesVoiceNotes {
                HStack {
                    Spacer()
                    voiceNoteButton
                }
                .padding(.horizontal, MuesliTheme.spacing24)
                .padding(.bottom, MuesliTheme.spacing12)
            }

            dictationFilterBar
                .padding(.horizontal, MuesliTheme.spacing24)
                .padding(.bottom, MuesliTheme.spacing12)

            if appState.dictationRows.isEmpty, visibleAudioOnlyDictations.isEmpty {
                Spacer()
                VStack(spacing: MuesliTheme.spacing12) {
                    Image(systemName: "mic.badge.plus")
                        .font(.system(size: 40, weight: .thin))
                        .foregroundStyle(MuesliTheme.textTertiary)
                    Text(emptyStateTitle)
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textSecondary)
                    Text(emptyStateInstruction)
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                        if !visibleAudioOnlyDictations.isEmpty {
                            audioOnlyHistorySection
                        }

                        ForEach(groupedDictations, id: \.id) { group in
                            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                                HStack {
                                    Text(group.header)
                                        .font(MuesliTheme.font(size: 12, weight: .semibold))
                                        .foregroundStyle(MuesliTheme.textTertiary)
                                        .padding(.leading, MuesliTheme.spacing4)
                                }

                                VStack(spacing: 1) {
                                    ForEach(group.records) { record in
                                        DictationRowView(
                                            record: record,
                                            timeOnly: formatTimeOnly(record.timestamp),
                                            onCopy: {
                                                controller.copyToClipboard(record.rawText)
                                            },
                                            onOpen: {
                                                selectedDictation = record
                                            },
                                            onCopyTrace: record.computerUseTrace == nil ? nil : {
                                                controller.copyToClipboard(ComputerUseTraceFormatter.debugText(for: record))
                                            },
                                            onDelete: {
                                                controller.deleteDictation(id: record.id)
                                            }
                                        )
                                        .contextMenu {
                                            Button {
                                                controller.copyToClipboard(record.rawText)
                                            } label: {
                                                Label("Copy", systemImage: "doc.on.doc")
                                            }
                                            if record.computerUseTrace != nil {
                                                Button {
                                                    controller.copyToClipboard(ComputerUseTraceFormatter.debugText(for: record))
                                                } label: {
                                                    Label("Copy CUA Trace", systemImage: "list.bullet.clipboard")
                                                }
                                            }
                                        }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                                )
                            }
                        }

                        // Infinite scroll trigger
                        if appState.hasMoreDictations {
                            Color.clear
                                .frame(height: 1)
                                .onAppear {
                                    controller.loadMoreDictations()
                                }
                        }
                    }
                    .padding(.horizontal, MuesliTheme.spacing24)
                    .padding(.bottom, MuesliTheme.spacing24)
                }
            }
        }
        .sheet(item: $selectedDictation) { record in
            DictationDetailView(
                record: record,
                onCopy: { controller.copyToClipboard(record.rawText) },
                onDelete: { controller.deleteDictation(id: record.id) },
                onClose: { selectedDictation = nil }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { selectedAudioOnlyRecord != nil },
                set: { if !$0 { selectedAudioOnlySessionID = nil } }
            )
        ) {
            if let record = selectedAudioOnlyRecord {
                AudioOnlyDictationDetailView(
                    record: record,
                    onDelete: { deleteAudioOnlyDictation(record.sessionID) },
                    onClose: { selectedAudioOnlySessionID = nil }
                )
            }
        }
        .task {
            await reloadAudioOnlyDictations()
        }
        .onChange(of: appState.dictationState) { _, state in
            guard state == .idle else { return }
            Task { await reloadAudioOnlyDictations() }
        }
    }

    private var selectedAudioOnlyRecord: DictationAudioHistoryRecord? {
        guard let selectedAudioOnlySessionID else { return nil }
        return audioOnlyDictations.first { $0.sessionID == selectedAudioOnlySessionID }
    }

    /// Audio-only sessions never became dictation rows, so they are listed apart from
    /// the transcript history and are deliberately excluded from sync/stats/CLI.
    private var audioOnlyHistorySection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("RECORDINGS WITHOUT TRANSCRIPT HISTORY")
                    .font(MuesliTheme.font(size: 12, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text("Local only · excluded from sync, statistics, CLI, and text export")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .padding(.leading, MuesliTheme.spacing4)

            VStack(spacing: 1) {
                ForEach(visibleAudioOnlyDictations, id: \.sessionID) { record in
                    AudioOnlyDictationRowView(
                        record: record,
                        onOpen: { selectedAudioOnlySessionID = record.sessionID },
                        onDelete: { deleteAudioOnlyDictation(record.sessionID) }
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
    }

    @MainActor
    private func reloadAudioOnlyDictations() async {
        audioOnlyDictations = await controller.audioOnlyDictationHistory()
    }

    private func deleteAudioOnlyDictation(_ sessionID: UUID) {
        controller.deleteAudioOnlyDictationHistory(sessionID: sessionID)
        audioOnlyDictations.removeAll { $0.sessionID == sessionID }
        if selectedAudioOnlySessionID == sessionID {
            selectedAudioOnlySessionID = nil
        }
    }

    private var emptyStateInstruction: String {
        if appState.dictationOriginFilter != .all
            || selectedFilter != .all
            || appState.dictationApplicationFilter != nil {
            return "Try another source, app, or time range"
        }
        return appState.config.resolvedOnboardingUseCase.includesVoiceNotes
            ? "Click Record Voice Note to capture your first note"
            : "Hold \(appState.config.dictationHotkey.label) to start dictating"
    }

    private var emptyStateTitle: String {
        if let application = appState.dictationApplicationFilter {
            return "No dictations for \(application.name)"
        }
        switch appState.dictationOriginFilter {
        case .all: return "No dictations yet"
        case .thisMac: return "No dictations from this Mac"
        case .fromIPhone: return "No dictations from iPhone"
        }
    }

    private var dictationFilterBar: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            RecordOriginPicker(selection: Binding(
                get: { appState.dictationOriginFilter },
                set: { controller.filterDictations(origin: $0) }
            ))
            if !appState.dictationTargetApplications.isEmpty || appState.dictationApplicationFilter != nil {
                TargetApplicationFilterMenu(
                    applications: appState.dictationTargetApplications,
                    selection: appState.dictationApplicationFilter,
                    onSelect: { controller.filterDictations(application: $0) }
                )
            }
            Spacer(minLength: 0)
            dateFilterButton
        }
    }

    private var voiceNoteButton: some View {
        let isRecording = appState.isVoiceNoteRecording
        return Button {
            controller.toggleVoiceNoteRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(isRecording ? "Stop Voice Note" : "Record Voice Note")
                    .font(MuesliTheme.font(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(isRecording ? MuesliTheme.recording : MuesliTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(appState.dictationState == .transcribing)
        .opacity(appState.dictationState == .transcribing ? 0.55 : 1)
    }

    @ViewBuilder
    private var dateFilterButton: some View {
        Menu {
            ForEach(availableFilters, id: \.self) { filter in
                Button {
                    selectedFilter = filter
                    applyFilter(filter)
                } label: {
                    HStack {
                        Text(filter.label)
                        if selectedFilter == filter {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11))
                if selectedFilter != .all {
                    Text(selectedFilter.label)
                        .font(MuesliTheme.font(size: 11))
                }
            }
            .foregroundStyle(selectedFilter != .all ? MuesliTheme.accent : MuesliTheme.textTertiary)
            .padding(.horizontal, selectedFilter != .all ? 8 : 0)
            .padding(.vertical, 3)
            .background(selectedFilter != .all ? MuesliTheme.accent.opacity(0.12) : Color.clear)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Build filter options dynamically based on the date range of actual data.
    private var availableFilters: [HistoryDateFilter] {
        var filters: [HistoryDateFilter] = [.all]
        let calendar = Calendar.current
        let now = Date()

        // Check oldest dictation to determine which filters make sense
        let oldestTextDate = appState.dictationRows.last.flatMap { parseDate($0.timestamp) }
            ?? appState.dictationRows.first.flatMap { parseDate($0.timestamp) }
        let oldestAudioDate = audioOnlyDictations.last?.capturedAt
        let oldestDate = [oldestTextDate, oldestAudioDate].compactMap { $0 }.min()

        guard let oldest = oldestDate else { return filters }
        let daysSinceOldest = calendar.dateComponents([.day], from: oldest, to: now).day ?? 0

        // Always show "Last 2 days" if data spans more than today
        if daysSinceOldest >= 1 { filters.append(.last2Days) }
        if daysSinceOldest >= 3 { filters.append(.lastWeek) }
        if daysSinceOldest >= 8 { filters.append(.last2Weeks) }
        if daysSinceOldest >= 15 { filters.append(.lastMonth) }
        if daysSinceOldest >= 31 { filters.append(.last3Months) }

        return filters
    }

    private func applyFilter(_ filter: HistoryDateFilter) {
        if filter == .all {
            controller.clearDictationFilter()
        } else {
            controller.filterDictations(from: filter.fromDate(), to: nil)
        }
    }

    // MARK: - Date parsing

    private static let parsers: [DateFormatterProtocol] = {
        let iso1 = ISO8601DateFormatter()
        iso1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        let local1: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            return f
        }()
        let local2: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return f
        }()
        return [iso1, iso2, local1, local2]
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "hh:mm a"
        return f
    }()

    private func parseDate(_ raw: String) -> Date? {
        for parser in Self.parsers {
            if let date = parser.date(from: raw) {
                return date
            }
        }
        return nil
    }

    private func formatTimeOnly(_ raw: String) -> String {
        guard let date = parseDate(raw) else {
            let clean = raw.replacingOccurrences(of: "T", with: " ")
            return clean.count > 5 ? String(clean.suffix(8).prefix(5)) : clean
        }
        return Self.timeFormatter.string(from: date)
    }
}

private protocol DateFormatterProtocol {
    func date(from string: String) -> Date?
}

extension DateFormatter: DateFormatterProtocol {}
extension ISO8601DateFormatter: DateFormatterProtocol {}
