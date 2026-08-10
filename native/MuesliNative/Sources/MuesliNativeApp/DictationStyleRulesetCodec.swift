import Foundation

/// Narrow, portable Writing Styles document. It intentionally has no access to
/// the wider app configuration, credentials, context, or transcript history.
struct DictationStyleRuleset: Codable, Equatable {
    static let currentVersion = 1

    struct GlobalDefault: Codable, Equatable {
        var styleID: String
        var prompt: String

        enum CodingKeys: String, CodingKey {
            case styleID = "style_id"
            case prompt
        }
    }

    var version: Int
    var globalDefault: GlobalDefault
    var customStyles: [CustomTranscriptCleanupPrompt]
    var groups: [DictationStyleGroup]
    var exactExceptions: [DictationStyleExactException]

    enum CodingKeys: String, CodingKey {
        case version
        case globalDefault = "global_default"
        case customStyles = "custom_styles"
        case groups
        case exactExceptions = "exact_exceptions"
    }
}

struct DictationStyleRulesetPreview: Equatable {
    let ruleset: DictationStyleRuleset
    let additions: [String]
    let changes: [String]
    let removals: [String]
    let effectiveChanges: [String]
    let rulesWillBeActive: Bool

    static let privacyWarning = "This file contains configured app and site identities, group and style names, and custom instructions. Share it intentionally."
    var privacyWarningText: String { Self.privacyWarning }
}

enum DictationStyleRulesetCodec {
    enum Error: Swift.Error, Equatable, LocalizedError {
        case fileTooLarge
        case invalidFormat
        case unsupportedVersion(Int)
        case invalidRuleset(String)
        case fidelityMismatch

        var errorDescription: String? {
            switch self {
            case .fileTooLarge: "The Writing Styles file exceeds 1 MiB."
            case .invalidFormat: "The file is not a valid Writing Styles export."
            case .unsupportedVersion(let version): "Writing Styles format version \(version) is not supported."
            case .invalidRuleset(let reason): reason
            case .fidelityMismatch: "The imported Writing Styles changed during preparation."
            }
        }
    }

    static let maximumFileBytes = 1_048_576

    static func encode(_ config: AppConfig) throws -> Data {
        let ruleset = try ruleset(from: config)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(ruleset)
        data.append(Data("\n".utf8))
        return data
    }

    static func decode(_ data: Data) throws -> DictationStyleRuleset {
        guard data.count <= maximumFileBytes else { throw Error.fileTooLarge }
        guard let document = try? JSONDecoder().decode(DictationStyleRuleset.self, from: data) else {
            throw Error.invalidFormat
        }
        guard document.version == DictationStyleRuleset.currentVersion else {
            throw Error.unsupportedVersion(document.version)
        }
        try validatePortable(document)
        return canonicalized(document)
    }

    static func ruleset(from config: AppConfig) throws -> DictationStyleRuleset {
        let prepared = try DictationStyleResolver.prepareCanonicalConfiguration(config)
        let ruleset = DictationStyleRuleset(
            version: DictationStyleRuleset.currentVersion,
            globalDefault: .init(styleID: prepared.activeTranscriptCleanupPromptId, prompt: prepared.postProcessorSystemPrompt),
            customStyles: prepared.customTranscriptCleanupPrompts,
            groups: prepared.dictationStyleGroups,
            exactExceptions: prepared.dictationStyleExactExceptions
        )
        try validatePortable(ruleset)
        return canonicalized(ruleset)
    }

