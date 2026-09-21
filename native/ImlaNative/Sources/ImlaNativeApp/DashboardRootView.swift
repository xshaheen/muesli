import SwiftUI
import ImlaCore

enum DashboardWindowLayout {
    /// Narrow enough to sit beside a call window while preserving a useful
    /// notes editor when the sidebar is collapsed or hidden.
    static let minimumContentWidth: CGFloat = 520
    static let minimumContentHeight: CGFloat = 600
    static let compactQuickNotesThreshold: CGFloat = 600

    static func usesCompactQuickNotes(width: CGFloat, hasOpenMeeting: Bool) -> Bool {
        hasOpenMeeting && width < compactQuickNotesThreshold
    }
}

private struct CompactQuickNotesEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usesCompactQuickNotes: Bool {
        get { self[CompactQuickNotesEnvironmentKey.self] }
        set { self[CompactQuickNotesEnvironmentKey.self] = newValue }
    }
}

@Observable
final class DashboardSidebarPresentation {
    var isCollapsed = false

    func toggle() {
        isCollapsed.toggle()
    }
}

struct DashboardContentLayout<SidebarContent: View, DetailContent: View>: View {
    let usesCompactQuickNotes: Bool
    @ViewBuilder let sidebar: () -> SidebarContent
    @ViewBuilder let detail: () -> DetailContent

    var body: some View {
        HSplitView {
            if !usesCompactQuickNotes {
                sidebar()
            }

            detail()
                .environment(\.usesCompactQuickNotes, usesCompactQuickNotes)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ImlaTheme.backgroundBase)
        }
    }
}

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
    let controller: ImlaController
    @State private var sidebarPresentation: DashboardSidebarPresentation

    init(
        appState: AppState,
        controller: ImlaController,
        sidebarPresentation: DashboardSidebarPresentation = DashboardSidebarPresentation()
    ) {
        self.appState = appState
        self.controller = controller
        _sidebarPresentation = State(initialValue: sidebarPresentation)
    }

    var sidebarView: SidebarView {
        SidebarView(
            appState: appState,
            controller: controller,
            isCollapsed: sidebarPresentation.isCollapsed,
            onToggleCollapsed: {
                withAnimation(ImlaTheme.Motion.eased(0.22)) {
                    sidebarPresentation.toggle()
                }
            }
        )
    }

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
            .font(ImlaTheme.title1())
            .foregroundStyle(ImlaTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ImlaTheme.spacing24)
            .padding(.top, ImlaTheme.spacing16)
            .padding(.bottom, ImlaTheme.spacing12)
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
        withAnimation(ImlaTheme.Motion.eased(0.22)) {
            sidebarPresentation.toggle()
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
            if sidebarPresentation.isCollapsed {
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
            .background(ImlaTheme.backgroundBase)
        }
        .ignoresSafeArea(.container, edges: .top)

        .frame(minWidth: 640, minHeight: 480)
        .preferredColorScheme(appState.config.darkMode ? .dark : .light)
        .featureTourHost(.dashboard, appState: appState, controller: controller)
        .alert(
            appState.contributionMilestonePrompt?.title ?? "Imla milestone",
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
            if appState.contributionMilestonePrompt?.showTweetAboutImla == true {
                Button("Tweet about Imla") {
                    controller.openContributionMilestoneAction(.tweetAboutImla)
                }
            }
            if appState.contributionMilestonePrompt?.showPostOnLinkedIn == true {
                Button("Post about Imla on LinkedIn") {
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
    }

    private var hasOpenMeeting: Bool {
        if case .document = appState.meetingsNavigationState {
            return true
        }
        return false
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
            }
        }
    }
}


