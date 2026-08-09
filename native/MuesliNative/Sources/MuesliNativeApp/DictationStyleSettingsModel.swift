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

    var confirmationMessage: String {
        var parts: [String] = []
        if repairsGlobal { parts.append("the global style") }
        if categoryCount > 0 { parts.append("\(categoryCount) category assignment\(categoryCount == 1 ? "" : "s")") }
        if appCount > 0 { parts.append("\(appCount) app rule\(appCount == 1 ? "" : "s")") }
        if domainCount > 0 { parts.append("\(domainCount) website rule\(domainCount == 1 ? "" : "s")") }
        guard !parts.isEmpty else {
            return "This custom style will be permanently removed. Existing dictations are not affected."
        }
        return "This custom style will be permanently removed and repair \(parts.joined(separator: ", ")). Existing dictations are not affected."
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
        }
    }
}

enum DictationStyleSettingsModel {
    static func committing(
        current: AppConfig,
        mutate: (inout AppConfig) -> Void,
        persist: (AppConfig) throws -> AppConfig
    ) throws -> AppConfig {
        var candidate = current
        mutate(&candidate)
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

    static func settingCategoryStyle(
        _ styleID: String?,
        category: DictationStyleCategory,
        in config: AppConfig
    ) -> AppConfig {
        var candidate = config
        if let styleID, !styleID.isEmpty {
            candidate.dictationStyleCategoryAssignments[category.rawValue] = styleID
        } else {
            candidate.dictationStyleCategoryAssignments.removeValue(forKey: category.rawValue)
        }
        return candidate
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

    static func settingAppRule(
        bundleID: String,
        categoryID: String?,
        styleID: String?,
        in config: AppConfig
    ) -> AppConfig {
        var candidate = config
        guard let index = candidate.dictationStyleAppRules.firstIndex(where: {
            DictationStyleResolver.normalizeBundleID($0.bundleID)
                == DictationStyleResolver.normalizeBundleID(bundleID)
        }) else { return config }
        candidate.dictationStyleAppRules[index].categoryID = nonEmpty(categoryID)
        candidate.dictationStyleAppRules[index].styleID = nonEmpty(styleID)
        return candidate
    }

    static func removingAppRule(bundleID: String, from config: AppConfig) -> AppConfig {
        var candidate = config
        let normalized = DictationStyleResolver.normalizeBundleID(bundleID)
        candidate.dictationStyleAppRules.removeAll {
            DictationStyleResolver.normalizeBundleID($0.bundleID) == normalized
        }
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

    static func settingDomainRule(
        hostname: String,
        categoryID: String?,
        styleID: String?,
        in config: AppConfig
    ) -> AppConfig {
        var candidate = config
        guard let index = candidate.dictationStyleDomainRules.firstIndex(where: {
            DictationStyleResolver.normalizeHostname($0.hostname)
                == DictationStyleResolver.normalizeHostname(hostname)
        }) else { return config }
        candidate.dictationStyleDomainRules[index].categoryID = nonEmpty(categoryID)
        candidate.dictationStyleDomainRules[index].styleID = nonEmpty(styleID)
        return candidate
    }

    static func removingDomainRule(hostname: String, from config: AppConfig) -> AppConfig {
        var candidate = config
        let normalized = DictationStyleResolver.normalizeHostname(hostname)
        candidate.dictationStyleDomainRules.removeAll {
            DictationStyleResolver.normalizeHostname($0.hostname) == normalized
        }
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
        case .domain: sourceLabel = "Exact website"
        case .app: sourceLabel = "Exact app"
        case .category: sourceLabel = result.categoryID.flatMap(DictationStyleCategory.init(rawValue:))?.displayName ?? "Category"
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
            domainCount: config.dictationStyleDomainRules.filter { $0.styleID == styleID }.count
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
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
