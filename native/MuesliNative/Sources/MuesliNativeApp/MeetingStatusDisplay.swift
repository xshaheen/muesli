import SwiftUI
import MuesliCore

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
            return MuesliTheme.recording
        case .processing:
            // Work in progress is amber. It used the accent before, which made a meeting's
            // state follow whichever accent preset the user had picked.
            return MuesliTheme.transcribing
        case .completed:
            return MuesliTheme.success
        case .noteOnly:
            return MuesliTheme.textTertiary
        case .failed:
            return MuesliTheme.danger
        }
    }
}
