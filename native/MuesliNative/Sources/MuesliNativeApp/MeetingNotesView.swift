import SwiftUI
import MuesliCore

struct MeetingNotesView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            MeetingMarkdownContent(markdown: markdown)
                .frame(maxWidth: 880, alignment: .leading)
                .padding(.horizontal, MuesliTheme.spacing24)
                .padding(.vertical, MuesliTheme.spacing16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Renders markdown the way notes and transcripts are rendered, without imposing a
/// scroll container or width.
///
/// Extracted so chat answers look like every other piece of prose in the app
/// instead of showing raw `**` and `-` characters.
struct MeetingMarkdownContent: View {
    let markdown: String
    var bodyPointSize: CGFloat = 14

    var body: some View {
        MeetingSelectableText(attributedText: MeetingSelectableTextContent.markdown(
            markdown,
            bodyPointSize: bodyPointSize
        ), fillsAvailableWidth: true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
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
