import Foundation

enum MeetingCleanupRejection: Error, Equatable {
    case emptyResponse
    case truncatedByProvider
    case unitCountMismatch(expected: Int, received: Int)
    case markerMissing(index: Int)
    case structuralUnitAltered(index: Int)
    case prefixAltered(index: Int)
    case unitContracted(index: Int)

    var reason: String {
        switch self {
        case .emptyResponse: return "empty response"
        case .truncatedByProvider: return "provider stopped at the output cap"
        case .unitCountMismatch(let expected, let received):
            return "expected \(expected) units, received \(received)"
        case .markerMissing(let index): return "marker for unit \(index) missing"
        case .structuralUnitAltered(let index): return "structural line \(index) was altered"
        case .prefixAltered(let index): return "timestamp or speaker changed on unit \(index)"
        case .unitContracted(let index): return "unit \(index) came back far shorter than it went in"
        }
    }
}

/// Builds the request payload for a chunk and checks what comes back.
///
/// The whole design exists because a partially-cleaned transcript is worse than
/// an uncleaned one: it reads as correct, and it would then hide the complete raw
/// transcript from every surface. So a chunk is accepted only when it can be
/// shown to be complete, and any rejection discards the entire cleanup.
enum MeetingTranscriptCleanupValidator {

    /// A cleaned unit shorter than this fraction of its input is treated as
    /// truncated rather than repaired.
    ///
    /// Cross-language repair legitimately moves length in both directions --
    /// البرايمريكية becoming `primary key` is longer, removed filler is shorter --
    /// so the floor is set well below any plausible repair and only catches a
    /// response that stopped part-way through an utterance. Structural checks
    /// cannot see that case: prefix, unit count, and markers all survive it.
    static let minimumLengthRatio = 0.45

    /// Units short enough that the ratio is noise rather than signal.
    static let ratioExemptLength = 24

    static func requestPayload(for chunk: [MeetingTranscriptUnit]) -> String {
        chunk.enumerated()
            .map { "\(MeetingTranscriptCleanupPrompt.marker(for: $0.offset))\n\($0.element.text)" }
            .joined(separator: "\n")
    }

    /// Splits a response back into per-unit text using the markers the model was
    /// told to echo. Returns nil for any unit whose marker did not come back.
    static func parse(response: String, expectedUnits: Int) -> [String?] {
        var result = [String?](repeating: nil, count: expectedUnits)
        // Locate each marker, then take everything up to the next one. Scanning by
        // marker rather than by line means a model that re-wrapped its output still
        // maps correctly.
        var ranges: [(index: Int, range: Range<String.Index>)] = []
        for index in 0..<expectedUnits {
            let marker = MeetingTranscriptCleanupPrompt.marker(for: index)
            if let range = response.range(of: marker) {
                ranges.append((index, range))
            }
        }
        ranges.sort { $0.range.lowerBound < $1.range.lowerBound }
        for (position, entry) in ranges.enumerated() {
            let start = entry.range.upperBound
            let end = position + 1 < ranges.count ? ranges[position + 1].range.lowerBound : response.endIndex
            guard start <= end else { continue }
            result[entry.index] = String(response[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    static func validate(
        chunk: [MeetingTranscriptUnit],
        response: String,
        wasTruncated: Bool
    ) -> Result<[MeetingTranscriptUnit], MeetingCleanupRejection> {
        if wasTruncated { return .failure(.truncatedByProvider) }
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyResponse)
        }

        let parsed = parse(response: response, expectedUnits: chunk.count)
        let received = parsed.compactMap { $0 }.count
        guard received == chunk.count else {
            return .failure(.unitCountMismatch(expected: chunk.count, received: received))
        }

        var cleaned: [MeetingTranscriptUnit] = []
        for (index, unit) in chunk.enumerated() {
            guard let text = parsed[index] else { return .failure(.markerMissing(index: index)) }

            switch unit.kind {
            case .structural:
                // Blank lines and the resume separator are structure, not language.
                guard text == unit.text.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return .failure(.structuralUnitAltered(index: index))
                }
                cleaned.append(unit)
                continue
            case .prefixed(let prefix):
                guard text.hasPrefix(prefix.trimmingCharacters(in: .whitespaces))
                    || text.hasPrefix(prefix) else {
                    return .failure(.prefixAltered(index: index))
                }
            case .content:
                break
            }

            if unit.text.count > ratioExemptLength {
                let ratio = Double(text.count) / Double(unit.text.count)
                guard ratio >= minimumLengthRatio else {
                    return .failure(.unitContracted(index: index))
                }
            }
            cleaned.append(MeetingTranscriptUnit(
                text: text,
                kind: unit.kind,
                lineIndex: unit.lineIndex,
                joiner: unit.joiner
            ))
        }
        return .success(cleaned)
    }
}
