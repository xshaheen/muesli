import Foundation
import MuesliCore

/// Decides whether to turn dictation cleanup on for a newly bilingual user.
///
/// Pure so the rule is testable without a controller, and so the one-shot
/// behaviour (KTD6) lives in one place rather than being re-derived at each call
/// site. Repair only reaches a dictation when the post-processor runs, so a
/// bilingual user whose cleanup is off would otherwise see nothing change.
enum BilingualRepairAutoEnable {

    struct Decision: Equatable {
        /// Record the attempt, so it never runs a second time.
        let recordsAttempt: Bool
        /// Ask the controller to turn cleanup on. The controller's own readiness
        /// guards still apply and may refuse.
        let enablesPostProcessor: Bool

        static let none = Decision(recordsAttempt: false, enablesPostProcessor: false)
    }

    static func decide(config: AppConfig) -> Decision {
        // Already ran. Whatever the user did afterwards is theirs to keep.
        guard !config.bilingualRepairAutoEnableApplied else { return .none }
        guard config.dictationLanguageProfile.isBilingual else { return .none }
        return Decision(
            recordsAttempt: true,
            enablesPostProcessor: !config.enablePostProcessor
        )
    }
}
