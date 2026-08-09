import Foundation

enum DictationStyleResolver {
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

    static func normalizeBundleID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidDotSeparatedIdentifier(normalized, requiresMultipleLabels: true) else {
            return nil
        }
        return normalized
    }

    static func normalizeHostname(_ value: String?) -> String? {
        guard let value else { return nil }
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty,
              normalized.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              normalized.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@")) == nil
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
        guard isValidDotSeparatedIdentifier(normalized, requiresMultipleLabels: false) else {
            return nil
        }
        return normalized
    }

    static func hasAppRuleCollision(
        bundleID: String,
        in rules: [DictationStyleAppRule]
    ) -> Bool {
        guard let candidate = normalizeBundleID(bundleID) else { return false }
        return rules.contains { normalizeBundleID($0.bundleID) == candidate }
    }

    static func hasDomainRuleCollision(
        hostname: String,
        in rules: [DictationStyleDomainRule]
    ) -> Bool {
        guard let candidate = normalizeHostname(hostname) else { return false }
        return rules.contains { normalizeHostname($0.hostname) == candidate }
    }

    static func resolve(
        config: AppConfig,
        bundleID: String?,
        hostname: String?
    ) -> DictationStyleSelectionResult {
        resolve(config: config, target: DictationStyleTarget(bundleID: bundleID, hostname: hostname))
    }

    static func resolve(
        config: AppConfig,
        target: DictationStyleTarget
    ) -> DictationStyleSelectionResult {
        let customStyles = sanitizedCustomStyles(config.customTranscriptCleanupPrompts)
        let category = category(for: target, config: config)

        if config.adaptiveDictationStylesEnabled {
            if let hostname = target.hostname,
               let rule = lastDomainRule(for: hostname, in: config.dictationStyleDomainRules),
               let result = selection(
                   styleID: rule.styleID,
                   source: .domain,
                   category: category,
                   customStyles: customStyles
               ) {
                return result
            }

            if let bundleID = target.bundleID,
               let rule = lastAppRule(for: bundleID, in: config.dictationStyleAppRules),
               let result = selection(
                   styleID: rule.styleID,
                   source: .app,
                   category: category,
                   customStyles: customStyles
               ) {
                return result
            }

            if let category,
               let result = selection(
                   styleID: config.dictationStyleCategoryAssignments[category.rawValue],
                   source: .category,
                   category: category,
                   customStyles: customStyles
               ) {
                return result
            }
        }

        if let global = globalSelection(config: config, category: category, customStyles: customStyles) {
            return global
        }

        let fallback = TranscriptCleanupPrompts.builtIns[0]
        return DictationStyleSelectionResult(
            styleID: fallback.id,
            styleName: fallback.name,
            prompt: fallback.prompt,
            isCustom: false,
            source: .builtInFallback,
            categoryID: category?.rawValue
        )
    }

    static func category(
        for target: DictationStyleTarget,
        config: AppConfig
    ) -> DictationStyleCategory? {
        if let hostname = target.hostname,
           let rule = lastDomainRule(for: hostname, in: config.dictationStyleDomainRules),
           let category = category(id: rule.categoryID) {
            return category
        }
        if let bundleID = target.bundleID,
           let rule = lastAppRule(for: bundleID, in: config.dictationStyleAppRules),
           let category = category(id: rule.categoryID) {
            return category
        }
        if let hostname = target.hostname,
           let category = curatedHostnameCategories[hostname] {
            return category
        }
        if let bundleID = target.bundleID {
            return curatedBundleCategories[bundleID]
        }
        return nil
    }

    static func enablingAdaptiveStyles(in config: AppConfig) -> AppConfig {
        guard !config.adaptiveDictationStylesEnabled else { return config }
        var candidate = config
        candidate.adaptiveDictationStylesEnabled = true
        for category in DictationStyleCategory.allCases {
            let assignedID = candidate.dictationStyleCategoryAssignments[category.rawValue]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if assignedID?.isEmpty != false {
                candidate.dictationStyleCategoryAssignments[category.rawValue] = category.defaultStyleID
            }
        }
        return candidate
    }

    static func deletingCustomStyle(id: String, from config: AppConfig) -> AppConfig {
        guard !TranscriptCleanupPrompts.reservedIDs.contains(id),
              config.customTranscriptCleanupPrompts.contains(where: { $0.id == id })
        else {
            return config
        }

        var candidate = config
        candidate.customTranscriptCleanupPrompts.removeAll { $0.id == id }
        if candidate.activeTranscriptCleanupPromptId == id {
            candidate.activeTranscriptCleanupPromptId = TranscriptCleanupPrompts.defaultID
            candidate.postProcessorSystemPrompt = PostProcessorOption.defaultSystemPrompt
        }
        candidate.dictationStyleCategoryAssignments = candidate.dictationStyleCategoryAssignments.filter {
            normalizedReference($0.value) != id
        }
        candidate.dictationStyleAppRules = candidate.dictationStyleAppRules.compactMap { rule in
            var repaired = rule
            if normalizedReference(repaired.styleID) == id { repaired.styleID = nil }
            return hasAssignment(categoryID: repaired.categoryID, styleID: repaired.styleID) ? repaired : nil
        }
        candidate.dictationStyleDomainRules = candidate.dictationStyleDomainRules.compactMap { rule in
            var repaired = rule
            if normalizedReference(repaired.styleID) == id { repaired.styleID = nil }
            return hasAssignment(categoryID: repaired.categoryID, styleID: repaired.styleID) ? repaired : nil
        }
        return candidate
    }

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

    private static func globalSelection(
        config: AppConfig,
        category: DictationStyleCategory?,
        customStyles: [CustomTranscriptCleanupPrompt]
    ) -> DictationStyleSelectionResult? {
        guard let style = TranscriptCleanupPrompts.resolveOptional(
            id: config.activeTranscriptCleanupPromptId,
            custom: customStyles
        ) else {
            return nil
        }
        let prompt = config.postProcessorSystemPrompt
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return DictationStyleSelectionResult(
            styleID: style.id,
            styleName: style.name,
            prompt: prompt,
            isCustom: style.isCustom,
            source: .global,
            categoryID: category?.rawValue
        )
    }

    private static func selection(
        styleID: String?,
        source: DictationStyleSelectionSource,
        category: DictationStyleCategory?,
        customStyles: [CustomTranscriptCleanupPrompt]
    ) -> DictationStyleSelectionResult? {
        guard let style = TranscriptCleanupPrompts.resolveOptional(id: styleID, custom: customStyles) else {
            return nil
        }
        return DictationStyleSelectionResult(
            styleID: style.id,
            styleName: style.name,
            prompt: style.prompt,
            isCustom: style.isCustom,
            source: source,
            categoryID: category?.rawValue
        )
    }

    private static func category(id: String?) -> DictationStyleCategory? {
        guard let normalized = normalizedReference(id) else { return nil }
        return DictationStyleCategory(rawValue: normalized)
    }

    private static func lastAppRule(
        for bundleID: String,
        in rules: [DictationStyleAppRule]
    ) -> DictationStyleAppRule? {
        rules.last { normalizeBundleID($0.bundleID) == bundleID }
    }

    private static func lastDomainRule(
        for hostname: String,
        in rules: [DictationStyleDomainRule]
    ) -> DictationStyleDomainRule? {
        rules.last { normalizeHostname($0.hostname) == hostname }
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
            guard let bundleID = normalizeBundleID(rule.bundleID) else { return nil }
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
            guard let hostname = normalizeHostname(rule.hostname) else { return nil }
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

    private static func hasAssignment(categoryID: String?, styleID: String?) -> Bool {
        categoryID != nil || styleID != nil
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
