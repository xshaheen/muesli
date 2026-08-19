import AppKit
import OSLog

/// The sole window and lifecycle owner for short-lived dictation feedback.
@MainActor
final class DictationMiniIndicatorController: NSObject {
    private static let idleLogger = Logger(subsystem: "com.muesli.native", category: "MiniIdle")
    struct Generation: Hashable, Sendable {
        fileprivate let rawValue: UInt64
    }

    enum Presentation: Equatable {
        case hidden
        /// The idle dot: a surface-free seed that sits near the focused text context while no
        /// session is running. Visually identical to `preparing`; never announced; yields to
        /// any real session, typing, scrolling, Space switches and Escape.
        case idle
        case preparing
        case recording
        case processing
        case success
        case failure
        case warning(String)
    }

    typealias AccessibilitySink = (String) -> Void

    private(set) var presentation: Presentation = .hidden
    private(set) var currentFrame: CGRect?

    private let screenProvider: () -> [DictationMiniPlacement.Screen]
    private let caretAnchorProvider: () -> CGPoint?
    private let caretClearanceProvider: () -> CGFloat
    private let pointerProvider: () -> CGPoint?
    private let accessibilitySink: AccessibilitySink
    private let caretPollingInterval: TimeInterval

    private var panel: NSPanel?
    private var contentView: DictationMiniView?
    private var generation: UInt64 = 0
    private var activeGeneration: Generation?
    private var anchorPoint: CGPoint?
    private var anchorScreen: DictationMiniPlacement.Screen?
    private var powerProvider: (() -> Float)?
    private var animationTimer: Timer?
    private var animationStartedAt: TimeInterval?
    private var disappearanceGeneration: UInt64 = 0
    private var idleHysteresis = DictationFollowerHysteresis()
    private var idleAnchor: CGPoint?
    private var idleActivity = DictationFollowerActivity()
    private var idleHiddenUntilFocusChange = false
    private var idleSnoozedUntil: TimeInterval?
    private var idleHasSelection = false
    private var idleSelectionHintElement: AXElementToken?
    private var idleWindowFrame: CGRect?
    private var idleProcessIdentifier: pid_t?
    private var idlePins: [pid_t: CGPoint] = [:]
    private var idleIsHovered = false
    private var pendingToast: (text: String, duration: TimeInterval)?
    private let hintPanel = DictationMiniHintPanel()
    private var dismissTask: Task<Void, Never>?
    private var caretPollingTimer: Timer?
    private var accessibilityObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    override convenience init() {
        self.init(
            screenProvider: {
                NSScreen.screens.map {
                    DictationMiniPlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame)
                }
            },
            caretAnchorProvider: { DictationCaretAnchorProvider.currentAnchor() },
            caretClearanceProvider: { DictationMiniPlacement.minimumCaretClearance },
            pointerProvider: { NSEvent.mouseLocation },
            accessibilitySink: { message in
                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: message,
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                    ]
                )
            }
        )
    }

    init(
        screenProvider: @escaping () -> [DictationMiniPlacement.Screen],
        caretAnchorProvider: @escaping () -> CGPoint?,
        caretClearanceProvider: @escaping () -> CGFloat = {
            DictationMiniPlacement.minimumCaretClearance
        },
        caretPollingInterval: TimeInterval = 0.1,
        pointerProvider: @escaping () -> CGPoint? = { nil },
        accessibilitySink: @escaping AccessibilitySink = { _ in }
    ) {
        self.screenProvider = screenProvider
        self.caretAnchorProvider = caretAnchorProvider
        self.caretClearanceProvider = caretClearanceProvider
        self.pointerProvider = pointerProvider
        self.caretPollingInterval = caretPollingInterval
        self.accessibilitySink = accessibilitySink
        super.init()

        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAccessibilityPresentation() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreensChanged() }
        }
    }

    @discardableResult
    func beginPreparing(at anchor: CGPoint? = nil) -> Generation {
        generation &+= 1
        let token = Generation(rawValue: generation)
        activeGeneration = token
        dismissTask?.cancel()
        dismissTask = nil
        stopAnimation(clearPowerProvider: true)
        anchorPoint = anchor ?? caretAnchorProvider()
        anchorScreen = nil
        present(.preparing, generation: token, followsCaret: true)
        return token
    }

    func showRecording(
        generation token: Generation,
        powerProvider: @escaping () -> Float
    ) {
        guard accepts(token) else { return }
        self.powerProvider = powerProvider
        present(.recording, generation: token, followsCaret: true)
        startAnimation()
    }

    func updatePowerProvider(
        generation token: Generation,
        powerProvider: @escaping () -> Float
    ) {
        guard accepts(token), presentation == .recording else { return }
        self.powerProvider = powerProvider
    }

    func showProcessing(generation token: Generation) {
        guard accepts(token) else { return }
        present(.processing, generation: token, followsCaret: false)
        startAnimation()
    }

    func showSuccess(generation token: Generation, duration: TimeInterval = 0.35) {
        showTerminal(.success, generation: token, duration: duration)
    }

    func showFailure(generation token: Generation, duration: TimeInterval = 1.2) {
        showTerminal(.failure, generation: token, duration: duration)
    }

    func showRecoveryWarningAfterFailure(
        _ message: String,
        failureDuration: TimeInterval = 1.2,
        warningDuration: TimeInterval = 3
    ) {
        guard presentation == .failure,
              let token = activeGeneration,
              accepts(token) else { return }
        let normalized = Self.normalizedWarning(message)
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(failureDuration, 0)))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.accepts(token), self.presentation == .failure else { return }
                self.present(.warning(normalized), generation: token, followsCaret: false)
            }
            try? await Task.sleep(for: .seconds(max(warningDuration, 0)))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.accepts(token), self.presentation == .warning(normalized) else { return }
                self.hide(invalidateGeneration: true)
            }
        }
    }

    @discardableResult
    func showWarning(
        _ message: String,
        at anchor: CGPoint? = nil,
        duration: TimeInterval = 3
    ) -> Generation? {
        guard presentation == .hidden || presentation == .idle || isWarning(presentation) else { return nil }
        generation &+= 1
        let token = Generation(rawValue: generation)
        activeGeneration = token
        dismissTask?.cancel()
        stopAnimation(clearPowerProvider: true)
        anchorPoint = anchor ?? caretAnchorProvider()
        anchorScreen = nil
        let normalized = Self.normalizedWarning(message)
        present(.warning(normalized), generation: token, followsCaret: false)
        scheduleDismissal(generation: token, duration: duration)
        return token
    }

    // MARK: Idle dot (text-context follower)

    enum IdleMenuAction: Equatable {
        case hideUntilFieldChanges
        case hideForHour
        case turnOff
        case openSettings
        case unpin
    }

    /// Supplies the dictation hotkey label for keycaps, hints and toasts.
    var hotkeyLabelProvider: () -> String = { "the hotkey" }
    var onIdleMenuAction: ((IdleMenuAction) -> Void)?

    /// Shows a short toast beside the Mini (e.g. hands-free engaged). If nothing is visible yet
    /// it waits for the next presentation that has a frame.
    func showToast(_ text: String, duration: TimeInterval = 2.2) {
        if let currentFrame, presentation != .hidden {
            hintPanel.show(text, beside: currentFrame, on: screenProvider().map(\.visibleFrame), duration: duration)
        } else {
            pendingToast = (text, duration)
        }
    }

    var hintTextForTesting: String? { hintPanel.text }
    var isIdlePinnedForTesting: Bool { idlePinOffset(for: idleProcessIdentifier) != nil }

    /// The frontmost app's focused window (AppKit coordinates), used for window pinning.
    func updateIdleWindowFrame(_ frame: CGRect?, processIdentifier: pid_t?) {
        idleWindowFrame = frame
        idleProcessIdentifier = processIdentifier
        if idlePinOffset(for: processIdentifier) != nil { refreshIdleDot() }
    }

    /// Whether the idle dot may show at all (setting, onboarding, no meeting recording).
    var isIdleDotAllowed = false {
        didSet { if oldValue != isIdleDotAllowed { refreshIdleDot() } }
    }

    /// Feeds one text-context observation (or a miss). Hysteresis holds the last caret for a
    /// few misses before the dot withdraws.
    func updateIdleContext(_ sample: DictationTextContextSample?) {
        idleHasSelection = sample?.hasSelection ?? false
        idleAnchor = idleHysteresis.observe(sample?.anchor)
        refreshIdleDot()
        // Selection hint: once per selection, while the dot is showing.
        if let sample, sample.hasSelection, presentation == .idle, idleSelectionHintElement != sample.element {
            idleSelectionHintElement = sample.element
            if let currentFrame {
                hintPanel.show(
                    "Hold \(hotkeyLabelProvider()) to replace the selection",
                    beside: currentFrame,
                    on: screenProvider().map(\.visibleFrame),
                    duration: 2.5
                )
            }
        } else if sample?.hasSelection != true {
            idleSelectionHintElement = nil
        }
    }

    func setIdleActivity(_ activity: DictationFollowerActivity) {
        idleActivity = activity
        refreshIdleDot()
    }

    /// Escape: hide the dot until the focused text element changes.
    func hideIdleDotUntilFocusChanges() {
        guard presentation == .idle else { return }
        idleHiddenUntilFocusChange = true
        refreshIdleDot()
    }

    /// The focused element changed; an Escape hide is over.
    func idleFocusDidChange() {
        guard idleHiddenUntilFocusChange else { return }
        idleHiddenUntilFocusChange = false
        refreshIdleDot()
    }

    func snoozeIdleDot(for duration: TimeInterval) {
        idleSnoozedUntil = ProcessInfo.processInfo.systemUptime + max(duration, 0)
        refreshIdleDot()
    }

    var isIdleDotVisibleForTesting: Bool { presentation == .idle && (panel?.isVisible ?? false) }
    var idleHasSelectionForTesting: Bool { idleHasSelection }

    private var lastIdleDiagnosticAt: TimeInterval = 0

    private func refreshIdleDot() {
        guard presentation == .hidden || presentation == .idle else { return }
        let snoozed = idleSnoozedUntil.map { ProcessInfo.processInfo.systemUptime < $0 } ?? false
        let pinnedFrame = pinnedIdleFrame()
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastIdleDiagnosticAt > 10 {
            lastIdleDiagnosticAt = now
            Self.idleLogger.notice("idle allowed=\(self.isIdleDotAllowed, privacy: .public) anchor=\(self.idleAnchor != nil, privacy: .public) suppress=\(self.idleActivity.isSuppressing, privacy: .public) escape=\(self.idleHiddenUntilFocusChange, privacy: .public) snoozed=\(snoozed, privacy: .public) presentation=\(String(describing: self.presentation), privacy: .public)")
        }
        let canShow = isIdleDotAllowed
            && !idleActivity.isSuppressing
            && !idleHiddenUntilFocusChange
            && !snoozed
            && (idleAnchor != nil || pinnedFrame != nil)
        guard canShow, let anchor = idleAnchor ?? pinnedFrame.map({ CGPoint(x: $0.midX, y: $0.midY) }) else {
            if presentation == .idle { hide(invalidateGeneration: true) }
            return
        }
        if presentation == .idle {
            if let pinnedFrame {
                moveIdleDot(toFrame: pinnedFrame)
            } else {
                moveIdleDot(to: anchor)
            }
            return
        }
        generation &+= 1
        let token = Generation(rawValue: generation)
        activeGeneration = token
        dismissTask?.cancel()
        dismissTask = nil
        stopAnimation(clearPowerProvider: true)
        anchorPoint = anchor
        anchorScreen = nil
        currentFrame = pinnedFrame
        present(.idle, generation: token, followsCaret: false)
    }

    /// Frame for a dot pinned to the frontmost app's focused window, if pinned and known.
    private func pinnedIdleFrame() -> CGRect? {
        guard let offset = idlePinOffset(for: idleProcessIdentifier), let window = idleWindowFrame else { return nil }
        let size = Self.surfaceSize(for: .idle)
        let raw = CGRect(x: window.minX + offset.x, y: window.maxY + offset.y, width: size.width, height: size.height)
        return DictationMiniPlacement.rehomeFrozenFrame(raw, screens: screenProvider()) ?? raw
    }

    private func idlePinOffset(for pid: pid_t?) -> CGPoint? {
        guard let pid else { return nil }
        return idlePins[pid]
    }

    private func moveIdleDot(toFrame frame: CGRect) {
        guard currentFrame != frame else { return }
        currentFrame = frame
        anchorPoint = CGPoint(x: frame.midX, y: frame.midY)
        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
    }

    private func moveIdleDot(to anchor: CGPoint) {
        let screens = screenProvider()
        guard let placement = DictationMiniPlacement.place(
            near: anchor,
            size: Self.surfaceSize(for: .idle),
            screens: screens,
            clearance: caretClearanceProvider()
        ) else { return }
        if let previous = anchorPoint,
           let previousScreen = anchorScreen,
           !DictationMiniPlacement.shouldReacquire(
               from: previous,
               on: previousScreen,
               to: anchor,
               on: placement.screen
           ) {
            return
        }
        anchorPoint = anchor
        anchorScreen = placement.screen
        currentFrame = placement.frame
        if let panel, let currentFrame {
            // Glide rather than jump so the dot reads as following the caret.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(currentFrame, display: true)
            }
            panel.orderFrontRegardless()
            if hintPanel.isVisible { hintPanel.move(beside: currentFrame, on: screens.map(\.visibleFrame)) }
        }
    }

    // MARK: Idle interaction (hover keycaps, click menu, drag to pin)

    func idleHoverChanged(_ hovered: Bool) {
        guard presentation == .idle else { return }
        idleIsHovered = hovered
        if hovered, let currentFrame {
            hintPanel.show(
                "Hold \(hotkeyLabelProvider()) to dictate",
                beside: currentFrame,
                on: screenProvider().map(\.visibleFrame),
                duration: nil
            )
        } else if hintPanel.text?.hasSuffix("to dictate") == true {
            hintPanel.hide()
        }
    }

    func idleClicked() {
        guard presentation == .idle, let panel else { return }
        let menu = NSMenu()
        let pinned = idlePinOffset(for: idleProcessIdentifier) != nil
        func item(_ title: String, _ action: IdleMenuAction) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(handleIdleMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = IdleMenuBox(action: action)
            return item
        }
        menu.addItem(item("Hide until I switch fields", .hideUntilFieldChanges))
        menu.addItem(item("Hide for an hour", .hideForHour))
        if pinned { menu.addItem(item("Unpin from window", .unpin)) }
        menu.addItem(.separator())
        menu.addItem(item("Turn off idle dot", .turnOff))
        menu.addItem(item("Open Settings…", .openSettings))
        let location = NSPoint(x: panel.frame.width / 2, y: 0)
        menu.popUp(positioning: nil, at: location, in: contentView)
    }

    @objc private func handleIdleMenuItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? IdleMenuBox else { return }
        switch box.action {
        case .hideUntilFieldChanges: hideIdleDotUntilFocusChanges()
        case .hideForHour: snoozeIdleDot(for: 3600)
        case .unpin:
            if let pid = idleProcessIdentifier { idlePins[pid] = nil }
            refreshIdleDot()
        case .turnOff, .openSettings: break
        }
        onIdleMenuAction?(box.action)
    }

    func idleDragged(to origin: CGPoint) {
        guard presentation == .idle, let panel else { return }
        let size = panel.frame.size
        let frame = DictationMiniPlacement.rehomeFrozenFrame(CGRect(origin: origin, size: size), screens: screenProvider())
            ?? CGRect(origin: origin, size: size)
        currentFrame = frame
        panel.setFrame(frame, display: true)
        hintPanel.hide()
    }

    /// Dropping the dot pins it to the frontmost app's focused window as an offset from the
    /// window's top-left; it then rides with that window until unpinned.
    func idleDragEnded() {
        guard presentation == .idle, let currentFrame else { return }
        guard let pid = idleProcessIdentifier, let window = idleWindowFrame else { return }
        idlePins[pid] = CGPoint(x: currentFrame.minX - window.minX, y: currentFrame.minY - window.maxY)
        refreshIdleDot()
    }

    /// Neutral completion/cancellation. A terminal hold owns its own dismissal.
    func dismiss(generation token: Generation) {
        guard accepts(token), !isTerminal(presentation) else { return }
        hide(invalidateGeneration: true)
    }

    func close() {
        hide(invalidateGeneration: true)
        hintPanel.close()
        panel?.close()
        panel = nil
        contentView = nil
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    var isVisibleForTesting: Bool { panel?.isVisible ?? false }
    var isMouseTransparentForTesting: Bool { panel?.ignoresMouseEvents ?? true }
    var isFollowingCaretForTesting: Bool { caretPollingTimer != nil }
    func refreshCaretAnchorForTesting() { reacquireCaretIfNeeded() }
    static func processingAnimationIsContinuous(reduceMotion: Bool) -> Bool { !reduceMotion }

    /// Preparing, processing, success, and failure share one footprint so the session never
    /// appears to jump between states; they are centred on the same anchor.
    static let signalWindowSide: CGFloat = 20

    static func surfaceSize(for presentation: Presentation) -> CGSize {
        switch presentation {
        case .hidden: return .zero
        case .idle, .preparing, .processing, .success, .failure:
            return CGSize(width: Self.signalWindowSide, height: Self.signalWindowSide)
        case .recording: return CGSize(width: 58, height: 22)
        case .warning(let text):
            return CGSize(width: min(max(CGFloat(text.count) * 6.4 + 34, 96), 320), height: 26)
        }
    }

    static func usesCompositorShadow(_ presentation: Presentation) -> Bool {
        switch presentation {
        case .recording, .processing, .failure, .warning: return true
        case .hidden, .idle, .preparing, .success: return false
        }
    }

    static func accessibilityLabel(for presentation: Presentation) -> String? {
        switch presentation {
        case .hidden: return nil
        case .idle: return "Dictation ready"
        case .preparing: return "Preparing dictation"
        case .recording: return "Recording dictation"
        case .processing: return "Generating transcription"
        case .success: return "Dictation complete"
        case .failure: return "Dictation failed"
        case .warning(let message): return "Dictation warning: \(message)"
        }
    }

    private func showTerminal(
        _ terminal: Presentation,
        generation token: Generation,
        duration: TimeInterval
    ) {
        guard accepts(token) else { return }
        // Terminal states hold the session anchor: the user looks where Preparing appeared,
        // not at wherever the caret landed after insertion.
        present(terminal, generation: token, followsCaret: false)
        scheduleDismissal(generation: token, duration: duration)
    }

    private func present(
        _ newPresentation: Presentation,
        generation token: Generation,
        followsCaret: Bool
    ) {
        guard accepts(token) else { return }
        let oldPresentation = presentation
        presentation = newPresentation
        if followsCaret {
            startCaretMonitoring()
            placeFollowingSurface(size: Self.surfaceSize(for: newPresentation))
        } else {
            stopCaretMonitoring()
            placeFrozenSurface(size: Self.surfaceSize(for: newPresentation))
        }

        let panel = ensurePanel(size: Self.surfaceSize(for: newPresentation))
        // Only the idle dot is interactive (hover keycaps, click menu, drag to pin).
        panel.ignoresMouseEvents = newPresentation != .idle
        panel.level = .statusBar
        // Small bright signals get no compositor shadow: on a light page it reads as a dark
        // ring around the seed or the completion disk.
        let wantsShadow = Self.usesCompositorShadow(newPresentation)
        if panel.hasShadow != wantsShadow {
            panel.hasShadow = wantsShadow
            panel.invalidateShadow()
        }
        contentView?.presentation = newPresentation
        contentView?.animationPhase = 0
        contentView?.updateAccessibilityLabel(Self.accessibilityLabel(for: newPresentation))
        contentView?.needsDisplay = true
        disappearanceGeneration &+= 1
        contentView?.cancelDisappearance()
        if let currentFrame {
            panel.setFrame(currentFrame, display: true)
            if oldPresentation != newPresentation {
                contentView?.playAppearance(
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        || newPresentation == .idle
                )
            }
            panel.orderFrontRegardless()
            if let pendingToast {
                self.pendingToast = nil
                hintPanel.show(pendingToast.text, beside: currentFrame, on: screenProvider().map(\.visibleFrame), duration: pendingToast.duration)
            } else if hintPanel.isVisible {
                hintPanel.move(beside: currentFrame, on: screenProvider().map(\.visibleFrame))
            }
        } else {
            panel.orderOut(nil)
        }
        if oldPresentation == .idle, newPresentation != .idle {
            idleIsHovered = false
            if hintPanel.text?.hasPrefix("Hold ") == true { hintPanel.hide() }
        }

        if oldPresentation != newPresentation,
           let announcement = Self.accessibilityAnnouncement(for: newPresentation) {
            accessibilitySink(announcement)
        }
    }

    /// Active states are never left without a home: caret → pointer → screen bottom.
    /// The idle dot uses only real text context and never reaches this ladder.
    private func activeFallbackAnchor() -> CGPoint? {
        if let pointer = pointerProvider() { return pointer }
        guard let screen = screenProvider().first else { return nil }
        return CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.minY + Self.bottomFallbackInset)
    }

    static let bottomFallbackInset: CGFloat = 36

    private func placeFollowingSurface(size: CGSize) {
        guard let anchor = anchorPoint ?? caretAnchorProvider() ?? activeFallbackAnchor() else { return }
        let screens = screenProvider()
        guard let result = DictationMiniPlacement.place(
            near: anchor,
            size: size,
            screens: screens,
            clearance: caretClearanceProvider()
        ) else { return }
        anchorPoint = anchor
        anchorScreen = result.screen
        currentFrame = result.frame
    }

    private func placeFrozenSurface(size: CGSize) {
        if presentation == .idle, let pinned = pinnedIdleFrame() {
            currentFrame = pinned
            return
        }
        // Hold the session anchor, not the previous frame: a 20 pt signal placed against the
        // same caret anchor lands exactly where Preparing appeared, whatever size Recording was.
        if let anchor = anchorPoint,
           let result = DictationMiniPlacement.place(
               near: anchor,
               size: size,
               screens: screenProvider(),
               clearance: caretClearanceProvider()
           ) {
            anchorScreen = result.screen
            currentFrame = result.frame
            return
        }
        if let currentFrame {
            let resized = CGRect(
                x: currentFrame.midX - size.width / 2,
                y: currentFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            self.currentFrame = DictationMiniPlacement.rehomeFrozenFrame(resized, screens: screenProvider())
                ?? resized
            return
        }
        placeFollowingSurface(size: size)
    }

    private func ensurePanel(size: CGSize) -> NSPanel {
        if let panel, let contentView {
            contentView.frame = CGRect(origin: .zero, size: size)
            return panel
        }
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = DictationMiniView(frame: CGRect(origin: .zero, size: size))
        view.owner = self
        panel.contentView = view
        self.panel = panel
        contentView = view
        return panel
    }

    private func startCaretMonitoring() {
        guard caretPollingTimer == nil else { return }
        let timer = Timer(timeInterval: max(caretPollingInterval, 0.04), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reacquireCaretIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        caretPollingTimer = timer
    }

    private func stopCaretMonitoring() {
        caretPollingTimer?.invalidate()
        caretPollingTimer = nil
    }

    private func reacquireCaretIfNeeded() {
        guard presentation == .preparing || presentation == .recording,
              let anchor = caretAnchorProvider() else { return }
        let screens = screenProvider()
        guard let placement = DictationMiniPlacement.place(
            near: anchor,
            size: Self.surfaceSize(for: presentation),
            screens: screens,
            clearance: caretClearanceProvider()
        ) else { return }
        if let previousAnchor = anchorPoint,
           let previousScreen = anchorScreen,
           !DictationMiniPlacement.shouldReacquire(
               from: previousAnchor,
               on: previousScreen,
               to: anchor,
               on: placement.screen
           ) {
            return
        }
        anchorPoint = anchor
        anchorScreen = placement.screen
        currentFrame = placement.frame
        if let currentFrame {
            panel?.setFrame(currentFrame, display: true)
            panel?.orderFrontRegardless()
        }
    }

    private func handleScreensChanged() {
        switch presentation {
        case .preparing, .recording:
            anchorPoint = caretAnchorProvider() ?? anchorPoint
            placeFollowingSurface(size: Self.surfaceSize(for: presentation))
        case .idle, .processing, .success, .failure, .warning:
            guard let currentFrame else { return }
            self.currentFrame = DictationMiniPlacement.rehomeFrozenFrame(currentFrame, screens: screenProvider())
        case .hidden:
            return
        }
        if let currentFrame { panel?.setFrame(currentFrame, display: true) }
    }

    private func startAnimation() {
        animationTimer?.invalidate()
        guard presentation == .recording
                || (presentation == .processing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        else {
            animationStartedAt = nil
            contentView?.needsDisplay = true
            return
        }
        animationStartedAt = ProcessInfo.processInfo.systemUptime
        if presentation == .recording { contentView?.resetRecordingWave() }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advanceAnimation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func advanceAnimation() {
        guard presentation == .recording || presentation == .processing else {
            stopAnimation(clearPowerProvider: false)
            return
        }
        if presentation == .recording {
            let decibels = powerProvider?() ?? -160
            let target = DictationMiniRendering.recordingLevel(decibels: CGFloat(decibels))
            let current = contentView?.power ?? 0
            let level = DictationMiniRendering.recordingEnvelope(current: current, target: target)
            contentView?.power = level
            contentView?.advanceRecordingWave(level: level)
        } else {
            let elapsed = ProcessInfo.processInfo.systemUptime - (animationStartedAt ?? 0)
            contentView?.animationPhase = CGFloat(elapsed * 3.2).truncatingRemainder(dividingBy: .pi * 2)
        }
        contentView?.needsDisplay = true
    }

    private func stopAnimation(clearPowerProvider: Bool) {
        animationTimer?.invalidate()
        animationTimer = nil
        animationStartedAt = nil
        contentView?.power = 0
        if clearPowerProvider { powerProvider = nil }
    }

    private func scheduleDismissal(generation token: Generation, duration: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(duration, 0)))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.accepts(token) else { return }
                self.hide(invalidateGeneration: true)
            }
        }
    }

    private func hide(invalidateGeneration: Bool) {
        if invalidateGeneration { generation &+= 1 }
        activeGeneration = nil
        dismissTask?.cancel()
        dismissTask = nil
        stopCaretMonitoring()
        stopAnimation(clearPowerProvider: true)
        presentation = .hidden
        anchorPoint = nil
        anchorScreen = nil
        currentFrame = nil
        contentView?.updateAccessibilityLabel(nil)
        idleIsHovered = false
        hintPanel.hide()
        orderOutPanel()
    }

    /// Fades the visible signal out before ordering the panel out; a newer presentation
    /// cancels the fade and keeps the panel.
    private func orderOutPanel() {
        guard let panel, let contentView, panel.isVisible else {
            contentView?.presentation = .hidden
            panel?.orderOut(nil)
            return
        }
        disappearanceGeneration &+= 1
        let generation = disappearanceGeneration
        contentView.playDisappearance { [weak self] in
            guard let self, self.disappearanceGeneration == generation, self.presentation == .hidden else { return }
            self.contentView?.presentation = .hidden
            self.panel?.orderOut(nil)
        }
    }

    private func refreshAccessibilityPresentation() {
        contentView?.refreshAccessibilityPresentation()
        if presentation == .processing { startAnimation() }
    }

    private func accepts(_ token: Generation) -> Bool {
        activeGeneration == token && token.rawValue == generation
    }

    private func isTerminal(_ presentation: Presentation) -> Bool {
        presentation == .success || presentation == .failure
    }

    private func isWarning(_ presentation: Presentation) -> Bool {
        if case .warning = presentation { return true }
        return false
    }

    private static func normalizedWarning(_ message: String) -> String {
        let normalized = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? "Dictation unavailable" : normalized
    }

    private static func accessibilityAnnouncement(for presentation: Presentation) -> String? {
        switch presentation {
        case .hidden, .idle, .preparing:
            return nil
        case .warning(let message):
            return message
        case .recording, .processing, .success, .failure:
            return accessibilityLabel(for: presentation)
        }
    }
}

