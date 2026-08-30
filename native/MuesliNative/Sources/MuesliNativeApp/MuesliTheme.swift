import CoreText
import SwiftUI
import MuesliCore

enum MuesliTheme {
    // MARK: - Ramp (warm charcoal / warm paper)

    /// The Contextual Spark ramp, shared in value with the floating surfaces so the window
    /// and the Mini read as one product. `raisedDarkHex` is deliberately the same number as
    /// `DictationMiniPalette.glassTintHex`: a card in the window and the capsule beside the
    /// caret sit at one value. The two are kept as independent literals and pinned together
    /// by test rather than by reference, so the window does not depend on a floating surface
    /// it is otherwise forbidden to touch.
    enum Ramp {
        static let inkWellDarkHex = 0x0E_0E_0D
        static let deepDarkHex    = 0x14_13_12
        static let baseDarkHex    = 0x1A_19_18
        static let raisedDarkHex  = 0x21_1F_1E
        static let hoverDarkHex   = 0x2A_28_26
        static let surfaceDarkHex = 0x32_31_2F
        static let selectedDarkHex = 0x3A_38_35

        static let baseLightHex    = 0xFF_FD_FB
        static let deepLightHex    = 0xF7_F4_EF
        static let raisedLightHex  = 0xF0_EC_E5
        static let hoverLightHex   = 0xE7_E2_D9
        static let surfaceLightHex = 0xD9_D3_C8
        static let selectedLightHex = 0xE3_DA_CF
    }

    /// Ink and hairline. The opacity ladder is unchanged from the values the app shipped
    /// with; only the colour the alphas are applied to moves, from pure white/black to the
    /// warm off-white and near-black of the Spark palette.
    enum Ink {
        static let darkHex  = 0xF3_F2_EF
        static let lightHex = 0x1A_19_18

        static let primaryDarkAlpha: CGFloat = 0.92
        static let primaryLightAlpha: CGFloat = 0.88
        static let secondaryDarkAlpha: CGFloat = 0.62
        static let secondaryLightAlpha: CGFloat = 0.55
        static let tertiaryDarkAlpha: CGFloat = 0.40
        static let tertiaryLightAlpha: CGFloat = 0.33
        static let disabledDarkAlpha: CGFloat = 0.22
        static let disabledLightAlpha: CGFloat = 0.22
        static let hairlineDarkAlpha: CGFloat = 0.07
        static let hairlineLightAlpha: CGFloat = 0.08
        /// Increase Contrast lifts the hairline to the same weight the floating surfaces use.
        static let hairlineHighContrastAlpha: CGFloat = 0.80

        static var dark: NSColor { .colorWith(hex: darkHex, alpha: 1) }
        static var light: NSColor { .colorWith(hex: lightHex, alpha: 1) }
    }

    // MARK: - Colors — Backgrounds (layered)

    // dev extracted the deep hexes so AppKit window chrome could share them, and darkened the
    // dark value to 0x0B0C0E. The extraction is kept and re-pointed at the Spark ramp; the
    // darkening is superseded, because the ramp's ordering is what the window ground now comes
    // from and #141312 is its deep step.
    static let backgroundDeepDarkHex = Ramp.deepDarkHex
    static let backgroundDeepLightHex = Ramp.deepLightHex

    static let backgroundInkWell = Color.adaptive(dark: Ramp.inkWellDarkHex, light: Ramp.surfaceLightHex)
    static let backgroundDeep   = Color.adaptive(dark: backgroundDeepDarkHex, light: backgroundDeepLightHex)

    /// AppKit counterpart of `backgroundDeep`, for window chrome that cannot use SwiftUI colors.
    static let backgroundDeepNSColor = NSColor.adaptive(
        dark: backgroundDeepDarkHex,
        light: backgroundDeepLightHex
    )
    static let backgroundBase   = Color.adaptive(dark: Ramp.baseDarkHex, light: Ramp.baseLightHex)
    static let backgroundRaised = Color.adaptive(dark: Ramp.raisedDarkHex, light: Ramp.raisedLightHex)
    static let backgroundHover  = Color.adaptive(dark: Ramp.hoverDarkHex, light: Ramp.hoverLightHex)

    // MARK: - Surfaces (interactive elements)

    static let surfacePrimary   = Color.adaptive(dark: Ramp.surfaceDarkHex, light: Ramp.surfaceLightHex)
    static let surfaceSelected  = Color.adaptive(dark: Ramp.selectedDarkHex, light: Ramp.selectedLightHex)
    /// Pure resolver so the accessibility branch is testable without an AppKit appearance.
    static func hairlineAlpha(isDark: Bool, increaseContrast: Bool) -> CGFloat {
        if increaseContrast { return Ink.hairlineHighContrastAlpha }
        return isDark ? Ink.hairlineDarkAlpha : Ink.hairlineLightAlpha
    }

