import Foundation
import Testing

@Suite("Meeting detail responsive layout")
struct MeetingDetailResponsiveLayoutTests {
    @Test("header falls back to stacked title and actions when the detail pane is narrow")
    func headerHasStackedFallback() throws {
        let source = try meetingDetailSource()
        let adaptiveHeader = try sourceSection(
            in: source,
            from: "private func adaptiveHeaderContent",
            to: "private func headerTitleContent"
        )

        #expect(adaptiveHeader.contains("ViewThatFits(in: .horizontal)"))
        #expect(adaptiveHeader.contains("HStack(alignment: .top"))
        #expect(adaptiveHeader.contains("VStack(alignment: .leading"))
        #expect(
            try index(of: "HStack(alignment: .top", in: adaptiveHeader)
                < index(of: "VStack(alignment: .leading", in: adaptiveHeader)
        )
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