private final class IdleMenuBox: NSObject {
    let action: DictationMiniIndicatorController.IdleMenuAction
    init(action: DictationMiniIndicatorController.IdleMenuAction) { self.action = action }
}

enum DictationMiniPalette {
    static let glassTintHex = 0x211F1E
    static let surfaceTopHex = 0x32312F
    static let surfaceBottomHex = 0x181817
    static let orbTopHex = 0x272725
    static let orbBottomHex = 0x0E0E0D
    static let accentHex = 0xFF7043
    static let accentHighlightHex = 0xFFB04D
    /// Vivid completion green; rendered as a tinted glass disk, not a solid fill.
    static let successHex = 0x48E57B
    static let successHighlightHex = 0xB6FFCF
    static let failureHex = 0xFF6961
    static let inkHex = 0xF3F2EF
}

enum DictationMiniRendering {
    static let glassTintAlpha: CGFloat = 0.44
    /// Recording sits on a lower, darker ground so the fine one-point bars stay legible.
    static let recordingGlassTintAlpha: CGFloat = 0.62
    static let recordingBarCount = 24
    static let recordingBarWidth: CGFloat = 1
    static let recordingBarPitch: CGFloat = 2
    static let recordingBarMinHeight: CGFloat = 1
    static let recordingBarMaxHeight: CGFloat = 12
    static let recordingQuietAlpha: CGFloat = 0.48
    /// Processing point field inside the 20 pt orb: five columns span 11.2 pt plus dot radii.
    static let processingPointSpacing: CGFloat = 2.8
    static let processingPointMaxDiameter: CGFloat = 2.3
    static let processingPointMinDiameter: CGFloat = 1.7
    static let preparingDotDiameter: CGFloat = 10
    /// Completion fills the shared 20 pt window as a glass disk.
    static let completionDiameter: CGFloat = 20
    static let successGlassTintAlpha: CGFloat = 0.82
    static let successCheckLineWidth: CGFloat = 1.8
    static let appearanceFadeDuration: TimeInterval = 0.14
    static let appearancePopDuration: TimeInterval = 0.26
    static let disappearanceFadeDuration: TimeInterval = 0.14

