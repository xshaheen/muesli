import AppKit
import SwiftUI
import Testing
@testable import MuesliNativeApp

@Suite("Typography")
struct TypographyTests {
    @Test("a text font is returned at the requested size")
    func fontKeepsRequestedSize() {
        for size in [10.0, 12.0, 14.0, 22.0, 28.0] as [CGFloat] {
            #expect(MuesliTheme.nsFont(size: size, weight: .regular).pointSize == size)
        }
    }

    @Test("each weight maps to a real face")
    func weightsMapToFaces() {
        let weights: [Font.Weight] = [.regular, .medium, .semibold, .bold, .heavy, .light]

        for weight in weights {
            let font = MuesliTheme.nsFont(size: 13, weight: weight)
            #expect(font.pointSize == 13)
            #expect(!font.fontName.isEmpty)
        }
    }

    @Test("text resolves to Inter when it is registered, and to the system font when it is not")
    func interWithSystemFallback() {
        // R10. AppFonts registers nothing when it finds no font files, and silently falls back
        // to the system face -- so this asserts the contract holds either way rather than
        // depending on whether the test host happens to have the bundle's fonts.
        let font = MuesliTheme.nsFont(size: 14, weight: .regular)
        let family = font.familyName ?? ""
        let systemFamily = NSFont.systemFont(ofSize: 14, weight: .regular).familyName ?? ""

        #expect(family.contains("Inter") || family == systemFamily)
        #expect(font.pointSize == 14)
    }

    @Test("every theme text helper goes through the shared font path")
    func helpersUseSharedPath() {
        // If a helper regressed to .system() this would still compile, so compare against the
        // font path rather than trusting the call site.
        #expect(MuesliTheme.body() == MuesliTheme.font(size: 14, weight: .regular))
        #expect(MuesliTheme.caption() == MuesliTheme.font(size: 12, weight: .regular))
        #expect(MuesliTheme.captionMedium() == MuesliTheme.font(size: 12, weight: .medium))
        #expect(MuesliTheme.callout() == MuesliTheme.font(size: 13, weight: .regular))
        #expect(MuesliTheme.headline() == MuesliTheme.font(size: 15, weight: .semibold))
        #expect(MuesliTheme.title1() == MuesliTheme.font(size: 28, weight: .bold))
        #expect(MuesliTheme.title2() == MuesliTheme.font(size: 22, weight: .semibold))
        #expect(MuesliTheme.title3() == MuesliTheme.font(size: 18, weight: .semibold))
    }

    @Test("the monospaced token is distinct from the text token")
    func monoIsDistinct() {
        #expect(MuesliTheme.mono(size: 12) != MuesliTheme.font(size: 12))
    }

    @Test("SF Symbols keep the system face")
    func symbolsAreNotRoutedThroughInter() throws {
        // 140 of the 382 sites size an SF Symbol. Routing those through a text font would
        // distort their glyph metrics, so the migration deliberately left them alone and this
        // records that as intent rather than an oversight.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent("MuesliNativeApp")
                .appendingPathComponent("SidebarView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("Image(systemName: \"magnifyingglass\")"))
        #expect(source.contains(".font(.system(size: 12))"))
    }
}
