import AppKit
import QuartzCore

/// Pure visibility policy for the meeting Record pill. It exists only while a meeting app
/// is actively in use and no meeting recording is running or starting.
enum MeetingRecordButtonPolicy {
    static func shouldShow(
        enabled: Bool,
        monitorsAllowed: Bool,
        hasActivityCandidate: Bool,
        candidateDismissed: Bool,
        isRecording: Bool,
        isStartingRecording: Bool
    ) -> Bool {
        enabled
            && monitorsAllowed
            && hasActivityCandidate
            && !candidateDismissed
            && !isRecording
            && !isStartingRecording
    }
}

enum MeetingRecordButtonPalette {
    static let glassTintHex = DictationMiniPalette.glassTintHex
    static let recordHex = DictationMiniPalette.accentHex
    static let recordHighlightHex = DictationMiniPalette.accentHighlightHex
    static let inkHex = DictationMiniPalette.inkHex
    static let glassTintAlpha: CGFloat = 0.62
    static let hoverGlassTintAlpha: CGFloat = 0.50
    static let edgeAlpha: CGFloat = 0.16
}

@MainActor
private final class MeetingRecordButtonContentView: NSView {
    weak var owner: MeetingRecordButtonController?
    private var trackingAreaRef: NSTrackingArea?
    private var mouseDownScreenLocation: NSPoint?
    private var didDrag = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { owner?.setHovered(true) }
    override func mouseExited(with event: NSEvent) { owner?.setHovered(false) }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        mouseDownScreenLocation = NSEvent.mouseLocation
        owner?.setPressed(true)
        owner?.pointerInteractionBegan(at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownScreenLocation else { return }
        let current = NSEvent.mouseLocation
        guard didDrag || hypot(current.x - mouseDownScreenLocation.x, current.y - mouseDownScreenLocation.y) >= 6 else {
            return
        }
        if !didDrag { owner?.setPressed(false) }
        didDrag = true
        owner?.pointerDragged(to: current)
    }

    override func mouseUp(with event: NSEvent) {
        owner?.setPressed(false)
        if event.modifierFlags.contains(.option) {
            owner?.dismissRequested()
        } else {
            owner?.pointerInteractionEnded(didDrag: didDrag)
        }
        mouseDownScreenLocation = nil
        didDrag = false
    }

    override func rightMouseUp(with event: NSEvent) {
        owner?.dismissRequested()
    }
}

/// A compact draggable "Record" pill that appears while a meeting app is active and starts
/// a meeting recording with one click. It hands off to the Meeting Recording Panel, which
/// owns pause/stop/transcript; the pill never shows during a recording.
@MainActor
final class MeetingRecordButtonController: NSObject {
    /// Matches the Dictation Mini's 22 pt capsule height; "● Record" at 11 pt fits in 72 pt.
    nonisolated static let pillSize = NSSize(width: 72, height: 22)
    nonisolated static let recordDotDiameter: CGFloat = 8

    var onRecord: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onCenterSaved: ((CGPoint) -> Void)?

    private(set) var platformName: String?
    private var savedCenter: CGPoint?
    private var panel: InteractiveFloatingPanel?
    private var contentView: MeetingRecordButtonContentView?
    private var glassView: NSVisualEffectView?
    /// Hosts the tint and record-dot layers above the glass: AppKit keeps subview layers
    /// above hand-added sublayers, so decor must live in its own layer-backed view.
    private let decorView = NSView()
    private let tintLayer = CALayer()
    private let dotLayer = CAShapeLayer()
    private let coreLayer = CAShapeLayer()
    private var label: NSTextField?
    private var isHovered = false
    private var isPressed = false
    private var dragWindowOrigin: NSPoint?
    private var dragPointerOrigin: NSPoint?
    private var dragScreenFrames: [NSRect] = []
    private var accessibilityObserver: NSObjectProtocol?

