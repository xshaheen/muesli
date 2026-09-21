import AppKit

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
    /// is still accessory, and that is the call whose activation must wait a run-loop turn
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
/// `setActivationPolicy(.regular)` returns before the Dock and window server have applied it,
/// so an activation issued in the same run-loop turn can still run against the accessory
/// identity. An accessory app cannot switch Spaces when it activates; its window is instead
/// forced onto whichever Space is active — including another app's full-screen Space, where it
/// floats over that app — rather than onto the desktop a regular app would get. Activation is
/// therefore deferred one turn whenever the policy was just changed.
///
/// The window is still ordered in synchronously: alert flows call `show()` and immediately
/// need `isVisible` to pick a sheet host. Ordering does not activate the app, so it is safe
/// to do before the policy lands.
@MainActor
enum MenuBarWindowPresenter {
    static func present(_ window: NSWindow, policyJustBecameRegular: Bool) {
        window.makeKeyAndOrderFront(nil)
        if policyJustBecameRegular {
            DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