    /// Maps `AVAudioRecorder` average power to a 0...1 bar level. The floor matches the
    /// recorder's −58 dB speech threshold so anything Muesli treats as speech lifts off the
    /// baseline dot; conversational speech fills the capsule without pinning at the ceiling.
    static func recordingLevel(decibels: CGFloat) -> CGFloat {
        let floor: CGFloat = -58
        let ceiling: CGFloat = -18
        let linear = max(0, min(1, (decibels - floor) / (ceiling - floor)))
        return pow(linear, 0.7)
    }

    /// Fast attack, slower release so syllables register immediately and decay smoothly.
    static func recordingEnvelope(current: CGFloat, target: CGFloat) -> CGFloat {
        let weight: CGFloat = target > current ? 0.62 : 0.26
        return current + (target - current) * weight
    }

    /// Reduce Motion replaces the scrolling history with a calm, centred envelope.
    static func recordingStaticEnvelope(index: Int, count: Int) -> CGFloat {
        guard count > 1 else { return 1 }
        let midpoint = CGFloat(count - 1) / 2
        let distance = abs(CGFloat(index) - midpoint) / midpoint
        return 0.35 + 0.65 * (1 - distance * distance)
    }

    static func pixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded() / scale
    }
}

/// Deterministic pseudo-random source so the wave is reproducible for a given seed.
struct DictationMiniSplitMix64: Equatable {
    private(set) var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func nextUnit() -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(1 << 53)
    }
}

