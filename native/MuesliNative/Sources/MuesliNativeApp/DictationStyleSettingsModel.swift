import Foundation

struct DictationStyleEffectiveState: Equatable {
    let styleName: String
    let sourceLabel: String
    let accessibilityDescription: String
}

struct DictationStyleDeletionImpact: Equatable {
    let repairsGlobal: Bool
    let categoryCount: Int
    let appCount: Int
    let domainCount: Int
    let groupCount: Int
    let exceptionCount: Int

    var confirmationMessage: String {
        var parts: [String] = []
        if repairsGlobal { parts.append("the global style") }
        if categoryCount > 0 { parts.append("\(categoryCount) category assignment\(categoryCount == 1 ? "" : "s")") }
        if appCount > 0 { parts.append("\(appCount) app rule\(appCount == 1 ? "" : "s")") }
        if domainCount > 0 { parts.append("\(domainCount) website rule\(domainCount == 1 ? "" : "s")") }
        if groupCount > 0 { parts.append("\(groupCount) group assignment\(groupCount == 1 ? "" : "s")") }
        if exceptionCount > 0 { parts.append("\(exceptionCount) exact exception\(exceptionCount == 1 ? "" : "s")") }
        guard !parts.isEmpty else {
            return "This custom style will be permanently removed. Existing dictations are not affected."
        }
        return "This custom style will be permanently removed and repair \(parts.joined(separator: ", ")). Existing dictations are not affected."
    }
}

struct DictationStyleGroupDeletionImpact: Equatable {
    let matcherCount: Int
    let knownTargetCount: Int
    let survivingExceptionCount: Int

    var confirmationMessage: String {
        "This removes \(matcherCount) matcher\(matcherCount == 1 ? "" : "s") affecting \(knownTargetCount) currently known target\(knownTargetCount == 1 ? "" : "s"). \(survivingExceptionCount) independent exception\(survivingExceptionCount == 1 ? "" : "s") will remain."
    }
}

struct DictationStyleAppCandidate: Identifiable, Equatable {
    let bundleID: String
    let displayName: String

    var id: String { bundleID }
}

enum DictationStyleSettingsError: LocalizedError, Equatable {
    case invalidApplication
    case missingBundleID
    case duplicateApplication
    case invalidHostname
    case duplicateHostname
    case missingStyleName
    case duplicateStyleName
    case missingStyleInstructions
    case missingGroupName
    case duplicateGroupName
    case missingGroup

    var errorDescription: String? {
        switch self {
        case .invalidApplication: "Choose a valid macOS application."
        case .missingBundleID: "That application has no bundle identifier and cannot be matched."
        case .duplicateApplication: "A rule for that application already exists."
        case .invalidHostname: "Enter a valid hostname or URL, such as docs.google.com."
        case .duplicateHostname: "A rule for that exact hostname already exists."
        case .missingStyleName: "Enter a style name."
        case .duplicateStyleName: "Use a unique style name."
        case .missingStyleInstructions: "Enter cleanup instructions for this style."
        case .missingGroupName: "Enter a group name."
        case .duplicateGroupName: "Use a unique group name."
        case .missingGroup: "That group no longer exists."
        }
    }
}

enum DictationStyleSettingsModel {
    static func knownTargets(
        appBundleIDs: [String],
        groups: [DictationStyleGroup],
        exactExceptions: [DictationStyleExactException]
    ) -> [DictationStyleTarget] {
        var seen = Set<String>()
        let appTargets = appBundleIDs.compactMap { bundleID -> DictationStyleTarget? in
            guard let bundleID = DictationStyleResolver.normalizeBundleID(bundleID),
                  seen.insert("bundle_id:\(bundleID)").inserted
            else { return nil }
            return DictationStyleTarget(bundleID: bundleID, hostname: nil)
        }
        let configuredTargets = (groups.flatMap(\.matchers).compactMap { matcher -> (DictationStyleMatcherKind, String)? in
            guard !matcher.pattern.contains("*") else { return nil }
            return (matcher.kind, matcher.pattern)
        } + exactExceptions.map { ($0.kind, $0.target) }).compactMap { kind, value -> DictationStyleTarget? in
            guard seen.insert("\(kind.rawValue):\(value)").inserted else { return nil }
            return DictationStyleTarget(
                bundleID: kind == .bundleID ? value : nil,
                hostname: kind == .hostname ? value : nil
            )
        }
        return appTargets + configuredTargets
    }

    static func hasUnappliedStyleChanges(
        styleID: String?,
        name: String,
        instructions: String,
        in config: AppConfig
    ) -> Bool {
        guard let styleID,
              let style = config.customTranscriptCleanupPrompts.first(where: { $0.id == styleID })
        else { return false }
        return style.name != name || style.prompt != instructions
    }

