import AppKit

/// A small mouse-transparent glass pill that sits beside the Dictation Mini: hotkey keycaps on
/// hover, the selection hint, and short toasts. One panel, one label; callers decide the text.
@MainActor
final class DictationMiniHintPanel {
    static let height: CGFloat = 22
    static let gap: CGFloat = 6
    static let horizontalPadding: CGFloat = 10

    private var panel: NSPanel?
    private var contentView: NSView?
    private var glassView: NSVisualEffectView?
    private let tintLayer = CALayer()
    private var label: NSTextField?
    private var dismissTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private(set) var text: String?

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows `text` beside `frame` (AppKit coordinates). `duration` nil keeps it until `hide()`.
    func show(_ text: String, beside frame: CGRect, on screens: [CGRect], duration: TimeInterval?) {
        self.text = text
        generation &+= 1
        let token = generation
        dismissTask?.cancel()
        dismissTask = nil
        let panel = panel ?? makePanel()
        self.panel = panel
        label?.stringValue = text
        let textWidth = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
        let width = ceil(textWidth + Self.horizontalPadding * 2)
        let size = NSSize(width: width, height: Self.height)
        let target = Self.placement(beside: frame, size: size, screens: screens)
        panel.setFrame(target, display: true)
        contentView?.frame = NSRect(origin: .zero, size: size)
        label?.frame = NSRect(x: Self.horizontalPadding, y: (Self.height - 14) / 2 - 0.5, width: width - Self.horizontalPadding * 2, height: 14)
        tintLayer.frame = NSRect(origin: .zero, size: size)
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
        guard let panel, panel.isVisible else { return }
        generation &+= 1
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

    func close() {
        dismissTask?.cancel()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        contentView = nil
        glassView = nil
        label = nil
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

        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 11, weight: .semibold)
        text.alignment = .left
        text.lineBreakMode = .byClipping
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
            alpha: reduceTransparency ? 1 : DictationMiniRendering.recordingGlassTintAlpha
        ).cgColor
        contentView?.layer?.borderWidth = increaseContrast ? 2 : 1
        contentView?.layer?.borderColor = NSColor.white.withAlphaComponent(increaseContrast ? 0.82 : 0.16).cgColor
        CATransaction.commit()
        label?.textColor = NSColor.colorWith(hex: DictationMiniPalette.inkHex, alpha: 0.94)
    }
}
