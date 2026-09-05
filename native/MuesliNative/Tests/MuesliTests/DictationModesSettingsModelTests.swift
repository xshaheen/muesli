import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("Dictation modes settings model")
@MainActor
struct DictationModesSettingsModelTests {

    private func mode(
        _ id: String,
        name: String? = nil,
        apps: [String] = [],
        websites: [String] = [],
        instructions: String = "text",
        override: Bool = false,
        enabled: Bool = true
    ) -> DictationMode {
        DictationMode(
            id: id,
            name: name ?? id.capitalized,
            isEnabled: enabled,
            instructions: instructions,
            overrideDefaultInstructions: override,
            appBundleIDs: apps,
            websiteHostnames: websites
        )
    }

    /// Persists into an array the test can inspect, so a save is observable
    /// without a controller.
    private func recordingClient(_ store: Store) -> DictationModesClient {
        DictationModesClient(
            load: { store.modes },
            save: { modes in
                store.modes = DictationModes.sanitized(modes: modes)
                return store.modes
            }
        )
    }

    private final class Store {
        var modes: [DictationMode]
        init(_ modes: [DictationMode]) { self.modes = modes }
    }

    private struct SaveFailed: Error, LocalizedError {
        var errorDescription: String? { "Disk is full." }
    }

    // MARK: - Validation

    @Test("an empty name blocks the save")
    func emptyNameBlocked() {
        let model = DictationModesSettingsModel(modes: [mode("email")])
        #expect(model.validationMessage(for: mode("email", name: "   ")) != nil)
    }

    @Test("a duplicate name blocks the save but a mode may keep its own")
    func duplicateNameBlocked() {
        let model = DictationModesSettingsModel(modes: [
            mode("email", name: "Email"),
            mode("chat", name: "Chat"),
        ])

        #expect(model.validationMessage(for: mode("chat", name: "EMAIL")) != nil)
        #expect(model.validationMessage(for: mode("chat", name: "Chat")) == nil)
    }

