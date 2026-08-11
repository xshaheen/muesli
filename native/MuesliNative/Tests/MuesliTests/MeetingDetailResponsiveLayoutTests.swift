import Foundation
@testable import MuesliNativeApp
import Testing

@Suite("Meeting detail responsive layout")
struct MeetingDetailResponsiveLayoutTests {
    @Test("utility band uses one wrapping layout instead of duplicate responsive trees")
    func utilityBandUsesSingleWrappingLayout() throws {
        let source = try meetingDetailSource()
        let utilityBand = try sourceSection(
            in: source,
            from: "private func headerUtilityBand",
            to: "private func meetingActionRail"
        )

        #expect(utilityBand.contains("VStack(alignment: .leading"))
        #expect(!utilityBand.contains("ViewThatFits"))
        #expect(utilityBand.contains("folderPill(for: meeting)"))
        #expect(utilityBand.contains("meetingActionRail(for: meeting"))
    }

    @Test("meeting actions render once and wrap as compact groups")
    func actionsUseSingleWrappingRail() throws {
        let source = try meetingDetailSource()
        let titleContent = try sourceSection(
            in: source,
            from: "private func headerTitleContent",
            to: "private func headerUtilityBand"
        )
        let utilityBand = try sourceSection(
            in: source,
            from: "private func headerUtilityBand",
            to: "private func meetingActionRail"
        )
        let responsiveRail = try sourceSection(
            in: source,
            from: "private func meetingActionRail",
            to: "private func content(for meeting"
        )
        let railContainer = try sourceSection(
            in: source,
            from: "private func actionRailContainer",
            to: "private var railDivider"
        )
        let iconButton = try sourceSection(
            in: source,
            from: "private func railIconButton",
            to: "private func retranscribeAction"
        )
        let templateMenu = try sourceSection(
            in: source,
            from: "private func templateMenu(for meeting",
            to: "private func contentToolbar"
        )

        #expect(!titleContent.contains("folderPill(for: meeting)"))
        #expect(utilityBand.contains("folderPill(for: meeting)"))
        #expect(utilityBand.contains("meetingActionRail(for: meeting"))
        #expect(responsiveRail.contains("MeetingDetailFlowLayout"))
        #expect(!responsiveRail.contains("ViewThatFits"))
        #expect(!responsiveRail.contains("extremeNarrowActionRail"))
        #expect(responsiveRail.contains("templateAndExportActionRailContent(for: meeting"))
        #expect(responsiveRail.contains("utilityActionRail(for: meeting)"))
        #expect(railContainer.contains("HStack(spacing: 0)"))
        #expect(railContainer.contains(".clipShape(RoundedRectangle"))
        #expect(iconButton.contains(".accessibilityLabel(label)"))
        #expect(iconButton.contains(".help(label)"))
        #expect(templateMenu.contains(".truncationMode(.tail)"))
        #expect(templateMenu.contains(".frame(maxWidth: 120"))
        #expect(templateMenu.contains(".menuStyle(.borderlessButton)\n        .frame(height: 30)"))
        #expect(templateMenu.contains(".accessibilityLabel(templateAccessibilityLabel"))
    }

    @Test("flow layout wraps groups without rebuilding them")
    func flowLayoutWrapsGroups() {
        let result = MeetingDetailFlowLayout(spacing: 8).layout(
            sizes: [
                CGSize(width: 90, height: 28),
                CGSize(width: 150, height: 30),
                CGSize(width: 110, height: 30),
            ],
            width: 260
        )

        #expect(result.size == CGSize(width: 260, height: 68))
        #expect(result.points == [
            CGPoint(x: 0, y: 1),
            CGPoint(x: 98, y: 0),
            CGPoint(x: 0, y: 38),
        ])
    }

    @Test("export menu is icon-only while keeping an accessible label")
    func exportMenuUsesIconOnlyLabel() throws {
        let source = try meetingDetailSource()
        let exportMenu = try sourceSection(
            in: source,
            from: "private func exportMenu(for meeting",
            to: "private func hasMoreActions"
        )

        #expect(exportMenu.contains("Image(systemName: \"square.and.arrow.up\")"))
        #expect(!exportMenu.contains("Text(\"Export\")"))
        #expect(exportMenu.contains(".menuStyle(.borderlessButton)\n        .frame(height: 30)"))
        #expect(exportMenu.contains(".accessibilityLabel(\"Export meeting\")"))
        #expect(exportMenu.contains(".help(\"Export meeting\")"))
    }

    private func meetingDetailSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MuesliNativeApp")
            .appendingPathComponent("MeetingDetailView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func sourceSection(
        in source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> String {
        let start = try index(of: startMarker, in: source)
        let suffix = source[start...]
        guard let end = suffix.range(of: endMarker)?.lowerBound else {
            throw LayoutTestFailure("Could not find \(endMarker)")
        }
        return String(source[start..<end])
    }

    private func index(of needle: String, in haystack: String) throws -> String.Index {
        guard let range = haystack.range(of: needle) else {
            throw LayoutTestFailure("Could not find \(needle)")
        }
        return range.lowerBound
    }
}

private struct LayoutTestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
