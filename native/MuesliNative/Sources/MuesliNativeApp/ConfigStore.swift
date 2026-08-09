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

    func load() -> AppConfig {
        ensureDirectory()
        guard let data = try? Data(contentsOf: configURL) else {
            return AppConfig()
        }
        return (try? decoder.decode(AppConfig.self, from: data)) ?? AppConfig()
    }

    func save(_ config: AppConfig) {
        ensureDirectory()
        guard let data = try? encoder.encode(config) else { return }
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
        let candidate = DictationStyleResolver.sanitizeConfiguration(config)
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
