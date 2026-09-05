import Foundation

/// The persistence seam for the Modes screen.
///
/// Injected rather than reached through the controller so the editor's failure
/// behavior is testable without an app: a throwing `save` is the only way to prove
/// a failed write leaves the user's draft intact.
struct DictationModesClient {
    var load: () -> [DictationMode]
    var save: ([DictationMode]) throws -> [DictationMode]

    enum Error: Swift.Error, LocalizedError {
        case controllerUnavailable

        var errorDescription: String? {
            switch self {
            case .controllerUnavailable: "Muesli is shutting down; the change was not saved."
            }
        }
    }
}

/// Draft state for the Modes screen: validation, target moves, reset, and one
/// commit path shared by the cards and the editor.
@MainActor
@Observable
final class DictationModesSettingsModel {
    private(set) var modes: [DictationMode]
    private(set) var errorMessage: String?

    init(modes: [DictationMode]) {
        self.modes = modes
    }

    convenience init(client: DictationModesClient) {
        self.init(modes: client.load())
    }

    // MARK: - Validation

    /// A name is required and must be unique among the *other* modes, so editing a
    /// mode without renaming it is never blocked by its own name.
    func validationMessage(for candidate: DictationMode) -> String? {
        let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return "Give this mode a name."
        }
        let clashes = modes.contains {
            $0.id != candidate.id && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
        if clashes {
            return "Another mode is already called \"\(name)\"."
        }
        if candidate.overrideDefaultInstructions,
           CustomInstructions.normalized(candidate.instructions).isEmpty {
            return "Add instructions, or turn off Override default."
        }
        return nil
    }

    /// Which mode currently owns a target, so the editor can say where it moved from.
    func modeOwning(bundleID: String, excluding modeID: String) -> DictationMode? {
        guard let normalized = DictationModes.normalizedBundleID(bundleID) else { return nil }
        return modes.first { $0.id != modeID && $0.appBundleIDs.contains(normalized) }
    }

    func modeOwning(hostname: String, excluding modeID: String) -> DictationMode? {
        guard let normalized = DictationModes.normalizedHostname(hostname) else { return nil }
        return modes.first { $0.id != modeID && $0.websiteHostnames.contains(normalized) }
    }

    // MARK: - Commits

    func save(_ candidate: DictationMode, using client: DictationModesClient) {
        if let message = validationMessage(for: candidate) {
            errorMessage = message
            return
        }
        var next = modes
        // A target belongs to one mode, so saving one that claims a target takes it
        // from whoever held it. The editor already told the user this would happen.
        for index in next.indices where next[index].id != candidate.id {
            next[index].appBundleIDs.removeAll { candidate.appBundleIDs.contains($0) }
            next[index].websiteHostnames.removeAll { candidate.websiteHostnames.contains($0) }
        }
        if let index = next.firstIndex(where: { $0.id == candidate.id }) {
            next[index] = candidate
        } else {
            next.append(candidate)
        }
        commit(next, using: client)
    }

    func setEnabled(_ isEnabled: Bool, id: String, using client: DictationModesClient) {
        guard let index = modes.firstIndex(where: { $0.id == id }) else { return }
        var next = modes
        next[index].isEnabled = isEnabled
        commit(next, using: client)
    }

    func delete(id: String, using client: DictationModesClient) {
        commit(modes.filter { $0.id != id }, using: client)
    }

    /// Restores the built-ins in place, appends the ones that were deleted, and
    /// leaves custom modes alone. A built-in reclaims its shipped targets, and takes
    /// a suffix when a custom mode already answers to its name, so Reset can never
    /// leave two modes the editor refuses to save.
    func resetToBuiltIns(using client: DictationModesClient) {
        let builtIns = DictationModes.builtInModes(isEnabled: true)
        let builtInIDs = Set(builtIns.map(\.id))
        var next = modes

        for var builtIn in builtIns {
            let shippedTargets = Set(builtIn.appBundleIDs)
            let shippedHosts = Set(builtIn.websiteHostnames)
            for index in next.indices where !builtInIDs.contains(next[index].id) {
                next[index].appBundleIDs.removeAll { shippedTargets.contains($0) }
                next[index].websiteHostnames.removeAll { shippedHosts.contains($0) }
            }
            let clash = next.contains {
                !builtInIDs.contains($0.id)
                    && $0.name.compare(builtIn.name, options: .caseInsensitive) == .orderedSame
            }
            if clash {
                builtIn.name += " (default)"
            }
            if let index = next.firstIndex(where: { $0.id == builtIn.id }) {
                next[index] = builtIn
            } else {
                next.append(builtIn)
            }
        }
        commit(next, using: client)
    }

    private func commit(_ candidate: [DictationMode], using client: DictationModesClient) {
        do {
            modes = try client.save(candidate)
            errorMessage = nil
        } catch {
            // The draft stays exactly as the user left it: a failed write must not
            // also cost them the edit that failed to save.
            errorMessage = error.localizedDescription
        }
    }
}
