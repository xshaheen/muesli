import AppKit
import Foundation
import ImlaCore

@MainActor
final class PreferencesWindowController: NSObject {
    private let controller: ImlaController

    init(controller: ImlaController) {
        self.controller = controller
    }

    func show() {
        controller.openHistoryWindow(tab: .settings)
    }

    func refresh() {
        controller.syncAppState()
    }
}
