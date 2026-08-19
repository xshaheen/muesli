import AppKit
import ApplicationServices

/// Pure gate deciding when a newly focused editable element earns a dictation reminder.
/// One reminder per focused element; a short global cooldown absorbs focus storms.
struct DictationFocusReminderGate<Token: Equatable>: Equatable {
    static var defaultCooldown: TimeInterval { 1.5 }

    private(set) var lastToken: Token?
    private(set) var lastShownAt: TimeInterval?
    let cooldown: TimeInterval

    init(cooldown: TimeInterval = DictationFocusReminderGate.defaultCooldown) {
        self.cooldown = cooldown
    }

    mutating func shouldRemind(for token: Token, at now: TimeInterval) -> Bool {
        if let lastToken, lastToken == token { return false }
        lastToken = token
        if let lastShownAt, now - lastShownAt < cooldown { return false }
        lastShownAt = now
        return true
    }

    mutating func focusLost() {
        lastToken = nil
    }
}

/// Watches the frontmost application's focused UI element through an `AXObserver` and
/// reports when an editable text element with a real caret gains focus. It never reads
/// text content; it only resolves the caret anchor the Mini already uses for placement.
@MainActor
final class DictationFocusReminderMonitor {
    var onEditableFocus: ((DictationCaretAnchorProvider.EditableFocus) -> Void)?
    var onFocusLost: (() -> Void)?

    private let now: () -> TimeInterval
    private var gate = DictationFocusReminderGate<AXElementToken>()
    private var observer: AXObserver?
    private var observedProcessIdentifier: pid_t?
    private var activationObserver: NSObjectProtocol?
    private var evaluationTimer: Timer?
    private var isRunning = false

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    var isRunningForTesting: Bool { isRunning }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            Task { @MainActor [weak self] in self?.attach(to: pid) }
        }
        attach(to: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        detach()
        evaluationTimer?.invalidate()
        evaluationTimer = nil
        gate.focusLost()
    }

    private func attach(to pid: pid_t?) {
        detach()
        gate.focusLost()
        onFocusLost?()
        guard isRunning,
              let pid,
              pid != ProcessInfo.processInfo.processIdentifier,
              AXIsProcessTrusted()
        else { return }

        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<DictationFocusReminderMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.scheduleEvaluation() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let application = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(
            created,
            application,
            kAXFocusedUIElementChangedNotification as CFString,
            refcon
        ) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        observedProcessIdentifier = pid
        // The app may already have a focused field; the notification only fires on change.
        scheduleEvaluation()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedProcessIdentifier = nil
    }

    private func scheduleEvaluation() {
        evaluationTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluateFocus() }
        }
        RunLoop.main.add(timer, forMode: .common)
        evaluationTimer = timer
    }

    private func evaluateFocus() {
        guard isRunning else { return }
        guard let focus = DictationCaretAnchorProvider.currentEditableFocus(),
              focus.processIdentifier == observedProcessIdentifier
        else {
            gate.focusLost()
            onFocusLost?()
            return
        }
        if gate.shouldRemind(for: AXElementToken(element: focus.element), at: now()) {
            onEditableFocus?(focus)
        }
    }
}

/// Equatable wrapper so `AXUIElement` identity can drive the reminder gate.
struct AXElementToken: Equatable {
    let element: AXUIElement

    static func == (lhs: AXElementToken, rhs: AXElementToken) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}
