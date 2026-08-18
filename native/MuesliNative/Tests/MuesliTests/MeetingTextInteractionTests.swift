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
            bottomPadding: 8,
            surfacePresentation: .floatingPanel
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

    private static func firstSelectableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isSelectable { return field }
        return view.subviews.lazy.compactMap(firstSelectableField(in:)).first
    }

    private static func selectableFields(in view: NSView) -> [NSTextField] {
        let current = (view as? NSTextField).map { [$0] } ?? []
        return current + view.subviews.flatMap(selectableFields(in:))
    }

}
