import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("Installed application catalog")
@MainActor
struct InstalledApplicationCatalogTests {

    private func app(_ bundleID: String, _ name: String) -> InstalledApplication {
        InstalledApplication(bundleID: bundleID, displayName: name, applicationURL: nil)
    }

    @Test("an empty query returns every application unchanged")
    func emptyQueryReturnsAll() {
        let apps = [app("com.apple.mail", "Mail"), app("com.apple.notes", "Notes")]
        #expect(InstalledApplicationCatalog.filter(apps, query: "") == apps)
        #expect(InstalledApplicationCatalog.filter(apps, query: "   ") == apps)
    }

    @Test("the filter matches display name and bundle id case-insensitively")
    func filterMatchesNameAndBundleID() {
        let apps = [
            app("com.apple.mail", "Mail"),
            app("com.tinyspeck.slackmacgap", "Slack"),
            app("com.microsoft.vscode", "Visual Studio Code"),
        ]

        #expect(InstalledApplicationCatalog.filter(apps, query: "sla").map(\.bundleID)
            == ["com.tinyspeck.slackmacgap"])
        #expect(InstalledApplicationCatalog.filter(apps, query: "MICROSOFT").map(\.bundleID)
            == ["com.microsoft.vscode"])
        #expect(InstalledApplicationCatalog.filter(apps, query: "studio").map(\.bundleID)
            == ["com.microsoft.vscode"])
        #expect(InstalledApplicationCatalog.filter(apps, query: "zzz").isEmpty)
    }

    /// A running app that the directory scan also found must not appear twice.
    @Test("merging de-duplicates by bundle id and keeps the scanned entry")
    func mergeDeduplicates() {
        let scanned = [app("com.apple.mail", "Mail")]
        let running = [app("com.apple.mail", "Mail (running)"), app("com.apple.notes", "Notes")]

        let merged = InstalledApplicationCatalog.merged(scanned: scanned, running: running)
        #expect(merged.map(\.bundleID) == ["com.apple.mail", "com.apple.notes"])
        #expect(merged.first?.displayName == "Mail")
    }

    @Test("merging sorts by display name so the picker is scannable")
    func mergeSortsByName() {
        let merged = InstalledApplicationCatalog.merged(
            scanned: [app("com.z.app", "Zed"), app("com.a.app", "Arc")],
            running: []
        )
        #expect(merged.map(\.displayName) == ["Arc", "Zed"])
    }

    @Test("a non-application URL is rejected with a readable reason")
    func nonApplicationURLRejected() {
        let url = URL(fileURLWithPath: "/tmp/not-an-app.txt")
        #expect(throws: InstalledApplicationCatalog.CatalogError.self) {
            try InstalledApplicationCatalog.application(at: url)
        }
    }

    @Test("the scan directories cover the three places apps are installed")
    func searchDirectories() {
        let paths = InstalledApplicationCatalog.searchDirectories.map(\.path)
        #expect(paths.contains("/Applications"))
        #expect(paths.contains("/System/Applications"))
        #expect(paths.contains { $0.hasSuffix("/Applications") && $0.contains(NSHomeDirectory()) })
    }

    /// The catalog and a persisted mode have to agree on the identifier, or a mode
    /// picked from this list would never match at dictation time.
    @Test("catalog bundle ids are normalized the same way modes persist them")
    func bundleIDsMatchModeNormalization() {
        #expect(DictationModes.normalizedBundleID("Com.Apple.Mail") == "com.apple.mail")
        let running = InstalledApplicationCatalog.runningApplications()
        #expect(running.allSatisfy { $0.bundleID == $0.bundleID.lowercased() })
        #expect(running.allSatisfy { $0.bundleID != Bundle.main.bundleIdentifier })
    }
}
