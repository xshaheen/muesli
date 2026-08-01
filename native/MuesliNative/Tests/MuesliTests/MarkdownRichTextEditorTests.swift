import AppKit
import SwiftUI
import Testing
@testable import MuesliNativeApp

@Suite("MarkdownRichTextEditor")
@MainActor
struct MarkdownRichTextEditorTests {

    /// Renders `markdown` into a text view and serializes it back, the same path
    /// the editor takes when it publishes notes after a formatting command.
    private func roundTrip(_ markdown: String) -> String {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)

        let coordinator = MarkdownRichTextEditor.Coordinator(
            text: .constant(""),
            command: .constant(nil),
            onTextChange: nil
        )
        coordinator.apply(markdown: markdown, to: textView)
        return coordinator.serializedMarkdown(from: textView)
    }

    @Test("round-trips lines whose UTF-16 length exceeds their character count")
    func preservesEmojiLines() {
        // Emoji outside the BMP take two UTF-16 units, so serializing against
        // character counts used to drop trailing text from these lines.
        let markdown = "- [ ] Ship the 🚀 release\nCelebrate 🎉 after"
        #expect(roundTrip(markdown) == markdown)
    }

    @Test("round-trips plain ASCII lists unchanged")
    func preservesAsciiLines() {
        let markdown = "- [ ] Ship the release\n- Follow up\nPlain line"
        #expect(roundTrip(markdown) == markdown)
    }
}
