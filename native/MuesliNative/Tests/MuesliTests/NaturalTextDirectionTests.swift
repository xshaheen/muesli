import SwiftUI
import Testing
@testable import MuesliNativeApp

@Suite("Natural text direction")
struct NaturalTextDirectionTests {
    @Test("Arabic and Hebrew resolve right to left")
    func rightToLeftScripts() {
        #expect(NaturalTextDirection.resolve("مرحبا بالعالم") == .rightToLeft)
        #expect(NaturalTextDirection.resolve("שלום עולם") == .rightToLeft)
    }

    @Test("Latin and Cyrillic resolve left to right")
    func leftToRightScripts() {
        #expect(NaturalTextDirection.resolve("Hello world") == .leftToRight)
        #expect(NaturalTextDirection.resolve("Привет, мир") == .leftToRight)
    }

    @Test("neutral prefixes do not decide direction")
    func neutralPrefixes() {
        #expect(NaturalTextDirection.resolve("### 2026-08-12 🎯 — مرحبا") == .rightToLeft)
        #expect(NaturalTextDirection.resolve("- [ ] 42. Hello") == .leftToRight)
    }

    @Test("mixed text follows its first strong character")
    func mixedText() {
        #expect(NaturalTextDirection.resolve("ناقشنا API v2 وخطة Q3") == .rightToLeft)
        #expect(NaturalTextDirection.resolve("API v2 ناقشنا اليوم") == .leftToRight)
        #expect(NaturalTextDirection.resolve("... שלום roadmap") == .rightToLeft)
    }

    @Test("empty and neutral-only text falls back left to right")
    func neutralFallback() {
        for text in ["", "   ", "2026-08-12", "🎯 — …", "# - [ ] 123"] {
            #expect(NaturalTextDirection.resolve(text) == .leftToRight)
        }
    }

    @Test("resolved values map to SwiftUI presentation directions")
    func presentationValues() {
        let ltr = NaturalTextDirection.leftToRight
        #expect(ltr.layoutDirection == LayoutDirection.leftToRight)
        #expect(ltr.frameAlignment == Alignment.leading)

        let rtl = NaturalTextDirection.rightToLeft
        #expect(rtl.layoutDirection == LayoutDirection.rightToLeft)
        #expect(rtl.frameAlignment == Alignment.trailing)
    }
}