    static let surfaceBorder = Color.adaptiveHairline(
        dark: Ink.dark,
        light: Ink.light,
        alpha: hairlineAlpha(isDark:increaseContrast:)
    )

    static let textDisabled = Color.adaptiveAlpha(
        dark: Ink.dark, darkAlpha: Ink.disabledDarkAlpha,
        light: Ink.light, lightAlpha: Ink.disabledLightAlpha
    )

    // MARK: - Text hierarchy

    static let textPrimary = Color.adaptiveAlpha(
        dark: Ink.dark, darkAlpha: Ink.primaryDarkAlpha,
        light: Ink.light, lightAlpha: Ink.primaryLightAlpha
    )
    static let textSecondary = Color.adaptiveAlpha(
        dark: Ink.dark, darkAlpha: Ink.secondaryDarkAlpha,
        light: Ink.light, lightAlpha: Ink.secondaryLightAlpha
    )
    static let textTertiary = Color.adaptiveAlpha(
        dark: Ink.dark, darkAlpha: Ink.tertiaryDarkAlpha,
        light: Ink.light, lightAlpha: Ink.tertiaryLightAlpha
    )

    // MARK: - Accent

    /// Coral is the product accent. Presets remain selectable but are scoped to selection and
    /// highlight; every semantic state owns its own token so a preset cannot recolour state.
    static let defaultAccentDarkHex = 0xFF7043
    static let defaultAccentLightHex = 0xE8542A
    static let defaultAccent    = Color.adaptive(dark: defaultAccentDarkHex, light: defaultAccentLightHex)
    static var accentOverrideHex: String?
    static var accent: Color {
        if let value = parsedAccentHex(accentOverrideHex) {
            return Color(hex: value)
        }
        return defaultAccent
    }
    static var resolvedAccentDarkHex: Int {
        resolvedAccentDarkHex(overrideHex: accentOverrideHex)
    }
    static func resolvedAccentDarkHex(overrideHex: String?) -> Int {
        parsedAccentHex(overrideHex) ?? defaultAccentDarkHex
    }
    static var accentSubtle: Color { accent.opacity(0.15) }

