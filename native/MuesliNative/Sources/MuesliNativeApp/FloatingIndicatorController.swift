import AppKit
import QuartzCore
import Foundation
import MuesliCore
import os

enum FloatingIndicatorPointerIntent {
    static let dragThreshold: CGFloat = 6
    /// A release closer to the press than this is a click that wobbled, not a drag:
    /// clicks carry a few points of jitter, and starting a drag collapses the
    /// hover-expanded pill under the pointer — so a misread click visibly
    /// displaces the pill and then persists the accident.
    static let deliberateDragDistance: CGFloat = 12

    static func isDrag(from start: NSPoint, to current: NSPoint) -> Bool {
        hypot(current.x - start.x, current.y - start.y) >= dragThreshold
    }

    static func isDeliberateDrag(from start: NSPoint, to current: NSPoint) -> Bool {
        hypot(current.x - start.x, current.y - start.y) >= deliberateDragDistance
    }
}

final class InteractiveFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class HoverIndicatorView: NSView {
    weak var owner: FloatingIndicatorController?
    private var trackingAreaRef: NSTrackingArea?
    private var mouseDownScreenLocation: NSPoint?
    private var dragOriginScreenLocation: NSPoint?
    private var windowOriginAtDragStart: NSPoint?
    private var didDrag = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        owner?.setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        owner?.scheduleHoverExit()
    }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        mouseDownScreenLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let mouseDownScreenLocation else { return }
        let currentScreenLocation = NSEvent.mouseLocation
        guard didDrag || FloatingIndicatorPointerIntent.isDrag(
            from: mouseDownScreenLocation,
            to: currentScreenLocation
        ) else { return }
        if !didDrag {
            didDrag = true
            // The collapse belongs here rather than in mouseDown: it displaces the pill,
            // and a plain click must leave the geometry it found alone.
            //
            // It also moves the window under the pointer, so both the origin the deltas
            // apply to and the point they are measured from have to be read after it
            // runs -- otherwise the first delta is applied to a stale origin.
            owner?.pointerDragBegan()
            windowOriginAtDragStart = window.frame.origin
            dragOriginScreenLocation = currentScreenLocation
            return
        }
        guard let windowOriginAtDragStart, let dragOriginScreenLocation else { return }
        let origin = NSPoint(
            x: windowOriginAtDragStart.x + (currentScreenLocation.x - dragOriginScreenLocation.x),
            y: windowOriginAtDragStart.y + (currentScreenLocation.y - dragOriginScreenLocation.y)
        )
        window.setFrameOrigin(owner?.clampedDragOrigin(origin, size: window.frame.size) ?? origin)
    }

    override func mouseUp(with event: NSEvent) {
        let releasedNearPress = mouseDownScreenLocation.map {
            !FloatingIndicatorPointerIntent.isDeliberateDrag(from: $0, to: NSEvent.mouseLocation)
        } ?? false
        if didDrag, releasedNearPress {
            // The wobble crossed the drag threshold but the release came back to the
            // press: a click. The collapse already moved the pill, so snap it home
            // instead of persisting the accident, then deliver the click.
            owner?.abandonDragAsClick(atX: convert(event.locationInWindow, from: nil).x,
                                      optionClick: event.modifierFlags.contains(.option))
        } else if didDrag {
            owner?.savePosition()
        } else if event.modifierFlags.contains(.option) {
            owner?.handleOptionClick()
        } else {
            let clickX = convert(event.locationInWindow, from: nil).x
            owner?.handleClick(atX: clickX)
        }
        owner?.pointerInteractionEnded()
        mouseDownScreenLocation = nil
        dragOriginScreenLocation = nil
        windowOriginAtDragStart = nil
        didDrag = false
    }

    override func rightMouseUp(with event: NSEvent) {
        owner?.handleOptionClick()
    }
}

@MainActor
final class FloatingIndicatorController: NSObject {
    private var panel: NSPanel?
    private var containerView: NSView?
    private var contentView: HoverIndicatorView?
    private var iconLabel: NSTextField?
    private var textLabel: NSTextField?
    private var state: DictationState = .idle
    private var isHovered = false
    private var hoverExitWorkItem: DispatchWorkItem?
    private var warningDismissWorkItem: DispatchWorkItem?
    private let configStore: ConfigStore
    private var isMeetingRecording = false
    private var isMeetingRecordingPaused = false
    private var isMeetingTranscriptManuallyDismissed = false
    private lazy var meetingTranscriptPanel = FloatingMeetingTranscriptPanelController(
        onOpenNotes: { [weak self] in
            self?.openMeetingNotesFromTranscript()
        },
        onDismiss: { [weak self] in
            self?.dismissMeetingTranscript()
        }
    )
    private var glassView: NSVisualEffectView?
    private var tintLayer: CALayer?
    private var micIconView: NSImageView?
    private var wandIconView: NSImageView?
    private var barLayers: [CALayer] = []
    private var amplitudeTimer: Timer?
    private var smoothedAmplitude: CGFloat = 0
    private var waveformAnimationMode: WaveformAnimationMode = .level
    private var recordingWaveformMode: WaveformAnimationMode = .level
    private var waveformAnimationStartedAt = Date()
    fileprivate var isDragging = false
    // Captured when a drag begins: the anchor the pill was placed from (read before the
    // collapse, which does not move it), where the collapse left the pill (read after),
    // and the displays the drag may cross.
    private var dragStartAnchorCenter: CGPoint?
    private var dragStartPillCenter: CGPoint?
    private var dragScreenFrames: [NSRect] = []
    var powerProvider: (() -> Float)?
    var onStopMeeting: (() -> Void)?
    var onDiscardMeeting: (() -> Void)?
    var onToggleMeetingPause: (() -> Void)?
    var onOpenMeetingNotes: (() -> Void)?
    var onCancelToggleDictation: (() -> Void)?
    var onPositionSaved: ((CGPoint) -> Void)?
    private var stopLayer: CALayer?
    private var panelToggleLayer: CALayer?
    private var transcribingTitle = "Transcribing"
    private var computerUseTranscriptText: String?
    private var loadingSpinner: NSProgressIndicator?
    private var isShowingLoading = false
    private var isComputerUseCursorMode = false
    private var computerUseCursorReturnFrame: NSRect?
    /// The frame the last layout pass asked for.
    ///
    /// `panel.frame` reports the interpolated rect while an animation is in flight, so
    /// anything that places itself relative to the pill right after a transition inherits
    /// a position the pill is only passing through.
    private var lastAppliedIndicatorFrame: NSRect?
    /// Bumped by every pass that rewrites the pill's chrome, so work deferred to the end
    /// of a transition can tell whether it is still the current one.
    private var chromeGeneration: UInt64 = 0
    /// The generation whose waveform layout is still waiting on a transition to finish.
    ///
    /// Compared against the live generation rather than cleared by hand: anything that
    /// claims the chrome bumps that counter, which is exactly what makes this marker
    /// stale, so there is no cancellation path to keep in step.
    private var pendingWaveformChromeGeneration: UInt64?
    private var hasPendingWaveformChrome: Bool { pendingWaveformChromeGeneration == chromeGeneration }

    private static let logger = Logger(subsystem: "com.muesli.native", category: "FloatingIndicator")

    private enum WaveformAnimationMode {
        case level
        case waiting
    }

