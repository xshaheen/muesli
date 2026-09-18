import Foundation

/// Decides when an idle on-device dictation cleanup model may be released.
///
/// The Gemma 4 E2B engine holds roughly 1.4 GB resident for as long as the process
/// lives, which is a large permanent cost for a feature most people use in short
/// bursts. Hosted cleanup backends keep nothing on this machine, so an idle unload
/// has nothing to reclaim for them.
enum PostProcessorIdleUnloadPolicy {
    /// Minutes without a dictation cleanup before the model is released.
    static let defaultIdleMinutes = 15

    /// Clamps a configured value. A negative delay would otherwise unload
    /// immediately, so anything below zero is treated as "never unload".
    static func resolvedIdleMinutes(_ raw: Int) -> Int {
        max(0, raw)
    }

    /// Seconds to wait before unloading, or nil when the model should stay resident.
    ///
    /// A meeting keeps the model loaded for its whole duration: the user may dictate
    /// into another app while it records, and paying a multi-second reload then is
    /// worse than holding the memory until the meeting finishes.
    static func unloadDelaySeconds(idleMinutes: Int, isMeetingActive: Bool) -> Double? {
        guard idleMinutes > 0, !isMeetingActive else { return nil }
        return Double(idleMinutes) * 60
    }

    /// Whether the Gemma engine may be released.
    ///
    /// One engine serves both transcription and cleanup, so releasing it on a
    /// cleanup idle timer would unload the dictation backend out from under the
    /// next hotkey press.
    static func canUnloadGemma4Engine(activeTranscriptionBackend: String?) -> Bool {
        activeTranscriptionBackend != BackendOption.gemma4E2BLiteRT.backend
    }
}
