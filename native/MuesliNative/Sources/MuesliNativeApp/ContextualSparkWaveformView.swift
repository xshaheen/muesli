import AppKit
import QuartzCore

/// The Contextual Spark wave: a field of one-point bars lit by the seeded spark engine, over a
/// coral halo that tracks the live level. Hoisted out of the Dictation Mini so every size of the
/// merged meeting object renders the same wave; geometry is parameterised, the palette is not.
final class ContextualSparkWaveformView: NSView {
    private var bars: [CALayer] = []
    private let haloLayer = CAGradientLayer()
    private var engine: DictationMiniSpikeEngine
    private let barWidth: CGFloat
    private let barPitch: CGFloat
    private let minHeight: CGFloat
    private let maxHeight: CGFloat
    private var backingScale: CGFloat = 2
    /// The accessibility flags and the palette colours are read once and cached rather than per
    /// frame: this view redraws 30 times a second for the whole length of a meeting, and both
    /// `NSWorkspace` reads and `NSColor` construction are far from free at that cadence.
    /// `refreshAccessibilityPresentation()` is the single refresh point, and every owner already
    /// calls it from `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    private let accentColor = NSColor.colorWith(hex: DictationMiniPalette.accentHex, alpha: 1)
    private let highlightColor = NSColor.colorWith(hex: DictationMiniPalette.accentHighlightHex, alpha: 1)
    /// Smoothed live level: drives the halo.
    var power: CGFloat = 0 { didSet { updateBars() } }

    var barLevelsForTesting: [CGFloat] { engine.bars }

    init(
        frame frameRect: NSRect = .zero,
        barCount: Int = DictationMiniRendering.recordingBarCount,
        barWidth: CGFloat = DictationMiniRendering.recordingBarWidth,
        barPitch: CGFloat = DictationMiniRendering.recordingBarPitch,
        minHeight: CGFloat = DictationMiniRendering.recordingBarMinHeight,
        maxHeight: CGFloat = DictationMiniRendering.recordingBarMaxHeight,
        seed: UInt64 = DictationMiniSpikeEngine.defaultSeed
    ) {
        self.barWidth = barWidth
        self.barPitch = barPitch
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        engine = DictationMiniSpikeEngine(count: barCount, seed: seed)
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
        for _ in 0..<max(barCount, 1) {
            let bar = CALayer()
            bar.cornerRadius = barWidth / 2
            bar.allowsEdgeAntialiasing = true
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        applyBarColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Advances the spark engine first so the single `power` redraw sees the fresh bar state.
    func advance(level: CGFloat) {
        engine.advance(level: level)
        power = level
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
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        applyBarColors()
        updateBars()
    }

    private func applyBarColors() {
        let quietAlpha = increaseContrast ? 0.8 : DictationMiniRendering.recordingQuietAlpha
        // Lit bars warm toward amber and brighten; quiet bars rest as muted orange.
        for (index, bar) in bars.enumerated() {
            let level = engine.bars.indices.contains(index) ? engine.bars[index] : 0
            let color = accentColor.blended(withFraction: level * 0.85, of: highlightColor) ?? accentColor
            bar.backgroundColor = color.withAlphaComponent(quietAlpha + (1 - quietAlpha) * min(1, level * 1.6)).cgColor
        }
    }

    private func updateBars() {
        guard !bars.isEmpty else { return }
        let fieldWidth = CGFloat(bars.count - 1) * barPitch + barWidth
        let startX = DictationMiniRendering.pixelAligned(bounds.midX - fieldWidth / 2, scale: backingScale)
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
                x: DictationMiniRendering.pixelAligned(startX + CGFloat(index) * barPitch, scale: backingScale),
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
