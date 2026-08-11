import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("MeetingChatRecipes")
struct MeetingChatRecipesTests {
    @Test("ships the named built-in recipes")
    func shipsNamedBuiltIns() {
        let names = MeetingChatRecipes.builtIns.map(\.name)

        #expect(names.contains("Suggest questions"))
        #expect(names.contains("What did I miss"))
        #expect(names.contains("Make me sound smart"))
    }

    @Test("every recipe has a unique id and a non-empty prompt")
    func recipesAreWellFormed() {
        let ids = MeetingChatRecipes.builtIns.map(\.id)

        #expect(Set(ids).count == ids.count)
        for recipe in MeetingChatRecipes.builtIns {
            #expect(!recipe.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("no recipe inlines the transcript")
    func recipesDoNotInlineTranscript() {
        // The transcript reaches the model as system context. A recipe that also asked for
        // it, or carried a placeholder for it, would send the meeting twice and burn the
        // context budget for no gain.
        let placeholders = ["{transcript}", "{{transcript}}", "%@", "<transcript>"]

        for recipe in MeetingChatRecipes.builtIns {
            for placeholder in placeholders {
                #expect(recipe.prompt.contains(placeholder) == false)
            }
        }
    }

    @Test("overflow splits at the visible limit without losing recipes")
    func overflowSplitsCleanly() {
        let visible = MeetingChatRecipes.visible()
        let overflow = MeetingChatRecipes.overflow()

        #expect(visible.count <= MeetingChatRecipes.visibleChipLimit)
        #expect(visible.count + overflow.count == MeetingChatRecipes.builtIns.count)

        // Visible must be a prefix, so chip order stays stable rather than reshuffling.
        #expect(visible.map(\.id) == MeetingChatRecipes.builtIns.prefix(visible.count).map(\.id))
        #expect(Set(visible.map(\.id)).isDisjoint(with: Set(overflow.map(\.id))))
    }

    @Test("running a recipe sends its prompt but displays its name")
    @MainActor
    func recipeSendsPromptDisplaysName() async {
        let conversation = MeetingChatConversation()
        let recipe = try! #require(MeetingChatRecipes.builtIns.first { $0.id == "what-did-i-miss" })

        await conversation.send(
            displayText: recipe.name,
            sentText: recipe.prompt,
            transcript: "[10:00:00] Speaker 1: we shipped",
            systemPrompt: MeetingChatPrompts.live,
            config: AppConfig(),
            send: { _, _ in "caught up" }
        )

        #expect(conversation.turns.first?.displayText == "What did I miss")

        let request = conversation.requestMessages(
            transcript: "[10:00:00] Speaker 1: we shipped",
            systemPrompt: MeetingChatPrompts.live
        )
        let userTurn = try! #require(request.first { $0.role == .user })
        #expect(userTurn.content == recipe.prompt)
        #expect(userTurn.content != recipe.name)
    }
}
