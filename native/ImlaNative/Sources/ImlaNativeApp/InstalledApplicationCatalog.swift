import AppKit
import Foundation

/// One app a mode can be attached to.
struct InstalledApplication: Identifiable, Equatable, Sendable {
    /// Normalized, so it compares equal to what a mode persists.
    let bundleID: String
    let displayName: String
    let applicationURL: URL?

    var id: String { bundleID }
}

/// The installed applications a user can attach a mode to.
///
/// The scan is the one `ComputerUseExecutor` already ran to find an app by name;
/// it lives here now so both callers share it and the picker can show progress.
@MainActor
@Observable
final class InstalledApplicationCatalog {
    private(set) var applications: [InstalledApplication] = []
    private(set) var isScanning = false

    private var hasLoaded = false

    static let searchDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Applications",
            isDirectory: true
        ),
    ]

    func loadIfNeeded() {
        guard !hasLoaded, !isScanning else { return }
        isScanning = true
        Task.detached(priority: .utility) {
            let scanned = Self.scanInstalledApplications()
            await MainActor.run {
                self.applications = Self.merged(scanned: scanned, running: Self.runningApplications())
                self.isScanning = false
                self.hasLoaded = true
            }
        }
    }

    /// A running app the scan missed still belongs in the list: it is on screen, so
    /// it is exactly the app a user is most likely to be attaching a mode to.
    nonisolated static func merged(
        scanned: [InstalledApplication],
        running: [InstalledApplication]
    ) -> [InstalledApplication] {
        var seen = Set<String>()
        var result: [InstalledApplication] = []
        for candidate in scanned + running where !seen.contains(candidate.bundleID) {
            seen.insert(candidate.bundleID)
            result.append(candidate)
        }
        return result.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    nonisolated static func filter(_ applications: [InstalledApplication], query: String) -> [InstalledApplication] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return applications }
        return applications.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Builds a candidate from an app bundle the user picked in a file panel.
    nonisolated static func application(at url: URL) throws -> InstalledApplication {
        guard url.pathExtension == "app", let bundle = Bundle(url: url) else {
            throw CatalogError.notAnApplication
        }
        guard let bundleID = DictationModes.normalizedBundleID(bundle.bundleIdentifier) else {
            throw CatalogError.missingBundleIdentifier
        }
        return InstalledApplication(
            bundleID: bundleID,
            displayName: displayName(for: bundle, url: url),
            applicationURL: url
        )
    }

    enum CatalogError: Error, LocalizedError {
        case notAnApplication
        case missingBundleIdentifier

        var errorDescription: String? {
            switch self {
            case .notAnApplication: "That file is not an application."
            case .missingBundleIdentifier: "That application has no bundle identifier."
            }
        }
    }

    // MARK: - Scanning

    nonisolated static func scanInstalledApplications() -> [InstalledApplication] {
        var found: [InstalledApplication] = []
        for directory in searchDirectories {
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            var checked = 0
            for case let url as URL in enumerator {
                checked += 1
                if checked % 25 == 0, Task.isCancelled { return found }
                guard url.pathExtension == "app" else { continue }
                guard let bundle = Bundle(url: url),
                      let bundleID = DictationModes.normalizedBundleID(bundle.bundleIdentifier)
                else {
                    continue
                }
                found.append(
                    InstalledApplication(
                        bundleID: bundleID,
                        displayName: displayName(for: bundle, url: url),
                        applicationURL: url
                    )
                )
            }
        }
        return found
    }

    nonisolated static func displayName(for bundle: Bundle, url: URL) -> String {
        let candidates = [
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
        ]
        for candidate in candidates {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Regular apps only: background agents have bundle ids but no window a user
    /// would ever dictate into.
    nonisolated static func runningApplications() -> [InstalledApplication] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  let bundleID = DictationModes.normalizedBundleID(app.bundleIdentifier)
            else {
                return nil
            }
            return InstalledApplication(
                bundleID: bundleID,
                displayName: app.localizedName ?? bundleID,
                applicationURL: app.bundleURL
            )
        }
    }
}
