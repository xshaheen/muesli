import Foundation

/// Who owns the computer-use overlay's Stop and Cancel buttons.
///
/// Quill and Computer Use share one floating surface, and both can be mid-flight
/// in different ways: a held hotkey still recording, a toggle session running, or
/// a captured selection waiting for its instruction. The click has to reach the
/// interaction the user is actually looking at, so the precedence lives here
/// rather than inside the closure that installs the overlay.
enum InteractiveOverlayAction: Equatable {
    case stopComputerUseToggle
    case stopQuilToggle
    case stopQuil
    case stopComputerUse
    case cancelQuil
    case cancelComputerUse
}

enum InteractiveOverlayActionPolicy {
    struct State: Equatable {
        /// Computer Use is recording under a hands-free toggle.
        var computerUseToggleRecording = false
        /// Quill is recording under a hands-free toggle.
        var quilToggleRecording = false
        /// A Quill recording has started and not yet been resolved.
        var quilInFlight = false
        /// Quill captured a selection and is waiting on its spoken instruction.
        var quilSelectionPending = false
    }

    /// Stop ends the recording that is running. A toggle outranks a held session
    /// because only the toggle has a mode to leave.
    static func stopAction(for state: State) -> InteractiveOverlayAction {
        if state.computerUseToggleRecording { return .stopComputerUseToggle }
        if state.quilToggleRecording { return .stopQuilToggle }
        if state.quilInFlight { return .stopQuil }
        return .stopComputerUse
    }

    /// Cancel discards the interaction. Quill claims it whenever any part of a
    /// Quill session is still live, including a selection captured before the
    /// user has said anything.
    static func cancelAction(for state: State) -> InteractiveOverlayAction {
        if state.quilToggleRecording || state.quilInFlight || state.quilSelectionPending {
            return .cancelQuil
        }
        return .cancelComputerUse
    }
}
