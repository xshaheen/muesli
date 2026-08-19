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
    private var lastRecordingSampleAt: TimeInterval = 0
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
        case .preparing: return CGSize(width: 24, height: 24)
        case .recording: return CGSize(width: 58, height: 22)
        case .processing: return CGSize(width: 28, height: 28)
        case .success: return CGSize(width: 24, height: 24)
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
        lastRecordingSampleAt = 0
        if presentation == .recording { contentView?.resetRecordingHistory() }
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
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastRecordingSampleAt >= DictationMiniRendering.recordingSampleInterval {
                lastRecordingSampleAt = now
                contentView?.pushRecordingSample(level)
            }
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
    static let glassTintHex = 0x211F1E
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

enum DictationMiniRendering {
    static let glassTintAlpha: CGFloat = 0.44
    /// Recording sits on a lower, darker ground so the fine one-point bars stay legible.
    static let recordingGlassTintAlpha: CGFloat = 0.62
    static let recordingBarCount = 24
    static let recordingBarWidth: CGFloat = 1
    static let recordingBarPitch: CGFloat = 2
    static let recordingBarMinHeight: CGFloat = 1
    static let recordingBarMaxHeight: CGFloat = 12
    /// History advances at 30 Hz: 24 bars hold the last 0.8 s of speech.
    static let recordingSampleInterval: TimeInterval = 1 / 30
    static let recordingTailAlpha: CGFloat = 0.42
    static let preparingDotDiameter: CGFloat = 14
    static let completionDiameter: CGFloat = 20

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

    /// Bars age from a hot amber live edge (right) to a muted orange tail (left).
    static func recordingBarAge(index: Int, count: Int) -> CGFloat {
        guard count > 1 else { return 1 }
        return CGFloat(index) / CGFloat(count - 1)
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

/// Fixed-capacity level history, oldest first, newest last.
struct DictationMiniWaveformHistory: Equatable {
    private(set) var levels: [CGFloat]

    init(count: Int = DictationMiniRendering.recordingBarCount) {
        levels = Array(repeating: 0, count: max(count, 1))
    }

    var count: Int { levels.count }

    mutating func push(_ level: CGFloat) {
        levels.removeFirst()
        levels.append(max(0, min(1, level)))
    }

    mutating func reset() {
        levels = Array(repeating: 0, count: levels.count)
    }
}

private final class DictationMiniView: NSView {
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
    func pushRecordingSample(_ level: CGFloat) { waveformView.push(level) }
    func resetRecordingHistory() { waveformView.reset() }
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

    private func updateSurface() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let usesSurface: Bool
        switch presentation {
        case .recording, .processing, .failure, .warning:
            usesSurface = true
        case .hidden, .preparing, .success:
            usesSurface = false
        }
        glassView.isHidden = !usesSurface || reduceTransparency
        tintView.isHidden = !usesSurface
        let radius: CGFloat
        switch presentation {
        case .processing, .failure:
            radius = bounds.height / 2
        default:
            radius = min(bounds.height / 2, 11)
        }
        layer?.masksToBounds = usesSurface
        layer?.cornerRadius = radius
        layer?.borderWidth = usesSurface
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
        tintView.layer?.backgroundColor = NSColor.colorWith(
            hex: DictationMiniPalette.glassTintHex,
            alpha: reduceTransparency ? 1 : tintAlpha
        ).cgColor
    }
}

private final class DictationMiniCueView: NSView {
    private let diskLayer = CAShapeLayer()
    private let checkLayer = CAShapeLayer()
    private var backingScale: CGFloat = 2

    var presentation: DictationMiniIndicatorController.Presentation = .hidden {
        didSet { updateCue() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        diskLayer.shadowOffset = .zero
        checkLayer.fillColor = nil
        checkLayer.lineCap = .round
        checkLayer.lineJoin = .round
        layer?.addSublayer(diskLayer)
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
        case .preparing:
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
        diskLayer.path = CGPath(ellipseIn: diskRect, transform: nil)
        diskLayer.fillColor = fillColor.cgColor
        diskLayer.shadowColor = fillColor.withAlphaComponent(0.52).cgColor
        diskLayer.shadowOpacity = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.3 : 1
        diskLayer.shadowRadius = presentation == .preparing ? 5 : 4

        if presentation == .success {
            let check = CGMutablePath()
            check.move(to: CGPoint(x: diskRect.minX + 5.1, y: diskRect.midY + 0.1))
            check.addLine(to: CGPoint(x: diskRect.minX + 8.7, y: diskRect.minY + 6.4))
            check.addLine(to: CGPoint(x: diskRect.minX + 15.3, y: diskRect.minY + 13.3))
            checkLayer.path = check
            checkLayer.strokeColor = NSColor.colorWith(
                hex: DictationMiniPalette.orbBottomHex,
                alpha: 0.92
            ).cgColor
            checkLayer.lineWidth = 2.2
            checkLayer.isHidden = false
        } else {
            checkLayer.isHidden = true
        }
        CATransaction.commit()
    }
}

private final class DictationMiniWaveformView: NSView {
    private var bars: [CALayer] = []
    private let haloLayer = CAGradientLayer()
    private var history = DictationMiniWaveformHistory()
    private var backingScale: CGFloat = 2
    /// Smoothed live level: drives the halo and the newest bar between history pushes.
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

    func push(_ level: CGFloat) {
        history.push(level)
        updateBars()
    }

    func reset() {
        history.reset()
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
        let tailAlpha = increaseContrast ? 0.78 : DictationMiniRendering.recordingTailAlpha
        for (index, bar) in bars.enumerated() {
            let age = DictationMiniRendering.recordingBarAge(index: index, count: bars.count)
            let warmth = age * age
            let color = accent.blended(withFraction: warmth * 0.8, of: highlight) ?? accent
            bar.backgroundColor = color.withAlphaComponent(tailAlpha + (1 - tailAlpha) * age).cgColor
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
        let levels = history.levels
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let level: CGFloat
            if reduceMotion {
                level = power * 0.55 * DictationMiniRendering.recordingStaticEnvelope(index: index, count: bars.count)
            } else if index == bars.count - 1 {
                level = max(levels[index], power)
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
        let spacing: CGFloat = 3.5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (definition, dot) in zip(points, dots) {
            let diameter = max(2, 2.7 - definition.distance * 0.16)
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
        case .preparing:
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
