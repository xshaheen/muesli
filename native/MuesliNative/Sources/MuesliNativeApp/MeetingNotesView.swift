import AppKit
import SwiftUI
import MuesliCore

enum MeetingNotesPresentation {
    static let maximumContentWidth: CGFloat = 880
    // Bound layout work without altering the persisted meeting or transcript.
    static let maximumRenderedCharacters = 150_000
    static var truncationNotice: String { """


    ---

    *Meeting notes were truncated for display after \(maximumRenderedCharacters) characters. The stored meeting was not changed.*
    """
    }

    static func renderedMarkdown(for markdown: String) -> String {
        guard let trimIndex = markdown.index(
            markdown.startIndex,
            offsetBy: maximumRenderedCharacters,
            limitedBy: markdown.endIndex
        ), trimIndex < markdown.endIndex else {
            return markdown
        }

        return String(markdown[..<trimIndex]) + truncationNotice
    }
}

struct MeetingNotesView: View {
    let markdown: String

    var body: some View {
        // Intrinsic NSTextField sizing shapes the complete document on every
        // parent layout pass. Keep read-only notes in one scroll-backed native
        // surface so title edits never remeasure the meeting body.
        MeetingScrollableNotesText(markdown: markdown)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MeetingScrollableNotesText: NSViewRepresentable {
    let markdown: String

    final class Coordinator {
        var sourceMarkdown: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.drawsBackground = false

        let textView = MeetingScrollableNotesTextView(frame: scrollView.contentView.bounds)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.usesFindBar = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        scrollView.documentView = textView
        textView.updateTextContainerWidth()
        update(textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        update(textView, coordinator: context.coordinator)
    }

    private func update(_ textView: NSTextView, coordinator: Coordinator) {
        guard coordinator.sourceMarkdown != markdown else { return }
        let renderedMarkdown = MeetingNotesPresentation.renderedMarkdown(for: markdown)
        let attributedText = MeetingSelectableTextContent.markdown(renderedMarkdown, bodyPointSize: 14)
        textView.textStorage?.setAttributedString(attributedText)
        coordinator.sourceMarkdown = markdown
    }
}

private final class MeetingScrollableNotesTextView: NSTextView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTextContainerWidth()
    }

    func updateTextContainerWidth() {
        let minimumInset = MuesliTheme.spacing24
        let availableWidth = max(0, bounds.width - 2 * minimumInset)
        let contentWidth = bounds.width > 0
            ? min(MeetingNotesPresentation.maximumContentWidth, availableWidth)
            : MeetingNotesPresentation.maximumContentWidth
        let nextInset = NSSize(
            width: max(minimumInset, (bounds.width - contentWidth) / 2),
            height: MuesliTheme.spacing16
        )
        guard textContainerInset != nextInset || textContainer?.containerSize.width != contentWidth else {
            return
        }

        textContainerInset = nextInset
        textContainer?.containerSize = NSSize(
            width: contentWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
    }
}

/// Renders markdown the way notes and transcripts are rendered, without imposing a
/// scroll container or width.
///
/// Extracted so chat answers look like every other piece of prose in the app
/// instead of showing raw `**` and `-` characters.
/// Rendered markdown for a chat answer.
///
/// Hugs its text rather than filling. It used to do both — `fillsAvailableWidth: true` plus a
/// `maxWidth: .infinity` frame — which made it a second flexible child inside a bubble row that
/// already had a flexible `Spacer`. An `HStack` cannot divide width between two flexible children
/// analytically, so it falls back to probing them repeatedly, and a sample of the frozen chat tab
/// was dominated by exactly that: `sizeChildrenGenerallyWithConcreteMajorProposal` under
/// `StackLayout.placeChildren`, once per turn.
///
/// The bubble's width is bounded by its row's `Spacer(minLength:)`, so hugging here loses no
/// wrapping behaviour — it only stops the row having two things to solve for at once.
struct MeetingMarkdownContent: View {
    let markdown: String
    var bodyPointSize: CGFloat = 14

    var body: some View {
        MeetingSelectableText(attributedText: MeetingSelectableTextContent.markdown(
            markdown,
            bodyPointSize: bodyPointSize
        ))
        .fixedSize(horizontal: false, vertical: true)
    }

    static func contentDirection(for rawLine: String) -> NaturalTextDirection {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let content: String

        if let heading = headingContent(from: line) {
            content = String(heading.text.characters)
        } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            content = String(line.dropFirst(6))
        } else if line.hasPrefix("- ") {
            content = String(line.dropFirst(2))
        } else if let numbered = numberedListContent(from: line) {
            content = numbered.text
        } else {
            content = line
        }

        return NaturalTextDirection.resolve(content)
    }

    /// Renders inline markdown — bold, italic, code, links — within one line.
    ///
    /// Block structure (headings, lists, checkboxes) is matched by
    /// `markdownLine`, so parsing is inline-only: a stray `#` or `-` in body
    /// text stays literal instead of being re-read as a block marker. Text that
    /// fails to parse falls back to itself, so notes always render.
    static func inline(_ text: String) -> AttributedString {
        guard let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return AttributedString(text)
        }
        let hasUnsafeLink = parsed.runs.contains { run in
            guard let link = run.link else { return false }
            guard let scheme = link.scheme?.lowercased() else { return true }
            return scheme != "http" && scheme != "https"
        }
        return hasUnsafeLink ? AttributedString(text) : parsed
    }

    static func headingContent(from line: String) -> (level: Int, text: AttributedString)? {
        let headings = [
            (prefix: "### ", level: 3),
            (prefix: "## ", level: 2),
            (prefix: "# ", level: 1),
        ]
        guard let heading = headings.first(where: { line.hasPrefix($0.prefix) }) else {
            return nil
        }
        return (heading.level, inline(String(line.dropFirst(heading.prefix.count))))
    }

    static func indentLevel(for line: String) -> Int {
        let spaces = line.prefix { character in
            character == " " || character == "\t"
        }.reduce(0) { count, character in
            count + (character == "\t" ? 4 : 1)
        }
        return min(spaces / 2, 4)
    }

    static func numberedListContent(from line: String) -> (marker: String, text: String)? {
        guard let range = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) else {
            return nil
        }
        let marker = line[..<line.index(before: range.upperBound)]
            .trimmingCharacters(in: .whitespaces)
        let text = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !marker.isEmpty, !text.isEmpty else { return nil }
        return (String(marker), text)
    }
}
