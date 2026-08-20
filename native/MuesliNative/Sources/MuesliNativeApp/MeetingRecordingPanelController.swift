import AppKit
import QuartzCore
import Foundation

/// Borderless floating panels need to become key only when one of their controls
/// explicitly requests keyboard focus. They must never become the app's main window.
final class InteractiveFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct MeetingRecordingElapsedClock: Equatable {
    private(set) var accumulated: TimeInterval = 0
    private(set) var runningSince: Date?

    mutating func start(at date: Date) {
        accumulated = 0
        runningSince = date
    }

    mutating func pause(at date: Date) {
        guard let runningSince else { return }
        accumulated += max(0, date.timeIntervalSince(runningSince))
        self.runningSince = nil
    }

    mutating func resume(at date: Date) {
        guard runningSince == nil else { return }
        runningSince = date
    }

    mutating func reset() {
        self = MeetingRecordingElapsedClock()
    }

    func elapsed(at date: Date) -> TimeInterval {
        accumulated + (runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }
}

enum MeetingRecordingPanelState: Equatable {
    case hidden
    case recording
    case paused
    case finalizing(String)
}

/// The three sizes of the one merged meeting object. Orthogonal to
/// `MeetingRecordingPanelState`: any state can be shown in any size it allows.
enum MeetingObjectLayout: Equatable {
    case pill
    case row
    case panel
}

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

/// What a pointer at a given point would reach: the drag/discard surface, a header control,
/// or the hosted body, which owns its own clicks.
enum MeetingObjectHitTarget: Equatable {
    case surface
    case body
    case control(String)
}

@MainActor
private final class MeetingRecordingPanelContentView: NSView {
    weak var owner: MeetingRecordingPanelController?
    /// U5's hosted body; every point inside it belongs to the body, never to drag or discard.
    weak var bodyContainer: NSView?
    var accessibilityCustomActionsStorage: [NSAccessibilityCustomAction] = []
    private var trackingAreaRef: NSTrackingArea?
    private var mouseDownScreenLocation: NSPoint?
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        owner?.layoutContent()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        // The body owns its own clicks: a click in the transcript, the chat field or the
        // notes editor must neither drag the object nor open the discard confirmation.
        if let bodyContainer, !bodyContainer.isHidden, bodyContainer.frame.contains(point) {
            return bodyContainer.hitTest(point) ?? bodyContainer
        }
        for subview in subviews.reversed() {
            guard let button = subview as? NSButton, !button.isHidden, button.frame.contains(point) else { continue }
            return button
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        accessibilityCustomActionsStorage
    }

    override func mouseEntered(with event: NSEvent) {
        owner?.pointerEntered()
    }

    override func mouseExited(with event: NSEvent) {
        owner?.pointerExited()
    }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        mouseDownScreenLocation = NSEvent.mouseLocation
        owner?.pointerInteractionBegan(at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownScreenLocation else { return }
        let current = NSEvent.mouseLocation
        guard didDrag || hypot(current.x - mouseDownScreenLocation.x, current.y - mouseDownScreenLocation.y) >= 6 else {
            return
        }
        didDrag = true
        owner?.pointerDragged(to: current)
    }

    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            owner?.discardRequested()
        } else {
            owner?.pointerInteractionEnded(didDrag: didDrag)
        }
        mouseDownScreenLocation = nil
        didDrag = false
    }

    override func rightMouseUp(with event: NSEvent) {
        owner?.discardRequested()
    }
}

@MainActor
final class MeetingRecordingPanelController: NSObject {
    /// The canonical anchor: every other size is derived from this frame, and
    /// `meeting_recording_panel_center` always stores *its* center.
    nonisolated static let basePillSize = NSSize(width: 72, height: 22)
    nonisolated static let widePillSize = NSSize(width: 86, height: 22)
    nonisolated static let rowSize = NSSize(width: 196, height: 22)
    nonisolated static let wideRowSize = NSSize(width: 210, height: 22)
    nonisolated static let defaultPanelSize = NSSize(width: 360, height: 320)
    nonisolated static let minimumPanelSize = NSSize(width: 360, height: 240)
    nonisolated static let panelHeaderHeight: CGFloat = 30
    nonisolated static let pillCornerRadius: CGFloat = 11
    nonisolated static let panelCornerRadius: CGFloat = 14
    /// The pill fits this whole vocabulary at once, so advancing the status never re-steps
    /// the width under the pointer.
    nonisolated static let finalizingStatusWords = [
        "Finalizing", "Transcribing", "Cleaning", "Titling", "Summarizing",
    ]
    nonisolated static let hoverGraceInterval: TimeInterval = 0.4

    nonisolated private static let screenInset: CGFloat = 12
    nonisolated private static let dotDiameter: CGFloat = 8
    nonisolated private static let dotLeading: CGFloat = 9
    nonisolated private static let dotTextGap: CGFloat = 5
    nonisolated private static let pillTrailingInset: CGFloat = 11
    nonisolated private static let waveSlotWidth: CGFloat = 48
    nonisolated private static let controlWidth: CGFloat = 24

