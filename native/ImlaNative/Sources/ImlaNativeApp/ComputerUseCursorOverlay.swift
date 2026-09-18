import AppKit

/// The sole floating-surface owner for computer-use commands.
@MainActor
final class ComputerUseCursorOverlay: NSObject {
    enum TerminalKind: Equatable { case success, warning, failure }

    enum Presentation: Equatable {
        case hidden
        case acquiring
        case recording
        case processing(String)
        case transcript(String)
        case status(String)
        case target(String)
        case terminal(String, TerminalKind)
    }

    static let shared = ComputerUseCursorOverlay()

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private(set) var presentation: Presentation = .hidden
    private var basePresentation: Presentation = .hidden
    private var panel: NSPanel?
    private var contentView: ComputerUseOverlayView?
    private var amplitudeTimer: Timer?
    private var powerProvider: (() -> Float)?
    private var dismissTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var anchorPoint: CGPoint?
    private var accessibilityObserver: NSObjectProtocol?

    private override init() {
        super.init()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.contentView?.needsDisplay = true }
        }
    }

    func showAcquiring() {
        showBase(.acquiring)
    }

    func showRecording(powerProvider: @escaping () -> Float) {
        self.powerProvider = powerProvider
        showBase(.recording)
        startAmplitudeTimer()
    }

    func showProcessing(_ status: String) {
        showBase(.processing(status))
    }

    func showTranscript(_ transcript: String) {
        showBase(.transcript(Self.normalizedText(transcript)))
    }

    func showStatus(_ status: String) {
        showBase(.status(Self.normalizedText(status)))
    }

    func showTarget(at quartzPoint: CGPoint, label: String?) {
        dismissTask?.cancel()
        generation &+= 1
        let label = Self.normalizedText(label ?? "")
        presentation = .target(label)
        let size = Self.cursorSize(label: label)
        let panel = ensurePanel(size: size)
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        contentView?.presentation = presentation
        contentView?.power = 0
        panel.setFrame(
            Self.cursorFrame(
                forQuartzPoint: quartzPoint,
                size: size,
                offsetFromTarget: !label.isEmpty,
                screens: NSScreen.screens.map(\.frame),
                visibleFrames: NSScreen.screens.map(\.visibleFrame)
            ),
            display: true
        )
        panel.orderFrontRegardless()
    }

    func hideTarget() {
        guard case .target = presentation else { return }
        applyBasePresentation()
    }

    func showTerminal(_ message: String, kind: TerminalKind, duration: TimeInterval = 3) {
        showBase(.terminal(Self.normalizedText(message), kind))
        let terminalGeneration = generation
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == terminalGeneration else { return }
                self.hide()
            }
        }
    }

    func hide() {
        generation &+= 1
        dismissTask?.cancel()
        dismissTask = nil
        stopAmplitudeTimer(clearProvider: true)
        presentation = .hidden
        basePresentation = .hidden
        anchorPoint = nil
        panel?.orderOut(nil)
    }

    func close() {
        hide()
        panel?.close()
        panel = nil
        contentView = nil
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
    }

    private func showBase(_ presentation: Presentation) {
        generation &+= 1
        dismissTask?.cancel()
        dismissTask = nil
        basePresentation = presentation
        self.presentation = presentation
        if presentation != .recording {
            stopAmplitudeTimer(clearProvider: Self.isTerminal(presentation))
        }
        if anchorPoint == nil { anchorPoint = NSEvent.mouseLocation }
        let size = Self.surfaceSize(for: presentation)
        let panel = ensurePanel(size: size)
        panel.ignoresMouseEvents = !presentation.isInteractive
        panel.level = presentation.isInteractive ? .floating : .statusBar
        contentView?.presentation = presentation
        contentView?.needsDisplay = true
        panel.setFrame(
            Self.surfaceFrame(
                near: anchorPoint ?? NSEvent.mouseLocation,
                size: size,
                visibleFrames: NSScreen.screens.map(\.visibleFrame)
            ),
            display: true
        )
        panel.orderFrontRegardless()
    }

    private func applyBasePresentation() {
        guard basePresentation != .hidden else { hide(); return }
        presentation = basePresentation
        let size = Self.surfaceSize(for: basePresentation)
        let panel = ensurePanel(size: size)
        panel.ignoresMouseEvents = !basePresentation.isInteractive
        panel.level = basePresentation.isInteractive ? .floating : .statusBar
        contentView?.presentation = basePresentation
        contentView?.needsDisplay = true
        panel.setFrame(
            Self.surfaceFrame(
                near: anchorPoint ?? NSEvent.mouseLocation,
                size: size,
                visibleFrames: NSScreen.screens.map(\.visibleFrame)
            ),
            display: true
        )
        panel.orderFrontRegardless()
        if basePresentation.isInteractive { startAmplitudeTimer() }
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = ComputerUseOverlayView(frame: CGRect(origin: .zero, size: size))
        view.owner = self
        panel.contentView = view
        self.panel = panel
        contentView = view
        return panel
    }

    private func startAmplitudeTimer() {
        amplitudeTimer?.invalidate()
        amplitudeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.presentation == .recording else { return }
                let decibels = self.powerProvider?() ?? -160
                let normalized = max(0, min(1, (CGFloat(decibels) + 55) / 55))
                let current = self.contentView?.power ?? 0
                self.contentView?.power = current + (normalized - current) * 0.35
                self.contentView?.needsDisplay = true
            }
        }
    }

    private func stopAmplitudeTimer(clearProvider: Bool) {
        amplitudeTimer?.invalidate()
        amplitudeTimer = nil
        if clearProvider { powerProvider = nil }
    }

    fileprivate func handleClick(at point: CGPoint) {
        guard presentation == .recording, let contentView else { return }
        if point.x >= contentView.bounds.maxX - 34 {
            onStop?()
        } else if point.x >= contentView.bounds.maxX - 68 {
            onCancel?()
        }
    }

    static func cursorFrame(
        forQuartzPoint point: CGPoint,
        size: CGSize,
        offsetFromTarget: Bool,
        screens: [CGRect],
        visibleFrames: [CGRect]
    ) -> CGRect {
        let primaryMaxY = screens.first?.maxY ?? 0
        let converted = CGPoint(x: point.x, y: primaryMaxY - point.y)
        let offset: CGFloat = offsetFromTarget ? 12 : 0
        let proposed = CGRect(
            x: converted.x - size.width / 2 + offset,
            y: converted.y - size.height / 2 - offset,
            width: size.width,
            height: size.height
        )
        guard let index = screens.firstIndex(where: { $0.contains(converted) }),
              visibleFrames.indices.contains(index) else { return proposed }
        return clamped(proposed, to: visibleFrames[index])
    }

    static func surfaceFrame(near point: CGPoint, size: CGSize, visibleFrames: [CGRect]) -> CGRect {
        let proposed = CGRect(x: point.x + 18, y: point.y - size.height - 18, width: size.width, height: size.height)
        let visible = visibleFrames.first(where: { $0.contains(point) }) ?? visibleFrames.first
        return visible.map { clamped(proposed, to: $0) } ?? proposed
    }

    static func cursorSize(label: String) -> CGSize {
        guard !label.isEmpty else { return CGSize(width: 30, height: 30) }
        return CGSize(width: min(max(CGFloat(label.count) * 7 + 42, 96), 280), height: 30)
    }

    static func surfaceSize(for presentation: Presentation) -> CGSize {
        switch presentation {
        case .hidden: return .zero
        case .acquiring: return CGSize(width: 96, height: 30)
        case .recording: return CGSize(width: 170, height: 32)
        case .processing(let text), .status(let text), .terminal(let text, _):
            return CGSize(width: min(max(CGFloat(text.count) * 7 + 34, 92), 360), height: 30)
        case .transcript(let text):
            let width = min(max(CGFloat(text.count) * 6.5 + 32, 140), 420)
            let lines = max(1, ceil((CGFloat(text.count) * 6.5) / max(width - 24, 1)))
            return CGSize(width: width, height: min(22 + lines * 18, 180))
        case .target(let label): return cursorSize(label: label)
        }
    }

    private static func clamped(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        CGRect(
            x: min(max(frame.minX, bounds.minX), max(bounds.minX, bounds.maxX - frame.width)),
            y: min(max(frame.minY, bounds.minY), max(bounds.minY, bounds.maxY - frame.height)),
            width: frame.width,
            height: frame.height
        )
    }

    private static func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isTerminal(_ presentation: Presentation) -> Bool {
        if case .terminal = presentation { return true }
        return false
    }
}