    init(configStore: ConfigStore) {
        self.configStore = configStore
        super.init()
        meetingTranscriptPanel.savedOriginProvider = { [weak self] in
            self?.configStore.load().meetingPanelOrigin.map { CGPoint(x: $0.x, y: $0.y) }
        }
        // Display attach/detach moves windows without the app's involvement: macOS
        // constrains them onto whatever screens remain, leaving the pill wherever it
        // landed until the next state change. Re-resolve it from its anchor as soon as
        // the topology settles. The transcript is not re-placed here -- it is a window
        // the user positioned, and its saved origin is re-clamped onto an attached
        // screen at the next show.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleScreenReconfigurationRelayout()
        }
    }

    private var screenRelayoutWorkItem: DispatchWorkItem?

    /// Screen-parameter notifications arrive in bursts during a reconfiguration;
    /// coalesce them and re-layout once the topology has settled.
    private func scheduleScreenReconfigurationRelayout() {
        screenRelayoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            // A loading pill is excluded along with the drag and the cursor: setState knows
            // nothing about the spinner, so re-framing through it would strand the spinner
            // on an idle pill and leave the flag latched with it.
            guard let self, panel != nil, !isDragging, !isComputerUseCursorMode, !isShowingLoading else { return }
            Self.logger.notice("screens changed; re-resolving pill")
            setState(state, config: configStore.load())
        }
        screenRelayoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    var onStopToggleDictation: (() -> Void)?

    /// Persists the user's panel position; wired by MuesliController to config.
    var onMeetingPanelPositionSaved: ((CGPoint) -> Void)? {
        get { meetingTranscriptPanel.onUserMovedPanel }
        set { meetingTranscriptPanel.onUserMovedPanel = newValue }
    }

    /// Whether the transcript window is on screen, for the menu item's title.
    var isMeetingTranscriptPanelVisible: Bool { meetingTranscriptPanel.isVisible }

    /// Menu-bar toggle: shows the transcript at the user's saved position (or beside
    /// the pill on first use) regardless of hover state, or hides a visible one.
    ///
    /// Both directions are deliberate, so both move the latch: hiding from here suppresses
    /// hover-to-show for the rest of the meeting exactly as the chevron does, and showing
    /// from here is the way back.
    func toggleMeetingTranscriptPanel() {
        if meetingTranscriptPanel.isVisible {
            isMeetingTranscriptManuallyDismissed = true
            hideMeetingTranscript()
        } else {
            isMeetingTranscriptManuallyDismissed = false
            showMeetingTranscript()
        }
    }

    var currentFrame: NSRect? {
        indicatorScreenFrame
    }

    func pointerDragBegan() {
        // The anchor the pill was placed from, read before the collapse: the collapse
        // resizes and moves the pill but does not change where it is anchored. The
        // settled frame rather than the live one, so a drag started mid-transition
        // measures against the rect the pill is arriving at instead of one it is only
        // passing through.
        let settledFrame = lastAppliedIndicatorFrame ?? indicatorScreenFrame
        dragStartAnchorCenter = customAnchorCenter ?? settledFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
        dragScreenFrames = NSScreen.screens.map(\.visibleFrame)
        collapseForDrag()
        // Where the collapse actually left the pill, read after it runs rather than
        // before. A wide state is clamped inward from its anchor and the collapse undoes
        // that clamp; measuring the drag from the pre-collapse centre would carry the
        // clamp into the saved anchor on top of the movement, so a drop a few points
        // from the grab could migrate the anchor by the full clamp. The live frame, not
        // the applied one: the collapse ends by moving the window off it to put the grab
        // back under the pointer.
        dragStartPillCenter = indicatorScreenFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    func pointerInteractionEnded() {
        isDragging = false
        dragStartAnchorCenter = nil
        dragStartPillCenter = nil
        dragScreenFrames = []
    }

    /// Clamps a dragged origin so the pill's centre stays on a display.
    ///
    /// Runs on every mouse-moved event, so it works from the screen list captured at
    /// drag start rather than re-reading it each time.
    fileprivate func clampedDragOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let screens = dragScreenFrames.isEmpty ? NSScreen.screens.map(\.visibleFrame) : dragScreenFrames
        return Self.clampedDragOrigin(origin, size: size, screens: screens)
    }

    func handleClick(atX x: CGFloat? = nil) {
        guard state == .recording else { return }
        if isMeetingRecording {
            switch Self.meetingRecordingPillAction(
                clickX: x,
                pauseRegionMaxX: recordingPauseRegionMaxX(),
                panelToggleRegion: panelToggleHitRegion(),
                stopRegionMinX: stopHitRegionMinX()
            ) {
            case .togglePause: onToggleMeetingPause?()
            case .togglePanel: toggleMeetingTranscriptPanel()
            case .stop: onStopMeeting?()
            case .ignore: break
            }
            return
        }
        if let x, x < recordingPauseRegionMaxX() {
            onCancelToggleDictation?()
            return
        }
        onStopToggleDictation?()
    }

    enum MeetingRecordingPillAction: Equatable {
        case togglePause
        case togglePanel
        case stop
        case ignore
    }

    /// Maps a click on the meeting pill to its control: pause on the left, the
    /// panel toggle beside it, stop only in its own trailing region. The waveform
    /// strip between them is display, not a control — a meeting must not stop
    /// because a click meant for a nearby control missed by a few points.
    static func meetingRecordingPillAction(
        clickX: CGFloat?,
        pauseRegionMaxX: CGFloat,
        panelToggleRegion: ClosedRange<CGFloat>?,
        stopRegionMinX: CGFloat
    ) -> MeetingRecordingPillAction {
        guard let clickX else { return .ignore }
        if clickX < pauseRegionMaxX { return .togglePause }
        if let panelToggleRegion, panelToggleRegion.contains(clickX) { return .togglePanel }
        if clickX >= stopRegionMinX { return .stop }
        return .ignore
    }

    /// The panel toggle's hit region: the comfortable minimum width centred on the
    /// glyph, stopping short of the pause region and the stop square.
    private func panelToggleHitRegion() -> ClosedRange<CGFloat>? {
        guard let panelToggleLayer, panelToggleLayer.superlayer != nil else { return nil }
        let mid = panelToggleLayer.frame.midX
        let lower = max(recordingPauseRegionMaxX(), mid - Self.minimumControlHitWidth / 2)
        let upper = min(stopLayer?.frame.minX ?? .greatestFiniteMagnitude, mid + Self.minimumControlHitWidth / 2)
        guard lower < upper else { return nil }
        return lower...upper
    }

    /// Where the stop control's hit region begins: the comfortable minimum width
    /// centred on the square, never reaching back into the panel toggle. Falls back
    /// to the historical everything-right-of-pause behavior if the square is
    /// somehow missing, so the pill can never lose its stop control.
    private func stopHitRegionMinX() -> CGFloat {
        guard let stopLayer, stopLayer.superlayer != nil else {
            return recordingPauseRegionMaxX()
        }
        return max(
            panelToggleHitRegion()?.upperBound ?? recordingPauseRegionMaxX(),
            stopLayer.frame.midX - Self.minimumControlHitWidth / 2
        )
    }

    /// Where the leading control's hit region ends on a recording pill.
    ///
    /// Derived from the chrome rather than fixed at 30pt: the glyph and the stop square
    /// are both laid out against the pill's width, so on a pill that is not 76pt wide a
    /// constant split falls in the middle of neither control. The glyph itself is 10pt
    /// across -- too small to aim at -- so its region is the minimum comfortable target
    /// centred on it, stopping short of the stop square. Everything to the right of it
    /// stops the recording, which is what the pill's trailing side has always done.
    private func recordingPauseRegionMaxX() -> CGFloat {
        guard let iconLabel, !iconLabel.isHidden, iconLabel.frame.width > 0 else { return 0 }
        let padded = iconLabel.frame.midX + Self.minimumControlHitWidth / 2
        guard let stopMinX = stopLayer?.frame.minX else { return padded }
        return min(padded, stopMinX)
    }

    func handleOptionClick() {
        if isMeetingRecording, state == .recording {
            onDiscardMeeting?()
        } else if state == .recording {
            onCancelToggleDictation?()
        }
    }

    func collapseForDrag() {
        isDragging = true
        // The collapse lays out its own chrome below, so any still-pending layout from the
        // transition it interrupts -- a hover expansion, most often -- is stale now.
        chromeGeneration &+= 1
        hoverExitWorkItem?.cancel()

        // Where the pill sits and where the pointer grabbed it, both read before the
        // resize below moves either.
        //
        // The settled frame rather than the live one: a window animation reports an
        // interpolated rect while it runs, so a drag started mid-transition would map
        // the grab against a size and origin the pill is only passing through.
        let pillScreenFrame = lastAppliedIndicatorFrame ?? indicatorScreenFrame
        let grabPoint = NSEvent.mouseLocation

        guard !isShowingLoading,
              let panel,
              let contentView,
              let iconLabel,
              let textLabel else {
            // A declined collapse still leaves the drag running, so settle any transition
            // in flight onto the frame the pill already has: setFrameOrigin does not stop
            // a running animation, and its next step would overwrite what the drag writes.
            // The frame itself is kept on purpose -- whatever declined the collapse, the
            // loading pill above all, owns its own geometry.
            if let panel { applyIndicatorFrame(lastAppliedIndicatorFrame ?? panel.frame) }
            return
        }
        // Only idle has a hover expansion to drop; every other state keeps its size.
        if state == .idle { isHovered = false }

        let config = configStore.load()
        let style = styleForState(state, config: config)
        let targetFrame = frameForState(state, config: config)

        let localIndicator = applyIndicatorFrame(targetFrame)
        // Put it back under the pointer. After the collapse the window is the pill, so
        // its origin is the pill's origin.
        if let pillScreenFrame {
            panel.setFrameOrigin(Self.collapsedDragOrigin(
                pillFrame: pillScreenFrame,
                collapsedSize: targetFrame.size,
                grabPoint: grabPoint
            ))
        }

        contentView.layer?.backgroundColor = style.background.cgColor
        contentView.layer?.borderColor = style.border.cgColor
        glassView?.frame = NSRect(origin: .zero, size: localIndicator.size)
        panel.alphaValue = style.alpha

        if state == .recording {
            // Through the same helper setState uses, not the generic icon/title layout:
            // that centres the glyph over the waveform at whatever font the previous
            // state left behind, which is what turned the pause control into a smeared
            // block the moment a recording pill was dragged.
            applyRecordingControlChrome(
                iconLabel: iconLabel,
                textLabel: textLabel,
                in: targetFrame.size,
                animated: false
            )
        } else {
            iconLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
            iconLabel.stringValue = style.icon
            iconLabel.textColor = style.iconColor
            let hasTitle = !style.title.isEmpty
            textLabel.stringValue = style.title
            textLabel.isHidden = !hasTitle
            textLabel.alphaValue = hasTitle ? 1 : 0
            layoutLabels(iconLabel: iconLabel, textLabel: textLabel, in: targetFrame.size, hasTitle: hasTitle, animated: false)
        }

        // Re-apply the chrome for whatever state we are actually in.
        //
        // This used to run only for idle, so dragging during a recording resized the
        // window and stopped -- leaving the tint layer and waveform bars laid out for
        // the old geometry. A recording pill has a clear
        // background and a hidden glass view, so those two *are* its entire visible
        // appearance: stale, they render as nothing and the pill vanishes.
        applyGlassState(state, frameSize: targetFrame.size)
        applyWaveformChrome(for: state, mode: recordingWaveformMode, in: targetFrame.size)
        // setState orders the panel front after every transition; a drag resizes the
        // same way and needs the same guarantee.
        panel.orderFrontRegardless()
    }

    /// A drag that ended back at its press point was a click that wobbled. The
    /// collapse already displaced the pill under the pointer, so re-resolve it from
    /// its unchanged anchor — no position is saved — and deliver the click.
    func abandonDragAsClick(atX x: CGFloat, optionClick: Bool) {
        isDragging = false
        dragStartAnchorCenter = nil
        dragStartPillCenter = nil
        dragScreenFrames = []
        setState(state, config: configStore.load())
        if optionClick {
            handleOptionClick()
        } else {
            handleClick(atX: x)
        }
    }

    func savePosition() {
        guard let frame = indicatorScreenFrame else { return }
        let liveCenter = CGPoint(x: frame.midX, y: frame.midY)
        // No captures means the drag was interrupted rather than dropped -- the
        // computer-use cursor ends one out from under the pointer -- and the anchor it
        // started from still stands. Adopting the live centre here would persist wherever
        // the cursor pill happened to be pointing.
        guard let anchor = dragStartAnchorCenter, let start = dragStartPillCenter else { return }
        // Move the anchor by as far as the drag moved the pill, instead of adopting the
        // pill's own centre. In a wide state the live frame is clamped inward, so adopting
        // it turns a 5pt nudge into a permanent ~60pt migration of the anchor; the delta
        // carries the same movement without inheriting the clamp.
        let moved = Self.draggedAnchorCenter(
            anchorAtDragStart: anchor,
            pillCenterAtDragStart: start,
            pillCenterAtDrop: liveCenter
        )
        let home = Self.screenVisibleFrame(containing: moved) ?? Self.primaryVisibleFrame
        let center = home.map {
            Self.clampedAnchorCenter(moved, in: $0, size: Self.idleIndicatorSize)
        } ?? moved
        // Update in memory as well as in config: config round-trips through the
        // owning controller, and a collapse landing before that completes would
        // otherwise snap the pill back to where it was before the drag.
        customAnchorCenter = center
        // The drag is over the moment its position is saved, and the flag has to say so
        // before the callback runs: the config write it triggers re-lays the pill out
        // synchronously, and that is the pass which reconciles the frame with the anchor
        // just stored. Leaving the flag up would have the guard swallow it.
        isDragging = false
        onPositionSaved?(center)
        // Reconcile locally too, and after the callback so this pass sees whatever it
        // wrote. The config round-trip is not a reliable repair on its own: it re-lays
        // the pill out only when the clamped centre actually differs from the stored one,
        // so a drop that lands back on the saved position leaves the chrome laid out
        // against the mid-drag geometry for good.
        setState(state, config: configStore.load())
    }

    func setToggleDictation(_ active: Bool, config: AppConfig) {
        if active {
            setState(.recording, config: config)
        } else {
            removeStopLayer()
            // The provider belongs to the recording that just ended; a stale one would
            // drive the next waveform from an audio engine that is no longer running.
            powerProvider = nil
            setState(.idle, config: config)
        }
    }

    func setMeetingRecording(_ recording: Bool, config: AppConfig) {
        isMeetingRecording = recording
        recordingWaveformMode = .level
        // A dismissal holds for the meeting it was made in, and no longer: letting it
        // survive the boundary leaves hover-to-show dead in a meeting the user dismissed
        // nothing in.
        isMeetingTranscriptManuallyDismissed = false
        if !recording {
            isMeetingRecordingPaused = false
            hideMeetingTranscript(reset: true)
            // The provider reads the meeting session's level; the session is gone.
            powerProvider = nil
        }
        if recording {
            clearLoadingChrome()
            setState(.recording, config: config)
        } else {
            setState(.idle, config: config)
        }
    }

    func setRecordingWaveformWaiting(config: AppConfig) {
        recordingWaveformMode = .waiting
        guard state == .recording else { return }
        reapplyWaveformChrome(for: .recording, mode: .waiting, config: config)
    }

    func setRecordingWaveformLevel(config: AppConfig) {
        recordingWaveformMode = .level
        guard state == .recording else {
            setState(.recording, config: config)
            return
        }
        reapplyWaveformChrome(for: .recording, mode: .level, config: config)
    }

    func setPreparingWaveformWaiting(config: AppConfig) {
        recordingWaveformMode = .waiting
        guard state == .preparing else {
            setState(.preparing, config: config)
            return
        }
        reapplyWaveformChrome(for: .preparing, mode: .waiting, config: config)
    }

    /// Re-lays the waveform for a mode change that arrives outside a state transition.
    ///
    /// Declines while setState still has a deferred pass pending for this same chrome
    /// generation: that pass reads the mode live and lays out against the size the pill
    /// is arriving at, so running now would only put the bars on the interpolating frame
    /// and be overwritten a moment later.
    private func reapplyWaveformChrome(
        for state: DictationState,
        mode: WaveformAnimationMode,
        config: AppConfig
    ) {
        guard !hasPendingWaveformChrome else { return }
        applyWaveformChrome(for: state, mode: mode, in: chromeLayoutSize(for: state, config: config))
    }

    func setMeetingRecordingPaused(_ paused: Bool, config: AppConfig) {
        guard isMeetingRecordingPaused != paused else { return }
        isMeetingRecordingPaused = paused
        // The panel reports the pause in its own header, so pausing is not a reason to
        // take it down: hiding it here meant the user lost the transcript for asking the
        // recording to wait, and the re-show on resume then had to guess from the pointer.
        meetingTranscriptPanel.setPaused(paused)
        guard isMeetingRecording, state == .recording else { return }
        setState(.recording, config: config)
    }

    func updateMeetingTranscript(
        transcript: String,
        partialYou: String,
        partialOthers: String
    ) {
        meetingTranscriptPanel.update(
            transcript: transcript,
            partialYou: partialYou,
            partialOthers: partialOthers
        )
    }

    /// Gives the panel what it needs to answer questions, or clears it when no meeting is
    /// recording. Set once per session — the prior transcript does not change mid-meeting.
    func setMeetingChatContext(_ context: FloatingMeetingChatContext?) {
        meetingTranscriptPanel.setChatContext(context)
    }

    /// Honours a change to the hover preference, and nothing else.
    ///
    /// Where the pill is anchored, independent of what size it currently is.
    ///
    /// Only a drag moves this. Hovering, recording, and transcribing all change the
    /// pill's size and may be clamped to the screen edge, none of which should
    /// relocate it.
    private var customAnchorCenter: CGPoint?

    private var indicatorScreenFrame: NSRect? {
        guard let panel, let contentView else { return nil }
        return panel.convertToScreen(contentView.frame)
    }

    /// Shows the transcript, offering the pill's frame as a first-time position.
    ///
    /// The panel only uses that frame until the user drags it; from then on it shows at
    /// its saved origin and the pill is irrelevant. The live frame rather than the anchor:
    /// loading, the computer-use cursor, and a drag all move the window away from its
    /// anchor, and a first-time placement derived from the anchor would land beside a
    /// pill that is not there.
    private func showMeetingTranscript() {
        let source: String
        let indicatorFrame: NSRect
        if let live = indicatorScreenFrame {
            source = "live"
            indicatorFrame = live
        } else {
            source = "anchor"
            indicatorFrame = frameForState(state, config: configStore.load())
        }
        guard let visibleFrame = Self.screenVisibleFrame(intersecting: indicatorFrame) else { return }
        Self.logger.notice("transcript show source=\(source, privacy: .public) pill=\(NSStringFromRect(indicatorFrame), privacy: .public)")
        meetingTranscriptPanel.show(beside: indicatorFrame, in: visibleFrame)
    }


    private func hideMeetingTranscript(reset: Bool = false) {
        // Nothing to resize. The transcript owns its window, so showing and hiding it
        // cannot disturb the indicator's geometry -- which is what used to move the
        // pill out from under the cursor mid-drag.
        if reset {
            meetingTranscriptPanel.reset()
        } else {
            meetingTranscriptPanel.hide()
        }
    }

    /// Applies a new indicator geometry.
    ///
    /// The indicator's window is always exactly the pill now, so this is a plain
    /// resize with no union to recompute and no container to keep in step.
    @discardableResult
    private func applyIndicatorFrame(_ indicatorFrame: NSRect, animated: Bool = false) -> NSRect {
        guard let panel, let contentView else { return .zero }
        let local = NSRect(origin: .zero, size: indicatorFrame.size)
        lastAppliedIndicatorFrame = indicatorFrame
        if animated {
            // The animator retargets an animation already in flight for the same property;
            // the plain setter cannot, which is what the branch below has to work around.
            panel.animator().setFrame(indicatorFrame, display: true)
            contentView.animator().frame = local
        } else {
            // Setting the frame directly does not stop an animation already running: it
            // keeps stepping and its next step overwrites this. A 0.2s hover collapse
            // therefore lands *after* the instant preparing/recording resize it should
            // have been cancelled by, leaving the pill the wrong size with the waveform
            // laid out for the other one.
            //
            // Retargeting through the same animator at zero duration ends that animation
            // on this frame. The direct set that follows is the authoritative one, so the
            // final geometry is the same whichever of the two AppKit applies last.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().setFrame(indicatorFrame, display: true)
                contentView.animator().frame = local
            }
            panel.setFrame(indicatorFrame, display: true)
            contentView.frame = local
        }
        containerView?.frame = local
        applyIndicatorCornerRadius(height: indicatorFrame.height)
        // Nothing here touches the transcript. It is a window the user positions, not
        // something pinned to the pill, so a hover expansion or a state resize has no
        // business re-placing it -- which is what used to walk it across the screen every
        // time the pill changed size.
        return local
    }

    /// The pill's radius always follows its own height.
    ///
    /// Deriving it from a frame the view may not have ended up with is what produces
    /// a radius wider than the view, and with it the lens/trapezoid silhouette.
    private func applyIndicatorCornerRadius(height: CGFloat) {
        contentView?.layer?.cornerRadius = height / 2
        glassView?.layer?.cornerRadius = height / 2
    }


    func setTranscribingTitle(_ title: String, config: AppConfig) {
        computerUseTranscriptText = nil
        transcribingTitle = title
        guard state == .transcribing else { return }
        setState(.transcribing, config: config)
    }

    func showComputerUseTranscript(_ transcript: String, config: AppConfig) {
        let normalized = Self.normalizedComputerUseTranscript(transcript)
        computerUseTranscriptText = normalized.isEmpty ? nil : normalized
        transcribingTitle = normalized.isEmpty ? "Starting CUA" : normalized
        setState(.transcribing, config: config)
    }

    func setState(_ state: DictationState, config: AppConfig) {
        let previousState = self.state
        let previousHover = isHovered
        if isComputerUseCursorMode {
            exitComputerUseCursorMode(restoreFrame: false)
        }
        self.state = state
        chromeGeneration &+= 1
        if state != .idle {
            // The warning owns an idle pill only, and its dismissal snaps back to idle --
            // which is the wrong thing to do to whatever state has taken the pill since.
            cancelWarningDismissal()
        }
        if state == .recording {
            clearLoadingChrome()
        }
        if state != .transcribing {
            transcribingTitle = "Transcribing"
            computerUseTranscriptText = nil
        }
        if state != .recording {
            recordingWaveformMode = .level
        }
        if state != .idle {
            isHovered = false
        }
        if !config.showFloatingIndicator && state == .idle {
            close()
            return
        }
        if panel == nil {
            createPanel(config: config)
        }
        guard let panel, let contentView, let iconLabel, let textLabel else { return }

        let preservesWaveformAcrossTransition = previousState == .preparing && state == .recording
        if (previousState == .recording || previousState == .preparing)
            && state != previousState
            && !preservesWaveformAcrossTransition {
            stopWaveformAnimation()
        }

        // Immediately snap glass elements off when leaving idle so the SF Symbol
        // mic doesn't linger/fade during the recording/transcribing transition.
        if state != .idle {
            micIconView?.isHidden = true
            glassView?.isHidden = true
            tintLayer?.isHidden = true

        }

        let style = styleForState(state, config: config)
        let targetFrame = frameForState(state, config: config)
        // A background re-layout -- a config write, an iCloud sync landing -- must not
        // yank the pill out from under a drag. State and chrome still update, laid out
        // against the size the window actually has; the frame itself reconciles at the
        // first setState after the drag ends.
        let layoutFrame = isDragging ? (indicatorScreenFrame ?? targetFrame) : targetFrame

        let duration = transitionDuration(
            from: previousState,
            to: state,
            wasHovered: previousHover,
            isHovered: isHovered
        )
        // Nothing to animate towards when the transition is instant or when a drag owns
        // the frame, and nothing to wait for either.
        let animatesFrame = duration > 0 && !isDragging
        let generation = chromeGeneration

        // The waveform bars and the stop square are laid out against the pill's final
        // size, so running them while the window is still on its way there misrenders for
        // the length of the transition. When there is a transition to wait for they run at
        // the end of it instead, and check on arrival that no later state has claimed the
        // pill in the meantime.
        //
        // Waiting out the transition's own duration rather than taking the animation
        // group's completion handler: that handler is `@Sendable`, so main-actor work
        // routed through it is a concurrency violation, and every other deferred pass in
        // this file already waits this way.
        let waveformChrome = DispatchWorkItem { [weak self] in
            guard let self, self.chromeGeneration == generation else { return }
            self.pendingWaveformChromeGeneration = nil
            // The mode is read here rather than captured: a level/waiting change arriving
            // mid-transition defers to this pass, so this pass has to honour it.
            self.applyWaveformChrome(for: state, mode: self.recordingWaveformMode, in: layoutFrame.size)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            if !isDragging {
                applyIndicatorFrame(layoutFrame, animated: animatesFrame)
            }
            panel.animator().alphaValue = style.alpha

            contentView.layer?.backgroundColor = style.background.cgColor
            contentView.layer?.borderWidth = 1.0
            contentView.layer?.borderColor = style.border.cgColor

            if state == .recording {
                applyRecordingControlChrome(
                    iconLabel: iconLabel,
                    textLabel: textLabel,
                    in: layoutFrame.size,
                    animated: true
                )
            } else {
                iconLabel.isHidden = false
                iconLabel.animator().alphaValue = 1
                iconLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
                iconLabel.stringValue = style.icon
                iconLabel.textColor = style.iconColor
                configureTextLabelForTranscript(state == .transcribing && computerUseTranscriptText != nil)
                textLabel.stringValue = style.title
                textLabel.textColor = style.textColor
                textLabel.animator().alphaValue = style.title.isEmpty ? 0 : 1
                textLabel.isHidden = style.title.isEmpty
                if state == .transcribing, computerUseTranscriptText != nil {
                    layoutComputerUseTranscript(in: layoutFrame.size, animated: true)
                } else {
                    layoutLabels(
                        iconLabel: iconLabel,
                        textLabel: textLabel,
                        in: layoutFrame.size,
                        hasTitle: !style.title.isEmpty,
                        animated: true
                    )
                }
            }

            // Apply glass state last so it can override iconLabel visibility set above.
            applyGlassState(state, frameSize: layoutFrame.size)
        }

        // Manage SF Symbol effects — stop everything first, then start for the new state.
        micIconView?.removeAllSymbolEffects(animated: false)
        wandIconView?.removeAllSymbolEffects(animated: false)

        if state == .transcribing {
            if #available(macOS 15, *) {
                wandIconView?.addSymbolEffect(
                    .wiggle.backward.byLayer,
                    options: .repeating, animated: true
                )
            }
        }
        if animatesFrame {
            pendingWaveformChromeGeneration = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: waveformChrome)
        } else {
            waveformChrome.perform()
        }

        panel.orderFrontRegardless()
        if state == .preparing {
            contentView.displayIfNeeded()
            panel.displayIfNeeded()
        }
    }

    func showComputerUseCursor(at quartzPoint: CGPoint, label rawLabel: String?) {
        let config = configStore.load()
        if panel == nil {
            createPanel(config: config)
        }
        guard let panel, let contentView, let iconLabel, let textLabel else { return }

        if !isComputerUseCursorMode {
            // The settled frame, not `panel.frame`: entering cursor mode during a
            // transition would otherwise persist an interpolated rect as the pill's home
            // and drop it there for the rest of the run.
            computerUseCursorReturnFrame = lastAppliedIndicatorFrame ?? panel.frame
        }
        isComputerUseCursorMode = true
        chromeGeneration &+= 1
        hoverExitWorkItem?.cancel()
        cancelWarningDismissal()
        if isDragging {
            // `ignoresMouseEvents` below swallows the mouse-up that would have ended the
            // drag, so the flag would stay up for the rest of the session and take hover
            // and drag-collapse with it. The drag was interrupted rather than dropped, so
            // the anchor it started from stands and nothing is saved.
            pointerInteractionEnded()
        }
        isHovered = false
        clearLoadingChrome()
        stopWaveformAnimation()

        let label = Self.cursorLabel(rawLabel)
        let targetSize = Self.computerUseCursorSize(label: label)
        let targetFrame = Self.computerUseCursorFrame(
            forQuartzPoint: quartzPoint,
            size: targetSize,
            offsetFromTarget: !label.isEmpty
        )

        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        glassView?.isHidden = true
        tintLayer?.isHidden = true
        micIconView?.isHidden = true
        wandIconView?.isHidden = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            applyIndicatorFrame(targetFrame, animated: true)
            panel.animator().alphaValue = 1.0
            contentView.layer?.backgroundColor = NSColor.colorWith(hex: 0x1455D9, alpha: 0.88).cgColor
            contentView.layer?.borderWidth = 1.0
            contentView.layer?.borderColor = NSColor.colorWith(hex: 0xFFFFFF, alpha: 0.34).cgColor

            iconLabel.isHidden = false
            iconLabel.animator().alphaValue = 1
            iconLabel.stringValue = "•"
            iconLabel.font = NSFont.systemFont(ofSize: 18, weight: .heavy)
            iconLabel.textColor = .white

            textLabel.stringValue = label
            textLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            textLabel.textColor = .white.withAlphaComponent(0.92)
            textLabel.isHidden = label.isEmpty
            textLabel.animator().alphaValue = label.isEmpty ? 0 : 1
            layoutLabels(
                iconLabel: iconLabel,
                textLabel: textLabel,
                in: targetSize,
                hasTitle: !label.isEmpty,
                animated: true
            )
        }
        panel.orderFrontRegardless()
    }

    func hideComputerUseCursor() {
        exitComputerUseCursorMode(restoreFrame: true)
    }

    func ensureVisible(config: AppConfig) {
        setState(state, config: config)
    }

    /// Refresh the idle icon to match the user's selected menu bar icon.
    func refreshIcon() {
        let config = configStore.load()
        let fallback = NSImage(systemSymbolName: "waveform.badge.microphone", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)) ?? NSImage()
        let newImage = MenuBarIconRenderer.make(choice: config.menuBarIcon) ?? fallback
        newImage.isTemplate = false
        micIconView?.image = newImage
    }

    /// Flash a brief warning message on the indicator pill, then snap back to idle.
    func showWarning(_ message: String, icon: String = "⚡", duration: TimeInterval = 2.5) {
        guard state == .idle else { return }
        // The cursor pill is mouse-transparent, sits at statusBar level and is placed
        // against the thing it points at. Re-framing it here would leave all three wrong
        // and hand the eventual cursor exit a stale frame to restore over the top.
        guard !isComputerUseCursorMode else {
            Self.logger.notice("Ignoring warning during computer-use cursor: \(message, privacy: .public)")
            return
        }
        let config = configStore.load()
        if panel == nil { createPanel(config: config) }
        guard let panel, let contentView, let iconLabel, let textLabel else { return }
        // The warning is centred on the pill's current position, so it has to be sized
        // and clamped against the display the pill is actually on.
        //
        // Where it has settled, not `panel.frame`: that reports an interpolated rect for
        // as long as a transition is still running, and a warning raised right after one
        // would inherit a position the pill was only passing through.
        let pillFrame = lastAppliedIndicatorFrame ?? panel.frame
        guard let screen = Self.screenVisibleFrame(intersecting: pillFrame) else { return }

        // Stacked warnings must not truncate each other: the pending dismissal belongs to
        // the message being replaced.
        cancelWarningDismissal()
        // A warning replaces the loading pill rather than landing on top of it: the
        // spinner would otherwise keep turning over the amber fill, and the latched flag
        // would take hover, hover-to-transcript and drag-collapse with it until an
        // unrelated hideLoading happened along.
        clearLoadingChrome()
        chromeGeneration &+= 1

        let warningFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let warningSize = warningPillSize(
            message: message,
            icon: icon,
            font: warningFont,
            screen: screen
        )
        let center = CGPoint(x: pillFrame.midX, y: pillFrame.midY)
        let x = min(max(center.x - warningSize.width / 2, screen.minX), screen.maxX - warningSize.width)
        let y = min(max(center.y - warningSize.height / 2, screen.minY), screen.maxY - warningSize.height)
        let targetFrame = NSRect(x: x, y: y, width: warningSize.width, height: warningSize.height)

        // Warning uses its own solid amber background — hide glass layers.
        glassView?.isHidden = true
        tintLayer?.isHidden = true
        micIconView?.isHidden = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            applyIndicatorFrame(targetFrame, animated: true)
            panel.animator().alphaValue = 1.0
            contentView.layer?.backgroundColor = NSColor.colorWith(hex: 0xD99A11, alpha: 0.92).cgColor
            contentView.layer?.borderWidth = 1.0
            contentView.layer?.borderColor = NSColor.colorWith(hex: 0xFFFFFF, alpha: 0.24).cgColor

            let hasIcon = !icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            iconLabel.isHidden = !hasIcon
            iconLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
            iconLabel.stringValue = icon
            iconLabel.textColor = NSColor.colorWith(hex: 0x1A140D, alpha: 0.95)
            iconLabel.animator().alphaValue = hasIcon ? 1 : 0

            textLabel.stringValue = message
            textLabel.font = warningFont
            textLabel.textColor = NSColor.colorWith(hex: 0x1A140D, alpha: 0.95)
            textLabel.isHidden = false
            textLabel.animator().alphaValue = 1
            layoutLabels(iconLabel: iconLabel, textLabel: textLabel, in: warningSize, hasTitle: true, animated: true)
        }
        panel.orderFrontRegardless()

        // Held so it can be cancelled: an unstored timer outlives the warning it belongs
        // to, and its idle snap then lands under a loading spinner, mid-drag, or on top of
        // a state that replaced the warning entirely.
        let dismissal = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.warningDismissWorkItem = nil
            guard self.state == .idle else { return }
            self.setState(.idle, config: self.configStore.load())
        }
        warningDismissWorkItem = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismissal)
    }

    private func cancelWarningDismissal() {
        warningDismissWorkItem?.cancel()
        warningDismissWorkItem = nil
    }

    private func warningPillSize(message: String, icon: String, font: NSFont, screen: NSRect) -> NSSize {
        let horizontalPadding: CGFloat = 18
        let hasIcon = !icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let iconWidth = hasIcon
            ? max(24, ceil((icon as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold)]).width) + 2)
            : 0
        let iconGap: CGFloat = hasIcon ? 4 : 0
        let textWidth = ceil((message as NSString).size(withAttributes: [.font: font]).width) + 2
        let preferredWidth = horizontalPadding + iconWidth + iconGap + textWidth + horizontalPadding
        let minWidth: CGFloat = hasIcon ? 180 : 88
        let maxWidth = max(minWidth, min(640, screen.width - 32))
        return NSSize(width: min(max(preferredWidth, minWidth), maxWidth), height: 36)
    }

    func showLoading(_ message: String) {
        // A recording owns the pill. Nothing on a recording's path calls hideLoading --
        // every call site of it belongs to an import or backend-prepare flow -- so a
        // loading pill raised over one strands the flag, and with it hover,
        // hover-to-transcript, and drag-collapse, for as long as the recording lasts.
        guard !isMeetingRecording, state != .recording else {
            Self.logger.notice("Ignoring loading pill during recording: \(message, privacy: .public)")
            return
        }
        // Same reasoning for the computer-use cursor: it is mouse-transparent, raised to
        // statusBar level and placed against its target, none of which survives being
        // re-framed as a loading pill.
        guard !isComputerUseCursorMode else {
            Self.logger.notice("Ignoring loading pill during computer-use cursor: \(message, privacy: .public)")
            return
        }
        let config = configStore.load()
        if panel == nil { createPanel(config: config) }
        guard let panel, let contentView, let textLabel else { return }
        // Where the pill has settled, not `panel.frame`: that is still interpolating while
        // a transition runs, and the loading pill would inherit the rect it passed through.
        let pillFrame = lastAppliedIndicatorFrame ?? panel.frame
        guard let screen = Self.screenVisibleFrame(intersecting: pillFrame) else { return }

        cancelWarningDismissal()
        chromeGeneration &+= 1
        isShowingLoading = true
        let loadingSize = loadingPillSize(message: message, screen: screen)
        let center = CGPoint(x: pillFrame.midX, y: pillFrame.midY)
        let x = min(max(center.x - loadingSize.width / 2, screen.minX), screen.maxX - loadingSize.width)
        let y = min(max(center.y - loadingSize.height / 2, screen.minY), screen.maxY - loadingSize.height)
        let targetFrame = NSRect(x: x, y: y, width: loadingSize.width, height: loadingSize.height)

        // Create spinner if needed
        if loadingSpinner == nil {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.appearance = NSAppearance(named: .darkAqua)
            contentView.addSubview(spinner)
            loadingSpinner = spinner
        }

        let spinnerSize: CGFloat = 16
        let gap: CGFloat = 8
        let horizontalPadding: CGFloat = 16
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]
        let measuredTextW = ceil((message as NSString).size(withAttributes: attrs).width) + 2
        let availableTextW = max(40, loadingSize.width - (horizontalPadding * 2) - spinnerSize - gap)
        let textW = min(measuredTextW, availableTextW)
        let totalW = spinnerSize + gap + textW
        let startX = max(horizontalPadding, (loadingSize.width - totalW) / 2)

        micIconView?.isHidden = true
        wandIconView?.isHidden = true
        iconLabel?.isHidden = true
        glassView?.isHidden = false
        tintLayer?.isHidden = false
        tintLayer?.backgroundColor = NSColor.colorWith(hexString: "1e1e2e", alpha: 0.72).cgColor
        applyTintLayerGeometry(size: loadingSize, radius: loadingSize.height / 2)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            applyIndicatorFrame(targetFrame, animated: true)
            panel.animator().alphaValue = 1.0
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
            contentView.layer?.borderWidth = 1.0
            contentView.layer?.borderColor = NSColor.colorWith(hex: 0xFFFFFF, alpha: 0.16).cgColor

            loadingSpinner?.frame = NSRect(
                x: startX, y: (loadingSize.height - spinnerSize) / 2,
                width: spinnerSize, height: spinnerSize
            )
            loadingSpinner?.isHidden = false
            loadingSpinner?.startAnimation(nil)

            textLabel.stringValue = message
            textLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            textLabel.lineBreakMode = .byTruncatingTail
            textLabel.maximumNumberOfLines = 1
            textLabel.usesSingleLineMode = true
            textLabel.cell?.wraps = false
            textLabel.cell?.isScrollable = false
            textLabel.textColor = NSColor.colorWith(hex: 0xFFFFFF, alpha: 0.82)
            textLabel.frame = NSRect(
                x: startX + spinnerSize + gap,
                y: (loadingSize.height - 14) / 2,
                width: textW, height: 14
            )
            textLabel.isHidden = false
            textLabel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
    }

    private func loadingPillSize(message: String, screen: NSRect) -> NSSize {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let spinnerSize: CGFloat = 16
        let gap: CGFloat = 8
        let horizontalPadding: CGFloat = 16
        let textWidth = ceil((message as NSString).size(withAttributes: [.font: font]).width) + 2
        let preferredWidth = horizontalPadding + spinnerSize + gap + textWidth + horizontalPadding
        let minWidth = min(CGFloat(180), max(120, screen.width - 32))
        let maxWidth = max(minWidth, min(360, screen.width - 32))
        return NSSize(width: min(max(preferredWidth, minWidth), maxWidth), height: 36)
    }

    func hideLoading() {
        guard isShowingLoading else { return }
        clearLoadingChrome()
        // Only reset to idle if no dictation started during the warmup window
        if state == .idle || state == .preparing {
            setState(.idle, config: configStore.load())
        }
    }

    /// Takes the spinner down without touching the state that superseded it.
    ///
    /// `hideLoading()` is the only other way out of loading, and every one of its call
    /// sites belongs to an audio-import or backend-prepare flow. A recording that starts
    /// while the spinner is up therefore has to clear the flag itself: `setHovered`,
    /// `collapseForDrag` and `closeIfIdle` all gate on it, so leaving it set kills hover,
    /// hover-to-transcript and drag-collapse for the whole recording -- with the spinner
    /// still turning underneath.
    private func clearLoadingChrome() {
        guard isShowingLoading else { return }
        isShowingLoading = false
        loadingSpinner?.stopAnimation(nil)
        loadingSpinner?.isHidden = true
    }

    func setHovered(_ hovered: Bool) {
        if state == .recording, isMeetingRecording, !isShowingLoading, !isDragging {
            // Hover opens the transcript and never closes it. The panel is its own window
            // at a position the user chose, which may be nowhere near the pill, so the
            // pointer leaving says nothing about whether they still want it -- it usually
            // means they are on their way over to read it.
            guard hovered else { return }
            guard !isMeetingTranscriptManuallyDismissed else { return }
            let config = configStore.load()
            guard config.showMeetingTranscriptOnIndicatorHover, panel != nil else { return }
            showMeetingTranscript()
            return
        }
        guard state == .idle, !isShowingLoading, !isDragging, isHovered != hovered else { return }
        hoverExitWorkItem?.cancel()
        isHovered = hovered
        let config = configStore.load()
        setState(.idle, config: config)
    }

    func scheduleHoverExit() {
        // A meeting pill has no hover exit. Nothing here is a preview the pointer owns:
        // the transcript stays until the chevron, the menu bar, or the meeting ends, and
        // the dismissal that suppresses hover-to-show holds for the same reasons.
        if state == .recording, isMeetingRecording { return }
        guard state == .idle, !isShowingLoading, isHovered else { return }
        hoverExitWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.pointerIsInsidePill() else { return }
            self.setHovered(false)
        }
        hoverExitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: workItem)
    }

    func closeIfIdle() {
        if state == .idle, !isShowingLoading { close() }
    }

    func close() {
        stopWaveformAnimation()
        hoverExitWorkItem?.cancel()
        hoverExitWorkItem = nil
        cancelWarningDismissal()
        // Everything below describes the panel being torn down here, and a recreated pill
        // inherits whatever is left set: a stuck `isDragging` or `isShowingLoading` leaves
        // it permanently un-hoverable and un-draggable, a stale return frame drops it
        // somewhere it has never been, and the spinner reference outlives the view
        // hierarchy it was added to, so it never renders again.
        chromeGeneration &+= 1
        pointerInteractionEnded()
        isShowingLoading = false
        isHovered = false
        isComputerUseCursorMode = false
        computerUseCursorReturnFrame = nil
        lastAppliedIndicatorFrame = nil
        pendingWaveformChromeGeneration = nil
        loadingSpinner = nil
        powerProvider = nil
        // The transcript window goes down with the pill below, so the latch suppressing
        // its re-show has nothing left to suppress.
        isMeetingTranscriptManuallyDismissed = false
        panel?.close()
        panel = nil
        containerView = nil
        contentView = nil
        iconLabel = nil
        textLabel = nil
        glassView = nil
        tintLayer = nil
        micIconView = nil
        wandIconView = nil
        meetingTranscriptPanel.close()
    }

    /// The chevron in the panel's own header.
    ///
    /// The latch it sets holds for the rest of the meeting: only a deliberate show --
    /// the menu bar -- or the next meeting clears it. It used to clear itself after
    /// 0.2s, which made the chevron a button that undid itself while the user was still
    /// looking at it.
    private func dismissMeetingTranscript() {
        isMeetingTranscriptManuallyDismissed = true
        hideMeetingTranscript()
    }

    private func openMeetingNotesFromTranscript() {
        hideMeetingTranscript()
        onOpenMeetingNotes?()
    }

    // MARK: - Recording chrome

    /// The recording pill's leading control: cancel for dictation, pause/resume for a
    /// meeting.
    ///
    /// Shared with the drag collapse so the two can never disagree. The generic
    /// icon/title layout is wrong for this control -- it centres the glyph over the
    /// waveform at a 26x18 minimum and leaves the font whatever the previous state set --
    /// so a path that reached for it rendered the pause glyph as a smear.
    private func applyRecordingControlChrome(
        iconLabel: NSTextField,
        textLabel: NSTextField,
        in size: NSSize,
        animated: Bool
    ) {
        iconLabel.isHidden = false
        iconLabel.stringValue = recordingControlSymbol()
        iconLabel.textColor = .white.withAlphaComponent(isMeetingRecording ? 0.86 : 0.45)
        iconLabel.font = NSFont.systemFont(ofSize: isMeetingRecording ? 8 : 7, weight: .semibold)
        // Frame from the measured glyph, centred on the control point. A fixed
        // 10x10 box let the text field's font metrics decide where the glyph sat
        // inside it, which is why the pause bars floated off the row's centreline
        // the other chrome (waveform, stop square, chevron) is centred on.
        let controlSize = Self.recordingControlSize
        let glyphSize = iconLabel.attributedStringValue.size()
        let width = max(controlSize, ceil(glyphSize.width) + 2)
        let height = max(controlSize, ceil(glyphSize.height))
        let centerX = Self.recordingControlLeadingInset + controlSize / 2
        iconLabel.frame = NSRect(
            x: round(centerX - width / 2),
            y: round((size.height - height) / 2),
            width: width,
            height: height
        )
        textLabel.isHidden = true
        if animated {
            iconLabel.animator().alphaValue = 1
            textLabel.animator().alphaValue = 0
        } else {
            iconLabel.alphaValue = 1
            textLabel.alphaValue = 0
        }
    }

    /// Lays the waveform out, plus the stop square a recording also carries.
    ///
    /// Every pass that re-lays the bars goes through here: the stop square is positioned
    /// against the pill's width, so the two are the same piece of chrome and separating
    /// them leaves the control hanging off the end of a resized pill.
    private func applyWaveformChrome(
        for state: DictationState,
        mode: WaveformAnimationMode,
        in size: NSSize
    ) {
        switch state {
        case .recording:
            ensureWaveformAnimation(in: size, mode: mode)
            addStopLayer(in: size)
        case .preparing:
            ensureWaveformAnimation(in: size, mode: .waiting)
        default:
            break
        }
    }

    /// The size chrome raised outside a state transition lays itself out against.
    ///
    /// Mirrors what setState does with its layout frame: a drag owns the window, so
    /// chrome has to match the size it actually has; otherwise it matches the size the
    /// state is on its way to.
    private func chromeLayoutSize(for state: DictationState, config: AppConfig) -> NSSize {
        if isDragging, let live = indicatorScreenFrame { return live.size }
        return indicatorSize(for: state, config: config)
    }

    private func addStopLayer(in size: NSSize) {
        removeStopLayer()
        guard let contentView else { return }

        let stop = CALayer()
        stop.frame = Self.stopLayerFrame(in: size)
        stop.cornerRadius = 1
        stop.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor

        contentView.layer?.addSublayer(stop)
        stopLayer = stop
        addPanelToggleLayer(in: size)
    }

    /// The panel-toggle glyph a meeting pill carries between the waveform and the
    /// stop square. Added and removed with the stop layer so the two cannot drift
    /// apart across relayouts.
    private func addPanelToggleLayer(in size: NSSize) {
        removePanelToggleLayer()
        guard isMeetingRecording, let contentView else { return }

        let scale = contentView.window?.backingScaleFactor ?? 2
        let glyph = CALayer()
        // The real chevron.up symbol, not a unicode stand-in: it reads as "raise
        // the panel" and mirrors the chevron-down dismiss in the panel's header,
        // where the same symbol family renders at the same weight.
        glyph.contents = Self.panelToggleGlyphImage?.layerContents(forContentsScale: scale)
        glyph.contentsGravity = .resizeAspect
        glyph.contentsScale = scale
        glyph.frame = Self.panelToggleLayerFrame(in: size)
        contentView.layer?.addSublayer(glyph)
        panelToggleLayer = glyph
    }

    /// White chevron.up at the pill's control weight, tinted once and reused —
    /// symbol images are template images, which draw black as raw layer contents.
    private static let panelToggleGlyphImage: NSImage? = {
        guard let symbol = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Show live transcript")?
            // 8pt to match the pause glyph's 8pt semibold, so the two leading
            // controls read at the same optical weight.
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
        else { return nil }
        return NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.withAlphaComponent(0.8).set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }()

    private func removePanelToggleLayer() {
        panelToggleLayer?.removeFromSuperlayer()
        panelToggleLayer = nil
    }

    private static let stopSquareSize: CGFloat = 6
    private static let stopSquareTrailingInset: CGFloat = 8
    private static let recordingControlSize: CGFloat = 10
    private static let recordingControlLeadingInset: CGFloat = 7
    private static let panelToggleGlyphSize: CGFloat = 12
    /// The panel toggle sits right after the pause control on the leading side:
    /// [pause] [panel] [waveform] [stop]. The inset keeps the glyph's whole hit
    /// region clear of the pause region, which ends at the pause glyph's centre
    /// plus half the minimum hit width (12 + 18 = 30).
    private static let panelToggleLeadingInset: CGFloat = 32
    /// The smallest region a pointer can comfortably aim at, used to pad the recording
    /// pill's 10pt leading control out to a clickable width.
    private static let minimumControlHitWidth: CGFloat = 36

    private static func stopLayerFrame(in size: NSSize) -> CGRect {
        CGRect(
            x: size.width - stopSquareSize - stopSquareTrailingInset,
            y: floor((size.height - stopSquareSize) / 2),
            width: stopSquareSize,
            height: stopSquareSize
        )
    }

    private static func panelToggleLayerFrame(in size: NSSize) -> CGRect {
        // The image's natural size, centred on the control point: aspect-fitting
        // into an arbitrary square rescales the glyph, so a fixed box dictated its
        // drawn size and a leftover -1 nudge (tuned for the old text glyph) held
        // it below the centreline the rest of the chrome sits on.
        let imageSize = panelToggleGlyphImage?.size
            ?? NSSize(width: panelToggleGlyphSize, height: panelToggleGlyphSize)
        let centerX = panelToggleLeadingInset + panelToggleGlyphSize / 2
        return CGRect(
            x: round(centerX - imageSize.width / 2),
            y: round((size.height - imageSize.height) / 2),
            width: imageSize.width,
            height: imageSize.height
        )
    }

    private func recordingControlSymbol() -> String {
        guard isMeetingRecording else { return "\u{2715}" }
        return isMeetingRecordingPaused ? "\u{25B6}" : "\u{23F8}"
    }

    private func removeStopLayer() {
        stopLayer?.removeFromSuperlayer()
        stopLayer = nil
        removePanelToggleLayer()
    }

    private func stopWaveformAnimation() {
        amplitudeTimer?.invalidate()
        amplitudeTimer = nil
        barLayers.forEach { $0.removeFromSuperlayer() }
        barLayers.removeAll()
        smoothedAmplitude = 0
        waveformAnimationMode = .level
        // The power provider is wiring, not animation state: the computer-use cursor stops
        // the animation on a recording that is still running, and clearing it here left the
        // waveform flat at minimum height for the rest of that meeting. It is cleared where
        // the recording it belongs to actually ends.
        contentView?.layer?.transform = CATransform3DIdentity
        removeStopLayer()
    }

    private func setupWaveformBars(in frameSize: NSSize) {
        barLayers.forEach { $0.removeFromSuperlayer() }
        barLayers.removeAll()
        guard let layer = contentView?.layer else { return }

        let barCount = 5
        let barWidth: CGFloat = 3
        let barSpacing: CGFloat = 3
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let startX = waveformStartX(totalWidth: totalWidth, frameWidth: frameSize.width)
        let minHeight: CGFloat = 4

        for i in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
            bar.cornerRadius = barWidth / 2
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            bar.frame = CGRect(x: x, y: (frameSize.height - minHeight) / 2, width: barWidth, height: minHeight)
            layer.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    private func updateWaveformBarsLayout(in frameSize: NSSize) {
        guard !barLayers.isEmpty else { return }
        let barWidth: CGFloat = 3
        let barSpacing: CGFloat = 3
        let totalWidth = CGFloat(barLayers.count) * barWidth + CGFloat(max(0, barLayers.count - 1)) * barSpacing
        let startX = waveformStartX(totalWidth: totalWidth, frameWidth: frameSize.width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            var frame = bar.frame
            frame.origin.x = startX + CGFloat(i) * (barWidth + barSpacing)
            frame.origin.y = (frameSize.height - frame.height) / 2
            frame.size.width = barWidth
            bar.frame = frame
            bar.cornerRadius = barWidth / 2
        }
        CATransaction.commit()
    }

    /// Where the bars start. A meeting pill carries controls on both sides and an
    /// inert waveform, so its bars centre in the gap between the panel toggle's hit
    /// region and the stop square's — derived from the same constants the click map
    /// uses, so the visible bars and the inert interval cannot drift apart.
    private func waveformStartX(totalWidth: CGFloat, frameWidth: CGFloat) -> CGFloat {
        guard state == .recording, isMeetingRecording else {
            return (frameWidth - totalWidth) / 2
        }
        let leading = Self.panelToggleLeadingInset + Self.panelToggleGlyphSize / 2 + Self.minimumControlHitWidth / 2
        let trailing = frameWidth - Self.stopSquareTrailingInset - Self.stopSquareSize / 2 - Self.minimumControlHitWidth / 2
        return leading + max(0, trailing - leading - totalWidth) / 2
    }

    private func ensureWaveformAnimation(in frameSize: NSSize, mode: WaveformAnimationMode) {
        if barLayers.isEmpty {
            setupWaveformBars(in: frameSize)
        } else {
            updateWaveformBarsLayout(in: frameSize)
        }
        setWaveformAnimationMode(mode)
        if amplitudeTimer == nil {
            startWaveformAnimation(mode: mode)
        }
    }

    private func setWaveformAnimationMode(_ mode: WaveformAnimationMode) {
        guard waveformAnimationMode != mode else { return }
        waveformAnimationMode = mode
        waveformAnimationStartedAt = Date()
    }

    private func startWaveformAnimation(mode: WaveformAnimationMode) {
        amplitudeTimer?.invalidate()
        waveformAnimationMode = mode
        waveformAnimationStartedAt = Date()
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(waveformTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        amplitudeTimer = timer
    }

    @objc private func waveformTimerFired(_ timer: Timer) {
        guard let contentView else { return }
        let multipliers: [CGFloat] = [0.6, 0.85, 1.0, 0.85, 0.6]
        let minHeight: CGFloat = 3
        let maxHeight: CGFloat = 14
        let pillHeight = contentView.frame.height
        let elapsed = CGFloat(Date().timeIntervalSince(waveformAnimationStartedAt))
        let levelAmplitude: CGFloat
        if waveformAnimationMode == .level {
            let dB = CGFloat(powerProvider?() ?? -160)
            let raw = max(0, min(1, (dB + 68) / 38))
            smoothedAmplitude = 0.48 * raw + 0.52 * smoothedAmplitude
            levelAmplitude = smoothedAmplitude
        } else {
            levelAmplitude = 0
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            let m = i < multipliers.count ? multipliers[i] : 1.0
            let amplitude: CGFloat
            switch waveformAnimationMode {
            case .level:
                amplitude = levelAmplitude * m
                bar.opacity = 0.85
            case .waiting:
                let phase = elapsed * 5.8 + CGFloat(i) * 0.72
                amplitude = 0.28 + (sin(phase) + 1) * 0.22 * m
                bar.opacity = Float(0.38 + (sin(phase) + 1) * 0.18)
            }
            let h = minHeight + (maxHeight - minHeight) * amplitude
            bar.frame.size.height = h
            bar.frame.origin.y = (pillHeight - h) / 2
        }
        // The bars re-seat themselves against the live pill on every tick, so the stop
        // square has to as well: its frame is frozen at layout time, and the 0.16-0.24s
        // resize after a drop would otherwise leave it floating off the row.
        if let stopLayer {
            stopLayer.frame = Self.stopLayerFrame(in: contentView.frame.size)
        }
        CATransaction.commit()
    }

    private func applyGlassState(_ state: DictationState, frameSize: NSSize) {
        let config = configStore.load()
        let radius = frameSize.height / 2
        let themeHex = config.recordingColorHex

        // Frosted glass in every state. Recording used to hide the frost behind a
        // near-solid accent fill, which made the meeting pill the one opaque slab in
        // an otherwise translucent surface family — the accent now tints the same
        // glass the idle pill and the transcript panel use.
        glassView?.isHidden = false
        glassView?.frame = NSRect(origin: .zero, size: frameSize)
        glassView?.layer?.cornerRadius = radius
        glassView?.layer?.masksToBounds = true

        let tintAlpha: CGFloat
        let tintHex: String
        switch state {
        case .idle:
            tintAlpha = isHovered ? 0.72 : 0.44
            tintHex = "1e1e2e"
        case .preparing:
            tintAlpha = 0.62
            tintHex = "1e1e2e"
        case .recording:
            // Low enough for the blur to read through, high enough that the white
            // waveform and controls keep their contrast on bright backdrops.
            tintAlpha = 0.6
            tintHex = themeHex
        case .transcribing:
            tintAlpha = 0.62
            tintHex = "1e1e2e"
        }
        tintLayer?.isHidden = false
        tintLayer?.backgroundColor = NSColor.colorWith(hexString: tintHex, alpha: tintAlpha).cgColor
        applyTintLayerGeometry(size: frameSize, radius: radius)

        let iconSize = NSSize(width: 18, height: 18)

        switch state {
        case .idle:
            // Mic symbol centred (or left-aligned when hovered beside text).
            wandIconView?.isHidden = true
            iconLabel?.isHidden = true
            micIconView?.isHidden = false
            if let mic = micIconView {
                mic.alphaValue = 1
                if isHovered {
                    mic.frame = NSRect(x: 12, y: (frameSize.height - iconSize.height) / 2,
                                      width: iconSize.width, height: iconSize.height)
                } else {
                    mic.frame = NSRect(x: (frameSize.width - iconSize.width) / 2,
                                       y: (frameSize.height - iconSize.height) / 2,
                                       width: iconSize.width, height: iconSize.height)
                }
            }

        case .recording:
            // Waveform bars replace mic icon during recording.
            wandIconView?.isHidden = true
            iconLabel?.isHidden = false   // keeps the ✕ cancel label
            micIconView?.isHidden = true

        case .transcribing:
            // Animated wand beside "Transcribing" label, the pair centred in the pill.
            micIconView?.isHidden = true
            iconLabel?.isHidden = true
            wandIconView?.isHidden = false
            if computerUseTranscriptText != nil {
                layoutComputerUseTranscript(in: frameSize, animated: false)
                return
            }
            if let wand = wandIconView {
                let gap: CGFloat = 6
                let horizontalPadding: CGFloat = 14
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular)
                ]
                let measuredTextW = max(
                    ceil((transcribingTitle as NSString).size(withAttributes: attrs).width),
                    ceil(textLabel?.intrinsicContentSize.width ?? 0)
                ) + 8
                let availableTextW = max(0, frameSize.width - iconSize.width - gap - (horizontalPadding * 2))
                let textW = min(measuredTextW, availableTextW)
                let totalW = iconSize.width + gap + textW
                let startX = (frameSize.width - totalW) / 2
                wand.frame = NSRect(x: startX, y: (frameSize.height - iconSize.height) / 2,
                                    width: iconSize.width, height: iconSize.height)
                // Reposition text label to sit right of the wand.
                let textH: CGFloat = 14
                textLabel?.frame = NSRect(x: startX + iconSize.width + gap,
                                          y: (frameSize.height - textH) / 2,
                                          width: textW, height: textH)
                textLabel?.isHidden = false
                textLabel?.alphaValue = 1
            }

        case .preparing:
            wandIconView?.isHidden = true
            iconLabel?.isHidden = true
            micIconView?.isHidden = true
        }
    }

    private func configureTextLabelForTranscript(_ isTranscript: Bool) {
        guard let textLabel else { return }
        Self.configureTextLabel(textLabel, forTranscript: isTranscript)
    }

    private static func configureTextLabel(_ textLabel: NSTextField, forTranscript isTranscript: Bool) {
        textLabel.alignment = .left
        if isTranscript {
            textLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            textLabel.lineBreakMode = .byWordWrapping
            textLabel.maximumNumberOfLines = 0
            textLabel.usesSingleLineMode = false
            textLabel.cell?.wraps = true
            textLabel.cell?.isScrollable = false
        } else {
            textLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            textLabel.lineBreakMode = .byTruncatingTail
            textLabel.maximumNumberOfLines = 1
            textLabel.usesSingleLineMode = true
            textLabel.cell?.wraps = false
            textLabel.cell?.isScrollable = false
        }
    }

    private func layoutComputerUseTranscript(in size: NSSize, animated: Bool) {
        guard let wand = wandIconView, let textLabel else { return }
        let iconSize = NSSize(width: 18, height: 18)
        let gap: CGFloat = 8
        let horizontalPadding: CGFloat = 16
        let verticalPadding: CGFloat = 12
        let textX = horizontalPadding + iconSize.width + gap
        let textWidth = max(40, size.width - textX - horizontalPadding)
        let textHeight = max(16, size.height - (verticalPadding * 2))
        let textFrame = NSRect(
            x: textX,
            y: floor((size.height - textHeight) / 2),
            width: textWidth,
            height: textHeight
        )
        let iconFrame = NSRect(
            x: horizontalPadding,
            y: floor(size.height - verticalPadding - iconSize.height),
            width: iconSize.width,
            height: iconSize.height
        )

        wand.isHidden = false
        textLabel.isHidden = false
        if animated {
            wand.animator().alphaValue = 1
            wand.animator().frame = iconFrame
            textLabel.animator().alphaValue = 1
            textLabel.animator().frame = textFrame
        } else {
            wand.alphaValue = 1
            wand.frame = iconFrame
            textLabel.alphaValue = 1
            textLabel.frame = textFrame
        }
    }

    private func createPanel(config: AppConfig) {
        let panel = InteractiveFloatingPanel(
            contentRect: frameForState(.idle, config: config),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]


        let containerView = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        containerView.wantsLayer = true

        let contentView = HoverIndicatorView(frame: containerView.bounds)
        contentView.owner = self
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = contentView.bounds.height / 2
        contentView.layer?.masksToBounds = false

        let iconLabel = NSTextField(labelWithString: "")
        iconLabel.alignment = .center
        iconLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        contentView.addSubview(iconLabel)

        let textLabel = NSTextField(labelWithString: "")
        textLabel.alignment = .left
        textLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        Self.configureTextLabel(textLabel, forTranscript: false)
        contentView.addSubview(textLabel)

        containerView.addSubview(contentView)
        panel.contentView = containerView

        self.panel = panel
        self.containerView = containerView
        self.contentView = contentView
        self.iconLabel = iconLabel
        self.textLabel = textLabel

        setupGlassLayer(in: contentView, iconLabel: iconLabel)
    }

    private func exitComputerUseCursorMode(restoreFrame: Bool) {
        guard isComputerUseCursorMode else { return }
        isComputerUseCursorMode = false
        panel?.ignoresMouseEvents = false
        panel?.level = .floating
        let returnFrame = computerUseCursorReturnFrame
        computerUseCursorReturnFrame = nil
        // setState calls this on its way to laying the pill out itself, so only the exit
        // with no successor has to put the pill back together.
        guard restoreFrame else { return }
        if let returnFrame {
            // Through applyIndicatorFrame rather than a bare setFrame: the corner radius
            // and the container view follow the size, and cursor mode changed it.
            applyIndicatorFrame(returnFrame)
        }
        // Geometry alone leaves the cursor pill's appearance behind -- blue fill, "•" for
        // an icon, the glass, tint, mic and wand views all hidden -- so the pill sits at
        // home as a blue dot until something else happens to change state. Re-running the
        // state it is actually in restores its own chrome.
        setState(state, config: configStore.load())
    }

    private static func cursorLabel(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count <= 24 { return trimmed }
        return String(trimmed.prefix(21)) + "..."
    }

    private static func computerUseCursorSize(label: String) -> NSSize {
        guard !label.isEmpty else {
            return NSSize(width: 36, height: 36)
        }
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let textWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        return NSSize(width: min(max(84, textWidth + 48), 190), height: 34)
    }

    private static func computerUseCursorFrame(
        forQuartzPoint point: CGPoint,
        size: NSSize,
        offsetFromTarget: Bool
    ) -> NSRect {
        // Quartz coordinates are global with their origin at the top-left of the *primary*
        // display, so the flip is against that one screen and no other.
        //
        // Converting with each candidate screen's own maxY -- as the containment test that
        // used to live here did -- moves the point along with whichever screen is being
        // tested, which makes the test self-referential: it can match the wrong display, or
        // match none at all and fall back to another display, dropping the cursor pill on
        // one screen while the thing it points at sits on another.
        let appKitPoint = CGPoint(
            x: point.x,
            y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y
        )
        let xOffset: CGFloat = offsetFromTarget ? 14 : 0
        let yOffset: CGFloat = offsetFromTarget ? 14 : 0
        let proposed = NSRect(
            x: appKitPoint.x - size.width / 2 + xOffset,
            y: appKitPoint.y - size.height / 2 - yOffset,
            width: size.width,
            height: size.height
        )
        guard let visibleFrame = screenVisibleFrame(containing: appKitPoint)
            ?? primaryVisibleFrame else {
            return proposed
        }
        let bounds = visibleFrame.insetBy(dx: 4, dy: 4)
        return NSRect(
            x: min(max(proposed.minX, bounds.minX), bounds.maxX - size.width),
            y: min(max(proposed.minY, bounds.minY), bounds.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }

    private func setupGlassLayer(in contentView: HoverIndicatorView, iconLabel: NSTextField) {
        // masksToBounds clips both the glass blur and the tint layer to the pill shape.
        // The panel's compositor-level shadow is unaffected.
        contentView.layer?.masksToBounds = true

        // NSVisualEffectView — frosted blur behind the pill.
        let vev = NSVisualEffectView(frame: contentView.bounds)
        vev.autoresizingMask = [.width, .height]
        vev.material = .hudWindow
        vev.blendingMode = .behindWindow
        vev.state = .active
        // Force dark appearance so the glass always looks dark regardless of
        // what's behind the pill (light windows, bright desktops, etc.).
        vev.appearance = NSAppearance(named: .darkAqua)
        vev.isHidden = true
        contentView.addSubview(vev, positioned: .below, relativeTo: iconLabel)
        glassView = vev

        // Dark Catppuccin Mocha tint over the blur — gives the pill a defined
        // dark glass presence rather than showing everything underneath.
        let tint = CALayer()
        tint.backgroundColor = NSColor.colorWith(hex: 0x1e1e2e, alpha: 0.44).cgColor
        tint.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        tint.masksToBounds = false
        tint.cornerCurve = .continuous
        tint.isHidden = true
        contentView.layer?.insertSublayer(tint, at: 0)
        tintLayer = tint

        // Idle icon — uses the user's selected menu bar icon from config.
        // Falls back to waveform.badge.microphone if the configured icon can't be loaded.
        let config = configStore.load()
        let fallbackImage = NSImage(systemSymbolName: "waveform.badge.microphone", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)) ?? NSImage()
        let idleImage = MenuBarIconRenderer.make(choice: config.menuBarIcon) ?? fallbackImage
        idleImage.isTemplate = false // we tint manually via contentTintColor
        let micView = NSImageView(image: idleImage)
        micView.contentTintColor = .white
        micView.imageScaling = .scaleProportionallyDown
        micView.isHidden = true
        contentView.addSubview(micView)
        micIconView = micView

        // wand.and.sparkles — transcribing (animated).
        let wandConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let wandImage = NSImage(systemSymbolName: "wand.and.sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(wandConfig)
        let wandView = NSImageView(image: wandImage ?? NSImage())
        wandView.contentTintColor = .white
        wandView.imageScaling = .scaleProportionallyDown
        wandView.isHidden = true
        contentView.addSubview(wandView)
        wandIconView = wandView

    }

    private func applyTintLayerGeometry(size: NSSize, radius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer?.frame = CGRect(origin: .zero, size: size)
        tintLayer?.cornerRadius = radius
        tintLayer?.cornerCurve = .continuous
        CATransaction.commit()
    }

    /// The collapsed pill. The anchor is defined against this size, not against whichever
    /// state happens to be showing.
    nonisolated static let idleIndicatorSize = NSSize(width: 44, height: 28)

    /// Stand-in bounds for sizing when no display is attached. Only the states that clamp
    /// their width against the screen read it at all.
    private static let headlessSizingFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)

    static func defaultIndicatorCenter(in visibleFrame: NSRect, idleSize: NSSize = idleIndicatorSize) -> CGPoint {
        anchorCenter(.midTrailing, in: visibleFrame, size: idleSize)
    }

    static func anchorCenter(_ anchor: IndicatorAnchor, in visibleFrame: NSRect, size: NSSize) -> CGPoint {
        let inset: CGFloat = 8
        let leadingX = visibleFrame.minX + size.width / 2 + inset
        let centerX = visibleFrame.midX
        let trailingX = visibleFrame.maxX - size.width / 2 - inset
        let topY = visibleFrame.maxY - size.height / 2 - inset
        let midY = visibleFrame.midY
        let bottomY = visibleFrame.minY + size.height / 2 + inset

        switch anchor {
        case .topLeading:
            return CGPoint(x: leadingX, y: topY)
        case .topCenter:
            return CGPoint(x: centerX, y: topY)
        case .topTrailing:
            return CGPoint(x: trailingX, y: topY)
        case .midLeading:
            return CGPoint(x: leadingX, y: midY)
        case .midTrailing:
            return CGPoint(x: trailingX, y: midY)
        case .bottomLeading:
            return CGPoint(x: leadingX, y: bottomY)
        case .bottomCenter:
            return CGPoint(x: centerX, y: bottomY)
        case .bottomTrailing:
            return CGPoint(x: trailingX, y: bottomY)
        case .custom:
            return defaultIndicatorCenter(in: visibleFrame, idleSize: size)
        }
    }

    static func isUsableIndicatorCenter(
        _ center: CGPoint,
        in visibleFrame: NSRect,
        size: NSSize
    ) -> Bool {
        let allowedRect = visibleFrame.insetBy(dx: size.width / 2, dy: size.height / 2)
        return allowedRect.contains(center)
    }

    /// Brings an anchor centre inside the area where a pill of `size` sits fully on screen.
    ///
    /// The counterpart to the veto this replaced: a saved centre that fails the fit is
    /// nudged in, never discarded. Rejecting it substituted the mid-trailing default for a
    /// position the user chose, and did so on every launch because the config was never
    /// rewritten.
    ///
    /// Callers pass the collapsed size on purpose. An anchor is size-independent by
    /// definition, so clamping it against whatever size happens to be showing would let a
    /// wide transcribing pill pull the anchor inward and never give it back.
    static func clampedAnchorCenter(_ center: CGPoint, in visibleFrame: NSRect, size: NSSize) -> CGPoint {
        // Computed per axis rather than via insetBy: over-half insets make insetBy
        // return CGRect.null (infinite origin, zero size), which reads as valid to a
        // width check. A pill larger than its display centres on that axis instead.
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        let x = visibleFrame.width >= size.width
            ? min(max(center.x, visibleFrame.minX + halfWidth), visibleFrame.maxX - halfWidth)
            : visibleFrame.midX
        let y = visibleFrame.height >= size.height
            ? min(max(center.y, visibleFrame.minY + halfHeight), visibleFrame.maxY - halfHeight)
            : visibleFrame.midY
        return CGPoint(x: x, y: y)
    }

    /// Where a drag leaves the anchor: where it started, moved by as far as the pill
    /// itself moved.
    ///
    /// Adopting the dropped pill's own centre instead is only equivalent while the pill
    /// is unclamped. In a state wide enough to be pushed inward the two diverge by the
    /// whole clamp, so a 5pt nudge would rewrite the anchor by hundreds of points and the
    /// collapsed pill would never find its way back to the edge.
    static func draggedAnchorCenter(
        anchorAtDragStart: CGPoint,
        pillCenterAtDragStart: CGPoint,
        pillCenterAtDrop: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: anchorAtDragStart.x + (pillCenterAtDrop.x - pillCenterAtDragStart.x),
            y: anchorAtDragStart.y + (pillCenterAtDrop.y - pillCenterAtDragStart.y)
        )
    }

    /// Keeps a dragged pill droppable: its centre has to land on a display rather than in
    /// the gap between two, or beyond the edge of the last one.
    static func clampedDragOrigin(_ origin: NSPoint, size: NSSize, screens: [NSRect]) -> NSPoint {
        guard !screens.isEmpty else { return origin }
        let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        var nearest: CGPoint?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for screen in screens {
            if screen.contains(center) { return origin }
            let clamped = CGPoint(
                x: min(max(center.x, screen.minX), screen.maxX),
                y: min(max(center.y, screen.minY), screen.maxY)
            )
            let distance = hypot(clamped.x - center.x, clamped.y - center.y)
            if distance < nearestDistance {
                nearestDistance = distance
                nearest = clamped
            }
        }
        guard let nearest else { return origin }
        return NSPoint(x: nearest.x - size.width / 2, y: nearest.y - size.height / 2)
    }

    /// The display preset anchors resolve against.
    ///
    /// `NSScreen.main` is whichever display holds keyboard focus, so a rule resolved
    /// against it re-anchors the pill to a different display every time the user clicks
    /// into a window on another one. The primary display does not move until the user
    /// rearranges their displays.
    private static var primaryVisibleFrame: NSRect? { NSScreen.screens.first?.visibleFrame }

    /// The visible frame of the display the pill belongs to.
    ///
    /// Resolving `NSScreen.main` here -- as this did -- pulls a pill parked on a second
    /// display back onto the focused screen every time it resizes or is hovered, and on
    /// relaunch rejects its saved centre outright: a display left of or below that one
    /// has coordinates its bounds can never contain.
    ///
    /// Only a custom position can leave the primary display. A preset anchor is a rule
    /// resolved against the primary display, and stays that way.
    private func indicatorVisibleFrame(config: AppConfig) -> NSRect? {
        guard config.indicatorAnchor == .custom else { return Self.primaryVisibleFrame }
        let candidate = customAnchorCenter ?? config.indicatorOrigin.map { CGPoint(x: $0.x, y: $0.y) }
        // No saved position, or the display it named is no longer attached: the primary
        // display is the right answer either way.
        guard let candidate,
              let visibleFrame = Self.screenVisibleFrame(containing: candidate) else {
            return Self.primaryVisibleFrame
        }
        return visibleFrame
    }

    /// The visible frame of whichever attached display holds `point`.
    private static func screenVisibleFrame(containing point: CGPoint) -> NSRect? {
        NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame
    }

    /// The visible frame of the display a pill currently occupies, for the states that
    /// re-place themselves from where the pill already is rather than from its anchor.
    private static func screenVisibleFrame(intersecting frame: NSRect) -> NSRect? {
        NSScreen.screens.first { $0.frame.intersects(frame) }?.visibleFrame ?? primaryVisibleFrame
    }

    /// The size the pill takes in `state`, laid out against the display it will sit on.
    private func indicatorSize(for state: DictationState, on screen: NSRect) -> NSSize {
        switch state {
        case .idle:
            return isHovered ? NSSize(width: 220, height: 36) : Self.idleIndicatorSize
        case .preparing, .recording:
            // A meeting pill carries a third control (the panel toggle), and its
            // waveform strip is inert — so the width must hold two full-size hit
            // regions on the left, one on the right, and 27pt of bars that overlap
            // none of them.
            if state == .recording, isMeetingRecording {
                return NSSize(width: 112, height: 22)
            }
            return NSSize(width: 76, height: 22)
        case .transcribing:
            if let transcript = computerUseTranscriptText {
                return Self.computerUseTranscriptPillSize(transcript: transcript, screen: screen)
            }
            return Self.transcribingPillSize(title: transcribingTitle, screenWidth: screen.width)
        }
    }

    /// The size `state` lays out against, without resolving or caching an anchor.
    ///
    /// `frameForState` writes `customAnchorCenter` as a side effect of answering, so
    /// asking it for a size alone moves the pill's home.
    private func indicatorSize(for state: DictationState, config: AppConfig) -> NSSize {
        indicatorSize(for: state, on: indicatorVisibleFrame(config: config) ?? Self.headlessSizingFrame)
    }

    private func frameForState(_ state: DictationState, config: AppConfig) -> NSRect {
        // Size first. With no display attached there is nothing to anchor or clamp
        // against, but every caller lays its chrome out against whatever comes back --
        // so it has to be this state's real size rather than the placeholder 64x28 no
        // state uses.
        let resolvedScreen = indicatorVisibleFrame(config: config)
        let size = indicatorSize(for: state, on: resolvedScreen ?? Self.headlessSizingFrame)
        guard let screen = resolvedScreen else {
            return NSRect(origin: .zero, size: size)
        }

        // Resolve every size from one stable anchor, never from the pill's current
        // frame.
        //
        // Reading the live frame looks equivalent but is not: the clamp below pushes
        // a frame back on-screen, so near an edge the expanded pill's real centre is
        // not the anchor it was laid out from. Feeding that back in on collapse moved
        // the pill to the middle of wherever the expanded version had been forced to
        // sit, and each hover walked it further inward -- which is why it was worst
        // in the corners, where the clamp always bites.
        let center: CGPoint
        switch config.indicatorAnchor {
        case .custom:
            let saved = customAnchorCenter ?? config.indicatorOrigin.map { CGPoint(x: $0.x, y: $0.y) }
            if let saved {
                // Clamp, never discard. `screen` is already the display holding `saved`
                // when one does, so this only bites when the position outlived the
                // display it was saved on -- and then it repairs against the collapsed
                // size, so the repair does not depend on which state asked first.
                center = Self.clampedAnchorCenter(saved, in: screen, size: Self.idleIndicatorSize)
            } else {
                // Also the collapsed size: this value is cached as the anchor, and a
                // default derived from a 720pt transcribing pill would park the collapsed
                // one 350pt short of the edge for the rest of the session.
                center = Self.defaultIndicatorCenter(in: screen)
            }
            customAnchorCenter = center
        default:
            // A preset anchor is a rule, not a remembered point, so it re-resolves
            // against the current size and any stale custom anchor is discarded.
            customAnchorCenter = nil
            center = Self.anchorCenter(config.indicatorAnchor, in: screen, size: size)
        }

        // Clamping keeps the pill on-screen for *this* size only. It deliberately
        // does not write back to the anchor.
        return Self.clampedIndicatorFrame(center: center, size: size, in: screen)
    }

    /// Places a pill of `size` around `center`, pushed back on-screen if it would
    /// overhang.
    ///
    /// Pure and side-effect free on purpose: the clamp must never feed back into the
    /// anchor, or a pill parked in a corner walks inward every time it resizes.
    static func clampedIndicatorFrame(center: CGPoint, size: NSSize, in screen: NSRect) -> NSRect {
        let x = min(max(center.x - size.width / 2, screen.minX), screen.maxX - size.width)
        let y = min(max(center.y - size.height / 2, screen.minY), screen.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Keeps the grabbed point under the pointer when the pill changes size mid-drag.
    ///
    /// Reusing the pre-collapse origin pins the pill's *left edge* to where the user
    /// grabbed, so a hovered idle pill collapsing 220pt -> 44pt hands whoever grabbed
    /// its right half up to 176pt of empty space to drag. Mapping the grab's fractional
    /// position into the new size keeps the pointer at the same relative spot, and the
    /// clamped fraction keeps it inside the pill whatever the size becomes.
    ///
    /// Sizes that do not change return the original origin exactly, so the states that
    /// keep their size across a collapse are unaffected.
    static func collapsedDragOrigin(
        pillFrame: NSRect,
        collapsedSize: NSSize,
        grabPoint: NSPoint
    ) -> NSPoint {
        let fractionX = pillFrame.width > 0 ? (grabPoint.x - pillFrame.minX) / pillFrame.width : 0.5
        let fractionY = pillFrame.height > 0 ? (grabPoint.y - pillFrame.minY) / pillFrame.height : 0.5
        return NSPoint(
            x: grabPoint.x - min(max(fractionX, 0), 1) * collapsedSize.width,
            y: grabPoint.y - min(max(fractionY, 0), 1) * collapsedSize.height
        )
    }

    private func styleForState(_ state: DictationState, config: AppConfig) -> (background: NSColor, border: NSColor, icon: String, title: String, iconColor: NSColor, textColor: NSColor, alpha: CGFloat) {
        switch state {
        case .idle:
            return (
                .clear,
                .colorWith(hex: 0xFFFFFF, alpha: isHovered ? 0.14 : 0.22),
                "",
                isHovered ? "Hold \(config.dictationHotkey.label) to dictate" : "",
                .colorWith(hex: 0xFFFFFF, alpha: 0.75),
                .colorWith(hex: 0xFFFFFF, alpha: 0.75),
                isHovered ? 1.0 : 0.85
            )
        case .preparing:
            return (.clear, .colorWith(hex: 0xFFFFFF, alpha: 0.16), "", "", .white, .white, 1.0)
        case .recording:
            // No icon or title here: the recording pill's leading control comes from
            // `applyRecordingControlChrome`, which every path that lays it out uses. The
            // stop glyph this used to carry was only ever picked up by the drag collapse,
            // where it rendered at the wrong size in the wrong place.
            return (.clear, .colorWith(hex: 0xFFFFFF, alpha: 0.16), "", "", .white, .white, 1.0)
        case .transcribing:
            return (
                .clear, .colorWith(hex: 0xFFFFFF, alpha: 0.16),
                "", transcribingTitle,
                .white, .colorWith(hex: 0xFFFFFF, alpha: 0.82), 1.0
            )
        }
    }

    private func transitionDuration(from oldState: DictationState, to newState: DictationState, wasHovered: Bool, isHovered: Bool) -> TimeInterval {
        if newState == .preparing {
            return 0
        }
        if oldState == .preparing, newState == .recording {
            return 0
        }
        if oldState == .idle, newState == .idle, wasHovered != isHovered {
            return isHovered ? 0.24 : 0.2
        }
        if oldState == .idle || newState == .idle {
            return 0.18
        }
        return 0.16
    }

    private func layoutLabels(iconLabel: NSTextField, textLabel: NSTextField, in size: NSSize, hasTitle: Bool, animated: Bool) {
        if !hasTitle {
            let iconSize = iconLabel.attributedStringValue.size()
            let iconWidth = max(26, ceil(iconSize.width) + 4)
            let iconHeight = max(18, ceil(iconSize.height))
            let iconFrame = NSRect(
                x: (size.width - iconWidth) / 2,
                y: (size.height - iconHeight) / 2,
                width: iconWidth,
                height: iconHeight
            )
            if animated {
                iconLabel.animator().frame = iconFrame
                textLabel.animator().alphaValue = 0
                textLabel.animator().frame = .zero
            } else {
                iconLabel.frame = iconFrame
                textLabel.alphaValue = 0
                textLabel.frame = .zero
            }
            return
        }

        let iconSize = iconLabel.attributedStringValue.size()
        let textSize = textLabel.attributedStringValue.size()
        let hasIcon = !iconLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let gap: CGFloat = hasIcon ? 4 : 0
        let horizontalPadding: CGFloat = 12

        let iconWidth = hasIcon ? max(24, ceil(iconSize.width) + 2) : 0
        let iconHeight = max(18, ceil(iconSize.height))
        let availableTextWidth = max(0, size.width - (horizontalPadding * 2) - iconWidth - gap)
        let textWidth = min(ceil(textSize.width) + 2, availableTextWidth)
        let textHeight = max(16, ceil(textSize.height))

        let totalWidth = iconWidth + gap + textWidth
        let originX = max((size.width - totalWidth) / 2, horizontalPadding)

        let iconFrame = NSRect(
            x: originX,
            y: (size.height - iconHeight) / 2,
            width: iconWidth,
            height: iconHeight
        )
        let textFrame = NSRect(
            x: originX + iconWidth + gap,
            y: (size.height - textHeight) / 2,
            width: textWidth,
            height: textHeight
        )
        if animated {
            iconLabel.animator().alphaValue = hasIcon ? 1 : 0
            iconLabel.animator().frame = iconFrame
            textLabel.animator().alphaValue = 1
            textLabel.animator().frame = textFrame
        } else {
            iconLabel.alphaValue = hasIcon ? 1 : 0
            iconLabel.frame = iconFrame
            textLabel.alphaValue = 1
            textLabel.frame = textFrame
        }
    }

    static func transcribingPillSizeForTesting(title: String, screenWidth: CGFloat) -> NSSize {
        transcribingPillSize(title: title, screenWidth: screenWidth)
    }

    static func computerUseTranscriptPillSizeForTesting(
        transcript: String,
        screenWidth: CGFloat,
        screenHeight: CGFloat = 900
    ) -> NSSize {
        computerUseTranscriptPillSize(
            transcript: transcript,
            screen: NSRect(x: 0, y: 0, width: screenWidth, height: screenHeight)
        )
    }

    private static func transcribingPillSize(title: String, screenWidth: CGFloat) -> NSSize {
        let font = NSFont.systemFont(ofSize: 11, weight: .regular)
        let iconWidth: CGFloat = 18
        let gap: CGFloat = 6
        let horizontalPadding: CGFloat = 14
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width) + 8
        let preferredWidth = horizontalPadding + iconWidth + gap + textWidth + horizontalPadding
        let minWidth = min(CGFloat(190), max(120, screenWidth - 32))
        let maxWidth = max(minWidth, min(420, screenWidth - 32))
        return NSSize(width: min(max(preferredWidth, minWidth), maxWidth), height: 32)
    }

    private static func computerUseTranscriptPillSize(transcript: String, screen: NSRect) -> NSSize {
        let normalized = normalizedComputerUseTranscript(transcript)
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let iconWidth: CGFloat = 18
        let gap: CGFloat = 8
        let horizontalPadding: CGFloat = 16
        let verticalPadding: CGFloat = 12
        let chromeWidth = horizontalPadding + iconWidth + gap + horizontalPadding
        let minWidth = min(CGFloat(280), max(160, screen.width - 48))
        let maxWidth = max(minWidth, min(720, screen.width - 48))
        let singleLineTextWidth = ceil((normalized as NSString).size(withAttributes: [.font: font]).width) + 2
        let preferredWidth = min(maxWidth, max(minWidth, chromeWidth + singleLineTextWidth))
        let textWidth = max(40, preferredWidth - chromeWidth)
        let textHeight = transcriptTextHeight(normalized, font: font, width: textWidth)
        let maxHeight = max(CGFloat(56), screen.height - 48)
        let preferredHeight = max(CGFloat(44), ceil(textHeight) + (verticalPadding * 2))
        return NSSize(width: preferredWidth, height: min(preferredHeight, maxHeight))
    }

    private static func transcriptTextHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(16, ceil(bounding.height))
    }

    private static func normalizedComputerUseTranscript(_ transcript: String) -> String {
        transcript
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Whether the pointer is over the pill itself.
    ///
    /// Named for what it reads: it tests the indicator's frame, not the transcript's, and
    /// under the old name it was reached for whenever a decision was about "the panel" --
    /// including deciding whether the user was still looking at a transcript parked on the
    /// other side of the screen.
    private func pointerIsInsidePill() -> Bool {
        indicatorScreenFrame?.contains(NSEvent.mouseLocation) == true
    }
}

private extension NSColor {
    static func colorWith(hex: Int, alpha: CGFloat) -> NSColor {
        NSColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }

    static func colorWith(hexString: String, alpha: CGFloat = 1.0) -> NSColor {
        var h = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        h = h.hasPrefix("#") ? String(h.dropFirst()) : h
        guard h.count == 6, let value = UInt64(h, radix: 16) else {
            return .colorWith(hex: 0x1e1e2e, alpha: alpha)
        }
        return .colorWith(hex: Int(value), alpha: alpha)
    }
}
