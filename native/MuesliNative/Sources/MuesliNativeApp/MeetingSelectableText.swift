import AppKit
import SwiftUI

/// A read-only AppKit text field used for meeting prose.
///
/// SwiftUI's text-selection modifier creates a separate selection field for
/// every `Text` value. Transcript bubbles and rendered Markdown contain many
/// such values, so a drag cannot select a complete logical block. This field
/// keeps each block in one native selection surface while remaining visually
/// indistinguishable from a label.
final class MeetingSelectableTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = true
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        allowsEditingTextAttributes = true
        usesSingleLineMode = false
        maximumNumberOfLines = 0
        lineBreakMode = .byWordWrapping
        cell?.wraps = true
        cell?.isScrollable = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct MeetingSelectableText: NSViewRepresentable {
    let attributedText: NSAttributedString
    var fillsAvailableWidth = false

    func makeNSView(context: Context) -> MeetingSelectableTextField {
        let field = MeetingSelectableTextField()
        field.attributedStringValue = attributedText
        return field
    }

    func updateNSView(_ field: MeetingSelectableTextField, context: Context) {
        // Reassigning the value tears down AppKit's field-editor selection.
        // Live transcript updates revisit existing rows, so preserve an active
        // selection whenever the logical block itself did not change.
        guard !field.attributedStringValue.isEqual(to: attributedText) else { return }
        field.attributedStringValue = attributedText
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: MeetingSelectableTextField,
        context: Context
    ) -> CGSize? {
        let unconstrained = attributedText.boundingRect(
            with: NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let width = max(
            1,
            fillsAvailableWidth
                ? (proposedWidth ?? ceil(unconstrained.width))
                : min(proposedWidth ?? unconstrained.width, ceil(unconstrained.width))
        )
        let bounds = attributedText.boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        // The attributed-string bounds can be one point shorter than the native
        // field cell. Returning that smaller height clips the final transcript line.
        let height = max(bounds.height, nsView.fittingSize.height)
        return CGSize(width: width, height: max(1, ceil(height)))
    }
}

enum MeetingSelectableTextContent {
    static func plain(
        _ text: String,
        pointSize: CGFloat,
        color: NSColor = .labelColor,
        italic: Bool = false,
        lineSpacing: CGFloat = 0
    ) -> NSAttributedString {
        attributedLine(
            MeetingMarkdownContent.inline(text),
            pointSize: pointSize,
            color: color,
            direction: NaturalTextDirection.resolve(text),
            italic: italic,
            lineSpacing: lineSpacing
        )
    }

    static func transcript(
        metadata: String?,
        body: String,
        bodyPointSize: CGFloat,
        isPartial: Bool
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let metadata, !metadata.isEmpty {
            result.append(attributedLine(
                AttributedString(metadata),
                pointSize: 10,
                weight: .medium,
                color: .tertiaryLabelColor,
                direction: NaturalTextDirection.resolve(body)
            ))
            result.append(newline(matching: result))
        }
        result.append(attributedLine(
            MeetingMarkdownContent.inline(body),
            pointSize: bodyPointSize,
            color: isPartial ? .secondaryLabelColor : .labelColor,
            direction: NaturalTextDirection.resolve(body),
            italic: isPartial,
            lineSpacing: 2
        ))
        return result
    }

    static func markdown(_ markdown: String, bodyPointSize: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: .newlines)

        for (index, rawLine) in lines.enumerated() {
            let renderedLine = markdownLine(rawLine, bodyPointSize: bodyPointSize)
            result.append(renderedLine)
            if index < lines.count - 1 {
                result.append(newline(matching: renderedLine))
            }
        }
        return result
    }

    private static func markdownLine(_ rawLine: String, bodyPointSize: CGFloat) -> NSAttributedString {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let direction = MeetingMarkdownContent.contentDirection(for: rawLine)

        if line.isEmpty {
            return NSAttributedString()
        }

        if let heading = MeetingMarkdownContent.headingContent(from: line) {
            let pointSize: CGFloat
            switch heading.level {
            case 1: pointSize = 28
            case 2: pointSize = 18
            default: pointSize = 15
            }
            return attributedLine(
                heading.text,
                pointSize: pointSize,
                weight: heading.level == 1 ? .bold : .semibold,
                color: .labelColor,
                direction: direction,
                paragraphSpacingBefore: heading.level == 1 ? 8 : (heading.level == 2 ? 12 : 4)
            )
        }

        let indentLevel = MeetingMarkdownContent.indentLevel(for: rawLine)
        if line.hasPrefix("- [ ] ") {
            return listLine(
                marker: "☐",
                text: String(line.dropFirst(6)),
                indentLevel: indentLevel,
                direction: direction,
                bodyPointSize: bodyPointSize
            )
        }
        if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            return listLine(
                marker: "☑",
                text: String(line.dropFirst(6)),
                indentLevel: indentLevel,
                direction: direction,
                bodyPointSize: bodyPointSize
            )
        }
        if line.hasPrefix("- ") {
            return listLine(
                marker: "•",
                text: String(line.dropFirst(2)),
                indentLevel: indentLevel,
                direction: direction,
                bodyPointSize: bodyPointSize
            )
        }
        if let numbered = MeetingMarkdownContent.numberedListContent(from: line) {
            return listLine(
                marker: numbered.marker,
                text: numbered.text,
                indentLevel: indentLevel,
                direction: direction,
                bodyPointSize: bodyPointSize
            )
        }

        return attributedLine(
            MeetingMarkdownContent.inline(line),
            pointSize: bodyPointSize,
            color: .labelColor,
            direction: direction,
            lineSpacing: 3
        )
    }

    private static func listLine(
        marker: String,
        text: String,
        indentLevel: Int,
        direction: NaturalTextDirection,
        bodyPointSize: CGFloat
    ) -> NSAttributedString {
        attributedLine(
            MeetingMarkdownContent.inline("\(marker)\t\(text)"),
            pointSize: bodyPointSize,
            color: .secondaryLabelColor,
            direction: direction,
            lineSpacing: 3,
            indentLevel: indentLevel,
            isList: true
        )
    }

    private static func attributedLine(
        _ content: AttributedString,
        pointSize: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor,
        direction: NaturalTextDirection,
        italic: Bool = false,
        lineSpacing: CGFloat = 0,
        paragraphSpacingBefore: CGFloat = 0,
        indentLevel: Int = 0,
        isList: Bool = false
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in content.runs {
            let text = String(content[run.range].characters)
            let intent = run.inlinePresentationIntent
            var font = NSFont.systemFont(ofSize: pointSize, weight: weight)
            if intent?.contains(.code) == true {
                font = NSFont.monospacedSystemFont(ofSize: pointSize * 0.92, weight: weight)
            }
            var traits: NSFontTraitMask = []
            if italic || intent?.contains(.emphasized) == true { traits.insert(.italicFontMask) }
            if intent?.contains(.stronglyEmphasized) == true { traits.insert(.boldFontMask) }
            if !traits.isEmpty {
                font = NSFontManager.shared.convert(font, toHaveTrait: traits)
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = direction == .rightToLeft ? .rightToLeft : .leftToRight
        paragraph.alignment = direction == .rightToLeft ? .right : .left
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacingBefore = paragraphSpacingBefore
        if isList {
            let indentation = CGFloat(indentLevel) * MuesliTheme.spacing20
            paragraph.firstLineHeadIndent = indentation
            paragraph.headIndent = indentation + 22
            paragraph.tabStops = [NSTextTab(textAlignment: .natural, location: indentation + 18)]
        }
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func newline(matching text: NSAttributedString) -> NSAttributedString {
        guard text.length > 0 else { return NSAttributedString(string: "\n") }
        return NSAttributedString(
            string: "\n",
            attributes: text.attributes(at: text.length - 1, effectiveRange: nil)
        )
    }
}
