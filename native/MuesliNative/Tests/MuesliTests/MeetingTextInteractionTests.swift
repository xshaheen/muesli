import AppKit
import SwiftUI
import Testing
@testable import MuesliNativeApp

@Suite("Meeting text interaction")
struct MeetingTextInteractionTests {
    @Test("transcript text direction does not change speaker role")
    func transcriptDirectionIsIndependentFromRole() throws {
        let messages = TranscriptChatMessage.messages(from: """
        [10:00:00] You: مرحبا بالفريق
        [10:00:04] Speaker 1: Hello team
        """)

        let user = try #require(messages.first)
        let other = try #require(messages.last)
        #expect(user.isUser)
        #expect(user.textDirection == .rightToLeft)
        #expect(!other.isUser)
        #expect(other.textDirection == .leftToRight)
        #expect(LiveTranscriptBubble.contentDirection(for: ["… 42 مرحبا"]) == .rightToLeft)
    }

    @Test("title anchor and marquee travel follow content direction")
    func titleDirectionGeometry() {
        #expect(NaturalTextDirection.resolve("2026 — خطة الإطلاق") == .rightToLeft)
        #expect(NaturalTextDirection.resolve("2026 launch plan") == .leftToRight)
        #expect(NaturalTextDirection.resolve("خطة الإطلاق").frameAlignment == .trailing)
        #expect(NaturalTextDirection.resolve("Launch plan").frameAlignment == .leading)
        #expect(MeetingTitlePresentation.marqueeOffset(for: "خطة طويلة", distance: 120) == 120)
        #expect(MeetingTitlePresentation.marqueeOffset(for: "A long plan", distance: 120) == -120)
    }

    @Test("meeting prose uses one native selectable surface per logical block")
    @MainActor
    func nativeSelectableSurface() {
        let field = MeetingSelectableTextField()

        #expect(field.isSelectable)
        #expect(!field.isEditable)
        #expect(!field.drawsBackground)
        #expect(field.maximumNumberOfLines == 0)

        let transcript = MeetingSelectableTextContent.transcript(
            metadata: "Speaker 1  10:04",
            body: "مرحبا بالفريق",
            bodyPointSize: 14,
            isPartial: false
        )
        #expect(transcript.string == "Speaker 1  10:04\nمرحبا بالفريق")
        let transcriptParagraph = transcript.attribute(
            .paragraphStyle,
            at: transcript.length - 1,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(transcriptParagraph?.baseWritingDirection == .rightToLeft)

        let markdown = MeetingSelectableTextContent.markdown(
            "# Summary\n- First point\n1. النقطة الثانية",
            bodyPointSize: 13
        )
        #expect(markdown.string == "Summary\n•\tFirst point\n1.\tالنقطة الثانية")

        let host = NSHostingView(rootView: MeetingSelectableText(attributedText: markdown)
            .frame(width: 280))
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 160)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()

        let renderedField = Self.firstSelectableField(in: host)
        renderedField?.selectText(nil)
        #expect(renderedField?.currentEditor()?.selectedRange.length == markdown.length)
        renderedField?.currentEditor()?.selectedRange = NSRange(location: 2, length: 7)
        #expect(renderedField?.currentEditor()?.selectedRange == NSRange(location: 2, length: 7))
        window.orderOut(nil)
    }

    @Test("live transcript renders every committed message body")
    @MainActor
    func liveTranscriptRendersEveryCommittedMessageBody() {
        let messages = TranscriptChatMessage.messages(from: """
        [20:02:09] You: That's okay, baby.
        [20:02:13] You: I do.
        [20:02:14] You: It's okay.
        """)
        let host = NSHostingView(rootView: LiveTranscriptFeedView(
            messages: messages,
            partialYou: "",
            partialOthers: "",
            horizontalPadding: 16,
            topPadding: 8,
            bottomPadding: 8
        ))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 320)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()

