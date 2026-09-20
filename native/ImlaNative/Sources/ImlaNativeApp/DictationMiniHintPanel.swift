import AppKit

/// Hints stay mouse-transparent; explicit recovery actions use the same nonactivating surface
/// so copying a retained dictation does not take focus away from the user's editor.
@MainActor
final class DictationMiniHintPanel {
    enum Kind { case general, destination, recovery }
    enum ActionStyle { case primary, secondary, dismiss }
    struct Action {
        let title: String
        var symbol: String? = nil
        var accessibilityLabel: String? = nil
        var style: ActionStyle = .secondary
        let perform: () -> Void
    }
    static let height: CGFloat = 22
    static let gap: CGFloat = 6
    static let horizontalPadding: CGFloat = 10

    private var panel: NSPanel?
    private var contentView: NSView?
    private var glassView: NSVisualEffectView?
    private let tintLayer = CALayer()
    private let dividerLayer = CALayer()
    private var label: NSTextField?
    private var dismissTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private(set) var text: String?
    private(set) var kind: Kind = .general
    private var buttons: [DictationHintButton] = []

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows `text` beside `frame` (AppKit coordinates). `duration` nil keeps it until `hide()`.
    func show(
        _ text: String, beside frame: CGRect, on screens: [CGRect], duration: TimeInterval?,
        kind: Kind = .general, actions: [Action] = []
    ) {
        self.text = text
        self.kind = kind
        generation &+= 1
        let token = generation
        dismissTask?.cancel()
        dismissTask = nil
        let panel = panel ?? makePanel()
        self.panel = panel
        buttons.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        panel.ignoresMouseEvents = actions.isEmpty
        for action in actions {
            let button = DictationHintButton(title: action.title, target: nil, action: nil)
            button.isBordered = false
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.appearance = NSAppearance(named: .darkAqua)
            button.style = action.style
            button.setAccessibilityLabel(action.accessibilityLabel ?? action.title)
            button.toolTip = action.accessibilityLabel ?? action.title
            if let symbol = action.symbol {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
                button.imagePosition = action.title.isEmpty ? .imageOnly : .imageLeading
            }
            button.onPress = { [weak self] in
                guard let self, self.generation == token, self.text != nil else { return }
                action.perform()
            }
            button.target = button
            button.action = #selector(DictationHintButton.pressed)
            button.frame.size = NSSize(
                width: action.style == .dismiss ? 24 : max(44, ceil(button.fittingSize.width) + 16),
                height: 24
            )
            button.refreshChrome()
            contentView?.addSubview(button)
            buttons.append(button)
        }
        label?.stringValue = text
        // NSTextField's cell needs more room than an NSString glyph measurement; measuring the
        // real control avoids truncating a message even when the window has space for it.
        let textSize = label?.fittingSize ?? .zero
        let availableWidth = (screens.first(where: { $0.intersects(frame) }) ?? screens.first)?.width ?? 800
        let layout = Self.layout(textSize: textSize, buttonWidths: buttons.map { $0.frame.width }, maximumWidth: availableWidth - 8)
        let size = layout.size
        let target = Self.placement(beside: frame, size: size, screens: screens)
        panel.setFrame(target, display: true)
        contentView?.frame = NSRect(origin: .zero, size: size)
        label?.frame = layout.label
        for (button, frame) in zip(buttons, layout.buttons) {
            button.frame = frame
        }
        tintLayer.frame = NSRect(origin: .zero, size: size)
        dividerLayer.isHidden = layout.divider == nil
        dividerLayer.frame = layout.divider ?? .zero
        contentView?.layer?.cornerRadius = actions.isEmpty ? 11 : 12
        tintLayer.cornerRadius = actions.isEmpty ? 11 : 12
        applyChrome()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            panel.animator().alphaValue = 1
        }
        if let duration {
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(duration, 0)))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.generation == token else { return }
                    self.hide()
                }
            }
        }
    }

    func move(beside frame: CGRect, on screens: [CGRect]) {
        guard let panel, panel.isVisible else { return }
        let target = Self.placement(beside: frame, size: panel.frame.size, screens: screens)
        panel.setFrame(target, display: true)
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        text = nil
        generation &+= 1
        buttons.forEach { $0.onPress = nil }
        guard let panel, panel.isVisible else { return }
        panel.ignoresMouseEvents = true
        let token = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    func hide(ifKind expected: Kind) {
        if kind == expected { hide() }
    }

    var actionButtonsForTesting: [NSButton] { buttons }
    var labelForTesting: NSTextField? { label }
    var isMouseTransparentForTesting: Bool { panel?.ignoresMouseEvents ?? true }

    func close() {
        hide()
        dismissTask?.cancel()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        contentView = nil
        glassView = nil
        label = nil
        buttons.removeAll()
    }

    struct Layout {
        let size: NSSize
        let label: NSRect
        let buttons: [NSRect]
        let divider: NSRect?
    }

    nonisolated static func layout(textSize: NSSize, buttonWidths: [CGFloat], maximumWidth: CGFloat) -> Layout {
        let available = max(24, maximumWidth)
        let padding: CGFloat = buttonWidths.isEmpty ? horizontalPadding : 12
        let textWidth = ceil(textSize.width) + 2
        let textHeight = ceil(textSize.height)
        guard !buttonWidths.isEmpty else {
            let width = min(available, textWidth + padding * 2)
            return Layout(size: NSSize(width: width, height: height), label: NSRect(
                x: padding, y: (height - textHeight) / 2, width: max(0, width - padding * 2), height: textHeight
            ), buttons: [], divider: nil)
        }
        let actionGap: CGFloat = 4
        let sectionGap: CGFloat = 18
        let gaps = CGFloat(buttonWidths.count - 1) * actionGap
        let controlsWidth = buttonWidths.reduce(0, +) + gaps
        let stacked = textWidth + sectionGap + controlsWidth + padding * 2 > available
        let width = min(available, (stacked ? max(textWidth, controlsWidth) : textWidth + sectionGap + controlsWidth) + padding * 2)
        let height: CGFloat = stacked ? 62 : 36
        let labelWidth = stacked ? width - padding * 2 : textWidth
        let label = NSRect(x: padding, y: stacked ? 37 : (height - textHeight) / 2, width: max(0, labelWidth), height: textHeight)
        var x = stacked ? padding : label.maxX + sectionGap
        let scale = min(1, max(0, width - padding * 2 - gaps) / max(1, buttonWidths.reduce(0, +)))
        let frames = buttonWidths.map { buttonWidth in
            let frame = NSRect(x: x, y: 6, width: buttonWidth * scale, height: 24)
            x = frame.maxX + actionGap
            return frame
        }
        let divider = stacked ? nil : NSRect(x: label.maxX + 9, y: 11, width: 0.5, height: 14)
        return Layout(size: NSSize(width: width, height: height), label: label, buttons: frames, divider: divider)
    }

    /// To the right of the Mini, vertically centred; flips to the left when it would leave the screen.
    nonisolated static func placement(beside frame: CGRect, size: NSSize, screens: [CGRect]) -> NSRect {
        let y = frame.midY - size.height / 2
        var x = frame.maxX + gap
        let screen = screens.first(where: { $0.intersects(frame) }) ?? screens.first
        if let screen, x + size.width > screen.maxX - 4 {
            x = frame.minX - gap - size.width
        }
        var rect = NSRect(x: x, y: y, width: size.width, height: size.height)
        if let screen {
            rect.origin.x = min(max(rect.minX, screen.minX + 4), screen.maxX - 4 - size.width)
            rect.origin.y = min(max(rect.minY, screen.minY + 4), screen.maxY - 4 - size.height)
        }
        return rect
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = NSView(frame: panel.contentView?.bounds ?? .zero)
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.height / 2
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

        let decor = NSView(frame: content.bounds)
        decor.autoresizingMask = [.width, .height]
        decor.wantsLayer = true
        tintLayer.cornerRadius = Self.height / 2
        tintLayer.cornerCurve = .continuous
        decor.layer?.addSublayer(tintLayer)
        content.addSubview(decor)
        decor.layer?.addSublayer(dividerLayer)

        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 11, weight: .medium)
        text.alignment = .left
        text.lineBreakMode = .byTruncatingTail
        content.addSubview(text)
        label = text
        return panel
    }

    private func applyChrome() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        glassView?.isHidden = reduceTransparency
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.backgroundColor = NSColor.colorWith(
            hex: DictationMiniPalette.glassTintHex,
            alpha: reduceTransparency ? 1 : 0.88
        ).cgColor
        contentView?.layer?.borderWidth = increaseContrast ? 2 : 0.5
        contentView?.layer?.borderColor = NSColor.white.withAlphaComponent(increaseContrast ? 0.82 : 0.18).cgColor
        dividerLayer.backgroundColor = NSColor.white.withAlphaComponent(increaseContrast ? 0.6 : 0.12).cgColor
        CATransaction.commit()
        label?.textColor = NSColor.colorWith(hex: DictationMiniPalette.inkHex, alpha: 0.94)
    }
}

@MainActor
private final class DictationHintButton: NSButton {
    var onPress: (() -> Void)?
    var style: DictationMiniHintPanel.ActionStyle = .secondary
    private var hovered = false
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isHighlighted: Bool { didSet { refreshChrome() } }
    @objc func pressed() { onPress?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; refreshChrome() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshChrome() }

    func refreshChrome() {
        wantsLayer = true
        let primary = style == .primary
        let active = hovered || isHighlighted
        contentTintColor = NSColor.white.withAlphaComponent(primary ? 0.96 : (active ? 0.95 : 0.7))
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.white.withAlphaComponent(
            isHighlighted ? 0.22 : (primary ? (hovered ? 0.18 : 0.12) : (hovered ? 0.08 : 0))
        ).cgColor
        layer?.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.65).cgColor
    }
}
