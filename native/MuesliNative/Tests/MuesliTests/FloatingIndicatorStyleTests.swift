import AppKit
import Testing
@testable import MuesliNativeApp

@Suite("Floating indicator surface style")
struct FloatingIndicatorStyleTests {
    @Test("every presentation uses the recording-derived neutral glass surface")
    func everyRoleUsesRecordingDerivedNeutralGlass() {
        for role in FloatingIndicatorPresentationRole.allCases {
            let style = FloatingIndicatorSurfaceStyle.resolve(role: role)

            #expect(style.tintHex == "1e1e2e")
            #expect(style.tintAlpha == 0.60)
            #expect(style.borderHex == "ffffff")
            #expect(style.borderAlpha == 0.16)
            #expect(style.borderWidth == 1)
            #expect(style.glyphHex == "ffffff")
            #expect(style.glyphAlpha == 0.95)
            #expect(style.panelAlpha == 1)
            #expect(style.usesGlassEffect)
        }
    }

    @Test("reduce transparency uses an opaque neutral fallback")
    func reduceTransparencyFallback() {
        let style = FloatingIndicatorSurfaceStyle.resolve(
            role: .warning,
            reduceTransparency: true
        )

        #expect(!style.usesGlassEffect)
        #expect(style.tintHex == "1e1e2e")
        #expect(style.tintAlpha == 1)
        #expect(style.panelAlpha == 1)
        #expect(style.glyphHex == "ffffff")
    }

    @Test("collapsed idle stays opaque when transparency is reduced")
    func collapsedIdleReduceTransparencyFallback() {
        let normal = FloatingIndicatorSurfaceStyle.resolve(role: .idleCollapsed)
        let reducedTransparency = FloatingIndicatorSurfaceStyle.resolve(
            role: .idleCollapsed,
            reduceTransparency: true
        )

        #expect(normal.panelAlpha == 1)
        #expect(reducedTransparency.panelAlpha == 1)
    }

    @Test("increase contrast strengthens every border")
    func increaseContrastBorder() {
        for role in FloatingIndicatorPresentationRole.allCases {
            let style = FloatingIndicatorSurfaceStyle.resolve(
                role: role,
                increaseContrast: true
            )

            #expect(style.borderWidth == 2)
            #expect(style.borderAlpha >= 0.80)
        }
    }

    @Test("secondary text remains legible")
    func textOpacityFloor() {
        for role in FloatingIndicatorPresentationRole.allCases {
            let style = FloatingIndicatorSurfaceStyle.resolve(role: role)

            #expect(style.textAlpha >= 0.82)
        }
    }
}

@Suite("Floating meeting panel surface style")
struct FloatingMeetingPanelStyleTests {
    @Test("panel inherits the indicator neutral glass surface without accent chrome")
    func panelUsesNeutralGlassSurface() {
        let panel = FloatingMeetingPanelSurfaceStyle.resolve()
        let indicator = FloatingIndicatorSurfaceStyle.resolve(role: .recording)

        #expect(panel.glass == indicator)
        #expect(panel.cornerRadius == MuesliTheme.cornerXL)
        #expect(panel.selectedControlAlpha == 0.14)
    }

    @Test("panel preserves accessible opaque and high-contrast fallbacks")
    func panelAccessibilityFallbacks() {
        let panel = FloatingMeetingPanelSurfaceStyle.resolve(
            reduceTransparency: true,
            increaseContrast: true
        )

        #expect(panel.glass.tintAlpha == 1)
        #expect(!panel.glass.usesGlassEffect)
        #expect(panel.glass.borderAlpha == 0.80)
        #expect(panel.glass.borderWidth == 2)
    }
}
