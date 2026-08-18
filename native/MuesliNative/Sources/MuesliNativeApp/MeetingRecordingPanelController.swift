import AppKit
import QuartzCore
import Foundation

/// Borderless floating panels need to become key only when one of their controls
/// explicitly requests keyboard focus. They must never become the app's main window.
final class InteractiveFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct MeetingRecordingElapsedClock: Equatable {
    private(set) var accumulated: TimeInterval = 0
    private(set) var runningSince: Date?

    mutating func start(at date: Date) {
        accumulated = 0
        runningSince = date
    }

    mutating func pause(at date: Date) {
        guard let runningSince else { return }
        accumulated += max(0, date.timeIntervalSince(runningSince))
        self.runningSince = nil
    }

    mutating func resume(at date: Date) {
        guard runningSince == nil else { return }
        runningSince = date
    }

    mutating func reset() {
        self = MeetingRecordingElapsedClock()
    }

    func elapsed(at date: Date) -> TimeInterval {
        accumulated + (runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }
}

enum MeetingRecordingPanelState: Equatable {
    case hidden
    case recording
    case paused
    case finalizing(String)
}

@MainActor
private final class MeetingRecordingPanelContentView: NSView {
    weak var owner: MeetingRecordingPanelController?
    private var trackingAreaRef: NSTrackingArea?
    private var mouseDownScreenLocation: NSPoint?
    private var didDrag = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        for subview in subviews.reversed() {
            guard let button = subview as? NSButton, !button.isHidden, button.frame.contains(point) else { continue }
            return button
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        owner?.pointerEntered()
    }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        mouseDownScreenLocation = NSEvent.mouseLocation
        owner?.pointerInteractionBegan(at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownScreenLocation else { return }
        let current = NSEvent.mouseLocation
        guard didDrag || hypot(current.x - mouseDownScreenLocation.x, current.y - mouseDownScreenLocation.y) >= 6 else {
            return
        }
        didDrag = true
        owner?.pointerDragged(to: current)
    }

    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            owner?.discardRequested()
        } else {
            owner?.pointerInteractionEnded(didDrag: didDrag)
        }
        mouseDownScreenLocation = nil
        didDrag = false
    }

    override func rightMouseUp(with event: NSEvent) {
        owner?.discardRequested()
    }
}

@MainActor
final class MeetingRecordingPanelController: NSObject {
    nonisolated static let panelSize = NSSize(width: 224, height: 46)
    nonisolated private static let screenInset: CGFloat = 12

    var onStop: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onOpenNotes: (() -> Void)?
    var onControlCenterSaved: ((CGPoint) -> Void)?

    var onTranscriptPanelOriginSaved: ((CGPoint) -> Void)? {
        get { transcriptPanel.onUserMovedPanel }
        set { transcriptPanel.onUserMovedPanel = newValue }
    }

    private let configStore: ConfigStore
    private let now: () -> Date
    private var state: MeetingRecordingPanelState = .hidden
    private var ownerID: UUID?
    private var elapsedClock = MeetingRecordingElapsedClock()
    private var powerProvider: (() -> Float)?
    private var isTranscriptManuallyDismissed = false

    private var panel: InteractiveFloatingPanel?
    private var contentView: MeetingRecordingPanelContentView?
    private var glassView: NSVisualEffectView?
    private var tintLayer: CALayer?
    private var transcriptButton: NSButton?
    private var pauseButton: NSButton?
    private var stopButton: NSButton?
    private var elapsedLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var waveformLayers: [CALayer] = []
    private var animationTimer: Timer?
    private var smoothedAmplitude: CGFloat = 0
    private var dragWindowOrigin: NSPoint?
    private var dragPointerOrigin: NSPoint?
    private var dragScreenFrames: [NSRect] = []
    private var notificationObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private lazy var transcriptPanel = FloatingMeetingTranscriptPanelController(
        onOpenNotes: { [weak self] in
            self?.hideTranscript()
            self?.onOpenNotes?()
        },
        onDismiss: { [weak self] in
            self?.isTranscriptManuallyDismissed = true
            self?.hideTranscript()
        }
    )