/// The recording wave: a field of bars lit by short-lived sparks. Each frame the live level
/// spawns sparks at seeded positions; sparks spread to their neighbours, carry over with decay,
/// and the bars ease toward the lit shape. Silence leaves a faint, slowly shimmering baseline.
struct DictationMiniSpikeEngine: Equatable {
    struct Spark: Equatable {
        var index: Int
        var amplitude: CGFloat
    }

    static let carry: CGFloat = 0.84
    static let sparksPerFrameAtFullLevel: CGFloat = 2.2
    static let kernel: [CGFloat] = [0.32, 0.68, 1, 0.68, 0.32]
    static let quietThreshold: CGFloat = 0.05
    static let quietShimmer: CGFloat = 0.06
    static let attack: CGFloat = 0.6
    static let release: CGFloat = 0.28

    private(set) var bars: [CGFloat]
    private(set) var sparks: [Spark] = []
    private(set) var isQuiet = true
    private var rng: DictationMiniSplitMix64
    private var shimmerPhase: CGFloat = 0

    init(count: Int = DictationMiniRendering.recordingBarCount, seed: UInt64 = 0x4D75_6573_6C69) {
        bars = Array(repeating: 0, count: max(count, 1))
        rng = DictationMiniSplitMix64(seed: seed)
    }