    var onStop: (() -> Void)?
    /// Carries the owner the object was showing, so a confirmation the user leaves open while
    /// that meeting stops is never applied to the recording that replaced it.
    var onDiscard: ((UUID) -> Void)?
    var onTogglePause: (() -> Void)?
    var onOpenNotes: (() -> Void)?
    var onControlCenterSaved: ((CGPoint) -> Void)?
    /// Fires only for a user-initiated open or minimize. The start-time
    /// resolution, the finalizing fold, discard and close must never write the
    /// remembered choice, otherwise an automatic transition would masquerade as intent.
    var onPanelOpenSaved: ((Bool) -> Void)?
    /// Announcements go through an injectable sink, as in the Dictation Mini, so tests can
    /// assert them without a live accessibility client.
    var accessibilitySink: (String) -> Void = { message in
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private let now: () -> Date
    private var savedControlCenter: CGPoint?
    private var preferredPanelOpen: Bool?
    private var panelOpenSaveCount = 0
    private var lastSavedPanelOpen: Bool?
    private var state: MeetingRecordingPanelState = .hidden
    private var layout: MeetingObjectLayout = .pill
    private var ownerID: UUID?
    private var elapsedClock = MeetingRecordingElapsedClock()
    private var powerProvider: (() -> Float)?

    /// The live anchor: the *base* pill's center, never a widened or clamped frame's.
    private var anchorCenter: CGPoint?
    private var heldCorner: MeetingObjectCorner = .bottomTrailing
    private var resolvedPanelSize = MeetingRecordingPanelController.defaultPanelSize
    private var appliedContent: MeetingObjectContent?

    private var isPointerInside = false
    private var isPointerDown = false
    private var isDragging = false
    /// After a minimize or the finalizing fold the pointer is still over the object; the row
    /// stays closed until it has left once, otherwise the size the user just dismissed reopens.
    private var hoverSuppressedUntilExit = false
    private var hoverGraceDeadline: Date?
    private var hoverGraceTimer: Timer?

    private var panel: InteractiveFloatingPanel?
    private var contentView: MeetingRecordingPanelContentView?
    private var surfaceView: ContextualSparkGlassSurfaceView?
    private var bodyContainerView: NSView?
    private let dotLayer = CAShapeLayer()
    private let coreLayer = CAShapeLayer()
    private let clusterSeparatorLayer = CALayer()
    private var panelButton: NSButton?
    private var pauseButton: NSButton?
    private var stopButton: NSButton?
    private var elapsedLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var waveformView: ContextualSparkWaveformView?
    private var waveformBarCount = 0
    private var isMorphing = false
    private var animationTimer: Timer?
    private var lastElapsedText: String?
    private var smoothedLevel: CGFloat = 0
    private var dragAnchorOrigin: CGPoint?
    private var dragPointerOrigin: NSPoint?
    private var dragScreenFrames: [NSRect] = []
    private var announcementsForTesting: [String] = []
    private var notificationObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// The panel body's model and focus rules. Held for the whole recording, not just
    /// while the panel is open, so the transcript keeps arriving into the pill and the
    /// selected tab, notes draft and chat context survive minimize and reopen.
    private let bodyCoordinator = MeetingPanelBodyCoordinator()
    private var bodyHostingView: FirstMouseHostingView<MeetingPanelBody>?

    init(
        configStore: ConfigStore,
        configuration: AppConfig? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        let configuration = configuration ?? configStore.load()
        self.now = now
        self.savedControlCenter = configuration.meetingRecordingPanelCenter.map { CGPoint(x: $0.x, y: $0.y) }
        self.preferredPanelOpen = configuration.meetingPanelOpen
        super.init()

        // The body lives inside the one merged window, so its focus rules resign and
        // hit-test against that window rather than one of their own.
        bodyCoordinator.panelWindowProvider = { [weak self] in self?.panel }

        let screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcilePanelToAttachedScreens() }
        }
        notificationObservers.append((NotificationCenter.default, screenObserver))

