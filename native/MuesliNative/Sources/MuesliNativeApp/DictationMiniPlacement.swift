import CoreGraphics

/// Pure AppKit-coordinate placement for the caret-contextual dictation Mini.
struct DictationMiniPlacement {
    struct Screen: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    enum Quadrant: CaseIterable, Equatable {
        case lowerLeft
        case lowerRight
        case upperLeft
        case upperRight
        /// Centred under the caret (the Mini's home position).
        case below
        /// Centred above the caret when there is no room below.
        case above
    }

    struct Result: Equatable {
        let frame: CGRect
        let quadrant: Quadrant
        let screen: Screen
    }

    static let minimumCaretClearance: CGFloat = 10
    static let movementThreshold: CGFloat = 4
    static let screenEdgeInset: CGFloat = 4
    /// Gap between the caret's bottom edge and the Mini's visible top edge.
    static let caretGap: CGFloat = 6
    /// Lift used when the Mini must sit above the caret (caret bottom → Mini bottom).
    static let caretLiftAbove: CGFloat = 22
    /// The follower sits a touch left of the caret so it reads as "under the insertion point",
    /// not under the next character (measured against the reference follower).
    static let caretHorizontalBias: CGFloat = -4

    /// Places the Mini centred directly under a caret anchor (the caret's bottom-centre point),
    /// flipping above it when the screen runs out, and clamping as a last resort.
    /// `visualInset` is the transparent margin between the window edge and the visible glyph
    /// (e.g. the seed's glow margin), so the glyph — not the window — keeps the caret gap.
    static func placeBelowCaret(
        _ anchor: CGPoint,
        size: CGSize,
        screens: [Screen],
        visualInset: CGFloat = 0
    ) -> Result? {
        guard size.width > 0, size.height > 0,
              let screen = selectedScreen(containingOrNearestTo: anchor, screens: screens)
        else { return nil }
        let visibleFrame = insetVisibleFrame(screen.visibleFrame, by: screenEdgeInset)
        let clearance = caretGap - visualInset
        let below = proposedFrame(near: anchor, size: size, clearance: clearance, quadrant: .below)
        if visibleFrame.contains(below) {
            return Result(frame: below, quadrant: .below, screen: screen)
        }
        let above = proposedFrame(near: anchor, size: size, clearance: clearance, quadrant: .above)
        if visibleFrame.contains(above) {
            return Result(frame: above, quadrant: .above, screen: screen)
        }
        return Result(frame: clamped(below, to: visibleFrame), quadrant: .below, screen: screen)
    }

    static func place(
        near anchor: CGPoint,
        size: CGSize,
        screens: [Screen],
        clearance: CGFloat = minimumCaretClearance
    ) -> Result? {
        guard size.width > 0, size.height > 0,
              let screen = selectedScreen(containingOrNearestTo: anchor, screens: screens)
        else { return nil }

        let safeClearance = max(clearance, minimumCaretClearance)
        let visibleFrame = insetVisibleFrame(screen.visibleFrame, by: screenEdgeInset)
        for quadrant in [Quadrant.lowerLeft, .lowerRight, .upperLeft, .upperRight] {
            let frame = proposedFrame(
                near: anchor,
                size: size,
                clearance: safeClearance,
                quadrant: quadrant
            )
            if visibleFrame.contains(frame) {
                return Result(frame: frame, quadrant: quadrant, screen: screen)
            }
        }

        let preferred = proposedFrame(
            near: anchor,
            size: size,
            clearance: safeClearance,
            quadrant: .lowerLeft
        )
        return Result(
            frame: clamped(preferred, to: visibleFrame),
            quadrant: .lowerLeft,
            screen: screen
        )
    }

    static func shouldReacquire(
        from previousAnchor: CGPoint,
        on previousScreen: Screen,
        to currentAnchor: CGPoint,
        on currentScreen: Screen,
        threshold: CGFloat = movementThreshold
    ) -> Bool {
        guard previousScreen == currentScreen else { return true }
        let distance = hypot(
            currentAnchor.x - previousAnchor.x,
            currentAnchor.y - previousAnchor.y
        )
        return distance >= max(threshold, 0)
    }

    static func rehomeFrozenFrame(_ frame: CGRect, screens: [Screen]) -> CGRect? {
        guard !screens.isEmpty else { return nil }
        if let current = screens.first(where: { $0.frame.intersects(frame) }) {
            return clamped(frame, to: insetVisibleFrame(current.visibleFrame, by: screenEdgeInset))
        }
        let nearest = screens.min { lhs, rhs in
            squaredDistance(from: frame.center, to: lhs.visibleFrame)
                < squaredDistance(from: frame.center, to: rhs.visibleFrame)
        }
        guard let nearest else { return nil }
        return clamped(frame, to: insetVisibleFrame(nearest.visibleFrame, by: screenEdgeInset))
    }

    private static func selectedScreen(containingOrNearestTo point: CGPoint, screens: [Screen]) -> Screen? {
        screens.first(where: { $0.frame.contains(point) })
            ?? screens.min {
                squaredDistance(from: point, to: $0.frame)
                    < squaredDistance(from: point, to: $1.frame)
            }
    }

    private static func proposedFrame(
        near anchor: CGPoint,
        size: CGSize,
        clearance: CGFloat,
        quadrant: Quadrant
    ) -> CGRect {
        let x: CGFloat
        let y: CGFloat
        switch quadrant {
        case .lowerRight:
            x = anchor.x + clearance
            y = anchor.y - clearance - size.height
        case .lowerLeft:
            x = anchor.x - clearance - size.width
            y = anchor.y - clearance - size.height
        case .upperRight:
            x = anchor.x + clearance
            y = anchor.y + clearance
        case .upperLeft:
            x = anchor.x - clearance - size.width
            y = anchor.y + clearance
        case .below:
            x = anchor.x + caretHorizontalBias - size.width / 2
            y = anchor.y - clearance - size.height
        case .above:
            x = anchor.x + caretHorizontalBias - size.width / 2
            y = anchor.y + caretLiftAbove
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private static func clamped(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        let x = frame.width > bounds.width
            ? bounds.midX - frame.width / 2
            : min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        let y = frame.height > bounds.height
            ? bounds.midY - frame.height / 2
            : min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: frame.size)
    }

    private static func insetVisibleFrame(_ frame: CGRect, by inset: CGFloat) -> CGRect {
        guard frame.width > inset * 2, frame.height > inset * 2 else { return frame }
        return frame.insetBy(dx: inset, dy: inset)
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
