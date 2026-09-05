import Foundation

/// The user's standing preferences for how Muesli rewrites their words.
///
/// One owner for the normalization, the reserved-delimiter stripping, and the
/// delimited block text, so dictation cleanup, meeting cleanup, and meeting
/// notes cannot drift on any of them.
enum CustomInstructions {
    /// Global cap in characters. Every consumer shares one model context with
    /// the transcript, so instructions are bounded rather than open-ended.
    static let maxLength = 2_000

    static let openingTag = "<CUSTOM-INSTRUCTIONS>"
    static let closingTag = "</CUSTOM-INSTRUCTIONS>"

    /// Sequences the text may never carry: the block's own tags, which would let
    /// the text close the block early, and the meeting unit-marker prefix, which
    /// would let it forge a marker the cleanup validator trusts.
    static let reservedSequences = [closingTag, openingTag, MeetingTranscriptCleanupPrompt.unitMarker]

    static let dictationPreamble = """
    The user's standing preferences for wording and formatting. Apply them only \
    where they do not conflict with the instructions above.
    """

    static let meetingCleanupPreamble = """
    The user's standing preferences for wording and formatting. Apply them only \
    where they do not change the number of lines, the markers, or the language \
    the speaker used.
    """

    static let meetingNotesPreamble = """
    The user's standing preferences for wording and formatting. Apply them only \
    where they do not change the template structure or the required output language.
    """

    /// Trim first, then cap, so leading whitespace never costs meaningful text.
    static func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxLength))
    }

    /// The delimited block for one prompt, or nil when nothing meaningful remains.
    ///
    /// `limit` lets a consumer with a tighter context budget shorten the body
    /// below the global cap; it never raises it.
    static func promptBlock(_ text: String, preamble: String, limit: Int = maxLength) -> String? {
        let stripped = removingReservedSequences(normalized(text))
        let body = String(stripped.prefix(max(0, min(limit, maxLength))))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return """
        \(openingTag)
        \(preamble)

        \(body)
        \(closingTag)
        """
    }

    /// Repeats until no reserved sequence remains, so one that a removal
    /// reassembles from its neighbours is removed too.
    private static func removingReservedSequences(_ text: String) -> String {
        var result = text
        var changed = true
        while changed {
            changed = false
            for sequence in reservedSequences where result.contains(sequence) {
                result = result.replacingOccurrences(of: sequence, with: "")
                changed = true
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