        let resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleLiveResizeEnded(notification) }
        }
        notificationObservers.append((NotificationCenter.default, resizeObserver))

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let accessibilityObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAccessibilityPresentation() }
        }
        notificationObservers.append((workspaceCenter, accessibilityObserver))
    }

    deinit {
        for observer in notificationObservers {
            observer.center.removeObserver(observer.token)
        }
    }

    /// Mirrors `accessibilityDisplayShouldReduceMotion`. Injectable so tests can assert the
    /// frame the object landed on instead of an in-flight morph.
    var reduceMotionOverrideForTesting: Bool?

    var isVisible: Bool { panel?.isVisible == true }
    var isPanelOpen: Bool { layout == .panel }
    var stateForTesting: MeetingRecordingPanelState { state }
    var layoutForTesting: MeetingObjectLayout { layout }
    var frameForTesting: NSRect? { panel?.frame }
    var heldCornerForTesting: MeetingObjectCorner { heldCorner }
    var anchorCenterForTesting: CGPoint? { anchorCenter }
    var activeOwnerIDForTesting: UUID? { ownerID }
    var elapsedSecondsForTesting: TimeInterval { elapsedClock.elapsed(at: now()) }
    var accessibilityAnnouncementsForTesting: [String] { announcementsForTesting }
    var accessibilityRoleForTesting: NSAccessibility.Role? { contentView?.accessibilityRole() }
    var accessibilityLabelForTesting: String? { contentView?.accessibilityLabel() }
    var accessibilityCustomActionNamesForTesting: [String] {
        contentView?.accessibilityCustomActionsStorage.map(\.name) ?? []
    }
    var surfaceStyleForTesting: ContextualSparkSurfaceStyle? { surfaceView?.resolvedStyleForTesting }
    var controlsEnabledForTesting: Bool {
        [pauseButton, stopButton, panelButton].allSatisfy { $0?.isEnabled == true }
    }
    var controlAccessibilityLabelsForTesting: [String] {
        guard layout != .pill else { return [] }
        return [pauseButton, stopButton, panelButton].compactMap { $0?.accessibilityLabel() }
    }
    var hasMeetingContextForTesting: Bool { bodyCoordinator.hasMeetingContextForTesting }
    var panelBodyForTesting: MeetingPanelBodyCoordinator { bodyCoordinator }
    var isPanelBodyHostedForTesting: Bool { bodyHostingView != nil }
    var preferredPanelOpenForTesting: Bool? { preferredPanelOpen }
    /// Derived, never stored: the live layout is the only authority on whether the panel is
    /// open, so a fold (finalizing) cannot leave a second copy of that fact reading stale.
    var resolvedPanelOpenForTesting: Bool { layout == .panel }
    var panelOpenSaveCountForTesting: Int { panelOpenSaveCount }
    var lastSavedPanelOpenForTesting: Bool? { lastSavedPanelOpen }
    /// The dot and the clock must not move when the row unfolds, so both are asserted in
    /// screen coordinates.
    var dotOriginForTesting: CGPoint? {
        guard let panel, let box = dotLayer.path?.boundingBox else { return nil }
        return panel.convertPoint(toScreen: CGPoint(x: box.minX, y: box.minY))
    }
    var clockOriginForTesting: CGPoint? {
        guard let panel, let elapsedLabel else { return nil }
        return panel.convertPoint(toScreen: elapsedLabel.frame.origin)
    }
    var controlFramesForTesting: [String: NSRect] {
        var frames: [String: NSRect] = [:]
        for button in [pauseButton, stopButton, panelButton] {
            guard let button, !button.isHidden, let label = button.accessibilityLabel() else { continue }
            frames[label] = button.frame
        }
        return frames
    }

    /// Drives one 30 Hz tick without a run loop.
    func tickForTesting() {
        updateElapsedLabelIfNeeded()
        updateWaveLevel()
    }

    func hitTargetForTesting(at point: NSPoint) -> MeetingObjectHitTarget? {
        guard let contentView, let hit = contentView.hitTest(point) else { return nil }
        if hit === contentView { return .surface }
        if let body = bodyContainerView, hit === body || hit.isDescendant(of: body) { return .body }
        if let button = hit as? NSButton { return .control(button.accessibilityLabel() ?? "") }
        return .surface
    }

    /// Config is only the seed for the *next* start: the live layout stays
    /// authoritative, so a re-entrant config apply never re-folds an open panel.
    func applyConfiguration(_ configuration: AppConfig) {
        savedControlCenter = configuration.meetingRecordingPanelCenter.map { CGPoint(x: $0.x, y: $0.y) }
        preferredPanelOpen = configuration.meetingPanelOpen
    }

    /// The remembered choice wins for every start that can present the floating
    /// object; a start that opens the meeting document always rests as the pill.
    nonisolated static func resolvesPanelOpen(
        preferred: Bool?,
        presentation: MeetingStartPresentation
    ) -> Bool {
        guard !presentation.opensMeetingDocument else { return false }
        return preferred ?? presentation.presentsFloatingPanelWhenRecordingStarts
    }

    func showRecording(
        ownerID: UUID,
        startedAt: Date,
        powerProvider: @escaping () -> Float,
        chatContext: FloatingMeetingChatContext? = nil,
        presentation: MeetingStartPresentation
    ) {
        self.ownerID = ownerID
        self.powerProvider = powerProvider
        state = .recording
        layout = .pill
        appliedContent = nil
        hoverSuppressedUntilExit = false
        elapsedClock.start(at: startedAt)
        bodyCoordinator.reset()
        bodyCoordinator.setChatContext(chatContext)
        bodyCoordinator.setPaused(false)
        bodyCoordinator.setSelectionAccentHex(DictationMiniPalette.accentHex)

        let panel = panel ?? makePanel()
        self.panel = panel
        resolvedPanelSize = Self.defaultPanelSize
        // The held corner is chosen from the base pill once per recording and kept from here on.
        let screens = NSScreen.screens.map(\.visibleFrame)
        let pill = Self.basePillFrame(anchorCenter: savedControlCenter, screens: screens)
        anchorCenter = CGPoint(x: pill.midX, y: pill.midY)
        heldCorner = Self.heldCorner(for: pill, in: Self.screenFrame(containing: anchorCenter ?? .zero, screens: screens))
        updateFrameForCurrentLayout(animated: false)
        updateChrome()
        panel.orderFrontRegardless()
        surfaceView?.updateBackingScale(panel.backingScaleFactor)
        waveformView?.updateBackingScale(panel.backingScaleFactor)
        startAnimationTimer()

        if Self.resolvesPanelOpen(preferred: preferredPanelOpen, presentation: presentation) {
            openPanel(userInitiated: false, animated: false)
        }
    }

    func setPaused(_ paused: Bool, ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        switch state {
        case .recording where paused:
            elapsedClock.pause(at: now())
            state = .paused
            stopAnimationTimer()
            announce("Meeting recording paused")
        case .paused where !paused:
            elapsedClock.resume(at: now())
            state = .recording
            startAnimationTimer()
            announce("Meeting recording resumed")
        default:
            return
        }
        bodyCoordinator.setPaused(paused)
        updateChrome()
    }

    func beginFinalizing(ownerID: UUID, status: String = "Finalizing") {
        guard self.ownerID == ownerID else { return }
        if state == .recording {
            elapsedClock.pause(at: now())
        }
        state = .finalizing(status)
        powerProvider = nil
        stopAnimationTimer()
        // Release focus before the body folds away: a key window the user cannot see keeps
        // swallowing the keystrokes meant for the call. The body's content is *not* reset —
        // the transcript and notes stay readable in the panel until the meeting is saved.
        bodyCoordinator.releaseFocus()
        // The fold is not the user dismissing the panel, so hover must not reopen the row
        // under a pointer that never moved.
        hoverSuppressedUntilExit = true
        setLayout(.pill, animated: true)
        announce("Meeting recording \(status.lowercased())")
    }

    func updateFinalizingStatus(_ status: String, ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        guard case .finalizing = state else { return }
        state = .finalizing(status)
        updateChrome()
    }

    func close(ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        close()
    }

    func close() {
        stopAnimationTimer()
        cancelHoverGrace()
        // Focus first, then content, then the views: a body torn out from under a key
        // window leaves the keyboard trapped in a window nothing can reach.
        bodyCoordinator.reset()
        bodyCoordinator.teardown()
        bodyHostingView?.removeFromSuperview()
        bodyHostingView = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        contentView = nil
        surfaceView = nil
        bodyContainerView = nil
        panelButton = nil
        pauseButton = nil
        stopButton = nil
        elapsedLabel = nil
        statusLabel = nil
        waveformView = nil
        waveformBarCount = 0
        lastElapsedText = nil
        powerProvider = nil
        ownerID = nil
        state = .hidden
        layout = .pill
        appliedContent = nil
        elapsedClock.reset()
        isPointerInside = false
        isPointerDown = false
        isDragging = false
        hoverSuppressedUntilExit = false
        anchorCenter = savedControlCenter
        resolvedPanelSize = Self.defaultPanelSize
        dragAnchorOrigin = nil
        dragPointerOrigin = nil
        dragScreenFrames.removeAll()
    }

    /// Feeds the body while the object is any size: the pill and the row keep the model
    /// current so an open lands on a transcript that is already there.
    func updateMeetingTranscript(transcript: String, partialYou: String, partialOthers: String) {
        bodyCoordinator.update(
            transcript: transcript,
            partialYou: partialYou,
            partialOthers: partialOthers
        )
    }

    func setMeetingChatContext(_ context: FloatingMeetingChatContext?) {
        bodyCoordinator.setChatContext(context)
    }

    /// The status bar's "Open/Minimize Meeting Panel" and the header buttons: a user toggle,
    /// so it writes the remembered choice exactly once.
    func toggleTranscriptPanel() {
        guard state == .recording || state == .paused else { return }
        if layout == .panel {
            minimizePanel(userInitiated: true)
        } else {
            openPanel(userInitiated: true, animated: true)
        }
    }

    // MARK: Hover

    func pointerEntered() {
        isPointerInside = true
        guard !hoverSuppressedUntilExit, layout == .pill, state != .hidden else { return }
        cancelHoverGrace()
        setLayout(.row, animated: true)
    }

    func pointerExited() {
        isPointerInside = false
        hoverSuppressedUntilExit = false
        guard layout == .row else { return }
        scheduleHoverGrace()
    }

    /// Drives the fold without a run loop: `now` is injected, so advancing the test clock and
    /// firing here reproduces the 0.4 s timer exactly.
    func fireHoverGraceForTesting() {
        evaluateHoverGrace(at: now())
    }

    private func scheduleHoverGrace() {
        hoverGraceDeadline = now().addingTimeInterval(Self.hoverGraceInterval)
        hoverGraceTimer?.invalidate()
        hoverGraceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.hoverGraceInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.evaluateHoverGrace(at: self.now())
            }
        }
    }

    private func cancelHoverGrace() {
        hoverGraceTimer?.invalidate()
        hoverGraceTimer = nil
        hoverGraceDeadline = nil
    }

    private func evaluateHoverGrace(at date: Date) {
        guard layout == .row, let deadline = hoverGraceDeadline else { return }
        // A press or a live drag holds the row open; the fold re-arms when the pointer is up.
        guard !isPointerInside, !isPointerDown, !isDragging else {
            hoverGraceDeadline = nil
            return
        }
        guard date >= deadline else { return }
        cancelHoverGrace()
        setLayout(.pill, animated: true)
    }

    // MARK: Pointer

    func pointerInteractionBegan(at screenPoint: NSPoint) {
        guard let panel else { return }
        isPointerDown = true
        // A plain setFrame does not cancel an in-flight animator().setFrame, so the morph is
        // retargeted to where the window actually is before the drag takes over.
        cancelFrameAnimation()
        dragAnchorOrigin = anchorCenter ?? CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        dragPointerOrigin = screenPoint
        dragScreenFrames = NSScreen.screens.map(\.visibleFrame)
    }

    func pointerDragged(to screenPoint: NSPoint) {
        guard let dragAnchorOrigin, let dragPointerOrigin else { return }
        isDragging = true
        // Every size moves the anchor by the pointer delta; the frame is re-derived from it.
        anchorCenter = CGPoint(
            x: dragAnchorOrigin.x + screenPoint.x - dragPointerOrigin.x,
            y: dragAnchorOrigin.y + screenPoint.y - dragPointerOrigin.y
        )
        updateFrameForCurrentLayout(animated: false, screens: dragScreenFrames)
    }

    func pointerInteractionEnded(didDrag: Bool) {
        defer {
            isPointerDown = false
            isDragging = false
            dragAnchorOrigin = nil
            dragPointerOrigin = nil
            dragScreenFrames.removeAll()
            if !isPointerInside, layout == .row { scheduleHoverGrace() }
        }
        guard didDrag else { return }
        let screens = dragScreenFrames.isEmpty ? NSScreen.screens.map(\.visibleFrame) : dragScreenFrames
        // Save the *base pill's* center, never the dragged size's midpoint.
        let pill = Self.basePillFrame(anchorCenter: anchorCenter, screens: screens)
        let center = CGPoint(x: pill.midX, y: pill.midY)
        anchorCenter = center
        savedControlCenter = center
        onControlCenterSaved?(center)
    }

    func discardRequested() {
        guard state == .recording || state == .paused, let ownerID else { return }
        onDiscard?(ownerID)
    }

    // MARK: Geometry

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
        if let savedCenter,
           let screen = screens.first(where: { $0.contains(savedCenter) }) {
            return clampedFrame(center: savedCenter, size: size, in: screen)
        }
        return clampedFrame(center: defaultCenter(in: fallback, size: size), size: size, in: fallback)
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

    // MARK: Layout

    private var currentContent: MeetingObjectContent {
        content(for: layout)
    }

    private func content(for layout: MeetingObjectLayout) -> MeetingObjectContent {
        if case .finalizing(let status) = state, layout == .pill {
            return .status(status)
        }
        return .clock(hasHours: elapsedClock.elapsed(at: now()) >= 3_600)
    }

    private func setLayout(_ newLayout: MeetingObjectLayout, animated: Bool) {
        guard state != .hidden, panel != nil else { return }
        layout = newLayout
        // The frame is re-derived even when the layout is unchanged: the finalizing status
        // word steps the pill's width on the same path.
        updateFrameForCurrentLayout(animated: animated)
        updateChrome()
    }

    private func updateFrameForCurrentLayout(animated: Bool, screens: [NSRect]? = nil) {
        guard panel != nil else { return }
        let screens = screens ?? NSScreen.screens.map(\.visibleFrame)
        let pill = Self.basePillFrame(anchorCenter: anchorCenter, screens: screens)
        anchorCenter = CGPoint(x: pill.midX, y: pill.midY)
        let screen = Self.screenFrame(containing: CGPoint(x: pill.midX, y: pill.midY), screens: screens)
        let content = currentContent
        let size = Self.size(for: layout, content: content, panelSize: resolvedPanelSize)
        heldCorner = Self.resolvedCorner(heldCorner, size: size, anchoredTo: pill, screen: screen)
        appliedContent = content
        let target = Self.frame(
            for: layout,
            anchoredTo: pill,
            corner: heldCorner,
            size: size,
            screen: screen
        )
        setPanelFrame(target, animated: animated)
    }

    private func setPanelFrame(_ frame: NSRect, animated: Bool) {
        guard let panel else { return }
        guard animated, !reducesMotion, panel.isVisible else {
            applyContentSizeLimits()
            panel.setFrame(frame, display: true)
            layoutContent()
            return
        }
        // The pinned pill/row size would clamp every intermediate frame, so the limits are
        // released for the morph and re-pinned when it lands.
        releaseContentSizeLimits()
        isMorphing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DictationMiniRendering.morphDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.isMorphing = false
                self?.applyContentSizeLimits()
                self?.layoutContent()
            }
        }
    }

    private var reducesMotion: Bool {
        reduceMotionOverrideForTesting ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func cancelFrameAnimation() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrame(panel.frame, display: false)
        }
    }

    private func applyContentSizeLimits() {
        guard let panel else { return }
        switch layout {
        case .pill, .row:
            panel.contentMinSize = panel.frame.size
            panel.contentMaxSize = panel.frame.size
        case .panel:
            panel.contentMinSize = Self.minimumPanelSize
            panel.contentMaxSize = NSSize(width: 20_000, height: 20_000)
        }
    }

    private func releaseContentSizeLimits() {
        guard let panel else { return }
        panel.contentMinSize = NSSize(width: 1, height: 1)
        panel.contentMaxSize = NSSize(width: 20_000, height: 20_000)
    }

    private func handleLiveResizeEnded(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        reanchorAfterResize()
    }

    /// The held corner survives a resize; the anchor is re-derived from it so a later minimize
    /// returns the pill to the corner the panel was left on.
    private func reanchorAfterResize() {
        guard let panel, layout == .panel else { return }
        resolvedPanelSize = panel.frame.size
        let center = Self.anchorCenter(afterDragging: panel.frame, corner: heldCorner)
        guard center != anchorCenter else { return }
        anchorCenter = center
        savedControlCenter = center
        onControlCenterSaved?(center)
    }

    /// Reproduces an edge resize that ends: the window takes the new size keeping the held
    /// corner, then the anchor is re-derived.
    func endLiveResizeForTesting(to size: NSSize) {
        guard let panel, layout == .panel else { return }
        let frame = panel.frame
        panel.setFrame(
            NSRect(
                x: heldCorner.holdsTrailing ? frame.maxX - size.width : frame.minX,
                y: heldCorner.holdsTop ? frame.maxY - size.height : frame.minY,
                width: size.width,
                height: size.height
            ),
            display: false
        )
        reanchorAfterResize()
    }

    private func reconcilePanelToAttachedScreens() {
        guard let panel, panel.isVisible else { return }
        updateFrameForCurrentLayout(animated: false)
        surfaceView?.updateBackingScale(panel.backingScaleFactor)
        waveformView?.updateBackingScale(panel.backingScaleFactor)
    }

    // MARK: Panel open / minimize

    private func openPanel(userInitiated: Bool, animated: Bool) {
        guard state == .recording || state == .paused else { return }
        guard layout != .panel else { return }
        // Hosted before the layout change so the first `layoutPanel` already has a body to
        // size; the host survives minimize and reopen, which is what carries the selected
        // tab, the chat draft and the notes draft across the fold.
        installPanelBodyIfNeeded()
        setLayout(.panel, animated: animated)
        // The selected tab survives a minimize, so a reopen can land straight on Chat or My
        // notes; the outside-click rule has to come back with it.
        bodyCoordinator.resumeFocusRules()
        // orderFront, never makeKey: an object that takes focus during a call swallows the
        // keystrokes meant for Zoom. Chat and My notes ask for key themselves when clicked.
        panel?.orderFront(nil)
        announce("Meeting panel opened")
        if userInitiated { rememberPanelOpen(true) }
    }

    private func minimizePanel(userInitiated: Bool) {
        guard layout == .panel else { return }
        // Focus is handed back before the body disappears. Folding away a key window without
        // resigning leaves an invisible window holding the keyboard, so keystrokes meant for
        // the call vanish into a body the user cannot even see.
        bodyCoordinator.releaseFocus()
        // The pointer is still over the object after a minimize; the row waits for it to leave.
        hoverSuppressedUntilExit = true
        setLayout(.pill, animated: true)
        announce("Meeting panel minimized")
        if userInitiated { rememberPanelOpen(false) }
    }

    private func rememberPanelOpen(_ isOpen: Bool) {
        preferredPanelOpen = isOpen
        panelOpenSaveCount += 1
        lastSavedPanelOpen = isOpen
        onPanelOpenSaved?(isOpen)
    }

    private func installPanelBodyIfNeeded() {
        guard let bodyContainerView, bodyHostingView == nil else { return }
        let hosting = FirstMouseHostingView(
            rootView: MeetingPanelBody(
                model: bodyCoordinator.model,
                onOpenNotes: { [weak self] in
                    // The meeting document is about to take the screen; a 360x320 panel
                    // parked over it helps nobody. Not a user minimize, so it must not
                    // overwrite the remembered open/minimize choice.
                    self?.minimizePanel(userInitiated: false)
                    self?.onOpenNotes?()
                },
                // Through the coordinator, never straight to the model: opening a typing
                // tab has to arm outside-click dismissal and leaving it has to hand
                // keyboard focus back.
                onSelectTab: { [weak self] tab in
                    self?.bodyCoordinator.selectTab(tab)
                }
            )
        )
        hosting.wantsLayer = true
        // The controller owns the window's frame; SwiftUI must never drive it. With the
        // default sizing options the async content pass re-moves the frame the morph just
        // landed on, from whatever anchor a zero-size host was last given.
        hosting.sizingOptions = []
        // `layoutPanel` drives the frame, not an autoresizing mask: the pill and the row
        // collapse the container to zero, and autoresizing from a zero box back to 360 pt
        // is where the proportions go to NaN.
        hosting.frame = bodyContainerView.bounds
        bodyContainerView.addSubview(hosting)
        bodyHostingView = hosting
    }

    // MARK: Window

    private func makePanel() -> InteractiveFloatingPanel {
        let panel = InteractiveFloatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.basePillSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = MeetingRecordingPanelContentView(frame: NSRect(origin: .zero, size: Self.basePillSize))
        content.owner = self
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.setAccessibilityElement(true)
        panel.contentView = content
        contentView = content

        let surface = ContextualSparkGlassSurfaceView(cornerRadius: Self.pillCornerRadius)
        surface.frame = content.bounds
        surface.autoresizingMask = [.width, .height]
        content.addSubview(surface)
        surfaceView = surface

        dotLayer.shadowOffset = .zero
        dotLayer.shadowRadius = 3
        surface.decorLayer.addSublayer(dotLayer)
        surface.decorLayer.addSublayer(coreLayer)
        clusterSeparatorLayer.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        clusterSeparatorLayer.isHidden = true
        surface.decorLayer.addSublayer(clusterSeparatorLayer)

        let body = NSView(frame: .zero)
        body.wantsLayer = true
        body.isHidden = true
        content.addSubview(body)
        content.bodyContainer = body
        bodyContainerView = body

        let elapsed = NSTextField(labelWithString: "00:00")
        elapsed.alignment = .left
        elapsed.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        elapsed.lineBreakMode = .byClipping
        elapsed.setAccessibilityLabel("Elapsed meeting recording time")
        content.addSubview(elapsed)
        elapsedLabel = elapsed

        let status = NSTextField(labelWithString: "")
        status.alignment = .center
        status.font = .systemFont(ofSize: 10, weight: .semibold)
        status.lineBreakMode = .byClipping
        status.isHidden = true
        status.setAccessibilityLabel("Meeting recording status")
        content.addSubview(status)
        statusLabel = status

        pauseButton = makeButton(
            symbol: "pause.fill",
            accessibilityLabel: "Pause meeting recording",
            action: #selector(pauseButtonPressed)
        )
        stopButton = makeButton(
            symbol: "stop.fill",
            accessibilityLabel: "Stop meeting recording",
            action: #selector(stopButtonPressed)
        )
        panelButton = makeButton(
            symbol: "arrow.up.left.and.arrow.down.right",
            accessibilityLabel: "Open meeting panel",
            action: #selector(panelButtonPressed)
        )
        if let pauseButton { content.addSubview(pauseButton) }
        if let stopButton { content.addSubview(stopButton) }
        if let panelButton { content.addSubview(panelButton) }

        pauseButton?.nextKeyView = stopButton
        stopButton?.nextKeyView = panelButton
        panelButton?.nextKeyView = pauseButton

        layoutContent()
        refreshAccessibilityPresentation()
        return panel
    }

    private func makeButton(symbol: String, accessibilityLabel: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = configuredSymbol(symbol, description: accessibilityLabel)
        button.contentTintColor = NSColor.colorWith(hex: DictationMiniPalette.inkHex, alpha: 0.86)
        button.focusRingType = .default
        button.target = self
        button.action = action
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = accessibilityLabel
        button.isHidden = true
        return button
    }

    private func configuredSymbol(_ name: String, description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
    }

    /// Places the dot, the clock, the wave slot and the controls for the current layout.
    /// Called on every frame change, so a morph lays out as the window resizes.
    func layoutContent() {
        guard let contentView else { return }
        let bounds = contentView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        switch layout {
        case .pill:
            layoutPill(in: bounds)
        case .row:
            layoutRow(in: bounds)
        case .panel:
            layoutPanel(in: bounds)
        }
    }

    private func layoutPill(in bounds: NSRect) {
        let textX = Self.dotLeading + Self.dotDiameter + Self.dotTextGap
        let textRect = NSRect(
            x: textX,
            y: (bounds.height - 14) / 2 - 0.5,
            width: max(0, bounds.width - textX - Self.pillTrailingInset),
            height: 14
        )
        placeDot(centeredIn: NSRect(x: Self.dotLeading, y: 0, width: Self.dotDiameter, height: bounds.height))
        if case .status = currentContent {
            statusLabel?.alignment = .left
            statusLabel?.frame = textRect
            elapsedLabel?.frame = textRect
        } else {
            elapsedLabel?.frame = textRect
        }
        bodyContainerView?.frame = .zero
        clusterSeparatorLayer.isHidden = true
    }

    private func layoutRow(in bounds: NSRect) {
        let pillWidth = Self.pillSize(for: .clock(hasHours: isPastFirstHour)).width
        // The dot and clock never move when the row unfolds: at a trailing corner the row
        // grows leftward, so the pill block sits at its right end and the controls mirror.
        let mirrored = heldCorner.holdsTrailing
        let pillOriginX = mirrored ? bounds.width - pillWidth : 0
        let dotX = pillOriginX + Self.dotLeading
        let clockX = dotX + Self.dotDiameter + Self.dotTextGap
        placeDot(centeredIn: NSRect(x: dotX, y: 0, width: Self.dotDiameter, height: bounds.height))
        elapsedLabel?.frame = NSRect(
            x: clockX,
            y: (bounds.height - 14) / 2 - 0.5,
            width: max(0, pillWidth - Self.dotLeading - Self.dotDiameter - Self.dotTextGap),
            height: 14
        )

        let waveRect: NSRect
        if mirrored {
            let waveMaxX = pillOriginX - 8
            waveRect = NSRect(x: waveMaxX - Self.waveSlotWidth, y: (bounds.height - 14) / 2, width: Self.waveSlotWidth, height: 14)
            var x = waveRect.minX - 6
            for button in [pauseButton, stopButton, panelButton] {
                x -= Self.controlWidth
                button?.frame = NSRect(x: x, y: 0, width: Self.controlWidth, height: bounds.height)
            }
        } else {
            var x = bounds.width - 6
            for button in [panelButton, stopButton, pauseButton] {
                x -= Self.controlWidth
                button?.frame = NSRect(x: x, y: 0, width: Self.controlWidth, height: bounds.height)
            }
            waveRect = NSRect(x: x - 6 - Self.waveSlotWidth, y: (bounds.height - 14) / 2, width: Self.waveSlotWidth, height: 14)
        }
        placeWave(in: waveRect)
        statusLabel?.alignment = .center
        statusLabel?.frame = NSRect(x: waveRect.minX, y: waveRect.midY - 7, width: waveRect.width, height: 14)
        bodyContainerView?.frame = .zero
        clusterSeparatorLayer.isHidden = true
    }

    private func layoutPanel(in bounds: NSRect) {
        let headerY = bounds.height - Self.panelHeaderHeight
        let header = NSRect(x: 0, y: headerY, width: bounds.width, height: Self.panelHeaderHeight)
        placeDot(centeredIn: NSRect(x: 11, y: header.minY, width: Self.dotDiameter, height: header.height))
        let clockX = 11 + Self.dotDiameter + Self.dotTextGap
        let clockWidth = Self.pillSize(for: .clock(hasHours: isPastFirstHour)).width
            - Self.dotLeading - Self.dotDiameter - Self.dotTextGap - Self.pillTrailingInset
        elapsedLabel?.frame = NSRect(
            x: clockX,
            y: header.midY - 7,
            width: clockWidth,
            height: 14
        )

        // One trailing cluster: pause · stop ‖ minimize behind a hairline (node 17, variant A).
        var x = bounds.width - 6
        x -= Self.controlWidth
        panelButton?.frame = NSRect(x: x, y: header.minY, width: Self.controlWidth, height: header.height)
        let separatorX = x - 5
        clusterSeparatorLayer.isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clusterSeparatorLayer.frame = CGRect(x: separatorX, y: header.midY - 7, width: 1, height: 14)
        CATransaction.commit()
        x = separatorX - 4
        for button in [stopButton, pauseButton] {
            x -= Self.controlWidth
            button?.frame = NSRect(x: x, y: header.minY, width: Self.controlWidth, height: header.height)
        }

        let waveMinX = clockX + clockWidth + 10
        let waveRect = NSRect(x: waveMinX, y: header.midY - 7, width: max(24, x - 10 - waveMinX), height: 14)
        placeWave(in: waveRect)
        statusLabel?.alignment = .center
        statusLabel?.frame = NSRect(x: waveRect.minX, y: waveRect.minY, width: waveRect.width, height: 14)
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, headerY))
        bodyContainerView?.frame = body
        bodyHostingView?.frame = NSRect(origin: .zero, size: body.size)
    }

    private var isPastFirstHour: Bool {
        elapsedClock.elapsed(at: now()) >= 3_600
    }

    private func placeDot(centeredIn rect: NSRect) {
        let dotRect = CGRect(
            x: rect.minX,
            y: rect.midY - Self.dotDiameter / 2,
            width: Self.dotDiameter,
            height: Self.dotDiameter
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.path = CGPath(ellipseIn: dotRect, transform: nil)
        coreLayer.path = CGPath(
            ellipseIn: dotRect.insetBy(dx: 2.5, dy: 2.5).offsetBy(dx: -0.4, dy: 0.4),
            transform: nil
        )
        CATransaction.commit()
    }

    private func placeWave(in rect: NSRect) {
        guard let contentView else { return }
        let barCount = max(8, Int((rect.width / DictationMiniRendering.recordingBarPitch).rounded(.down)))
        // The field is rebuilt for the landed width only: a morph resizes the existing bars
        // rather than allocating a new field on every animation step.
        if waveformView == nil || (barCount != waveformBarCount && !isMorphing) {
            waveformView?.removeFromSuperview()
            let wave = ContextualSparkWaveformView(
                frame: rect,
                barCount: barCount,
                maxHeight: 12
            )
            contentView.addSubview(wave)
            waveformView = wave
            waveformBarCount = barCount
            wave.updateBackingScale(panel?.backingScaleFactor ?? 2)
        }
        waveformView?.frame = rect
    }

    // MARK: Chrome

    private func updateChrome() {
        guard contentView != nil else { return }
        updateElapsedLabelIfNeeded()
        let ink = DictationMiniPalette.inkHex
        let amber = NSColor.colorWith(hex: DictationMiniPalette.accentHighlightHex, alpha: 0.92)
        let showsControls = layout != .pill
        let controlsEnabled: Bool
        var statusText: String?
        var clockAlpha: CGFloat = 0.92

        switch state {
        case .hidden:
            controlsEnabled = false
        case .recording:
            controlsEnabled = true
            pauseButton?.image = configuredSymbol("pause.fill", description: "Pause meeting recording")
            pauseButton?.setAccessibilityLabel("Pause meeting recording")
            pauseButton?.toolTip = "Pause meeting recording"
        case .paused:
            controlsEnabled = true
            clockAlpha = 0.70
            statusText = "Paused"
            pauseButton?.image = configuredSymbol("play.fill", description: "Resume meeting recording")
            pauseButton?.setAccessibilityLabel("Resume meeting recording")
            pauseButton?.toolTip = "Resume meeting recording"
        case .finalizing(let status):
            controlsEnabled = false
            clockAlpha = 0.70
            statusText = status
        }

        let panelSymbol = layout == .panel ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        let panelLabel = layout == .panel ? "Minimize meeting panel" : "Open meeting panel"
        panelButton?.image = configuredSymbol(panelSymbol, description: panelLabel)
        panelButton?.setAccessibilityLabel(panelLabel)
        panelButton?.toolTip = panelLabel

        // The pill trades the clock for the status word; the row and the header keep the clock
        // at 70 % and put the status word in the wave slot.
        let pillShowsStatus: Bool
        if case .status = currentContent { pillShowsStatus = true } else { pillShowsStatus = false }
        elapsedLabel?.isHidden = pillShowsStatus
        elapsedLabel?.textColor = NSColor.colorWith(hex: ink, alpha: clockAlpha)
        statusLabel?.textColor = amber
        if pillShowsStatus {
            statusLabel?.isHidden = false
            statusLabel?.stringValue = statusText ?? ""
        } else if showsControls, let statusText {
            statusLabel?.isHidden = false
            statusLabel?.stringValue = statusText
        } else {
            statusLabel?.isHidden = true
            statusLabel?.stringValue = ""
        }
        statusLabel?.setAccessibilityValue(statusLabel?.stringValue ?? "")

        waveformView?.isHidden = !showsControls || statusLabel?.isHidden == false
        for button in [pauseButton, stopButton, panelButton] {
            button?.isHidden = !showsControls
            button?.isEnabled = controlsEnabled
            button?.alphaValue = controlsEnabled ? 1 : 0.36
        }
        bodyContainerView?.isHidden = layout != .panel

        surfaceView?.apply(cornerRadius: layout == .panel ? Self.panelCornerRadius : Self.pillCornerRadius)
        contentView?.layer?.cornerRadius = layout == .panel ? Self.panelCornerRadius : Self.pillCornerRadius
        contentView?.layer?.cornerCurve = .continuous
        updateDot()
        updateWaveLevel()
        layoutContent()
        updateAccessibility()
    }

    private func updateDot() {
        let coral = NSColor.colorWith(hex: DictationMiniPalette.accentHex, alpha: 1)
        let amber = NSColor.colorWith(hex: DictationMiniPalette.accentHighlightHex, alpha: 1)
        let reduceMotion = reducesMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.removeAllAnimations()
        switch state {
        case .hidden:
            break
        case .recording:
            dotLayer.fillColor = coral.cgColor
            dotLayer.shadowColor = coral.cgColor
            dotLayer.shadowOpacity = 1
            coreLayer.fillColor = amber.withAlphaComponent(0.78).cgColor
            if !reduceMotion { breathe(duration: 1.6, from: 2, to: 4) }
        case .paused:
            dotLayer.fillColor = amber.cgColor
            dotLayer.shadowOpacity = 0
            coreLayer.fillColor = NSColor.white.withAlphaComponent(0.55).cgColor
        case .finalizing:
            dotLayer.fillColor = amber.cgColor
            dotLayer.shadowColor = amber.cgColor
            dotLayer.shadowOpacity = 1
            coreLayer.fillColor = NSColor.white.withAlphaComponent(0.6).cgColor
            if !reduceMotion { breathe(duration: 0.9, from: 1.5, to: 4) }
        }
        CATransaction.commit()
    }

    private func breathe(duration: TimeInterval, from: CGFloat, to: CGFloat) {
        let radius = CABasicAnimation(keyPath: "shadowRadius")
        radius.fromValue = from
        radius.toValue = to
        let opacity = CABasicAnimation(keyPath: "shadowOpacity")
        opacity.fromValue = 0.5
        opacity.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [radius, opacity]
        group.duration = duration / 2
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dotLayer.add(group, forKey: "halo")
    }

    private func refreshAccessibilityPresentation() {
        surfaceView?.refreshAccessibilityPresentation()
        waveformView?.refreshAccessibilityPresentation()
        updateChrome()
    }

    private func updateAccessibility() {
        guard let contentView else { return }
        let clock = lastElapsedText ?? "00:00"
        let stateWord: String
        switch state {
        case .hidden: stateWord = ""
        case .recording: stateWord = "recording"
        case .paused: stateWord = "paused"
        case .finalizing(let status): stateWord = status.lowercased()
        }
        contentView.setAccessibilityLabel("Meeting recording, \(clock), \(stateWord)")
        switch layout {
        case .pill:
            contentView.setAccessibilityRole(.button)
            contentView.accessibilityCustomActionsStorage = pillCustomActions()
            panel?.initialFirstResponder = nil
            if panel?.firstResponder is NSView { panel?.makeFirstResponder(nil) }
        case .row, .panel:
            contentView.setAccessibilityRole(.group)
            contentView.accessibilityCustomActionsStorage = []
            panel?.initialFirstResponder = pauseButton
        }
        contentView.setAccessibilityHelp(
            "Drag to move. Option-click or right-click to discard the recording."
        )
    }

    private func pillCustomActions() -> [NSAccessibilityCustomAction] {
        var actions: [NSAccessibilityCustomAction] = []
        if state == .recording || state == .paused {
            actions.append(NSAccessibilityCustomAction(name: "Open panel", target: self, selector: #selector(panelButtonPressed)))
        }
        let pauseName = state == .paused ? "Resume" : "Pause"
        actions.append(NSAccessibilityCustomAction(name: pauseName, target: self, selector: #selector(pauseButtonPressed)))
        actions.append(NSAccessibilityCustomAction(name: "Stop", target: self, selector: #selector(stopButtonPressed)))
        return actions
    }

    private func announce(_ message: String) {
        announcementsForTesting.append(message)
        if announcementsForTesting.count > 32 { announcementsForTesting.removeFirst() }
        accessibilitySink(message)
    }

    // MARK: Cadence

    private func startAnimationTimer() {
        stopAnimationTimer()
        guard state == .recording else { return }
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(animationTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
        smoothedLevel = 0
        waveformView?.reset()
    }

    @objc private func animationTimerFired(_ timer: Timer) {
        updateElapsedLabelIfNeeded()
        updateWaveLevel()
    }

    private func updateElapsedLabelIfNeeded() {
        let text = Self.formattedElapsed(elapsedClock.elapsed(at: now()))
        guard text != lastElapsedText else { return }
        lastElapsedText = text
        elapsedLabel?.stringValue = text
        // The hour steps the width once, in every size, keeping the held edge.
        if appliedContent != currentContent {
            updateFrameForCurrentLayout(animated: true)
        }
        updateAccessibility()
    }

    private func updateWaveLevel() {
        guard let waveformView, !waveformView.isHidden else { return }
        switch state {
        case .recording:
            let target = DictationMiniRendering.recordingLevel(decibels: CGFloat(powerProvider?() ?? -160))
            smoothedLevel = 0.48 * target + 0.52 * smoothedLevel
            waveformView.advance(level: smoothedLevel)
        case .paused, .finalizing, .hidden:
            waveformView.reset()
        }
    }

    private static func formattedElapsed(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }

    // MARK: Actions

    @objc private func panelButtonPressed() {
        guard state == .recording || state == .paused else { return }
        if layout == .panel {
            minimizePanel(userInitiated: true)
        } else {
            openPanel(userInitiated: true, animated: true)
        }
    }

    @objc private func pauseButtonPressed() {
        guard state == .recording || state == .paused else { return }
        onTogglePause?()
    }

    @objc private func stopButtonPressed() {
        guard state == .recording || state == .paused else { return }
        onStop?()
    }
}
