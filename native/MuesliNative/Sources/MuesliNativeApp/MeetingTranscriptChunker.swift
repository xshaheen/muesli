import Foundation

/// One indivisible piece of a transcript sent for cleanup.
///
/// Usually a whole transcript line. An undiarized audio import can arrive as a
/// single very long line, which no chunk budget fits, so such a line is split
/// further and each piece tagged with the line it came from -- that tag is what
/// lets reassembly rejoin them without inventing a newline.
struct MeetingTranscriptUnit: Equatable {
    enum Kind: Equatable {
        /// `[HH:MM:SS] Speaker: text` -- the prefix is structure and must survive.
        case prefixed(prefix: String)
        /// A blank line, or the `— Resumed —` marker. Must come back byte-identical.
        case structural
        /// Content with no prefix, e.g. an import whose diarization was unavailable.
        case content
    }

    let text: String
    let kind: Kind
    /// Index of the transcript line this unit came from. Several units share one
    /// index when an oversized line had to be split.
    let lineIndex: Int
    /// What separated this unit from the previous one within the same line.
    let joiner: String

    var isRewritable: Bool {
        if case .structural = kind { return false }
        return true
    }
}

enum MeetingTranscriptChunker {

    /// `[10:00:00] Speaker 1: ` and similar. The speaker label is deliberately
    /// permissive -- diarization emits names as well as "Speaker N".
    private static let prefixPattern = try? NSRegularExpression(
        pattern: #"^\[\d{1,2}:\d{2}(?::\d{2})?\]\s*[^:]{1,60}:\s*"#
    )

    static func prefix(of line: String) -> String? {
        guard let prefixPattern else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard
            let match = prefixPattern.firstMatch(in: line, range: range),
            let matched = Range(match.range, in: line)
        else { return nil }
        return String(line[matched])
    }

    /// Splits a transcript into units no larger than `budget` characters.
    ///
    /// A line that fits stays whole. A line that does not is split on sentence
    /// boundaries, then on whitespace when the text has no punctuation -- which
    /// unpunctuated ASR output routinely does not -- and finally on character
    /// boundaries. The last fallback never splits inside a grapheme cluster;
    /// Arabic is the target language here and a split inside a cluster would
    /// corrupt the text before the model ever saw it.
    static func units(in transcript: String, budget: Int) -> [MeetingTranscriptUnit] {
        let lines = transcript.components(separatedBy: "\n")
        var units: [MeetingTranscriptUnit] = []
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty || isSeparator(line) {
                units.append(.init(text: line, kind: .structural, lineIndex: index, joiner: ""))
                continue
            }
            let linePrefix = prefix(of: line)
            let kind: MeetingTranscriptUnit.Kind = linePrefix.map { .prefixed(prefix: $0) } ?? .content
            if line.count <= budget {
                units.append(.init(text: line, kind: kind, lineIndex: index, joiner: ""))
                continue
            }
            let pieces = split(line, budget: budget)
            for (offset, piece) in pieces.enumerated() {
                // Only the first piece carries the line's prefix; the rest are
                // continuation content and must not be asked to reproduce one.
                let pieceKind: MeetingTranscriptUnit.Kind = offset == 0 ? kind : .content
                units.append(.init(
                    text: piece.text,
                    kind: pieceKind,
                    lineIndex: index,
                    joiner: offset == 0 ? "" : piece.joiner
                ))
            }
        }
        return units
    }

    /// Rebuilds a transcript from units, exactly inverting `units(in:budget:)`.
    static func reassemble(_ units: [MeetingTranscriptUnit]) -> String {
        var lines: [String] = []
        var current: String?
        var currentIndex: Int?
        for unit in units {
            if unit.lineIndex == currentIndex {
                current = (current ?? "") + unit.joiner + unit.text
            } else {
                if let current { lines.append(current) }
                current = unit.text
                currentIndex = unit.lineIndex
            }
        }
        if let current { lines.append(current) }
        return lines.joined(separator: "\n")
    }

    /// Groups units into request-sized chunks without splitting a unit.
    static func chunks(of units: [MeetingTranscriptUnit], budget: Int) -> [[MeetingTranscriptUnit]] {
        var chunks: [[MeetingTranscriptUnit]] = []
        var current: [MeetingTranscriptUnit] = []
        var size = 0
        for unit in units {
            let cost = unit.text.count + 1
            if !current.isEmpty, size + cost > budget {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(unit)
            size += cost
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func isSeparator(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "— Resumed —"
    }

    private struct Piece {
        let text: String
        let joiner: String
    }

    private static func split(_ line: String, budget: Int) -> [Piece] {
        let sentences = splitKeepingSeparators(line, on: [".", "!", "?", "؟", "۔"])
        var pieces: [Piece] = []
        for sentence in sentences {
            if sentence.text.count <= budget {
                pieces.append(sentence)
                continue
            }
            pieces.append(contentsOf: splitOnWhitespace(sentence, budget: budget))
        }
        return pieces.isEmpty ? [Piece(text: line, joiner: "")] : pieces
    }

    private static func splitKeepingSeparators(_ line: String, on terminators: Set<Character>) -> [Piece] {
        var pieces: [Piece] = []
        var buffer = ""
        var pendingJoiner = ""
        for character in line {
            buffer.append(character)
            if terminators.contains(character) {
                pieces.append(Piece(text: buffer, joiner: pendingJoiner))
                buffer = ""
                pendingJoiner = ""
            }
        }
        if !buffer.isEmpty {
            pieces.append(Piece(text: buffer, joiner: pendingJoiner))
        }
        return pieces
    }

    private static func splitOnWhitespace(_ piece: Piece, budget: Int) -> [Piece] {
        var pieces: [Piece] = []
        var buffer = ""
        var joiner = piece.joiner
        for word in piece.text.split(separator: " ", omittingEmptySubsequences: false) {
            let candidate = buffer.isEmpty ? String(word) : buffer + " " + String(word)
            if candidate.count > budget, !buffer.isEmpty {
                pieces.append(Piece(text: buffer, joiner: joiner))
                joiner = " "
                buffer = String(word)
            } else {
                buffer = candidate
            }
        }
        if !buffer.isEmpty { pieces.append(Piece(text: buffer, joiner: joiner)) }
        // A single token longer than the budget still has to go somewhere. Cut on
        // Character boundaries, which in Swift are grapheme clusters, so Arabic
        // combining marks stay attached to their base letter.
        return pieces.flatMap { current -> [Piece] in
            guard current.text.count > budget else { return [current] }
            var chunks: [Piece] = []
            var index = current.text.startIndex
            var isFirst = true
            while index < current.text.endIndex {
                let end = current.text.index(index, offsetBy: budget, limitedBy: current.text.endIndex)
                    ?? current.text.endIndex
                chunks.append(Piece(text: String(current.text[index..<end]), joiner: isFirst ? current.joiner : ""))
                isFirst = false
                index = end
            }
            return chunks
        }
    }
}
