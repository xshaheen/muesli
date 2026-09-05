import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("Dictation mode resolver")
struct DictationModeResolverTests {

    private func config(_ modes: [DictationMode]) -> AppConfig {
        var config = AppConfig()
        config.dictationModes = modes
        return config
    }

    private func mode(
        _ id: String,
        enabled: Bool = true,
        apps: [String] = [],
        websites: [String] = [],
        autoEnter: DictationModeAutoEnter? = nil
    ) -> DictationMode {
        DictationMode(
            id: id,
            name: id.capitalized,
            isEnabled: enabled,
            instructions: "\(id) instructions",
            overrideDefaultInstructions: false,
            appBundleIDs: apps,
            websiteHostnames: websites,
            autoEnter: autoEnter
        )
    }

    // MARK: - Website matching

    /// Covers AE4. A user types the address they recognize, so the entry has to
    /// cover its own subdomains without swallowing a different registrable name.
    @Test("a website entry matches its own host and its subdomains, not a longer label")
    func websiteSuffixMatching() {
        let config = config([mode("notion", websites: ["notion.so"])])

        for host in ["notion.so", "www.notion.so", "docs.notion.so"] {
            let selection = DictationModeResolver.resolve(
                config: config,
                target: DictationModeTarget(bundleID: nil, hostname: host)
            )
            #expect(selection.modeID == "notion", "\(host) should match")
        }

        let unrelated = DictationModeResolver.resolve(
            config: config,
            target: DictationModeTarget(bundleID: nil, hostname: "notion.software")
        )
        #expect(unrelated.source == .defaultInstructions)
    }

    /// Covers AE5. Position is not something the user can see or reorder, so the
    /// more specific address has to win on its own.
    @Test("the longest matching website entry wins regardless of array order")
    func longestWebsiteEntryWins() {
        let broadFirst = config([
            mode("broad", websites: ["notion.so"]),
            mode("specific", websites: ["www.notion.so"]),
        ])
        let specificFirst = config([
            mode("specific", websites: ["www.notion.so"]),
            mode("broad", websites: ["notion.so"]),
        ])
        let target = DictationModeTarget(bundleID: nil, hostname: "www.notion.so")

        #expect(DictationModeResolver.resolve(config: broadFirst, target: target).modeID == "specific")
        #expect(DictationModeResolver.resolve(config: specificFirst, target: target).modeID == "specific")
    }

    @Test("website beats app when both match")
    func websiteBeatsApp() {
        let config = config([
            mode("browser", apps: ["com.google.chrome"]),
            mode("mail", websites: ["mail.google.com"]),
        ])
        let selection = DictationModeResolver.resolve(
            config: config,
            target: DictationModeTarget(bundleID: "com.google.Chrome", hostname: "mail.google.com")
        )
        #expect(selection.modeID == "mail")
        #expect(selection.source == .modeWebsite)
    }

    @Test("app matches break ties by array order")
    func appTiesBreakByOrder() {
        let config = config([
            mode("first", apps: ["com.apple.mail"]),
            mode("second", apps: ["com.apple.mail"]),
        ])
        let selection = DictationModeResolver.resolve(
            config: config,
            target: DictationModeTarget(bundleID: "com.apple.mail", hostname: nil)
        )
        #expect(selection.modeID == "first")
        #expect(selection.source == .modeApp)
    }

    @Test("a disabled mode is skipped and the next enabled mode wins")
    func disabledModeSkipped() {
        let config = config([
            mode("off", enabled: false, apps: ["com.apple.mail"]),
            mode("on", apps: ["com.apple.mail"]),
        ])
        let selection = DictationModeResolver.resolve(
            config: config,
            target: DictationModeTarget(bundleID: "com.apple.mail", hostname: nil)
        )
        #expect(selection.modeID == "on")
    }

    @Test("no match resolves to the named default rather than nothing")
    func noMatchResolvesToDefault() {
        let selection = DictationModeResolver.resolve(
            config: config([mode("mail", apps: ["com.apple.mail"])]),
            target: DictationModeTarget(bundleID: "com.apple.finder", hostname: nil)
        )
        #expect(selection == .default)
        #expect(selection.modeID == "default")
        #expect(selection.modeName == "Default")
        #expect(selection.autoEnter == nil)
    }

    @Test("the selection carries the mode's delivery key")
    func selectionCarriesAutoEnter() {
        let config = config([mode("chat", apps: ["com.tinyspeck.slackmacgap"], autoEnter: .return)])
        let selection = DictationModeResolver.resolve(
            config: config,
            target: DictationModeTarget(bundleID: "com.tinyspeck.slackmacgap", hostname: nil)
        )
        #expect(selection.autoEnter == .return)
    }

    // MARK: - Normalization pins (moved from the retired Writing Styles suites)

    @Test("a bundle id is lowercased and a single-label identifier is rejected")
    func bundleIDNormalization() {
        #expect(DictationModes.normalizedBundleID("Com.Apple.Mail") == "com.apple.mail")
        #expect(DictationModes.normalizedBundleID("  com.apple.mail  ") == "com.apple.mail")
        #expect(DictationModes.normalizedBundleID("mail") == nil)
        #expect(DictationModes.normalizedBundleID("") == nil)
        #expect(DictationModes.normalizedBundleID(nil) == nil)
    }

    @Test("a hostname drops a port and a trailing dot, and rejects a path or query")
    func hostnameNormalization() {
        #expect(DictationModes.normalizedHostname("Example.COM") == "example.com")
        #expect(DictationModes.normalizedHostname("example.com:8443") == "example.com")
        #expect(DictationModes.normalizedHostname("example.com.") == "example.com")
        #expect(DictationModes.normalizedHostname("example.com/path") == nil)
        #expect(DictationModes.normalizedHostname("example.com?q=1") == nil)
        #expect(DictationModes.normalizedHostname("*.example.com") == nil)
        #expect(DictationModes.normalizedHostname("localhost") == nil)
    }

    @Test("a target normalizes both halves on construction")
    func targetNormalizesInput() {
        let target = DictationModeTarget(bundleID: "COM.Apple.Mail", hostname: "WWW.Example.com.")
        #expect(target.bundleID == "com.apple.mail")
        #expect(target.hostname == "www.example.com")
    }

    @Test("an unmatchable target resolves to the default without crashing")
    func emptyTargetResolvesToDefault() {
        let selection = DictationModeResolver.resolve(
            config: config([mode("mail", apps: ["com.apple.mail"])]),
            target: DictationModeTarget(bundleID: nil, hostname: nil)
        )
        #expect(selection == .default)
    }
}
