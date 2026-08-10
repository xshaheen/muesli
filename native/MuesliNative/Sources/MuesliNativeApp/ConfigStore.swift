import Foundation
import MuesliCore

final class ConfigStore {
    enum DictationStyleLoadResult {
        case loaded(AppConfig)
        case quarantined(AppConfig, String)
    }

    enum DictationStylePersistenceError: Error, LocalizedError {
        case quarantined(String)

        var errorDescription: String? {
            switch self { case .quarantined(let reason): "Writing styles are quarantined: \(reason)" }
        }
    }

    private let configURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var dictationStyleQuarantineReason: String?

    init(supportDirectory: URL = AppIdentity.supportDirectoryURL) {
        self.configURL = supportDirectory.appendingPathComponent("config.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> AppConfig {
        switch loadResult() {
        case .loaded(let config), .quarantined(let config, _): return config
        }
    }

    func loadResult() -> DictationStyleLoadResult {
        ensureDirectory()
        guard let data = try? Data(contentsOf: configURL) else {
            return .loaded(AppConfig())
        }
        guard let decoded = try? decoder.decode(AppConfig.self, from: data) else {
            return .loaded(AppConfig())
        }
        do {
            _ = try DictationStyleResolver.prepareCanonicalConfiguration(decoded)
            return .loaded(decoded)
        } catch {
            let reason = error.localizedDescription
            dictationStyleQuarantineReason = reason
            var fallback = decoded
            fallback.adaptiveDictationStylesEnabled = false
            fallback.dictationStyleRulesetQuarantineReason = reason
            return .quarantined(fallback, reason)
        }
    }

    func save(_ config: AppConfig) {
        guard dictationStyleQuarantineReason == nil else {
            fputs("[config-store] refusing to overwrite quarantined dictation styles\n", stderr)
            return
        }
        ensureDirectory()
        guard let candidate = try? DictationStyleResolver.prepareCanonicalConfiguration(config),
              let data = try? encoder.encode(candidate)
        else {
            fputs("[config-store] refusing to persist invalid dictation styles\n", stderr)
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
        if let reason = dictationStyleQuarantineReason {
            throw DictationStylePersistenceError.quarantined(reason)
        }
        let candidate = try DictationStyleResolver.prepareCanonicalConfiguration(config)
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
