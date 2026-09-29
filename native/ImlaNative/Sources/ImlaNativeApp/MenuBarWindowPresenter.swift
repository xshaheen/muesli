import AppKit
import OSLog

/// Which of the app's regular (dashboard, settings) windows are open, and when the app must
/// change activation policy because of it. Imla is an accessory app that shows a Dock icon
/// only while one of these windows exists.
///
/// Windows are tracked by identity rather than counted: a miniaturized window reports
/// `isVisible == false`, so a reopen used to be counted as a second open, the count never
/// returned to zero, and the Dock icon stayed after the last window closed.
struct RegularWindowRegistry: Equatable {
    private var openWindows: Set<ObjectIdentifier> = []

    var isEmpty: Bool { openWindows.isEmpty }

    /// Returns whether the app must become a regular app now. It is only true when the policy
    /// is still accessory, and that is the call whose presentation must wait a run-loop turn
    /// because `setActivationPolicy` is applied asynchronously — see `MenuBarWindowPresenter`.
    mutating func noteOpened(_ window: ObjectIdentifier, isRegular: Bool) -> Bool {
        openWindows.insert(window)
        return !isRegular
    }

    /// Returns whether the app should return to the accessory policy.
    mutating func noteClosed(_ window: ObjectIdentifier) -> Bool {
        openWindows.remove(window)
        return openWindows.isEmpty
    }
}

/// Brings one of the app's regular, Space-managed windows (dashboard, settings) to the front.
///
/// The window server assigns a window to a Space when it is ordered in, and for an accessory
/// app that is whatever Space is active at that moment — another app's full-screen Space
/// included, where the window then floats over that app. A regular app's window is kept off
/// full-screen Spaces and activation switches to its desktop instead. `setActivationPolicy(
/// .regular)` returns before the change is applied, so when the policy was flipped in this
/// turn both the order-in and the activation wait for the next one; ordering first and
/// activating later did not help, because it is the order-in that picks the Space.
///
/// Alert flows need the window as a sheet host right after asking for it, so `completion`
/// reports when it has actually been ordered in: synchronously when the app was already
/// regular, a turn later otherwise.
@MainActor
enum MenuBarWindowPresenter {
    /// Where each regular window landed. Space placement cannot be reproduced on demand, so
    /// every order-in leaves a metadata trail: the window's title, booleans, and screen
    /// geometry only. A visible frame as tall as the screen means the menu bar was hidden,
    /// which on a machine without menu-bar auto-hide means a full-screen Space was active.
    private static let logger = Logger(subsystem: "com.xshaheen.imla", category: "Windows")

    static func present(
        _ window: NSWindow,
        policyJustBecameRegular: Bool,
        completion: (() -> Void)? = nil
    ) {
        guard policyJustBecameRegular else {
            orderFront(window, deferred: false)
            completion?()
            return
        }
        DispatchQueue.main.async {
            orderFront(window, deferred: true)
            completion?()
        }
    }

    private static func orderFront(_ window: NSWindow, deferred: Bool) {
        let screen = NSScreen.main
        let menuBarHiddenBefore = screen.map { $0.visibleFrame.height == $0.frame.height } ?? false
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        logger.notice(
            "present window=\(window.title, privacy: .public) deferred=\(deferred, privacy: .public) policy=\(NSApplication.shared.activationPolicy().rawValue, privacy: .public) appActive=\(NSApplication.shared.isActive, privacy: .public) visible=\(window.isVisible, privacy: .public) key=\(window.isKeyWindow, privacy: .public) activeSpace=\(window.isOnActiveSpace, privacy: .public) menuBarHiddenBefore=\(menuBarHiddenBefore, privacy: .public)"
        )
        // The Space switch, if any, happens after this turn; record where the window ended up
        // once the window server has had a chance to move it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak window] in
            guard let window else { return }
            let screen = NSScreen.main
            let menuBarHidden = screen.map { $0.visibleFrame.height == $0.frame.height } ?? false
            logger.notice(
                "settled window=\(window.title, privacy: .public) appActive=\(NSApplication.shared.isActive, privacy: .public) visible=\(window.isVisible, privacy: .public) key=\(window.isKeyWindow, privacy: .public) activeSpace=\(window.isOnActiveSpace, privacy: .public) occluded=\(!window.occlusionState.contains(.visible), privacy: .public) menuBarHidden=\(menuBarHidden, privacy: .public)"
            )
        }
    }
}