    init(configStore: ConfigStore, now: @escaping () -> Date = Date.init) {
        self.configStore = configStore
        self.now = now
        super.init()
        transcriptPanel.savedOriginProvider = { [weak self] in
            self?.configStore.load().meetingPanelOrigin.map { CGPoint(x: $0.x, y: $0.y) }
        }

        let screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcilePanelToAttachedScreens() }
        }
        notificationObservers.append((NotificationCenter.default, screenObserver))

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let accessibilityObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applySurfaceStyle() }
        }
        notificationObservers.append((workspaceCenter, accessibilityObserver))
    }

    deinit {
        for observer in notificationObservers {
            observer.center.removeObserver(observer.token)
        }
    }

    var presentationWindow: NSPanel? { panel }
    var isVisible: Bool { panel?.isVisible == true }
    var isTranscriptPanelVisible: Bool { transcriptPanel.isVisible }
    var stateForTesting: MeetingRecordingPanelState { state }
    var activeOwnerIDForTesting: UUID? { ownerID }
    var elapsedSecondsForTesting: TimeInterval { elapsedClock.elapsed(at: now()) }
    var controlsEnabledForTesting: Bool {
        [transcriptButton, pauseButton, stopButton].allSatisfy { $0?.isEnabled == true }
    }
    var controlAccessibilityLabelsForTesting: [String] {
        [transcriptButton, pauseButton, stopButton].compactMap { $0?.accessibilityLabel() }
    }

    func showRecording(
        ownerID: UUID,
        startedAt: Date,
        powerProvider: @escaping () -> Float,
        showTranscript: Bool
    ) {
        self.ownerID = ownerID
        self.powerProvider = powerProvider
        state = .recording
        elapsedClock.start(at: startedAt)
        isTranscriptManuallyDismissed = false
        transcriptPanel.reset()
        transcriptPanel.setPaused(false)
        transcriptPanel.setSelectionAccentHex(MuesliTheme.resolvedAccentDarkHex)

        let panel = panel ?? makePanel()
        self.panel = panel
        let savedCenter = configStore.load().meetingRecordingPanelCenter.map { CGPoint(x: $0.x, y: $0.y) }
        let frame = Self.resolvedFrame(
            savedCenter: savedCenter,
            size: Self.panelSize,
            screens: NSScreen.screens.map(\.visibleFrame)
        )
        panel.setFrame(frame, display: true)
        updateChrome()
        panel.orderFrontRegardless()
        startAnimationTimer()

        if showTranscript {
            showTranscriptPanel()
        }
    }

    func setPaused(_ paused: Bool, ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        switch state {
        case .recording where paused:
            elapsedClock.pause(at: now())
            state = .paused
            stopAnimationTimer()
        case .paused where !paused:
            elapsedClock.resume(at: now())
            state = .recording
            startAnimationTimer()
        default:
            return
        }
        transcriptPanel.setPaused(paused)
        updateChrome()
    }

    func beginFinalizing(ownerID: UUID, status: String = "Finalizing") {
        guard self.ownerID == ownerID else { return }
        if state == .recording {
            elapsedClock.pause(at: now())
        }
        state = .finalizing(status)
        powerProvider = nil
        stopAnimationTimer()
        hideTranscript(reset: true)
        updateChrome()
    }

    func updateFinalizingStatus(_ status: String, ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        guard case .finalizing = state else { return }
        state = .finalizing(status)
        updateChrome()
    }

    func close(ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        close()
    }

    func close() {
        stopAnimationTimer()
        transcriptPanel.reset()
        transcriptPanel.close()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        contentView = nil
        glassView = nil
        tintLayer = nil
        transcriptButton = nil
        pauseButton = nil
        stopButton = nil
        elapsedLabel = nil
        statusLabel = nil
        waveformLayers.removeAll()
        powerProvider = nil
        ownerID = nil
        state = .hidden
        elapsedClock.reset()
        isTranscriptManuallyDismissed = false
        dragWindowOrigin = nil
        dragPointerOrigin = nil
        dragScreenFrames.removeAll()
    }

    func updateMeetingTranscript(transcript: String, partialYou: String, partialOthers: String) {
        transcriptPanel.update(
            transcript: transcript,
            partialYou: partialYou,
            partialOthers: partialOthers
        )
    }

    func setMeetingChatContext(_ context: FloatingMeetingChatContext?) {
        transcriptPanel.setChatContext(context)
    }

    func toggleTranscriptPanel() {
        guard state == .recording || state == .paused else { return }
        if transcriptPanel.isVisible {
            isTranscriptManuallyDismissed = true
            hideTranscript()
        } else {
            showTranscriptPanel()
        }
    }

    func showTranscriptPanel() {
        guard state == .recording || state == .paused else { return }
        isTranscriptManuallyDismissed = false
        showTranscript()
    }

    func pointerEntered() {
        guard state == .recording || state == .paused else { return }
        guard !isTranscriptManuallyDismissed else { return }
        guard configStore.load().showMeetingTranscriptOnIndicatorHover else { return }
        showTranscript()
    }

    func pointerInteractionBegan(at screenPoint: NSPoint) {
        guard let panel else { return }
        dragWindowOrigin = panel.frame.origin
        dragPointerOrigin = screenPoint
        dragScreenFrames = NSScreen.screens.map(\.visibleFrame)
    }

    func pointerDragged(to screenPoint: NSPoint) {
        guard let panel, let dragWindowOrigin, let dragPointerOrigin else { return }
        let proposed = NSPoint(
            x: dragWindowOrigin.x + screenPoint.x - dragPointerOrigin.x,
            y: dragWindowOrigin.y + screenPoint.y - dragPointerOrigin.y
        )
        panel.setFrameOrigin(Self.clampedDragOrigin(proposed, size: panel.frame.size, screens: dragScreenFrames))
    }

    func pointerInteractionEnded(didDrag: Bool) {
        defer {
            dragWindowOrigin = nil
            dragPointerOrigin = nil
            dragScreenFrames.removeAll()
        }
        guard didDrag, let frame = panel?.frame else { return }
        onControlCenterSaved?(CGPoint(x: frame.midX, y: frame.midY))
    }

    func discardRequested() {
        guard state == .recording || state == .paused else { return }
        onDiscard?()
    }

    nonisolated static func defaultCenter(
        in visibleFrame: NSRect,
        size: NSSize = NSSize(width: 224, height: 46)
    ) -> CGPoint {
        CGPoint(
            x: visibleFrame.maxX - size.width / 2 - screenInset,
            y: visibleFrame.minY + size.height / 2 + screenInset
        )
    }

    nonisolated static func resolvedFrame(savedCenter: CGPoint?, size: NSSize, screens: [NSRect]) -> NSRect {
        guard let fallback = screens.first else {
            return NSRect(origin: .zero, size: size)
        }
        if let savedCenter,
           let screen = screens.first(where: { $0.contains(savedCenter) }) {
            return clampedFrame(center: savedCenter, size: size, in: screen)
        }
        return clampedFrame(center: defaultCenter(in: fallback, size: size), size: size, in: fallback)
    }

    nonisolated static func clampedDragOrigin(_ origin: NSPoint, size: NSSize, screens: [NSRect]) -> NSPoint {
        guard !screens.isEmpty else { return origin }
        let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let destination = screens.min { lhs, rhs in
            distance(from: center, to: lhs) < distance(from: center, to: rhs)
        } ?? screens[0]
        let clamped = clampedFrame(center: center, size: size, in: destination)
        return clamped.origin
    }

    nonisolated private static func distance(from point: CGPoint, to rect: NSRect) -> CGFloat {
        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)
        return hypot(point.x - x, point.y - y)
    }

    nonisolated private static func clampedFrame(center: CGPoint, size: NSSize, in screen: NSRect) -> NSRect {
        let minX = screen.minX + screenInset
        let maxX = max(minX, screen.maxX - screenInset - size.width)
        let minY = screen.minY + screenInset
        let maxY = max(minY, screen.maxY - screenInset - size.height)
        return NSRect(
            x: min(max(center.x - size.width / 2, minX), maxX),
            y: min(max(center.y - size.height / 2, minY), maxY),
            width: size.width,
            height: size.height
        )
    }

    private func makePanel() -> InteractiveFloatingPanel {
        let panel = InteractiveFloatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = MeetingRecordingPanelContentView(frame: NSRect(origin: .zero, size: Self.panelSize))
        content.owner = self
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.panelSize.height / 2
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        panel.contentView = content
        contentView = content

        let glass = NSVisualEffectView(frame: content.bounds)
        glass.autoresizingMask = [.width, .height]
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        content.addSubview(glass)
        glassView = glass

        let tint = CALayer()
        content.layer?.insertSublayer(tint, at: 0)
        tintLayer = tint

        transcriptButton = makeButton(
            symbol: "captions.bubble",
            accessibilityLabel: "Show live transcript",
            action: #selector(transcriptButtonPressed)
        )
        pauseButton = makeButton(
            symbol: "pause.fill",
            accessibilityLabel: "Pause meeting recording",
            action: #selector(pauseButtonPressed)
        )
        stopButton = makeButton(
            symbol: "stop.fill",
            accessibilityLabel: "Stop meeting recording",
            action: #selector(stopButtonPressed)
        )

        if let transcriptButton { content.addSubview(transcriptButton) }
        if let pauseButton { content.addSubview(pauseButton) }

        let elapsed = NSTextField(labelWithString: "00:00")
        elapsed.alignment = .center
        elapsed.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        elapsed.textColor = .white
        elapsed.setAccessibilityLabel("Elapsed meeting recording time")
        content.addSubview(elapsed)
        elapsedLabel = elapsed

        let status = NSTextField(labelWithString: "Meeting recording")
        status.alignment = .center
        status.font = .systemFont(ofSize: 8, weight: .semibold)
        status.textColor = .white.withAlphaComponent(0.62)
        status.setAccessibilityLabel("Meeting recording status")
        content.addSubview(status)
        statusLabel = status

        if let stopButton { content.addSubview(stopButton) }

        transcriptButton?.nextKeyView = pauseButton
        pauseButton?.nextKeyView = stopButton
        stopButton?.nextKeyView = transcriptButton
        panel.initialFirstResponder = transcriptButton

        setupWaveform(in: content)
        layoutContent()
        applySurfaceStyle()
        return panel
    }

    private func makeButton(symbol: String, accessibilityLabel: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        button.contentTintColor = .white.withAlphaComponent(0.86)
        button.focusRingType = .default
        button.target = self
        button.action = action
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = accessibilityLabel
        return button
    }

    private func layoutContent() {
        let height = Self.panelSize.height
        transcriptButton?.frame = NSRect(x: 4, y: 3, width: 38, height: height - 6)
        pauseButton?.frame = NSRect(x: 42, y: 3, width: 38, height: height - 6)
        elapsedLabel?.frame = NSRect(x: 126, y: 22, width: 58, height: 16)
        statusLabel?.frame = NSRect(x: 119, y: 8, width: 72, height: 12)
        stopButton?.frame = NSRect(x: 184, y: 3, width: 36, height: height - 6)
    }

    private func setupWaveform(in content: NSView) {
        waveformLayers.forEach { $0.removeFromSuperlayer() }
        waveformLayers.removeAll()
        for index in 0..<5 {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.82).cgColor
            bar.cornerRadius = 1.5
            bar.frame = CGRect(x: 88 + CGFloat(index) * 6, y: 20, width: 3, height: 6)
            content.layer?.addSublayer(bar)
            waveformLayers.append(bar)
        }
    }

    private func applySurfaceStyle() {
        guard let contentView else { return }
        let workspace = NSWorkspace.shared
        let style = FloatingMeetingPanelSurfaceStyle.resolve(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        ).glass
        glassView?.isHidden = !style.usesGlassEffect
        tintLayer?.frame = contentView.bounds
        tintLayer?.cornerRadius = contentView.bounds.height / 2
        tintLayer?.cornerCurve = .continuous
        tintLayer?.backgroundColor = NSColor.colorWith(hexString: style.tintHex, alpha: style.tintAlpha).cgColor
        contentView.layer?.borderWidth = style.borderWidth
        contentView.layer?.borderColor = NSColor.colorWith(hexString: style.borderHex, alpha: style.borderAlpha).cgColor
        panel?.alphaValue = style.panelAlpha
    }

    private func updateChrome() {
        guard contentView != nil else { return }
        elapsedLabel?.stringValue = Self.formattedElapsed(elapsedClock.elapsed(at: now()))
        let controlsEnabled: Bool
        switch state {
        case .hidden:
            controlsEnabled = false
            statusLabel?.stringValue = ""
        case .recording:
            controlsEnabled = true
            statusLabel?.stringValue = "Meeting recording"
            pauseButton?.image = configuredSymbol("pause.fill", description: "Pause meeting recording")
            pauseButton?.setAccessibilityLabel("Pause meeting recording")
        case .paused:
            controlsEnabled = true
            statusLabel?.stringValue = "Paused"
            pauseButton?.image = configuredSymbol("play.fill", description: "Resume meeting recording")
            pauseButton?.setAccessibilityLabel("Resume meeting recording")
        case .finalizing(let status):
            controlsEnabled = false
            statusLabel?.stringValue = status
        }
        transcriptButton?.isEnabled = controlsEnabled
        pauseButton?.isEnabled = controlsEnabled
        stopButton?.isEnabled = controlsEnabled
        transcriptButton?.alphaValue = controlsEnabled ? 1 : 0.36
        pauseButton?.alphaValue = controlsEnabled ? 1 : 0.36
        stopButton?.alphaValue = controlsEnabled ? 1 : 0.36
        statusLabel?.setAccessibilityValue(statusLabel?.stringValue ?? "")
        updateWaveform()
    }

    private func configuredSymbol(_ name: String, description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
    }

    private func startAnimationTimer() {
        stopAnimationTimer()
        guard state == .recording else { return }
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(animationTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
        smoothedAmplitude = 0
    }

    @objc private func animationTimerFired(_ timer: Timer) {
        elapsedLabel?.stringValue = Self.formattedElapsed(elapsedClock.elapsed(at: now()))
        updateWaveform()
    }

    private func updateWaveform() {
        let amplitude: CGFloat
        switch state {
        case .recording:
            let dB = CGFloat(powerProvider?() ?? -160)
            let raw = max(0, min(1, (dB + 68) / 38))
            smoothedAmplitude = 0.48 * raw + 0.52 * smoothedAmplitude
            amplitude = smoothedAmplitude
        case .paused:
            amplitude = 0
        case .finalizing:
            amplitude = 0.24
        case .hidden:
            amplitude = 0
        }
        let multipliers: [CGFloat] = [0.6, 0.85, 1, 0.85, 0.6]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in waveformLayers.enumerated() {
            let height = 4 + 12 * amplitude * multipliers[index]
            bar.frame.size.height = height
            bar.frame.origin.y = (Self.panelSize.height - height) / 2
            bar.backgroundColor = state.isFinalizing
                ? NSColor.colorWith(hex: MuesliTheme.transcribingHex, alpha: 0.82).cgColor
                : NSColor.white.withAlphaComponent(state == .paused ? 0.42 : 0.82).cgColor
        }
        CATransaction.commit()
    }

    private static func formattedElapsed(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }

    private func showTranscript() {
        guard let panel else { return }
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) })?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
        guard let visibleFrame else { return }
        transcriptPanel.show(beside: panel.frame, in: visibleFrame)
        refreshTranscriptButton()
    }

    private func hideTranscript(reset: Bool = false) {
        if reset {
            transcriptPanel.reset()
        } else {
            transcriptPanel.hide()
        }
        refreshTranscriptButton()
    }

    private func refreshTranscriptButton() {
        let selected = transcriptPanel.isVisible
        transcriptButton?.contentTintColor = selected
            ? .colorWith(hex: MuesliTheme.resolvedAccentDarkHex, alpha: 0.95)
            : .white.withAlphaComponent(0.86)
        transcriptButton?.setAccessibilityLabel(selected ? "Hide live transcript" : "Show live transcript")
    }

    private func reconcilePanelToAttachedScreens() {
        guard let panel, panel.isVisible else { return }
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let frame = Self.resolvedFrame(
            savedCenter: center,
            size: panel.frame.size,
            screens: NSScreen.screens.map(\.visibleFrame)
        )
        panel.setFrame(frame, display: true)
    }

    @objc private func transcriptButtonPressed() {
        toggleTranscriptPanel()
    }

    @objc private func pauseButtonPressed() {
        guard state == .recording || state == .paused else { return }
        onTogglePause?()
    }

    @objc private func stopButtonPressed() {
        guard state == .recording || state == .paused else { return }
        onStop?()
    }
}

private extension MeetingRecordingPanelState {
    var isFinalizing: Bool {
        if case .finalizing = self { return true }
        return false
    }
}
