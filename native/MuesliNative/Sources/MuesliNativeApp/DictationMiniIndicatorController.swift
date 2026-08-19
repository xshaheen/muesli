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
    private var animationStartedAt: TimeInterval?
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
        case .processing: return CGSize(width: 28, height: 28)
        case .success: return CGSize(width: 18, height: 14)
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
            animationStartedAt = nil
            contentView?.needsDisplay = true
            return
        }
        animationStartedAt = ProcessInfo.processInfo.systemUptime
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
            let normalized = max(0, min(1, (CGFloat(decibels) + 68) / 38))
            let current = contentView?.power ?? 0
            contentView?.power = current * 0.52 + normalized * 0.48
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

enum DictationMiniPalette {
    static let surfaceTopHex = 0x32312F
    static let surfaceBottomHex = 0x181817
    static let orbTopHex = 0x272725
    static let orbBottomHex = 0x0E0E0D
    static let accentHex = 0xFF7043
    static let accentHighlightHex = 0xFFB04D
    static let successHex = 0x62D691
    static let failureHex = 0xFF6961
    static let inkHex = 0xF3F2EF
}

private final class DictationMiniView: NSView {
    private let glassView = NSVisualEffectView()
    private let artworkView = DictationMiniArtworkView()

    var presentation: DictationMiniIndicatorController.Presentation = .hidden {
        didSet {
            artworkView.presentation = presentation
            updateGlass()
        }
    }
    var power: CGFloat {
        get { artworkView.power }
        set { artworkView.power = newValue }
    }
    var animationPhase: CGFloat {
        get { artworkView.animationPhase }
        set { artworkView.animationPhase = newValue }
    }

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glassView.material = .hudWindow
        glassView.blendingMode = .behindWindow
        glassView.state = .active
        glassView.wantsLayer = true
        artworkView.wantsLayer = true
        addSubview(glassView)
        addSubview(artworkView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func updateAccessibilityLabel(_ label: String?) {
        setAccessibilityLabel(label)
    }

    override func layout() {
        super.layout()
        glassView.frame = bounds
        artworkView.frame = bounds
        updateGlass()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        glassView.layer?.contentsScale = scale
        artworkView.layer?.contentsScale = scale
    }

    override var needsDisplay: Bool {
        get { artworkView.needsDisplay }
        set { artworkView.needsDisplay = newValue }
    }

    private func updateGlass() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let usesGlass: Bool
        switch presentation {
        case .recording, .processing, .failure, .warning:
            usesGlass = !reduceTransparency
        case .hidden, .preparing, .success:
            usesGlass = false
        }
        glassView.isHidden = !usesGlass
        let radius: CGFloat
        switch presentation {
        case .processing, .failure:
            radius = bounds.height / 2
        default:
            radius = min(bounds.height / 2, 11)
        }
        glassView.layer?.cornerRadius = radius
        glassView.layer?.cornerCurve = .continuous
        glassView.layer?.masksToBounds = true
    }
}

