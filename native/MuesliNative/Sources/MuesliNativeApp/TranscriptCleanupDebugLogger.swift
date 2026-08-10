import Foundation

enum TranscriptCleanupDebugLogger {
    private static let logEnv = "MUESLI_LOG_TRANSCRIPT_CLEANUP_DEBUG"
    static let maxLoggedTextCharacters = 4_000
    static let maxLogFileBytes: UInt64 = 5 * 1024 * 1024
    private static let writeQueue = DispatchQueue(label: "MuesliNative.TranscriptCleanupDebugLogger")

    struct Entry: Codable {
        let ts: String
        let status: String
        let cleanupOutcome: String
        let cleanupBackend: String
        let cleanupModel: String
        let asrBackend: String
        let selectedStyleID: String?
        let styleSelectionSource: String?
        let styleCategoryID: String?
        let styleGroupID: String?
        let appContextText: String?
        let rawASRText: String
        let rawCleanupOutputText: String?
        let cleanupOutputText: String?
        let errorDescription: String?
        let elapsedMs: Double?
    }

    static func append(
        status: String,
        cleanupBackend: TranscriptCleanupBackendOption,
        cleanupModel: String,
        asrBackend: String,
        cleanupOutcome: DictationCleanupOutcome,
        styleProvenance: DictationCleanupStyleProvenance? = nil,
        appContextText: String? = nil,
        rawASRText: String,
        rawCleanupOutputText: String? = nil,
        cleanupOutputText: String? = nil,
        errorDescription: String? = nil,
        elapsedMs: Double? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logURL: URL = AppIdentity.supportDirectoryURL.appendingPathComponent("transcript-cleanup-debug.jsonl")
    ) {
        guard isEnabled(environment: environment) else { return }
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entry = Entry(
            ts: iso8601.string(from: Date()),
            status: status,
            cleanupOutcome: cleanupOutcome.rawValue,
            cleanupBackend: cleanupBackend.backend,
            cleanupModel: cleanupModel,
            asrBackend: asrBackend,
            selectedStyleID: styleProvenance?.styleID,
            styleSelectionSource: styleProvenance?.source.rawValue,
            styleCategoryID: styleProvenance?.categoryID,
            styleGroupID: styleProvenance?.groupID,
            appContextText: appContextText.map(bounded),
            rawASRText: bounded(rawASRText),
            rawCleanupOutputText: rawCleanupOutputText.map(bounded),
            cleanupOutputText: cleanupOutputText.map(bounded),
            errorDescription: errorDescription,
            elapsedMs: elapsedMs
        )
        append(entry, to: logURL)
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        isTruthy(environment[logEnv])
            || (isTruthy(environment["MUESLI_DEBUG_POSTPROC_LOGS"])
                && isTruthy(environment["MUESLI_LOG_POSTPROC_PAIRS"]))
    }

    private static func isTruthy(_ value: String?) -> Bool {
        let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    private static func append(_ entry: Entry, to logURL: URL) {
        writeQueue.sync {
            guard var data = try? JSONEncoder().encode(entry) else { return }
            data.append(0x0A)
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            rotateIfNeeded(logURL)
            if FileManager.default.fileExists(atPath: logURL.path),
               let fh = try? FileHandle(forWritingTo: logURL) {
                defer { try? fh.close() }
                fh.seekToEndOfFile()
                fh.write(data)
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    static func bounded(_ text: String) -> String {
        guard text.count > maxLoggedTextCharacters else { return text }
        return "\(text.prefix(maxLoggedTextCharacters))...[truncated]"
    }

    private static func rotateIfNeeded(_ logURL: URL) {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
            let size = attributes[.size] as? UInt64,
            shouldRotate(fileSize: size)
        else { return }
        try? FileManager.default.removeItem(at: logURL)
    }

    static func shouldRotate(fileSize: UInt64) -> Bool {
        fileSize > maxLogFileBytes
    }
}
