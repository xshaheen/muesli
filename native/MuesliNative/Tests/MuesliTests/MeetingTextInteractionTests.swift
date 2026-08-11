import Foundation
import SwiftUI
import Testing
@testable import MuesliNativeApp

@Suite("Meeting text interaction")
struct MeetingTextInteractionTests {
    @Test("transcript text direction does not change speaker role")
    func transcriptDirectionIsIndependentFromRole() throws {
        let messages = TranscriptChatMessage.messages(from: """
        [10:00:00] You: مرحبا بالفريق
        [10:00:04] Speaker 1: Hello team
        """)

        let user = try #require(messages.first)
        let other = try #require(messages.last)
        #expect(user.isUser)
        #expect(user.textDirection == .rightToLeft)
        #expect(!other.isUser)
        #expect(other.textDirection == .leftToRight)
        #expect(LiveTranscriptBubble.contentDirection(for: ["… 42 مرحبا"]) == .rightToLeft)
    }

    @Test("title anchor and marquee travel follow content direction")
    func titleDirectionGeometry() {
        #expect(NaturalTextDirection.resolve("2026 — خطة الإطلاق") == .rightToLeft)
        #expect(NaturalTextDirection.resolve("2026 launch plan") == .leftToRight)
        #expect(NaturalTextDirection.resolve("خطة الإطلاق").frameAlignment == .trailing)
        #expect(NaturalTextDirection.resolve("Launch plan").frameAlignment == .leading)
        #expect(MeetingTitlePresentation.marqueeOffset(for: "خطة طويلة", distance: 120) == 120)
        #expect(MeetingTitlePresentation.marqueeOffset(for: "A long plan", distance: 120) == -120)
    }

    @Test("live transcript uses explicit Open instead of a body-wide tap")
    func liveTranscriptOpenInteraction() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MuesliNativeApp/LiveTranscriptView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains(".onTapGesture { onOpen?() }"))
        #expect(source.contains("private var openButton"))
        #expect(source.contains(".accessibilityLabel(\"Open meeting details\")"))
        #expect(source.contains(".textSelection(.enabled)"))
    }

    @Test("chat text direction stays independent from bubble role and selection")
    func chatTextInteraction() throws {
        #expect(NaturalTextDirection.resolve("مرحبا بالفريق") == .rightToLeft)
        #expect(NaturalTextDirection.resolve("Hello team") == .leftToRight)

        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MuesliNativeApp/MeetingChatView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains(".onTapGesture"))
        #expect(source.contains(".textSelection(.enabled)"))
        #expect(source.contains(".accessibilityLabel("))
    }
}
