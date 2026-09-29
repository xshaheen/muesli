import AppKit
import OSLog

/// Membership repair for windows that must show on every Space.
///
/// A window tagged `canJoinAllSpaces` is added to each Space when the Space is created, but
/// the window server can later drop it from one: this app's dictation panel, its hint panel,
/// and its status item window were all found missing from one full-screen Space while a
/// freshly made window was on all of them, and nothing in the app had touched their
/// collection behavior. Once dropped, the window is ordered in but never composited on that
/// Space, and setting `collectionBehavior` again does not re-add it. What does re-add it is
/// moving the window to the active Space and then restoring the all-Spaces tag: the window
/// server rebuilds the membership from the current Space outward. The trigger that drops the
/// window is still unknown, so this is repaired at every order-in rather than at a guessed
/// moment.
extension NSWindow {
    private static let spacesLogger = Logger(subsystem: "com.xshaheen.imla", category: "WindowSpaces")

    /// Orders the window front without activating the app, then repairs its Space membership
    /// if the window server left it off the active Space. Returns whether a repair was needed.
    @discardableResult
    func orderFrontOnEverySpace() -> Bool {
        orderFrontRegardless()
        return restoreEverySpaceMembershipIfNeeded()
    }

    /// For a window that is ordered in with `canJoinAllSpaces` but is not on the active Space:
    /// moves it to the active Space and restores the tag, which puts it back on every Space.
    /// `canJoinAllSpaces` and `moveToActiveSpace` cannot be set together, so the swap is
    /// explicit. No-op for windows that are not all-Spaces windows or are already placed.
    @discardableResult
    func restoreEverySpaceMembershipIfNeeded() -> Bool {
        let behavior = collectionBehavior
        guard isVisible, behavior.contains(.canJoinAllSpaces), !isOnActiveSpace else { return false }
        collectionBehavior = behavior.subtracting(.canJoinAllSpaces).union(.moveToActiveSpace)
        orderFrontRegardless()
        // Load-bearing read: it makes AppKit flush the move to the window server before the
        // tag goes back. Restoring in the same transaction, on the next main-queue turn, or
        // after an unrelated CoreGraphics query all left the membership unchanged.
        let moved = isOnActiveSpace
        collectionBehavior = behavior
        Self.spacesLogger.notice("restored all-Spaces membership window=\(self.windowNumber, privacy: .public) level=\(self.level.rawValue, privacy: .public) moved=\(moved, privacy: .public)")
        return true
    }
}
