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
    var bodyFont: Font = MuesliTheme.body()

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            let lines = markdown.components(separatedBy: .newlines)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                markdownLine(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func markdownLine(_ rawLine: String) -> some View {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let indentLevel = Self.indentLevel(for: rawLine)
        let direction = Self.contentDirection(for: rawLine)
        if line.isEmpty {
            Color.clear
                .frame(height: MuesliTheme.spacing8)
        } else if let heading = Self.headingContent(from: line) {
            Text(heading.text)
                .font(Self.headingFont(level: heading.level))
                .foregroundStyle(MuesliTheme.textPrimary)
                .padding(.top, Self.headingTopPadding(level: heading.level))
                .environment(\.layoutDirection, direction.layoutDirection)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: direction.frameAlignment)
        } else if line.hasPrefix("- [ ] ") {
            listRow(
                text: String(line.dropFirst(6)),
                indentLevel: indentLevel,
                direction: direction,
                systemImage: "square"
            )
        } else if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            listRow(
                text: String(line.dropFirst(6)),
                indentLevel: indentLevel,
                direction: direction,
                systemImage: "checkmark.square",
                iconColor: MuesliTheme.success
            )
        } else if line.hasPrefix("- ") {
            listRow(text: String(line.dropFirst(2)), indentLevel: indentLevel, direction: direction)
        } else if let numbered = Self.numberedListContent(from: line) {
            HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing8) {
                Text(numbered.marker)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 22, alignment: .trailing)
                Text(Self.inline(numbered.text))
                    .font(bodyFont)
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .environment(\.layoutDirection, direction.layoutDirection)
            .padding(Self.listIndentationEdge(for: rawLine), CGFloat(indentLevel) * MuesliTheme.spacing20)
            .frame(maxWidth: .infinity, alignment: direction.frameAlignment)
        } else {
            Text(Self.inline(line))
                .font(bodyFont)
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineSpacing(3)
                .environment(\.layoutDirection, direction.layoutDirection)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: direction.frameAlignment)
        }
    }

    @ViewBuilder
    private func listRow(
        text: String,
        indentLevel: Int,
        direction: NaturalTextDirection,
        systemImage: String? = nil,
        iconColor: Color = MuesliTheme.textTertiary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(iconColor)
                    .frame(width: 14, alignment: .center)
            } else {
                Circle()
                    .fill(MuesliTheme.textTertiary)
                    .frame(width: 4, height: 4)
                    .offset(y: -2)
                    .frame(width: 14, alignment: .center)
            }
            Text(Self.inline(text))
                .font(bodyFont)
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.layoutDirection, direction.layoutDirection)
        .padding(direction == .rightToLeft ? .trailing : .leading, CGFloat(indentLevel) * MuesliTheme.spacing20)
        .frame(maxWidth: .infinity, alignment: direction.frameAlignment)
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

    static func listIndentationEdge(for rawLine: String) -> Edge.Set {
        contentDirection(for: rawLine) == .rightToLeft ? .trailing : .leading
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

    private static func headingFont(level: Int) -> Font {
        switch level {
        case 1: MuesliTheme.title1()
        case 2: MuesliTheme.title3()
        default: MuesliTheme.headline()
        }
    }

    private static func headingTopPadding(level: Int) -> CGFloat {
        switch level {
        case 1: MuesliTheme.spacing8
        case 2: MuesliTheme.spacing12
        default: MuesliTheme.spacing4
        }
    }

    private static func indentLevel(for line: String) -> Int {
        let spaces = line.prefix { character in
            character == " " || character == "\t"
        }.reduce(0) { count, character in
            count + (character == "\t" ? 4 : 1)
        }
        return min(spaces / 2, 4)
    }

    private static func numberedListContent(from line: String) -> (marker: String, text: String)? {
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
