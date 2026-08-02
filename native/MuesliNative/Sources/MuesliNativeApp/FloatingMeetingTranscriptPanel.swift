import AppKit
import Observation
import SwiftUI
import os

enum FloatingMeetingTranscriptPlacement {
    static let panelSize = NSSize(width: 360, height: 320)
    /// Keeps the panel off the pill rather than flush against it.
    ///
    /// Non-zero is safe for the hover bridge: leaving the pill schedules a delayed exit
    /// that re-tests the pointer against both frames when it fires, and entering the panel
    /// cancels it, so a pointer crossing 8pt reads as neither having left.
    static let gap: CGFloat = 8
    static let screenInset: CGFloat = 8

    enum Side {
        case left
        case right
    }

    struct Placement: Equatable {
        let frame: NSRect
        let side: Side
    }

    /// Places the panel beside the pill, keeping the side it was last placed on.
    ///
    /// Side selection is a width threshold, and the panel is 360pt wide: without memory a
    /// pill nudged a few points across that threshold throws the panel more than its own
    /// width across the screen. `preferredSide` is only overruled once it stops fitting.
    static func placement(
        beside indicatorFrame: NSRect,
        panelSize: NSSize = panelSize,
        visibleFrame: NSRect,
        preferredSide: Side? = nil
    ) -> Placement {
        let availableOnLeft = indicatorFrame.minX - visibleFrame.minX
        let availableOnRight = visibleFrame.maxX - indicatorFrame.maxX
        // Fitting means fitting *unclamped*: the panel wants its gap from the pill and its
        // inset from the screen edge, so a side that cannot give both is not a fit.
        let required = panelSize.width + gap + screenInset
        let side = resolvedSide(
            preferred: preferredSide,
            fitsLeft: availableOnLeft >= required,
            fitsRight: availableOnRight >= required,
            availableOnLeft: availableOnLeft,
            availableOnRight: availableOnRight
        )
        let proposedX = side == .left
            ? indicatorFrame.minX - gap - panelSize.width
            : indicatorFrame.maxX + gap
        let minX = visibleFrame.minX + screenInset
        let maxX = max(minX, visibleFrame.maxX - screenInset - panelSize.width)
        let minY = visibleFrame.minY + screenInset
        let maxY = max(minY, visibleFrame.maxY - screenInset - panelSize.height)
        var frame = NSRect(
            x: min(max(proposedX, minX), maxX),
            y: min(max(indicatorFrame.midY - panelSize.height / 2, minY), maxY),
            width: panelSize.width,
            height: panelSize.height
        )
        if frame.intersects(indicatorFrame) {
            // No side of the screen can hold the panel, so the horizontal clamp has slid it
            // over the pill -- the only control the user has during a call. Step above or
            // below instead, whichever direction has the room.
            let below = indicatorFrame.minY - gap - panelSize.height
            let above = indicatorFrame.maxY + gap
            if below >= minY {
                frame.origin.y = below
            } else if above <= maxY {
                frame.origin.y = above
            } else {
                let roomBelow = indicatorFrame.minY - minY
                let roomAbove = visibleFrame.maxY - screenInset - indicatorFrame.maxY
                frame.origin.y = roomBelow >= roomAbove ? minY : maxY
            }
        }
        return Placement(frame: frame, side: side)
    }

    /// Placement with no memory, for callers with no side to thread through.
    static func frame(
        beside indicatorFrame: NSRect,
        panelSize: NSSize = panelSize,
        visibleFrame: NSRect
    ) -> NSRect {
        placement(
            beside: indicatorFrame,
            panelSize: panelSize,
            visibleFrame: visibleFrame
        ).frame
    }

    private static func resolvedSide(
        preferred: Side?,
        fitsLeft: Bool,
        fitsRight: Bool,
        availableOnLeft: CGFloat,
        availableOnRight: CGFloat
    ) -> Side {
        if let preferred {
            let stillFits = preferred == .left ? fitsLeft : fitsRight
            if stillFits { return preferred }
        }
        if fitsLeft { return .left }
        if fitsRight { return .right }
        // Neither side fits. Hold the side already in use rather than swapping between two
        // equally bad options every time the pill moves a few points.
        return preferred ?? (availableOnLeft >= availableOnRight ? .left : .right)
    }
}

