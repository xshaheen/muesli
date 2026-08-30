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
        #expect(MuesliTheme.title1() == MuesliTheme.font(size: 26, weight: .bold))
        #expect(MuesliTheme.title2() == MuesliTheme.font(size: 20, weight: .semibold))
        #expect(MuesliTheme.title3() == MuesliTheme.font(size: 18, weight: .semibold))
    }

    @Test("the monospaced token is distinct from the text token")
    func monoIsDistinct() {
        #expect(MuesliTheme.mono(size: 12) != MuesliTheme.font(size: 12))
    }

    @Test("the numeric token stays in the text voice but requests tabular figures")
    func numericKeepsTextVoiceWithTabularFigures() {
        // Numbers that tick must not shift their neighbours, but a counter is not code -- it
        // should still read in the text face rather than a monospaced one.
        let plain = MuesliTheme.nsFont(size: 18, weight: .semibold)
        let tabular = plain.withTabularFigures()

        #expect(tabular.pointSize == plain.pointSize)
        #expect(tabular.familyName == plain.familyName)
        #expect(MuesliTheme.numeric(size: 18, weight: .semibold) != MuesliTheme.mono(size: 18, weight: .semibold))
    }

    @Test("no main-window view falls back to the rounded system design")
    func noRoundedSystemDesign() throws {
        // SF Rounded was a second type voice competing with the window's own. Every text run
        // that used it now goes through the shared font path.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesDirectory = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MuesliNativeApp")

        let floating = [
            "DictationMini", "ContextualSpark", "FloatingMeeting", "FloatingIndicator",
            "MeetingRecordingPanel", "MeetingPanel",
        ]
        let names = try FileManager.default
            .contentsOfDirectory(atPath: sourcesDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .filter { name in !floating.contains { name.hasPrefix($0) } }

        for name in names {
            let source = try String(
                contentsOf: sourcesDirectory.appendingPathComponent(name),
                encoding: .utf8
            )
            #expect(!source.contains("design: .rounded"), "\(name) still uses the rounded design")
        }
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