    static func addingGroup(
        name: String,
        styleID: String,
        id: String,
        to config: AppConfig
    ) throws -> AppConfig {
        let normalizedName = normalizedDisplayName(name)
        guard !normalizedName.isEmpty else { throw DictationStyleSettingsError.missingGroupName }
        guard !hasGroupNamed(normalizedName, excludingID: nil, in: config) else {
            throw DictationStyleSettingsError.duplicateGroupName
        }
        var candidate = config
        candidate.dictationStyleGroups.append(DictationStyleGroup(id: id, name: normalizedName, styleID: styleID))
        return candidate
    }

    static func renamingGroup(id: String, name: String, in config: AppConfig) throws -> AppConfig {
        let normalizedName = normalizedDisplayName(name)
        guard !normalizedName.isEmpty else { throw DictationStyleSettingsError.missingGroupName }
        guard !hasGroupNamed(normalizedName, excludingID: id, in: config) else {
            throw DictationStyleSettingsError.duplicateGroupName
        }
        var candidate = config
        guard let index = candidate.dictationStyleGroups.firstIndex(where: { $0.id == id }) else {
            throw DictationStyleSettingsError.missingGroup
        }
        candidate.dictationStyleGroups[index].name = normalizedName
        return candidate
    }

    static func duplicatingGroup(id: String, newID: String, in config: AppConfig) throws -> AppConfig {
        guard let source = config.dictationStyleGroups.first(where: { $0.id == id }) else {
            throw DictationStyleSettingsError.missingGroup
        }
        var suffix = 2
        var name = "\(source.name) Copy"
        while hasGroupNamed(name, excludingID: nil, in: config) {
            name = "\(source.name) Copy \(suffix)"
            suffix += 1
        }
        // Matchers intentionally start empty: copying them would immediately
        // create an equal-specificity cross-group conflict.
        return try addingGroup(name: name, styleID: source.styleID, id: newID, to: config)
    }

    static func deletingGroup(id: String, from config: AppConfig) -> AppConfig {
        var candidate = config
        candidate.dictationStyleGroups.removeAll { $0.id == id }
        return candidate
    }

    static func groupDeletionImpact(
        id: String,
        knownTargets: [DictationStyleTarget],
        in config: AppConfig
    ) throws -> DictationStyleGroupDeletionImpact {
        guard let group = config.dictationStyleGroups.first(where: { $0.id == id }) else {
            throw DictationStyleSettingsError.missingGroup
        }
        let matchedTargets = knownTargets.filter { target in
            group.matchers.contains { DictationStyleResolver.matches($0, target: target) }
        }
        let matchedTargetKeys = Set(matchedTargets.map { "\($0.bundleID ?? "")|\($0.hostname ?? "")" })
        let survivingExceptions = config.dictationStyleExactExceptions.filter { exception in
            group.matchers.contains { matcher in
                matcher.kind == exception.kind
                    && DictationStyleResolver.matches(matcher, target: DictationStyleTarget(
                        bundleID: exception.kind == .bundleID ? exception.target : nil,
                        hostname: exception.kind == .hostname ? exception.target : nil
                    ))
            }
        }
        return DictationStyleGroupDeletionImpact(
            matcherCount: group.matchers.count,
            knownTargetCount: matchedTargetKeys.count,
            survivingExceptionCount: survivingExceptions.count
        )
    }

    static func previewingRulesetReplacement(
        _ imported: DictationStyleRuleset,
        replacing current: AppConfig
    ) throws -> DictationStyleRulesetPreview {
        try DictationStyleRulesetCodec.preview(imported: imported, replacing: current)
    }

    static func replacementCandidate(
        for preview: DictationStyleRulesetPreview,
        replacing current: AppConfig
    ) throws -> AppConfig {
        try DictationStyleRulesetCodec.candidate(from: preview.ruleset, replacing: current)
    }

    static func committing(
        current: AppConfig,
        mutate: (inout AppConfig) -> Void,
        persist: (AppConfig) throws -> AppConfig
    ) throws -> AppConfig {
        var candidate = current
        mutate(&candidate)
        candidate = try DictationStyleResolver.prepareCanonicalConfiguration(candidate)
        return try persist(candidate)
    }

    static func enabledConfiguration(from config: AppConfig, enabled: Bool) -> AppConfig {
        guard enabled else {
            var candidate = config
            candidate.adaptiveDictationStylesEnabled = false
            return candidate
        }
        return DictationStyleResolver.enablingAdaptiveStyles(in: config)
    }

    static func addingAppRule(
        bundleID: String?,
        displayName: String,
        to config: AppConfig
    ) throws -> AppConfig {
        guard let bundleID = DictationStyleResolver.normalizeBundleID(bundleID) else {
            throw DictationStyleSettingsError.missingBundleID
        }
        guard !DictationStyleResolver.hasAppRuleCollision(
            bundleID: bundleID,
            in: config.dictationStyleAppRules
        ) else {
            throw DictationStyleSettingsError.duplicateApplication
        }
        var candidate = config
        candidate.dictationStyleAppRules.append(DictationStyleAppRule(
            bundleID: bundleID,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            styleID: nil
        ))
        return candidate
    }

