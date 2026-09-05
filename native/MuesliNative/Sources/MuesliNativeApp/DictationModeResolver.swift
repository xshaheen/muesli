import Foundation

/// The normalized identity of the place a dictation is about to land.
///
/// Both fields are already normalized by `DictationModes`, so the resolver never
/// re-parses user input: whatever reaches it is comparable as-is.
struct DictationModeTarget: Equatable, Sendable {
    let bundleID: String?
    let hostname: String?

    init(bundleID: String?, hostname: String?) {
        self.bundleID = DictationModes.normalizedBundleID(bundleID)
        self.hostname = DictationModes.normalizedHostname(hostname)
    }
}

/// The mode chosen for one dictation, frozen with everything its consumers need.
///
/// Carries the prompt text and the delivery key together because both derive from
/// the same selection: resolving twice could hand the cleanup prompt of one mode
/// and the auto-enter key of another to the same dictation.
struct DictationModeSelection: Equatable, Sendable {
    let modeID: String
    let modeName: String
    let instructions: String
    let overrideDefaultInstructions: Bool
    let autoEnter: DictationModeAutoEnter?
    let source: DictationStyleSelectionSource

    /// The no-mode outcome. Named rather than optional so history rows and
    /// telemetry have something concrete to record for "the user's default".
    static let `default` = DictationModeSelection(
        modeID: "default",
        modeName: "Default",
        instructions: "",
        overrideDefaultInstructions: false,
        autoEnter: nil,
        source: .defaultInstructions
    )
}

enum DictationModeResolver {
    /// Picks the mode for a destination, or the default when none applies.
    ///
    /// Website beats app, and the longest matching website entry beats a shorter
    /// one, so a mode for `mail.google.com` wins over a mode for `google.com`
    /// without asking the user to order a list they cannot see. Array order is
    /// only the tie-break, which keeps the outcome deterministic without making
    /// position the thing users have to reason about.
    static func resolve(config: AppConfig, target: DictationModeTarget) -> DictationModeSelection {
        let enabled = config.dictationModes.filter(\.isEnabled)

        if let hostname = target.hostname {
            var best: (mode: DictationMode, length: Int)?
            for mode in enabled {
                for entry in mode.websiteHostnames {
                    guard matches(hostname: hostname, entry: entry) else { continue }
                    if best == nil || entry.count > best!.length {
                        best = (mode, entry.count)
                    }
                }
            }
            if let best {
                return selection(for: best.mode, source: .modeWebsite)
            }
        }

        if let bundleID = target.bundleID,
           let mode = enabled.first(where: { $0.appBundleIDs.contains(bundleID) }) {
            return selection(for: mode, source: .modeApp)
        }

        return .default
    }

    /// A website entry matches its own host and any subdomain of it.
    ///
    /// A user types the address they recognize, so `notion.so` has to cover
    /// `www.notion.so`. The leading dot is what keeps `notion.software` out.
    static func matches(hostname: String, entry: String) -> Bool {
        guard let entry = DictationModes.normalizedHostname(entry) else { return false }
        if hostname == entry { return true }
        return hostname.hasSuffix("." + entry)
    }

    private static func selection(
        for mode: DictationMode,
        source: DictationStyleSelectionSource
    ) -> DictationModeSelection {
        DictationModeSelection(
            modeID: mode.id,
            modeName: mode.name,
            instructions: mode.instructions,
            overrideDefaultInstructions: mode.overrideDefaultInstructions,
            autoEnter: mode.autoEnter,
            source: source
        )
    }
}