struct FloatingMeetingChatContext {
    let meetingID: Int64
    /// Transcript captured before the current recording session began. Empty for a fresh
    /// meeting; non-empty after a resume, where `liveMeetingTranscript` holds only the new
    /// portion.
    let priorTranscript: String
    /// Resolved when the panel sends, not captured, so changing backend or credentials
    /// mid-meeting takes effect here as it does in the detail view.
    let currentConfig: () -> AppConfig
    /// Whether the selected backend is actually usable. The detail view hides its Chat tab
    /// when this is false; the panel must agree, or it offers a control that always fails.
    let isReady: () -> Bool
    /// Resolved per send, like the config, because the user types notes during the
    /// meeting and the panel must see what they have written by the time they ask.
    var manualNotes: () -> String = { "" }
}

@MainActor
@Observable
final class FloatingMeetingTranscriptModel {
    let presentation = LiveTranscriptPresentationModel()
    var isPaused = false
    var isPresented = false
    var didCopy = false

    /// Chat is closed until the user deliberately opens it. This flag gates keyboard focus:
    /// while it is false the panel must never become key, or it would swallow keystrokes
    /// meant for the meeting app the user is actually talking in.
    var isChatOpen = false
    var chatContext: FloatingMeetingChatContext?

    var isChatAvailable: Bool { chatContext?.isReady() == true }

    /// The transcript chat reasons over: what was recorded before this session plus what has
    /// been captured since. Mirrors the detail view's Live tab; using the live portion alone
    /// would drop a resumed meeting's earlier half.
    var chatTranscript: String {
        MeetingChatSource.liveTranscript(
            prior: chatContext?.priorTranscript ?? "",
            live: presentation.transcript
        )
    }

    func openChat() {
        guard isChatAvailable else { return }
        isChatOpen = true
    }

    func closeChat() {
        isChatOpen = false
    }

    func toggleChat() {
        isChatOpen ? closeChat() : openChat()
    }

    func update(transcript: String, partialYou: String, partialOthers: String) {
        presentation.update(
            transcript: transcript,
            partialYou: partialYou,
            partialOthers: partialOthers
        )
    }

    /// Copies whatever the panel is currently showing.
    ///
    /// The header button is the only copy affordance the panel has, so with chat
    /// open it must copy the conversation. Copying the transcript instead gives the
    /// user something they were not looking at, silently.
    func copyToPasteboard() {
        let text: String
        if isChatOpen, let context = chatContext {
            text = MeetingChatConversations.shared
                .conversation(for: context.meetingID)
                .transcriptForCopying()
        } else {
            text = LiveTranscriptCopyContent.text(
                transcript: presentation.transcript,
                partialYou: presentation.partialYou,
                partialOthers: presentation.partialOthers
            )
        }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopyConfirmation()
    }

    func reset() {
        presentation.reset()
        isPaused = false
        isPresented = false
        didCopy = false
        isChatOpen = false
        chatContext = nil
    }

    func showCopyConfirmation() {
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.didCopy = false
        }
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class FloatingMeetingTranscriptPanelController {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "transcript-panel")
    private let model = FloatingMeetingTranscriptModel()
    private let onHoverChanged: (Bool) -> Void
    private let onOpenNotes: () -> Void
    private let onDismiss: () -> Void
    private var hostingView: FirstMouseHostingView<FloatingMeetingTranscriptPanelView>?
    /// The user-positioned origin persisted in config; nil until the user first drags
    /// the panel. The panel is user-positioned, not pill-attached: once moved, every
    /// show reuses this origin and the pill's position stops mattering.
    var savedOriginProvider: (() -> CGPoint?)?
    var onUserMovedPanel: ((CGPoint) -> Void)?
    private var isProgrammaticMove = false
    private var userMoveSaveWorkItem: DispatchWorkItem?
    private var windowMoveObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    /// The transcript's own window.
    ///
    /// It used to be a subview of the indicator's window, whose frame then had to be
    /// the union of both. Every indicator resize had to recompute that union, drag had
    /// to undo it, and edge-clamping fed back into the indicator's position -- a whole
    /// class of bug that simply does not exist once the two are separate windows.
    private var window: NSPanel?
    /// The side of the pill the panel last landed on.
    ///
    /// Held across hide/show so the panel stays put while the pill moves and resizes
    /// within a meeting; cleared on reset, where a new session should place it fresh.
    private(set) var placementSide: FloatingMeetingTranscriptPlacement.Side?