    static func candidate(from imported: DictationStyleRuleset, replacing current: AppConfig) throws -> AppConfig {
        try validatePortable(imported)
        var candidate = current
        candidate.activeTranscriptCleanupPromptId = imported.globalDefault.styleID
        candidate.postProcessorSystemPrompt = imported.globalDefault.prompt
        candidate.customTranscriptCleanupPrompts = imported.customStyles
        candidate.dictationStyleRulesetInitialized = true
        candidate.dictationStyleGroups = imported.groups
        candidate.dictationStyleExactExceptions = imported.exactExceptions
        // Import deliberately preserves local activation. A disabled profile can
        // stage portable groups without making them affect the current session.
        candidate = try DictationStyleResolver.prepareCanonicalConfiguration(candidate)
        guard try ruleset(from: candidate) == canonicalized(imported) else {
            throw Error.fidelityMismatch
        }
        return candidate
    }

    static func preview(imported: DictationStyleRuleset, replacing current: AppConfig) throws -> DictationStyleRulesetPreview {
        let currentRuleset = try ruleset(from: current)
        let candidate = try candidate(from: imported, replacing: current)
        let replacement = try ruleset(from: candidate)
        return DictationStyleRulesetPreview(
            ruleset: replacement,
            additions: differences(from: currentRuleset, to: replacement, kind: .addition),
            changes: differences(from: currentRuleset, to: replacement, kind: .change),
            removals: differences(from: currentRuleset, to: replacement, kind: .removal),
            effectiveChanges: effectiveChanges(from: current, to: candidate),
            rulesWillBeActive: current.adaptiveDictationStylesEnabled
        )
    }

    private enum DifferenceKind { case addition, change, removal }

    private static func differences(from current: DictationStyleRuleset, to replacement: DictationStyleRuleset, kind: DifferenceKind) -> [String] {
        var result: [String] = []
        appendDifferences("custom style", current.customStyles, replacement.customStyles, id: \.id, kind: kind, into: &result)
        appendDifferences("group", current.groups, replacement.groups, id: \.id, kind: kind, into: &result)
        appendDifferences("exact exception", current.exactExceptions, replacement.exactExceptions, id: \.id, kind: kind, into: &result)
        if current.globalDefault != replacement.globalDefault {
            if kind == .change { result.append("Global default") }
        }
        return result.sorted()
    }

