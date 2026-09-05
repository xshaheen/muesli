import AppKit
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Auto-enter guard")
struct AutoEnterGuardTests {

    private let muesli = AutoEnterAppIdentity(processID: 1, bundleID: "com.muesli.app")
    private let chrome = AutoEnterAppIdentity(processID: 42, bundleID: "com.google.Chrome")

    private func target(
        processID: pid_t = 42,
        bundleID: String = "com.google.Chrome"
    ) -> DictationSessionTarget {
        DictationSessionTarget(processID: processID, appName: "Chrome", bundleID: bundleID)
    }

    // MARK: - Delivery target

    /// The send key goes wherever focus is, so Muesli being frontmost means the
    /// Return would land in Muesli's own window.
    @Test("refuses when Muesli itself is frontmost")
    func ownAppFrontmostRefuses() {
        #expect(
            AutoEnterGuard.canDeliver(
                to: target(processID: muesli.processID, bundleID: muesli.bundleID),
                frontmost: muesli,
                current: muesli
            ) == false
        )
    }

    @Test("refuses when the captured target is no longer frontmost")
    func targetNoLongerFrontmostRefuses() {
        #expect(
            AutoEnterGuard.canDeliver(
                to: target(processID: 99, bundleID: "com.apple.Safari"),
                frontmost: chrome,
                current: muesli
            ) == false
        )
    }

    @Test("allows when the captured target is still frontmost")
    func matchingFrontmostAllows() {
        #expect(
            AutoEnterGuard.canDeliver(to: target(), frontmost: chrome, current: muesli) == true
        )
    }

    @Test("refuses without a captured target or a frontmost app")
    func missingInputsRefuse() {
        #expect(AutoEnterGuard.canDeliver(to: nil, frontmost: chrome, current: muesli) == false)
        #expect(AutoEnterGuard.canDeliver(to: target(), frontmost: nil, current: muesli) == false)
    }

    // MARK: - Focused role

    /// Return activates these rather than submitting text, so a dictation that
    /// happened to land next to a button must not press it.
    @Test("refuses a focused role Return would activate")
    func denylistedRoleRefuses() {
        for role in ["AXButton", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXLink"] {
            #expect(
                AutoEnterGuard.focusedRoleAcceptsAutoEnter(
                    isProcessTrusted: true,
                    focusedRole: role
                ) == false,
                "\(role) should refuse auto-enter"
            )
        }
    }

    @Test("allows a text-entry role")
    func textRoleAllows() {
        #expect(
            AutoEnterGuard.focusedRoleAcceptsAutoEnter(
                isProcessTrusted: true,
                focusedRole: "AXTextArea"
            ) == true
        )
    }

    /// Fails open: web and Electron composers routinely report no usable role and
    /// they are the main reason auto-enter exists.
    @Test("allows when the focused role cannot be read")
    func unreadableRoleFailsOpen() {
        #expect(
            AutoEnterGuard.focusedRoleAcceptsAutoEnter(
                isProcessTrusted: true,
                focusedRole: nil
            ) == true
        )
    }

    /// Without Accessibility trust no role is ever readable, so the guard must not
    /// silently disable a feature the user configured.
    @Test("allows when Accessibility is not trusted")
    func untrustedProcessFailsOpen() {
        #expect(
            AutoEnterGuard.focusedRoleAcceptsAutoEnter(
                isProcessTrusted: false,
                focusedRole: "AXButton"
            ) == true
        )
    }
}
