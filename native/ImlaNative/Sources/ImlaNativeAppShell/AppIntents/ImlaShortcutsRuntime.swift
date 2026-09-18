import Foundation
import ImlaNativeApp

@available(macOS 13.0, *)
enum ImlaShortcutsRuntime {
    /// Resolves the running controller. Shortcuts/Siri can cold-launch the
    /// app, and `ImlaController.current` is only set once
    /// `applicationDidFinishLaunching` runs, so wait briefly instead of
    /// failing with a spurious "not running" while the app is mid-launch.
    @MainActor
    static func waitForController(timeout: TimeInterval = 5) async throws -> ImlaController {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if let controller = ImlaController.current { return controller }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let controller = ImlaController.current else {
            throw ImlaShortcutsError.notRunning
        }
        return controller
    }
}