    var count: Int { bars.count }

    mutating func reset() {
        bars = Array(repeating: 0, count: bars.count)
        sparks.removeAll()
        isQuiet = true
        shimmerPhase = 0
    }

    mutating func advance(level rawLevel: CGFloat) {
        let level = max(0, min(1, rawLevel))
        isQuiet = level < Self.quietThreshold

        // Carry: existing sparks fade and the dimmest die.
        for index in sparks.indices {
            sparks[index].amplitude *= Self.carry
        }
        sparks.removeAll { $0.amplitude < 0.02 }

        // Spawn: the louder the voice, the more sparks per frame.
        var budget = level * Self.sparksPerFrameAtFullLevel
        while budget > 0 {
            if rng.nextUnit() < min(budget, 1) {
                let amplitude = level * (0.55 + 0.45 * rng.nextUnit())
                let index = Int(rng.nextUnit() * CGFloat(bars.count)) % bars.count
                sparks.append(Spark(index: index, amplitude: amplitude))
            }
            budget -= 1
        }
        if sparks.count > 48 { sparks.removeFirst(sparks.count - 48) }

        // Compose: baseline shimmer plus the spark kernels.
        shimmerPhase += 0.11
        var target = [CGFloat](repeating: 0, count: bars.count)
        let midpoint = CGFloat(bars.count - 1) / 2
        for index in target.indices {
            let distance = abs(CGFloat(index) - midpoint) / max(midpoint, 1)
            let shimmer = 0.5 + 0.5 * sin(shimmerPhase + CGFloat(index) * 0.9)
            target[index] = Self.quietShimmer * (1 - distance * 0.6) * (0.6 + 0.4 * shimmer)
        }
        for spark in sparks {
            for offset in -2...2 {
                let index = spark.index + offset
                guard bars.indices.contains(index) else { continue }
                target[index] += spark.amplitude * Self.kernel[offset + 2]
            }
        }

        // Ease: fast attack, slower release.
        for index in bars.indices {
            let goal = min(1, target[index])
            let weight = goal > bars[index] ? Self.attack : Self.release
            bars[index] += (goal - bars[index]) * weight
        }
    }
}