        let fields = Self.selectableFields(in: host)
        #expect(fields.map(\.stringValue) == [
            "You  20:02:09\nThat's okay, baby.",
            "You  20:02:13\nI do.",
            "You  20:02:14\nIt's okay.",
        ])
        #expect(fields.allSatisfy { $0.frame.height >= $0.fittingSize.height })
        window.orderOut(nil)
    }

    /// The merged panel must not fall back to the main window's bubble feed: node 17's
    /// line list carries the utterance alone, with the speaker in its own gutter and no
    /// `You  20:02:09` metadata header baked into the body.
    @Test("the panel feed renders bare utterances, not bubble metadata")
    @MainActor
    func panelFeedRendersBareUtterances() {
        let messages = TranscriptChatMessage.messages(from: """
        [20:02:09] Others: Let's lock the launch date.
        [20:02:13] You: Agreed.
        """)
        let host = NSHostingView(rootView: MeetingPanelTranscriptFeed(
            messages: messages,
            partialYou: "  Sure, I'll send them right after the  ",
            partialOthers: "",
            onOpen: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 290)
        host.layoutSubtreeIfNeeded()

        let fields = Self.selectableFields(in: host)
        #expect(fields.map(\.stringValue) == [
            "Let's lock the launch date.",
            "Agreed.",
            "Sure, I'll send them right after the",
        ])
        #expect(fields.allSatisfy { !$0.stringValue.contains("\n") })
    }

    @Test("large meeting notes use a native scroll-backed text view")
    @MainActor
    func largeMeetingNotesUseNativeScrolling() throws {
        let markdown = Self.recoveredMeetingMarkdown(characterCount: 143_542)
        #expect(markdown.count == 143_542)
        #expect(MeetingNotesPresentation.renderedMarkdown(for: markdown) == markdown)

        let host = NSHostingView(rootView: MeetingNotesView(markdown: markdown))
        host.frame = NSRect(x: 0, y: 0, width: 920, height: 640)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()

        let textView = try #require(Self.firstTextView(in: host))
        #expect(textView.isSelectable)
        #expect(!textView.isEditable)
        #expect(textView.enclosingScrollView?.documentView === textView)
        let expectedContentWidth = host.bounds.width - 2 * MuesliTheme.spacing24
        #expect(textView.textContainer?.containerSize.width == expectedContentWidth)
        #expect(textView.frame.height > host.bounds.height)
        #expect(textView.string.contains("A recovered transcript line"))
        #expect(textView.string.count == markdown.count)
        window.orderOut(nil)
    }

    @Test("mixed-language meeting notes avoid intrinsic text measurement")
    @MainActor
    func mixedLanguageMeetingNotesUseNativeScrolling() throws {
        let markdown = Self.mixedLanguageMeetingMarkdown(characterCount: 5_012)
        #expect(markdown.count == 5_012)

        let host = NSHostingView(rootView: MeetingNotesView(markdown: markdown))
        host.frame = NSRect(x: 0, y: 0, width: 920, height: 640)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()

        let textView = try #require(Self.firstTextView(in: host))
        #expect(textView.isSelectable)
        #expect(!textView.isEditable)
        #expect(textView.enclosingScrollView?.documentView === textView)
        #expect(textView.string.count == markdown.count)
        #expect(textView.string.contains("مرحبا"))
        #expect(textView.string.contains("สวัสดี"))
        window.orderOut(nil)
    }

    @Test("chat draft survives the chat view being recreated")
    @MainActor
    func chatDraftSurvivesViewRecreation() throws {
        var draft = "Unsent follow-up question"
        let draftBinding = Binding(
            get: { draft },
            set: { draft = $0 }
        )
        let conversation = MeetingChatConversation()
        let makeChat = {
            AnyView(MeetingChatView(
                conversation: conversation,
                draft: draftBinding,
                transcript: { "A completed meeting transcript" },
                hasTranscript: true,
                systemPrompt: MeetingChatPrompts.completed,
                config: { AppConfig() }
            ))
        }
        let host = NSHostingView(rootView: makeChat())
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        host.layoutSubtreeIfNeeded()

        #expect(try #require(Self.firstEditableField(in: host)).stringValue == draft)

        host.rootView = AnyView(Text("Notes"))
        host.layoutSubtreeIfNeeded()
        host.rootView = makeChat()
        host.layoutSubtreeIfNeeded()

        #expect(try #require(Self.firstEditableField(in: host)).stringValue == draft)
    }

    @Test("meeting notes trim only the rendered copy after the display cap")
    func largeMeetingNotesTrimRenderedCopy() {
        let retainedPrefix = String(
            repeating: "🙂",
            count: MeetingNotesPresentation.maximumRenderedCharacters
        )
        let storedMarkdown = retainedPrefix + "TAIL"

        let renderedMarkdown = MeetingNotesPresentation.renderedMarkdown(for: storedMarkdown)

        #expect(renderedMarkdown.hasPrefix(retainedPrefix))
        #expect(!renderedMarkdown.contains("TAIL"))
        #expect(renderedMarkdown.hasSuffix(MeetingNotesPresentation.truncationNotice))
        #expect(storedMarkdown.hasSuffix("TAIL"))
    }

    @Test("meeting notes view renders the bounded copy")
    @MainActor
    func meetingNotesViewRendersBoundedCopy() throws {
        let storedMarkdown = Self.recoveredMeetingMarkdown(
            characterCount: MeetingNotesPresentation.maximumRenderedCharacters
        ) + "TAIL"

        let host = NSHostingView(rootView: MeetingNotesView(markdown: storedMarkdown))
        host.frame = NSRect(x: 0, y: 0, width: 920, height: 640)
        host.layoutSubtreeIfNeeded()

        let textView = try #require(Self.firstTextView(in: host))
        #expect(!textView.string.contains("TAIL"))
        #expect(textView.string.contains("Meeting notes were truncated for display"))
    }

    @Test("meeting notes at the display cap remain byte-for-byte unchanged")
    func meetingNotesAtDisplayCapRemainUnchanged() {
        let markdown = String(
            repeating: "x",
            count: MeetingNotesPresentation.maximumRenderedCharacters
        )

        #expect(MeetingNotesPresentation.renderedMarkdown(for: markdown) == markdown)
    }

    @Test("large meeting notes preserve the readable line-width cap")
    @MainActor
    func largeMeetingNotesPreserveReadableWidth() throws {
        let markdown = String(repeating: "A long recovered meeting note.\n", count: 800)
        let host = NSHostingView(rootView: MeetingNotesView(markdown: markdown))
        host.frame = NSRect(x: 0, y: 0, width: 1_400, height: 640)
        host.layoutSubtreeIfNeeded()

        let textView = try #require(Self.firstTextView(in: host))
        #expect(textView.textContainer?.containerSize.width == MeetingNotesPresentation.maximumContentWidth)
        #expect(textView.textContainerInset.width > MuesliTheme.spacing24)
    }

    private static func firstSelectableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isSelectable { return field }
        return view.subviews.lazy.compactMap(firstSelectableField(in:)).first
    }

    private static func selectableFields(in view: NSView) -> [NSTextField] {
        let current = (view as? NSTextField).map { [$0] } ?? []
        return current + view.subviews.flatMap(selectableFields(in:))
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView,
           textView.enclosingScrollView?.documentView === textView {
            return textView
        }
        return view.subviews.lazy.compactMap(firstTextView(in:)).first
    }

    private static func firstEditableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap(firstEditableField(in:)).first
    }

    private static func recoveredMeetingMarkdown(characterCount: Int) -> String {
        let line = "[10:04:00] Speaker 1: A recovered transcript line that remains selectable.\n"
        return repeatedMarkdown(line: line, characterCount: characterCount)
    }

    private static func mixedLanguageMeetingMarkdown(characterCount: Int) -> String {
        let line = "[10:04:00] Speaker 1: مرحبا team 你好 สวัสดี — mixed meeting notes.\n"
        return repeatedMarkdown(line: line, characterCount: characterCount)
    }

    private static func repeatedMarkdown(line: String, characterCount: Int) -> String {
        let lineCount = characterCount / line.count + 1
        return String(String(repeating: line, count: lineCount).prefix(characterCount))
    }

}
