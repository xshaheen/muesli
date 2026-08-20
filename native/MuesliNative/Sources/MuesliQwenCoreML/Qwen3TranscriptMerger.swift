import Foundation

/// Conservative exact-overlap merge. It removes an overlap only when at least
/// three complete words or eight grapheme clusters agree; shorter/ambiguous
/// boundaries preserve both window transcripts.
public enum Qwen3TranscriptMerger {
    public static let minimumWordOverlap = 3
    public static let minimumGraphemeOverlap = 8

    public static func merge(_ transcripts: [String]) -> String {
        transcripts.reduce(into: "") { accumulated, next in
            accumulated = merge(accumulated, next)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func merge(_ left: String, _ right: String) -> String {
        let left = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }

        if let prefixEnd = wordOverlapPrefixEnd(left: left, right: right) {
            return join(left, String(right[prefixEnd...]))
        }
        if let prefixEnd = graphemeOverlapPrefixEnd(left: left, right: right) {
            return join(left, String(right[prefixEnd...]))
        }
        return join(left, right)
    }

    private static func wordOverlapPrefixEnd(left: String, right: String) -> String.Index? {
        let leftWords = wordRanges(in: left)
        let rightWords = wordRanges(in: right)
        let maximum = min(leftWords.count, rightWords.count)
        guard maximum >= minimumWordOverlap else { return nil }

        for count in stride(from: maximum, through: minimumWordOverlap, by: -1) {
            let lhs = leftWords.suffix(count).map { normalize(String(left[$0])) }
            let rhs = rightWords.prefix(count).map { normalize(String(right[$0])) }
            guard lhs == rhs else { continue }
            return rightWords[count - 1].upperBound
        }
        return nil
    }

    private static func graphemeOverlapPrefixEnd(left: String, right: String) -> String.Index? {
        let leftCharacters = Array(left)
        let rightCharacters = Array(right)
        let maximum = min(leftCharacters.count, rightCharacters.count)
        guard maximum >= minimumGraphemeOverlap else { return nil }

        for count in stride(from: maximum, through: minimumGraphemeOverlap, by: -1) {
            let lhs = String(leftCharacters.suffix(count)).folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            let rhs = String(rightCharacters.prefix(count)).folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard lhs == rhs else { continue }
            return right.index(right.startIndex, offsetBy: count)
        }
        return nil
    }

    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords]) {
            _, range, _, _ in ranges.append(range)
        }
        return ranges
    }

    private static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func join(_ left: String, _ right: String) -> String {
        let right = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !right.isEmpty else { return left }
        let needsSeparator = left.last.map { !$0.isWhitespace } == true
            && right.first.map { !$0.isWhitespace && !$0.isPunctuation } == true
        return left + (needsSeparator ? " " : "") + right
    }
}
