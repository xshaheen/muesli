import AppIntents
import ImlaNativeApp

@available(macOS 13.0, *)
struct StopDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Dictation"
    static var description = IntentDescription("Stops an in-progress hands-free Imla dictation and pastes/inserts the transcript.")
    // Ask the system to launch Imla before performing so the in-process
    // controller exists; without this a closed app makes the wait time out.
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let controller = try await ImlaShortcutsRuntime.waitForController()
        return .result(value: controller.stopDictationForShortcuts())
    }
}
