import Foundation

/// The single list of audio file extensions Imla accepts as an import: the CLI's
/// `transcribe <file>`, the app's file picker and drag-and-drop, and the recording
/// store that keeps a copy of what was imported all read it. Three private copies
/// of this list drifted apart once already, which is why the CLI rejected the
/// formats voice notes actually arrive in.
///
/// Membership is about what AVFoundation (`AVAssetReader`, `AVAudioFile`,
/// `AVAudioPlayer`) can open on macOS, not about what Imla itself understands, so
/// widening this list needs a decode check, not just a name. Every extension here
/// except `amr` was decoded and played from a generated fixture on macOS 27; `amr`
/// is listed because AudioToolbox reports the AMR-NB/WB decoders and the `.3gp`
/// container it usually travels in was verified. Matroska (`webm`, `mkv`, `mka`)
/// and WMA fail to open on that same machine and are rejected with a conversion
/// hint instead.
public enum ImportableAudioFormat {
    /// Lower-case extensions, without the dot.
    public static let supportedExtensions: Set<String> = [
        // Recordings and exports.
        "wav", "aiff", "aif", "caf", "flac", "mp3", "aac", "m4a", "mp4", "mov",
        // Voice notes: WhatsApp (.opus), Telegram and Discord (.ogg), Android (.3gp, .amr).
        "opus", "ogg", "oga", "3gp", "amr",
    ]

    /// Extensions that turn up as voice notes but that AVFoundation cannot open,
    /// each with the one-line conversion that produces an accepted file.
    public static let conversionHints: [String: String] = {
        let matroska = "ffmpeg -i <file> -c:a aac <file>.m4a"
        return [
            "webm": matroska,
            "mkv": matroska,
            "mka": matroska,
            "wma": "ffmpeg -i <file>.wma -c:a aac <file>.m4a",
        ]
    }()

    /// `supportedExtensions` in a stable order for help text and error messages.
    public static let sortedExtensions: [String] = supportedExtensions.sorted()

    public static func normalizedExtension(of url: URL) -> String {
        url.pathExtension.lowercased()
    }

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(normalizedExtension(of: url))
    }

    /// The reason a file is rejected, phrased for the person who has to fix it.
    /// Names the conversion for known-unsupported voice-note containers; otherwise
    /// lists what is accepted.
    public static func rejectionMessage(for url: URL) -> String {
        let ext = normalizedExtension(of: url)
        let accepted = "Supported extensions: \(sortedExtensions.joined(separator: ", "))."
        guard let hint = conversionHints[ext] else {
            return ext.isEmpty
                ? "The file has no audio extension. \(accepted)"
                : "Unsupported audio file extension '.\(ext)'. \(accepted)"
        }
        return "'.\(ext)' audio cannot be decoded by macOS. Convert it first, for example: \(hint)"
    }
}
