import SwiftUI
import ImlaCore

extension MeetingStatus {
    var displayLabel: String {
        switch self {
        case .recording:
            return "Recording"
        case .processing:
            return "Processing"
        case .completed:
            return "Completed"
        case .noteOnly:
            return "Note only"
        case .failed:
            return "Needs attention"
        }
    }

    var displayColor: Color {
        switch self {
        case .recording:
            return ImlaTheme.recording
        case .processing:
            // Work in progress is amber. It used the accent before, which made a meeting's
            // state follow whichever accent preset the user had picked.
            return ImlaTheme.transcribing
        case .completed:
            return ImlaTheme.success
        case .noteOnly:
            return ImlaTheme.textTertiary
        case .failed:
            return ImlaTheme.danger
        }
    }
}
