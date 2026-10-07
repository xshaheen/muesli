import AppKit
import OSLog

/// Membership repair for windows that must show on every Space.
///
/// A window tagged `canJoinAllSpaces` is meant to be on each Space, but the window server
/// leaves long-lived windows off a full-screen Space another app creates: this app's dictation
/// panel and hint panel were on the desktop Space only while a status item window made later
/// was on both, and nothing in the app had touched their collection behavior. Once off, the
/// window is ordered in there but never composited, and nothing done to that window-server
/// window puts it back. Resetting the behavior, toggling the level, `close()` on a window that
/// is not released when closed, and swapping in `moveToActiveSpace` were all tried against a
/// full-screen Space and left the membership as it was; the swap does work against the desktop
/// Space, which is how an earlier version of this file came to ship it. Only a new window gets
/// fresh membership, so the repair builds a replacement of the owner's class, moves the content
/// view across, and copies the chrome. The trigger for the drop is still unknown, so owners
/// check at every order-in.
extension NSWindow {
    private static let spacesLogger = Logger(subsystem: "com.xshaheen.imla", category: "WindowSpaces")

    /// Ordered in with the all-Spaces tag, yet the window server left it off the active Space.
    var isMissingFromActiveSpace: Bool {
        isVisible && collectionBehavior.contains(.canJoinAllSpaces) && !isOnActiveSpace
    }

    /// Replaces this window with one `make` builds: the content view, frame, level, behavior,
    /// and chrome carry over, this window is closed, and the replacement is ordered front.
    /// `make` only has to produce a bare window of the right class and style mask.
    func replacedOnActiveSpace<Window: NSWindow>(making make: () -> Window) -> Window {
        let fresh = make()
        if let panel = self as? NSPanel, let freshPanel = fresh as? NSPanel {
            // `isFloatingPanel` rewrites the level, so it goes before the level copy.
            freshPanel.isFloatingPanel = panel.isFloatingPanel
            freshPanel.becomesKeyOnlyIfNeeded = panel.becomesKeyOnlyIfNeeded
            freshPanel.worksWhenModal = panel.worksWhenModal
        }
        fresh.isReleasedWhenClosed = isReleasedWhenClosed
        fresh.level = level
        fresh.collectionBehavior = collectionBehavior
        fresh.sharingType = sharingType
        fresh.backgroundColor = backgroundColor
        fresh.isOpaque = isOpaque
        fresh.hasShadow = hasShadow
        fresh.ignoresMouseEvents = ignoresMouseEvents
        fresh.hidesOnDeactivate = hidesOnDeactivate
        fresh.isMovableByWindowBackground = isMovableByWindowBackground
        fresh.alphaValue = alphaValue
        fresh.contentMinSize = contentMinSize
        fresh.contentMaxSize = contentMaxSize
        fresh.delegate = delegate
        fresh.setFrame(frame, display: false)
        let content = contentView
        contentView = nil
        fresh.contentView = content
        orderOut(nil)
        close()
        fresh.orderFrontRegardless()
        Self.spacesLogger.notice("replaced window off the active Space old=\(self.windowNumber, privacy: .public) new=\(fresh.windowNumber, privacy: .public) level=\(fresh.level.rawValue, privacy: .public) onActiveSpace=\(fresh.isOnActiveSpace, privacy: .public)")
        return fresh
    }
}
