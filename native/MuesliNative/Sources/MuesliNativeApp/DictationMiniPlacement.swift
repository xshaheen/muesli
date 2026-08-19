import CoreGraphics

/// Pure AppKit-coordinate placement for the pointer-contextual dictation Mini.
struct DictationMiniPlacement {
    struct Screen: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    enum Quadrant: CaseIterable, Equatable {
        case lowerRight
        case lowerLeft
        case upperRight
        case upperLeft
    }

    struct Result: Equatable {
        let frame: CGRect
        let quadrant: Quadrant
        let screen: Screen
    }

    static let minimumPointerClearance: CGFloat = 28
    static let movementThreshold: CGFloat = 48
    static let screenEdgeInset: CGFloat = 4

    static func place(
        near pointer: CGPoint,
        size: CGSize,
        screens: [Screen],
        clearance: CGFloat = minimumPointerClearance
    ) -> Result? {
        guard size.width > 0, size.height > 0,
              let screen = selectedScreen(containingOrNearestTo: pointer, screens: screens)
        else { return nil }

        let safeClearance = max(clearance, minimumPointerClearance)
        let visibleFrame = insetVisibleFrame(screen.visibleFrame, by: screenEdgeInset)
        for quadrant in Quadrant.allCases {
            let frame = proposedFrame(
                near: pointer,
                size: size,
                clearance: safeClearance,
                quadrant: quadrant
            )
            if visibleFrame.contains(frame) {
                return Result(frame: frame, quadrant: quadrant, screen: screen)
            }
        }

        let preferred = proposedFrame(
            near: pointer,
            size: size,
            clearance: safeClearance,
            quadrant: .lowerRight
        )
        return Result(
            frame: clamped(preferred, to: visibleFrame),
            quadrant: .lowerRight,
            screen: screen
        )
    }

    static func shouldReacquire(
        from previousPointer: CGPoint,
        on previousScreen: Screen,
        to currentPointer: CGPoint,
        on currentScreen: Screen,
        threshold: CGFloat = movementThreshold
    ) -> Bool {
        guard previousScreen == currentScreen else { return true }
        let distance = hypot(
            currentPointer.x - previousPointer.x,
            currentPointer.y - previousPointer.y
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
        near pointer: CGPoint,
        size: CGSize,
        clearance: CGFloat,
        quadrant: Quadrant
    ) -> CGRect {
        let x: CGFloat
        let y: CGFloat
        switch quadrant {
        case .lowerRight:
            x = pointer.x + clearance
            y = pointer.y - clearance - size.height
        case .lowerLeft:
            x = pointer.x - clearance - size.width
            y = pointer.y - clearance - size.height
        case .upperRight:
            x = pointer.x + clearance
            y = pointer.y + clearance
        case .upperLeft:
            x = pointer.x - clearance - size.width
            y = pointer.y + clearance
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
