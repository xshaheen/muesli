import AppKit
import Testing
@testable import MuesliNativeApp

@Suite("Floating indicator surface style")
struct FloatingIndicatorStyleTests {
    @Test("every presentation uses the same neutral tint")
    func everyRoleUsesNeutralTint() {
        for role in FloatingIndicatorPresentationRole.allCases {
            let style = FloatingIndicatorSurfaceStyle.resolve(
                role: role,
                recordingAccentHex: "89b4fa"
            )

            #expect(style.tintHex == "1e1e2e")
            #expect(style.usesGlassEffect)
        }
    }

    @Test("roles keep their documented opacity hierarchy")
    func roleOpacityHierarchy() {
        let expected: [FloatingIndicatorPresentationRole: CGFloat] = [
            .idleCollapsed: 0.44,
            .idleHovered: 0.72,
            .preparing: 0.62,
            .recording: 0.60,
            .transcribing: 0.62,
            .loading: 0.72,
            .warning: 0.72,
            .computerUse: 0.72,
        ]

        for (role, tintAlpha) in expected {
            let style = FloatingIndicatorSurfaceStyle.resolve(
                role: role,
                recordingAccentHex: "89b4fa"
            )

            #expect(style.tintAlpha == tintAlpha)
        }
    }

    @Test("semantic colors stay out of surface fills")
    func semanticColorsAreAccentsOnly() {
        let recording = FloatingIndicatorSurfaceStyle.resolve(
            role: .recording,
            recordingAccentHex: "89b4fa"
        )
        let warning = FloatingIndicatorSurfaceStyle.resolve(
            role: .warning,
            recordingAccentHex: "89b4fa"
        )
        let computerUse = FloatingIndicatorSurfaceStyle.resolve(
            role: .computerUse,
            recordingAccentHex: "89b4fa"
        )

        #expect(recording.borderHex == "89b4fa")
        #expect(recording.borderAlpha == 0.42)
        #expect(recording.glyphHex == "ffffff")
        #expect(warning.borderHex == "d99a11")
        #expect(warning.borderAlpha == 0.58)
        #expect(warning.glyphHex == "d99a11")
        #expect(warning.glyphAlpha == 0.95)
        #expect(computerUse.borderHex == "1455d9")
        #expect(computerUse.borderAlpha == 0.58)
        #expect(computerUse.glyphHex == "89b4fa")
        #expect(computerUse.glyphAlpha == 0.95)
    }

    @Test("reduce transparency uses an opaque neutral fallback")
    func reduceTransparencyFallback() {
        let style = FloatingIndicatorSurfaceStyle.resolve(
            role: .warning,
            recordingAccentHex: "89b4fa",
            reduceTransparency: true
        )

        #expect(!style.usesGlassEffect)
        #expect(style.tintHex == "1e1e2e")
        #expect(style.tintAlpha == 1)
        #expect(style.panelAlpha == 1)
        #expect(style.glyphHex == "d99a11")
    }

    @Test("collapsed idle stays opaque when transparency is reduced")
    func collapsedIdleReduceTransparencyFallback() {
        let normal = FloatingIndicatorSurfaceStyle.resolve(
            role: .idleCollapsed,
            recordingAccentHex: "89b4fa"
        )
        let reducedTransparency = FloatingIndicatorSurfaceStyle.resolve(
            role: .idleCollapsed,
            recordingAccentHex: "89b4fa",
            reduceTransparency: true
        )

        #expect(normal.panelAlpha == 0.85)
        #expect(reducedTransparency.panelAlpha == 1)
    }

    @Test("increase contrast strengthens every border")
    func increaseContrastBorder() {
        for role in FloatingIndicatorPresentationRole.allCases {
            let style = FloatingIndicatorSurfaceStyle.resolve(
                role: role,
                recordingAccentHex: "89b4fa",
                increaseContrast: true
            )

            #expect(style.borderWidth == 2)
            #expect(style.borderAlpha >= 0.80)
        }
    }

    @Test("secondary text remains legible")
    func textOpacityFloor() {
        for role in FloatingIndicatorPresentationRole.allCases {
            let style = FloatingIndicatorSurfaceStyle.resolve(
                role: role,
                recordingAccentHex: "89b4fa"
            )

            #expect(style.textAlpha >= 0.82)
        }
    }
}
