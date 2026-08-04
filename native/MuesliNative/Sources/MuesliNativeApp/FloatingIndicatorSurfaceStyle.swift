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
        recordingAccentHex: String,
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false
    ) -> Self {
        let tintAlpha: CGFloat
        let borderHex: String
        let baseBorderAlpha: CGFloat
        let glyphHex: String
        let textAlpha: CGFloat

        switch role {
        case .idleCollapsed:
            tintAlpha = 0.44
            borderHex = "ffffff"
            baseBorderAlpha = 0.22
            glyphHex = "ffffff"
            textAlpha = 0.82
        case .idleHovered:
            tintAlpha = 0.72
            borderHex = "ffffff"
            baseBorderAlpha = 0.14
            glyphHex = "ffffff"
            textAlpha = 0.82
        case .preparing:
            tintAlpha = 0.62
            borderHex = "ffffff"
            baseBorderAlpha = 0.16
            glyphHex = "ffffff"
            textAlpha = 1
        case .recording:
            tintAlpha = 0.60
            borderHex = recordingAccentHex.lowercased()
            baseBorderAlpha = 0.42
            glyphHex = "ffffff"
            textAlpha = 1
        case .transcribing:
            tintAlpha = 0.62
            borderHex = "ffffff"
            baseBorderAlpha = 0.16
            glyphHex = "ffffff"
            textAlpha = 0.82
        case .loading:
            tintAlpha = 0.72
            borderHex = "ffffff"
            baseBorderAlpha = 0.16
            glyphHex = "ffffff"
            textAlpha = 0.82
        case .warning:
            tintAlpha = 0.72
            borderHex = "d99a11"
            baseBorderAlpha = 0.58
            glyphHex = "d99a11"
            textAlpha = 0.95
        case .computerUse:
            tintAlpha = 0.72
            borderHex = "1455d9"
            baseBorderAlpha = 0.58
            glyphHex = "89b4fa"
            textAlpha = 0.92
        }

        return Self(
            tintHex: "1e1e2e",
            tintAlpha: reduceTransparency ? 1 : tintAlpha,
            borderHex: borderHex,
            borderAlpha: increaseContrast ? max(0.80, baseBorderAlpha) : baseBorderAlpha,
            borderWidth: increaseContrast ? 2 : 1,
            glyphHex: glyphHex,
            glyphAlpha: 0.95,
            textAlpha: textAlpha,
            panelAlpha: reduceTransparency ? 1 : (role == .idleCollapsed ? 0.85 : 1),
            usesGlassEffect: !reduceTransparency
        )
    }
}
