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

        /// Only chat destinations send on Enter; a mail or editor mode must not.
        var autoEnter: DictationModeAutoEnter? {
            self == .messaging ? .return : nil
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
                appBundleIDs: DictationStyleResolver.curatedBundleCategories
                    .filter { $0.value == builtIn.category }
                    .keys
                    .sorted(),
                websiteHostnames: DictationStyleResolver.curatedHostnameCategories
                    .filter { $0.value == builtIn.category }
                    .keys
                    .sorted(),
                autoEnter: builtIn.autoEnter
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
