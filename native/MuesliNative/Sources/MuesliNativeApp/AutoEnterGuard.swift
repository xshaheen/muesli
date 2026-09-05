import AppKit
import Foundation

/// The identity of one running app, reduced to what the auto-enter guards compare.
///
/// Exists so the guards can be exercised without an `NSRunningApplication`: the
/// decision only ever needs a pid and a bundle id.
struct AutoEnterAppIdentity: Equatable, Sendable {
    let processID: pid_t
    let bundleID: String

    init(processID: pid_t, bundleID: String) {
        self.processID = processID
        self.bundleID = bundleID
    }

    init(app: NSRunningApplication) {
        self.init(
            processID: app.processIdentifier,
            bundleID: app.bundleIdentifier ?? ""
        )
    }
}

/// The two decisions that stand between a finished dictation and a synthetic
/// Return going into whatever has OS focus.
///
/// Pure for the same reason `DictationModeResolver` is: a regression here would
/// submit a half-dictated message or press a destructive button, and neither
/// outcome is visible in a build until it has already happened to a user.
enum AutoEnterGuard {

    /// Roles Return would activate rather than submit.
    static let nonTextRoles: Set<String> = [
        kAXButtonRole as String,
        kAXMenuItemRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        "AXLink",
    ]

    /// Stricter than the paste check: the frozen target must itself be frontmost.
    ///
    /// Pasting substitutes `lastExternalApp` when Muesli is frontmost, which is
    /// wrong for a send key — the key goes to whatever is actually focused, so
    /// that substitution could submit into Muesli's own window. Muesli never
    /// satisfies this check.
    static func canDeliver(
        to capturedTarget: DictationSessionTarget?,
        frontmost: AutoEnterAppIdentity?,
        current: AutoEnterAppIdentity
    ) -> Bool {
        guard let capturedTarget else { return false }
        guard let frontmost, frontmost.processID != current.processID else { return false }
        return capturedTarget.matches(
            processID: frontmost.processID,
            bundleID: frontmost.bundleID
        )
    }

    /// Fails open on both unknowns: an untrusted process and an unreadable role
    /// still press, because web and Electron composers routinely report nothing
    /// useful and they are the main reason auto-enter exists.
    static func focusedRoleAcceptsAutoEnter(
        isProcessTrusted: Bool,
        focusedRole: String?
    ) -> Bool {
        guard isProcessTrusted else { return true }
        guard let focusedRole else { return true }
        return !nonTextRoles.contains(focusedRole)
    }
}