    private static func parsedAccentHex(_ hex: String?) -> Int? {
        guard let hex, !hex.isEmpty,
              let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16)
        else { return nil }
        return Int(value)
    }

    // MARK: - Semantic

    /// One token per state. `recording` and `danger` were a single red before, which meant a
    /// delete button and a live recording could not be recoloured independently -- most uses
    /// of the old token were destructive controls and validation errors, not recording.
    static let recordingHex     = 0xFF7043
    static let transcribingHex  = 0xFFB04D
    static let dangerHex        = 0xFF6961
    static let successHex       = 0x48E57B
    static let recording        = Color(hex: recordingHex)
    static let transcribing     = Color(hex: transcribingHex)
    static let danger           = Color(hex: dangerHex)
    static let success          = Color(hex: successHex)

    // MARK: - Typography (Inter, bridged through AppFonts)

    /// Text runs go through `AppFonts`, which already owns the family-name candidates and the
    /// system-font fallback. `Font.custom` would duplicate that fallback and fail silently to
    /// a default face when Inter is missing.
    ///
    /// SF Symbols deliberately do *not* use this: their glyph metrics come from the system
    /// face, so sizing them through a text font would distort them.
    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(nsFont(size: size, weight: weight))
    }

    /// Durations, versions, traces and paths -- anything that wants a monospaced face.
    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced).monospacedDigit()
    }

    /// Counts and stats that stay in the text voice but must not jitter as they change.
    /// `Font.monospacedDigit()` can silently do nothing on a custom face, so the tabular
    /// figures are requested from the font itself rather than from SwiftUI.
    static func numeric(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(nsFont(size: size, weight: weight).withTabularFigures())
    }

    static func nsFont(size: CGFloat, weight: Font.Weight) -> NSFont {
        if weight == .bold || weight == .heavy || weight == .black { return AppFonts.bold(size) }
        if weight == .semibold { return AppFonts.semibold(size) }
        if weight == .medium { return AppFonts.medium(size) }
        return AppFonts.regular(size)
    }

    // Sizes follow dev's tightening of the two display steps (28 -> 26, 22 -> 20); the family
    // is the Spark change.
    static func title1() -> Font { font(size: 26, weight: .bold) }
    static func title2() -> Font { font(size: 20, weight: .semibold) }
    static func title3() -> Font { font(size: 18, weight: .semibold) }
    static func headline() -> Font { font(size: 15, weight: .semibold) }
    static func body() -> Font { font(size: 14, weight: .regular) }
    static func callout() -> Font { font(size: 13, weight: .regular) }
    static func caption() -> Font { font(size: 12, weight: .regular) }
    static func captionMedium() -> Font { font(size: 12, weight: .medium) }

    // MARK: - Spacing (4pt grid)

    /// Top padding for page content and for the sidebar header, so a page's heading lines up
    /// with the app name in the sidebar.
    static let pageTop: CGFloat = 8

    static let spacing4: CGFloat = 4
    static let spacing8: CGFloat = 8
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing20: CGFloat = 20
    static let spacing24: CGFloat = 24
    static let spacing32: CGFloat = 32

    // MARK: - Corner radii

    /// One continuous-curve scale by role. The continuous curve is not decoration: the default
    /// circular curve is the most visible difference between the window and the floating
    /// surfaces at a glance.
    static let cornerChip: CGFloat = 4
    static let cornerSmall: CGFloat = 6
    static let cornerMedium: CGFloat = 10
    static let cornerLarge: CGFloat = 14
    static let cornerXL: CGFloat = 22

    /// Prefer this over constructing a `RoundedRectangle` inline: it owns the curve so a call
    /// site names the role instead of repeating the style argument.
    static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    // MARK: - Motion

    /// Lifted verbatim from the shipped floating surfaces so both move alike.
    ///
    /// Under Reduce Motion these resolvers return `nil` rather than a shorter animation. That
    /// distinction is the whole point: a shortened animation still interpolates a changed
    /// offset, scale or position, so the user still sees movement. `nil` applies the state
    /// change with no interpolation at all, and a repeating animation never starts.
    enum Motion {
        static let morph: TimeInterval = 0.16
        static let popIn: TimeInterval = 0.26
        static let fade: TimeInterval = 0.14
        static let hoverGrace: TimeInterval = 0.4

        /// Pure form, for tests and for callers that already hold the environment value.
        static func eased(_ duration: TimeInterval, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeInOut(duration: duration)
        }

        static func easedOut(_ duration: TimeInterval, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeOut(duration: duration)
        }

        static func repeating(
            _ duration: TimeInterval,
            autoreverses: Bool,
            reduceMotion: Bool
        ) -> Animation? {
            guard !reduceMotion else { return nil }
            return .linear(duration: duration).repeatForever(autoreverses: autoreverses)
        }

        static func pulsing(
            _ duration: TimeInterval,
            reduceMotion: Bool
        ) -> Animation? {
            guard !reduceMotion else { return nil }
            return .easeInOut(duration: duration).repeatForever(autoreverses: true)
        }

        /// Ambient form for call sites with no environment access, such as controller
        /// callbacks. Reads the workspace setting directly.
        @MainActor static var reduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        @MainActor static func eased(_ duration: TimeInterval) -> Animation? {
            eased(duration, reduceMotion: reduceMotion)
        }

        @MainActor static func easedOut(_ duration: TimeInterval) -> Animation? {
            easedOut(duration, reduceMotion: reduceMotion)
        }

        @MainActor static func repeating(_ duration: TimeInterval, autoreverses: Bool) -> Animation? {
            repeating(duration, autoreverses: autoreverses, reduceMotion: reduceMotion)
        }

        @MainActor static func pulsing(_ duration: TimeInterval) -> Animation? {
            pulsing(duration, reduceMotion: reduceMotion)
        }
    }
}

// MARK: - Color Helpers

extension Color {
    init(hex: Int) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    static func adaptive(dark: Int, light: Int) -> Color {
        Color(nsColor: NSColor.adaptive(dark: dark, light: light))
    }

    /// Resolves both appearance and the Increase Contrast accessibility appearances, so a
    /// hairline can strengthen when the setting is on. `bestMatch` reports the high-contrast
    /// appearances as distinct names, which is what makes this observable without polling
    /// `NSWorkspace`.
    static func adaptiveHairline(
        dark: NSColor,
        light: NSColor,
        alpha: @escaping (Bool, Bool) -> CGFloat
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua,
                .darkAqua,
                .accessibilityHighContrastAqua,
                .accessibilityHighContrastDarkAqua,
            ])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let increaseContrast = match == .accessibilityHighContrastAqua
                || match == .accessibilityHighContrastDarkAqua
            return (isDark ? dark : light).withAlphaComponent(alpha(isDark, increaseContrast))
        })
    }

    static func adaptiveAlpha(dark: NSColor, darkAlpha: CGFloat, light: NSColor, lightAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark.withAlphaComponent(darkAlpha)
                : light.withAlphaComponent(lightAlpha)
        })
    }
}

extension NSFont {
    /// Turns on the font's tabular-figures feature, so digits share one advance width and a
    /// counter stops shifting its neighbours as it ticks.
    func withTabularFigures() -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                ]
            ]
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

extension NSColor {
    static func adaptive(dark: Int, light: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: 1.0
            )
        }
    }
}

/// Page heading used by every dashboard page, so titles stay identical across tabs.
struct PageTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(MuesliTheme.title1())
            .foregroundStyle(MuesliTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
