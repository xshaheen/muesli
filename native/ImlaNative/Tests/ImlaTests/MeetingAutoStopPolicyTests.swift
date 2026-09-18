import Foundation
import Testing
@testable import ImlaNativeApp

@Suite("Meeting activity detection policy")
struct MeetingActivityDetectionPolicyTests {
    @Test("manual recording keeps detection active until recording ends")
    func manualRecordingLifecycle() {
        #expect(MeetingActivityDetectionPolicy.shouldRun(
            showDetectionNotification: false,
            isAutoStopArmed: false,
            isStartingRecording: true,
            isRecording: false
        ))
        #expect(MeetingActivityDetectionPolicy.shouldRun(
            showDetectionNotification: false,
            isAutoStopArmed: false,
            isStartingRecording: false,
            isRecording: true
        ))
        #expect(!MeetingActivityDetectionPolicy.shouldRun(
            showDetectionNotification: false,
            isAutoStopArmed: false,
            isStartingRecording: false,
            isRecording: false
        ))
    }
}

@Suite("Meeting auto-stop policy")
struct MeetingAutoStopPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let room = "meet.google.com/aaa-bbbb-ccc"

    private func candidate(
        id: String = "room-a", url: String? = "meet.google.com/aaa-bbbb-ccc",
        bundle: String? = "com.google.Chrome", media: Bool = true,
        suppressionID: String? = "session-a"
    ) -> MeetingCandidate {
        MeetingCandidate(
            id: id, platform: .googleMeet, appName: "Meeting", url: url,
            evidence: media ? [.audioInputProcess] : [.browserURL],
            startedAt: now, meetingTitle: nil, sourceBundleID: bundle,
            suppressionID: suppressionID
        )
    }

    @Test("matches browser audio fallback by suppression session")
    func matchesBrowserAudioFallbackBySuppressionSession() {
        let source = MeetingAutoStopSource(candidate: googleMeetCandidate())
        let audioFallback = MeetingCandidate(
            id: "browser:com.google.Chrome:session:1800000000",
            platform: .unknown,
            appName: "Chrome",
            url: nil,
            evidence: [.audioInputProcess],
            startedAt: Date(timeIntervalSince1970: 1_800_000_005),
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 9876,
            suppressionID: "browser:com.google.Chrome:session:1800000000"
        )

        #expect(MeetingAutoStopPolicy.matches(candidate: audioFallback, source: source))
    }

    @Test("ignores unrelated browser audio in the same browser")
    func ignoresUnrelatedBrowserAudioInSameBrowser() {
        let source = MeetingAutoStopSource(candidate: googleMeetCandidate())
        let otherTabAudio = MeetingCandidate(
            id: "browser:com.google.Chrome:session:1800000999",
            platform: .unknown,
            appName: "Chrome",
            url: nil,
            evidence: [.audioInputProcess],
            startedAt: Date(timeIntervalSince1970: 1_800_000_005),
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 9876,
            suppressionID: "browser:com.google.Chrome:session:1800000999"
        )

        #expect(!MeetingAutoStopPolicy.matches(candidate: otherTabAudio, source: source))
    }

    @Test("ignores unrelated calendar-only activity")
    func ignoresUnrelatedCalendarOnlyActivity() {
        let source = MeetingAutoStopSource(candidate: googleMeetCandidate())
        let calendarOnly = MeetingCandidate(
            id: "cal:event-2",
            platform: .unknown,
            appName: "Meeting",
            url: nil,
            evidence: [.calendarEvent, .micActive],
            startedAt: Date(timeIntervalSince1970: 1_800_000_010),
            meetingTitle: "Later meeting"
        )

        #expect(!MeetingAutoStopPolicy.matches(candidate: calendarOnly, source: source))
    }

    @Test("creates source from supported meeting URL")
    func createsSourceFromSupportedMeetingURL() throws {
        let url = try #require(URL(string: "https://meet.google.com/aaa-bbbb-ccc?authuser=0"))
        let source = try #require(MeetingAutoStopSource(meetingURL: url))

        #expect(source.candidateID == "googleMeet:meet.google.com/aaa-bbbb-ccc")
        #expect(source.normalizedURL == "meet.google.com/aaa-bbbb-ccc")
        #expect(source.hasObservedCandidate == false)
    }

    @Test("refines URL-only source with observed browser source")
    func refinesURLOnlySourceWithObservedBrowserSource() throws {
        let url = try #require(URL(string: "https://meet.google.com/aaa-bbbb-ccc"))
        let source = try #require(MeetingAutoStopSource(meetingURL: url))

        let refined = source.refined(with: googleMeetCandidate())

        #expect(refined.sourceBundleID == "com.google.Chrome")
        #expect(refined.suppressionID == "browser:com.google.Chrome:session:1800000000")
        #expect(refined.hasObservedCandidate)
    }

    @Test("refinement preserves existing suppression ID when candidate lacks one")
    func refinementPreservesExistingSuppressionIDWhenCandidateLacksOne() throws {
        let url = try #require(URL(string: "https://meet.google.com/aaa-bbbb-ccc"))
        let source = try #require(MeetingAutoStopSource(meetingURL: url))
        let partialCandidate = MeetingCandidate(
            id: "browser:com.google.Chrome:unknown",
            platform: .unknown,
            appName: "Chrome",
            url: nil,
            evidence: [.audioInputProcess],
            startedAt: Date(timeIntervalSince1970: 1_800_000_005),
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 9876,
            suppressionID: nil
        )

        let refined = source.refined(with: partialCandidate)

        #expect(refined.suppressionID == "googleMeet:meet.google.com/aaa-bbbb-ccc")
        #expect(refined.hasObservedCandidate)
    }

    @Test("candidate source starts as observed")
    func candidateSourceStartsObserved() {
        let source = MeetingAutoStopSource(candidate: googleMeetCandidate())

        #expect(source.hasObservedCandidate)
    }

    @Test("manual recording can adopt meeting evidence observed after start")
    func manualRecordingCanAdoptLateMeetingEvidence() {
        var tracker = MeetingAutoStopTracker()
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        tracker.arm(source: nil, allowLateArmingUntil: now.addingTimeInterval(15))

        let didArm = tracker.armFromObservedCandidateIfNeeded(teamsCandidate(), now: now)
        #expect(didArm)
        #expect(tracker.source == MeetingAutoStopSource(candidate: teamsCandidate()))
        #expect(tracker.lastSeenAt == now)
        let warnedBeforeGracePeriod = tracker.observe(
            candidate: nil,
            now: now.addingTimeInterval(19),
            gracePeriod: 20
        )
        let warnedAtGracePeriod = tracker.observe(
            candidate: nil,
            now: now.addingTimeInterval(20),
            gracePeriod: 20
        )
        #expect(!warnedBeforeGracePeriod)
        #expect(warnedAtGracePeriod)
    }

    @Test("manual recording ignores unrelated meeting evidence after the late-arm window")
    func manualRecordingIgnoresEvidenceAfterLateArmWindow() {
        var tracker = MeetingAutoStopTracker()
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        tracker.arm(source: nil, allowLateArmingUntil: now.addingTimeInterval(15))

        let didArm = tracker.armFromObservedCandidateIfNeeded(
            teamsCandidate(),
            now: now.addingTimeInterval(16)
        )

        #expect(!didArm)
        #expect(!tracker.isArmed)
    }

    @Test("late evidence does not replace an already armed source")
    func lateEvidenceDoesNotReplaceArmedSource() {
        let originalSource = MeetingAutoStopSource(candidate: googleMeetCandidate())
        var tracker = MeetingAutoStopTracker()
        tracker.arm(source: originalSource)

        let didReplaceSource = tracker.armFromObservedCandidateIfNeeded(
            teamsCandidate(),
            now: Date(timeIntervalSince1970: 1_800_000_100)
        )
        #expect(!didReplaceSource)
        #expect(tracker.source == originalSource)
    }

    @Test("manual start origin warns when a meeting signal is available")
    func manualStartOriginWarnsWhenMeetingSignalIsAvailable() {
        let explicitSource = MeetingAutoStopSource(candidate: googleMeetCandidate())
        let recentSource = MeetingAutoStopSource(candidate: teamsCandidate())

        let resolvedSource = MeetingRecordingStartOrigin.manual.signalLossSource(
            explicitSource: explicitSource,
            recentSource: recentSource
        )

        #expect(!MeetingRecordingStartOrigin.manual.enablesMeetingAutoStop)
        #expect(MeetingRecordingStartOrigin.manual.signalLossResponse == .warnOnly)
        #expect(resolvedSource == explicitSource)
        #expect(MeetingRecordingStartOrigin.manual.signalLossSource(
            explicitSource: nil,
            recentSource: recentSource
        ) == recentSource)
        #expect(MeetingRecordingStartOrigin.manual.signalLossSource(
            explicitSource: nil,
            recentSource: nil
        ) == nil)
    }

    @Test("source-backed start origins can auto-stop after warning")
    func sourceBackedStartOriginsCanAutoStopAfterWarning() {
        let explicitSource = MeetingAutoStopSource(candidate: googleMeetCandidate())
        let recentSource = MeetingAutoStopSource(candidate: teamsCandidate())
        let origins: [MeetingRecordingStartOrigin] = [
            .detectedPrompt,
            .calendarAutoRecord,
            .scheduledMeetingPrompt,
            .joinAndRecord,
        ]

        for origin in origins {
            #expect(origin.enablesMeetingAutoStop)
            #expect(origin.signalLossResponse == .autoStopAfterWarning)
            #expect(origin.signalLossSource(explicitSource: explicitSource, recentSource: recentSource) == explicitSource)
            #expect(origin.signalLossSource(explicitSource: nil, recentSource: recentSource) == recentSource)
        }
    }

    @Test("room identity wins over browser attribution and shared suppression IDs")
    func roomMatching() {
        let source = MeetingAutoStopSource(candidate: candidate())
        let cases: [(MeetingCandidate, Bool)] = [
            (candidate(), true),
            (candidate(id: "calendar-wrapped", suppressionID: "calendar"), true),
            (candidate(id: "audio-fallback", url: nil), true),
            (candidate(id: "new-session", url: nil, suppressionID: "new"), true),
            (candidate(id: "helper", url: nil, bundle: "com.google.Chrome.helper", suppressionID: "new"), true),
            (candidate(id: "foreground", url: nil, media: false, suppressionID: "new"), false),
            (candidate(id: "safari", url: nil, bundle: "com.apple.Safari", suppressionID: "new"), false),
            (candidate(id: "unattributed", url: nil, bundle: nil, suppressionID: "new"), false),
            (candidate(id: "room-b", url: "meet.google.com/zzz-yyyy-xxx", suppressionID: "new"), false),
            // Even a reused browser session or candidate ID cannot override a conflicting URL.
            (candidate(url: "meet.google.com/zzz-yyyy-xxx"), false)
        ]
        for (observed, expected) in cases {
            #expect(MeetingAutoStopPolicy.matches(candidate: observed, source: source) == expected)
        }
    }

    @Test("native source survives new helper/session identity, but not another app")
    func nativeMatching() {
        let source = MeetingAutoStopSource(candidate: candidate(url: nil, bundle: "com.microsoft.teams2"))
        #expect(MeetingAutoStopPolicy.matches(
            candidate: candidate(id: "new", url: nil, bundle: "com.microsoft.teams2.helper", suppressionID: "new"), source: source
        ))
        #expect(!MeetingAutoStopPolicy.matches(
            candidate: candidate(id: "new", url: nil, bundle: "us.zoom.xos", suppressionID: "new"), source: source
        ))
    }

    @Test("URL-only sources need observation and retain identity during refinement")
    func refinement() throws {
        let url = try #require(URL(string: "https://\(room)?authuser=0"))
        let source = try #require(MeetingAutoStopSource(meetingURL: url))
        #expect(source.candidateID == "googleMeet:\(room)")
        #expect(source.normalizedURL == room && !source.hasObservedCandidate)
        #expect(!MeetingAutoStopPolicy.matches(candidate: candidate(id: "fallback", url: nil), source: source))
        let refined = source.refined(with: candidate())
        #expect(refined.sourceBundleID == "com.google.Chrome" && refined.hasObservedCandidate)
        #expect(refined.suppressionID == "session-a")
        #expect(refined.normalizedURL == room)
        let partial = source.refined(with: candidate(id: "partial", url: nil, suppressionID: nil))
        #expect(partial.suppressionID == source.suppressionID)
        #expect(MeetingAutoStopSource(candidate: candidate()).hasObservedCandidate)
    }

    @Test("only source-backed origins enable auto-stop", arguments: [
        MeetingRecordingStartOrigin.manual, .detectedPrompt, .calendarAutoRecord,
        .scheduledMeetingPrompt, .joinAndRecord
    ])
    func startOrigin(origin: MeetingRecordingStartOrigin) {
        let explicit = MeetingAutoStopSource(candidate: candidate())
        let recent = MeetingAutoStopSource(candidate: candidate(id: "recent", url: nil))
        let enabled = origin != .manual
        #expect(origin.enablesMeetingAutoStop == enabled)
        #expect(origin.signalLossResponse == (enabled ? .autoStopAfterWarning : .none))
        #expect(origin.signalLossSource(explicitSource: explicit, recentSource: recent) == (enabled ? explicit : nil))
        #expect(origin.signalLossSource(explicitSource: nil, recentSource: recent) == (enabled ? recent : nil))
    }

    @Test("source recovery reopens prompts unless the user dismissed them", arguments: [false, true])
    func promptLifetime(dismissed: Bool) {
        var state = MeetingSignalLossPromptState()
        #expect(state.canPresentPrompt)
        state.markPromptPresented()
        #expect(!state.canPresentPrompt)
        if dismissed { state.markDismissedByUser() }
        state.markSourceRecovered()
        #expect(state.canPresentPrompt == !dismissed)
        state.resetForRecording()
        #expect(state.canPresentPrompt)
    }

    @Test("unobserved source cannot auto-stop; confirmed source uses disappearance grace")
    func disappearance() throws {
        var tracker = MeetingAutoStopTracker()
        let url = try #require(URL(string: "https://\(room)"))
        tracker.arm(source: MeetingAutoStopSource(meetingURL: url))
        let shouldStop1 = tracker.observe(candidate: nil, now: now, gracePeriod: 20)
        #expect(!shouldStop1)
        #expect(tracker.lastSeenAt == nil)
        let shouldStop2 = tracker.observe(candidate: candidate(), now: now, gracePeriod: 20)
        #expect(!shouldStop2)
        #expect(tracker.source?.sourceBundleID == "com.google.Chrome")
        #expect(tracker.source?.hasObservedCandidate == true)
        let shouldStop3 = tracker.observe(candidate: nil, now: now.addingTimeInterval(19), gracePeriod: 20)
        #expect(!shouldStop3)
        let shouldStop4 = tracker.observe(candidate: nil, now: now.addingTimeInterval(21), gracePeriod: 20)
        #expect(shouldStop4)
        tracker.disarm()
        #expect(!tracker.isArmed && tracker.lastSeenAt == nil)
    }

    @Test("media fallback extends grace, but a different known room does not")
    func fallbackGrace() {
        var tracker = MeetingAutoStopTracker()
        tracker.arm(source: MeetingAutoStopSource(candidate: candidate()))
        let shouldStop5 = tracker.observe(candidate: candidate(), now: now, gracePeriod: 20)
        #expect(!shouldStop5)
        let shouldStop6 = tracker.observe(candidate: candidate(id: "fallback", url: nil, suppressionID: "new"),
                                now: now.addingTimeInterval(30), gracePeriod: 20)
        #expect(!shouldStop6)
        let shouldStop7 = tracker.observe(candidate: nil, now: now.addingTimeInterval(49), gracePeriod: 20)
        #expect(!shouldStop7)
        let shouldStop8 = tracker.observe(candidate: candidate(id: "room-b", url: "meet.google.com/zzz-yyyy-xxx"),
                               now: now.addingTimeInterval(51), gracePeriod: 20)
        #expect(shouldStop8)
    }

    @Test("startup observation starts grace at recording start, not preparation")
    func preparationGrace() throws {
        var tracker = MeetingAutoStopTracker()
        let url = try #require(URL(string: "https://\(room)"))
        tracker.arm(source: MeetingAutoStopSource(meetingURL: url))
        tracker.observeBeforeRecordingStarted(candidate: candidate())
        tracker.markRecordingStarted(now: now.addingTimeInterval(10))
        #expect(tracker.source?.sourceBundleID == "com.google.Chrome")
        let shouldStop9 = tracker.observe(candidate: nil, now: now.addingTimeInterval(29), gracePeriod: 20)
        #expect(!shouldStop9)
        let shouldStop10 = tracker.observe(candidate: nil, now: now.addingTimeInterval(31), gracePeriod: 20)
        #expect(shouldStop10)
    }
}
