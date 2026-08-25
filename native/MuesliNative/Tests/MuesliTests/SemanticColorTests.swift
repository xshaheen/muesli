import Foundation
import MuesliCore
import SwiftUI
import Testing
@testable import MuesliNativeApp

/// Reads a main-window source file so a test can assert on what the views actually say.
/// Mirrors the existing `MeetingDetailResponsiveLayoutTests` approach.
private func appSource(_ fileName: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = packageRoot
        .appendingPathComponent("Sources")
        .appendingPathComponent("MuesliNativeApp")
        .appendingPathComponent(fileName)
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

/// Every main-window view that carried a semantic colour before the split.
private let sweptViewFiles = [
    "AboutView.swift",
    "DictationRowView.swift",
    "DictationsView.swift",
    "DictionaryView.swift",
    "InsightsShareView.swift",
    "MeetingDetailView.swift",
    "MeetingListItemView.swift",
    "MeetingStatusDisplay.swift",
    "MeetingTemplatesManagerView.swift",
    "MeetingsView.swift",
    "ModelsView.swift",
    "OnboardingView.swift",
    "SettingsView.swift",
    "TranscriptCleanupPromptsManagerView.swift",
    "WritingStylesView.swift",
]

@Suite("Semantic colour tokens")
struct SemanticColorTests {
    @Test("each semantic state owns a distinct value")
    func semanticTokensAreDistinct() {
        let all = [
            MuesliTheme.recordingHex,
            MuesliTheme.transcribingHex,
            MuesliTheme.dangerHex,
            MuesliTheme.successHex,
        ]

        #expect(Set(all).count == all.count)
    }

    @Test("semantic values are the Contextual Spark palette")
    func semanticValuesMatchSpark() {
        #expect(MuesliTheme.recordingHex == DictationMiniPalette.accentHex)
        #expect(MuesliTheme.transcribingHex == DictationMiniPalette.accentHighlightHex)
        #expect(MuesliTheme.dangerHex == DictationMiniPalette.failureHex)
        #expect(MuesliTheme.successHex == DictationMiniPalette.successHex)
    }

    @Test("a failed meeting reads as failure, not as work in progress")
    func failedMeetingUsesDanger() {
        // This was amber before the split, which made a failed meeting look like a
        // running one.
        #expect(MeetingStatus.failed.displayColor == MuesliTheme.danger)
        #expect(MeetingStatus.failed.displayColor != MuesliTheme.transcribing)
    }

    @Test("a recording meeting reads as recording")
    func recordingMeetingUsesRecording() {
        #expect(MeetingStatus.recording.displayColor == MuesliTheme.recording)
    }

    @Test("a completed meeting reads as success")
    func completedMeetingUsesSuccess() {
        #expect(MeetingStatus.completed.displayColor == MuesliTheme.success)
    }
}

/// Serialized: these mutate the process-wide accent override.
@Suite("Semantic state does not follow the accent preset", .serialized)
struct SemanticStateAccentIndependenceTests {
    @Test("a processing meeting keeps its own colour whatever accent is chosen")
    func processingIgnoresAccentPreset() {
        let original = MuesliTheme.accentOverrideHex
        defer { MuesliTheme.accentOverrideHex = original }

        MuesliTheme.accentOverrideHex = nil
        let withDefaultAccent = MeetingStatus.processing.displayColor

        MuesliTheme.accentOverrideHex = "8b5cf6"
        let withPurpleAccent = MeetingStatus.processing.displayColor

        // R4 scopes presets to selection and highlight. A state colour that moved with the
        // preset is the defect this asserts against.
        #expect(withDefaultAccent == withPurpleAccent)
        #expect(withPurpleAccent == MuesliTheme.transcribing)
    }
}

@Suite("Semantic colour source boundaries")
struct SemanticColorSourceTests {
    @Test("no destructive control is painted with the recording token")
    func destructiveControlsDoNotUseRecording() throws {
        for fileName in sweptViewFiles {
            let source = try appSource(fileName)
            #expect(
                !source.contains("isDestructive ? MuesliTheme.recording"),
                "\(fileName) still paints a destructive control with the recording token"
            )
        }
    }

    @Test("no main-window view falls back to a raw red literal")
    func noRawRedLiterals() throws {
        for fileName in sweptViewFiles {
            let source = try appSource(fileName)
            #expect(
                !source.contains("foregroundStyle(.red"),
                "\(fileName) uses a raw red literal instead of the danger token"
            )
            #expect(
                !source.contains("Color.red"),
                "\(fileName) uses a raw Color.red instead of the danger token"
            )
        }
    }
}
