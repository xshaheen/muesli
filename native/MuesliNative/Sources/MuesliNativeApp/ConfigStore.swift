import Foundation
import MuesliCore

final class ConfigStore {
    private let configURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(supportDirectory: URL = AppIdentity.supportDirectoryURL) {
        self.configURL = supportDirectory.appendingPathComponent("config.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    /// A missing config file is a genuinely fresh install, so the built-in modes
    /// arrive enabled there and only there (R8). An unreadable file is not: it keeps
    /// its bytes on disk, writes nothing, and loads defaults in memory, so a parse
    /// bug can never cost the user a config it could not read.
    func load() -> AppConfig {
        ensureDirectory()
        guard let data = try? Data(contentsOf: configURL) else {
            var fresh = AppConfig()
            fresh.dictationModes = DictationModes.builtInModes(isEnabled: true)
            return fresh
        }
        guard let decoded = try? decoder.decode(AppConfig.self, from: data) else {
            fputs("[config-store] config.json is unreadable; loading defaults without overwriting it\n", stderr)
            return AppConfig()
        }
        // A migrated selection reaches disk on the launch that migrated it, so the
        // rewrite survives a crash and cannot be re-derived from stale keys.
        if decoded.retiredASRBackendMigrationApplied {
            save(decoded)
        }
        return decoded
    }

    func save(_ config: AppConfig) {
        ensureDirectory()
        // Normalization is total: nothing about mode content can refuse a save, so an
        // unrelated setting is never held hostage by a bad mode array (R4).
        guard let data = try? encoder.encode(DictationModes.sanitized(config)) else {
            fputs("[config-store] failed to encode config\n", stderr)
            return
        }
        do {
            try data.write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configURL.path
            )
        } catch {
            fputs("[config-store] failed to save config: \(error)\n", stderr)
        }
    }

    /// Persists a sanitized whole-config candidate before callers publish it as
    /// live style state. A thrown error leaves the caller's prior value intact.
    func saveDictationStyleConfiguration(_ config: AppConfig) throws -> AppConfig {
        try saveCanonicalConfiguration(config)
    }

    private func saveCanonicalConfiguration(_ config: AppConfig) throws -> AppConfig {
        let candidate = DictationModes.sanitized(config)
        let directory = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(candidate)
        let stagedURL = directory.appendingPathComponent(".config-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        try data.write(to: stagedURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stagedURL.path
        )

        if FileManager.default.fileExists(atPath: configURL.path) {
            _ = try FileManager.default.replaceItemAt(
                configURL,
                withItemAt: stagedURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: configURL)
        }
        return candidate
    }

    /// Persists a validated language profile before callers publish it as the
    /// live runtime authority. Legacy provider pins are mirrored only so an
    /// older build can read a deterministic rollback value.
    func saveLanguageProfileConfiguration(_ config: AppConfig) throws -> AppConfig {
        var candidate = config
        candidate.languageProfileNeedsConfirmation = false
        candidate.mirrorLanguageProfileToLegacyPins()
        return try saveCanonicalConfiguration(candidate)
    }

    /// Import uses this seam to prove that the exact portable projection it
    /// previewed is also the one that reaches disk. The comparison happens
    /// before staging a replacement file, so a mismatch cannot partially save.
    func saveDictationStyleRulesetConfiguration(
        _ config: AppConfig,
        expectedRuleset: DictationStyleRuleset
    ) throws -> AppConfig {
        let candidate = try DictationStyleResolver.prepareCanonicalConfiguration(config)
        guard try DictationStyleRulesetCodec.ruleset(from: candidate) == expectedRuleset else {
            throw DictationStyleRulesetCodec.Error.fidelityMismatch
        }
        return try saveDictationStyleConfiguration(candidate)
    }

    func configPath() -> URL {
        configURL
    }

    func supportDirectory() -> URL {
        configURL.deletingLastPathComponent()
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
