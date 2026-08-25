import Foundation
import Testing
@testable import MuesliNativeApp

private func appSourceFile(_ fileName: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MuesliNativeApp")
            .appendingPathComponent(fileName),
        encoding: .utf8
    )
}

/// Files that draw inside the main application window. The floating surfaces are excluded on
/// purpose: glass is theirs, and they are out of scope for this work entirely.
private func mainWindowSourceFiles() throws -> [(name: String, source: String)] {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourcesDirectory = packageRoot
        .appendingPathComponent("Sources")
        .appendingPathComponent("MuesliNativeApp")

    let floatingSurfacePrefixes = [
        "DictationMini",
        "ContextualSpark",
        "FloatingMeeting",
        "FloatingIndicator",
        "MeetingRecordingPanel",
        "MeetingPanel",
    ]

    let names = try FileManager.default
        .contentsOfDirectory(atPath: sourcesDirectory.path)
        .filter { $0.hasSuffix(".swift") }
        .filter { name in !floatingSurfacePrefixes.contains { name.hasPrefix($0) } }
        .sorted()

    return try names.map { name in
        (name, try String(contentsOf: sourcesDirectory.appendingPathComponent(name), encoding: .utf8))
    }
}

@Suite("Ink and hairline ladder")
struct InkLadderTests {
    @Test("the hairline keeps its shipped alpha when contrast is not increased")
    func hairlineNormalAlpha() {
        #expect(MuesliTheme.hairlineAlpha(isDark: true, increaseContrast: false) == 0.07)
        #expect(MuesliTheme.hairlineAlpha(isDark: false, increaseContrast: false) == 0.08)
    }

    @Test("Increase Contrast strengthens the hairline in both appearances")
    func hairlineHighContrastAlpha() {
        // MuesliTheme had no Increase Contrast path at all before this: the hairline stayed
        // at 7-8% however the setting was configured.
        #expect(MuesliTheme.hairlineAlpha(isDark: true, increaseContrast: true) == 0.80)
        #expect(MuesliTheme.hairlineAlpha(isDark: false, increaseContrast: true) == 0.80)
    }

    @Test("the disabled ink step sits below tertiary in both appearances")
    func disabledSitsBelowTertiary() {
        #expect(MuesliTheme.Ink.disabledDarkAlpha < MuesliTheme.Ink.tertiaryDarkAlpha)
        #expect(MuesliTheme.Ink.disabledLightAlpha < MuesliTheme.Ink.tertiaryLightAlpha)
    }
}

@Suite("Window material boundary")
struct WindowMaterialBoundaryTests {
    @Test("no main-window view uses glass or blur by any mechanism")
    func noGlassInsideTheWindow() throws {
        // Glass is the signature of a surface floating over another app's work. An opaque
        // window has nothing behind it to blur, so the material would imitate a function it
        // cannot perform. A gate written only against NSVisualEffectView passed the
        // .regularMaterial that was live in InsightsShareView, which is how it survived.
        let mechanisms = [
            "NSVisualEffectView",
            ".regularMaterial",
            ".ultraThinMaterial",
            ".thinMaterial",
            ".thickMaterial",
            ".ultraThickMaterial",
            ".blur(radius",
        ]

        for file in try mainWindowSourceFiles() {
            for mechanism in mechanisms {
                #expect(
                    !file.source.contains(mechanism),
                    "\(file.name) uses \(mechanism) inside the main window"
                )
            }
        }
    }
}

@Suite("Corner geometry")
struct CornerGeometryTests {
    @Test("the radius scale is ordered by role")
    func radiusScaleIsOrdered() {
        #expect(MuesliTheme.cornerChip < MuesliTheme.cornerSmall)
        #expect(MuesliTheme.cornerSmall < MuesliTheme.cornerMedium)
        #expect(MuesliTheme.cornerMedium < MuesliTheme.cornerLarge)
        #expect(MuesliTheme.cornerLarge < MuesliTheme.cornerXL)
    }

    @Test("no main-window view draws a default-curve rounded rectangle")
    func noDefaultCurveRectangles() throws {
        // The default circular curve is the most visible difference between the window and
        // the floating surfaces, so this is a gate rather than a convention.
        let pattern = try NSRegularExpression(pattern: #"RoundedRectangle\(cornerRadius: [^,)]+\)"#)

        for file in try mainWindowSourceFiles() {
            let range = NSRange(file.source.startIndex..., in: file.source)
            let matches = pattern.numberOfMatches(in: file.source, range: range)
            #expect(matches == 0, "\(file.name) has \(matches) default-curve rounded rectangle(s)")
        }
    }
}

@Suite("Floating surface ownership boundary")
struct FloatingSurfaceOwnershipTests {
    @Test("the floating surfaces keep their own shipped palette")
    func floatingPaletteUnchanged() {
        // These belong to the Mini and the meeting object, not to the window theme. Pinning
        // them turns the ownership boundary from a convention into a gate.
        #expect(DictationMiniPalette.glassTintHex == 0x211F1E)
        #expect(DictationMiniPalette.accentHex == 0xFF7043)
        #expect(DictationMiniPalette.accentHighlightHex == 0xFFB04D)
        #expect(DictationMiniPalette.successHex == 0x48E57B)
        #expect(DictationMiniPalette.failureHex == 0xFF6961)
        #expect(DictationMiniPalette.inkHex == 0xF3F2EF)
    }

    @Test("the floating indicator surface style is untouched")
    func floatingSurfaceStyleUnchanged() {
        let style = FloatingIndicatorSurfaceStyle.resolve(role: .recording)

        #expect(style.tintHex == "1e1e2e")
        #expect(style.tintAlpha == 0.60)
        #expect(style.borderAlpha == 0.16)
    }
}
