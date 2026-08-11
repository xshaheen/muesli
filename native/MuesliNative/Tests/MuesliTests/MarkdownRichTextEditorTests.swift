import AppKit
import SwiftUI
import Testing
@testable import MuesliNativeApp

/// A text view that owns its undo manager. `NSResponder.undoManager` normally
/// resolves through the window, and these tests run without one.
private final class UndoRecordingTextView: NSTextView {
    let testUndoManager = UndoManager()

    override var undoManager: UndoManager? { testUndoManager }
}

@Suite("MarkdownRichTextEditor")
@MainActor
struct MarkdownRichTextEditorTests {

    private func makeTextView() -> UndoRecordingTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        return UndoRecordingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
    }

    private func makeCoordinator(onTextChange: ((String) -> Void)? = nil) -> MarkdownRichTextEditor.Coordinator {
        MarkdownRichTextEditor.Coordinator(
            text: .constant(""),
            command: .constant(nil),
            onTextChange: onTextChange
        )
    }

    /// Renders `markdown` into a text view and serializes it back, the same path
    /// the editor takes when it publishes notes after a formatting command.
    private func roundTrip(_ markdown: String) -> String {
        let textView = makeTextView()
        let coordinator = makeCoordinator()
        coordinator.apply(markdown: markdown, to: textView)
        return coordinator.serializedMarkdown(from: textView)
    }

    @Test("uses natural paragraph direction without rewriting mixed-language notes")
    func usesNaturalWritingDirection() throws {
        let textView = makeTextView()
        let coordinator = makeCoordinator()
        coordinator.configureNaturalWritingDirection(in: textView)

        let paragraphStyle = try #require(
            coordinator.bodyAttributes()[.paragraphStyle] as? NSParagraphStyle
        )
        #expect(textView.baseWritingDirection == .natural)
        #expect(textView.alignment == .natural)
        #expect(paragraphStyle.baseWritingDirection == .natural)
        #expect(paragraphStyle.alignment == .natural)

        let markdown = "# خطة الإطلاق\n- [ ] Ship 🚀\nمراجعة **نهائية**"
        coordinator.apply(markdown: markdown, to: textView)
        #expect(coordinator.serializedMarkdown(from: textView) == markdown)
    }

    @Test("preserves a selection while applying natural-direction content")
    func preservesSelectionAcrossNaturalDirectionApply() {
        let textView = makeTextView()
        let coordinator = makeCoordinator()
        coordinator.apply(markdown: "مرحبا Hello", to: textView)
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        coordinator.apply(markdown: "مرحبا Hello team", to: textView)

        #expect(textView.selectedRange() == NSRange(location: 0, length: 5))
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

    @Test("covers the whole final paragraph when the note has no trailing newline")
    func linePrefixCoversUnterminatedFinalParagraph() {
        let textView = makeTextView()
        let coordinator = makeCoordinator()
        coordinator.apply(markdown: "Team sync", to: textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        coordinator.perform(.bullet, in: textView)

        #expect(textView.string == "• Team sync")
        #expect(coordinator.serializedMarkdown(from: textView) == "- Team sync")
        // The caret belongs past "sync", not one character short of it.
        #expect(textView.selectedRange() == NSRange(location: 11, length: 0))
    }

    @Test("places the caret using UTF-16 offsets after a line prefix")
    func linePrefixCaretUsesUTF16Offsets() {
        let textView = makeTextView()
        let coordinator = makeCoordinator()
        coordinator.apply(markdown: "Ship 🚀", to: textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        coordinator.perform(.checkbox, in: textView)

        #expect(textView.string == "☐ Ship 🚀")
        // 2 for the marker, 5 for "Ship ", 2 for the astral-plane emoji.
        #expect(textView.selectedRange() == NSRange(location: 9, length: 0))
    }

    @Test("registers a line prefix with the undo manager")
    func linePrefixIsUndoable() {
        let textView = makeTextView()
        textView.allowsUndo = true
        let undoManager = textView.testUndoManager
        // No run loop here closes the automatic per-event group, so the test
        // opens and closes the group itself before asking for undo.
        undoManager.groupsByEvent = false

        var published: [String] = []
        let coordinator = makeCoordinator { published.append($0) }
        textView.delegate = coordinator
        coordinator.apply(markdown: "Team sync", to: textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        undoManager.beginUndoGrouping()
        coordinator.perform(.bullet, in: textView)
        undoManager.endUndoGrouping()

        // The didChangeText the command now sends must not double up the publish
        // that perform() already does.
        #expect(published == ["- Team sync"])
        #expect(undoManager.canUndo)

        undoManager.undo()
        #expect(textView.string == "Team sync")
    }

    @Test("registers a heading style change with the undo manager")
    func headingIsUndoable() {
        let textView = makeTextView()
        textView.allowsUndo = true
        let undoManager = textView.testUndoManager
        undoManager.groupsByEvent = false

        let coordinator = makeCoordinator()
        textView.delegate = coordinator
        coordinator.apply(markdown: "Team sync", to: textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        undoManager.beginUndoGrouping()
        coordinator.perform(.heading, in: textView)
        undoManager.endUndoGrouping()

        #expect(coordinator.serializedMarkdown(from: textView) == "# Team sync")
        #expect(undoManager.canUndo)

        undoManager.undo()
        #expect(coordinator.serializedMarkdown(from: textView) == "Team sync")
    }
}
