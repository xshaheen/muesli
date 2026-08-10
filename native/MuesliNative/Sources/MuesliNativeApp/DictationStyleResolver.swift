import Foundation

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
            if config.dictationStyleRulesetInitialized {
                if let hostname = target.hostname,
                   let exception = config.dictationStyleExactExceptions.last(where: {
                       $0.kind == .hostname && $0.target == hostname
                   }), let result = selection(styleID: exception.styleID, source: .exception, category: nil, customStyles: customStyles) {
                    return result
                }
                if let bundleID = target.bundleID,
                   let exception = config.dictationStyleExactExceptions.last(where: {
                       $0.kind == .bundleID && $0.target == bundleID
                   }), let result = selection(styleID: exception.styleID, source: .exception, category: nil, customStyles: customStyles) {
                    return result
                }
                if let hostname = target.hostname,
                   let group = bestMatchingGroup(
                       config.dictationStyleGroups,
                       kind: .hostname,
                       target: hostname
                   ),
                   let result = selection(styleID: group.styleID, source: .group, category: nil, groupID: group.id, customStyles: customStyles) {
                    return result
                }
                if let bundleID = target.bundleID,
                   let group = bestMatchingGroup(
                       config.dictationStyleGroups,
                       kind: .bundleID,
                       target: bundleID
                   ),
                   let result = selection(styleID: group.styleID, source: .group, category: nil, groupID: group.id, customStyles: customStyles) {
                    return result
                }
            } else {
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
        guard !config.adaptiveDictationStylesEnabled || !config.dictationStyleRulesetInitialized else { return config }
        var candidate = config
        candidate.adaptiveDictationStylesEnabled = true
        if candidate.dictationStyleRulesetInitialized { return candidate }
        let migration = projectLegacyConfiguration(candidate)
        if migration.initialized {
            candidate.dictationStyleRulesetInitialized = true
            candidate.dictationStyleGroups = migration.groups
            candidate.dictationStyleExactExceptions = migration.exceptions
            return candidate
        }
        candidate.dictationStyleRulesetInitialized = true
        candidate.dictationStyleGroups = starterGroups()
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
        candidate.dictationStyleGroups.removeAll { normalizedReference($0.styleID) == id }
        candidate.dictationStyleExactExceptions.removeAll { normalizedReference($0.styleID) == id }
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

    /// Strict, pure preparation for settings commits and import. It never
    /// normalizes away canonical conflicts: callers must fix those explicitly.
    static func prepareCanonicalConfiguration(_ config: AppConfig) throws -> AppConfig {
        guard config.dictationStyleRulesetQuarantineReason == nil else {
            throw ConfigurationError.invalidCanonical(config.dictationStyleRulesetQuarantineReason!)
        }
        guard config.dictationStyleRulesetInitialized else {
            var migrated = sanitizeConfiguration(config)
            let projection = projectLegacyConfiguration(migrated)
            if projection.initialized {
                migrated.dictationStyleRulesetInitialized = true
                migrated.dictationStyleGroups = projection.groups
                migrated.dictationStyleExactExceptions = projection.exceptions
            }
            return migrated
        }
        let styles = config.customTranscriptCleanupPrompts
        var styleIDs = Set<String>()
        var styleNames = Set<String>()
        for style in styles {
            guard let id = nonEmpty(style.id),
                  id == style.id,
                  !TranscriptCleanupPrompts.reservedIDs.contains(id),
                  styleIDs.insert(id).inserted,
                  let name = nonEmpty(style.name),
                  !TranscriptCleanupPrompts.builtIns.contains(where: {
                      normalizedStyleName($0.name) == normalizedStyleName(name)
                  }),
                  styleNames.insert(normalizedStyleName(name)).inserted,
                  nonEmpty(style.prompt) != nil
            else { throw ConfigurationError.invalidCanonical("Invalid custom writing style") }
        }
        guard validStyleID(config.activeTranscriptCleanupPromptId, customStyles: styles),
              nonEmpty(config.postProcessorSystemPrompt) != nil
        else { throw ConfigurationError.invalidCanonical("Invalid global writing style") }

        var entityIDs = Set<String>()
        var groupNames = Set<String>()
        var matcherIDs = Set<String>()
        var matcherPatterns = Set<String>()
        var targets = Set<String>()
        var matchers: [(groupID: String, matcher: DictationStyleMatcher)] = []
        for group in config.dictationStyleGroups {
            guard !group.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entityIDs.insert(group.id).inserted,
                  let name = nonEmpty(group.name),
                  groupNames.insert(normalizedStyleName(name)).inserted,
                  validStyleID(group.styleID, customStyles: styles)
            else { throw ConfigurationError.invalidCanonical("Invalid writing-style group") }
            for matcher in group.matchers {
                guard !matcher.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      matcherIDs.insert(matcher.id).inserted,
                      let pattern = canonicalPattern(matcher.pattern, kind: matcher.kind),
                      pattern == matcher.pattern,
                      matcherPatterns.insert("\(matcher.kind.rawValue):\(pattern)").inserted
                else { throw ConfigurationError.invalidCanonical("Invalid writing-style matcher") }
                matchers.append((group.id, matcher))
            }
        }
        for exception in config.dictationStyleExactExceptions {
            guard !exception.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entityIDs.insert(exception.id).inserted,
                  validStyleID(exception.styleID, customStyles: styles),
                  normalizedTarget(exception.target, kind: exception.kind) == exception.target,
                  targets.insert("\(exception.kind.rawValue):\(exception.target)").inserted
            else { throw ConfigurationError.invalidCanonical("Invalid writing-style exact exception") }
        }
        for leftIndex in matchers.indices {
            for rightIndex in matchers.indices.dropFirst(leftIndex + 1) {
                let left = matchers[leftIndex]
                let right = matchers[rightIndex]
                guard left.groupID != right.groupID,
                      left.matcher.kind == right.matcher.kind,
                      matcherSpecificity(left.matcher.pattern) == matcherSpecificity(right.matcher.pattern),
                      patternsOverlap(left.matcher.pattern, right.matcher.pattern)
                else { continue }
                throw ConfigurationError.invalidCanonical("Ambiguous writing-style matchers")
            }
        }
        return config
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
            if let styleID = validStyle(rule.styleID), let target = normalizeHostname(rule.hostname) {
                exactTargets.insert("hostname:\(target)")
                exceptions.append(DictationStyleExactException(id: "legacy-exception-hostname-\(target)", kind: .hostname, target: target, styleID: styleID))
            }
        }
        for rule in sanitized.dictationStyleAppRules {
            if let styleID = validStyle(rule.styleID), let target = normalizeBundleID(rule.bundleID) {
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
                if let target = normalizeHostname(rule.hostname) {
                    matchers.append(DictationStyleMatcher(id: "legacy-group-\(legacyCategory.rawValue)-hostname-\(target)", kind: .hostname, pattern: target))
                }
            }
            for rule in sanitized.dictationStyleAppRules where category(id: rule.categoryID) == legacyCategory {
                if let target = normalizeBundleID(rule.bundleID) {
                    matchers.append(DictationStyleMatcher(id: "legacy-group-\(legacyCategory.rawValue)-bundle-id-\(target)", kind: .bundleID, pattern: target))
                }
            }
            var seen = Set<String>()
            matchers = matchers.filter { seen.insert("\($0.kind.rawValue):\($0.pattern)").inserted }
            groups.append(DictationStyleGroup(id: "legacy-group-\(legacyCategory.rawValue)", name: legacyCategory.displayName, styleID: styleID, matchers: matchers))
        }
        return LegacyProjection(initialized: !groups.isEmpty || !exceptions.isEmpty, groups: groups, exceptions: exceptions)
    }

    static func starterGroups() -> [DictationStyleGroup] {
        DictationStyleCategory.allCases.map { category in
            let bundleMatchers = curatedBundleCategories.compactMap { target, mapped in
                mapped == category ? DictationStyleMatcher(id: "starter-\(category.rawValue)-bundle-id-\(target)", kind: .bundleID, pattern: target) : nil
            }
            let hostnameMatchers = curatedHostnameCategories.compactMap { target, mapped in
                mapped == category ? DictationStyleMatcher(id: "starter-\(category.rawValue)-hostname-\(target)", kind: .hostname, pattern: target) : nil
            }
            return DictationStyleGroup(id: "starter-group-\(category.rawValue)", name: category.displayName, styleID: category.defaultStyleID, matchers: bundleMatchers + hostnameMatchers)
        }
    }

    static func canonicalPattern(_ value: String?, kind: DictationStyleMatcherKind) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        if !value.contains("*") {
            return normalizedTarget(value, kind: kind)
        }
        guard var pattern = nonEmpty(value)?.lowercased(),
              pattern.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              pattern.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@:")) == nil
        else { return nil }
        if kind == .hostname, pattern.hasSuffix(".") {
            pattern.removeLast()
        }
        guard !pattern.isEmpty else { return nil }
        while pattern.contains("**") {
            pattern = pattern.replacingOccurrences(of: "**", with: "*")
        }
        let labels = pattern.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.allSatisfy { character in
                      character.isASCII
                          && (character == "*" || character == "-" || character.isLetter || character.isNumber)
                  }
              }),
              patternCanMatchValidTarget(pattern, kind: kind)
        else { return nil }
        if kind == .bundleID, !pattern.contains("*"), labels.count < 2 {
            return nil
        }
        return pattern
    }

    private static func patternCanMatchValidTarget(
        _ pattern: String,
        kind: DictationStyleMatcherKind
    ) -> Bool {
        let labels = pattern.split(separator: ".", omittingEmptySubsequences: false)
        guard kind == .hostname || labels.count > 1 || pattern.contains("*") else { return false }
        return labels.allSatisfy { label in
            let witness = label.replacingOccurrences(of: "*", with: "a")
            return witness.first != "-"
                && witness.last != "-"
                && witness.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    static func matcherSpecificity(_ pattern: String) -> Int {
        pattern.reduce(into: 0) { count, character in
            if character != "*" { count += 1 }
        }
    }

    private static func normalizedTarget(_ value: String, kind: DictationStyleMatcherKind) -> String? {
        switch kind {
        case .bundleID: return normalizeBundleID(value)
        case .hostname: return normalizeHostname(value)
        }
    }

    private static func bestMatchingGroup(
        _ groups: [DictationStyleGroup],
        kind: DictationStyleMatcherKind,
        target: String
    ) -> DictationStyleGroup? {
        let candidates = groups.compactMap { group -> (DictationStyleGroup, Int, Bool)? in
            let matching = group.matchers.filter {
                $0.kind == kind && matchesFullPattern($0.pattern, target: target)
            }
            guard let best = matching.max(by: { isHigherRank(matcherRank($1.pattern), than: matcherRank($0.pattern)) }) else {
                return nil
            }
            return (group, matcherSpecificity(best.pattern), !best.pattern.contains("*"))
        }
        guard let best = candidates.max(by: { isHigherRank(candidateRank($1), than: candidateRank($0)) }) else { return nil }
        let tiedGroups = candidates.filter { candidateRank($0).exact == candidateRank(best).exact && candidateRank($0).specificity == candidateRank(best).specificity }
        guard tiedGroups.count == 1 else { return nil }
        return best.0
    }

    private static func matcherRank(_ pattern: String) -> (exact: Bool, specificity: Int) {
        (!pattern.contains("*"), matcherSpecificity(pattern))
    }

    private static func candidateRank(_ candidate: (DictationStyleGroup, Int, Bool)) -> (exact: Bool, specificity: Int) {
        (candidate.2, candidate.1)
    }

    private static func isHigherRank(
        _ left: (exact: Bool, specificity: Int),
        than right: (exact: Bool, specificity: Int)
    ) -> Bool {
        left.exact != right.exact ? left.exact : left.specificity > right.specificity
    }

    private static func matchesFullPattern(_ pattern: String, target: String) -> Bool {
        var patternIndex = pattern.startIndex
        var targetIndex = target.startIndex
        var wildcardIndex: String.Index?
        var retryTargetIndex: String.Index?

        while targetIndex < target.endIndex {
            if patternIndex < pattern.endIndex, pattern[patternIndex] == target[targetIndex] {
                pattern.formIndex(after: &patternIndex)
                target.formIndex(after: &targetIndex)
            } else if patternIndex < pattern.endIndex, pattern[patternIndex] == "*" {
                wildcardIndex = patternIndex
                pattern.formIndex(after: &patternIndex)
                retryTargetIndex = targetIndex
            } else if let wildcard = wildcardIndex, let retry = retryTargetIndex {
                patternIndex = pattern.index(after: wildcard)
                let nextTargetIndex = target.index(after: retry)
                retryTargetIndex = nextTargetIndex
                targetIndex = nextTargetIndex
            } else {
                return false
            }
        }
        while patternIndex < pattern.endIndex, pattern[patternIndex] == "*" {
            pattern.formIndex(after: &patternIndex)
        }
        return patternIndex == pattern.endIndex
    }

    private static func patternsOverlap(_ left: String, _ right: String) -> Bool {
        let alphabet = Set(left.filter { $0 != "*" } + right.filter { $0 != "*" })
            .union(Set<Character>(["a", "0", "-", "."]))
        let leftCharacters = Array(left)
        let rightCharacters = Array(right)
        var pending = [(0, 0)]
        var visited = Set<[Int]>()

        while let state = pending.popLast() {
            guard visited.insert([state.0, state.1]).inserted else { continue }
            if canFinish(leftCharacters, from: state.0), canFinish(rightCharacters, from: state.1) {
                return true
            }
            if state.0 < leftCharacters.count, leftCharacters[state.0] == "*" {
                pending.append((state.0 + 1, state.1))
            }
            if state.1 < rightCharacters.count, rightCharacters[state.1] == "*" {
                pending.append((state.0, state.1 + 1))
            }
            let leftTransitions = patternTransitions(leftCharacters, from: state.0, alphabet: alphabet)
            let rightTransitions = patternTransitions(rightCharacters, from: state.1, alphabet: alphabet)
            for (character, nextLeft) in leftTransitions {
                for (otherCharacter, nextRight) in rightTransitions where character == otherCharacter {
                    pending.append((nextLeft, nextRight))
                }
            }
        }
        return false
    }

    private static func canFinish(_ pattern: [Character], from index: Int) -> Bool {
        pattern[index...].allSatisfy { $0 == "*" }
    }

    private static func patternTransitions(
        _ pattern: [Character],
        from index: Int,
        alphabet: Set<Character>
    ) -> [(Character, Int)] {
        guard index < pattern.count else { return [] }
        if pattern[index] == "*" {
            return alphabet.map { ($0, index) }
        }
        return [(pattern[index], index + 1)]
    }

    private static func validStyleID(_ id: String, customStyles: [CustomTranscriptCleanupPrompt]) -> Bool {
        TranscriptCleanupPrompts.resolveOptional(id: id, custom: customStyles) != nil
    }

    private static func normalizedStyleName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        normalizedReference(value)
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
        groupID: String? = nil,
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
            categoryID: category?.rawValue,
            groupID: groupID
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
