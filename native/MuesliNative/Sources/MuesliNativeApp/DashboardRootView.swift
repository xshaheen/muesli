import SwiftUI
import MuesliCore

struct DashboardRootView: View {
    static let sidebarMinimumWidth: CGFloat = 260
    /// The collapsed rail is drawn as our own column beside the detail view, not as
    /// the split view's sidebar: AppKit clamps that sidebar to its own minimum and
    /// ignores a narrower request, which is what left the rail full of dead space.
    /// 52pt is one 40pt icon cell with a 6pt gutter each side.
    static let sidebarCollapsedWidth: CGFloat = 52
    private static let sidebarIdealWidth: CGFloat = 280
    private static let sidebarMaximumWidth: CGFloat = 320

    let appState: AppState
    let controller: MuesliController
    @State private var featureTourTargetFrames: [FeatureTourTarget: CGRect] = [:]
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isSidebarCollapsed = false

    /// The window's titlebar is opaque chrome that spans the whole width, so a page that
    /// draws its own large heading below it leaves that band empty. The page title lives
    /// in the band instead, which is what fills it.
    private var pageTitle: String {
        switch appState.selectedTab {
        case .timeline: "Timeline"
        case .dictations: "Dictations"
        case .insights: "Insights"
        case .meetings: "Meetings"
        case .dictionary: "Dictionary"
        case .models: "Models"
        case .shortcuts: "Shortcuts"
        case .settings: "Settings"
        case .about: "About"
        }
    }

    private var sidebar: some View {
        SidebarView(
            appState: appState,
            controller: controller,
            isCollapsed: false,
            onToggleCollapsed: toggleCollapsed,
            collapseShortcut: Self.collapseShortcut
        )
    }

    private var collapsedRail: some View {
        SidebarView(
            appState: appState,
            controller: controller,
            isCollapsed: true,
            onToggleCollapsed: toggleCollapsed,
            collapseShortcut: Self.collapseShortcut
        )
        .frame(width: Self.sidebarCollapsedWidth)
        .frame(maxHeight: .infinity)
    }

    private static let collapseShortcut = KeyboardShortcut("s", modifiers: [.control, .command])

