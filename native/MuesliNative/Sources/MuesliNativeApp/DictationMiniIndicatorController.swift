import AppKit

/// The sole window and lifecycle owner for short-lived dictation feedback.
@MainActor
final class DictationMiniIndicatorController: NSObject {
    struct Generation: Hashable, Sendable {
        fileprivate let rawValue: UInt64
    }

    enum Presentation: Equatable {
        case hidden
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
        accessibilitySink: @escaping AccessibilitySink = { _ in }
    ) {
        self.screenProvider = screenProvider
        self.caretAnchorProvider = caretAnchorProvider
        self.caretClearanceProvider = caretClearanceProvider
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
        guard presentation == .hidden || isWarning(presentation) else { return nil }
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

    /// Neutral completion/cancellation. A terminal hold owns its own dismissal.
    func dismiss(generation token: Generation) {
        guard accepts(token), !isTerminal(presentation) else { return }
        hide(invalidateGeneration: true)
    }

    func close() {
        hide(invalidateGeneration: true)
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

    static func surfaceSize(for presentation: Presentation) -> CGSize {
        switch presentation {
        case .hidden: return .zero
        case .preparing: return CGSize(width: 14, height: 14)
        case .recording: return CGSize(width: 58, height: 22)
        case .processing: return CGSize(width: 38, height: 38)
        case .success: return CGSize(width: 12, height: 12)
        case .failure: return CGSize(width: 22, height: 22)
        case .warning(let text):
            return CGSize(width: min(max(CGFloat(text.count) * 6.4 + 34, 96), 320), height: 26)
        }
    }

    static func accessibilityLabel(for presentation: Presentation) -> String? {
        switch presentation {
        case .hidden: return nil
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
        if let liveAnchor = caretAnchorProvider() {
            anchorPoint = liveAnchor
            anchorScreen = nil
            currentFrame = nil
            placeFollowingSurface(size: Self.surfaceSize(for: terminal))
        }
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
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        contentView?.presentation = newPresentation
        contentView?.animationPhase = 0
        contentView?.updateAccessibilityLabel(Self.accessibilityLabel(for: newPresentation))
        contentView?.needsDisplay = true
        if let currentFrame {
            panel.setFrame(currentFrame, display: true)
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }

        if oldPresentation != newPresentation,
           let announcement = Self.accessibilityAnnouncement(for: newPresentation) {
            accessibilitySink(announcement)
        }
    }

    private func placeFollowingSurface(size: CGSize) {
        guard let anchor = anchorPoint ?? caretAnchorProvider() else { return }
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
        case .processing, .success, .failure, .warning:
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
            contentView?.needsDisplay = true
            return
        }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advanceAnimation() }
        }
    }

    private func advanceAnimation() {
        guard presentation == .recording || presentation == .processing else {
            stopAnimation(clearPowerProvider: false)
            return
        }
        if presentation == .recording {
            let decibels = powerProvider?() ?? -160
            let normalized = max(0, min(1, (CGFloat(decibels) + 68) / 38))
            let current = contentView?.power ?? 0
            contentView?.power = current * 0.52 + normalized * 0.48
        } else {
            contentView?.animationPhase.formTruncatingRemainder(dividingBy: .pi * 2)
            contentView?.animationPhase += 0.11
        }
        contentView?.needsDisplay = true
    }

    private func stopAnimation(clearPowerProvider: Bool) {
        animationTimer?.invalidate()
        animationTimer = nil
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
        contentView?.presentation = .hidden
        contentView?.updateAccessibilityLabel(nil)
        panel?.orderOut(nil)
    }

    private func refreshAccessibilityPresentation() {
        contentView?.needsDisplay = true
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
        case .hidden, .preparing:
            return nil
        case .warning(let message):
            return message
        case .recording, .processing, .success, .failure:
            return accessibilityLabel(for: presentation)
        }
    }
}

