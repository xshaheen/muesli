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

    /// The page title, pinned above the scrolling content.
    ///
    /// There is no titlebar band to hold it: the window runs its content to the top edge,
    /// so this row is what sits beside the traffic lights. `titlebarHeight` keeps it clear
    /// of them, which matters most with the rail collapsed, where the lights reach past
    /// the 52pt rail and into this column.
    private var pageHeader: some View {
        Text(pageTitle)
            .font(MuesliTheme.title1())
            .foregroundStyle(MuesliTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MuesliTheme.spacing24)
            .padding(.top, MuesliTheme.spacing16)
            .padding(.bottom, MuesliTheme.spacing12)
    }

    /// The standard macOS titlebar height, which the traffic lights sit inside.
    private static let titlebarHeight: CGFloat = 28

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

    /// Swaps the leading column between the full sidebar and the icon rail.
    private func toggleCollapsed() {
        withAnimation(MuesliTheme.Motion.eased(0.22)) {
            isSidebarCollapsed.toggle()
        }
    }

    var body: some View {
        // Our own two columns, not NavigationSplitView.
        //
        // macOS 26 draws a split view's sidebar as an inset rounded card that never
        // reaches the window's corner, so the traffic lights always landed on bare window
        // above it. That card is the "separate bar", and no amount of padding removes it.
        // A plain HStack lets the leading column own the corner, so the lights sit on the
        // sidebar's own surface the way they do in Finder and WhatsApp. Nothing here used
        // the split view's navigation, and it also clamped the collapsed rail's width.
        HStack(spacing: 0) {
            if isSidebarCollapsed {
                collapsedRail
            } else {
                sidebar
                    .frame(width: Self.sidebarIdealWidth)
            }

            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                detailContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MuesliTheme.backgroundBase)
        }
        .ignoresSafeArea(.container, edges: .top)

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


