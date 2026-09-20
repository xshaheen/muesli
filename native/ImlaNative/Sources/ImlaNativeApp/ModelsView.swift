import FluidAudio
import ImlaCore
import SwiftUI

struct ModelDownloadGenerationState: Equatable {
    private(set) var current: UUID?

    mutating func begin() -> UUID {
        let generation = UUID()
        current = generation
        return generation
    }

    func contains(_ generation: UUID) -> Bool {
        current == generation
    }

    @discardableResult
    mutating func clear(_ generation: UUID) -> Bool {
        guard current == generation else { return false }
        current = nil
        return true
    }
}

struct ModelsView: View {
    let appState: AppState
    let controller: ImlaController

    @State private var nemotron35UpdateAvailable = false
    @State private var downloadingModels: Set<String> = []
    @State private var downloadProgress: [String: Double] = [:]
    @State private var downloadMessages: [String: String] = [:]
    @State private var downloadSnapshots: [String: ModelDownloadProgress] = [:]
    @State private var downloadGenerations: [String: UUID] = [:]
    @State private var downloadedModels: Set<String> = []
    @State private var downloadTasks: [String: Task<Void, Never>] = [:]
    @State private var modelToDelete: BackendOption?
    @State private var selectedParakeetModel: String
    @State private var selectedWhisperModel: String
    @State private var selectedBodhanCoreModel: String
    @State private var selectedBodhanFlexModel: String
    @State private var showExperimental: Bool
    @State private var appleSpeechLanguageOptions: [AppleSpeechLanguageOption] = [.system]
    @State private var isLiveCaptionModelDownloaded = false
    @State private var isDownloadingLiveCaptionModel = false
    @State private var isCancellingLiveCaptionModelDownload = false
    @State private var liveCaptionDownloadProgress = 0.0
    @State private var liveCaptionDownloadTask: Task<Void, Never>?
    @State private var liveCaptionDownloadGeneration = ModelDownloadGenerationState()
    @State private var showDeleteLiveCaptionModelConfirmation = false
    @State private var retiredCaches: [RetiredASRBackendCache] = []

    // Post-processor state
    @State private var downloadingPostProcModels: Set<String> = []
    @State private var downloadProgressPostProc: [String: Double] = [:]
    @State private var downloadedPostProcModels: Set<String> = []
    @State private var downloadTasksPostProc: [String: Task<Void, Never>] = [:]
    @State private var postProcModelToDelete: PostProcessorOption?

