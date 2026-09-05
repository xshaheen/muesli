import Foundation

/// The one owner of mode identity, naming, target normalization, and the shipped
/// built-in seeds.
///
/// Everything here is total: `sanitized(_:)` never throws and never reorders, so
/// no state a mode list can reach is able to refuse a config save the way the
/// Writing Styles quarantine did. Decode and save both run it, which is what makes
/// the in-memory list equal to the bytes on disk.
enum DictationModes {

    /// Shown when a mode has no usable name. Users see it in the Modes grid, so it
    /// reads as a placeholder rather than an error.
    static let fallbackName = "Untitled Mode"

    /// The deterministic identity for the element at `index`.
    ///
    /// Derived rather than random so a migration that is interrupted and re-run
    /// produces the same ids, and so history rows keep pointing at the same mode.
    static func deterministicID(index: Int) -> String {
        "mode-\(index)"
    }

    // MARK: - Built-ins

    /// The four modes Muesli ships. Their ids are stable across migrations and
    /// resets, and deliberately not in the `mode-<index>` namespace so a derived
    /// id can never collide with one.
    enum BuiltIn: String, CaseIterable, Sendable {
        case email
        case notes
        case coding
        case messaging

        var id: String { "builtin-\(rawValue)" }

        var name: String {
            switch self {
            case .email: "Email"
            case .notes: "Notes"
            case .coding: "Coding"
            case .messaging: "Messaging"
            }
        }

        /// The curated category this mode replaces. Writing becomes Notes.
        var category: DictationStyleCategory {
            switch self {
            case .email: .email
            case .notes: .writing
            case .coding: .code
            case .messaging: .messages
            }
        }

        /// Instruction text is read from the shipped cleanup presets rather than
        /// duplicated, so editing a preset can never leave the two out of step.
        var instructions: String {
            TranscriptCleanupPrompts.builtIns
                .first { $0.id == category.defaultStyleID }?
                .prompt ?? ""
        }
    }

    /// The shipped modes, already sanitized.
    ///
    /// `isEnabled` is the caller's decision because the two seeding paths differ:
    /// a fresh install turns them on, while the memberwise `AppConfig()` default
    /// leaves them off so no test fixture silently acquires a matching mode.
    static func builtInModes(isEnabled: Bool) -> [DictationMode] {
        sanitized(modes: BuiltIn.allCases.map { builtIn in
            DictationMode(
                id: builtIn.id,
                name: builtIn.name,
                isEnabled: isEnabled,
                instructions: builtIn.instructions,
                overrideDefaultInstructions: false,
                appBundleIDs: curatedBundleCategories
                    .filter { $0.value == builtIn.category }
                    .keys
                    .sorted(),
                websiteHostnames: curatedHostnameCategories
                    .filter { $0.value == builtIn.category }
                    .keys
                    .sorted(),
                // Auto-enter sends a message the user has not read yet, so it is never
                // a seeded default -- Messaging's built-in category would otherwise
                // post to Messages/Slack/WhatsApp on a fresh install before the user
                // ever opens the editor. The migration path withholds it on upgrade
                // for the same reason (see `groupDrafts` below); the editor is where
                // it gets turned on.
                autoEnter: nil
            )
        })
    }

    // MARK: - Decoding

    /// A mode array that survives one bad element.
    ///
    /// Decoding `[DictationMode]` directly would lose the whole list to a single
    /// non-object element, which is exactly the failure mode R2 forbids. Each
    /// element decodes through a wrapper that cannot throw, so only the element
    /// that is not an object is dropped.
    struct DecodedArray: Decodable {
        let modes: [DictationMode]

        private struct Element: Decodable {
            let mode: DictationMode?

            init(from decoder: Decoder) throws {
                mode = try? DictationMode(from: decoder)
            }
        }

        init(from decoder: Decoder) throws {
            modes = try [Element](from: decoder).compactMap(\.mode)
        }
    }

    // MARK: - Curated legacy catalogs

