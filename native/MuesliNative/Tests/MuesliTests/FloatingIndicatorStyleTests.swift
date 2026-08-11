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
    @Test("panel keeps neutral glass while reserving a subtle selected-control fill")
    func panelUsesNeutralGlassSurface() {
        let panel = FloatingMeetingPanelSurfaceStyle.resolve()
        let indicator = FloatingIndicatorSurfaceStyle.resolve(role: .recording)

        #expect(panel.glass == indicator)
        #expect(panel.cornerRadius == MuesliTheme.cornerXL)
        #expect(panel.selectedControlAlpha == 0.14)
    }

    @Test("semantic accents stay limited to the established state palette")
    func semanticAccentPalette() {
        #expect(MuesliTheme.defaultAccentDarkHex == 0x6BA3F7)
        #expect(MuesliTheme.recordingHex == 0xEF4444)
        #expect(MuesliTheme.transcribingHex == 0xF59E0B)
    }

    @Test("compact and expanded selections resolve the same custom accent")
    func selectionAccentOverride() {
        #expect(MuesliTheme.resolvedAccentDarkHex(overrideHex: "#89b4fa") == 0x89B4FA)
        #expect(MuesliTheme.resolvedAccentDarkHex(overrideHex: "not-a-color") == MuesliTheme.defaultAccentDarkHex)
    }

    @Test("an open panel can observe a refreshed selection accent")
    @MainActor
    func panelSelectionAccentRefresh() {
        let model = FloatingMeetingTranscriptModel()

        model.setSelectionAccentHex(0x89B4FA)

        #expect(model.selectionAccentHex == 0x89B4FA)
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