    @Test("override with no instructions blocks the save")
    func overrideNeedsInstructions() {
        let model = DictationModesSettingsModel(modes: [])
        #expect(model.validationMessage(
            for: mode("x", instructions: "   ", override: true)
        ) != nil)
        #expect(model.validationMessage(
            for: mode("x", instructions: "Do this", override: true)
        ) == nil)
    }

    // MARK: - Target moves

    /// Covers AE11. A target belongs to one mode, and the editor has to be able to
    /// say which mode it is taking it from.
    @Test("saving a mode that claims a target takes it from the mode that held it")
    func savingMovesTarget() {
        let store = Store([
            mode("coding", apps: ["com.microsoft.vscode"]),
            mode("notes", apps: []),
        ])
        let model = DictationModesSettingsModel(modes: store.modes)

        let owner = model.modeOwning(bundleID: "com.microsoft.vscode", excluding: "notes")
        #expect(owner?.id == "coding")

        model.save(mode("notes", apps: ["com.microsoft.vscode"]), using: recordingClient(store))

        #expect(model.modes.first { $0.id == "notes" }?.appBundleIDs == ["com.microsoft.vscode"])
        #expect(model.modes.first { $0.id == "coding" }?.appBundleIDs.isEmpty == true)
        #expect(model.errorMessage == nil)
    }

    @Test("a website target moves the same way and reports its previous owner")
    func websiteTargetMoves() {
        let store = Store([
            mode("docs", websites: ["docs.google.com"]),
            mode("writing", websites: []),
        ])
        let model = DictationModesSettingsModel(modes: store.modes)

        #expect(model.modeOwning(hostname: "docs.google.com", excluding: "writing")?.id == "docs")

        model.save(mode("writing", websites: ["docs.google.com"]), using: recordingClient(store))
        #expect(model.modes.first { $0.id == "docs" }?.websiteHostnames.isEmpty == true)
    }

    @Test("a failed save leaves the draft and the published modes untouched")
    func failedSaveRetainsDraft() {
        let original = [mode("email", apps: ["com.apple.mail"])]
        let model = DictationModesSettingsModel(modes: original)
        let failing = DictationModesClient(load: { original }, save: { _ in throw SaveFailed() })

        model.save(mode("email", name: "Renamed"), using: failing)

        #expect(model.modes == original)
        #expect(model.errorMessage == "Disk is full.")
    }

    @Test("a blocked save reports the reason and writes nothing")
    func blockedSaveWritesNothing() {
        let store = Store([mode("email", name: "Email"), mode("chat", name: "Chat")])
        let model = DictationModesSettingsModel(modes: store.modes)

        model.save(mode("chat", name: "Email"), using: recordingClient(store))

        #expect(model.errorMessage != nil)
        #expect(store.modes.first { $0.id == "chat" }?.name == "Chat")
    }

    // MARK: - Toggles and delete

    @Test("toggling a card persists only the enabled flag")
    func setEnabledPersistsOneField() {
        let store = Store([mode("email", enabled: true)])
        let model = DictationModesSettingsModel(modes: store.modes)

        model.setEnabled(false, id: "email", using: recordingClient(store))

        #expect(model.modes.first?.isEnabled == false)
        #expect(model.modes.first?.name == "Email")
    }

    @Test("deleting removes the mode")
    func deleteRemovesMode() {
        let store = Store([mode("email"), mode("chat")])
        let model = DictationModesSettingsModel(modes: store.modes)

        model.delete(id: "email", using: recordingClient(store))
        #expect(model.modes.map(\.id) == ["chat"])
    }

    // MARK: - Reset

    /// Covers AE10.
    @Test("reset restores a renamed built-in in place and re-adds a deleted one")
    func resetRestoresBuiltIns() {
        let builtIns = DictationModes.builtInModes(isEnabled: true)
        let email = builtIns.first { $0.id == DictationModes.BuiltIn.email.id }!
        let coding = builtIns.first { $0.id == DictationModes.BuiltIn.coding.id }!

        var renamed = email
        renamed.name = "My Email"
        renamed.instructions = "changed"
        let store = Store([renamed, mode("standup", name: "Standup")])
        let model = DictationModesSettingsModel(modes: store.modes)

        model.resetToBuiltIns(using: recordingClient(store))

        let restored = model.modes.first { $0.id == email.id }
        #expect(restored?.name == email.name)
        #expect(restored?.instructions == email.instructions)
        #expect(model.modes.first?.id == email.id, "a present built-in keeps its position")
        #expect(model.modes.contains { $0.id == coding.id }, "a deleted built-in comes back")
        #expect(model.modes.contains { $0.id == "standup" }, "custom modes survive")
    }

    @Test("reset reclaims a shipped target from a custom mode")
    func resetReclaimsShippedTargets() {
        let email = DictationModes.builtInModes(isEnabled: true)
            .first { $0.id == DictationModes.BuiltIn.email.id }!
        let stolen = email.appBundleIDs.first!
        let store = Store([mode("standup", name: "Standup", apps: [stolen])])
        let model = DictationModesSettingsModel(modes: store.modes)

        model.resetToBuiltIns(using: recordingClient(store))

        #expect(model.modes.first { $0.id == "standup" }?.appBundleIDs.contains(stolen) == false)
        #expect(model.modes.first { $0.id == email.id }?.appBundleIDs.contains(stolen) == true)
    }

    /// Two modes with the same name would both be unsaveable, so the restored
    /// built-in takes the suffix rather than leaving the user stuck.
    @Test("reset suffixes a built-in name a custom mode already uses")
    func resetSuffixesClashingName() {
        let email = DictationModes.builtInModes(isEnabled: true)
            .first { $0.id == DictationModes.BuiltIn.email.id }!
        let store = Store([mode("mine", name: email.name)])
        let model = DictationModesSettingsModel(modes: store.modes)

        model.resetToBuiltIns(using: recordingClient(store))

        let restored = model.modes.first { $0.id == email.id }
        #expect(restored?.name != email.name)
        #expect(restored?.name.hasPrefix(email.name) == true)
        #expect(model.modes.first { $0.id == "mine" }?.name == email.name)
    }
}