    init(appState: AppState, controller: ImlaController) {
        self.appState = appState
        self.controller = controller

        let active = appState.selectedBackend
        _selectedParakeetModel = State(initialValue: BackendOption.parakeetFamily.contains(active) ? active.model : BackendOption.parakeetUnified.model)
        _selectedWhisperModel = State(initialValue: BackendOption.whisperFamily.contains(active) ? active.model : BackendOption.whisperSmall.model)
        let bodhan = BodhanModel(rawValue: active.model)
        _selectedBodhanCoreModel = State(initialValue: bodhan?.isCore == true ? active.model : BodhanModel.coreInt8.rawValue)
        _selectedBodhanFlexModel = State(initialValue: bodhan?.isCore == false ? active.model : BodhanModel.flexInt8.rawValue)
        _showExperimental = State(initialValue: appState.activeFeatureTourTarget == .experimentalModels)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: ImlaTheme.spacing24) {

                    Text("Choose the dictation, live meeting, cleanup, and Quill models that fit how you speak and work.")
                        .font(ImlaTheme.body())
                        .foregroundStyle(ImlaTheme.textSecondary)

                    Picker("Model category", selection: modelsCategorySelection) {
                        ForEach(ModelsCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .id(FeatureTourTarget.modelLibrary.rawValue)
                    .featureTourTarget(.modelLibrary)

                    // Above the category switch, not inside one arm: a retired backend can
                    // move the meeting transcription model while leaving dictation alone,
                    // and this picker has no meeting category, so a notice scoped to
                    // .dictation would never reach the user it was written for.
                    retiredBackendSection

                    selectedCategoryContent
                }
                .padding(.horizontal, ImlaTheme.spacing32)
            .padding(.top, ImlaTheme.pageTop)
            .padding(.bottom, ImlaTheme.spacing32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                revealFeatureTourTargetIfNeeded(using: proxy)
            }
            .onChange(of: activeFeatureTourTarget) { _, _ in
                // The reveal helper owns target filtering. A second allowlist here
                // can miss model-to-model transitions while this view stays mounted.
                revealFeatureTourTargetIfNeeded(using: proxy)
            }
        }
        .background(ImlaTheme.backgroundBase)
        .onAppear {
            checkDownloadedModels()
            checkDownloadedPostProcModels()
            isLiveCaptionModelDownloaded = MeetingLiveCaptionModelStore.isDownloaded()
            syncSelectionsFromActiveBackend()
            checkNemotron35Update()
            refreshRetiredCaches()
            loadAppleSpeechLanguageOptions()
        }
        .onChange(of: appState.selectedBackend.model) { _, _ in
            syncSelectionsFromActiveBackend()
        }
        .alert(
            "Delete \"\(modelToDelete?.label ?? "")\"?",
            isPresented: Binding(
                get: { modelToDelete != nil },
                set: { if !$0 { modelToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                modelToDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard let option = modelToDelete else { return }
                deleteModel(option)
                modelToDelete = nil
            }
        } message: {
            Text("The downloaded model files will be removed from this Mac. You can download the model again later.")
        }
        .alert(
            "Delete \"\(postProcModelToDelete?.label ?? "")\"?",
            isPresented: Binding(
                get: { postProcModelToDelete != nil },
                set: { if !$0 { postProcModelToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                postProcModelToDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard let option = postProcModelToDelete else { return }
                deletePostProcModel(option)
                postProcModelToDelete = nil
            }
        } message: {
            Text(postProcessorDeleteMessage)
        }
        .alert(
            "Delete \"\(MeetingLiveCaptionModelStore.label)\"?",
            isPresented: $showDeleteLiveCaptionModelConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteLiveCaptionModel()
            }
        } message: {
            Text("Live meetings will fall back to standard chunk-by-chunk captions until this model is downloaded again.")
        }
    }

    private var modelsCategorySelection: Binding<ModelsCategory> {
        Binding(
            get: { appState.selectedModelsCategory },
            set: { appState.selectedModelsCategory = $0 }
        )
    }

    private var postProcessorDeleteMessage: String {
        guard let option = postProcModelToDelete, !option.isDownloadable else {
            return "The downloaded model files will be removed from this Mac. You can download the model again later."
        }
        return "The downloaded model files will be removed from this Mac. This legacy model is no longer available to download, so deleting it is permanent."
    }

    @ViewBuilder
    private var selectedCategoryContent: some View {
        switch appState.selectedModelsCategory {
        case .dictation:
            ForEach(BackendOption.systemManaged, id: \.model) { option in
                let featureTourTarget: FeatureTourTarget? = option.backend == BackendOption.appleSpeechAnalyzer.backend
                    ? .appleSpeechCard
                    : nil
                modelCard(
                    option: option,
                    logo: logoForBackend(option),
                    downloadedLabel: "Available"
                )
                .id(featureTourTarget?.rawValue ?? option.model)
                .featureTourTarget(featureTourTarget)
            }

            familyCard(
                title: "Parakeet Family",
                subtitle: "The most responsive choices for everyday dictation, with multilingual and English-only options.",
                defaultBadge: "Recommended: Unified",
                logo: "nvidia-logo",
                selection: $selectedParakeetModel,
                options: BackendOption.parakeetFamily
            )
            .id(FeatureTourTarget.parakeetFamilyCard.rawValue)
            .featureTourTarget(.parakeetFamilyCard)

            familyCard(
                title: "Whisper",
                subtitle: "Dependable alternatives when you prefer Whisper's transcription style or need broader multilingual coverage.",
                defaultBadge: "Default: Small",
                logo: "openai-logo",
                selection: $selectedWhisperModel,
                options: BackendOption.whisperFamily
            )

            modelCard(option: .cohereTranscribe, logo: "cohere-logo")
            modelCard(option: .cohereArabic, logo: "cohere-logo")
            bodhanCard(selection: $selectedBodhanCoreModel, isCore: true)
            bodhanCard(selection: $selectedBodhanFlexModel, isCore: false)
                .id(FeatureTourTarget.bodhanFlexCard.rawValue)
                .featureTourTarget(.bodhanFlexCard)
            experimentalSection
            comingSoonSection
        case .streaming:
            streamingSection
        case .postProcessing:
            postProcessorSection
        case .quill:
            quillSection
        }
    }

    /// R3 and R4 land in one place: the user is told which removed model they were on
    /// and what replaced it, and offered the space its files are still holding.
    @ViewBuilder
    private var retiredBackendSection: some View {
        if let notice = appState.config.retiredASRBackendNotice {
            retiredCard(
                title: "\(notice.retiredLabel) was removed",
                body: notice.message,
                action: ("Got it", { controller.updateConfig { $0.retiredASRBackendNotice = nil } })
            )
        }

        ForEach(retiredCaches, id: \.backend) { cache in
            retiredCard(
                title: "\(cache.backend.label) files are still on this Mac",
                body: "Deleting them frees \(cache.sizeLabel). \(cache.backend.label) can no longer be selected, so nothing will need them again.",
                action: (
                    "Delete \(cache.sizeLabel)",
                    { deleteRetiredCache(cache) }
                )
            )
        }
    }

    private func retiredCard(
        title: String,
        body: String,
        action: (title: String, perform: () -> Void)
    ) -> some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing8) {
            Text(title)
                .font(ImlaTheme.headline())
                .foregroundStyle(ImlaTheme.textPrimary)

            Text(body)
                .font(ImlaTheme.caption())
                .foregroundStyle(ImlaTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action.title, action: action.perform)
                .buttonStyle(.plain)
                .font(ImlaTheme.font(size: 12, weight: .medium))
                .foregroundStyle(ImlaTheme.textSecondary)
                .padding(.horizontal, ImlaTheme.spacing12)
                .padding(.vertical, 4)
                .background(ImlaTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ImlaTheme.spacing16)
        .background(ImlaTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
        )
        .padding(.top, ImlaTheme.spacing8)
    }

    /// Sizing walks the cache directories, so it runs once when the tab appears rather
    /// than on every view update.
    private func refreshRetiredCaches() {
        Task.detached(priority: .utility) {
            let detected = RetiredASRBackendCache.detectAll()
            await MainActor.run { retiredCaches = detected }
        }
    }

    private func deleteRetiredCache(_ cache: RetiredASRBackendCache) {
        retiredCaches.removeAll { $0.backend == cache.backend }
        Task {
            do {
                try await ModelDeletionExecutor.execute(
                    .retiredCache(directories: cache.directories)
                )
            } catch {
                fputs("[imla-native] retired cache delete failed for \(cache.backend.rawValue): \(error)\n", stderr)
                await MainActor.run { refreshRetiredCaches() }
            }
        }
    }

    @ViewBuilder
    private var comingSoonSection: some View {
        if !BackendOption.comingSoon.isEmpty {
            VStack(alignment: .leading, spacing: ImlaTheme.spacing8) {
                Text("COMING SOON")
                    .font(ImlaTheme.font(size: 11, weight: .semibold))
                    .foregroundStyle(ImlaTheme.textTertiary)
                    .textCase(.uppercase)
                    .padding(.leading, 2)
                    .padding(.top, ImlaTheme.spacing8)

                VStack(spacing: ImlaTheme.spacing12) {
                    ForEach(BackendOption.comingSoon, id: \.model) { option in
                        comingSoonCard(option: option)
                    }
                }
            }
        }
    }

    private var activeFeatureTourTarget: FeatureTourTarget? {
        appState.activeFeatureTourTarget
    }

    private func revealFeatureTourTargetIfNeeded(using proxy: ScrollViewProxy) {
        let target: FeatureTourTarget
        switch activeFeatureTourTarget {
        case .modelLibrary:
            target = .modelLibrary
            appState.selectedModelsCategory = .dictation
        case .appleSpeechCard:
            target = .appleSpeechCard
            appState.selectedModelsCategory = .dictation
        case .parakeetFamilyCard:
            target = .parakeetFamilyCard
            appState.selectedModelsCategory = .dictation
        case .bodhanFlexCard:
            target = .bodhanFlexCard
            appState.selectedModelsCategory = .dictation
        case .streamingModels:
            target = .streamingModels
            appState.selectedModelsCategory = .streaming
        case .experimentalModels:
            target = .experimentalModels
            appState.selectedModelsCategory = .dictation
            showExperimental = true
        default:
            return
        }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(target.rawValue, anchor: .center)
        }
    }

    private var streamingSection: some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
            VStack(alignment: .leading, spacing: ImlaTheme.spacing4) {
                Text("LIVE MEETINGS")
                    .font(ImlaTheme.font(size: 11, weight: .semibold))
                    .foregroundStyle(ImlaTheme.textTertiary)

                Text("Choose how words appear while a meeting is in progress. Apple Speech and Nemotron can also create the final transcript; Parakeet provides a provisional preview.")
                    .font(ImlaTheme.caption())
                    .foregroundStyle(ImlaTheme.textSecondary)
            }
            .padding(.leading, 2)
            .padding(.top, ImlaTheme.spacing8)
            .id(FeatureTourTarget.streamingModels.rawValue)
            .featureTourTarget(.streamingModels)

            if BackendOption.systemManaged.contains(.appleSpeechAnalyzer) {
                let option = BackendOption.appleSpeechAnalyzer
                modelCard(
                    option: option,
                    logo: logoForBackend(option),
                    isActive: appState.config.enableLiveStreamingPartials
                        && appState.config.resolvedMeetingLiveCaptionBackend == .appleSpeech,
                    onSetActive: {
                        controller.updateConfig {
                            $0.meetingLiveCaptionBackend = MeetingLiveCaptionBackend.appleSpeech.rawValue
                            $0.enableLiveStreamingPartials = true
                        }
                    },
                    description: "Apple's private, on-device streaming transcription on macOS 26. Finalized speech becomes your saved transcript; your regular meeting model recovers any audio the live stream could not finish.",
                    downloadedLabel: "Available"
                )
            }

            ForEach(BackendOption.streaming, id: \.model) { option in
                if let liveCaptionBackend = MeetingLiveCaptionBackend(rawValue: option.backend) {
                    modelCard(
                        option: option,
                        logo: logoForBackend(option),
                        isActive: appState.config.enableLiveStreamingPartials
                            && appState.config.resolvedMeetingLiveCaptionBackend == liveCaptionBackend,
                        onSetActive: {
                            controller.updateConfig {
                                $0.meetingLiveCaptionBackend = liveCaptionBackend.rawValue
                                $0.enableLiveStreamingPartials = true
                            }
                        }
                    )
                }
            }

            liveCaptionModelCard
        }
    }

    private var liveCaptionModelCard: some View {
        let isActive = isLiveCaptionModelDownloaded
            && appState.config.enableLiveStreamingPartials
            && appState.config.resolvedMeetingLiveCaptionBackend == .parakeetRealtimeEOU

        return VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
            HStack(alignment: .top, spacing: ImlaTheme.spacing12) {
                brandLogo("nvidia-logo")
                VStack(alignment: .leading, spacing: ImlaTheme.spacing4) {
                    HStack(spacing: ImlaTheme.spacing8) {
                        Text(MeetingLiveCaptionModelStore.label)
                            .font(ImlaTheme.headline())
                            .foregroundStyle(ImlaTheme.textPrimary)

                        Text(MeetingLiveCaptionModelStore.sizeLabel)
                            .font(ImlaTheme.caption())
                            .foregroundStyle(ImlaTheme.textTertiary)
                    }

                    Text("Fast English captions while a meeting is in progress. They are a provisional preview; your regular meeting model creates the transcript you keep.")
                        .font(ImlaTheme.caption())
                        .foregroundStyle(ImlaTheme.textSecondary)
                }

                Spacer()

                if isActive {
                    Text("Active")
                        .font(ImlaTheme.font(size: 11, weight: .semibold))
                        .foregroundStyle(ImlaTheme.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ImlaTheme.success.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else if isLiveCaptionModelDownloaded {
                    Text("Ready")
                        .font(ImlaTheme.font(size: 11, weight: .medium))
                        .foregroundStyle(ImlaTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ImlaTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }

            if isDownloadingLiveCaptionModel {
                downloadProgressView(
                    for: MeetingLiveCaptionModelStore.modelID,
                    fallbackProgress: liveCaptionDownloadProgress
                )
            }

            HStack(spacing: ImlaTheme.spacing8) {
                if isDownloadingLiveCaptionModel {
                    Button(isCancellingLiveCaptionModelDownload ? "Pausing…" : "Cancel") {
                        guard !isCancellingLiveCaptionModelDownload else { return }
                        let task = liveCaptionDownloadTask
                        task?.cancel()
                        let cancellationGeneration = liveCaptionDownloadGeneration.begin()
                        isCancellingLiveCaptionModelDownload = true
                        Task {
                            let shouldCancel = await MainActor.run {
                                liveCaptionDownloadGeneration.contains(cancellationGeneration)
                            }
                            guard shouldCancel else { return }
                            await ManagedASRModelDownloader.cancelAndWait(
                                modelID: MeetingLiveCaptionModelStore.modelID
                            )
                            _ = await task?.value
                            await MainActor.run {
                                guard liveCaptionDownloadGeneration.clear(cancellationGeneration) else { return }
                                liveCaptionDownloadTask = nil
                                isDownloadingLiveCaptionModel = false
                                isCancellingLiveCaptionModelDownload = false
                                liveCaptionDownloadProgress = 0
                            }
                        }
                        liveCaptionDownloadProgress = 0
                        if let snapshot = downloadSnapshots[MeetingLiveCaptionModelStore.modelID] {
                            downloadSnapshots[MeetingLiveCaptionModelStore.modelID] = snapshot.replacing(
                                phase: .paused,
                                message: "Paused — select Download to resume"
                            )
                        }
                    }
                    .disabled(isCancellingLiveCaptionModelDownload)
                    .buttonStyle(.plain)
                    .font(ImlaTheme.font(size: 12, weight: .medium))
                    .foregroundStyle(ImlaTheme.textSecondary)
                } else if isLiveCaptionModelDownloaded {
                    if !isActive {
                        Button("Set Active") {
                            controller.updateConfig {
                                $0.meetingLiveCaptionBackend = MeetingLiveCaptionBackend.parakeetRealtimeEOU.rawValue
                                $0.enableLiveStreamingPartials = true
                            }
                        }
                        .buttonStyle(.plain)
                        .font(ImlaTheme.font(size: 12, weight: .medium))
                        .foregroundStyle(ImlaTheme.accent)
                        .padding(.horizontal, ImlaTheme.spacing12)
                        .padding(.vertical, 4)
                        .background(ImlaTheme.accentSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
                    }

                    Button {
                        showDeleteLiveCaptionModelConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(ImlaTheme.danger.opacity(0.6))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Delete live caption model")
                } else {
                    Button("Download") {
                        startLiveCaptionModelDownload()
                    }
                    .buttonStyle(.plain)
                    .font(ImlaTheme.font(size: 12, weight: .medium))
                    .foregroundStyle(ImlaTheme.accent)
                    .padding(.horizontal, ImlaTheme.spacing12)
                    .padding(.vertical, 4)
                    .background(ImlaTheme.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
                }
            }
        }
        .padding(ImlaTheme.spacing16)
        .background(ImlaTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(isActive ? ImlaTheme.accent.opacity(0.6) : ImlaTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func startLiveCaptionModelDownload() {
        guard !isDownloadingLiveCaptionModel else { return }
        isCancellingLiveCaptionModelDownload = false
        isDownloadingLiveCaptionModel = true
        liveCaptionDownloadProgress = 0
        downloadSnapshots.removeValue(forKey: MeetingLiveCaptionModelStore.modelID)
        let generation = liveCaptionDownloadGeneration.begin()
        liveCaptionDownloadTask = Task {
            do {
                try await MeetingLiveCaptionModelStore.download { progress in
                    Task { @MainActor in
                        guard liveCaptionDownloadGeneration.contains(generation) else { return }
                        liveCaptionDownloadProgress = progress
                    }
                } progressSnapshot: { snapshot in
                    Task { @MainActor in
                        guard liveCaptionDownloadGeneration.contains(generation) else { return }
                        downloadSnapshots[MeetingLiveCaptionModelStore.modelID] = snapshot
                        if let fraction = snapshot.fractionCompleted {
                            liveCaptionDownloadProgress = fraction
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                let accepted = await MainActor.run {
                    guard liveCaptionDownloadGeneration.contains(generation) else { return false }
                    isLiveCaptionModelDownloaded = true
                    return true
                }
                guard accepted else { return }
            } catch is CancellationError {
                // Cancellation is an expected user action.
            } catch {
                fputs("[imla-native] live caption model download failed: \(error)\n", stderr)
            }
            await MainActor.run {
                guard liveCaptionDownloadGeneration.clear(generation) else { return }
                isDownloadingLiveCaptionModel = false
                isCancellingLiveCaptionModelDownload = false
                liveCaptionDownloadProgress = 0
                liveCaptionDownloadTask = nil
                if isLiveCaptionModelDownloaded {
                    downloadSnapshots.removeValue(forKey: MeetingLiveCaptionModelStore.modelID)
                }
            }
        }
    }

    private func deleteLiveCaptionModel() {
        Task {
            do {
                try await ModelDeletionExecutor.execute(.liveCaption)
                isLiveCaptionModelDownloaded = false
                if appState.config.resolvedMeetingLiveCaptionBackend == .parakeetRealtimeEOU {
                    controller.updateConfig { $0.enableLiveStreamingPartials = false }
                }
            } catch {
                fputs("[imla-native] live caption model delete failed: \(error)\n", stderr)
            }
        }
    }

    private var experimentalSection: some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
            Button {
                showExperimental.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: ImlaTheme.spacing12) {
                    VStack(alignment: .leading, spacing: ImlaTheme.spacing4) {
                        HStack(spacing: 6) {
                            Image(systemName: showExperimental ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(ImlaTheme.textTertiary)

                            Text("Experimental")
                                .font(ImlaTheme.font(size: 14, weight: .semibold))
                                .foregroundStyle(ImlaTheme.textSecondary)
                        }

                        Text("Early models for specific languages and evaluation. Expect less consistent transcripts, and try them with your own voice before relying on them.")
                            .font(ImlaTheme.font(size: 12, weight: .medium))
                            .foregroundStyle(ImlaTheme.textPrimary)
                            .opacity(0.8)
                    }

                    Spacer()

                    Text("Early access")
                        .font(ImlaTheme.font(size: 10, weight: .semibold))
                        .foregroundStyle(ImlaTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(ImlaTheme.surfacePrimary)
                        .clipShape(Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .featureTourTarget(.experimentalModels)

            if showExperimental {
                VStack(spacing: ImlaTheme.spacing12) {
                    ForEach(BackendOption.experimental, id: \.model) { option in
                        if !appState.selectedPostProcessorBackend.isCompatible(with: option) {
                            modelCard(
                                option: option,
                                logo: logoForBackend(option),
                                downloadedLabel: "Used for Cleanup",
                                activationDisabledReason: "Unavailable while Gemma 4 is selected for cleanup. Choose another cleanup backend first."
                            )
                        } else {
                            modelCard(option: option, logo: logoForBackend(option))
                        }
                    }
                }
            }
        }
        .padding(ImlaTheme.spacing16)
        .background(ImlaTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(ImlaTheme.surfaceBorder, lineWidth: 1)
        )
        .id(FeatureTourTarget.experimentalModels.rawValue)
    }

    /// Bodhan ships Core and Flex variants in INT8 and FP16; the card shows the
    /// variant matching the current precision selection.
    @ViewBuilder
    private func bodhanCard(selection: Binding<String>, isCore: Bool) -> some View {
        let variants = BackendOption.bodhanFamily.filter { BodhanModel(rawValue: $0.model)?.isCore == isCore }
        if let selected = variants.first(where: { $0.model == selection.wrappedValue }) ?? variants.first {
            modelCard(option: selected, logo: "bodhan-logo",
                         title: isCore ? "Bodhan Core" : "Bodhan Flex",
                         precisionSelection: selection)
        }
    }

    private var appleSpeechLanguageSelection: Binding<String> {
        Binding(
            get: { appState.config.resolvedAppleSpeechLanguage },
            set: { controller.selectAppleSpeechLanguage($0) }
        )
    }

    private var postProcessorSection: some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
            VStack(alignment: .leading, spacing: ImlaTheme.spacing4) {
                Text("CLEANUP")
                    .font(ImlaTheme.font(size: 11, weight: .semibold))
                    .foregroundStyle(ImlaTheme.textTertiary)
                    .textCase(.uppercase)
                    .padding(.leading, 2)

                Text("Optional cleanup after transcription. Use it to remove filler words, follow spoken corrections, format lists, and fix obvious dictation errors.")
                    .font(ImlaTheme.font(size: 12, weight: .medium))
                    .foregroundStyle(ImlaTheme.textSecondary)
                    .padding(.leading, 2)
            }
            .padding(.top, ImlaTheme.spacing8)

            VStack(spacing: ImlaTheme.spacing12) {
                ForEach(Gemma4LiteRTModel.allCases) { model in
                    gemmaCleanupModelCard(model)
                }

                ForEach(displayedPostProcessorOptions) { option in
                    postProcModelCard(option)
                }
            }
        }
    }

    private var quillSection: some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
            Text("QUILL")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ImlaTheme.textTertiary)
            Text("Rewrite selected text or generate text at the cursor with a local model. Download a model, choose Use for Quill, then enable Quill in Settings. These downloads are shared with cleanup.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ImlaTheme.textSecondary)
            ForEach(Gemma4LiteRTModel.allCases) { model in
                gemmaCleanupModelCard(model, forQuill: true)
            }
            ForEach(displayedPostProcessorOptions.filter(\.supportsQuil)) { option in
                postProcModelCard(option, forQuill: true)
            }
        }
        .padding(.top, ImlaTheme.spacing8)
    }

    private func selectQuillModel(backend: TranscriptCleanupBackendOption, model: String) {
        controller.updateConfig {
            $0.quilBackend = backend.backend
            $0.quilModel = model
        }
        if appState.config.enableQuilMode {
            _ = controller.ensureQuilModelIsAvailable()
        }
    }

    private func gemmaCleanupModelCard(_ model: Gemma4LiteRTModel, forQuill: Bool = false) -> some View {
        let option = BackendOption.gemma4LiteRT(model)
        let isDownloaded = downloadedModels.contains(option.model)
        let isCompatible = forQuill || TranscriptCleanupBackendOption.gemma4LiteRT
            .isCompatible(with: appState.selectedBackend)

        return modelCard(
            option: option,
            logo: "google-logo",
            isActive: isDownloaded
                && (forQuill
                    ? appState.config.quilBackend == TranscriptCleanupBackendOption.gemma4LiteRT.backend && appState.config.quilModel == model.repoID
                    : appState.selectedPostProcessorBackend == .gemma4LiteRT && appState.config.postProcessorGemmaModel == model.repoID),
            onSetActive: {
                if forQuill {
                    selectQuillModel(backend: .gemma4LiteRT, model: model.repoID)
                } else {
                    controller.selectGemma4PostProcessor(model)
                }
            },
            description: forQuill
                ? "An experimental local model for rewriting and generating text with Quill. Shares its download with dictation and cleanup."
                : "An experimental local option for filler removal, formatting, and obvious transcript errors. It shares the \(model.label) download with dictation and Quill.",
            activeLabel: forQuill ? "Quill Selected" : "Cleanup Active",
            downloadedLabel: isCompatible ? "Downloaded" : "Used for Dictation",
            actionTitle: forQuill ? "Use for Quill" : "Use for Cleanup",
            activationDisabledReason: isCompatible
                ? nil
                : "Unavailable while Gemma 4 is selected for dictation. Choose another dictation model first."
        )
    }

    private func postProcModelCard(_ option: PostProcessorOption, forQuill: Bool = false) -> some View {
        let isDownloaded = downloadedPostProcModels.contains(option.id)
        let isActive = isDownloaded && (forQuill
            ? appState.config.quilBackend == TranscriptCleanupBackendOption.local.backend && appState.config.quilModel == option.id
            : appState.activePostProcessor.id == option.id)
        let isDownloading = downloadingPostProcModels.contains(option.id)
        let progress = downloadProgressPostProc[option.id] ?? 0
        let showsDownloadStatus = shouldShowDownloadStatus(for: option.id, isDownloading: isDownloading)

        return VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
            HStack(alignment: .top, spacing: ImlaTheme.spacing12) {
                brandLogo(option.logoResourceName)
                VStack(alignment: .leading, spacing: ImlaTheme.spacing4) {
                    HStack(spacing: ImlaTheme.spacing8) {
                        Text(option.label)
                            .font(ImlaTheme.headline())
                            .foregroundStyle(ImlaTheme.textPrimary)

                        Text(option.sizeLabel)
                            .font(ImlaTheme.caption())
                            .foregroundStyle(ImlaTheme.textTertiary)
                    }

                    Text(forQuill ? "A local model for rewriting selected text and generating text at the cursor. Shares its download with cleanup." : option.description)
                        .font(ImlaTheme.caption())
                        .foregroundStyle(ImlaTheme.textSecondary)
                }

                Spacer()

                if isActive {
                    Text(forQuill ? "Quill Selected" : "Active")
                        .font(ImlaTheme.font(size: 11, weight: .semibold))
                        .foregroundStyle(ImlaTheme.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ImlaTheme.success.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else if isDownloaded {
                    Text("Downloaded")
                        .font(ImlaTheme.font(size: 11, weight: .medium))
                        .foregroundStyle(ImlaTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ImlaTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }

            if showsDownloadStatus {
                downloadProgressView(
                    for: option.id,
                    fallbackProgress: progress,
                    fallbackMessage: downloadMessages[option.id],
                    isDownloading: isDownloading
                )
            }

            HStack(spacing: ImlaTheme.spacing8) {
                if isDownloading {
                    Button("Pause") {
                        cancelPostProcDownload(option)
                    }
                    .buttonStyle(.plain)
                    .font(ImlaTheme.font(size: 12, weight: .medium))
                    .foregroundStyle(ImlaTheme.textSecondary)
                    .padding(.horizontal, ImlaTheme.spacing12)
                    .padding(.vertical, 4)
                    .background(ImlaTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
                } else if isDownloaded {
                    if !isActive {
                        Button(forQuill ? "Use for Quill" : "Set Active") {
                            if forQuill {
                                selectQuillModel(backend: .local, model: option.id)
                            } else {
                                controller.selectPostProcessor(option)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(ImlaTheme.font(size: 12, weight: .medium))
                        .foregroundStyle(ImlaTheme.accent)
                        .padding(.horizontal, ImlaTheme.spacing12)
                        .padding(.vertical, 4)
                        .background(ImlaTheme.accentSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
                    }

                    Button {
                        postProcModelToDelete = option
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(ImlaTheme.danger.opacity(0.6))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                } else if option.isDownloadable {
                    Button("Download") {
                        startPostProcDownload(option, forQuill: forQuill)
                    }
                    .buttonStyle(.plain)
                    .font(ImlaTheme.font(size: 12, weight: .medium))
                    .foregroundStyle(ImlaTheme.accent)
                    .padding(.horizontal, ImlaTheme.spacing12)
                    .padding(.vertical, 4)
                    .background(ImlaTheme.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
                } else {
                    Text("No longer available")
                        .font(ImlaTheme.caption())
                        .foregroundStyle(ImlaTheme.textTertiary)
                }
            }
        }
        .padding(ImlaTheme.spacing16)
        .background(ImlaTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(isActive ? ImlaTheme.accent.opacity(0.5) : ImlaTheme.surfaceBorder, lineWidth: isActive ? 1.5 : 1)
        )
    }

    private func familyCard(
        title: String,
        subtitle: String,
        defaultBadge: String,
        logo: String? = nil,
        selection: Binding<String>,
        options: [BackendOption]
    ) -> some View {
        let selectedOption = options.first(where: { $0.model == selection.wrappedValue }) ?? options[0]
        let isActive = appState.selectedBackend == selectedOption
        let isDownloaded = downloadedModels.contains(selectedOption.model)
        let isDownloading = downloadingModels.contains(selectedOption.model)
        let progress = downloadProgress[selectedOption.model] ?? 0
        let showsDownloadStatus = shouldShowDownloadStatus(for: selectedOption.model, isDownloading: isDownloading)
        let incompatibilityReason = selectedOption.incompatibilityReason()

        return VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
            HStack(alignment: .top, spacing: ImlaTheme.spacing12) {
                brandLogo(logo)
                VStack(alignment: .leading, spacing: ImlaTheme.spacing4) {
                    HStack(spacing: ImlaTheme.spacing8) {
                        Text(title)
                            .font(ImlaTheme.headline())
                            .foregroundStyle(ImlaTheme.textPrimary)

                        Text(defaultBadge)
                            .font(ImlaTheme.font(size: 10, weight: .semibold))
                            .foregroundStyle(ImlaTheme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(ImlaTheme.accentSubtle)
                            .clipShape(Capsule())
                    }

                    Text(subtitle)
                        .font(ImlaTheme.caption())
                        .foregroundStyle(ImlaTheme.textSecondary)
                }

                Spacer()

                familyStatusBadge(isActive: isActive, isDownloaded: isDownloaded)
            }

            HStack(alignment: .center, spacing: ImlaTheme.spacing12) {
                Text("Variant")
                    .font(ImlaTheme.caption())
                    .foregroundStyle(ImlaTheme.textTertiary)
                    .frame(width: 52, alignment: .leading)

                Picker("", selection: selection) {
                    ForEach(options, id: \.model) { option in
                        Text(option.label).tag(option.model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220, alignment: .leading)
                .disabled(incompatibilityReason != nil)

                Text(selectedOption.sizeLabel)
                    .font(ImlaTheme.caption())
                    .foregroundStyle(ImlaTheme.textTertiary)
            }

            Text(selectedOption.description)
                .font(ImlaTheme.caption())
                .foregroundStyle(incompatibilityReason == nil ? ImlaTheme.textSecondary : ImlaTheme.textTertiary)

            HStack(alignment: .top, spacing: ImlaTheme.spacing12) {
                Text("Language")
                    .font(ImlaTheme.caption())
                    .foregroundStyle(ImlaTheme.textTertiary)
                    .frame(width: 64, alignment: .leading)

                Text(appState.config.dictationLanguageProfile.presentation(for: selectedOption).explanation)
                    .font(ImlaTheme.caption())
                    .foregroundStyle(ImlaTheme.textSecondary)
                    .frame(maxWidth: 300, alignment: .leading)
            }

            // Parakeet's language is a script filter rather than a spoken-language
            // pin, but the language profile is still the authority that chooses it,
            // so the card explains the profile's decision instead of offering a
            // second control that the profile would override.
            if selectedOption.backend == BackendOption.parakeetMultilingual.backend {
                Text("Script filter: keeps the chosen language's writing script in the transcript. Parakeet v3 only — v2 ignores this setting.")
                    .font(ImlaTheme.caption())
                    .foregroundStyle(ImlaTheme.textTertiary)
            }

            if showsDownloadStatus, incompatibilityReason == nil {
                downloadProgressView(
                    for: selectedOption.model,
                    fallbackProgress: progress,
                    fallbackMessage: downloadMessages[selectedOption.model],
                    isDownloading: isDownloading
                )
            }

            if let incompatibilityReason {
                Label(incompatibilityReason, systemImage: "exclamationmark.triangle")
                    .font(ImlaTheme.caption())
                    .foregroundStyle(ImlaTheme.textTertiary)
            }

            actionButtons(
                for: selectedOption,
                isActive: isActive,
                isDownloaded: isDownloaded,
                isDownloading: isDownloading,
                incompatibilityReason: incompatibilityReason
            )
        }
        .padding(ImlaTheme.spacing16)
        .background(ImlaTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(isActive ? ImlaTheme.accent.opacity(0.5) : ImlaTheme.surfaceBorder, lineWidth: isActive ? 1.5 : 1)
        )
    }

    @ViewBuilder
    private func familyStatusBadge(isActive: Bool, isDownloaded: Bool) -> some View {
        if isActive {
            Text("Active")
                .font(ImlaTheme.font(size: 11, weight: .semibold))
                .foregroundStyle(ImlaTheme.success)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(ImlaTheme.success.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else if isDownloaded {
            Text("Downloaded")
                .font(ImlaTheme.font(size: 11, weight: .medium))
                .foregroundStyle(ImlaTheme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(ImlaTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    @ViewBuilder
    private func downloadProgressView(
        for modelID: String,
        fallbackProgress: Double,
        fallbackMessage: String? = nil,
        isDownloading: Bool = true
    ) -> some View {
        if let snapshot = downloadSnapshots[modelID] {
            VStack(alignment: .leading, spacing: 4) {
                if snapshot.phase != .preparing {
                    ProgressView(value: snapshot.fractionCompleted ?? fallbackProgress)
                        .tint(ImlaTheme.accent)
                }

                if let currentFile = snapshot.currentFile?.split(separator: "/").last.map(String.init), !currentFile.isEmpty {
                    Text("\(downloadPhaseLabel(snapshot.phase)): \(currentFile)")
                        .font(ImlaTheme.font(size: 11, weight: .medium))
                        .foregroundStyle(ImlaTheme.textSecondary)
                } else {
                    Text(snapshot.message ?? downloadPhaseLabel(snapshot.phase))
                        .font(ImlaTheme.font(size: 11, weight: .medium))
                        .foregroundStyle(ImlaTheme.textSecondary)
                }

                if let detail = downloadDetailText(snapshot), !detail.isEmpty {
                    Text(detail)
                        .font(ImlaTheme.font(size: 11))
                        .foregroundStyle(ImlaTheme.textTertiary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                // Only show a moving bar while a download is actually in flight — a failure with
                // no snapshot (e.g. an instant OS-compatibility rejection) can leave a stale
                // message behind with nothing in progress to animate.
                if isDownloading {
                    ProgressView(value: fallbackProgress)
                        .tint(ImlaTheme.accent)
                }
                Text(fallbackMessage ?? "\(Int(fallbackProgress * 100))% downloading...")
                    .font(ImlaTheme.font(size: 11))
                    .foregroundStyle(ImlaTheme.textTertiary)
            }
        }
    }

    private func downloadPhaseLabel(_ phase: ModelDownloadPhase) -> String {
        switch phase {
        case .downloading: return "Downloading"
        case .preparing: return "Preparing"
        case .ready: return "Ready"
        case .paused: return "Download paused"
        case .failed: return "Failed"
        }
    }

    private func downloadDetailText(_ snapshot: ModelDownloadProgress) -> String? {
        var details: [String] = []
        if snapshot.totalFileCount > 0 {
            let completed = min(max(snapshot.completedFileCount, 0), snapshot.totalFileCount)
            let remaining = snapshot.totalFileCount - completed
            details.append("\(completed) of \(snapshot.totalFileCount) \(downloadFileNoun(snapshot.totalFileCount))")
            if remaining > 0 {
                details.append("\(remaining) \(downloadFileNoun(remaining)) left")
            }
        }
        if let total = snapshot.totalBytes, total > 0 {
            details.append("\(ModelDownloadDisplayFormatting.bytes(snapshot.completedBytes)) / \(ModelDownloadDisplayFormatting.bytes(total))")
            if snapshot.completedBytes < total {
                details.append("\(ModelDownloadDisplayFormatting.bytes(total - snapshot.completedBytes)) left")
            }
        } else if let currentTotal = snapshot.currentFileTotalBytes, currentTotal > 0 {
            details.append("\(ModelDownloadDisplayFormatting.bytes(snapshot.currentFileCompletedBytes)) / \(ModelDownloadDisplayFormatting.bytes(currentTotal))")
            if snapshot.currentFileCompletedBytes < currentTotal {
                details.append("\(ModelDownloadDisplayFormatting.bytes(currentTotal - snapshot.currentFileCompletedBytes)) left in file")
            }
        }
        if snapshot.phase == .downloading {
            if snapshot.bytesPerSecond > 0 {
                details.append("\(ModelDownloadDisplayFormatting.rate(snapshot.bytesPerSecond))")
            }
            if let eta = snapshot.estimatedSecondsRemaining,
               let formattedETA = ModelDownloadDisplayFormatting.eta(eta) {
                details.append("\(formattedETA) left")
            }
            if snapshot.retryCount > 0 {
                details.append("retry \(snapshot.retryCount)/3")
            }
        } else if let message = snapshot.message, !message.isEmpty {
            details.append(message)
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private func downloadFileNoun(_ count: Int) -> String {
        count == 1 ? "file" : "files"
    }

    private func shouldShowDownloadStatus(for modelID: String, isDownloading: Bool) -> Bool {
        guard let phase = downloadSnapshots[modelID]?.phase else {
            return isDownloading || downloadMessages[modelID] != nil
        }
        return isDownloading || phase == .paused || phase == .failed
    }

    @ViewBuilder
    private func brandLogo(_ name: String?) -> some View {
        if name == "apple-system-logo" {
            Image(systemName: "apple.logo")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(ImlaTheme.textPrimary)
                .frame(width: 24, height: 24)
                .padding(.top, 2)
        } else if let name,
           let url = Bundle.main.url(forResource: name, withExtension: "png")
                ?? Bundle.main.url(forResource: name, withExtension: "svg"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(.top, 2)
        }
    }

    private func logoForBackend(_ option: BackendOption) -> String? {
        switch option.backend {
        case "fluidaudio": return "nvidia-logo"
        case "parakeet-unified": return "nvidia-logo"
        case "whisper": return "openai-logo"
        case "cohere", "cohere-arabic": return "cohere-logo"
        case "nemotron35": return "nvidia-logo"
        case "bodhan": return "bodhan-logo"
        case "sensevoice": return "qwen-logo"
        case "gemma4-litert": return "google-logo"
        case "apple-speech": return "apple-system-logo"
        default: return nil
        }
    }

    @ViewBuilder
    private func actionButtons(
        for option: BackendOption,
        isActive: Bool,
        isDownloaded: Bool,
        isDownloading: Bool,
        actionTitle: String = "Set Active",
        activationDisabledReason: String? = nil,
        incompatibilityReason: String? = nil,
        onSetActive: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: ImlaTheme.spacing8) {
            if isDownloading {
                Button("Pause") {
                    cancelDownload(option)
                }
                .buttonStyle(.plain)
                .font(ImlaTheme.font(size: 12, weight: .medium))
                .foregroundStyle(ImlaTheme.textSecondary)
                .padding(.horizontal, ImlaTheme.spacing12)
                .padding(.vertical, 4)
                .background(ImlaTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
            } else if isDownloaded {
                if !isActive {
                    let disabledReason = incompatibilityReason ?? activationDisabledReason
                    Button(actionTitle) {
                        if let onSetActive {
                            onSetActive()
                        } else {
                            controller.selectBackend(option)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(ImlaTheme.font(size: 12, weight: .medium))
                    .foregroundStyle(disabledReason == nil ? ImlaTheme.accent : ImlaTheme.textTertiary)
                    .padding(.horizontal, ImlaTheme.spacing12)
                    .padding(.vertical, 4)
                    .background(disabledReason == nil ? ImlaTheme.accentSubtle : ImlaTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
                    .disabled(disabledReason != nil)
                    .help(disabledReason ?? actionTitle)
                }

                if !option.isSystemManaged {
                    Button {
                        modelToDelete = option
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(ImlaTheme.danger.opacity(0.6))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button("Download") {
                    startDownload(option)
                }
                .buttonStyle(.plain)
                .font(ImlaTheme.font(size: 12, weight: .medium))
                .foregroundStyle(incompatibilityReason == nil ? ImlaTheme.accent : ImlaTheme.textTertiary)
                .padding(.horizontal, ImlaTheme.spacing12)
                .padding(.vertical, 4)
                .background(incompatibilityReason == nil ? ImlaTheme.accentSubtle : ImlaTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerSmall, style: .continuous))
                .disabled(incompatibilityReason != nil)
                .help(incompatibilityReason ?? "Download")
            }
        }
    }

    private func modelCard(
        option: BackendOption,
        logo: String? = nil,
        title: String? = nil,
        precisionSelection: Binding<String>? = nil,
        isActive activeOverride: Bool? = nil,
        onSetActive: (() -> Void)? = nil,
        description: String? = nil,
        activeLabel: String = "Active",
        downloadedLabel: String = "Downloaded",
        actionTitle: String = "Set Active",
        activationDisabledReason: String? = nil
    ) -> some View {
        let isActive = activeOverride ?? (appState.selectedBackend == option)
        let isDownloaded = downloadedModels.contains(option.model)
        let isDownloading = downloadingModels.contains(option.model)
        let progress = downloadProgress[option.model] ?? 0
        let showsDownloadStatus = shouldShowDownloadStatus(for: option.model, isDownloading: isDownloading)
        let incompatibilityReason = option.incompatibilityReason()

        return VStack(alignment: .leading, spacing: ImlaTheme.spacing12) {
            HStack(alignment: .top, spacing: ImlaTheme.spacing12) {
                brandLogo(logo)
                VStack(alignment: .leading, spacing: ImlaTheme.spacing4) {
                    HStack(spacing: ImlaTheme.spacing8) {
                        Text(title ?? option.label)
                            .font(ImlaTheme.headline())
                            .foregroundStyle(incompatibilityReason == nil ? ImlaTheme.textPrimary : ImlaTheme.textTertiary)

                        if option.recommended {
                            Text("Recommended")
                                .font(ImlaTheme.font(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ImlaTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }

                        Text(option.sizeLabel)
                            .font(ImlaTheme.caption())
                            .foregroundStyle(ImlaTheme.textTertiary)
                    }

                    Text(description ?? option.description)
                        .font(ImlaTheme.caption())
                        .foregroundStyle(incompatibilityReason == nil ? ImlaTheme.textSecondary : ImlaTheme.textTertiary)
                }

                Spacer()

                // Status badge — Incompatible takes priority over Active/Downloaded.
                if let incompatibilityReason {
                    Text("Incompatible")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ImlaTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ImlaTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .help(incompatibilityReason)
                } else if isActive {
                    Text(activeLabel)
                        .font(ImlaTheme.font(size: 11, weight: .semibold))
                        .foregroundStyle(ImlaTheme.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ImlaTheme.success.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else if isDownloaded {
                    Text(downloadedLabel)
                        .font(ImlaTheme.font(size: 11, weight: .medium))
                        .foregroundStyle(ImlaTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ImlaTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }

            HStack(alignment: .top, spacing: ImlaTheme.spacing12) {
                Text("Language")
                    .font(ImlaTheme.caption())
                    .foregroundStyle(ImlaTheme.textTertiary)
                    .frame(width: 64, alignment: .leading)

                Text(appState.config.dictationLanguageProfile.presentation(for: option).explanation)
                    .font(ImlaTheme.caption())
                    .foregroundStyle(ImlaTheme.textSecondary)
                    .frame(maxWidth: 300, alignment: .leading)
            }

            // Each Bodhan variant ships an INT8 and an FP16 build. Precision is a
            // download choice rather than a language one, so it stays on the card
            // while the profile keeps deciding the language.
            if option.backend == BackendOption.bodhanFlex.backend, let precisionSelection {
                HStack(alignment: .center, spacing: ImlaTheme.spacing12) {
                    Text("Precision")
                        .font(ImlaTheme.caption())
                        .foregroundStyle(ImlaTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("Precision", selection: precisionSelection) {
                        ForEach(BackendOption.bodhanFamily.filter {
                            BodhanModel(rawValue: $0.model)?.isCore == BodhanModel(rawValue: option.model)?.isCore
                        }, id: \.model) { variant in
                            Text(BodhanModel(rawValue: variant.model)?.isInt8 == true ? "INT8" : "FP16")
                                .tag(variant.model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 100)
                    .disabled(isDownloading || incompatibilityReason != nil)
                }
            }

            // Apple Speech takes a full locale identifier (en-GB, pt-BR, ...), which
            // the language profile's ISO language codes cannot express, so it keeps
            // its own picker sourced from the locales the OS reports as supported.
            if option.backend == BackendOption.appleSpeechAnalyzer.backend {
                HStack(alignment: .center, spacing: ImlaTheme.spacing12) {
                    Text("Locale")
                        .font(ImlaTheme.caption())
                        .foregroundStyle(ImlaTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: appleSpeechLanguageSelection) {
                        ForEach(appleSpeechLanguageOptions) { language in
                            Text(language.label).tag(language.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                    .disabled(incompatibilityReason != nil)
                }
            }

            if option.backend == BackendOption.nemotron35Multilingual.backend {
                if isDownloaded && nemotron35UpdateAvailable && !isDownloading {
                    HStack(spacing: ImlaTheme.spacing8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                            .foregroundStyle(ImlaTheme.accent)
                        Text("A newer model build is available.")
                            .font(ImlaTheme.caption())
                            .foregroundStyle(ImlaTheme.textSecondary)
                        Button("Update") { updateNemotron35(option) }
                            .buttonStyle(.plain)
                            .font(ImlaTheme.font(size: 12, weight: .medium))
                            .foregroundStyle(incompatibilityReason == nil ? ImlaTheme.accent : ImlaTheme.textTertiary)
                            .disabled(incompatibilityReason != nil)
                            .help(incompatibilityReason ?? "Update")
                    }
                }
            }

            // Progress bar when downloading.
            if showsDownloadStatus, incompatibilityReason == nil {
                downloadProgressView(
                    for: option.model,
                    fallbackProgress: progress,
                    fallbackMessage: downloadMessages[option.model],
                    isDownloading: isDownloading
                )
            }

            if let incompatibilityReason {
                Label(incompatibilityReason, systemImage: "exclamationmark.triangle")
                    .font(ImlaTheme.caption())
                    .foregroundStyle(ImlaTheme.textTertiary)
            } else if let activationDisabledReason, isDownloaded, !isActive {
                Label(activationDisabledReason, systemImage: "exclamationmark.lock")
                    .font(ImlaTheme.caption())
                    .foregroundStyle(ImlaTheme.textTertiary)
            }

            actionButtons(
                for: option,
                isActive: isActive,
                isDownloaded: isDownloaded,
                isDownloading: isDownloading,
                actionTitle: actionTitle,
                activationDisabledReason: activationDisabledReason,
                incompatibilityReason: incompatibilityReason,
                onSetActive: onSetActive
            )
        }
        .padding(ImlaTheme.spacing16)
        .background(ImlaTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(isActive ? ImlaTheme.accent.opacity(0.5) : ImlaTheme.surfaceBorder, lineWidth: isActive ? 1.5 : 1)
        )
    }

    private func comingSoonCard(option: BackendOption) -> some View {
        VStack(alignment: .leading, spacing: ImlaTheme.spacing8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: ImlaTheme.spacing4) {
                    HStack(spacing: ImlaTheme.spacing8) {
                        Text(option.label)
                            .font(ImlaTheme.headline())
                            .foregroundStyle(ImlaTheme.textTertiary)

                        Text("Coming soon")
                            .font(ImlaTheme.font(size: 10, weight: .semibold))
                            .foregroundStyle(ImlaTheme.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ImlaTheme.surfacePrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                        Text(option.sizeLabel)
                            .font(ImlaTheme.caption())
                            .foregroundStyle(ImlaTheme.textTertiary.opacity(0.6))
                    }

                    Text(option.description)
                        .font(ImlaTheme.caption())
                        .foregroundStyle(ImlaTheme.textTertiary.opacity(0.7))
                }
                Spacer()
            }
        }
        .padding(ImlaTheme.spacing16)
        .background(ImlaTheme.backgroundRaised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ImlaTheme.cornerMedium, style: .continuous)
                .strokeBorder(ImlaTheme.surfaceBorder.opacity(0.5), lineWidth: 1)
        )
        .opacity(0.6)
    }

    // MARK: - Post-Processor Actions

    private func startPostProcDownload(_ option: PostProcessorOption, forQuill: Bool = false) {
        guard option.isDownloadable else { return }
        withAnimation { _ = downloadingPostProcModels.insert(option.id) }
        downloadProgressPostProc[option.id] = 0.02
        downloadMessages.removeValue(forKey: option.id)
        downloadSnapshots.removeValue(forKey: option.id)
        let generation = UUID()
        downloadGenerations[option.id] = generation

        let task = Task {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: option.cacheDirectory, withIntermediateDirectories: true)

                try await downloadPostProcModel(option, generation: generation)
                try Task.checkCancellation()

                await MainActor.run {
                    guard downloadGenerations[option.id] == generation, !Task.isCancelled else { return }
                    withAnimation {
                        downloadingPostProcModels.remove(option.id)
                        downloadedPostProcModels.insert(option.id)
                        downloadProgressPostProc.removeValue(forKey: option.id)
                        downloadMessages.removeValue(forKey: option.id)
                        downloadSnapshots.removeValue(forKey: option.id)
                        if downloadGenerations[option.id] == generation {
                            downloadGenerations.removeValue(forKey: option.id)
                        }
                        downloadTasksPostProc.removeValue(forKey: option.id)
                    }
                    if !forQuill && appState.config.enablePostProcessor && !appState.activePostProcessor.isDownloaded {
                        controller.selectPostProcessor(option)
                        controller.preloadExperimentalTranscriptionFeatures()
                    }
                }
            } catch {
                let isCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                await MainActor.run {
                    guard downloadGenerations[option.id] == generation else { return }
                    withAnimation {
                        downloadingPostProcModels.remove(option.id)
                        downloadProgressPostProc.removeValue(forKey: option.id)
                        downloadMessages[option.id] = isCancelled
                            ? "Paused — select Download to resume"
                            : error.localizedDescription
                        if let snapshot = downloadSnapshots[option.id] {
                            downloadSnapshots[option.id] = snapshot.replacing(
                                phase: isCancelled ? .paused : .failed,
                                message: downloadMessages[option.id]
                            )
                        }
                        if downloadGenerations[option.id] == generation {
                            downloadGenerations.removeValue(forKey: option.id)
                        }
                        downloadTasksPostProc.removeValue(forKey: option.id)
                    }
                }
                if !isCancelled {
                    fputs("[imla-native] Post-processor download failed: \(error)\n", stderr)
                }
            }
        }
        downloadTasksPostProc[option.id] = task
    }

    private func downloadPostProcModel(_ option: PostProcessorOption, generation: UUID) async throws {
        let manifest = ModelDownloadManifest(
            id: option.id,
            version: "main",
            files: [ModelDownloadFile(relativePath: option.filename, remoteURL: option.downloadURL)],
            maximumConcurrency: 1
        )
        try await ModelDownloadCoordinator.shared.download(manifest, to: option.cacheDirectory) { snapshot in
            DispatchQueue.main.async {
                guard downloadGenerations[option.id] == generation else { return }
                downloadProgressPostProc[option.id] = max(snapshot.fractionCompleted ?? 0.02, 0.02)
                downloadSnapshots[option.id] = snapshot
            }
        }
        try Task.checkCancellation()
        do {
            try validateGGUFHeader(at: option.modelURL)
        } catch {
            try? FileManager.default.removeItem(at: option.modelURL)
            throw error
        }
    }

    private func validateGGUFHeader(at url: URL) throws {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let header = try fh.read(upToCount: 4) ?? Data()
        guard header == Data([0x47, 0x47, 0x55, 0x46]) else {
            throw NSError(domain: "PostProcDownload", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Downloaded post-processor file is not a GGUF model",
            ])
        }
    }

    private func cancelPostProcDownload(_ option: PostProcessorOption) {
        let task = downloadTasksPostProc[option.id]
        let cancellationGeneration = UUID()
        task?.cancel()
        Task {
            await ModelDownloadCoordinator.shared.cancel(modelID: option.id)
            _ = await task?.value
            await MainActor.run {
                guard downloadGenerations[option.id] == cancellationGeneration else { return }
                if option.isDownloaded {
                    downloadedPostProcModels.insert(option.id)
                    downloadMessages.removeValue(forKey: option.id)
                    downloadSnapshots.removeValue(forKey: option.id)
                } else {
                    downloadMessages[option.id] = "Paused — select Download to resume"
                }
                downloadGenerations.removeValue(forKey: option.id)
            }
        }
        withAnimation {
            downloadingPostProcModels.remove(option.id)
            downloadProgressPostProc.removeValue(forKey: option.id)
            // Invalidate callbacks from the cancelled task, but retain a
            // generation until it has fully unwound so a race that finalizes
            // the file can refresh the card immediately.
            downloadGenerations[option.id] = cancellationGeneration
            if let snapshot = downloadSnapshots[option.id] {
                downloadSnapshots[option.id] = snapshot.replacing(phase: .paused, message: "Paused — select Download to resume")
            }
            downloadTasksPostProc.removeValue(forKey: option.id)
        }
    }

    private func deletePostProcModel(_ option: PostProcessorOption) {
        if appState.activePostProcessor.id == option.id {
            let remainingDownloadedIDs = downloadedPostProcModels.subtracting([option.id])
            if let fallback = PostProcessorOption.firstDownloaded(excluding: option.id, downloadedIDs: remainingDownloadedIDs) {
                controller.selectPostProcessor(fallback)
            } else {
                controller.setPostProcessorEnabled(false)
            }
        }
        // Cleared up front so the card cannot offer "Set Active" for a model
        // whose files are about to disappear.
        downloadedPostProcModels.remove(option.id)
        downloadSnapshots.removeValue(forKey: option.id)
        downloadGenerations.removeValue(forKey: option.id)
        let plan = ModelDeletionPlan.postProcessor(option)
        Task {
            // Release the loaded GGUF before its files disappear; deletion
            // stays best effort. The re-scan afterwards reconciles anything
            // that interleaved with the pending deletion (e.g. a re-download).
            await controller.transcriptionCoordinator.unloadLocalPostProcessorModel(ifUsing: option.modelURL)
            try? await ModelDeletionExecutor.execute(plan)
            checkDownloadedPostProcModels()
        }
    }

    private func checkDownloadedPostProcModels() {
        downloadedPostProcModels.removeAll()
        for option in PostProcessorOption.downloaded {
            if option.isDownloaded {
                downloadedPostProcModels.insert(option.id)
            }
        }
    }

    /// The retired v2 cleanup model stays visible only for people who already
    /// have it installed. Deleting it removes the card, and the model cannot
    /// be downloaded again.
    private var displayedPostProcessorOptions: [PostProcessorOption] {
        PostProcessorOption.all
            + (downloadedPostProcModels.contains(PostProcessorOption.legacyV2.id)
                ? [.legacyV2]
                : [])
    }

    // MARK: - Actions

    private func startDownload(_ option: BackendOption) {
        guard option.isCompatible() else { return }
        withAnimation { _ = downloadingModels.insert(option.model) }
        downloadProgress[option.model] = 0.05  // Show initial progress immediately
        downloadMessages.removeValue(forKey: option.model)
        downloadSnapshots.removeValue(forKey: option.model)
        let generation = UUID()
        downloadGenerations[option.model] = generation

        let startTime = Date()
        let task = Task {
            do {
                try await controller.transcriptionCoordinator.preloadRequired(
                    backend: option,
                    includeMeetingHelpers: false,
                    meetingHelperTrigger: .modelLibrary,
                    appleSpeechLanguage: appState.config.resolvedAppleSpeechLanguage
                ) { progress, message in
                    DispatchQueue.main.async {
                        guard downloadGenerations[option.model] == generation else { return }
                        downloadProgress[option.model] = max(progress, 0.05)
                        if let message { downloadMessages[option.model] = message }
                    }
                } progressSnapshot: { snapshot in
                    DispatchQueue.main.async {
                        guard downloadGenerations[option.model] == generation else { return }
                        downloadSnapshots[option.model] = snapshot
                        if let fraction = snapshot.fractionCompleted {
                            downloadProgress[option.model] = max(fraction, 0.05)
                        }
                    }
                }
                guard !Task.isCancelled else {
                    await MainActor.run {
                        guard downloadGenerations[option.model] == generation else { return }
                        withAnimation {
                            downloadingModels.remove(option.model)
                            downloadProgress.removeValue(forKey: option.model)
                            downloadMessages[option.model] = "Paused — select Download to resume"
                            if let snapshot = downloadSnapshots[option.model] {
                                downloadSnapshots[option.model] = snapshot.replacing(
                                    phase: .paused,
                                    message: "Paused — select Download to resume"
                                )
                            }
                            downloadGenerations.removeValue(forKey: option.model)
                            downloadTasks.removeValue(forKey: option.model)
                        }
                    }
                    return
                }
                guard option.isDownloaded else {
                    throw NSError(
                        domain: "ImlaModelDownload",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "\(option.label) was not downloaded successfully."]
                    )
                }
                guard !Task.isCancelled else {
                    await MainActor.run {
                        guard downloadGenerations[option.model] == generation else { return }
                        withAnimation {
                            downloadingModels.remove(option.model)
                            downloadProgress.removeValue(forKey: option.model)
                            downloadMessages[option.model] = "Paused — select Download to resume"
                            if let snapshot = downloadSnapshots[option.model] {
                                downloadSnapshots[option.model] = snapshot.replacing(
                                    phase: .paused,
                                    message: "Paused — select Download to resume"
                                )
                            }
                            downloadGenerations.removeValue(forKey: option.model)
                            downloadTasks.removeValue(forKey: option.model)
                        }
                    }
                    return
                }
                // Ensure the downloading state is visible for at least 1.5s
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed < 1.5 {
                    try? await Task.sleep(nanoseconds: UInt64((1.5 - elapsed) * 1_000_000_000))
                }
                await MainActor.run {
                    guard downloadGenerations[option.model] == generation, !Task.isCancelled else { return }
                    withAnimation {
                        downloadingModels.remove(option.model)
                        downloadedModels.insert(option.model)
                        downloadProgress.removeValue(forKey: option.model)
                        downloadMessages.removeValue(forKey: option.model)
                        downloadSnapshots.removeValue(forKey: option.model)
                        downloadGenerations.removeValue(forKey: option.model)
                        downloadTasks.removeValue(forKey: option.model)
                    }
                }
            } catch {
                let isCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                await MainActor.run {
                    withAnimation {
                        guard downloadGenerations[option.model] == generation else { return }
                        downloadingModels.remove(option.model)
                        downloadProgress.removeValue(forKey: option.model)
                        if isCancelled {
                            if let snapshot = downloadSnapshots[option.model] {
                                downloadSnapshots[option.model] = snapshot.replacing(
                                    phase: .paused,
                                    message: "Paused — select Download to resume"
                                )
                            }
                        } else {
                            downloadMessages[option.model] = error.localizedDescription
                            if let snapshot = downloadSnapshots[option.model] {
                                downloadSnapshots[option.model] = snapshot.replacing(
                                    phase: .failed,
                                    message: error.localizedDescription
                                )
                            }
                        }
                        downloadGenerations.removeValue(forKey: option.model)
                        downloadTasks.removeValue(forKey: option.model)
                    }
                }
                if !isCancelled {
                    fputs("[imla-native] model download failed for \(option.backend)/\(option.model): \(error)\n", stderr)
                }
            }
        }
        downloadTasks[option.model] = task
    }

    private func loadAppleSpeechLanguageOptions() {
        guard #available(macOS 26.0, *), AppleSpeechAnalyzerTranscriber.isSupportedOnCurrentSystem else {
            appleSpeechLanguageOptions = [.system]
            return
        }

        Task {
            var options = await AppleSpeechLanguageOption.supportedOptions()
            let selectedIdentifier = appState.config.resolvedAppleSpeechLanguage
            if selectedIdentifier != AppleSpeechLanguageOption.systemIdentifier,
               !options.contains(where: { $0.id == selectedIdentifier }) {
                options.append(.locale(Locale(identifier: selectedIdentifier)))
            }
            appleSpeechLanguageOptions = options
        }
    }

    private func cancelDownload(_ option: BackendOption) {
        let modelID = option.model
        let task = downloadTasks[modelID]
        let cancellationGeneration = UUID()
        task?.cancel()
        withAnimation {
            downloadingModels.remove(modelID)
            downloadProgress.removeValue(forKey: modelID)
            downloadMessages[modelID] = "Paused — select Download to resume"
            // Keep a cancellation generation until the caller task has fully
            // unwound. If a replacement starts first, this generation changes
            // and the old cancellation must not stop the replacement transfer.
            downloadGenerations[modelID] = cancellationGeneration
            downloadTasks.removeValue(forKey: modelID)
            if let snapshot = downloadSnapshots[modelID] {
                downloadSnapshots[modelID] = snapshot.replacing(
                    phase: .paused,
                    message: "Paused — select Download to resume"
                )
            }
        }
        Task {
            let shouldCancel = await MainActor.run {
                downloadGenerations[modelID] == cancellationGeneration
            }
            guard shouldCancel else { return }

            await ManagedASRModelDownloader.cancel(modelID: modelID)
            _ = await task?.value

            await MainActor.run {
                guard downloadGenerations[modelID] == cancellationGeneration else { return }
                downloadGenerations.removeValue(forKey: modelID)
            }
        }
    }

    /// Re-download Nemotron 3.5 to pick up a newer upstream build: delete the cached
    /// files (so the download isn't skipped), then start a fresh download.
    private func updateNemotron35(_ option: BackendOption) {
        // Check before unloading or deleting the installed model: startDownload also
        // rejects incompatible backends, so otherwise no replacement would be started.
        guard option.isCompatible() else { return }
        let deletionPlan = ModelDeletionPlan.backend(option)
        Task {
            do {
                await controller.transcriptionCoordinator.unloadTranscriber(for: option)
                try await ModelDeletionExecutor.execute(deletionPlan)
                downloadedModels.remove(option.model)
                nemotron35UpdateAvailable = false
                startDownload(option)
            } catch {
                fputs("[imla-native] model update cleanup failed for \(option.backend)/\(option.model): \(error)\n", stderr)
            }
        }
    }

    private func deleteModel(_ option: BackendOption) {
        if option == .nemotron35Multilingual,
           appState.config.resolvedMeetingLiveCaptionBackend == .nemotron35 {
            controller.updateConfig { $0.enableLiveStreamingPartials = false }
        }
        if appState.selectedPostProcessorBackend == .gemma4LiteRT,
           appState.config.postProcessorGemmaModel == option.model {
            controller.selectPostProcessorBackend(.local)
        }
        if appState.selectedBackend == option {
            let fallback = downloadedModels
                .compactMap { model in BackendOption.all.first(where: { $0.model == model && $0 != option }) }
                .first ?? (option == .parakeetUnified ? .parakeetMultilingual : .parakeetUnified)
            controller.selectBackend(fallback)
        }
        let task = downloadTasks[option.model]
        task?.cancel()
        let deletionGeneration = UUID()
        downloadGenerations[option.model] = deletionGeneration
        downloadTasks.removeValue(forKey: option.model)
        let deletionPlan = ModelDeletionPlan.backend(option)
        Task {
            let deletionToken = await ManagedASRModelDownloader.beginDeletion(
                modelID: option.model
            )
            do {
                _ = await task?.value
                let shouldDelete = await MainActor.run {
                    downloadGenerations[option.model] == deletionGeneration
                }
                guard shouldDelete else {
                    await ManagedASRModelDownloader.endDeletion(deletionToken)
                    return
                }

                // Release the transcriber's file mappings (and RAM) before
                // deleting the files it maps; shutdown serializes behind any
                // in-flight transcription on that backend.
                await controller.transcriptionCoordinator.unloadTranscriber(for: option)
                try await ModelDeletionExecutor.execute(deletionPlan)
                await MainActor.run {
                    _ = downloadedModels.remove(option.model)
                    if appState.selectedMeetingTranscriptionBackend == option {
                        controller.refreshMeetingTranscriptionSelectionForAvailability()
                    }
                    downloadSnapshots.removeValue(forKey: option.model)
                    downloadMessages.removeValue(forKey: option.model)
                    downloadGenerations.removeValue(forKey: option.model)
                    controller.refreshMeetingTranscriptionSelectionAfterDeleting(option)
                }
            } catch {
                fputs("[imla-native] model delete failed for \(option.backend)/\(option.model): \(error)\n", stderr)
            }
            await ManagedASRModelDownloader.endDeletion(deletionToken)
        }
    }
    // MARK: - Check Downloaded Status

    private func checkDownloadedModels() {
        for option in BackendOption.all {
            if option.isDownloaded {
                downloadedModels.insert(option.model)
            }
        }
    }

    /// Background check: does FluidInference's repo have a newer commit than what's
    /// installed for Nemotron 3.5? Never auto-downloads — just surfaces a badge.
    private func checkNemotron35Update() {
        guard #available(macOS 15, *),
              BackendOption.nemotron35Multilingual.isDownloaded else { return }
        Task {
            let available = await Nemotron35StreamingTranscriber.updateAvailable()
            await MainActor.run { nemotron35UpdateAvailable = available }
        }
    }

    private func syncSelectionsFromActiveBackend() {
        let active = appState.selectedBackend
        if BackendOption.parakeetFamily.contains(active) {
            selectedParakeetModel = active.model
        }
        if BackendOption.whisperFamily.contains(active) {
            selectedWhisperModel = active.model
        }
        if let model = BodhanModel(rawValue: active.model) {
            if model.isCore { selectedBodhanCoreModel = active.model }
            else { selectedBodhanFlexModel = active.model }
        }
        if BackendOption.experimental.contains(active) {
            showExperimental = true
        }
    }

}