private final class DictationMiniArtworkView: NSView {
    var presentation: DictationMiniIndicatorController.Presentation = .hidden
    var power: CGFloat = 0
    var animationPhase: CGFloat = 0

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
        let workspace = NSWorkspace.shared
        let reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        switch presentation {
        case .preparing:
            drawPreparing()
        case .recording:
            drawSurface(
                reduceTransparency: reduceTransparency,
                increaseContrast: increaseContrast
            )
            drawWaveform(reduceMotion: workspace.accessibilityDisplayShouldReduceMotion)
        case .processing:
            drawSurface(
                circular: true,
                usesOrbPalette: true,
                reduceTransparency: reduceTransparency,
                increaseContrast: increaseContrast
            )
            drawPointField(reduceMotion: workspace.accessibilityDisplayShouldReduceMotion)
        case .success:
            drawSuccess()
        case .failure:
            drawSurface(
                circular: true,
                reduceTransparency: reduceTransparency,
                increaseContrast: increaseContrast
            )
            drawFailure()
        case .warning(let message):
            drawSurface(
                reduceTransparency: reduceTransparency,
                increaseContrast: increaseContrast
            )
            drawWarning(message)
        case .hidden:
            break
        }
    }

    private func drawSurface(
        circular: Bool = false,
        usesOrbPalette: Bool = false,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) {
        let surface = bounds.insetBy(dx: 1, dy: 1)
        let radius = circular ? surface.height / 2 : min(surface.height / 2, 11)
        let path = NSBezierPath(roundedRect: surface, xRadius: radius, yRadius: radius)

        let topHex = usesOrbPalette ? DictationMiniPalette.orbTopHex : DictationMiniPalette.surfaceTopHex
        let bottomHex = usesOrbPalette ? DictationMiniPalette.orbBottomHex : DictationMiniPalette.surfaceBottomHex
        let topAlpha: CGFloat = reduceTransparency ? 1 : 0.64
        let bottomAlpha: CGFloat = reduceTransparency ? 1 : 0.76
        let top = NSColor.colorWith(hex: topHex, alpha: topAlpha)
        let bottom = NSColor.colorWith(hex: bottomHex, alpha: bottomAlpha)
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)

        NSColor.white.withAlphaComponent(increaseContrast ? 0.82 : 0.18).setStroke()
        path.lineWidth = increaseContrast ? 2 : 1
        path.stroke()
    }

    private func drawPreparing() {
        let accent = NSColor.colorWith(hex: DictationMiniPalette.accentHex, alpha: 1)
        accent.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        accent.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).fill()
    }

    private func drawWaveform(reduceMotion: Bool) {
        let multipliers: [CGFloat] = [0.6, 0.85, 1, 0.85, 0.6]
        let barWidth: CGFloat = 2
        let spacing: CGFloat = 3
        let totalWidth = CGFloat(multipliers.count) * barWidth + CGFloat(multipliers.count - 1) * spacing
        let startX = bounds.midX - totalWidth / 2
        let motionScale: CGFloat = reduceMotion ? 0.55 : 1
        let accent = NSColor.colorWith(hex: DictationMiniPalette.accentHex, alpha: 1)
        let highlight = NSColor.colorWith(hex: DictationMiniPalette.accentHighlightHex, alpha: 1)
        for (index, multiplier) in multipliers.enumerated() {
            let height = max(3, min(14, 3 + 11 * power * multiplier * motionScale))
            let rect = CGRect(
                x: startX + CGFloat(index) * (barWidth + spacing),
                y: bounds.midY - height / 2,
                width: barWidth,
                height: height
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = accent.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = 5
            shadow.shadowOffset = .zero
            shadow.set()
            accent.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSGradient(starting: highlight, ending: accent)?.draw(in: rect, angle: -90)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawPointField(reduceMotion: Bool) {
        let accent = NSColor.colorWith(hex: DictationMiniPalette.accentHex, alpha: 1)
        let highlight = NSColor.colorWith(hex: DictationMiniPalette.accentHighlightHex, alpha: 1)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let spacing: CGFloat = 3.5
        for row in -2...2 {
            for column in -2...2 {
                let distance = hypot(CGFloat(column), CGFloat(row))
                guard distance <= 2.35 else { continue }
                let angularOffset = atan2(CGFloat(row), CGFloat(column))
                let wave = reduceMotion ? 0.78 : 0.70 + 0.30 * sin(animationPhase - distance * 0.9 + angularOffset * 0.22)
                let alpha = max(0.28, (1 - distance / 3.2) * wave)
                let diameter = max(1.8, 2.4 - distance * 0.18)
                let point = CGRect(
                    x: center.x + CGFloat(column) * spacing - diameter / 2,
                    y: center.y + CGFloat(row) * spacing - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                let warmth = max(0, min(1, 0.58 - distance * 0.14))
                let color = accent.blended(withFraction: warmth, of: highlight) ?? accent
                color.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: point).fill()
            }
        }
    }

    private func drawSuccess() {
        let color = NSColor.colorWith(hex: DictationMiniPalette.successHex, alpha: 1)
        let check = NSBezierPath()
        check.move(to: CGPoint(x: 1.5, y: 7))
        check.line(to: CGPoint(x: 6.2, y: 2.8))
        check.line(to: CGPoint(x: 16.5, y: 12))
        check.lineWidth = 2.4
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.42)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = .zero
        shadow.set()
        color.setStroke()
        check.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawFailure() {
        let color = NSColor.colorWith(hex: DictationMiniPalette.failureHex, alpha: 1)
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
