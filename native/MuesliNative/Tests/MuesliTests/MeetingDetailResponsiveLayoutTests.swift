import Foundation
import Testing

@Suite("Meeting detail responsive layout")
struct MeetingDetailResponsiveLayoutTests {
    @Test("utility band falls back to stacked folder and actions when the detail pane is narrow")
    func utilityBandHasStackedFallback() throws {
        let source = try meetingDetailSource()
        let utilityBand = try sourceSection(
            in: source,
            from: "private func headerUtilityBand",
            to: "private func meetingActionRail"
        )

        #expect(utilityBand.contains("ViewThatFits(in: .horizontal)"))
        #expect(utilityBand.contains("HStack(alignment: .center"))
        #expect(utilityBand.contains("VStack(alignment: .leading"))
        #expect(
            try index(of: "HStack(alignment: .center", in: utilityBand)
                < index(of: "VStack(alignment: .leading", in: utilityBand)
        )
    }

    @Test("folder and meeting actions share a compact responsive utility band")
    func headerUsesGroupedActionRail() throws {
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
        let actionRail = try sourceSection(
            in: source,
            from: "private func actionRail(for meeting",
            to: "private func primaryActionRail"
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
        #expect(utilityBand.contains("ViewThatFits(in: .horizontal)"))
        #expect(responsiveRail.contains("ViewThatFits(in: .horizontal)"))
        #expect(responsiveRail.contains("primaryActionRail(for: meeting"))
        #expect(responsiveRail.contains("extremeNarrowActionRail(for: meeting"))
        #expect(
            try index(of: "actionRail(for: meeting", in: responsiveRail)
                < index(of: "primaryActionRail(for: meeting", in: responsiveRail)
        )
        #expect(actionRail.contains("primaryActionRailContent(for: meeting"))
        #expect(actionRail.contains("utilityActionRailContent(for: meeting)"))
        #expect(actionRail.contains("railDivider"))
        #expect(railContainer.contains("HStack(spacing: 0)"))
        #expect(railContainer.contains(".clipShape(RoundedRectangle"))
        #expect(iconButton.contains(".accessibilityLabel(label)"))
        #expect(iconButton.contains(".help(label)"))
        #expect(templateMenu.contains(".truncationMode(.tail)"))
        #expect(templateMenu.contains(".frame(maxWidth: 120"))
        #expect(templateMenu.contains(".accessibilityLabel(templateAccessibilityLabel"))
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
