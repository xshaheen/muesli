import AppKit

/// Owns the merged panel body's model and its focus rules.
///
/// Lifted from the retired transcript-panel controller, which had a window of its own.
/// The body is now a subview of the meeting object's one panel, so every rule that used
/// to reach for `hostingView.window` goes through `panelWindowProvider` instead.
@MainActor
final class MeetingPanelBodyCoordinator {
    let model = FloatingMeetingTranscriptModel()

    /// The merged window the focus rules act on, supplied by the controller that owns it.
    var panelWindowProvider: () -> NSWindow? = { nil }

    /// Where the pointer is when a global click arrives. Injectable for the same reason
    /// `now` is on the panel controller: a unit test has no live pointer, and the branch
    /// that keeps a click *on* the object from dismissing it is only reachable through this.
    var pointerLocationProvider: () -> NSPoint = { NSEvent.mouseLocation }

    /// Installs the global click monitor. Injectable so a test can drive the branch where
    /// AppKit hands back nil, which a real monitor cannot be made to do on demand.
    var outsideClickMonitorInstaller: (@escaping (NSEvent) -> Void) -> Any? = { handler in
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler)
    }

    /// Paired with the installer: `NSEvent.removeMonitor` is undefined for a token it did
    /// not hand out, so a test that injects one has to take it back the same way.
    var outsideClickMonitorRemover: (Any) -> Void = { NSEvent.removeMonitor($0) }

    private var outsideClickMonitor: Any?
    /// Armed state kept separately from the monitor object: `addGlobalMonitorForEvents`
    /// can hand back nil, and the tear-down path must still run exactly once.
    private var isOutsideClickDismissalArmed = false
    /// An invisible offscreen panel that exists only to be made key and immediately
    /// ordered out — the mechanism `resignPanelKey` bounces keyboard focus through.
    private var keyReleaseWindow: NSPanel?

    /// True only while the user is on a tab they type into (chat or notes). The window
    /// must not become key at any other time — a floating object that takes focus during
    /// a call swallows the keystrokes the user is typing into Zoom or Teams.
    var wantsKeyboardFocus: Bool { model.selectedTab != .transcript }

    /// Whether the body is holding an open chat, and so must not be auto-dismissed.
    var isChatOpen: Bool { model.isChatOpen }

    var hasMeetingContextForTesting: Bool { model.isNotesAvailable }
    var isOutsideClickMonitorArmedForTesting: Bool { isOutsideClickDismissalArmed }

    // MARK: Content

    /// Supplies what chat and notes need. Called when a meeting starts rather than on
    /// every transcript chunk: the prior transcript does not change during a session.
    func setChatContext(_ context: FloatingMeetingChatContext?) {
        model.chatContext = context
        if context == nil {
            selectTab(.transcript)
        }
    }

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

    func setSelectionAccentHex(_ hex: Int) {
        model.setSelectionAccentHex(hex)
    }

    // MARK: Tabs and focus

    /// Selecting a typing tab lets the window take keys; leaving it must hand them back.
    ///
    /// Without the resign step, the window keeps key status after the composer closes and
    /// keeps swallowing keystrokes meant for the call — the precise failure the deliberate-
    /// focus rule exists to prevent, just delayed.
    func selectTab(_ tab: FloatingMeetingPanelTab) {
        switch tab {
        case .chat:
            model.openChat()
            // openChat declines when no usable backend is configured. Arming the monitor
            // anyway would leave a global event monitor running that nothing ever tears
            // down, since every teardown path is reached through the open tab.
            guard model.isChatOpen else { return }
            beginOutsideClickDismissal()
        case .notes:
            guard model.openNotes() else { return }
            beginOutsideClickDismissal()
        case .transcript:
            // The one path that both hands the keyboard back *and* leaves the transcript
            // selected: choosing the Transcript tab, or an outside click closing Chat.
            releaseFocus()
            model.selectedTab = .transcript
        }
    }

    /// Re-arms the outside-click rule for a typing tab that survived a minimize.
    ///
    /// The selected tab outlives the fold, so a reopen can land straight on Chat or My
    /// notes. Without this the panel comes back on a typing tab with nothing watching for
    /// the click that should hand the keyboard back. It does not take key — the window is
    /// only ordered front, and the user clicking into the field is what takes focus.
    func resumeFocusRules() {
        guard model.selectedTab != .transcript else { return }
        beginOutsideClickDismissal()
    }

    /// Hands the keyboard back and disarms the outside-click rule, *without* changing what
    /// the body is showing. Single place every fold and teardown path goes through, so no
    /// route can skip the resign step.
    ///
    /// The selected tab deliberately survives: minimizing is not the user leaving Chat or
    /// My notes, and a reopen must land back on the tab they were working in. Only an
    /// explicit `selectTab(.transcript)` — the Transcript tab, or an outside click closing
    /// Chat — changes the tab.
    func releaseFocus() {
        endOutsideClickDismissal()
        guard model.selectedTab != .transcript else { return }
        // resignKey is only a notification hook -- neither it nor orderBack reassigns
        // NSApp.keyWindow, so the window kept the keyboard after chat closed. Bouncing
        // key status through an invisible window makes AppKit hand it to another window
        // while the object stays on screen.
        resignPanelKey()
    }

    /// Clears the body back to a fresh session.
    func reset() {
        releaseFocus()
        model.reset()
    }

    /// Final teardown: the bounce window is the only extra window the body owns.
    func teardown() {
        releaseFocus()
        keyReleaseWindow?.close()
        keyReleaseWindow = nil
    }

    // MARK: Outside clicks

    /// Reacts to clicks somewhere else while a typing tab is open.
    ///
    /// Hover no longer dismisses an open chat, so this is what replaces it: chat closes
    /// outright (its old behavior), while notes stay visible but hand the keyboard back —
    /// the user is glancing at the call, not done taking notes.
    private func beginOutsideClickDismissal() {
        guard !isOutsideClickDismissalArmed else { return }
        let monitor = outsideClickMonitorInstaller { [weak self] _ in
            self?.handleOutsideClick()
        }
        // AppKit hands back nil when the monitor cannot be installed. Claiming armed anyway
        // would make every later `selectTab` skip the retry, and nothing would ever watch
        // for the click that closes Chat or hands the keyboard back from My notes.
        guard let monitor else { return }
        outsideClickMonitor = monitor
        isOutsideClickDismissalArmed = true
    }

    /// Chat closes outright on an outside click (its old behavior); My notes stays visible
    /// but hands the keyboard back — the user is glancing at the call, not done taking notes.
    private func handleOutsideClick() {
        guard model.selectedTab != .transcript else { return }
        // A global monitor only sees clicks outside this app's windows, but the
        // object can also be clicked while another app is frontmost, so check the
        // pointer against the window's own frame before dismissing.
        guard !pointerIsInsidePanel() else { return }
        if model.isChatOpen {
            selectTab(.transcript)
        } else {
            resignPanelKey()
        }
    }

    /// Drives the outside-click rule without a real global monitor, which needs a live GUI
    /// session a unit test does not have.
    func handleOutsideClickForTesting() {
        handleOutsideClick()
    }

    private func endOutsideClickDismissal() {
        if let outsideClickMonitor {
            outsideClickMonitorRemover(outsideClickMonitor)
        }
        outsideClickMonitor = nil
        isOutsideClickDismissalArmed = false
    }

    private func pointerIsInsidePanel() -> Bool {
        guard let window = panelWindowProvider() else { return false }
        return window.frame.contains(pointerLocationProvider())
    }

    /// Hands key status back without changing what the panel shows.
    ///
    /// Key status only moves when *some* window takes it — `resignKey` alone
    /// reassigns nothing. Ordering the visible window out and back did move it, but
    /// unmapped it for a frame, so every click that left a typing tab blinked the whole
    /// object. Bouncing through an invisible window moves key status the same way while
    /// the object never leaves the screen: making the bounce window key takes the
    /// keyboard off the panel, and ordering it out makes AppKit reassign key past the
    /// panel (skipped as `becomesKeyOnlyIfNeeded`), handing the keyboard back to the call.
    private func resignPanelKey() {
        guard let window = panelWindowProvider(), window.isKeyWindow else { return }
        let bounce: NSPanel
        if let keyReleaseWindow {
            bounce = keyReleaseWindow
        } else {
            bounce = InteractiveFloatingPanel(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            bounce.isOpaque = false
            bounce.backgroundColor = .clear
            bounce.hasShadow = false
            bounce.alphaValue = 0
            bounce.becomesKeyOnlyIfNeeded = true
            keyReleaseWindow = bounce
        }
        bounce.makeKeyAndOrderFront(nil)
        bounce.orderOut(nil)
    }
}
