import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

/// Covers finding #13 (2026-09-05 review followup): `matchModesByWebsite` must gate
/// every hostname source `resolveMode` consults, not just the identity-capture path
/// in `MuesliController`. A separate suite from `DictationStyleSessionTests` so the
/// two can be edited concurrently without conflicting.
@Suite("Dictation style session website toggle")
struct DictationModeWebsiteToggleTests {
    private let browserTarget = DictationSessionTarget(
        processID: 77,
        appName: "Chrome",
        bundleID: "com.google.Chrome"
    )

    private func config(matchModesByWebsite: Bool) -> AppConfig {
        var config = AppConfig()
        config.enablePostProcessor = true
        config.adaptiveDictationStylesEnabled = true
        config.matchModesByWebsite = matchModesByWebsite
        config.dictationModes = [
            DictationMode(
                id: "docs",
                name: "Docs",
                isEnabled: true,
                instructions: "docs instructions",
                websiteHostnames: ["docs.google.com"]
            ),
        ]
        return config
    }

    private func contextResult(
        snapshot: DictationStyleSessionSnapshot,
        hostname: String
    ) -> DictationSessionContextResult {
        DictationSessionContextResult(
            sessionID: snapshot.id,
            context: DictationContext(
                processID: browserTarget.processID,
                appName: browserTarget.appName,
                bundleID: browserTarget.bundleID,
                documentContext: "",
                selectedText: "",
                url: "docs.google.com/document/d/1",
                hostname: hostname,
                ocrText: ""
            )
        )
    }

    private func identity(hostname: String) -> DictationSessionIdentity {
        DictationSessionIdentity(
            processID: browserTarget.processID,
            bundleID: browserTarget.bundleID,
            hostname: hostname
        )
    }

    @Test("a matching screen-context hostname is ignored when the website toggle is off")
    func screenContextHostnameIgnoredWhenToggleOff() {
        let snapshot = DictationStyleSessionSnapshot(
            target: browserTarget,
            config: config(matchModesByWebsite: false),
            mode: .standard
        )
        let context = contextResult(snapshot: snapshot, hostname: "docs.google.com")

        let selection = snapshot.resolveMode(context: context)
        #expect(selection == .default)
    }

    @Test("a matching identity hostname is ignored when the website toggle is off")
    func identityHostnameIgnoredWhenToggleOff() {
        let snapshot = DictationStyleSessionSnapshot(
            target: browserTarget,
            config: config(matchModesByWebsite: false),
            mode: .standard
        )

        let selection = snapshot.resolveMode(context: nil, identity: identity(hostname: "docs.google.com"))
        #expect(selection == .default)
    }

    @Test("a matching hostname still resolves the mode when the website toggle is on")
    func hostnameResolvesWhenToggleOn() {
        let snapshot = DictationStyleSessionSnapshot(
            target: browserTarget,
            config: config(matchModesByWebsite: true),
            mode: .standard
        )
        let context = contextResult(snapshot: snapshot, hostname: "docs.google.com")

        let selection = snapshot.resolveMode(context: context)
        #expect(selection.modeID == "docs")
        #expect(selection.source == .modeWebsite)
    }
}