    /// Collapsing hides the split view's sidebar entirely and shows our own rail,
    /// so the two never appear at once and the detail view keeps its identity.
    private func toggleCollapsed() {
        withAnimation(MuesliTheme.Motion.eased(0.22)) {
            isSidebarCollapsed.toggle()
            columnVisibility = isSidebarCollapsed ? .detailOnly : .all
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .frame(minWidth: Self.sidebarMinimumWidth)
                .navigationSplitViewColumnWidth(
                    min: Self.sidebarMinimumWidth,
                    ideal: Self.sidebarIdealWidth,
                    max: Self.sidebarMaximumWidth
                )
                // SidebarView draws its own collapse control, so the system chevron
                // would be a second, competing toggle.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detailContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MuesliTheme.backgroundBase)
            // The rail lives here rather than in the sidebar column so its width is
            // ours; safeAreaInset also insets the detail content, so nothing hides
            // behind it.
            .safeAreaInset(edge: .leading, spacing: 0) {
                if isSidebarCollapsed {
                    collapsedRail
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(pageTitle)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .preferredColorScheme(appState.config.darkMode ? .dark : .light)
        .onPreferenceChange(FeatureTourTargetPreferenceKey.self) { frames in
            guard FeatureTourFrameTracking.hasMeaningfulChange(
                from: featureTourTargetFrames,
                to: frames
            ) else { return }
            featureTourTargetFrames = frames
        }
        .overlay {
            GeometryReader { proxy in
                if let invitation = appState.pendingFeatureTourInvitation {
                    FeatureTourInvitationView(
                        tour: invitation,
                        onAccept: { controller.acceptFeatureTourInvitation() },
                        onSkip: { controller.skipFeatureTourInvitation() }
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .zIndex(101)
                } else if let tour = appState.activeFeatureTour,
                   tour.steps.indices.contains(appState.featureTourStepIndex),
                   let globalTargetFrame = featureTourTargetFrames[tour.steps[appState.featureTourStepIndex].target] {
                    let globalRootFrame = proxy.frame(in: .global)
                    let targetFrame = globalTargetFrame.offsetBy(
                        dx: -globalRootFrame.minX,
                        dy: -globalRootFrame.minY
                    )
                    FeatureTourOverlay(
                        tour: tour,
                        stepIndex: appState.featureTourStepIndex,
                        spotlightRect: targetFrame,
                        containerSize: proxy.size,
                        onBack: { controller.showPreviousFeatureTourStep() },
                        onNext: { controller.showNextFeatureTourStep() },
                        onDismiss: { controller.dismissFeatureTour() }
                    )
                    .zIndex(100)
                }
            }
        }
        .alert(
            appState.contributionMilestonePrompt?.title ?? "Muesli milestone",
            isPresented: Binding(
                get: { appState.contributionMilestonePrompt != nil },
                set: { if !$0 { controller.dismissContributionMilestonePrompt() } }
            )
        ) {
            if appState.contributionMilestonePrompt?.showGitHubStar == true {
                Button("Star on GitHub") {
                    controller.openContributionMilestoneAction(.githubStar)
                }
            }
            if appState.contributionMilestonePrompt?.showBuyMeCoffee == true {
                Button("Buy Me a Coffee") {
                    controller.openContributionMilestoneAction(.buyMeCoffee)
                }
            }
            if appState.contributionMilestonePrompt?.showTweetAboutMuesli == true {
                Button("Tweet about Muesli") {
                    controller.openContributionMilestoneAction(.tweetAboutMuesli)
                }
            }
            if appState.contributionMilestonePrompt?.showPostOnLinkedIn == true {
                Button("Post about Muesli on LinkedIn") {
                    controller.openContributionMilestoneAction(.postOnLinkedIn)
                }
            }
            Button("Later", role: .cancel) {
                controller.dismissContributionMilestonePrompt()
            }
        } message: {
            Text(appState.contributionMilestonePrompt?.message ?? "")
        }
        .onAppear {
            controller.recordContributionMilestonePromptSeen()
        }
        .onChange(of: appState.contributionMilestonePrompt?.id) { _, _ in
            controller.recordContributionMilestonePromptSeen()
        }
        .sheet(
            item: Binding<DiagnosticIncident?>(
                get: { appState.pendingDiagnosticIncident },
                set: { if $0 == nil { controller.dismissDiagnosticIncidentPrompt() } }
            )
        ) { incident in
            DiagnosticIncidentReportView(
                incident: incident,
                onOpenIssue: { controller.openDiagnosticIncidentIssue(incident) },
                onDismiss: { controller.dismissDiagnosticIncidentPrompt() }
            )
        }
    }

    static func toggledColumnVisibility(
        after visibility: NavigationSplitViewVisibility
    ) -> NavigationSplitViewVisibility {
        visibility == .all ? .detailOnly : .all
    }

    @ViewBuilder
    private var detailContent: some View {
        if appState.isSearchActive,
           case .document(let id) = appState.meetingsNavigationState {
            MeetingDetailView(
                meeting: appState.selectedMeeting,
                controller: controller,
                appState: appState,
                onBack: {
                    appState.meetingsNavigationState = .browser
                    appState.selectedMeetingID = nil
                    appState.selectedMeetingRecord = nil
                },
                backLabel: "Back to Search"
            )
            .id(id)
        } else if appState.selectedTab == .timeline,
                  appState.meetingDetailReturnDestination == .timeline,
                  case .document(let id) = appState.meetingsNavigationState {
            MeetingDetailView(
                meeting: appState.selectedMeeting,
                controller: controller,
                appState: appState,
                onBack: { controller.showTimelineHome() },
                backLabel: "Back to Timeline"
            )
            .id(id)
        } else if appState.isSearchActive {
            SearchResultsView(appState: appState, controller: controller)
        } else {
            switch appState.selectedTab {
            case .timeline:
                TimelineView(appState: appState, controller: controller)
            case .dictations:
                DictationsView(appState: appState, controller: controller)
            case .insights:
                InsightsView(
                    initialSection: appState.insightsInitialSection,
                    loadSnapshot: { range in try await controller.insightsSnapshot(range: range) },
                    onBack: { controller.closeInsights() },
                    backLabel: appState.insightsBackLabel
                )
            case .meetings:
                MeetingsView(appState: appState, controller: controller)
            case .dictionary:
                DictionaryView(appState: appState, controller: controller)
            case .models:
                ModelsView(appState: appState, controller: controller)
            case .shortcuts:
                ShortcutsView(appState: appState, controller: controller)
            case .settings:
                SettingsView(appState: appState, controller: controller)
            case .about:
                AboutView(
                    appState: appState,
                    onOpenManualDiagnosticReport: { controller.openManualDiagnosticReport() },
                    onSetAutomaticDiagnosticIssuePrompts: { controller.setAutomaticDiagnosticIssuePrompts($0) }
                )
            }
        }
    }
}
