import CoreGraphics
import Testing
@testable import MuesliNativeApp

@Suite("Dictation Mini placement")
struct DictationMiniPlacementTests {
    private let primary = DictationMiniPlacement.Screen(
        frame: CGRect(x: 0, y: 0, width: 300, height: 240),
        visibleFrame: CGRect(x: 0, y: 24, width: 300, height: 216)
    )

    @Test("quadrants prefer behind the caret before using forward text space")
    func orderedQuadrants() {
        let size = CGSize(width: 58, height: 22)

        let lowerLeft = DictationMiniPlacement.place(
            near: CGPoint(x: 100, y: 140), size: size, screens: [primary]
        )
        let lowerRight = DictationMiniPlacement.place(
            near: CGPoint(x: 20, y: 140), size: size, screens: [primary]
        )
        let upperLeft = DictationMiniPlacement.place(
            near: CGPoint(x: 100, y: 40), size: size, screens: [primary]
        )
        let upperRight = DictationMiniPlacement.place(
            near: CGPoint(x: 20, y: 40), size: size, screens: [primary]
        )

        #expect(lowerLeft?.quadrant == .lowerLeft)
        #expect(lowerRight?.quadrant == .lowerRight)
        #expect(upperLeft?.quadrant == .upperLeft)
        #expect(upperRight?.quadrant == .upperRight)
        for result in [lowerLeft, lowerRight, upperLeft, upperRight].compactMap({ $0 }) {
            #expect(primary.visibleFrame.contains(result.frame))
        }
    }

    @Test("placement selects negative-origin and vertically offset displays")
    func multiDisplayCoordinates() {
        let negative = DictationMiniPlacement.Screen(
            frame: CGRect(x: -1_280, y: -180, width: 1_280, height: 800),
            visibleFrame: CGRect(x: -1_280, y: -180, width: 1_280, height: 776)
        )
        let result = DictationMiniPlacement.place(
            near: CGPoint(x: -1_100, y: 200),
            size: CGSize(width: 58, height: 22),
            screens: [primary, negative]
        )

        #expect(result?.screen == negative)
        #expect(result.map { negative.visibleFrame.contains($0.frame) } == true)
    }

    @Test("a caret in the full screen frame still selects that screen")
    func caretOutsideVisibleFrame() {
        let result = DictationMiniPlacement.place(
            near: CGPoint(x: 100, y: 10),
            size: CGSize(width: 58, height: 22),
            screens: [primary]
        )

        #expect(result?.screen == primary)
        #expect(result?.frame.minY ?? 0 >= primary.visibleFrame.minY)
    }

    @Test("oversized surfaces remain centered and vertically reachable")
    func oversizedSurface() {
        let result = DictationMiniPlacement.place(
            near: CGPoint(x: 150, y: 120),
            size: CGSize(width: 400, height: 22),
            screens: [primary]
        )

        #expect(result?.frame.midX == primary.visibleFrame.midX)
        #expect(result?.frame.minY ?? 0 >= primary.visibleFrame.minY)
        #expect(result?.frame.maxY ?? .infinity <= primary.visibleFrame.maxY)
    }

    @Test("movement threshold and display transitions control reacquisition")
    func reacquisitionPolicy() {
        let other = DictationMiniPlacement.Screen(
            frame: CGRect(x: 300, y: 0, width: 300, height: 240),
            visibleFrame: CGRect(x: 300, y: 24, width: 300, height: 216)
        )
        let origin = CGPoint(x: 100, y: 100)

        #expect(!DictationMiniPlacement.shouldReacquire(
            from: origin, on: primary, to: CGPoint(x: 103, y: 100), on: primary
        ))
        #expect(DictationMiniPlacement.shouldReacquire(
            from: origin, on: primary, to: CGPoint(x: 104, y: 100), on: primary
        ))
        #expect(DictationMiniPlacement.shouldReacquire(
            from: origin, on: primary, to: CGPoint(x: 101, y: 100), on: other
        ))
    }

    @Test("a disconnected frozen anchor is rehomed without following the caret")
    func frozenFrameRehoming() {
        let surviving = DictationMiniPlacement.Screen(
            frame: CGRect(x: 500, y: 100, width: 200, height: 140),
            visibleFrame: CGRect(x: 500, y: 100, width: 200, height: 140)
        )
        let rehomed = DictationMiniPlacement.rehomeFrozenFrame(
            CGRect(x: -900, y: -300, width: 38, height: 38),
            screens: [surviving]
        )

        #expect(rehomed.map { surviving.visibleFrame.contains($0) } == true)
    }
}
