import AppKit
import Foundation
import SwiftUI
import ImlaCore

struct DashboardPresentationReadiness<Action> {
    private(set) var isReady = false
    private(set) var isInitialLayoutScheduled = false
    private var queuedActions: [Action] = []

    mutating func enqueue(_ action: Action) -> [Action] {
        guard !isReady else { return [action] }
        queuedActions.append(action)
        return []
    }

    mutating func requestInitialLayout() -> Bool {
        guard !isReady, !isInitialLayoutScheduled else { return false }
        isInitialLayoutScheduled = true
        return true
    }

    mutating func completeInitialLayout() -> [Action] {
        isInitialLayoutScheduled = false
        isReady = true
        let actions = queuedActions
        queuedActions.removeAll()
        return actions
    }

    mutating func cancelInitialLayout() {
        isInitialLayoutScheduled = false
    }
}

enum DashboardWindowPresentation: Equatable {
    case restored
    case compactMeetingTrailing
}

enum DashboardWindowPlacement {
    static func compactTrailingFrame(
        currentFrame: NSRect,
        visibleFrame: NSRect,
        targetFrameWidth: CGFloat
    ) -> NSRect {
        let width = min(targetFrameWidth, visibleFrame.width)
        let height = min(currentFrame.height, visibleFrame.height)
        return NSRect(
            x: visibleFrame.maxX - width,
            y: visibleFrame.maxY - height,
            width: width,
            height: height
        )
    }
}

@MainActor
final class RecentHistoryWindowController: NSObject, NSWindowDelegate {
    typealias ReadyAction = () -> Void

    static let dashboardStyleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
        .fullSizeContentView,
    ]

    private static let frameAutosaveName = "DashboardWindow"

    private let store: DictationStore
    private let controller: ImlaController
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var presentationReadiness = DashboardPresentationReadiness<ReadyAction>()

    var presentationWindow: NSWindow? {
        window
    }

    init(store: DictationStore, controller: ImlaController) {
        self.store = store
        self.controller = controller
    }

    func show(
        whenReady readyAction: ReadyAction? = nil,
        presentation: DashboardWindowPresentation = .restored
    ) {
        if window == nil {
            buildWindow()
        }
        guard let window else { return }
        applyAppearance(to: window)
        controller.syncAppState()
        apply(presentation, to: window)
        let policyJustBecameRegular = controller.noteWindowOpened(window)

        if let readyAction {
            run(presentationReadiness.enqueue(readyAction))
        }
        MenuBarWindowPresenter.present(window, policyJustBecameRegular: policyJustBecameRegular)
        scheduleInitialOrderedLayoutIfNeeded(for: window)
    }

    private func apply(_ presentation: DashboardWindowPresentation, to window: NSWindow) {
        guard presentation == .compactMeetingTrailing else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? window.screen
            ?? NSScreen.main
        guard let screen else { return }

        let currentContentWidth = window.contentRect(forFrameRect: window.frame).width
        let frameChromeWidth = max(0, window.frame.width - currentContentWidth)
        let targetFrame = DashboardWindowPlacement.compactTrailingFrame(
            currentFrame: window.frame,
            visibleFrame: screen.visibleFrame,
            targetFrameWidth: DashboardWindowLayout.minimumContentWidth + frameChromeWidth
        )
        window.setFrame(targetFrame, display: true, animate: window.isVisible)
    }

    func reload() {
        applyThemeAppearance()
        controller.syncAppState()
    }

    /// Called when the theme preference changes, so the chrome follows the in-app light/dark
    /// toggle instead of waiting for the window to be rebuilt.
    func applyThemeAppearance() {
        guard let window else { return }
        applyAppearance(to: window)
    }

    nonisolated static func appearanceName(for darkMode: Bool) -> NSAppearance.Name {
        darkMode ? .darkAqua : .aqua
    }

    /// The window is created before SwiftUI applies `preferredColorScheme`, and AppKit chrome
    /// (transparent titlebar, traffic lights, resize corners) resolves against the window's own
    /// appearance rather than the SwiftUI environment. Without this the titlebar keeps rendering
    /// dark while the app is set to the light theme.
    ///
    /// Reads `controller.config` rather than `appState.config`: the latter is assigned during
    /// `syncAppState()`, so reading it here would apply the previous theme whenever the appearance
    /// is refreshed before that assignment.
    private func applyAppearance(to window: NSWindow) {
        let name = Self.appearanceName(for: controller.config.darkMode)
        if window.appearance?.name != name {
            window.appearance = NSAppearance(named: name)
        }
    }

    func close() {
        window?.close()
    }

    func updateBackendLabel() {
        controller.syncAppState()
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        let closing = notification.object as? NSWindow
        if let closing {
            controller.noteWindowClosed(closing)
        }
        releaseWindowAfterClose(closing)
    }

    /// Same contract as the settings window: with `isReleasedWhenClosed` off, the
    /// hosting view and every mounted dashboard view (the meeting detail, the
    /// recording player and its 10 Hz timer) lived on after a close for the
    /// life of the process. Deferred a turn so AppKit finishes unwinding the
    /// close before the content view is dropped. Position and size survive via
    /// the frame autosave name set in `buildWindow`.
    private func releaseWindowAfterClose(_ closing: NSWindow?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window === closing, !window.isVisible else { return }
            window.contentView = nil
            window.delegate = nil
            self.window = nil
        }
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 180, y: 140, width: 1120, height: 790),
            styleMask: Self.dashboardStyleMask,
            backing: .buffered,
            defer: false
        )
        window.title = AppIdentity.displayName
        window.contentMinSize = NSSize(width: 640, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // No titlebar band: with .fullSizeContentView the content runs to the top of the
        // window and the traffic lights float over it, so there is no strip to fill.
        //
        // A transparent titlebar previously rendered the system chrome material against
        // the OS theme instead of the app's, which is why this was opaque. `applyAppearance`
        // below pins `window.appearance` to the app's own light/dark choice, so that
        // material now resolves against the same theme the content uses.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        window.backgroundColor = ImlaTheme.backgroundDeepNSColor
        applyAppearance(to: window)

        let rootView = DashboardRootView(
            appState: controller.appState,
            controller: controller
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        window.contentView = hostingView
        // The window used to keep its frame only because it was never released;
        // now that a close rebuilds it, the frame has to be persisted explicitly.
        // The default contentRect above still applies on first launch.
        _ = window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)

        self.window = window

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "f" else {
                return event
            }
            self.controller.appState.focusSearchField = true
            return nil
        }
    }

    private func scheduleInitialOrderedLayoutIfNeeded(for window: NSWindow) {
        guard presentationReadiness.requestInitialLayout() else { return }

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            guard let window, self.window === window else {
                self.presentationReadiness.cancelInitialLayout()
                return
            }

            // An ordered AppKit window can report isVisible == false while a
            // different full-screen Space is active. Its hosting hierarchy is
            // still ready for layout, and feature UI must not wait on occlusion.
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            let actions = self.presentationReadiness.completeInitialLayout()
            self.run(actions)
        }
    }

    private func run(_ actions: [ReadyAction]) {
        for action in actions {
            action()
        }
    }
}
