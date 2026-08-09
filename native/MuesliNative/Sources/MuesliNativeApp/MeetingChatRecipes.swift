import Foundation

/// A saved prompt the user can run with one tap.
///
/// `name` is what the conversation shows; `prompt` is what the model receives. Keeping them
/// separate is why a chip reads "What did I miss" in the message list instead of a paragraph
/// of instructions.
struct MeetingChatRecipe: Identifiable, Equatable {
    let id: String
    let name: String
    let prompt: String
}

enum MeetingChatRecipes {
    /// Prompts are instruction-only. The transcript reaches the model as system context, so
    /// a recipe that inlined it would send the meeting twice and eat the context budget.
    static let builtIns: [MeetingChatRecipe] = [
        MeetingChatRecipe(
            id: "suggest-questions",
            name: "Suggest questions",
            prompt: """
            Suggest three questions worth asking right now, based on what has been discussed. \
            Favour questions that surface unstated assumptions, unassigned work, or decisions \
            nobody has confirmed. Skip anything already answered in the transcript. One line each.
            """
        ),
        MeetingChatRecipe(
            id: "what-did-i-miss",
            name: "What did I miss",
            prompt: """
            Summarize the most recent part of the conversation in a few bullets, as if catching \
            someone up who looked away for a few minutes. Lead with anything decided or assigned.
            """
        ),
        MeetingChatRecipe(
            id: "make-me-sound-smart",
            name: "Make me sound smart",
            prompt: """
            Offer two things I could say next that would move this discussion forward -- a \
            substantive point or a sharp question, grounded in what has actually been said. \
            No flattery, no filler, and nothing the transcript does not support.
            """
        ),
        MeetingChatRecipe(
            id: "open-loops",
            name: "Open loops",
            prompt: """
            List anything raised but not resolved: unanswered questions, work agreed with no \
            owner, and decisions deferred without a date. If everything raised was resolved, \
            say so rather than inventing items.
            """
        ),
    ]

    /// How many chips fit before the rest collapse behind an overflow control.
    static let visibleChipLimit = 3

    static func visible(from recipes: [MeetingChatRecipe] = builtIns) -> [MeetingChatRecipe] {
        Array(recipes.prefix(visibleChipLimit))
    }

    static func overflow(from recipes: [MeetingChatRecipe] = builtIns) -> [MeetingChatRecipe] {
        Array(recipes.dropFirst(visibleChipLimit))
    }
}
