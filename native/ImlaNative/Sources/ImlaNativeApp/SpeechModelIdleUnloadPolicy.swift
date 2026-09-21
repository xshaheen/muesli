import Foundation

/// Decides when the ASR models behind the designated slots may be released.
///
/// Designation (`TranscriptionBackendResidencyPolicy`) only frees backends the user
/// has moved on from; the selected dictation model stays resident for the life of
/// the process even when nobody has dictated for hours. That model is the bulk of
/// the app's footprint: the Cohere Arabic GGUF alone is copied into 2.2 GB of Metal
/// buffers, and a Mac that dictates twice a day carries it all day. Every wrapper
/// reloads lazily, and a warm reload takes about two seconds that the controller
/// hides behind the user's own speaking time by kicking it off on hotkey press, so
/// an idle window trades a rare, mostly invisible reload for that memory.
enum SpeechModelIdleUnloadPolicy {
    /// Minutes without dictation, meeting, or import activity before the loaded
    /// ASR models are released. Matches the cleanup model's window so a quiet
    /// machine returns to its baseline in one step rather than two.
    static let defaultIdleMinutes = 15

    /// Clamps a configured value. A negative delay would otherwise unload
    /// immediately, so anything below zero is treated as "never unload".
    static func resolvedIdleMinutes(_ raw: Int) -> Int {
        max(0, raw)
    }

    /// Seconds to wait before unloading, or nil while the models must stay resident.
    ///
    /// A dictation session is pinned from hotkey press to paste: streaming backends
    /// hand their model to the controller for the whole hold, outside the
    /// coordinator's in-flight accounting, so the countdown must not even be armed
    /// while one is live. A meeting pins for the same reason as the cleanup model,
    /// plus live captions stream against a coordinator-held model.
    static func unloadDelaySeconds(
        idleMinutes: Int,
        isDictationActive: Bool,
        isMeetingActive: Bool
    ) -> Double? {
        guard idleMinutes > 0, !isDictationActive, !isMeetingActive else { return nil }
        return Double(idleMinutes) * 60
    }

    /// Whether an idle countdown that has elapsed may still act.
    ///
    /// Re-evaluated when the timer fires, because the coordinator is an actor and
    /// a dictation can begin between the timer waking and its body running.
    static func mayUnload(
        isDictationActive: Bool,
        isMeetingActive: Bool
    ) -> Bool {
        !isDictationActive && !isMeetingActive
    }

    /// Loaded backends that can be released now: everything not mid-load or
    /// mid-inference. Designation is deliberately ignored — the point of this
    /// policy is to release the designated model while it is idle.
    static func backendsToUnload(
        loaded: Set<String>,
        inFlight: Set<String>
    ) -> [String] {
        loaded.subtracting(inFlight).sorted()
    }
}
