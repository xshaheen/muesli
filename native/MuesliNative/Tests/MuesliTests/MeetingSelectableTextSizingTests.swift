import AppKit
import SwiftUI
import Testing
@testable import MuesliNativeApp

/// Sizing for the selectable text used by transcript rows, meeting notes and chat bubbles.
///
/// This exists because of a hang. `sizeThatFits` used to take its height from
/// `nsView.fittingSize` — the live field's current content — while `updateNSView` assigned
/// that content. SwiftUI calls `sizeThatFits` repeatedly while resolving a layout, so each
/// pass answered from what the previous one had left behind, the two never agreed, and
/// layout never terminated: the main thread pinned at 100% inside `AG::Subgraph::update`,
/// captured in a live sample of the app while the chat tab was frozen.
///
/// The property that makes layout terminate is that the size is a function of the text and
/// the proposal alone. That is what these pin.
@MainActor
@Suite("Meeting selectable text sizing")
struct MeetingSelectableTextSizingTests {

    private func text(_ value: String, pointSize: CGFloat = 12) -> NSAttributedString {
        MeetingSelectableTextContent.plain(value, pointSize: pointSize)
    }

    private let wrappingProposal = ProposedViewSize(width: 180, height: nil)

    /// The regression itself. Sizing a second time must give the same answer, and sizing must
    /// not be reachable through a view at all — the old signature took one, which is how the
    /// live field's mutated state got into the result.
    @Test("sizing the same text against the same proposal is stable")
    func sizingIsDeterministic() {
        let value = text("A chat answer long enough to wrap onto more than one line in the panel.")

        let first = MeetingSelectableText.size(for: value, proposal: wrappingProposal, fillsAvailableWidth: false)
        let second = MeetingSelectableText.size(for: value, proposal: wrappingProposal, fillsAvailableWidth: false)

        #expect(first == second, "consecutive layout passes must agree, or layout cannot terminate")
    }

    /// Sizing must not be perturbed by whatever a field happens to be displaying. The old
    /// implementation read exactly that, so this is the specific coupling being ruled out.
    @Test("sizing is unaffected by what a live field currently displays")
    func sizingIgnoresLiveFieldContent() {
        let value = text("The measured line.")
        let expected = MeetingSelectableText.size(for: value, proposal: wrappingProposal, fillsAvailableWidth: false)

        // Drive a field through unrelated content, the way updateNSView does mid-layout.
        let field = MeetingSelectableTextField()
        field.attributedStringValue = text(String(repeating: "Much taller content. ", count: 40))
        _ = field.fittingSize
        field.attributedStringValue = text("")

        let afterMutation = MeetingSelectableText.size(for: value, proposal: wrappingProposal, fillsAvailableWidth: false)
        #expect(afterMutation == expected)
    }

    /// Measuring is allowed to use shared scratch state, but one text's answer must never
    /// carry into another's.
    ///
    /// Honest limit: this does not fail if the scratch field goes stale, because
    /// `max(bounds, fittingHeight)` is usually settled by the bounds and masks a wrong
    /// fitting height. Verified by mutation — removing the assignment in `fittingHeight`
    /// leaves this green. What actually rules the bug out is structural: `size(for:...)`
    /// takes no view, so the field being laid out is unreachable from the calculation.
    /// This covers the ordering it can.
    @Test("measuring one text does not contaminate the size reported for another")
    func interleavedMeasurementsStayIndependent() {
        let short = text("Short.")
        let long = text(String(repeating: "Long wrapping content that occupies many lines. ", count: 20))

        let shortAlone = MeetingSelectableText.size(for: short, proposal: wrappingProposal, fillsAvailableWidth: false)
        _ = MeetingSelectableText.size(for: long, proposal: wrappingProposal, fillsAvailableWidth: false)
        let shortAfterLong = MeetingSelectableText.size(for: short, proposal: wrappingProposal, fillsAvailableWidth: false)

        #expect(shortAfterLong == shortAlone, "a previous measurement leaked into this one")
    }

    /// The behaviour the removed `fittingSize` read was protecting: the raw attributed-string
    /// bounds can come out a point shorter than the cell actually draws, which clipped the
    /// final line. Keeping that guarantee without the view is the whole point of the fix.
    @Test("height is never shorter than the cell needs to draw the text")
    func heightDoesNotClipTheFinalLine() {
        let value = text("Wrapping text that runs past a single line inside a narrow chat bubble.")
        let measured = MeetingSelectableText.size(for: value, proposal: wrappingProposal, fillsAvailableWidth: false)

        let field = MeetingSelectableTextField()
        field.attributedStringValue = value
        let cellHeight = field.cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: measured.width, height: .greatestFiniteMagnitude)
        ).height ?? 0

        #expect(measured.height >= floor(cellHeight), "the final line would be clipped")
    }

    /// Chat bubbles hug their text; transcript rows and notes fill the row. Both paths must
    /// stay bounded by the proposal, since an answer wider than what was offered is another
    /// way to keep a parent stack re-proposing.
    @Test("a hugging bubble never exceeds the proposed width")
    func huggingWidthStaysWithinTheProposal() {
        let value = text("Short.")
        let size = MeetingSelectableText.size(for: value, proposal: wrappingProposal, fillsAvailableWidth: false)
        #expect(size.width <= 180)
    }

    @Test("a filling row takes the proposed width")
    func fillingWidthTakesTheProposal() {
        let value = text("Short.")
        let size = MeetingSelectableText.size(for: value, proposal: wrappingProposal, fillsAvailableWidth: true)
        #expect(size.width == 180)
    }

    /// An unspecified width still has to produce a usable size rather than a degenerate one;
    /// `.fixedSize(horizontal: false, vertical: true)` on the chat bubble proposes exactly
    /// this during one phase of the layout the hang was captured in.
    @Test("an unspecified proposed width still yields a positive size")
    func unspecifiedWidthIsHandled() {
        let value = text("Measured without a proposed width.")
        let size = MeetingSelectableText.size(
            for: value,
            proposal: ProposedViewSize(width: nil, height: nil),
            fillsAvailableWidth: false
        )
        #expect(size.width >= 1)
        #expect(size.height >= 1)
    }

}
