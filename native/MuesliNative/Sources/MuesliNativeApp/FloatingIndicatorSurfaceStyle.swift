import AppKit

enum FloatingIndicatorPresentationRole: CaseIterable {
    case idleCollapsed
    case idleHovered
    case preparing
    case recording
    case transcribing
    case loading
    case warning
    case computerUse
}

struct FloatingIndicatorSurfaceStyle: Equatable {
    let tintHex: String
    let tintAlpha: CGFloat
    let borderHex: String
    let borderAlpha: CGFloat
    let borderWidth: CGFloat
    let glyphHex: String
    let glyphAlpha: CGFloat
    let textAlpha: CGFloat
    let panelAlpha: CGFloat
    let usesGlassEffect: Bool

    static func resolve(
        role: FloatingIndicatorPresentationRole,
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false
    ) -> Self {
        let textAlpha: CGFloat

        switch role {
        case .idleCollapsed:
            textAlpha = 0.82
        case .idleHovered:
            textAlpha = 0.82
        case .preparing:
            textAlpha = 1
        case .recording:
            textAlpha = 1
        case .transcribing:
            textAlpha = 0.82
        case .loading:
            textAlpha = 0.82
        case .warning:
            textAlpha = 0.95
        case .computerUse:
            textAlpha = 0.92
        }

        // Surface chrome is deliberately role-independent. Varying these values by
        // state recreated the legacy pill family instead of carrying the recording
        // pill's glass treatment through the whole indicator lifecycle.
        return Self(
            tintHex: "1e1e2e",
            tintAlpha: reduceTransparency ? 1 : 0.60,
            borderHex: "ffffff",
            borderAlpha: increaseContrast ? 0.80 : 0.16,
            borderWidth: increaseContrast ? 2 : 1,
            glyphHex: "ffffff",
            glyphAlpha: 0.95,
            textAlpha: textAlpha,
            panelAlpha: 1,
            usesGlassEffect: !reduceTransparency
        )
    }
}
