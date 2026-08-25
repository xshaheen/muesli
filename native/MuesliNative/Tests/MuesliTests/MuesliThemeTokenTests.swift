import AppKit
import Testing
@testable import MuesliNativeApp

/// Luminance of a packed RGB hex, used only to assert ramp ordering.
private func luminance(_ hex: Int) -> Double {
    let red = Double((hex >> 16) & 0xFF) / 255
    let green = Double((hex >> 8) & 0xFF) / 255
    let blue = Double(hex & 0xFF) / 255
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue
}

@Suite("Muesli theme tokens")
struct MuesliThemeTokenTests {
    @Test("the raised surface is the Contextual Spark glass tint")
    func raisedMatchesGlassTint() {
        // The window's card value and the Mini's glass tint are deliberately the same
        // number. Asserting it here is what stops the two drifting apart later.
        #expect(MuesliTheme.Ramp.raisedDarkHex == 0x21_1F_1E)
        #expect(MuesliTheme.Ramp.raisedDarkHex == DictationMiniPalette.glassTintHex)
    }

    @Test("the dark ramp climbs from ink-well to surface")
    func darkRampIsMonotonic() {
        let ramp = [
            MuesliTheme.Ramp.inkWellDarkHex,
            MuesliTheme.Ramp.deepDarkHex,
            MuesliTheme.Ramp.baseDarkHex,
            MuesliTheme.Ramp.raisedDarkHex,
            MuesliTheme.Ramp.hoverDarkHex,
            MuesliTheme.Ramp.surfaceDarkHex,
        ]

        for (lower, higher) in zip(ramp, ramp.dropFirst()) {
            #expect(luminance(lower) < luminance(higher))
        }
    }

    @Test("the light ramp descends from base to surface")
    func lightRampIsMonotonic() {
        let ramp = [
            MuesliTheme.Ramp.baseLightHex,
            MuesliTheme.Ramp.deepLightHex,
            MuesliTheme.Ramp.raisedLightHex,
            MuesliTheme.Ramp.hoverLightHex,
            MuesliTheme.Ramp.surfaceLightHex,
        ]

        for (lighter, darker) in zip(ramp, ramp.dropFirst()) {
            #expect(luminance(lighter) > luminance(darker))
        }
    }

    @Test("both ramps are warm rather than neutral or cool")
    func rampsAreWarm() {
        // Warmth is what separates Spark from the old blue-black shell: red leads blue
        // at every step. A neutral grey would pass a luminance check and still be wrong.
        let all = [
            MuesliTheme.Ramp.inkWellDarkHex, MuesliTheme.Ramp.deepDarkHex,
            MuesliTheme.Ramp.baseDarkHex, MuesliTheme.Ramp.raisedDarkHex,
            MuesliTheme.Ramp.hoverDarkHex, MuesliTheme.Ramp.surfaceDarkHex,
            MuesliTheme.Ramp.baseLightHex, MuesliTheme.Ramp.deepLightHex,
            MuesliTheme.Ramp.raisedLightHex, MuesliTheme.Ramp.hoverLightHex,
            MuesliTheme.Ramp.surfaceLightHex,
        ]

        for hex in all {
            let red = (hex >> 16) & 0xFF
            let blue = hex & 0xFF
            #expect(red > blue)
        }
    }

    @Test("light and dark resolve to different values for every background step")
    func appearancesDiffer() {
        #expect(MuesliTheme.Ramp.deepDarkHex != MuesliTheme.Ramp.deepLightHex)
        #expect(MuesliTheme.Ramp.baseDarkHex != MuesliTheme.Ramp.baseLightHex)
        #expect(MuesliTheme.Ramp.raisedDarkHex != MuesliTheme.Ramp.raisedLightHex)
        #expect(MuesliTheme.Ramp.hoverDarkHex != MuesliTheme.Ramp.hoverLightHex)
        #expect(MuesliTheme.Ramp.surfaceDarkHex != MuesliTheme.Ramp.surfaceLightHex)
    }

    @Test("the ink opacity ladder keeps its shipped values")
    func inkLadderUnchanged() {
        // R3 is a hue change, not a contrast change. These numbers are the ones the app
        // shipped with; only the colour they are applied to moves.
        #expect(MuesliTheme.Ink.primaryDarkAlpha == 0.92)
        #expect(MuesliTheme.Ink.secondaryDarkAlpha == 0.62)
        #expect(MuesliTheme.Ink.tertiaryDarkAlpha == 0.40)
        #expect(MuesliTheme.Ink.primaryLightAlpha == 0.88)
        #expect(MuesliTheme.Ink.secondaryLightAlpha == 0.55)
        #expect(MuesliTheme.Ink.tertiaryLightAlpha == 0.33)
        #expect(MuesliTheme.Ink.hairlineDarkAlpha == 0.07)
        #expect(MuesliTheme.Ink.hairlineLightAlpha == 0.08)
    }

    @Test("ink is warm off-white on dark and warm near-black on light")
    func inkIsWarm() {
        #expect(MuesliTheme.Ink.darkHex == 0xF3_F2_EF)
        #expect(MuesliTheme.Ink.lightHex == 0x1A_19_18)
    }
}
