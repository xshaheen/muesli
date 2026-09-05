import Foundation

/// What is left of the Writing Styles resolver: sanitization of a pre-Modes
/// config, and the decode path that projects it into groups and exceptions,
/// which the mode migration then reads once. Nothing here runs for a config
/// that already has modes.
enum DictationStyleResolver {
    enum ConfigurationError: Error, Equatable, LocalizedError {
        case invalidCanonical(String)

        var errorDescription: String? {
            switch self { case .invalidCanonical(let message): message }
        }
    }

    struct LegacyProjection: Equatable {
        let initialized: Bool
        let groups: [DictationStyleGroup]
        let exceptions: [DictationStyleExactException]
    }
    // Keep this catalog intentionally small. Every bundle ID is already used by
    // Muesli source, and unknown targets remain configurable by the user.
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

    static func sanitizeConfiguration(_ config: AppConfig) -> AppConfig {
        var candidate = config
        candidate.customTranscriptCleanupPrompts = sanitizedCustomStyles(config.customTranscriptCleanupPrompts)
        candidate.dictationStyleCategoryAssignments = sanitizedCategoryAssignments(
            config.dictationStyleCategoryAssignments
        )
        candidate.dictationStyleAppRules = sanitizedAppRules(config.dictationStyleAppRules)
        candidate.dictationStyleDomainRules = sanitizedDomainRules(config.dictationStyleDomainRules)
        return candidate
    }

    /// Projects only valid legacy records. This is intentionally the sole
    /// lossy path; persisted canonical rules never pass through it.
    static func projectLegacyConfiguration(_ config: AppConfig) -> LegacyProjection {
        let sanitized = sanitizeConfiguration(config)
        let styles = sanitized.customTranscriptCleanupPrompts
        let validStyle: (String?) -> String? = { styleID in
            TranscriptCleanupPrompts.resolveOptional(id: styleID, custom: styles)?.id
        }
        var exactTargets = Set<String>()
        var exceptions: [DictationStyleExactException] = []
        for rule in sanitized.dictationStyleDomainRules {
            if let styleID = validStyle(rule.styleID), let target = DictationModes.normalizedHostname(rule.hostname) {
                exactTargets.insert("hostname:\(target)")
                exceptions.append(DictationStyleExactException(id: "legacy-exception-hostname-\(target)", kind: .hostname, target: target, styleID: styleID))
            }
        }
        for rule in sanitized.dictationStyleAppRules {
            if let styleID = validStyle(rule.styleID), let target = DictationModes.normalizedBundleID(rule.bundleID) {
                exactTargets.insert("bundle_id:\(target)")
                exceptions.append(DictationStyleExactException(id: "legacy-exception-bundle-id-\(target)", kind: .bundleID, target: target, styleID: styleID))
            }
        }
        var groups: [DictationStyleGroup] = []
        for legacyCategory in DictationStyleCategory.allCases {
            guard let styleID = validStyle(sanitized.dictationStyleCategoryAssignments[legacyCategory.rawValue]) else { continue }
            var matchers: [DictationStyleMatcher] = []
            for (target, mapped) in curatedHostnameCategories where mapped == legacyCategory && !exactTargets.contains("hostname:\(target)") {
                matchers.append(DictationStyleMatcher(id: "legacy-group-\(legacyCategory.rawValue)-hostname-\(target)", kind: .hostname, pattern: target))
            }
            for (target, mapped) in curatedBundleCategories where mapped == legacyCategory && !exactTargets.contains("bundle_id:\(target)") {
                matchers.append(DictationStyleMatcher(id: "legacy-group-\(legacyCategory.rawValue)-bundle-id-\(target)", kind: .bundleID, pattern: target))
            }
            for rule in sanitized.dictationStyleDomainRules where category(id: rule.categoryID) == legacyCategory {
                if let target = DictationModes.normalizedHostname(rule.hostname) {
                    matchers.append(DictationStyleMatcher(id: "legacy-group-\(legacyCategory.rawValue)-hostname-\(target)", kind: .hostname, pattern: target))
                }
            }
            for rule in sanitized.dictationStyleAppRules where category(id: rule.categoryID) == legacyCategory {
                if let target = DictationModes.normalizedBundleID(rule.bundleID) {
                    matchers.append(DictationStyleMatcher(id: "legacy-group-\(legacyCategory.rawValue)-bundle-id-\(target)", kind: .bundleID, pattern: target))
                }
            }
            var seen = Set<String>()
            matchers = matchers.filter { seen.insert("\($0.kind.rawValue):\($0.pattern)").inserted }
            groups.append(DictationStyleGroup(id: "legacy-group-\(legacyCategory.rawValue)", name: legacyCategory.displayName, styleID: styleID, matchers: matchers))
        }
        return LegacyProjection(initialized: !groups.isEmpty || !exceptions.isEmpty, groups: groups, exceptions: exceptions)
    }

    private static func category(id: String?) -> DictationStyleCategory? {
        guard let normalized = normalizedReference(id) else { return nil }
        return DictationStyleCategory(rawValue: normalized)
    }

    private static func sanitizedCustomStyles(
        _ styles: [CustomTranscriptCleanupPrompt]
    ) -> [CustomTranscriptCleanupPrompt] {
        var preservedIDs: Set<String> = []
        for style in styles {
            let candidateID = style.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidateID.isEmpty,
               !TranscriptCleanupPrompts.reservedIDs.contains(candidateID) {
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

    private static func sanitizedCategoryAssignments(
        _ assignments: [String: String]
    ) -> [String: String] {
        assignments.reduce(into: [:]) { result, assignment in
            guard let category = DictationStyleCategory(rawValue: assignment.key),
                  let styleID = normalizedReference(assignment.value)
            else {
                return
            }
            result[category.rawValue] = styleID
        }
    }

    private static func sanitizedAppRules(_ rules: [DictationStyleAppRule]) -> [DictationStyleAppRule] {
        var seenBundleIDs = Set<String>()
        let retained = rules.reversed().compactMap { rule -> DictationStyleAppRule? in
            guard let bundleID = DictationModes.normalizedBundleID(rule.bundleID) else { return nil }
            guard seenBundleIDs.insert(bundleID).inserted else { return nil }
            let categoryID = category(id: rule.categoryID)?.rawValue
            let styleID = normalizedReference(rule.styleID)
            let displayName = rule.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return DictationStyleAppRule(
                bundleID: bundleID,
                displayName: displayName,
                categoryID: categoryID,
                styleID: styleID
            )
        }
        return Array(retained.reversed())
    }

    private static func sanitizedDomainRules(
        _ rules: [DictationStyleDomainRule]
    ) -> [DictationStyleDomainRule] {
        var seenHostnames = Set<String>()
        let retained = rules.reversed().compactMap { rule -> DictationStyleDomainRule? in
            guard let hostname = DictationModes.normalizedHostname(rule.hostname) else { return nil }
            guard seenHostnames.insert(hostname).inserted else { return nil }
            let categoryID = category(id: rule.categoryID)?.rawValue
            let styleID = normalizedReference(rule.styleID)
            return DictationStyleDomainRule(
                hostname: hostname,
                categoryID: categoryID,
                styleID: styleID
            )
        }
        return Array(retained.reversed())
    }

    private static func normalizedReference(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