private final class DictationMiniView: NSView {
    var presentation: DictationMiniIndicatorController.Presentation = .hidden
    var power: CGFloat = 0
    var animationPhase: CGFloat = 0

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func updateAccessibilityLabel(_ label: String?) {
        setAccessibilityLabel(label)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard presentation != .hidden else { return }
        let workspace = NSWorkspace.shared
        let style = FloatingIndicatorSurfaceStyle.resolve(
            role: role,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
        switch presentation {
        case .preparing:
            drawPreparing()
        case .recording:
            drawSurface(style: style)
            drawWaveform(style: style, reduceMotion: workspace.accessibilityDisplayShouldReduceMotion)
        case .processing:
            drawSurface(style: style, circular: true)
            drawPointField(reduceMotion: workspace.accessibilityDisplayShouldReduceMotion)
        case .success:
            drawSuccess()
        case .failure:
            drawSurface(style: style, circular: true)
            drawFailure()
        case .warning(let message):
            drawSurface(style: style)
            drawWarning(message, style: style)
        case .hidden:
            break
        }
    }

    private var role: FloatingIndicatorPresentationRole {
        switch presentation {
        case .preparing, .success: return .preparing
        case .recording: return .recording
        case .processing: return .transcribing
        case .failure, .warning: return .warning
        case .hidden: return .idleCollapsed
        }
    }

    private func drawSurface(style: FloatingIndicatorSurfaceStyle, circular: Bool = false) {
        let surface = bounds.insetBy(dx: 1, dy: 1)
        NSColor.colorWith(hexString: style.tintHex, alpha: style.tintAlpha).setFill()
        let radius = circular ? surface.height / 2 : min(surface.height / 2, 11)
        let path = NSBezierPath(roundedRect: surface, xRadius: radius, yRadius: radius)
        path.fill()
        NSColor.colorWith(hexString: style.borderHex, alpha: style.borderAlpha).setStroke()
        path.lineWidth = style.borderWidth
        path.stroke()
    }

    private func drawPreparing() {
        let accent = NSColor.colorWith(hex: MuesliTheme.resolvedAccentDarkHex, alpha: 1)
        accent.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        accent.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).fill()
    }

    private func drawWaveform(style: FloatingIndicatorSurfaceStyle, reduceMotion: Bool) {
        let multipliers: [CGFloat] = [0.6, 0.85, 1, 0.85, 0.6]
        let barWidth: CGFloat = 3
        let spacing: CGFloat = 3
        let totalWidth = CGFloat(multipliers.count) * barWidth + CGFloat(multipliers.count - 1) * spacing
        let startX = bounds.midX - totalWidth / 2
        let motionScale: CGFloat = reduceMotion ? 0.55 : 1
        NSColor.colorWith(hexString: style.glyphHex, alpha: style.glyphAlpha).setFill()
        for (index, multiplier) in multipliers.enumerated() {
            let height = max(3, min(14, 3 + 11 * power * multiplier * motionScale))
            let rect = CGRect(
                x: startX + CGFloat(index) * (barWidth + spacing),
                y: bounds.midY - height / 2,
                width: barWidth,
                height: height
            )
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawPointField(reduceMotion: Bool) {
        let accent = NSColor.colorWith(hex: MuesliTheme.resolvedAccentDarkHex, alpha: 1)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let spacing: CGFloat = 4
        for row in -3...3 {
            for column in -3...3 {
                let distance = hypot(CGFloat(column), CGFloat(row))
                guard distance <= 3.25 else { continue }
                let wave = reduceMotion ? 0.75 : 0.68 + 0.32 * sin(animationPhase - distance * 0.8)
                let alpha = max(0.18, (1 - distance / 4) * wave)
                let diameter = max(1.2, 2.3 - distance * 0.22)
                let point = CGRect(
                    x: center.x + CGFloat(column) * spacing - diameter / 2,
                    y: center.y + CGFloat(row) * spacing - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                accent.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: point).fill()
            }
        }
    }

    private func drawSuccess() {
        let color = NSColor.systemGreen
        color.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        color.setStroke()
        let check = NSBezierPath()
        check.move(to: CGPoint(x: 3, y: 6))
        check.line(to: CGPoint(x: 5.2, y: 3.8))
        check.line(to: CGPoint(x: 9.3, y: 8.5))
        check.lineWidth = 1.7
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.stroke()
    }

    private func drawFailure() {
        let color = NSColor.systemRed
        color.withAlphaComponent(0.20).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).fill()
        color.setStroke()
        for endpoints in [
            (CGPoint(x: 7, y: 7), CGPoint(x: 15, y: 15)),
            (CGPoint(x: 15, y: 7), CGPoint(x: 7, y: 15)),
        ] {
            let path = NSBezierPath()
            path.move(to: endpoints.0)
            path.line(to: endpoints.1)
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    private func drawWarning(_ message: String, style: FloatingIndicatorSurfaceStyle) {
        let warningRect = CGRect(x: 8, y: 6, width: 14, height: 14)
        NSColor.systemOrange.setStroke()
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
            .foregroundColor: NSColor.colorWith(hexString: style.glyphHex, alpha: style.textAlpha),
            .paragraphStyle: paragraph,
        ]
        (message as NSString).draw(
            in: CGRect(x: 28, y: 6, width: bounds.width - 36, height: 15),
            withAttributes: attributes
        )
    }
}