private final class DictationMiniView: NSView {
    weak var owner: DictationMiniIndicatorController?
    private var trackingAreaRef: NSTrackingArea?
    private var mouseDownScreenLocation: NSPoint?
    private var mouseDownWindowOrigin: NSPoint?
    private var didDrag = false
    private let glassView = NSVisualEffectView()
    private let tintView = NSView()
    private let waveformView = DictationMiniWaveformView()
    private let pointFieldView = DictationMiniPointFieldView()
    private let cueView = DictationMiniCueView()
    private let artworkView = DictationMiniArtworkView()

    var presentation: DictationMiniIndicatorController.Presentation = .hidden {
        didSet {
            artworkView.presentation = presentation
            cueView.presentation = presentation
            waveformView.isHidden = presentation != .recording
            pointFieldView.isHidden = presentation != .processing
            updateSurface()
        }
    }
    var power: CGFloat {
        get { waveformView.power }
        set { waveformView.power = newValue }
    }
    func advanceRecordingWave(level: CGFloat) { waveformView.advance(level: level) }
    func resetRecordingWave() { waveformView.reset() }
    var animationPhase: CGFloat {
        get { pointFieldView.phase }
        set { pointFieldView.phase = newValue }
    }

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        glassView.material = .hudWindow
        glassView.blendingMode = .behindWindow
        glassView.state = .active
        glassView.appearance = NSAppearance(named: .darkAqua)
        glassView.wantsLayer = true
        glassView.autoresizingMask = [.width, .height]
        tintView.wantsLayer = true
        artworkView.wantsLayer = true
        addSubview(glassView)
        addSubview(tintView)
        addSubview(waveformView)
        addSubview(pointFieldView)
        addSubview(cueView)
        addSubview(artworkView)
        waveformView.isHidden = true
        pointFieldView.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func updateAccessibilityLabel(_ label: String?) {
        setAccessibilityLabel(label)
    }

    func refreshAccessibilityPresentation() {
        updateSurface()
        waveformView.refreshAccessibilityPresentation()
        pointFieldView.refreshAccessibilityPresentation()
        cueView.refreshAccessibilityPresentation()
        artworkView.needsDisplay = true
    }

    override func layout() {
        super.layout()
        glassView.frame = bounds
        tintView.frame = bounds
        waveformView.frame = bounds
        pointFieldView.frame = bounds
        cueView.frame = bounds
        artworkView.frame = bounds
        updateSurface()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { owner?.idleHoverChanged(true) }
    override func mouseExited(with event: NSEvent) { owner?.idleHoverChanged(false) }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        mouseDownScreenLocation = NSEvent.mouseLocation
        mouseDownWindowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownScreenLocation, let origin = mouseDownWindowOrigin else { return }
        let current = NSEvent.mouseLocation
        guard didDrag || hypot(current.x - start.x, current.y - start.y) >= 5 else { return }
        didDrag = true
        owner?.idleDragged(to: CGPoint(x: origin.x + current.x - start.x, y: origin.y + current.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownScreenLocation = nil; mouseDownWindowOrigin = nil; didDrag = false }
        if didDrag { owner?.idleDragEnded() } else { owner?.idleClicked() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        glassView.layer?.contentsScale = scale
        tintView.layer?.contentsScale = scale
        waveformView.updateBackingScale(scale)
        pointFieldView.updateBackingScale(scale)
        cueView.updateBackingScale(scale)
        artworkView.layer?.contentsScale = scale
    }

    override var needsDisplay: Bool {
        get { artworkView.needsDisplay }
        set { artworkView.needsDisplay = newValue }
    }

    /// A brief pop: fade in with a slight overshoot scale about the signal's centre.
    /// Reduce Motion keeps the fade and drops the scale.
    func playAppearance(reduceMotion: Bool) {
        guard let layer else { return }
        layer.removeAnimation(forKey: "disappear")
        layer.removeAnimation(forKey: "appear")
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = DictationMiniRendering.appearanceFadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        var animations: [CAAnimation] = [fade]
        if !reduceMotion {
            let pop = CAKeyframeAnimation(keyPath: "transform")
            pop.values = [0.55, 1.06, 1].map { NSValue(caTransform3D: centredScale($0)) }
            pop.keyTimes = [0, 0.7, 1]
            pop.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            pop.duration = DictationMiniRendering.appearancePopDuration
            animations.append(pop)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = DictationMiniRendering.appearancePopDuration
        layer.add(group, forKey: "appear")
    }

    func playDisappearance(completion: @escaping () -> Void) {
        guard let layer else { completion(); return }
        layer.removeAnimation(forKey: "appear")
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = DictationMiniRendering.disappearanceFadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "disappear")
        CATransaction.commit()
    }

    func cancelDisappearance() {
        layer?.removeAnimation(forKey: "disappear")
        layer?.opacity = 1
    }

    private func centredScale(_ scale: CGFloat) -> CATransform3D {
        let toOrigin = CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0)
        let back = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        return CATransform3DConcat(CATransform3DConcat(toOrigin, CATransform3DMakeScale(scale, scale, 1)), back)
    }

    private func updateSurface() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let usesSurface: Bool
        switch presentation {
        case .recording, .processing, .failure, .warning, .success:
            usesSurface = true
        case .hidden, .idle, .preparing:
            usesSurface = false
        }
        glassView.isHidden = !usesSurface || reduceTransparency
        tintView.isHidden = !usesSurface
        // Completion sits on a light material so the green reads bright on any page; every
        // other surface keeps the dark HUD material.
        let successMaterial = presentation == .success
        glassView.material = successMaterial ? .popover : .hudWindow
        glassView.appearance = NSAppearance(named: successMaterial ? .aqua : .darkAqua)
        let radius: CGFloat
        switch presentation {
        case .processing, .failure, .success:
            radius = bounds.height / 2
        default:
            radius = min(bounds.height / 2, 11)
        }
        layer?.masksToBounds = usesSurface
        layer?.cornerRadius = radius
        let isSuccess = presentation == .success
        layer?.borderWidth = usesSurface && !isSuccess
            ? (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 1)
            : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.82 : 0.16
        ).cgColor
        glassView.layer?.cornerRadius = radius
        glassView.layer?.cornerCurve = .continuous
        glassView.layer?.masksToBounds = true
        tintView.layer?.cornerRadius = radius
        tintView.layer?.cornerCurve = .continuous
        let tintAlpha = presentation == .recording
            ? DictationMiniRendering.recordingGlassTintAlpha
            : DictationMiniRendering.glassTintAlpha
        if isSuccess {
            tintView.layer?.backgroundColor = NSColor.colorWith(
                hex: DictationMiniPalette.successHex,
                alpha: reduceTransparency ? 1 : DictationMiniRendering.successGlassTintAlpha
            ).cgColor
        } else {
            tintView.layer?.backgroundColor = NSColor.colorWith(
                hex: DictationMiniPalette.glassTintHex,
                alpha: reduceTransparency ? 1 : tintAlpha
            ).cgColor
        }
    }
}

