import AppKit
import ApplicationServices
import OSLog

/// Pure gate deciding when a newly focused editable element earns a dictation reminder.
/// One reminder per focused element, a short global cooldown to absorb focus storms, and a
/// long per-element repeat interval so bouncing between a field and its neighbours never nags.
struct DictationFocusReminderGate<Token: Equatable>: Equatable {
    static var defaultCooldown: TimeInterval { 1.5 }
    static var defaultRepeatInterval: TimeInterval { 30 }
    static var rememberedElementLimit: Int { 12 }

    struct Reminded: Equatable {
        let token: Token
        let at: TimeInterval
    }

    private(set) var lastToken: Token?
    private(set) var lastShownAt: TimeInterval?
    private(set) var reminded: [Reminded] = []
    let cooldown: TimeInterval
    let repeatInterval: TimeInterval

    init(
        cooldown: TimeInterval = DictationFocusReminderGate.defaultCooldown,
        repeatInterval: TimeInterval = DictationFocusReminderGate.defaultRepeatInterval
    ) {
        self.cooldown = cooldown
        self.repeatInterval = repeatInterval
    }

    mutating func shouldRemind(for token: Token, at now: TimeInterval) -> Bool {
        if let lastToken, lastToken == token { return false }
        lastToken = token
        if let lastShownAt, now - lastShownAt < cooldown { return false }
        let repeatInterval = self.repeatInterval
        if reminded.contains(where: { $0.token == token && now - $0.at < repeatInterval }) { return false }
        lastShownAt = now
        reminded.removeAll { now - $0.at >= repeatInterval }
        reminded.append(Reminded(token: token, at: now))
        let overflow = reminded.count - Self.rememberedElementLimit
        if overflow > 0 {
            reminded.removeFirst(overflow)
        }
        return true
    }

    mutating func focusLost() {
        lastToken = nil
    }
}

/// Watches the frontmost application's focused UI element through an `AXObserver` and
/// reports when an editable text control gains focus. It never reads text content; it only
/// resolves the caret anchor the Mini already uses for placement.
@MainActor
final class DictationFocusReminderMonitor {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "FocusReminder")

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
        Self.logger.info("focus reminder monitor started")
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
        else {
            Self.logger.debug("attach skipped pid=\(pid ?? -1, privacy: .public) running=\(self.isRunning, privacy: .public)")
            return
        }

        DictationCaretAnchorProvider.enableManualAccessibility(for: pid)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<DictationFocusReminderMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.scheduleEvaluation() }
        }
        let createResult = AXObserverCreate(pid, callback, &created)
        guard createResult == .success, let created else {
            Self.logger.error("AXObserverCreate failed pid=\(pid, privacy: .public) code=\(createResult.rawValue, privacy: .public)")
            return
        }
        let application = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let addResult = AXObserverAddNotification(
            created,
            application,
            kAXFocusedUIElementChangedNotification as CFString,
            refcon
        )
        guard addResult == .success else {
            Self.logger.error("AXObserverAddNotification failed pid=\(pid, privacy: .public) code=\(addResult.rawValue, privacy: .public)")
            return
        }
        Self.logger.debug("attached to pid=\(pid, privacy: .public)")
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        observedProcessIdentifier = pid
        // The app may already have a focused field; the notification only fires on change.
        scheduleEvaluation()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
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
            Self.logger.debug("evaluate: no editable focus in observed pid=\(self.observedProcessIdentifier ?? -1, privacy: .public)")
            gate.focusLost()
            onFocusLost?()
            return
        }
        let remind = gate.shouldRemind(for: AXElementToken(element: focus.element), at: now())
        Self.logger.debug("evaluate: editable focus pid=\(focus.processIdentifier, privacy: .public) remind=\(remind, privacy: .public)")
        if remind {
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
