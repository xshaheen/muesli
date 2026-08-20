import AppKit
import Foundation

/// The display corner the object holds while it grows and shrinks. Chosen once when the
/// object first shows and kept for the recording, so a row or panel never pushes the pill
/// inward from the edge it was parked against.
enum MeetingObjectCorner: Equatable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var holdsTrailing: Bool { self == .topTrailing || self == .bottomTrailing }
    var holdsTop: Bool { self == .topLeading || self == .topTrailing }

    static func resolve(holdsTrailing: Bool, holdsTop: Bool) -> MeetingObjectCorner {
        switch (holdsTrailing, holdsTop) {
        case (true, true): return .topTrailing
        case (true, false): return .bottomTrailing
        case (false, true): return .topLeading
        case (false, false): return .bottomLeading
        }
    }
}

/// What the pill's text slot carries, which is also what decides the object's width.
enum MeetingObjectContent: Equatable {
    case clock(hasHours: Bool)
    case status(String)
}

/// Where the merged meeting object sits and how big it is, in one place.
///
/// Every function here is `nonisolated static` and depends on nothing but its arguments:
/// the object's placement rules are worth reading and testing without a window, a pointer
/// or a run loop anywhere near them. The controller keeps the live state — which layout is
/// showing, which corner is held, where the anchor is — and calls in here to turn it into a
/// frame.
extension MeetingRecordingPanelController {
    nonisolated static let dotDiameter: CGFloat = 8
    nonisolated static let dotLeading: CGFloat = 9
    nonisolated static let dotTextGap: CGFloat = 5
    nonisolated static let pillTrailingInset: CGFloat = 11

    nonisolated private static let screenInset: CGFloat = 12

    nonisolated static func defaultCenter(
        in visibleFrame: NSRect,
        size: NSSize = MeetingRecordingPanelController.basePillSize
    ) -> CGPoint {
        CGPoint(
            x: visibleFrame.maxX - size.width / 2 - screenInset,
            y: visibleFrame.minY + size.height / 2 + screenInset
        )
    }

    nonisolated static func resolvedFrame(savedCenter: CGPoint?, size: NSSize, screens: [NSRect]) -> NSRect {
        guard let fallback = screens.first else {
            return NSRect(origin: .zero, size: size)
        }
        // Only a genuinely absent anchor takes the default corner — that is first run.
        // A supplied anchor is resolved against the *nearest* display, never tested for
        // containment: during a drag it tracks the pointer 1:1 and legally sits in the
        // menu-bar strip, the Dock strip or a gap between mismatched displays, all of
        // which are outside every `visibleFrame`. Falling back to the default corner there
        // teleports the object to the primary display mid-drag, and the drag then saves
        // that jump as the user's spot.
        guard let savedCenter else {
            return clampedFrame(center: defaultCenter(in: fallback, size: size), size: size, in: fallback)
        }
        return clampedFrame(
            center: savedCenter,
            size: size,
            in: screenFrame(containing: savedCenter, screens: screens)
        )
    }

    /// The anchor frame: the 72 pt pill, clamped 12 pt inside its display.
    nonisolated static func basePillFrame(anchorCenter: CGPoint?, screens: [NSRect]) -> NSRect {
        resolvedFrame(savedCenter: anchorCenter, size: basePillSize, screens: screens)
    }

    nonisolated static func heldCorner(for pill: NSRect, in screen: NSRect) -> MeetingObjectCorner {
        MeetingObjectCorner.resolve(
            holdsTrailing: pill.midX >= screen.midX,
            holdsTop: pill.midY > screen.midY
        )
    }

    nonisolated static func pillSize(for content: MeetingObjectContent) -> NSSize {
        switch content {
        case .clock(let hasHours):
            return hasHours ? widePillSize : basePillSize
        case .status(let word):
            let widest = (finalizingStatusWords + [word]).map(statusPillWidth(for:)).max() ?? basePillSize.width
            return NSSize(width: max(basePillSize.width, widest.rounded(.up)), height: basePillSize.height)
        }
    }

    nonisolated static func size(
        for layout: MeetingObjectLayout,
        content: MeetingObjectContent,
        panelSize: NSSize = MeetingRecordingPanelController.defaultPanelSize
    ) -> NSSize {
        switch layout {
        case .pill:
            return pillSize(for: content)
        case .row:
            // The row keeps the clock in every state; only the pill trades it for the status
            // word, so a status never steps the row's width.
            if case .clock(let hasHours) = content, hasHours { return wideRowSize }
            return rowSize
        case .panel:
            return panelSize
        }
    }

