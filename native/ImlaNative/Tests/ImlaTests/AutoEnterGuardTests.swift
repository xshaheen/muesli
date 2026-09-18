import AppKit
import Foundation
import Testing
@testable import ImlaNativeApp

@Suite("Auto-enter guard")
struct AutoEnterGuardTests {

    private let imla = AutoEnterAppIdentity(processID: 1, bundleID: "com.xshaheen.imla")
    private let chrome = AutoEnterAppIdentity(processID: 42, bundleID: "com.google.Chrome")

    private func target(
        processID: pid_t = 42,
        bundleID: String = "com.google.Chrome"
    ) -> DictationSessionTarget {
        DictationSessionTarget(processID: processID, appName: "Chrome", bundleID: bundleID)
    }

    // MARK: - Delivery target

    /// The send key goes wherever focus is, so Imla being frontmost means the
    /// Return would land in Imla's own window.
    @Test("refuses when Imla itself is frontmost")
    func ownAppFrontmostRefuses() {
        #expect(
            AutoEnterGuard.canDeliver(
                to: target(processID: imla.processID, bundleID: imla.bundleID),
                frontmost: imla,
                current: imla
            ) == false
        )
    }

    @Test("refuses when the captured target is no longer frontmost")
    func targetNoLongerFrontmostRefuses() {
        #expect(
            AutoEnterGuard.canDeliver(
                to: target(processID: 99, bundleID: "com.apple.Safari"),
                frontmost: chrome,
                current: imla
            ) == false
        )
    }

    @Test("allows when the captured target is still frontmost")
    func matchingFrontmostAllows() {
        #expect(
            AutoEnterGuard.canDeliver(to: target(), frontmost: chrome, current: imla) == true
        )
    }

    @Test("refuses without a captured target or a frontmost app")
    func missingInputsRefuse() {
        #expect(AutoEnterGuard.canDeliver(to: nil, frontmost: chrome, current: imla) == false)
        #expect(AutoEnterGuard.canDeliver(to: target(), frontmost: nil, current: imla) == false)
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