    static func normalizedHostnameInput(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = DictationStyleResolver.normalizeHostname(trimmed) {
            return direct
        }
        let urlText = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URL(string: urlText)?.host else { return nil }
        return DictationStyleResolver.normalizeHostname(host)
    }

    static func addingDomainRule(input: String, to config: AppConfig) throws -> AppConfig {
        guard let hostname = normalizedHostnameInput(input) else {
            throw DictationStyleSettingsError.invalidHostname
        }
        guard !DictationStyleResolver.hasDomainRuleCollision(
            hostname: hostname,
            in: config.dictationStyleDomainRules
        ) else {
            throw DictationStyleSettingsError.duplicateHostname
        }
        var candidate = config
        candidate.dictationStyleDomainRules.append(DictationStyleDomainRule(
            hostname: hostname,
            styleID: nil
        ))
        return candidate
    }

    static func effectiveState(
        config: AppConfig,
        bundleID: String?,
        hostname: String?
    ) -> DictationStyleEffectiveState {
        let result = DictationStyleResolver.resolve(
            config: config,
            bundleID: bundleID,
            hostname: hostname
        )
        let sourceLabel: String
        switch result.source {
        case .exception: sourceLabel = "Exact exception"
        case .group: sourceLabel = "Group"
        case .domain: sourceLabel = "Exact website"
        case .app: sourceLabel = "Exact app"
        case .category:
            sourceLabel = config.dictationStyleRulesetInitialized
                ? "Group"
                : result.categoryID.flatMap(DictationStyleCategory.init(rawValue:))?.displayName ?? "Category"
        case .global: sourceLabel = "Global style"
        case .builtInFallback: sourceLabel = "Default fallback"
        }
        return DictationStyleEffectiveState(
            styleName: result.styleName,
            sourceLabel: sourceLabel,
            accessibilityDescription: "Effective style: \(result.styleName). Source: \(sourceLabel)."
        )
    }

    static func deletionImpact(styleID: String, in config: AppConfig) -> DictationStyleDeletionImpact {
        DictationStyleDeletionImpact(
            repairsGlobal: config.activeTranscriptCleanupPromptId == styleID,
            categoryCount: config.dictationStyleCategoryAssignments.values.filter { $0 == styleID }.count,
            appCount: config.dictationStyleAppRules.filter { $0.styleID == styleID }.count,
            domainCount: config.dictationStyleDomainRules.filter { $0.styleID == styleID }.count,
            groupCount: config.dictationStyleGroups.filter { $0.styleID == styleID }.count,
            exceptionCount: config.dictationStyleExactExceptions.filter { $0.styleID == styleID }.count
        )
    }

    static func deletingStyle(id: String, from config: AppConfig) -> AppConfig {
        DictationStyleResolver.deletingCustomStyle(id: id, from: config)
    }

    static func validateStyle(
        name: String,
        instructions: String,
        excludingID: String?,
        config: AppConfig
    ) throws {
        let normalizedName = normalizedStyleName(name)
        guard !normalizedName.isEmpty else { throw DictationStyleSettingsError.missingStyleName }
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictationStyleSettingsError.missingStyleInstructions
        }
        guard !hasStyleNamed(normalizedName, excludingID: excludingID, in: config) else {
            throw DictationStyleSettingsError.duplicateStyleName
        }
    }

    static func applicationCandidate(at url: URL) throws -> DictationStyleAppCandidate {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url) else {
            throw DictationStyleSettingsError.invalidApplication
        }
        guard let bundleID = DictationStyleResolver.normalizeBundleID(bundle.bundleIdentifier) else {
            throw DictationStyleSettingsError.missingBundleID
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return DictationStyleAppCandidate(bundleID: bundleID, displayName: name)
    }

    static func hasStyleNamed(_ name: String, excludingID: String?, in config: AppConfig) -> Bool {
        let normalizedName = normalizedStyleName(name)
        return TranscriptCleanupPrompts.builtIns.contains {
            normalizedStyleName($0.name) == normalizedName
        } || config.customTranscriptCleanupPrompts.contains {
            $0.id != excludingID && normalizedStyleName($0.name) == normalizedName
        }
    }

    static func normalizedStyleName(_ name: String) -> String {
        normalizedDisplayName(name)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    static func hasGroupNamed(_ name: String, excludingID: String?, in config: AppConfig) -> Bool {
        let normalizedName = normalizedStyleName(name)
        return config.dictationStyleGroups.contains {
            $0.id != excludingID && normalizedStyleName($0.name) == normalizedName
        }
    }

    private static func normalizedDisplayName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

}
