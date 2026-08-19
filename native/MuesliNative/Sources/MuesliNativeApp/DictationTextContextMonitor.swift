import AppKit
import ApplicationServices
import OSLog

/// Equatable wrapper so `AXUIElement` identity can be compared.
struct AXElementToken: Equatable {
    let element: AXUIElement

    static func == (lhs: AXElementToken, rhs: AXElementToken) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

/// One observation of the focused editable text context.
struct DictationTextContextSample: Equatable {
    let anchor: CGPoint
    let processIdentifier: pid_t
    let hasSelection: Bool
    let element: AXElementToken
}

/// Transient user activity during which the idle dot stays out of the way.
struct DictationFollowerActivity: Equatable {
    /// Measured against the reference follower: gone while keys fly, back ~0.7 s after the last.
    static let typingHold: TimeInterval = 0.7
    static let scrollHold: TimeInterval = 0.6
    static let windowMoveHold: TimeInterval = 0.5
    static let spaceSwitchHold: TimeInterval = 0.6

    var isTyping = false
    var isScrolling = false
    var isWindowMoving = false
    var isSwitchingSpace = false

    var isSuppressing: Bool { isTyping || isScrolling || isWindowMoving || isSwitchingSpace }
}

/// Pure hysteresis for the idle dot: hold the last caret through brief dropouts and hide only
/// after a streak of misses, so a slow accessibility reply never blinks the dot.
struct DictationFollowerHysteresis: Equatable {
    static let hideAfterMisses = 3

    private(set) var heldAnchor: CGPoint?
    private(set) var missStreak = 0

    /// Returns the anchor to show, or nil once the miss streak is exhausted.
    mutating func observe(_ anchor: CGPoint?) -> CGPoint? {
        if let anchor {
            heldAnchor = anchor
            missStreak = 0
            return anchor
        }
        missStreak += 1
        if missStreak >= Self.hideAfterMisses {
            heldAnchor = nil
            return nil
        }
        return heldAnchor
    }

    mutating func reset() {
        heldAnchor = nil
        missStreak = 0
    }
}

/// Follows the focused editable text context of the frontmost application: an `AXObserver`
/// for focus/selection/window changes, a light poll for apps that stay silent, and global
/// event monitors that report typing, scrolling, Space switches and Escape. It never reads
/// text content; it resolves the caret anchor the Mini already uses for placement.
@MainActor
final class DictationTextContextMonitor {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "TextContext")

    var onSample: ((DictationTextContextSample?) -> Void)?
    /// The observed app's focused window frame (AppKit coordinates), for window pinning.
    var onWindowFrame: ((CGRect?, pid_t?) -> Void)?
    var onActivityChanged: ((DictationFollowerActivity) -> Void)?
    var onFocusChanged: (() -> Void)?
    var onEscape: (() -> Void)?

    private(set) var activity = DictationFollowerActivity() {
        didSet { if oldValue != activity { onActivityChanged?(activity) } }
    }

    private let pollInterval: TimeInterval
    private var observer: AXObserver?
    private var observedProcessIdentifier: pid_t?
    private var pollTimer: Timer?
    private var evaluationTimer: Timer?
    private var holdTimers: [String: Timer] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var eventMonitors: [Any] = []
    private var lastElement: AXElementToken?
    private var isRunning = false

    init(pollInterval: TimeInterval = 1 / 8) {
        self.pollInterval = pollInterval
    }

