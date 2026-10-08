import AppKit
import Foundation
import ImlaCore
import SwiftUI
import Testing
@testable import ImlaNativeApp

@MainActor
@Suite("WindowAppearance", .serialized)
struct WindowAppearanceTests {
    @Test("replacing a panel off the active Space carries its content view, frame, and chrome")
    func everySpaceReplacementCarriesState() {
        let old = InteractiveFloatingPanel(
            contentRect: CGRect(x: 40, y: 60, width: 120, height: 30),
            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false
        )
        old.isReleasedWhenClosed = false
        old.level = .statusBar
        old.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        old.sharingType = .none
        old.backgroundColor = .clear
        old.isOpaque = false
        old.hasShadow = false
        old.ignoresMouseEvents = true
        old.hidesOnDeactivate = false
        old.alphaValue = 0.5
        old.contentMinSize = NSSize(width: 100, height: 20)
        old.becomesKeyOnlyIfNeeded = true
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 120, height: 30))
        old.contentView = content
        old.orderFrontRegardless()
        // A freshly made window is on every Space, so an order-in needs no replacement.
        #expect(!old.isMissingFromActiveSpace)

        let fresh = old.replacedOnActiveSpace {
            InteractiveFloatingPanel(
                contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                backing: .buffered, defer: false
            )
        }
        #expect(fresh !== old)
        #expect(fresh.contentView === content)
        #expect(old.contentView == nil)
        #expect(fresh.frame == CGRect(x: 40, y: 60, width: 120, height: 30))
        #expect(fresh.level == .statusBar)
        #expect(fresh.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary])
        // A replacement must stay hidden from screen sharing, or a repair would reveal the panel mid-call.
        #expect(fresh.sharingType == .none)
        #expect(fresh.ignoresMouseEvents)
        #expect(!fresh.hasShadow)
        #expect(!fresh.isOpaque)
        #expect(fresh.alphaValue == 0.5)
        #expect(fresh.contentMinSize == NSSize(width: 100, height: 20))
        #expect(fresh.becomesKeyOnlyIfNeeded)
        #expect(!fresh.isReleasedWhenClosed)
        #expect(fresh.isVisible)
        #expect(!old.isVisible)
        fresh.close()

        let ordinary = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 20, height: 20),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        ordinary.isReleasedWhenClosed = false
        ordinary.orderFrontRegardless()
        // Only all-Spaces windows are candidates; an ordinary window is never "missing".
        #expect(!ordinary.isMissingFromActiveSpace)
        ordinary.close()
    }

    @Test("dark mode maps to the dark AppKit appearance")
    func darkModeMapsToDarkAqua() {
        #expect(RecentHistoryWindowController.appearanceName(for: true) == .darkAqua)
    }

    @Test("light mode maps to the light AppKit appearance")
    func lightModeMapsToAqua() {
        #expect(RecentHistoryWindowController.appearanceName(for: false) == .aqua)
    }

    @Test("dashboard can shrink beside a call window")
    func dashboardUsesCompactMinimumWidth() {
        #expect(DashboardWindowLayout.minimumContentWidth == 520)
        #expect(DashboardWindowLayout.minimumContentWidth < 900)
        #expect(DashboardWindowLayout.minimumContentHeight == 600)
    }

    @Test("menu bar meeting placement uses the top-right of the active display")
    func menuBarMeetingPlacementUsesTopRightOfDisplay() {
        let visibleFrame = NSRect(x: -1920, y: 23, width: 1920, height: 1057)
        let frame = DashboardWindowPlacement.compactTrailingFrame(
            currentFrame: NSRect(x: 180, y: 140, width: 1120, height: 790),
            visibleFrame: visibleFrame,
            targetFrameWidth: DashboardWindowLayout.minimumContentWidth
        )

        #expect(frame.maxX == visibleFrame.maxX)
        #expect(frame.maxY == visibleFrame.maxY)
        #expect(frame.width == DashboardWindowLayout.minimumContentWidth)
        #expect(frame.height == 790)
    }

    @Test("menu bar meeting placement stays inside a smaller display")
    func menuBarMeetingPlacementClampsToDisplay() {
        let visibleFrame = NSRect(x: 0, y: 25, width: 500, height: 575)
        let frame = DashboardWindowPlacement.compactTrailingFrame(
            currentFrame: NSRect(x: 100, y: 100, width: 1120, height: 790),
            visibleFrame: visibleFrame,
            targetFrameWidth: DashboardWindowLayout.minimumContentWidth
        )

        #expect(frame == visibleFrame)
    }

    @Test("compact quick notes hides the sidebar only for an open meeting")
    func compactQuickNotesPresentationPolicy() {
        #expect(DashboardWindowLayout.usesCompactQuickNotes(width: 520, hasOpenMeeting: true))
        #expect(!DashboardWindowLayout.usesCompactQuickNotes(width: 600, hasOpenMeeting: true))
        #expect(!DashboardWindowLayout.usesCompactQuickNotes(width: 520, hasOpenMeeting: false))
    }

    @Test("dashboard renders one working custom sidebar toggle")
    func dashboardRendersOneWorkingSidebarToggle() {
        var actionCount = 0
        let expandedControl = SidebarToggleButton(isCollapsed: false) {
            actionCount += 1
        }
        let expandedRenderer = ImageRenderer(content: expandedControl)
        expandedRenderer.proposedSize = ProposedViewSize(width: 36, height: 36)

        #expect(expandedControl.accessibilityTitle == "Collapse sidebar")
        #expect(expandedRenderer.nsImage != nil)

        expandedControl.action()
        #expect(actionCount == 1)

        let collapsedControl = SidebarToggleButton(isCollapsed: true) {}
        let collapsedRenderer = ImageRenderer(content: collapsedControl)
        collapsedRenderer.proposedSize = ProposedViewSize(width: 36, height: 36)

        #expect(collapsedControl.accessibilityTitle == "Expand sidebar")
        #expect(collapsedRenderer.nsImage != nil)
    }

    @Test("meeting header chooses its compact layout at a constrained width")
    func meetingHeaderRendersCompactControls() {
        let selection = LayoutSelectionRecorder()
        let content =
            ResponsiveHorizontalLayout(
                wideIdentifier: "meeting.header.wide",
                compactIdentifier: "meeting.header.compact"
            ) {
                LayoutSelectionProbe(name: "wide", width: 600, recorder: selection)
            } compact: {
                LayoutSelectionProbe(name: "compact", width: 100, recorder: selection)
            }
            .frame(width: 360, height: DashboardWindowLayout.minimumContentHeight)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(
            width: 360,
            height: DashboardWindowLayout.minimumContentHeight
        )

        #expect(renderer.nsImage != nil)

        #expect(selection.names == ["compact"])
    }

    @Test("compact formatting follows editable note-taking workflows")
    func compactFormattingPolicy() {
        #expect(CompactMeetingFormattingPolicy.showsFormattingControls(for: .recording, isPreparing: false))
        #expect(!CompactMeetingFormattingPolicy.showsFormattingControls(for: .recording, isPreparing: true))
        #expect(CompactMeetingFormattingPolicy.showsFormattingControls(for: .noteOnly, isPreparing: false))
        #expect(!CompactMeetingFormattingPolicy.showsFormattingControls(for: .failed, isPreparing: false))
        #expect(!CompactMeetingFormattingPolicy.showsFormattingControls(for: .processing, isPreparing: false))
        #expect(!CompactMeetingFormattingPolicy.showsFormattingControls(for: .completed, isPreparing: false))
    }

    @Test("compact threshold preserves dashboard detail identity")
    func compactThresholdPreservesDashboardDetailIdentity() async {
        let presentation = DashboardLayoutPresentation()
        let lifecycle = DashboardDetailLifecycleRecorder()
        let hostingView = NSHostingView(
            rootView: DashboardLayoutIdentityHarness(
                presentation: presentation,
                lifecycle: lifecycle
            )
        )
        hostingView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: 700, height: DashboardWindowLayout.minimumContentHeight)
        )
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView

        hostingView.layoutSubtreeIfNeeded()
        #expect(await waitForAppearance(lifecycle))
        #expect(lifecycle.appearanceCount == 1)
        #expect(lifecycle.disappearanceCount == 0)

        presentation.usesCompactQuickNotes = true
        hostingView.frame.size.width = DashboardWindowLayout.minimumContentWidth
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()

        #expect(lifecycle.appearanceCount == 1)
        #expect(lifecycle.disappearanceCount == 0)

        presentation.usesCompactQuickNotes = false
        hostingView.frame.size.width = 700
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()

        #expect(lifecycle.appearanceCount == 1)
        #expect(lifecycle.disappearanceCount == 0)
    }

    private func waitForAppearance(_ lifecycle: DashboardDetailLifecycleRecorder) async -> Bool {
        for _ in 0..<50 {
            if lifecycle.appearanceCount > 0 {
                return true
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lifecycle.appearanceCount > 0
    }

    @Test("regular windows are tracked by identity so a reopen cannot strand the Dock icon")
    func openWindowTrackingReturnsToAccessoryAfterLastClose() {
        var registry = RegularWindowRegistry()
        // Kept alive for the whole test: a freed object's address, and so its identifier,
        // is reused by the next allocation.
        let dashboardObject = NSObject()
        let settingsObject = NSObject()
        let dashboard = ObjectIdentifier(dashboardObject)
        let settings = ObjectIdentifier(settingsObject)
        var mustBecomeRegular: Bool
        var mustBecomeAccessory: Bool

        // Only the call that flips the policy reports it: that is the one whose activation
        // must wait a run-loop turn.
        mustBecomeRegular = registry.noteOpened(dashboard, isRegular: false)
        #expect(mustBecomeRegular)
        mustBecomeRegular = registry.noteOpened(dashboard, isRegular: true)
        #expect(!mustBecomeRegular)
        mustBecomeRegular = registry.noteOpened(settings, isRegular: true)
        #expect(!mustBecomeRegular)

        // Reopening the same window (a miniaturized one reports itself as not visible)
        // must not need two closes to undo.
        mustBecomeRegular = registry.noteOpened(dashboard, isRegular: true)
        #expect(!mustBecomeRegular)
        mustBecomeAccessory = registry.noteClosed(dashboard)
        #expect(!mustBecomeAccessory)
        mustBecomeAccessory = registry.noteClosed(settings)
        #expect(mustBecomeAccessory)
        #expect(registry.isEmpty)

        // Closing a window that is not open changes nothing.
        mustBecomeAccessory = registry.noteClosed(dashboard)
        #expect(mustBecomeAccessory)
        mustBecomeRegular = registry.noteOpened(settings, isRegular: false)
        #expect(mustBecomeRegular)
    }

    @Test("dashboard and settings windows never force themselves front while the app may be inactive")
    func regularWindowsDoNotOrderFrontRegardless() throws {
        for file in ["RecentHistoryWindowController.swift", "SettingsWindowController.swift"] {
            let source = try appSource(file)
            #expect(!source.contains("orderFrontRegardless()"), "\(file) orders front regardless")
            #expect(source.contains("MenuBarWindowPresenter.present("), "\(file) bypasses the presenter")
        }
    }

    private func appSource(_ fileName: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("ImlaNativeApp")
            .appendingPathComponent(fileName)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("expanded sidebar fits the window when the folder tree is taller than it")
    func expandedSidebarScrollsLongFolderTree() {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-sidebar-test-\(UUID().uuidString)", isDirectory: true)
        let store = DictationStore(databaseURL: supportDirectory.appendingPathComponent("imla.db"))
        try? store.migrateIfNeeded()
        let controller = ImlaController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store,
            configStore: ConfigStore(supportDirectory: supportDirectory)
        )
        // 40 visible folder rows are far taller than the minimum window.
        controller.appState.folders = (1...40).map { index in
            MeetingFolder(id: Int64(index), name: "Folder \(index)", createdAt: "2026-01-01T00:00:00Z")
        }

        let height = DashboardWindowLayout.minimumContentHeight
        let hostingController = NSHostingController(
            rootView: SidebarView(appState: controller.appState, controller: controller)
        )
        let fitted = hostingController.sizeThatFits(in: NSSize(width: 260, height: height))

        // Without a scroll container the stack cannot shrink below the height
        // of every row, so it reports far more than the window offers.
        #expect(fitted.height <= height)
    }

    @Test("dashboard wires the production sidebar toggle and compact meeting header")
    func dashboardWiresProductionSidebarAndCompactMeetingComposition() {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-window-test-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = supportDirectory.appendingPathComponent("imla.db")
        let store = DictationStore(databaseURL: databaseURL)
        try? store.migrateIfNeeded()
        let controller = ImlaController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store,
            configStore: ConfigStore(supportDirectory: supportDirectory)
        )
        let meeting = MeetingRecord(
            id: 42,
            title: "Compact Header Test",
            startTime: ISO8601DateFormatter().string(from: Date()),
            durationSeconds: 0,
            rawTranscript: "",
            formattedNotes: "",
            wordCount: 0,
            folderID: nil,
            status: .recording
        )
        controller.appState.selectedTab = .meetings
        controller.appState.selectedMeetingID = meeting.id
        controller.appState.selectedMeetingRecord = meeting
        controller.appState.meetingsNavigationState = .document(meeting.id)

        let sidebarPresentation = DashboardSidebarPresentation()
        let rootView = DashboardRootView(
            appState: controller.appState,
            controller: controller,
            sidebarPresentation: sidebarPresentation
        )
        let productionSidebar = rootView.sidebarView
        #expect(!productionSidebar.isCollapsed)
        #expect(SidebarToggleButton.accessibilityIdentifier == "dashboard.sidebar.toggle")

        productionSidebar.onToggleCollapsed()
        #expect(sidebarPresentation.isCollapsed)
        #expect(rootView.sidebarView.isCollapsed)

        let renderer = ImageRenderer(
            content: rootView.frame(
                width: DashboardWindowLayout.minimumContentWidth,
                height: DashboardWindowLayout.minimumContentHeight
            )
        )
        renderer.proposedSize = ProposedViewSize(
            width: DashboardWindowLayout.minimumContentWidth,
            height: DashboardWindowLayout.minimumContentHeight
        )

        let image = renderer.nsImage
        #expect(image != nil)
        #expect(image?.size.width == DashboardWindowLayout.minimumContentWidth)
        #expect(image?.size.height == DashboardWindowLayout.minimumContentHeight)
    }

}