    /// Every layout grows from the base pill's held corner and is clamped 12 pt inside the
    /// pill's display.
    nonisolated static func frame(
        for layout: MeetingObjectLayout,
        anchoredTo basePill: NSRect,
        corner: MeetingObjectCorner,
        size: NSSize,
        screen: NSRect
    ) -> NSRect {
        var size = size
        if layout == .panel {
            size = NSSize(
                width: max(size.width, minimumPanelSize.width),
                height: max(size.height, minimumPanelSize.height)
            )
        }
        let resolved = resolvedCorner(corner, size: size, anchoredTo: basePill, screen: screen)
        let origin = NSPoint(
            x: resolved.holdsTrailing ? basePill.maxX - size.width : basePill.minX,
            y: resolved.holdsTop ? basePill.maxY - size.height : basePill.minY
        )
        return clampedFrame(
            center: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2),
            size: size,
            in: screen
        )
    }

    /// R4: the corner is kept for the recording, and re-chosen on an axis only when the
    /// derived frame would not fit 12 pt inside the display on that axis.
    nonisolated static func resolvedCorner(
        _ corner: MeetingObjectCorner,
        size: NSSize,
        anchoredTo basePill: NSRect,
        screen: NSRect
    ) -> MeetingObjectCorner {
        func fitsHorizontally(trailing: Bool) -> Bool {
            let minX = trailing ? basePill.maxX - size.width : basePill.minX
            return minX >= screen.minX + screenInset && minX + size.width <= screen.maxX - screenInset
        }
        func fitsVertically(top: Bool) -> Bool {
            let minY = top ? basePill.maxY - size.height : basePill.minY
            return minY >= screen.minY + screenInset && minY + size.height <= screen.maxY - screenInset
        }
        var holdsTrailing = corner.holdsTrailing
        if !fitsHorizontally(trailing: holdsTrailing), fitsHorizontally(trailing: !holdsTrailing) {
            holdsTrailing.toggle()
        }
        var holdsTop = corner.holdsTop
        if !fitsVertically(top: holdsTop), fitsVertically(top: !holdsTop) {
            holdsTop.toggle()
        }
        return MeetingObjectCorner.resolve(holdsTrailing: holdsTrailing, holdsTop: holdsTop)
    }

    /// The base pill center a dragged or resized frame lands on — the inverse of `frame(for:…)`
    /// on the held corner, so the saved center is never a derived size's midpoint.
    nonisolated static func anchorCenter(
        afterDragging frame: NSRect,
        corner: MeetingObjectCorner
    ) -> CGPoint {
        CGPoint(
            x: corner.holdsTrailing
                ? frame.maxX - basePillSize.width / 2
                : frame.minX + basePillSize.width / 2,
            y: corner.holdsTop
                ? frame.maxY - basePillSize.height / 2
                : frame.minY + basePillSize.height / 2
        )
    }

    nonisolated static func screenFrame(containing point: CGPoint, screens: [NSRect]) -> NSRect {
        if let match = screens.first(where: { $0.contains(point) }) { return match }
        return screens.min { distance(from: point, to: $0) < distance(from: point, to: $1) }
            ?? NSRect(origin: .zero, size: defaultPanelSize)
    }

    nonisolated static func clampedDragOrigin(_ origin: NSPoint, size: NSSize, screens: [NSRect]) -> NSPoint {
        guard !screens.isEmpty else { return origin }
        let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let destination = screens.min { lhs, rhs in
            distance(from: center, to: lhs) < distance(from: center, to: rhs)
        } ?? screens[0]
        let clamped = clampedFrame(center: center, size: size, in: destination)
        return clamped.origin
    }

    nonisolated private static func statusPillWidth(for word: String) -> CGFloat {
        let width = (word as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]
        ).width
        return dotLeading + dotDiameter + dotTextGap + width + pillTrailingInset
    }

    nonisolated private static func distance(from point: CGPoint, to rect: NSRect) -> CGFloat {
        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)
        return hypot(point.x - x, point.y - y)
    }

    nonisolated private static func clampedFrame(center: CGPoint, size: NSSize, in screen: NSRect) -> NSRect {
        let minX = screen.minX + screenInset
        let maxX = max(minX, screen.maxX - screenInset - size.width)
        let minY = screen.minY + screenInset
        let maxY = max(minY, screen.maxY - screenInset - size.height)
        return NSRect(
            x: min(max(center.x - size.width / 2, minX), maxX),
            y: min(max(center.y - size.height / 2, minY), maxY),
            width: size.width,
            height: size.height
        )
    }
}
