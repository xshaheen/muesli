enum MeetingStartPresentation: Equatable {
    case foregroundNotes
    case floatingPanel
    case backgroundPill

    static let compactControl: Self = .floatingPanel

    var opensMeetingDocument: Bool {
        self == .foregroundNotes
    }

    var presentsHistoryWindow: Bool {
        self == .foregroundNotes
    }

    var presentsFloatingPanelWhenRecordingStarts: Bool {
        self == .floatingPanel
    }
}