    private static func appendDifferences<Value: Equatable>(
        _ label: String, _ current: [Value], _ replacement: [Value], id: KeyPath<Value, String>, kind: DifferenceKind, into result: inout [String]
    ) {
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0[keyPath: id], $0) })
        let replacementByID = Dictionary(uniqueKeysWithValues: replacement.map { ($0[keyPath: id], $0) })
        switch kind {
        case .addition:
            result += replacementByID.keys.filter { currentByID[$0] == nil }.map { "Added \(label): \($0)" }
        case .removal:
            result += currentByID.keys.filter { replacementByID[$0] == nil }.map { "Removed \(label): \($0)" }
        case .change:
            result += replacementByID.keys.compactMap { key in
                guard let old = currentByID[key], old != replacementByID[key] else { return nil }
                return "Changed \(label): \(key)"
            }
        }
    }

    private static func effectiveChanges(from current: AppConfig, to candidate: AppConfig) -> [String] {
        let targets = Set((current.dictationStyleExactExceptions + candidate.dictationStyleExactExceptions).map { "\($0.kind.rawValue):\($0.target)" }
            + (current.dictationStyleGroups + candidate.dictationStyleGroups).flatMap { group in group.matchers.map { "\($0.kind.rawValue):\($0.pattern)" } })
        return targets.sorted().compactMap { encoded in
            let pieces = encoded.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2, let kind = DictationStyleMatcherKind(rawValue: pieces[0]) else { return nil }
            let before = DictationStyleResolver.resolve(config: current, bundleID: kind == .bundleID ? pieces[1] : nil, hostname: kind == .hostname ? pieces[1] : nil)
            let after = DictationStyleResolver.resolve(config: candidate, bundleID: kind == .bundleID ? pieces[1] : nil, hostname: kind == .hostname ? pieces[1] : nil)
            return before.styleID == after.styleID && before.prompt == after.prompt ? nil : "Effective style changed for \(pieces[1])"
        }
    }

    private static func canonicalized(_ ruleset: DictationStyleRuleset) -> DictationStyleRuleset {
        var result = ruleset
        result.customStyles.sort { $0.id < $1.id }
        result.groups.sort { $0.id < $1.id }
        result.groups = result.groups.map { group in
            var sorted = group
            sorted.matchers.sort { $0.id < $1.id }
            return sorted
        }
        result.exactExceptions.sort { $0.id < $1.id }
        return result
    }

    private static func validatePortable(_ ruleset: DictationStyleRuleset) throws {
        guard ruleset.version == DictationStyleRuleset.currentVersion else {
            throw Error.unsupportedVersion(ruleset.version)
        }
        guard ruleset.customStyles.count <= 256,
              ruleset.groups.count <= 128,
              ruleset.groups.reduce(0, { $0 + $1.matchers.count }) <= 512,
              ruleset.exactExceptions.count <= 512
        else { throw Error.invalidRuleset("The Writing Styles file exceeds its supported item limits.") }

        var promptBytes = 0
        try validateString(ruleset.globalDefault.styleID, label: "global style ID")
        try validatePrompt(ruleset.globalDefault.prompt, label: "global instructions", totalBytes: &promptBytes)
        for style in ruleset.customStyles {
            try validateString(style.id, label: "style ID")
            try validateString(style.name, label: "style name")
            try validatePrompt(style.prompt, label: "style instructions", totalBytes: &promptBytes)
            guard !TranscriptCleanupPrompts.reservedIDs.contains(style.id) else {
                throw Error.invalidRuleset("Custom styles cannot reuse built-in style IDs.")
            }
        }
        for group in ruleset.groups {
            try validateString(group.id, label: "group ID")
            try validateString(group.name, label: "group name")
            try validateString(group.styleID, label: "group style ID")
            for matcher in group.matchers {
                try validateString(matcher.id, label: "matcher ID")
                try validateString(matcher.pattern, label: "matcher pattern")
            }
        }
        for exception in ruleset.exactExceptions {
            try validateString(exception.id, label: "exception ID")
            try validateString(exception.target, label: "exception target")
            try validateString(exception.styleID, label: "exception style ID")
        }
        var portableConfig = AppConfig()
        portableConfig.activeTranscriptCleanupPromptId = ruleset.globalDefault.styleID
        portableConfig.postProcessorSystemPrompt = ruleset.globalDefault.prompt
        portableConfig.customTranscriptCleanupPrompts = ruleset.customStyles
        portableConfig.dictationStyleRulesetInitialized = true
        portableConfig.dictationStyleGroups = ruleset.groups
        portableConfig.dictationStyleExactExceptions = ruleset.exactExceptions
        do { _ = try DictationStyleResolver.prepareCanonicalConfiguration(portableConfig) }
        catch { throw Error.invalidRuleset(error.localizedDescription) }
    }

    private static func validateString(_ value: String, label: String) throws {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 128,
              !containsForbiddenControls(value, allowingPromptControls: false)
        else { throw Error.invalidRuleset("Invalid \(label).") }
    }

    private static func validatePrompt(_ value: String, label: String, totalBytes: inout Int) throws {
        let bytes = value.utf8.count
        totalBytes += bytes
        guard !value.isEmpty, bytes <= 16_384, totalBytes <= maximumFileBytes,
              !containsForbiddenControls(value, allowingPromptControls: true)
        else { throw Error.invalidRuleset("Invalid \(label).") }
    }

    private static func containsForbiddenControls(_ value: String, allowingPromptControls: Bool) -> Bool {
        value.unicodeScalars.contains { scalar in
            let forbiddenBidi = (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
            if forbiddenBidi { return true }
            guard scalar.value < 0x20 else { return false }
            return !(allowingPromptControls && (scalar.value == 9 || scalar.value == 10 || scalar.value == 13))
        }
    }
}