    init(
        onHoverChanged: @escaping (Bool) -> Void,
        onOpenNotes: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onHoverChanged = onHoverChanged
        self.onOpenNotes = onOpenNotes
        self.onDismiss = onDismiss
    }

    /// Supplies what chat needs. Called when a meeting starts rather than on every transcript
    /// chunk: the prior transcript does not change during a session.
    func setChatContext(_ context: FloatingMeetingChatContext?) {
        model.chatContext = context
        if context == nil { model.closeChat() }
    }

    /// True only while the user has the composer open. The window must not become key at any
    /// other time — a floating panel that takes focus during a call swallows the keystrokes
    /// the user is typing into Zoom or Teams.
    var wantsKeyboardFocus: Bool { model.isChatOpen }

    func closeChat() {
        setChatOpen(false)
    }

    var isVisible: Bool {
        window?.isVisible == true && hostingView?.isHidden == false
    }

    /// Whether the panel is holding an open chat, and so must not be auto-dismissed.
    var isChatOpen: Bool { model.isChatOpen }

    func update(transcript: String, partialYou: String, partialOthers: String) {
        model.update(
            transcript: transcript,
            partialYou: partialYou,
            partialOthers: partialOthers
        )
    }

    func setPaused(_ paused: Bool) {
        model.isPaused = paused
    }

    /// Shows the transcript beside the pill, on the side it is already using when that
    /// side still fits. Preferred over `show(at:)`, which cannot remember anything.
    /// Places the panel beside the pill and remembers the chosen side.
    ///
    /// The panel is an independent window: the pill's controller re-invokes this from
    /// its window's didMove/didResize notifications, so the panel follows the live
    /// pill through moves, animations, and system-originated relocations — and every
    /// step re-runs the clamped placement math, which a fixed child-window offset
    /// cannot express (a bottom-edge pill pins the panel to the screen, not to itself).
    func show(beside indicatorFrame: NSRect, in visibleFrame: NSRect) {
        if let saved = savedFrameOnAnAttachedScreen() {
            Self.logger.notice("place saved=\(NSStringFromRect(saved), privacy: .public)")
            show(at: saved)
            return
        }
        // First-ever show: beside the pill is a sensible starting point. From the
        // first drag onward the user owns the position.
        let placement = FloatingMeetingTranscriptPlacement.placement(
            beside: indicatorFrame,
            visibleFrame: visibleFrame,
            preferredSide: placementSide
        )
        placementSide = placement.side
        let placementDescription = "beside=\(NSStringFromRect(indicatorFrame)) visible=\(NSStringFromRect(visibleFrame)) -> \(NSStringFromRect(placement.frame)) side=\(placement.side)"
        Self.logger.notice("place \(placementDescription, privacy: .public)")
        show(at: placement.frame)
    }