private final class ComputerUseOverlayView: NSView {
    weak var owner: ComputerUseCursorOverlay?
    var presentation: ComputerUseCursorOverlay.Presentation = .hidden
    var power: CGFloat = 0

    override var isOpaque: Bool { false }

    override func mouseUp(with event: NSEvent) {
        guard presentation.isInteractive else { return }
        owner?.handleClick(at: convert(event.locationInWindow, from: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard presentation != .hidden else { return }
        let style = FloatingIndicatorSurfaceStyle.resolve(
            role: .computerUse,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        let surface = bounds.insetBy(dx: 1, dy: 1)
        NSColor.colorWith(hexString: style.tintHex, alpha: style.tintAlpha).setFill()
        NSBezierPath(roundedRect: surface, xRadius: surface.height / 2, yRadius: surface.height / 2).fill()
        NSColor.colorWith(hexString: style.borderHex, alpha: style.borderAlpha).setStroke()
        let border = NSBezierPath(roundedRect: surface, xRadius: surface.height / 2, yRadius: surface.height / 2)
        border.lineWidth = style.borderWidth
        border.stroke()

        switch presentation {
        case .recording:
            drawWaveform(style: style)
            drawText("×", in: CGRect(x: bounds.maxX - 68, y: 5, width: 34, height: 22), style: style)
            drawText("■", in: CGRect(x: bounds.maxX - 34, y: 5, width: 34, height: 22), style: style)
        case .target(let label): drawTarget(label: label, style: style)
        case .acquiring: drawText("Preparing", in: bounds.insetBy(dx: 12, dy: 5), style: style)
        case .processing(let text), .status(let text), .transcript(let text):
            drawText(text, in: bounds.insetBy(dx: 12, dy: 6), style: style, wraps: true)
        case .terminal(let text, let kind):
            let color: NSColor = kind == .failure ? .systemRed : (kind == .warning ? .systemOrange : .systemGreen)
            drawText(text, in: bounds.insetBy(dx: 12, dy: 5), style: style, color: color)
        case .hidden: break
        }
    }

    private func drawWaveform(style: FloatingIndicatorSurfaceStyle) {
        let available = CGRect(x: 14, y: 7, width: bounds.width - 88, height: bounds.height - 14)
        NSColor.colorWith(hexString: style.glyphHex, alpha: style.glyphAlpha).setFill()
        for index in 0..<7 {
            let phase = CGFloat(index) / 6
            let height = max(3, available.height * (0.2 + power * (0.35 + 0.45 * sin(phase * .pi))))
            let rect = CGRect(x: available.minX + phase * available.width - 1.5, y: available.midY - height / 2, width: 3, height: height)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawTarget(label: String, style: FloatingIndicatorSurfaceStyle) {
        let diameter = min(bounds.height - 8, 22)
        let circle = CGRect(x: 5, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        NSColor.systemBlue.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSColor.systemBlue.setStroke()
        let ring = NSBezierPath(ovalIn: circle)
        ring.lineWidth = 2
        ring.stroke()
        guard !label.isEmpty else { return }
        drawText(label, in: CGRect(x: circle.maxX + 7, y: 4, width: bounds.maxX - circle.maxX - 12, height: bounds.height - 8), style: style)
    }

    private func drawText(_ text: String, in rect: CGRect, style: FloatingIndicatorSurfaceStyle, wraps: Bool = false, color: NSColor? = nil) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: color ?? NSColor.colorWith(hexString: style.glyphHex, alpha: style.glyphAlpha),
            .paragraphStyle: paragraph,
        ]
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

}

private extension ComputerUseCursorOverlay.Presentation {
    var isInteractive: Bool { self == .recording }
}
