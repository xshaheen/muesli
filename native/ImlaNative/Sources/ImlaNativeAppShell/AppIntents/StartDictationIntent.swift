import AppIntents
import ImlaNativeApp

@available(macOS 13.0, *)
struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Dictation"
    static var description = IntentDescription("Starts hands-free Imla dictation, same as double-tapping the dictation hotkey.")
    // Ask the system to launch Imla before performing so the in-process
    // controller exists; without this a closed app makes the wait time out.
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let controller = try await ImlaShortcutsRuntime.waitForController()
        return .result(value: controller.startDictationForShortcuts())
    }
}
