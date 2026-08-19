import AppKit
import QuartzCore

/// The Contextual Spark glass recipe as a pure value: dark HUD material under a tint layer,
/// a hairline white edge, and a continuous corner radius. Resolving is separated from the
/// view so the accessibility fallbacks stay testable without AppKit state.
struct ContextualSparkSurfaceStyle: Equatable {
    let tintHex: Int
    let tintColorAlpha: CGFloat
    let cornerRadius: CGFloat
    let borderWidth: CGFloat
    let borderAlpha: CGFloat
    let usesGlassEffect: Bool

    static func resolve(
        tintHex: Int = DictationMiniPalette.glassTintHex,
        tintAlpha: CGFloat = DictationMiniRendering.recordingGlassTintAlpha,
        cornerRadius: CGFloat,
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false
    ) -> Self {
        Self(
            tintHex: tintHex,
            // Reduce Transparency drops the material, so the tint alone has to carry the
            // ground: it goes fully opaque rather than letting the page show through.
            tintColorAlpha: reduceTransparency ? 1 : tintAlpha,
            cornerRadius: cornerRadius,
            borderWidth: increaseContrast ? 2 : 1,
            borderAlpha: increaseContrast ? 0.82 : 0.16,
            usesGlassEffect: !reduceTransparency
        )
    }
}

/// The reusable Contextual Spark surface: a layer-backed host that owns the HUD glass, the
/// tint above it, the edge and the radius. Callers add their own artwork through `decorLayer`,
/// which sits above the tint.
@MainActor
final class ContextualSparkGlassSurfaceView: NSView {
    private let glassView = NSVisualEffectView()
    /// The tint and caller decor live in their own layer-backed view rather than in the host's
    /// layer: AppKit keeps subview layers above hand-added sublayers, so decor added to the
    /// host would otherwise be painted under the glass.
    private let decorView = NSView()
    private let tintLayer = CALayer()
    private let decorContainer = CALayer()

    private var cornerRadius: CGFloat
    private let tintHex: Int
    private var tintAlpha: CGFloat
    private(set) var resolvedStyleForTesting: ContextualSparkSurfaceStyle

    /// Artwork added here is drawn above the glass and the tint, in the surface's own
    /// coordinate space.
    var decorLayer: CALayer { decorContainer }

    init(
        cornerRadius: CGFloat,
        tintHex: Int = DictationMiniPalette.glassTintHex,
        tintAlpha: CGFloat = DictationMiniRendering.recordingGlassTintAlpha
    ) {
        self.cornerRadius = cornerRadius
        self.tintHex = tintHex
        self.tintAlpha = tintAlpha
        resolvedStyleForTesting = ContextualSparkSurfaceStyle.resolve(
            tintHex: tintHex,
            tintAlpha: tintAlpha,
            cornerRadius: cornerRadius
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        glassView.material = .hudWindow
        glassView.blendingMode = .behindWindow
        glassView.state = .active
        glassView.appearance = NSAppearance(named: .darkAqua)
        glassView.autoresizingMask = [.width, .height]
        addSubview(glassView)

        decorView.wantsLayer = true
        decorView.autoresizingMask = [.width, .height]
        addSubview(decorView)
        decorView.layer?.addSublayer(tintLayer)
        decorView.layer?.addSublayer(decorContainer)

        refreshAccessibilityPresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateSublayerFrames()
    }

    /// Also sync on resize, not only in the layout pass: the tint is a hand-added layer, so a
    /// surface shown before its first layout would otherwise flash with no ground.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSublayerFrames()
    }

    private func updateSublayerFrames() {
        glassView.frame = bounds
        decorView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        decorContainer.frame = bounds
        CATransaction.commit()
    }

    /// The merged meeting object morphs between the pill radius and the panel radius.
    func apply(cornerRadius: CGFloat) {
        guard self.cornerRadius != cornerRadius else { return }
        self.cornerRadius = cornerRadius
        refreshAccessibilityPresentation()
    }

    /// Hover and pressed states ride the tint alpha, not a transform, so the layer's anchor
    /// never shifts the artwork above it.
    func apply(tintAlpha: CGFloat) {
        guard self.tintAlpha != tintAlpha else { return }
        self.tintAlpha = tintAlpha
        refreshAccessibilityPresentation()
    }

    func refreshAccessibilityPresentation() {
        let style = ContextualSparkSurfaceStyle.resolve(
            tintHex: tintHex,
            tintAlpha: tintAlpha,
            cornerRadius: cornerRadius,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        resolvedStyleForTesting = style
        glassView.isHidden = !style.usesGlassEffect

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.backgroundColor = NSColor.colorWith(
            hex: style.tintHex,
            alpha: style.tintColorAlpha
        ).cgColor
        tintLayer.cornerRadius = style.cornerRadius
        tintLayer.cornerCurve = .continuous
        glassView.layer?.cornerRadius = style.cornerRadius
        glassView.layer?.cornerCurve = .continuous
        glassView.layer?.masksToBounds = true
        layer?.cornerRadius = style.cornerRadius
        layer?.borderWidth = style.borderWidth
        layer?.borderColor = NSColor.white.withAlphaComponent(style.borderAlpha).cgColor
        CATransaction.commit()
    }

    func updateBackingScale(_ scale: CGFloat) {
        let resolved = max(scale, 1)
        layer?.contentsScale = resolved
        glassView.layer?.contentsScale = resolved
        decorView.layer?.contentsScale = resolved
        tintLayer.contentsScale = resolved
        decorContainer.contentsScale = resolved
    }
}
