import Foundation
import SwiftUI
import Testing
@testable import MuesliNativeApp

@Suite("Motion and Reduce Motion")
struct MotionTests {
    @Test("the durations are the ones the floating surfaces ship")
    func durationsMatchSparkSurfaces() {
        #expect(MuesliTheme.Motion.morph == DictationMiniRendering.morphDuration)
        #expect(MuesliTheme.Motion.fade == DictationMiniRendering.appearanceFadeDuration)
        #expect(MuesliTheme.Motion.popIn == DictationMiniRendering.appearancePopDuration)
    }

    @Test("motion resolves normally when Reduce Motion is off")
    func normalMotionAnimates() {
        #expect(MuesliTheme.Motion.eased(0.16, reduceMotion: false) != nil)
        #expect(MuesliTheme.Motion.easedOut(0.2, reduceMotion: false) != nil)
        #expect(MuesliTheme.Motion.repeating(0.9, autoreverses: false, reduceMotion: false) != nil)
        #expect(MuesliTheme.Motion.pulsing(1.05, reduceMotion: false) != nil)
    }

    @Test("Reduce Motion removes the animation rather than shortening it")
    func reduceMotionRemovesAnimation() {
        // This is the distinction that matters. A shorter animation still interpolates a
        // changed offset, scale or position, so the user still sees movement. nil applies the
        // state change with no interpolation at all.
        #expect(MuesliTheme.Motion.eased(0.16, reduceMotion: true) == nil)
        #expect(MuesliTheme.Motion.easedOut(0.2, reduceMotion: true) == nil)
    }

    @Test("a repeating animation stops under Reduce Motion instead of running faster")
    func reduceMotionStopsRepeating() {
        #expect(MuesliTheme.Motion.repeating(0.9, autoreverses: false, reduceMotion: true) == nil)
        #expect(MuesliTheme.Motion.pulsing(1.05, reduceMotion: true) == nil)
    }
}

@Suite("Motion source boundary")
struct MotionSourceTests {
    @Test("main-window views animate through the shared motion path")
    func windowAnimationsUseTheResolver() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesDirectory = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MuesliNativeApp")

        // Floating surfaces own their own motion. Onboarding is out of scope for this slice
        // and still animates directly; it is named here so the exemption is visible rather
        // than silently folded into the exclusion list.
        let exempt = [
            "DictationMini", "ContextualSpark", "FloatingMeeting", "FloatingIndicator",
            "MeetingRecordingPanel", "MeetingPanel",
            "Onboarding",
            // These resolve Reduce Motion themselves through the SwiftUI environment.
            "StatsHeaderView", "FeatureTourView", "InsightsView",
            // A marquee that is skipped wholesale under Reduce Motion.
            "MeetingDetailView",
        ]

        let names = try FileManager.default
            .contentsOfDirectory(atPath: sourcesDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .filter { name in !exempt.contains { name.hasPrefix($0) } }

        for name in names {
            let source = try String(
                contentsOf: sourcesDirectory.appendingPathComponent(name),
                encoding: .utf8
            )
            #expect(
                !source.contains("withAnimation(.easeInOut(duration:"),
                "\(name) animates outside the shared motion path"
            )
            #expect(
                !source.contains("withAnimation(.easeOut(duration:"),
                "\(name) animates outside the shared motion path"
            )
        }
    }
}
