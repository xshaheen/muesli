import AppIntents

@available(macOS 13.0, *)
enum ImlaShortcutsError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noDictations
    case noMeetings
    case notRunning

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noDictations: return "Imla has no dictations yet."
        case .noMeetings: return "Imla has no meetings yet."
        case .notRunning: return "Imla isn't running. Open Imla and try again."
        }
    }
}
