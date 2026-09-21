import AppKit
import Foundation
import SwiftUI
import ImlaCore

/// Owns the settings window. Non-modal on purpose: a setting is often changed
/// while looking at a dictation or meeting in the dashboard, and a modal would
/// lock that window for the duration.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let controller: ImlaController
    private var window: NSWindow?

    var presentationWindow: NSWindow? {
        window
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    init(controller: ImlaController) {
        self.controller = controller
    }

    func show() {
        if window == nil {
            buildWindow()
        }
        guard let window else { return }
        applyAppearance(to: window)
        controller.syncAppState()
        let policyJustBecameRegular = controller.noteWindowOpened(window)
        MenuBarWindowPresenter.present(window, policyJustBecameRegular: policyJustBecameRegular)
    }

    func close() {
        window?.close()
    }

    /// Called when the theme preference changes so the chrome follows the in-app
    /// light/dark toggle without waiting for the window to be rebuilt.
    func applyThemeAppearance() {
        guard let window else { return }
        applyAppearance(to: window)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if let closing {
            controller.noteWindowClosed(closing)
        }
        releaseWindowAfterClose(closing)
    }

    /// Drops the window and its SwiftUI tree once AppKit has finished closing.
    ///
    /// `isReleasedWhenClosed` is off so a close never frees an NSWindow AppKit is
    /// still unwinding, which means this controller is what decides when the
    /// hosting view goes. Keeping it around cost the whole settings hierarchy
    /// (`ModelsView` included) for the life of the process after one visit;
    /// rebuilding on the next `show()` is cheap and the frame is autosaved. A
    /// section switch already unmounts the previous section's view, so closing
    /// loses nothing that switching did not.
    private func releaseWindowAfterClose(_ closing: NSWindow?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window === closing, !window.isVisible else { return }
            window.contentView = nil
            window.delegate = nil
            self.window = nil
        }
    }

    /// Same reasoning as the dashboard window: AppKit chrome resolves against the
    /// window's own appearance, not the SwiftUI environment, and `controller.config`
    /// is read because `appState.config` lags it during `syncAppState()`.
    private func applyAppearance(to window: NSWindow) {
        let name = RecentHistoryWindowController.appearanceName(for: controller.config.darkMode)
        if window.appearance?.name != name {
            window.appearance = NSAppearance(named: name)
        }
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowLayout.defaultContentSize),
            styleMask: RecentHistoryWindowController.dashboardStyleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "\(AppIdentity.displayName) Settings"
        window.contentMinSize = NSSize(
            width: SettingsWindowLayout.minimumContentWidth,
            height: SettingsWindowLayout.minimumContentHeight
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Chrome matches the dashboard: content runs to the top edge under floating
        // traffic lights, and the titlebar material resolves against the app theme.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        // With the titlebar hidden there is no drag handle, and the hosting view
        // covering the top band did not move the window. Sidebar, header, and
        // empty space all drag instead; controls still take their own clicks.
        window.isMovableByWindowBackground = true
        window.backgroundColor = ImlaTheme.backgroundDeepNSColor
        applyAppearance(to: window)

        let hostingView = NSHostingView(
            rootView: SettingsRootView(appState: controller.appState, controller: controller)
        )
        // This controller owns the frame; without this SwiftUI's async content pass
        // re-places the window after every setFrame.
        hostingView.sizingOptions = []
        window.contentView = hostingView
        // Restore the last position; on first launch there is none, so centre.
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        self.window = window
    }

    private static let frameAutosaveName = "SettingsWindow"
}
