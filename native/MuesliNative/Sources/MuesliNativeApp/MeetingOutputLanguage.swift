import Foundation

enum MeetingOutputLanguage: Equatable {
    case arabic
    case unspecified

    // Arabic technical meetings frequently contain Latin product names and code.
    private static let minimumArabicLetterShare = 0.25
    // Several neighboring languages use Arabic script; repeated extension letters
    // are a stronger signal that automatic Arabic translation would be incorrect.
    private static let minimumPersoArabicExtensionShare = 0.03

    var summaryFailureHeading: String {
        self == .arabic ? "## تعذر إنشاء الملخص" : "## Summary failed"
    }

    var meetingLabel: String {
        self == .arabic ? "الاجتماع" : "Meeting"
    }

    var summaryFailureMessage: String {
        self == .arabic
            ? "تعذر على Muesli إنشاء ملاحظات منظمة للاجتماع."
            : "Muesli could not generate structured meeting notes."
    }

    var writtenNotesHeading: String {
        self == .arabic ? "### ملاحظات مكتوبة" : "### Written notes"
    }

    var rawTranscriptHeading: String {
        self == .arabic ? "## النص الخام" : "## Raw Transcript"
    }

    static func detect(transcript: String, manualNotes: String? = nil) -> Self {
        let transcriptCounts = letterCounts(in: transcriptContent(from: transcript))
        let counts = transcriptCounts.total > 0
            ? transcriptCounts
            : letterCounts(in: manualNotes ?? "")
        guard counts.total > 0 else { return .unspecified }
        let persoArabicShare = Double(counts.persoArabic) / Double(counts.total)
        guard counts.persoArabic < 2 || persoArabicShare < minimumPersoArabicExtensionShare else {
            return .unspecified
        }
        let arabicShare = Double(counts.arabic) / Double(counts.total)
        return arabicShare >= minimumArabicLetterShare ? .arabic : .unspecified
    }

    private static func transcriptContent(from transcript: String) -> String {
        transcript.components(separatedBy: "\n").map { line in
            guard let prefix = MeetingTranscriptChunker.prefix(of: line) else { return line }
            return String(line.dropFirst(prefix.count))
        }.joined(separator: "\n")
    }

    private static func letterCounts(in text: String) -> (arabic: Int, persoArabic: Int, other: Int, total: Int) {
        var arabic = 0
        var persoArabic = 0
        var other = 0

        for scalar in text.unicodeScalars where isLetter(scalar) {
            if isPersoArabicExtension(scalar) {
                persoArabic += 1
            } else if isArabicScript(scalar) {
                arabic += 1
            } else {
                other += 1
            }
        }
        return (arabic, persoArabic, other, arabic + persoArabic + other)
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    private static func isPersoArabicExtension(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0679, 0x067E, 0x0686, 0x0688, 0x0691, 0x0698,
             0x06A9, 0x06AF, 0x06BA, 0x06BE, 0x06C1, 0x06CC, 0x06D2:
            return true
        default:
            return false
        }
    }

    private static func isArabicScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0600...0x06FF,
             0x0750...0x077F,
             0x0870...0x089F,
             0x08A0...0x08FF,
             0xFB50...0xFDFF,
             0xFE70...0xFEFF,
             0x1EE00...0x1EEFF:
            return true
        default:
            return false
        }
    }
}