private final class DictationMiniCueView: NSView {
    private let diskLayer = CAShapeLayer()
    private let glossLayer = CAGradientLayer()
    private let glossMask = CAShapeLayer()
    private let checkLayer = CAShapeLayer()
    private var backingScale: CGFloat = 2

    var presentation: DictationMiniIndicatorController.Presentation = .hidden {
        didSet { updateCue() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        diskLayer.shadowOffset = .zero
        // Glass gel: a light catch on the upper half and a faint shade at the base.
        glossLayer.colors = [
            NSColor.white.withAlphaComponent(0.34).cgColor,
            NSColor.white.withAlphaComponent(0.06).cgColor,
            NSColor.black.withAlphaComponent(0.10).cgColor,
        ]
        glossLayer.locations = [0, 0.55, 1]
        glossLayer.startPoint = CGPoint(x: 0.5, y: 1)
        glossLayer.endPoint = CGPoint(x: 0.5, y: 0)
        glossLayer.mask = glossMask
        checkLayer.fillColor = nil
        checkLayer.lineCap = .round
        checkLayer.lineJoin = .round
        layer?.addSublayer(diskLayer)
        layer?.addSublayer(glossLayer)
        layer?.addSublayer(checkLayer)
        updateCue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateCue()
    }

    func updateBackingScale(_ scale: CGFloat) {
        backingScale = max(scale, 1)
        diskLayer.contentsScale = backingScale
        glossLayer.contentsScale = backingScale
        glossMask.contentsScale = backingScale
        checkLayer.contentsScale = backingScale
        updateCue()
    }

    func refreshAccessibilityPresentation() {
        updateCue()
    }

    private func updateCue() {
        let diameter: CGFloat
        let fillColor: NSColor
        switch presentation {
        case .preparing, .idle:
            diameter = DictationMiniRendering.preparingDotDiameter
            fillColor = NSColor.colorWith(hex: DictationMiniPalette.accentHex, alpha: 1)
        case .success:
            diameter = DictationMiniRendering.completionDiameter
            fillColor = NSColor.colorWith(hex: DictationMiniPalette.successHex, alpha: 1)
        default:
            isHidden = true
            return
        }

        isHidden = false
        let origin = CGPoint(
            x: DictationMiniRendering.pixelAligned(bounds.midX - diameter / 2, scale: backingScale),
            y: DictationMiniRendering.pixelAligned(bounds.midY - diameter / 2, scale: backingScale)
        )
        let diskRect = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if presentation == .success {
            // The green comes from the tinted glass surface underneath; here we only add the
            // gloss and a small white check. No solid disk, no glow, no edge.
            diskLayer.isHidden = true
            glossMask.path = CGPath(ellipseIn: CGRect(origin: .zero, size: diskRect.size), transform: nil)
            glossLayer.frame = diskRect
            glossLayer.isHidden = false
            let unit = diameter / 20
            let check = CGMutablePath()
            check.move(to: CGPoint(x: diskRect.minX + 6.3 * unit, y: diskRect.midY + 0.1 * unit))
            check.addLine(to: CGPoint(x: diskRect.minX + 9.0 * unit, y: diskRect.minY + 7.3 * unit))
            check.addLine(to: CGPoint(x: diskRect.minX + 14.0 * unit, y: diskRect.minY + 12.5 * unit))
            checkLayer.path = check
            checkLayer.strokeColor = NSColor.white.withAlphaComponent(0.97).cgColor
            checkLayer.lineWidth = DictationMiniRendering.successCheckLineWidth * unit
            checkLayer.isHidden = false
        } else {
            diskLayer.isHidden = false
            glossLayer.isHidden = true
            checkLayer.isHidden = true
            diskLayer.path = CGPath(ellipseIn: diskRect, transform: nil)
            diskLayer.fillColor = fillColor.cgColor
            diskLayer.shadowColor = fillColor.withAlphaComponent(0.52).cgColor
            diskLayer.shadowOpacity = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.3 : 1
            diskLayer.shadowRadius = 4
        }
        CATransaction.commit()
    }
}

private final class DictationMiniWaveformView: NSView {
    private var bars: [CALayer] = []
    private let haloLayer = CAGradientLayer()
    private var engine = DictationMiniSpikeEngine()
    private var backingScale: CGFloat = 2
    /// Smoothed live level: drives the halo.
    var power: CGFloat = 0 { didSet { updateBars() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let accent = NSColor.colorWith(hex: DictationMiniPalette.accentHex, alpha: 1)
        haloLayer.type = .radial
        haloLayer.colors = [
            accent.withAlphaComponent(0.30).cgColor,
            accent.withAlphaComponent(0.10).cgColor,
            accent.withAlphaComponent(0).cgColor,
        ]
        haloLayer.locations = [0, 0.45, 1]
        haloLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        haloLayer.endPoint = CGPoint(x: 1, y: 1)
        haloLayer.opacity = 0
        layer?.addSublayer(haloLayer)
        for _ in 0..<DictationMiniRendering.recordingBarCount {
            let bar = CALayer()
            bar.cornerRadius = DictationMiniRendering.recordingBarWidth / 2
            bar.allowsEdgeAntialiasing = true
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        applyBarColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func advance(level: CGFloat) {
        engine.advance(level: level)
        updateBars()
    }

    func reset() {
        engine.reset()
        power = 0
    }

    override func layout() {
        super.layout()
        updateBars()
    }

    func updateBackingScale(_ scale: CGFloat) {
        backingScale = max(scale, 1)
        bars.forEach { $0.contentsScale = backingScale }
        haloLayer.contentsScale = backingScale
        updateBars()
    }

    func refreshAccessibilityPresentation() {
        applyBarColors()
        updateBars()
    }

    private func applyBarColors() {
        let accent = NSColor.colorWith(hex: DictationMiniPalette.accentHex, alpha: 1)
        let highlight = NSColor.colorWith(hex: DictationMiniPalette.accentHighlightHex, alpha: 1)
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let quietAlpha = increaseContrast ? 0.8 : DictationMiniRendering.recordingQuietAlpha
        // Lit bars warm toward amber and brighten; quiet bars rest as muted orange.
        for (index, bar) in bars.enumerated() {
            let level = engine.bars.indices.contains(index) ? engine.bars[index] : 0
            let color = accent.blended(withFraction: level * 0.85, of: highlight) ?? accent
            bar.backgroundColor = color.withAlphaComponent(quietAlpha + (1 - quietAlpha) * min(1, level * 1.6)).cgColor
        }
    }

    private func updateBars() {
        guard !bars.isEmpty else { return }
        let barWidth = DictationMiniRendering.recordingBarWidth
        let pitch = DictationMiniRendering.recordingBarPitch
        let minHeight = DictationMiniRendering.recordingBarMinHeight
        let maxHeight = DictationMiniRendering.recordingBarMaxHeight
        let fieldWidth = CGFloat(bars.count - 1) * pitch + barWidth
        let startX = DictationMiniRendering.pixelAligned(bounds.midX - fieldWidth / 2, scale: backingScale)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let levels = engine.bars
        if !reduceMotion { applyBarColors() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let level: CGFloat
            if reduceMotion {
                level = power * 0.55 * DictationMiniRendering.recordingStaticEnvelope(index: index, count: bars.count)
            } else {
                level = levels[index]
            }
            let height = DictationMiniRendering.pixelAligned(
                minHeight + (maxHeight - minHeight) * max(0, min(1, level)),
                scale: backingScale
            )
            bar.frame = CGRect(
                x: DictationMiniRendering.pixelAligned(startX + CGFloat(index) * pitch, scale: backingScale),
                y: DictationMiniRendering.pixelAligned(bounds.midY - height / 2, scale: backingScale),
                width: barWidth,
                height: height
            )
        }
        let haloSize = CGSize(width: min(bounds.width - 8, 44), height: min(bounds.height, 18))
        haloLayer.frame = CGRect(
            x: bounds.midX - haloSize.width / 2,
            y: bounds.midY - haloSize.height / 2,
            width: haloSize.width,
            height: haloSize.height
        )
        haloLayer.opacity = Float(reduceMotion ? 0.35 : 0.25 + 0.75 * power)
        CATransaction.commit()
    }
}

private final class DictationMiniPointFieldView: NSView {
    private struct PointDefinition {
        let row: Int
        let column: Int
        let distance: CGFloat
        let angularOffset: CGFloat
    }

    private let points: [PointDefinition]
    private var dots: [CAShapeLayer] = []
    private var backingScale: CGFloat = 2
    var phase: CGFloat = 0 { didSet { updateDots() } }

    override init(frame frameRect: NSRect) {
        var definitions: [PointDefinition] = []
        for row in -2...2 {
            for column in -2...2 {
                let distance = hypot(CGFloat(column), CGFloat(row))
                guard distance <= 2.35 else { continue }
                definitions.append(PointDefinition(
                    row: row,
                    column: column,
                    distance: distance,
                    angularOffset: atan2(CGFloat(row), CGFloat(column))
                ))
            }
        }
        points = definitions
        super.init(frame: frameRect)
        wantsLayer = true
        for point in points {
            let dot = CAShapeLayer()
            let warmth = max(0, min(1, 0.58 - point.distance * 0.14))
            let accent = NSColor.colorWith(hex: DictationMiniPalette.accentHex, alpha: 1)
            let highlight = NSColor.colorWith(hex: DictationMiniPalette.accentHighlightHex, alpha: 1)
            dot.fillColor = (accent.blended(withFraction: warmth, of: highlight) ?? accent).cgColor
            dot.shadowColor = accent.withAlphaComponent(0.34).cgColor
            dot.shadowOpacity = 1
            dot.shadowRadius = 2
            dot.shadowOffset = .zero
            layer?.addSublayer(dot)
            dots.append(dot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateDotGeometry()
        updateDots()
    }

    func updateBackingScale(_ scale: CGFloat) {
        backingScale = max(scale, 1)
        dots.forEach { $0.contentsScale = backingScale }
        updateDotGeometry()
        updateDots()
    }

    func refreshAccessibilityPresentation() {
        updateDots()
    }

    private func updateDotGeometry() {
        let spacing = DictationMiniRendering.processingPointSpacing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (definition, dot) in zip(points, dots) {
            let diameter = max(
                DictationMiniRendering.processingPointMinDiameter,
                DictationMiniRendering.processingPointMaxDiameter - definition.distance * 0.14
            )
            let size = CGSize(width: diameter, height: diameter)
            dot.bounds = CGRect(origin: .zero, size: size)
            dot.position = CGPoint(
                x: DictationMiniRendering.pixelAligned(
                    bounds.midX + CGFloat(definition.column) * spacing,
                    scale: backingScale
                ),
                y: DictationMiniRendering.pixelAligned(
                    bounds.midY + CGFloat(definition.row) * spacing,
                    scale: backingScale
                )
            )
            dot.path = CGPath(ellipseIn: CGRect(origin: .zero, size: size), transform: nil)
        }
        CATransaction.commit()
    }

    private func updateDots() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (definition, dot) in zip(points, dots) {
            let wave = reduceMotion
                ? 0.82
                : 0.74 + 0.26 * sin(phase - definition.distance * 0.9 + definition.angularOffset * 0.22)
            dot.opacity = Float(max(0.34, (1 - definition.distance / 3.4) * wave))
            let scale = reduceMotion ? 1 : 0.92 + 0.08 * wave
            dot.transform = CATransform3DMakeScale(scale, scale, 1)
        }
        CATransaction.commit()
    }
}

private final class DictationMiniArtworkView: NSView {
    var presentation: DictationMiniIndicatorController.Presentation = .hidden

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard presentation != .hidden else { return }
        if let context = NSGraphicsContext.current?.cgContext {
            context.setShouldAntialias(true)
            context.setAllowsAntialiasing(true)
            context.interpolationQuality = .high
        }
        switch presentation {
        case .preparing, .idle:
            break
        case .recording:
            break
        case .processing:
            break
        case .success:
            break
        case .failure:
            drawFailure()
        case .warning(let message):
            drawWarning(message)
        case .hidden:
            break
        }
    }

    private func drawFailure() {
        let color = NSColor.colorWith(hex: DictationMiniPalette.failureHex, alpha: 1)
        let side = min(bounds.width, bounds.height)
        let inset = (side * 0.15).rounded()
        color.withAlphaComponent(0.20).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset)).fill()
        color.setStroke()
        let low = bounds.midX - side * 0.18
        let high = bounds.midX + side * 0.18
        let bottom = bounds.midY - side * 0.18
        let top = bounds.midY + side * 0.18
        for endpoints in [
            (CGPoint(x: low, y: bottom), CGPoint(x: high, y: top)),
            (CGPoint(x: high, y: bottom), CGPoint(x: low, y: top)),
        ] {
            let path = NSBezierPath()
            path.move(to: endpoints.0)
            path.line(to: endpoints.1)
            path.lineWidth = max(1.6, side * 0.09)
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    private func drawWarning(_ message: String) {
        let warningRect = CGRect(x: 8, y: 6, width: 14, height: 14)
        NSColor.colorWith(hex: DictationMiniPalette.accentHighlightHex, alpha: 1).setStroke()
        let triangle = NSBezierPath()
        triangle.move(to: CGPoint(x: warningRect.midX, y: warningRect.maxY))
        triangle.line(to: CGPoint(x: warningRect.maxX, y: warningRect.minY))
        triangle.line(to: CGPoint(x: warningRect.minX, y: warningRect.minY))
        triangle.close()
        triangle.lineWidth = 1.5
        triangle.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.colorWith(hex: DictationMiniPalette.inkHex, alpha: 0.95),
            .paragraphStyle: paragraph,
        ]
        (message as NSString).draw(
            in: CGRect(x: 28, y: 6, width: bounds.width - 36, height: 15),
            withAttributes: attributes
        )
    }
}
