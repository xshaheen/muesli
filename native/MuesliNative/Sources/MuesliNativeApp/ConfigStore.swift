import Foundation
import MuesliCore

final class ConfigStore {
    /// The pre-migration copy of `config.json`, kept beside it. It is the manual
    /// rollback for a downgrade or a migration bug, because the migrating save is the
    /// moment the legacy Writing Styles keys leave disk (KTD13).
    static let legacyBackupFileName = "config.pre-modes.json"

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
        guard decoded.retiredASRBackendMigrationApplied || decoded.dictationModesMigrationApplied else {
            return decoded
        }
        // R9: the backup goes down before the only save that removes the legacy keys.
        // A backup that cannot be written aborts the save, so the migration re-runs next
        // launch against a file that still has everything it needs. Derived ids make the
        // second run produce the same modes (KTD13).
        if decoded.dictationModesMigrationApplied, !backUpLegacyConfig(data) {
            return decoded
        }
        if !write(decoded) {
            fputs(
                "[config-store] the dictation modes migration could not be persisted; it will run again on the next launch\n",
                stderr
            )
        }
        return decoded
    }

    func save(_ config: AppConfig) {
        _ = write(config)
    }

    /// Copies the pre-migration bytes aside once. An existing backup is left exactly as
    /// it is: it is the older, more original state, and overwriting it would replace the
    /// only rollback with a file the migration has already rewritten.
    private func backUpLegacyConfig(_ data: Data) -> Bool {
        let backupURL = legacyBackupURL()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: backupURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { return true }
            // Something that is not the backup occupies the path, so no rollback exists
            // and none can be written here.
            fputs(
                "[config-store] cannot back up config.json before the dictation modes migration: \(backupURL.lastPathComponent) is a directory; leaving the existing config untouched\n",
                stderr
            )
            return false
        }
        do {
            try data.write(to: backupURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: backupURL.path
            )
            return true
        } catch {
            fputs(
                "[config-store] failed to back up config.json before the dictation modes migration: \(error); leaving the existing config untouched\n",
                stderr
            )
            return false
        }
    }

    func legacyBackupURL() -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent(Self.legacyBackupFileName)
    }

    private func write(_ config: AppConfig) -> Bool {
        ensureDirectory()
        // Normalization is total: nothing about mode content can refuse a save, so an
        // unrelated setting is never held hostage by a bad mode array (R4).
        guard let data = try? encoder.encode(DictationModes.sanitized(config)) else {
            fputs("[config-store] failed to encode config\n", stderr)
            return false
        }
        do {
            try data.write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configURL.path
            )
            return true
        } catch {
            fputs("[config-store] failed to save config: \(error)\n", stderr)
            return false
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
