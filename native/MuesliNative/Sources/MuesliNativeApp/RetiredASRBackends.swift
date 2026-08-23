import Foundation

/// An ASR backend that used to be selectable and no longer is.
///
/// Qwen3 ASR was measured against every shipped backend on 21-08-2026
/// (`docs/transcription-quality-findings-2026-08.md`) and came last or near-last on
/// every cohort, including the Arabic ones it had been retained for. Deleting the
/// catalogue entry is not enough on its own: a config that still names it would fall
/// through to whatever the resolver happened to pick, which is exactly the silent
/// model swap the removal plan forbids.
enum RetiredASRBackend: String, CaseIterable, Sendable {
    /// The `BackendOption.backend` identifier the removed model shipped under.
    case qwen3ASR = "qwen"

    var label: String {
        switch self {
        case .qwen3ASR: "Qwen3 ASR"
        }
    }

    /// Why it went, in the words the user sees. Kept short enough to sit in a card.
    var removalReason: String {
        switch self {
        case .qwen3ASR:
            "It was measured against every other model and came last or near-last on every language, including Arabic."
        }
    }

    /// Cache directories the removed backend may still occupy under the shared
    /// FluidAudio models root. Qwen kept two: FluidAudio's `Repo.folderName` strips the
    /// `-coreml` suffix (issue #380), so a manual or pre-fix install can sit under the
    /// longer name while the managed download sits under the shorter one.
    var cacheDirectoryNames: [String] {
        switch self {
        case .qwen3ASR: ["qwen3-asr-0.6b", "qwen3-asr-0.6b-coreml"]
        }
    }

    /// Approximate size of a complete install, shown before anything is deleted.
    var approximateSizeLabel: String {
        switch self {
        case .qwen3ASR: "~1.3 GB"
        }
    }

    static func resolve(backend: String?) -> Self? {
        guard let backend else { return nil }
        return Self(rawValue: backend)
    }
}

/// A removed backend's files still sitting on disk, and how much space they hold.
///
/// AE7: model management offers these for deletion with their size, rather than
/// leaving over a gigabyte behind with no surface left that can reach it.
struct RetiredASRBackendCache: Equatable, Sendable {
    let backend: RetiredASRBackend
    let directories: [URL]
    let byteCount: Int64

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    /// The shared FluidAudio models root every managed ASR download lands under.
    static func modelsRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    }

    static func detectAll(
        in modelsRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> [RetiredASRBackendCache] {
        let root = modelsRoot ?? Self.modelsRoot(fileManager: fileManager)
        return RetiredASRBackend.allCases.compactMap {
            detect($0, in: root, fileManager: fileManager)
        }
    }

    static func detect(
        _ backend: RetiredASRBackend,
        in modelsRoot: URL,
        fileManager: FileManager = .default
    ) -> RetiredASRBackendCache? {
        let directories = backend.cacheDirectoryNames
            .map { modelsRoot.appendingPathComponent($0, isDirectory: true) }
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard !directories.isEmpty else { return nil }
        return RetiredASRBackendCache(
            backend: backend,
            directories: directories,
            byteCount: directories.reduce(0) { $0 + byteCount(of: $1, fileManager: fileManager) }
        )
    }

    /// Sums allocated size so the figure matches what the user reclaims, and skips
    /// unreadable entries rather than aborting: a partially readable cache is still
    /// worth offering to delete.
    private static func byteCount(of directory: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            )
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}

/// What the app tells the user after moving them off a removed backend.
///
/// Persisted rather than raised in the moment: the migration happens while the config
/// is being decoded at launch, long before there is a window to show it in, and the
/// user must still see it if they were not looking at the app when it happened. It is
/// cleared once they acknowledge it, and the migration cannot re-arm it because the
/// selection it keys on is gone by then.
struct RetiredASRBackendNotice: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable {
        /// The surface as the settings UI names it, e.g. "Dictation".
        let surface: String
        let replacementLabel: String

        enum CodingKeys: String, CodingKey {
            case surface
            case replacementLabel = "replacement_label"
        }
    }

    let retiredLabel: String
    let reason: String
    let changes: [Change]

    enum CodingKeys: String, CodingKey {
        case retiredLabel = "retired_label"
        case reason
        case changes
    }

    var message: String {
        let moves = changes
            .map { "\($0.surface) now uses \($0.replacementLabel)." }
            .joined(separator: " ")
        return "\(retiredLabel) was removed. \(moves) \(reason)"
    }
}

/// Resolves what a persisted selection of a removed backend becomes.
enum RetiredASRBackendMigration {
    /// KTD2: the replacement is read off the language profile rather than fixed.
    ///
    /// Parakeet v3 won English outright (0.063 WER) and scored 0.005 faithfulness on
    /// Arabic — it essentially never emits Arabic script — so it is only safe when the
    /// profile indicates nothing but English. Any non-English language anywhere in the
    /// profile, dominant or merely selected, sends the user to Whisper Large Turbo,
    /// which led both Arabic cohorts. An unset profile indicates nothing, so it takes
    /// the English winner.
    static func replacement(for profile: LanguageProfile) -> BackendOption {
        indicatesNonEnglish(profile) ? .whisperLargeTurbo : .parakeetMultilingual
    }

    static func indicatesNonEnglish(_ profile: LanguageProfile) -> Bool {
        ([profile.dominantLanguage] + profile.selectedLanguages.map(Optional.some))
            .compactMap { $0 }
            .contains { $0 != .english }
    }
}
