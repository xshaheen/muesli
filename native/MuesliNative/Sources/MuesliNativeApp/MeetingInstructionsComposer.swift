import Foundation

/// Derives the meeting-side custom-instructions inputs from the frozen config.
///
/// One pure owner, so meeting cleanup and meeting notes read the same text
/// through the same normalization instead of each consulting `AppConfig`.
enum MeetingInstructionsComposer {
    /// The normalized instructions, or an empty string when the user set none.
    static func customInstructions(for config: AppConfig) -> String {
        CustomInstructions.normalized(config.customInstructions)
    }

    /// The transcript-cleanup system prompt for this config.
    ///
    /// The worked Arabic examples apply only when the meeting authority actually
    /// selected Arabic and English; another pair gets the script-neutral text (R3).
    static func cleanupSystemPrompt(for config: AppConfig) -> String {
        MeetingTranscriptCleanupPrompt.systemPrompt(
            customInstructions: customInstructions(for: config),
            usesArabicExamples: MixedLanguageRepairPrompt.usesArabicExamples(config.meetingSpokenLanguage)
        )
    }
}