    /// The app and website defaults the retired Writing Styles resolver shipped.
    /// They live here because the built-in mode seeds and the legacy migration are
    /// now their only readers.
    static let curatedBundleCategories: [String: DictationStyleCategory] = [
        "com.apple.mail": .email,
        "com.apple.mobilesms": .messages,
        "com.apple.notes": .writing,
        "com.apple.textedit": .writing,
        "com.microsoft.vscode": .code,
        "com.tinyspeck.slackmacgap": .messages,
        "net.whatsapp.whatsapp": .messages,
    ]

    static let curatedHostnameCategories: [String: DictationStyleCategory] = [
        "docs.google.com": .writing,
        "mail.google.com": .email,
        "outlook.office.com": .email,
        "web.whatsapp.com": .messages,
    ]

    // MARK: - Normalization

    /// Normalizes the instructions a user typed.
    ///
    /// The cap lives here rather than in `sanitized(_:)` on purpose: migrated
    /// prompt text must survive whole (R7), and the sanitizer cannot tell typed
    /// text from migrated text. The editor calls this; the sanitizer does not.
    static func normalizedTypedInstructions(_ text: String) -> String {
        CustomInstructions.normalized(text)
    }

    /// A lowercased, dot-separated bundle identifier, or nil when it is not one.
    static func normalizedBundleID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isValidDotSeparatedIdentifier(normalized, requiresMultipleLabels: true) ? normalized : nil
    }

    /// A lowercased registrable hostname, or nil.
    ///
    /// Stricter than the Writing Styles hostname rule in one way: a single-label
    /// host is rejected, because a mode matches a browser address and `localhost`
    /// or a typo'd word would match nothing a user meant.
    static func normalizedHostname(_ value: String?) -> String? {
        guard let value else { return nil }
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty,
              normalized.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              normalized.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@*")) == nil
        else {
            return nil
        }

        let colonCount = normalized.reduce(into: 0) { count, character in
            if character == ":" { count += 1 }
        }
        if colonCount == 1, let colon = normalized.lastIndex(of: ":") {
            let port = normalized[normalized.index(after: colon)...]
            guard !port.isEmpty,
                  port.allSatisfy(\.isNumber),
                  let portNumber = Int(port),
                  (1 ... 65_535).contains(portNumber)
            else {
                return nil
            }
            normalized = String(normalized[..<colon])
        } else if colonCount > 0 {
            return nil
        }

        if normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return isValidDotSeparatedIdentifier(normalized, requiresMultipleLabels: true) ? normalized : nil
    }

    /// The whole-config entry point used by decode and by every save path.
    static func sanitized(_ config: AppConfig) -> AppConfig {
        var candidate = config
        candidate.dictationModes = sanitized(modes: config.dictationModes)
        return candidate
    }

    /// Order-preserving, total, and idempotent.
    ///
    /// Array order is the user's own ordering and also the documented tie-breaker
    /// for resolution, so nothing here sorts. Ownership of a duplicated id or a
    /// duplicated target goes to the earlier element for the same reason.
    static func sanitized(modes: [DictationMode]) -> [DictationMode] {
        var claimedIDs = Set<String>()
        var claimedBundleIDs = Set<String>()
        var claimedHostnames = Set<String>()

        return modes.enumerated().map { index, mode in
            var candidate = mode

            let trimmedName = mode.name.trimmingCharacters(in: .whitespacesAndNewlines)
            candidate.name = trimmedName.isEmpty ? fallbackName : trimmedName

            candidate.id = uniqueID(
                for: mode.id.trimmingCharacters(in: .whitespacesAndNewlines),
                index: index,
                claimed: &claimedIDs
            )

            candidate.appBundleIDs = claimedTargets(
                mode.appBundleIDs,
                normalize: normalizedBundleID,
                claimed: &claimedBundleIDs
            )
            candidate.websiteHostnames = claimedTargets(
                mode.websiteHostnames,
                normalize: normalizedHostname,
                claimed: &claimedHostnames
            )

            return candidate
        }
    }

    // MARK: - Legacy migration (R5-R9)

    /// The mode list a legacy Writing Styles config becomes, exactly once.
    ///
    /// Pure and total: every id it produces is derived from the config's own bytes
    /// (KTD13), so a launch whose migrating save is interrupted re-derives the same
    /// list next time and history rows keep pointing at the same modes.
    ///
    /// Output order is pinned: groups in legacy order, then modes an exception had to
    /// create, then unreferenced custom prompts, then the built-ins that are absent.
    ///
    /// `notes` carries every `logMigration` message this pass produces (dropped
    /// matchers, dropped groups, unresolvable exceptions) so the caller can persist
    /// them and surface a one-time notice; the migration itself stays total either
    /// way (R4/R9's total-sanitize guarantee does not depend on this list).
    static func migratedModes(from config: AppConfig) -> (modes: [DictationMode], notes: [String]) {
        let notes = MigrationNotes()
        let styles = sanitizedLegacyStyles(config.customTranscriptCleanupPrompts)
        let ruleset = legacyRuleset(config, styles: styles)
        var drafts = groupDrafts(
            ruleset.groups,
            styles: styles,
            isEnabled: config.adaptiveDictationStylesEnabled,
            notes: notes
        )
        applyExceptions(
            ruleset.exceptions,
            to: &drafts,
            styles: styles,
            isEnabled: config.adaptiveDictationStylesEnabled,
            notes: notes
        )
        appendUnreferencedPrompts(styles, to: &drafts)
        appendAbsentBuiltIns(to: &drafts)
        let modes = sanitized(modes: uniquelyNamed(drafts.map(\.mode)))
        return (modes, notes.messages)
    }

    /// One mode under construction plus the legacy style it carries, which is how an
    /// exception finds the mode that already speaks in its voice (R6).
    private struct MigrationDraft {
        var mode: DictationMode
        var styleID: String?
    }

    /// A target a group claims, and whether the group named it exactly.
    ///
    /// The distinction only matters when `*.host` collapses onto a bare `host` another
    /// group named exactly: the legacy resolver ranked the exact matcher higher, so the
    /// exact claim keeps the target.
    private struct TargetClaim {
        let value: String
        let isExact: Bool
    }

    private static func groupDrafts(
        _ groups: [DictationStyleGroup],
        styles: [CustomTranscriptCleanupPrompt],
        isEnabled: Bool,
        notes: MigrationNotes
    ) -> [MigrationDraft] {
        var resolved: [(group: DictationStyleGroup, style: TranscriptCleanupPromptPreset)] = []
        for group in groups {
            guard let style = TranscriptCleanupPrompts.resolveOptional(id: group.styleID, custom: styles) else {
                // The legacy resolver skipped a group whose style no longer resolves and
                // fell through to the global prompt, so there is no text to carry over.
                logMigration("dropping group \"\(group.name)\": its writing style no longer exists", notes: notes)
                continue
            }
            resolved.append((group, style))
        }

        let bundleClaims = resolved.map { claims(in: $0.group, kind: .bundleID, notes: notes) }
        let websiteClaims = resolved.map { claims(in: $0.group, kind: .hostname, notes: notes) }
        let bundleOwners = targetOwners(bundleClaims, notes: notes)
        let websiteOwners = targetOwners(websiteClaims, notes: notes)

        return resolved.indices.map { index in
            MigrationDraft(
                mode: DictationMode(
                    id: migratedGroupID(resolved[index].group),
                    name: resolved[index].group.name,
                    isEnabled: isEnabled,
                    // R7: the style's exact bytes, never the typed-instructions cap.
                    instructions: resolved[index].style.prompt,
                    overrideDefaultInstructions: false,
                    appBundleIDs: bundleClaims[index].map(\.value).filter { bundleOwners[$0] == index },
                    websiteHostnames: websiteClaims[index].map(\.value).filter { websiteOwners[$0] == index },
                    // Legacy had no auto-enter. Adopting one on upgrade would press a key
                    // in a destination the user never asked it to.
                    autoEnter: nil
                ),
                styleID: resolved[index].style.id
            )
        }
    }

    /// Sorted so the migration is reproducible even when the legacy groups came from a
    /// projection that iterated an unordered dictionary.
    private static func claims(
        in group: DictationStyleGroup,
        kind: DictationStyleMatcherKind,
        notes: MigrationNotes
    ) -> [TargetClaim] {
        var seen = Set<String>()
        return group.matchers
            .filter { $0.kind == kind }
            .compactMap { matcher in
                switch kind {
                case .bundleID: bundleClaim(matcher.pattern, group: group.name, notes: notes)
                case .hostname: websiteClaim(matcher.pattern, group: group.name, notes: notes)
                }
            }
            .filter { seen.insert($0.value).inserted }
            .sorted { $0.value < $1.value }
    }

    private static func bundleClaim(_ pattern: String, group: String, notes: MigrationNotes) -> TargetClaim? {
        guard !pattern.contains("*"), let bundleID = normalizedBundleID(pattern) else {
            logMigration(
                "dropping matcher \"\(pattern)\" from group \"\(group)\": not an exact bundle identifier",
                notes: notes
            )
            return nil
        }
        return TargetClaim(value: bundleID, isExact: true)
    }

    private static func websiteClaim(_ pattern: String, group: String, notes: MigrationNotes) -> TargetClaim? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("*.") {
            let host = String(trimmed.dropFirst(2))
            // `*.host` is the one wildcard the new model maps losslessly: a website entry
            // matches the host itself and every subdomain of it.
            if !host.contains("*"), let normalized = normalizedHostname(host) {
                return TargetClaim(value: normalized, isExact: false)
            }
        } else if !trimmed.contains("*"), let normalized = normalizedHostname(trimmed) {
            return TargetClaim(value: normalized, isExact: true)
        }
        logMigration("dropping matcher \"\(pattern)\" from group \"\(group)\": no equivalent website entry", notes: notes)
        return nil
    }

    /// The group index that keeps each target, or no entry when the legacy resolver
    /// itself had no winner (equal-rank matchers in two groups resolved to nothing).
    private static func targetOwners(_ claims: [[TargetClaim]], notes: MigrationNotes) -> [String: Int] {
        var byValue: [String: [(index: Int, isExact: Bool)]] = [:]
        for (index, groupClaims) in claims.enumerated() {
            for claim in groupClaims {
                byValue[claim.value, default: []].append((index, claim.isExact))
            }
        }
        return byValue.reduce(into: [:]) { owners, entry in
            let (value, candidates) = entry
            if candidates.count == 1 {
                owners[value] = candidates[0].index
                return
            }
            let exact = candidates.filter(\.isExact)
            if exact.count == 1 {
                owners[value] = exact[0].index
                return
            }
            logMigration("dropping \"\(value)\": more than one writing-style group claimed it", notes: notes)
        }
    }

    /// R8: a category group still carrying its category's default style is the same
    /// thing the built-in mode is, so it keeps the built-in id and "Reset modes"
    /// restores it. Both the starter and the projected id families map.
    private static func migratedGroupID(_ group: DictationStyleGroup) -> String {
        for prefix in ["starter-group-", "legacy-group-"] where group.id.hasPrefix(prefix) {
            guard let category = DictationStyleCategory(rawValue: String(group.id.dropFirst(prefix.count))),
                  group.styleID == category.defaultStyleID,
                  let builtIn = BuiltIn.allCases.first(where: { $0.category == category })
            else {
                continue
            }
            return builtIn.id
        }
        return group.id
    }

    /// R6: an exception outranked every group, so its target moves to the mode that
    /// carries its style and leaves every other mode. Processing in order reproduces
    /// the legacy last-exception-wins rule.
    private static func applyExceptions(
        _ exceptions: [DictationStyleExactException],
        to drafts: inout [MigrationDraft],
        styles: [CustomTranscriptCleanupPrompt],
        isEnabled: Bool,
        notes: MigrationNotes
    ) {
        for exception in exceptions {
            guard let style = TranscriptCleanupPrompts.resolveOptional(id: exception.styleID, custom: styles) else {
                continue
            }
            let normalized = switch exception.kind {
            case .bundleID: normalizedBundleID(exception.target)
            case .hostname: normalizedHostname(exception.target)
            }
            guard let target = normalized else {
                logMigration("dropping exception for \"\(exception.target)\": no equivalent mode target", notes: notes)
                continue
            }

            let index: Int
            if let existing = drafts.firstIndex(where: { $0.styleID == style.id }) {
                index = existing
            } else {
                drafts.append(MigrationDraft(
                    mode: DictationMode(
                        id: "legacy-style-\(style.id)",
                        name: style.name,
                        isEnabled: isEnabled,
                        instructions: style.prompt,
                        overrideDefaultInstructions: false
                    ),
                    styleID: style.id
                ))
                index = drafts.count - 1
            }

            for other in drafts.indices {
                switch exception.kind {
                case .bundleID: drafts[other].mode.appBundleIDs.removeAll { $0 == target }
                case .hostname: drafts[other].mode.websiteHostnames.removeAll { $0 == target }
                }
            }
            switch exception.kind {
            case .bundleID: drafts[index].mode.appBundleIDs.append(target)
            case .hostname: drafts[index].mode.websiteHostnames.append(target)
            }
        }
    }

    /// R7: a custom prompt no group or exception speaks for would otherwise be deleted
    /// by the upgrade, so it survives as a disabled, targetless override mode.
    private static func appendUnreferencedPrompts(
        _ styles: [CustomTranscriptCleanupPrompt],
        to drafts: inout [MigrationDraft]
    ) {
        let referenced = Set(drafts.compactMap(\.styleID))
        for style in styles where !referenced.contains(style.id) {
            guard !style.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            drafts.append(MigrationDraft(
                mode: DictationMode(
                    id: "legacy-prompt-\(style.id)",
                    name: style.name,
                    isEnabled: false,
                    instructions: style.prompt,
                    overrideDefaultInstructions: true
                ),
                styleID: style.id
            ))
        }
    }

    /// R8: every shipped mode is reachable after the upgrade, so "Reset modes" is not
    /// the only way back to one the legacy config had no equivalent for.
    private static func appendAbsentBuiltIns(to drafts: inout [MigrationDraft]) {
        let present = Set(drafts.map(\.mode.id))
        for shipped in builtInModes(isEnabled: false) where !present.contains(shipped.id) {
            drafts.append(MigrationDraft(mode: shipped, styleID: nil))
        }
    }

    /// The editor requires case-insensitively unique names, so a migrated list that
    /// collides would contain modes the user cannot save without renaming them first.
    private static func uniquelyNamed(_ modes: [DictationMode]) -> [DictationMode] {
        var claimed = Set<String>()
        return modes.map { mode in
            var candidate = mode
            let trimmed = mode.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = trimmed.isEmpty ? fallbackName : trimmed
            var name = base
            var suffix = 1
            while !claimed.insert(comparableName(name)).inserted {
                suffix += 1
                name = "\(base) (\(suffix))"
            }
            candidate.name = name
            return candidate
        }
    }

    private static func comparableName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    // MARK: - Legacy projection

    /// The groups and exceptions to migrate: the canonical ruleset when the user has
    /// one, otherwise the projection of the pre-canonical category, app, and domain
    /// rules. The projection is copied here rather than called so that retiring the
    /// Writing Styles resolver cannot change what an upgrading config becomes.
    private static func legacyRuleset(
        _ config: AppConfig,
        styles: [CustomTranscriptCleanupPrompt]
    ) -> (groups: [DictationStyleGroup], exceptions: [DictationStyleExactException]) {
        guard config.dictationStyleGroups.isEmpty, config.dictationStyleExactExceptions.isEmpty else {
            return (config.dictationStyleGroups, config.dictationStyleExactExceptions)
        }
        return projectedLegacyRuleset(config, styles: styles)
    }

    private static func projectedLegacyRuleset(
        _ config: AppConfig,
        styles: [CustomTranscriptCleanupPrompt]
    ) -> (groups: [DictationStyleGroup], exceptions: [DictationStyleExactException]) {
        let resolvedStyleID: (String?) -> String? = {
            TranscriptCleanupPrompts.resolveOptional(id: $0, custom: styles)?.id
        }
        let domainRules = lastRulePerTarget(config.dictationStyleDomainRules) { normalizedHostname($0.hostname) }
        let appRules = lastRulePerTarget(config.dictationStyleAppRules) { normalizedBundleID($0.bundleID) }

        var exactTargets = Set<String>()
        var exceptions: [DictationStyleExactException] = []
        for rule in domainRules {
            guard let styleID = resolvedStyleID(rule.rule.styleID) else { continue }
            exactTargets.insert("hostname:\(rule.target)")
            exceptions.append(DictationStyleExactException(
                id: "legacy-exception-hostname-\(rule.target)",
                kind: .hostname,
                target: rule.target,
                styleID: styleID
            ))
        }
        for rule in appRules {
            guard let styleID = resolvedStyleID(rule.rule.styleID) else { continue }
            exactTargets.insert("bundle_id:\(rule.target)")
            exceptions.append(DictationStyleExactException(
                id: "legacy-exception-bundle-id-\(rule.target)",
                kind: .bundleID,
                target: rule.target,
                styleID: styleID
            ))
        }

        var groups: [DictationStyleGroup] = []
        for category in DictationStyleCategory.allCases {
            guard let styleID = resolvedStyleID(config.dictationStyleCategoryAssignments[category.rawValue]) else {
                continue
            }
            var matchers: [DictationStyleMatcher] = []
            // Sorted, unlike the retired resolver, which iterated the curated
            // dictionaries directly and produced a different order per process.
            for target in curatedHostnameCategories
                .filter({ $0.value == category })
                .keys
                .sorted() where !exactTargets.contains("hostname:\(target)") {
                matchers.append(DictationStyleMatcher(
                    id: "legacy-group-\(category.rawValue)-hostname-\(target)",
                    kind: .hostname,
                    pattern: target
                ))
            }
            for target in curatedBundleCategories
                .filter({ $0.value == category })
                .keys
                .sorted() where !exactTargets.contains("bundle_id:\(target)") {
                matchers.append(DictationStyleMatcher(
                    id: "legacy-group-\(category.rawValue)-bundle-id-\(target)",
                    kind: .bundleID,
                    pattern: target
                ))
            }
            for rule in domainRules where legacyCategory(rule.rule.categoryID) == category {
                matchers.append(DictationStyleMatcher(
                    id: "legacy-group-\(category.rawValue)-hostname-\(rule.target)",
                    kind: .hostname,
                    pattern: rule.target
                ))
            }
            for rule in appRules where legacyCategory(rule.rule.categoryID) == category {
                matchers.append(DictationStyleMatcher(
                    id: "legacy-group-\(category.rawValue)-bundle-id-\(rule.target)",
                    kind: .bundleID,
                    pattern: rule.target
                ))
            }
            var seen = Set<String>()
            matchers = matchers.filter { seen.insert("\($0.kind.rawValue):\($0.pattern)").inserted }
            groups.append(DictationStyleGroup(
                id: "legacy-group-\(category.rawValue)",
                name: category.displayName,
                styleID: styleID,
                matchers: matchers
            ))
        }
        return (groups, exceptions)
    }

    /// The legacy resolver read the *last* rule for a target, so a duplicated target
    /// keeps its last rule in the position that rule held.
    private static func lastRulePerTarget<Rule>(
        _ rules: [Rule],
        target: (Rule) -> String?
    ) -> [(target: String, rule: Rule)] {
        var seen = Set<String>()
        let retained = rules.reversed().compactMap { rule -> (target: String, rule: Rule)? in
            guard let value = target(rule), seen.insert(value).inserted else { return nil }
            return (value, rule)
        }
        return retained.reversed()
    }

    private static func legacyCategory(_ id: String?) -> DictationStyleCategory? {
        guard let id else { return nil }
        return DictationStyleCategory(rawValue: id.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Copied from the retired resolver so the ids groups and exceptions reference stay
    /// resolvable once it is gone.
    private static func sanitizedLegacyStyles(
        _ styles: [CustomTranscriptCleanupPrompt]
    ) -> [CustomTranscriptCleanupPrompt] {
        var preservedIDs: Set<String> = []
        for style in styles {
            let candidateID = style.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidateID.isEmpty, !TranscriptCleanupPrompts.reservedIDs.contains(candidateID) {
                preservedIDs.insert(candidateID)
            }
        }

        var claimedPreservedIDs: Set<String> = []
        var usedIDs = TranscriptCleanupPrompts.reservedIDs.union(preservedIDs)
        var nextGeneratedID = 1
        return styles.map { style in
            var sanitized = style
            let candidateID = style.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if preservedIDs.contains(candidateID), !claimedPreservedIDs.contains(candidateID) {
                sanitized.id = candidateID
                claimedPreservedIDs.insert(candidateID)
            } else {
                repeat {
                    sanitized.id = "custom-style-\(nextGeneratedID)"
                    nextGeneratedID += 1
                } while usedIDs.contains(sanitized.id)
                usedIDs.insert(sanitized.id)
            }
            return sanitized
        }
    }

    /// Accumulates every `logMigration` message from one `migratedModes(from:)` pass.
    ///
    /// A reference type rather than an `inout [String]` threaded through the
    /// migration's helper functions: several of those helpers log from inside a
    /// `map`/`compactMap`/`reduce(into:)` closure, and an `inout` parameter cannot
    /// cross that closure boundary the way a captured reference can.
    private final class MigrationNotes {
        private(set) var messages: [String] = []

        func record(_ message: String) {
            messages.append(message)
        }
    }

    private static func logMigration(_ message: String, notes: MigrationNotes) {
        fputs("[dictation-modes-migration] \(message)\n", stderr)
        notes.record(message)
    }

    // MARK: - Private

    private static func uniqueID(
        for rawID: String,
        index: Int,
        claimed: inout Set<String>
    ) -> String {
        if !rawID.isEmpty, claimed.insert(rawID).inserted {
            return rawID
        }
        // A blank id, or a duplicate of one an earlier element already owns.
        let derived = deterministicID(index: index)
        if claimed.insert(derived).inserted {
            return derived
        }
        // Only reachable when a hand-edited config literally spells `mode-<index>`
        // on some other element. Still derived, so it stays reproducible.
        var suffix = 2
        while !claimed.insert("\(derived)-\(suffix)").inserted {
            suffix += 1
        }
        return "\(derived)-\(suffix)"
    }

    private static func claimedTargets(
        _ values: [String],
        normalize: (String?) -> String?,
        claimed: inout Set<String>
    ) -> [String] {
        values.compactMap { value in
            guard let normalized = normalize(value),
                  claimed.insert(normalized).inserted
            else {
                return nil
            }
            return normalized
        }
    }

    private static func isValidDotSeparatedIdentifier(
        _ value: String,
        requiresMultipleLabels: Bool
    ) -> Bool {
        guard !value.isEmpty else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.contains(where: \.isEmpty),
              !requiresMultipleLabels || labels.count > 1
        else {
            return false
        }
        return labels.allSatisfy { label in
            guard label.first != "-", label.last != "-" else { return false }
            return label.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-")
            }
        }
    }
}