    var isRunningForTesting: Bool { isRunning }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Self.logger.notice("text context monitor started")
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            Task { @MainActor [weak self] in self?.attach(to: pid) }
        })
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.mark(\.isSwitchingSpace, for: DictationFollowerActivity.spaceSwitchHold, key: "space")
                self?.attach(to: NSWorkspace.shared.frontmostApplication?.processIdentifier)
            }
        })
        if let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor [weak self] in self?.handleKeyDown(event) }
        } {
            eventMonitors.append(keyMonitor)
        }
        if let scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.mark(\.isScrolling, for: DictationFollowerActivity.scrollHold, key: "scroll")
            }
        } {
            eventMonitors.append(scrollMonitor)
        }
        attach(to: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceTokens.removeAll()
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors.removeAll()
        holdTimers.values.forEach { $0.invalidate() }
        holdTimers.removeAll()
        detach()
        pollTimer?.invalidate()
        pollTimer = nil
        evaluationTimer?.invalidate()
        evaluationTimer = nil
        lastElement = nil
        activity = DictationFollowerActivity()
    }

    // MARK: Attachment

    private func attach(to pid: pid_t?) {
        detach()
        lastElement = nil
        onSample?(nil)
        guard isRunning,
              let pid,
              pid != ProcessInfo.processInfo.processIdentifier,
              AXIsProcessTrusted()
        else {
            Self.logger.notice("attach skipped pid=\(pid ?? -1, privacy: .public) running=\(self.isRunning, privacy: .public) trusted=\(AXIsProcessTrusted(), privacy: .public)")
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }
        DictationCaretAnchorProvider.enableManualAccessibility(for: pid)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<DictationTextContextMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { monitor.handleNotification(name) }
        }
        let createResult = AXObserverCreate(pid, callback, &created)
        guard createResult == .success, let created else {
            Self.logger.error("AXObserverCreate failed pid=\(pid, privacy: .public) code=\(createResult.rawValue, privacy: .public)")
            return
        }
        let application = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [
            kAXFocusedUIElementChangedNotification,
            kAXSelectedTextChangedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXFocusedWindowChangedNotification,
        ] {
            AXObserverAddNotification(created, application, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        observedProcessIdentifier = pid
        Self.logger.notice("attached pid=\(pid, privacy: .public)")
        startPolling()
        scheduleEvaluation()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedProcessIdentifier = nil
    }

    private func handleNotification(_ name: String) {
        switch name {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            mark(\.isWindowMoving, for: DictationFollowerActivity.windowMoveHold, key: "window")
        default:
            scheduleEvaluation()
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onEscape?()
            return
        }
        mark(\.isTyping, for: DictationFollowerActivity.typingHold, key: "typing")
    }

    private func mark(
        _ keyPath: WritableKeyPath<DictationFollowerActivity, Bool>,
        for hold: TimeInterval,
        key: String
    ) {
        activity[keyPath: keyPath] = true
        holdTimers[key]?.invalidate()
        let timer = Timer(timeInterval: hold, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.activity[keyPath: keyPath] = false
                self?.scheduleEvaluation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimers[key] = timer
    }

    // MARK: Sampling

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func scheduleEvaluation() {
        evaluationTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        evaluationTimer = timer
    }

    private var lastDiagnosticAt: TimeInterval = 0

    private func evaluate() {
        guard isRunning else { return }
        onWindowFrame?(observedProcessIdentifier.flatMap { DictationCaretAnchorProvider.focusedWindowFrame(for: $0) }, observedProcessIdentifier)
        let focus = DictationCaretAnchorProvider.currentEditableFocus()
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDiagnosticAt > 10 {
            lastDiagnosticAt = now
            Self.logger.notice("sample pid=\(self.observedProcessIdentifier ?? -1, privacy: .public) editable=\(focus != nil, privacy: .public) focusPid=\(focus?.processIdentifier ?? -1, privacy: .public) activity=\(self.activity.isSuppressing, privacy: .public)")
        }
        guard let focus, focus.processIdentifier == observedProcessIdentifier else {
            if lastElement != nil {
                lastElement = nil
                onFocusChanged?()
            }
            onSample?(nil)
            return
        }
        let token = AXElementToken(element: focus.element)
        if lastElement != token {
            lastElement = token
            onFocusChanged?()
        }
        onSample?(DictationTextContextSample(
            anchor: focus.anchor,
            processIdentifier: focus.processIdentifier,
            hasSelection: focus.hasSelection,
            element: token
        ))
    }
}