@MainActor
private final class LayoutSelectionRecorder {
    var names: [String] = []
}

private struct LayoutSelectionProbe: View {
    let name: String
    let width: CGFloat
    let recorder: LayoutSelectionRecorder

    var body: some View {
        Color.clear
            .frame(width: width, height: 40)
            .onAppear { recorder.names.append(name) }
    }
}

@MainActor
@Observable
private final class DashboardLayoutPresentation {
    var usesCompactQuickNotes = false
}

@MainActor
private final class DashboardDetailLifecycleRecorder {
    var appearanceCount = 0
    var disappearanceCount = 0
}

private struct DashboardLayoutIdentityHarness: View {
    let presentation: DashboardLayoutPresentation
    let lifecycle: DashboardDetailLifecycleRecorder

    var body: some View {
        DashboardContentLayout(
            usesCompactQuickNotes: presentation.usesCompactQuickNotes
        ) {
            Color.clear
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 300)
        } detail: {
            DashboardDetailIdentityProbe(lifecycle: lifecycle)
        }
    }
}

private struct DashboardDetailIdentityProbe: View {
    let lifecycle: DashboardDetailLifecycleRecorder

    var body: some View {
        Color.clear
            .onAppear { lifecycle.appearanceCount += 1 }
            .onDisappear { lifecycle.disappearanceCount += 1 }
    }
}