    override init() {
        super.init()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyChrome() }
        }
    }

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    var isVisible: Bool { panel?.isVisible == true }
    var frameForTesting: NSRect? { panel?.frame }
    var isHoveredForTesting: Bool { isHovered }
    var accessibilityLabelForTesting: String? { contentView?.accessibilityLabel() }

    func applySavedCenter(_ center: CGPoint?) {
        savedCenter = center
    }

    func show(platformName: String?) {
        self.platformName = platformName
        let panel = panel ?? makePanel()
        self.panel = panel
        let frame = MeetingRecordingPanelController.resolvedFrame(
            savedCenter: savedCenter,
            size: Self.pillSize,
            screens: NSScreen.screens.map(\.visibleFrame)
        )
        panel.setFrame(frame, display: true)
        applyChrome()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        isHovered = false
        isPressed = false
    }

    func close() {
        hide()
        panel?.contentView = nil
        panel = nil
        contentView = nil
        glassView = nil
        label = nil
    }

    // MARK: Pointer

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        applyChrome()
    }

    func setPressed(_ pressed: Bool) {
        guard isPressed != pressed else { return }
        isPressed = pressed
        applyChrome()
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
        panel.setFrameOrigin(MeetingRecordingPanelController.clampedDragOrigin(
            proposed,
            size: panel.frame.size,
            screens: dragScreenFrames
        ))
    }

    func pointerInteractionEnded(didDrag: Bool) {
        defer {
            dragWindowOrigin = nil
            dragPointerOrigin = nil
            dragScreenFrames.removeAll()
        }
        if didDrag {
            guard let frame = panel?.frame else { return }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            savedCenter = center
            onCenterSaved?(center)
            return
        }
        onRecord?()
    }

    func dismissRequested() {
        onDismiss?()
    }

    // MARK: Chrome

    private func makePanel() -> InteractiveFloatingPanel {
        let panel = InteractiveFloatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.pillSize),
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

        let content = MeetingRecordButtonContentView(frame: NSRect(origin: .zero, size: Self.pillSize))
        content.owner = self
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.pillSize.height / 2
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.setAccessibilityElement(true)
        content.setAccessibilityRole(.button)
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

        decorView.frame = content.bounds
        decorView.autoresizingMask = [.width, .height]
        decorView.wantsLayer = true
        content.addSubview(decorView)
        tintLayer.frame = content.bounds
        tintLayer.cornerRadius = Self.pillSize.height / 2
        tintLayer.cornerCurve = .continuous
        decorView.layer?.addSublayer(tintLayer)

        let dotDiameter = Self.recordDotDiameter
        let dotRect = CGRect(
            x: 9,
            y: (Self.pillSize.height - dotDiameter) / 2,
            width: dotDiameter,
            height: dotDiameter
        )
        dotLayer.path = CGPath(ellipseIn: dotRect, transform: nil)
        dotLayer.shadowOffset = .zero
        dotLayer.shadowRadius = 3
        decorView.layer?.addSublayer(dotLayer)
        coreLayer.path = CGPath(ellipseIn: dotRect.insetBy(dx: 2.5, dy: 2.5).offsetBy(dx: -0.4, dy: 0.4), transform: nil)
        decorView.layer?.addSublayer(coreLayer)

        let text = NSTextField(labelWithString: "Record")
        text.font = .systemFont(ofSize: 11, weight: .semibold)
        text.alignment = .left
        text.lineBreakMode = .byClipping
        text.frame = NSRect(x: 22, y: (Self.pillSize.height - 14) / 2 - 0.5, width: Self.pillSize.width - 28, height: 14)
        content.addSubview(text)
        label = text
        return panel
    }

    private func applyChrome() {
        guard let contentView else { return }
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        glassView?.isHidden = reduceTransparency

        // Pressed darkens the ground slightly; hover lifts it. No transform, so the
        // view-backed layer's (0,0) anchor never shifts the content.
        let restingAlpha = isHovered
            ? MeetingRecordButtonPalette.hoverGlassTintAlpha
            : MeetingRecordButtonPalette.glassTintAlpha
        let tintAlpha = reduceTransparency ? 1 : (isPressed ? restingAlpha + 0.16 : restingAlpha)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.backgroundColor = NSColor.colorWith(
            hex: MeetingRecordButtonPalette.glassTintHex,
            alpha: tintAlpha
        ).cgColor
        contentView.layer?.borderWidth = increaseContrast ? 2 : 1
        contentView.layer?.borderColor = NSColor.white.withAlphaComponent(
            increaseContrast ? 0.82 : MeetingRecordButtonPalette.edgeAlpha
        ).cgColor

        let record = NSColor.colorWith(hex: MeetingRecordButtonPalette.recordHex, alpha: 1)
        let highlight = NSColor.colorWith(hex: MeetingRecordButtonPalette.recordHighlightHex, alpha: 1)
        dotLayer.fillColor = record.cgColor
        dotLayer.shadowColor = record.withAlphaComponent(isHovered ? 0.62 : 0.42).cgColor
        dotLayer.shadowOpacity = increaseContrast ? 0.3 : 1
        coreLayer.fillColor = highlight.withAlphaComponent(isHovered ? 0.95 : 0.78).cgColor
        CATransaction.commit()

        let inkAlpha: CGFloat = isPressed ? 0.8 : (isHovered ? 1 : 0.92)
        label?.textColor = NSColor.colorWith(hex: MeetingRecordButtonPalette.inkHex, alpha: inkAlpha)
        let platform = platformName.map { "\($0) meeting" } ?? "meeting"
        contentView.setAccessibilityLabel("Record \(platform)")
        contentView.setAccessibilityHelp("Click to start recording. Drag to move. Option-click to hide until this meeting ends.")
        contentView.toolTip = "Record \(platform)"
    }
}