    /// The saved origin as a full panel frame, clamped into the display that holds it;
    /// nil when the user has never moved the panel or that display is gone.
    private func savedFrameOnAnAttachedScreen() -> NSRect? {
        guard let origin = savedOriginProvider?() else { return nil }
        let size = FloatingMeetingTranscriptPlacement.panelSize
        let frame = NSRect(origin: origin, size: size)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let visible = NSScreen.screens.first(where: { $0.frame.contains(center) })?.visibleFrame
            ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.visibleFrame
        else { return nil }
        let inset = FloatingMeetingTranscriptPlacement.screenInset
        let x = min(max(frame.origin.x, visible.minX + inset), max(visible.minX + inset, visible.maxX - inset - size.width))
        let y = min(max(frame.origin.y, visible.minY + inset), max(visible.minY + inset, visible.maxY - inset - size.height))
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Shows the transcript at a screen frame of its own.
    func show(at screenFrame: NSRect) {
        let hostingView = hostingView ?? makeHostingView()
        self.hostingView = hostingView

        let window = window ?? makeWindow()
        self.window = window
        hostingView.frame = NSRect(origin: .zero, size: screenFrame.size)
        if window.contentView !== hostingView {
            window.contentView = hostingView
        }
        hostingView.isHidden = false
        isProgrammaticMove = true
        window.setFrame(screenFrame, display: true)
        isProgrammaticMove = false
        installMoveObserverIfNeeded(for: window)
        model.isPresented = true
        // orderFront, never makeKey: a floating panel that takes focus during a call
        // swallows the keystrokes meant for Zoom. Chat asks for key explicitly.
        window.orderFront(nil)
    }

    private func makeWindow() -> NSPanel {
        let window = InteractiveFloatingPanel(
            contentRect: NSRect(origin: .zero, size: FloatingMeetingTranscriptPlacement.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = false
        // Match the pill: without this the pill follows a Space switch or a
        // full-screen meeting while the panel stays behind on the old Space.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.becomesKeyOnlyIfNeeded = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return window
    }

    func hide() {
        // Release focus before the view goes away. Tearing down a key panel without
        // resigning leaves an invisible window holding the keyboard, so keystrokes meant
        // for the call vanish into a panel the user cannot even see.
        releaseChatFocus()
        model.isPresented = false
        hostingView?.isHidden = true
        window?.orderOut(nil)
    }

    func reset() {
        hide()
        model.reset()
        placementSide = nil
    }

    func close() {
        releaseChatFocus()
        userMoveSaveWorkItem?.cancel()
        if let windowMoveObserver { NotificationCenter.default.removeObserver(windowMoveObserver) }
        windowMoveObserver = nil
        model.isPresented = false
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        hostingView = nil
        placementSide = nil
    }

    /// Single place every teardown path goes through, so no route can skip the resign step.
    private func releaseChatFocus() {
        endOutsideClickDismissal()
        guard model.isChatOpen else { return }
        model.closeChat()
        if let window = hostingView?.window, window.isKeyWindow {
            // resignKey is only a notification hook -- neither it nor orderBack reassigns
            // NSApp.keyWindow, so the panel kept the keyboard after chat closed. Ordering
            // out and straight back in makes AppKit hand key status to another window
            // while the panel stays on screen.
            window.orderOut(nil)
            window.orderFront(nil)
        }
    }

    private func installMoveObserverIfNeeded(for window: NSWindow) {
        guard windowMoveObserver == nil else { return }
        windowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowDidMove() }
        }
    }

    private func windowDidMove() {
        guard !isProgrammaticMove, let window, window.isVisible else { return }
        // performDrag streams moves with no end event; debounce to one save per drop.
        userMoveSaveWorkItem?.cancel()
        let origin = window.frame.origin
        let workItem = DispatchWorkItem { [weak self] in
            self?.onUserMovedPanel?(origin)
        }
        userMoveSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    func containsMouseLocation() -> Bool {
        screenFrame?.contains(NSEvent.mouseLocation) == true
    }

    private var screenFrame: NSRect? {
        guard isVisible, let hostingView, let window = hostingView.window else { return nil }
        let frameInWindow = hostingView.convert(hostingView.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    /// Opening chat lets the panel take keys; closing it must hand them back.
    ///
    /// Without the resign step, the panel keeps key status after the composer closes and
    /// keeps swallowing keystrokes meant for the call — the precise failure the deliberate-
    /// focus rule exists to prevent, just delayed.
    func setChatOpen(_ open: Bool) {
        if open {
            model.openChat()
            // openChat declines when no usable backend is configured. Arming the monitor
            // anyway would leave a global event monitor running that nothing ever tears
            // down, since every teardown path is reached through the open chat.
            guard model.isChatOpen else { return }
            beginOutsideClickDismissal()
        } else {
            endOutsideClickDismissal()
            // Resign only the panel's own key status. Deactivating the whole app would also
            // hide a main window the user may have opened deliberately.
            releaseChatFocus()
        }
    }

    /// Closes chat when the user clicks somewhere else.
    ///
    /// Hover no longer dismisses an open chat, so this is what replaces it. Without
    /// it the panel would have no deliberate way out short of the header button, and
    /// would sit over the call until the meeting ended.
    private func beginOutsideClickDismissal() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.model.isChatOpen else { return }
            // A global monitor only sees clicks outside this app's windows, but the
            // panel can also be clicked while another app is frontmost, so check the
            // pointer against the panel's own frame before dismissing.
            guard !self.pointerIsInsidePanel() else { return }
            self.setChatOpen(false)
        }
    }

    private func endOutsideClickDismissal() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    private func pointerIsInsidePanel() -> Bool {
        guard let window = hostingView?.window else { return false }
        return window.frame.contains(NSEvent.mouseLocation)
    }

    private func copyTranscript() {
        model.copyToPasteboard()
    }

    private func makeHostingView() -> FirstMouseHostingView<FloatingMeetingTranscriptPanelView> {
        let hostingView = FirstMouseHostingView(
            rootView: FloatingMeetingTranscriptPanelView(
                model: model,
                onHoverChanged: onHoverChanged,
                onOpenNotes: onOpenNotes,
                onDismiss: onDismiss,
                // Through the controller, never straight to the model: opening chat has
                // to arm outside-click dismissal and closing it has to hand keyboard focus
                // back. Flipping the model's flag alone leaves a 360x320 panel parked over
                // the call with no way out but the header button.
                onToggleChat: { [weak self] in
                    guard let self else { return }
                    self.setChatOpen(!self.model.isChatOpen)
                }
            )
        )
        hostingView.wantsLayer = true
        return hostingView
    }
}

/// Lets the user drag the panel by its header: mouseDown hands the event to the
/// window's native drag loop. Sits behind the header's controls, so buttons win.
private struct PanelWindowDragHandle: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

private struct FloatingMeetingTranscriptPanelView: View {
    let model: FloatingMeetingTranscriptModel
    let onHoverChanged: (Bool) -> Void
    let onOpenNotes: () -> Void
    let onDismiss: () -> Void
    var onToggleChat: () -> Void = {}

    private var partialYou: String {
        model.presentation.partialYou.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var partialOthers: String {
        model.presentation.partialOthers.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var messages: [TranscriptChatMessage] {
        model.presentation.messages
    }

    private var copyText: String {
        LiveTranscriptCopyContent.text(
            transcript: model.presentation.transcript,
            partialYou: model.presentation.partialYou,
            partialOthers: model.presentation.partialOthers
        )
    }

    var body: some View {
        if model.isPresented {
            VStack(spacing: 0) {
                header
                    .background(PanelWindowDragHandle())
                Divider().background(MuesliTheme.surfaceBorder)
                if model.isChatOpen, let context = model.chatContext {
                    MeetingChatView(
                        conversation: MeetingChatConversations.shared.conversation(for: context.meetingID),
                        transcript: model.chatTranscript,
                        systemPrompt: MeetingChatSource.systemPrompt(isRecording: true),
                        manualNotes: context.manualNotes(),
                        config: context.currentConfig(),
                        isCompact: true
                    )
                } else {
                    transcript
                }
            }
            .frame(
                width: FloatingMeetingTranscriptPlacement.panelSize.width,
                height: FloatingMeetingTranscriptPlacement.panelSize.height
            )
            .background(.ultraThinMaterial)
            .background(MuesliTheme.backgroundRaised.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(MuesliTheme.surfaceBorder.opacity(0.8), lineWidth: 1)
            }
            .onHover(perform: onHoverChanged)
        }
    }

    private var header: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Text(model.isChatOpen ? "Ask about this meeting" : "Live transcript")
                .font(MuesliTheme.callout().weight(.semibold))
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            Circle()
                .fill(model.isPaused ? MuesliTheme.textTertiary : MuesliTheme.success)
                .frame(width: 6, height: 6)
            Text(model.isPaused ? "Paused" : "Live")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize()
            // Sits immediately left of dismiss, and to the right of the variable-width
            // status label, so its hit region is a fixed offset from the panel's right edge.
            // Placing it left of the status text would make the region depend on whether the
            // label reads "Live" or "Paused".
            if model.isChatAvailable {
                Button(action: onToggleChat) {
                    Image(systemName: model.isChatOpen ? "text.quote" : "bubble.left.and.text.bubble.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.isChatOpen ? MuesliTheme.accent : MuesliTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(model.isChatOpen
                                    ? MuesliTheme.accent.opacity(0.14)
                                    : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.isChatOpen ? "Back to transcript" : "Ask about this meeting")
            }
            Button(action: onDismiss) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide live transcript")
            Button(action: copyTranscript) {
                Image(systemName: model.didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.didCopy ? MuesliTheme.success : MuesliTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(copyText.isEmpty)
            .help("Copy transcript")
        }
        .padding(.horizontal, MuesliTheme.spacing16)
        .frame(height: 42)
    }

    private var transcript: some View {
        ScrollView {
            LiveTranscriptFeedView(
                messages: messages,
                partialYou: partialYou,
                partialOthers: partialOthers,
                horizontalPadding: MuesliTheme.spacing12,
                topPadding: MuesliTheme.spacing8,
                bottomPadding: MuesliTheme.spacing8,
                onOpen: onOpenNotes
            )
        }
        .defaultScrollAnchor(.bottom)
    }

    private func copyTranscript() {
        model.copyToPasteboard()
    }

}
