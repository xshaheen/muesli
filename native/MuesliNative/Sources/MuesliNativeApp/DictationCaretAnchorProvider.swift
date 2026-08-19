import AppKit
import ApplicationServices
import os

/// Resolves the insertion caret of the currently focused editable accessibility element.
/// Accessibility uses Quartz's top-left coordinate space, so the result is converted
/// into AppKit's global bottom-left coordinate space before placement.
///
/// Every `AXUIElement*` call here is a synchronous IPC round trip to the focused app and is
/// thread-safe, so the resolution entry points are nonisolated and may run off the main actor;
/// only the callers that read `NSScreen` stay on it.
enum DictationCaretAnchorProvider {
    /// A focused editable text element and its resolved caret anchor.
    /// `AXUIElement` is an immutable CF handle, so the value is safe to hand across threads.
    struct EditableFocus: @unchecked Sendable {
        let anchor: CGPoint
        let element: AXUIElement
        let processIdentifier: pid_t
        /// True when the caret is a non-empty selection (dictating would replace it).
        let hasSelection: Bool

        func isSameElement(as other: EditableFocus?) -> Bool {
            guard let other else { return false }
            return CFEqual(element, other.element)
        }
    }

    /// Outcome of one resolution attempt: the focus (if any) and whether the wall-clock budget
    /// ran out first, so a caller can back off a slow accessibility server.
    struct Resolution: @unchecked Sendable {
        let focus: EditableFocus?
        let exhaustedBudget: Bool

        static let none = Resolution(focus: nil, exhaustedBudget: false)
        static let timedOut = Resolution(focus: nil, exhaustedBudget: true)
    }

    /// End-to-end wall-clock budget for one resolution. Each AX call carries its own 50–80 ms
    /// messaging timeout, so without this a slow target could chain 20+ individually timed-out
    /// round trips into one multi-second sample.
    static let resolutionBudget: TimeInterval = 0.07

    /// Monotonic deadline for one resolution.
    struct Deadline {
        let uptime: TimeInterval

        init(budget: TimeInterval = DictationCaretAnchorProvider.resolutionBudget) {
            uptime = ProcessInfo.processInfo.systemUptime + budget
        }

        var isPast: Bool { ProcessInfo.processInfo.systemUptime >= uptime }
    }

    /// Roles that denote a user-editable text control. Web areas, groups, static text and
    /// code viewers also expose selection ranges, so a range alone is not enough.
    static let editableTextRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    /// Resolves the focused element only when it is an editable text control: an allow-listed
    /// role, a settable value, a selected text range, and no read-only DOM marker. The anchor is
    /// the caret rect whenever the app exposes it; an empty field has no caret bounds yet, so it
    /// falls back to the first line of the element (top-leading), which is where its caret sits.
    ///
    /// `primaryMaxY` is the primary screen's top edge in AppKit coordinates (`NSScreen.screens
    /// .first?.frame.maxY`), read by the caller on the main actor so this can run anywhere.
    /// The whole chain shares one `resolutionBudget`; once it is past the result is a miss
    /// flagged `exhaustedBudget` rather than a partially resolved (possibly wrong) anchor.
    static func resolveEditableFocus(
        primaryMaxY: CGFloat?,
        budget: TimeInterval = resolutionBudget
    ) -> Resolution {
        let deadline = Deadline(budget: budget)
        guard AXIsProcessTrusted(),
              let primaryMaxY,
              let focused = focusedElement()
        else { return .none }
        guard !deadline.isPast else { return .timedOut }
        AXUIElementSetMessagingTimeout(focused, 0.08)
        // The selected range is fetched once per element and threaded through the editable
        // check, the caret rect and the selection flag instead of three separate round trips.
        let focusedRange = copiedRange(focused, attribute: kAXSelectedTextRangeAttribute)
        let element: AXUIElement
        let selectedRange: CFRange?
        if isEditableTextElement(focused, selectedRange: focusedRange) {
            element = focused
            selectedRange = focusedRange
        } else {
            // Some hosts focus a container (web area, scroll area, group) while the caret lives
            // in a text input inside it; drill a couple of levels before giving up.
            guard !deadline.isPast else { return .timedOut }
            guard let drilled = drillToTextInput(from: focused, deadline: deadline) else {
                return deadline.isPast ? .timedOut : .none
            }
            element = drilled.element
            selectedRange = drilled.selectedRange
        }
        guard !deadline.isPast else { return .timedOut }
        let anchor: CGPoint
        if let accessibilityRect = caretRect(for: element, selectedRange: selectedRange, deadline: deadline) {
            anchor = appKitAnchor(fromAccessibilityRect: accessibilityRect, primaryMaxY: primaryMaxY)
        } else if !deadline.isPast,
                  copiedInt(element, attribute: kAXNumberOfCharactersAttribute) == 0,
                  let accessibilityRect = elementRect(element) {
            let converted = appKitRect(fromAccessibilityRect: accessibilityRect, primaryMaxY: primaryMaxY)
            anchor = firstLineAnchor(inAppKitRect: converted)
        } else {
            return deadline.isPast ? .timedOut : .none
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return Resolution(
            focus: EditableFocus(
                anchor: anchor,
                element: element,
                processIdentifier: pid,
                hasSelection: (selectedRange?.length ?? 0) > 0
            ),
            exhaustedBudget: false
        )
    }

    static let drillDepthLimit = 2
    static let drillNodeLimit = 16

    /// Breadth-first search for the first editable text input below `root`, bounded by node
    /// count and by the shared wall-clock deadline so a huge or slow web page never stalls a
    /// sample. Returns the input together with the selected range already fetched for it.
    static func drillToTextInput(
        from root: AXUIElement,
        deadline: Deadline
    ) -> (element: AXUIElement, selectedRange: CFRange?)? {
        var frontier: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !frontier.isEmpty, visited < drillNodeLimit, !deadline.isPast {
            let (node, depth) = frontier.removeFirst()
            visited += 1
            guard depth < drillDepthLimit else { continue }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &value) == .success,
                  let children = value as? [AXUIElement]
            else { continue }
            for child in children.prefix(drillNodeLimit) {
                guard !deadline.isPast else { return nil }
                AXUIElementSetMessagingTimeout(child, 0.05)
                // Only a child that reports itself focused can own the caret; otherwise a page's
                // stray search box would steal the anchor.
                if copiedBool(child, attribute: kAXFocusedAttribute) == true {
                    let childRange = copiedRange(child, attribute: kAXSelectedTextRangeAttribute)
                    if isEditableTextElement(child, selectedRange: childRange) {
                        return (child, childRange)
                    }
                }
                frontier.append((child, depth + 1))
            }
        }
        return nil
    }

    private static func copiedBool(_ element: AXUIElement, attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    @MainActor
    static func currentAnchor() -> CGPoint? {
        guard AXIsProcessTrusted(),
              let primaryMaxY = NSScreen.screens.first?.frame.maxY,
              let element = focusedElement()
        else { return nil }

        AXUIElementSetMessagingTimeout(element, 0.08)
        let selectedRange = copiedRange(element, attribute: kAXSelectedTextRangeAttribute)
        if let accessibilityRect = caretRect(for: element, selectedRange: selectedRange, deadline: Deadline()) {
            return appKitAnchor(fromAccessibilityRect: accessibilityRect, primaryMaxY: primaryMaxY)
        }
        guard copiedInt(element, attribute: kAXNumberOfCharactersAttribute) == 0,
              let accessibilityRect = elementRect(element)
        else { return nil }
        let converted = appKitRect(fromAccessibilityRect: accessibilityRect, primaryMaxY: primaryMaxY)
        return firstLineAnchor(inAppKitRect: converted)
    }

    static func appKitRect(fromAccessibilityRect rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// The caret anchor is the caret's bottom-centre point: the Mini hangs directly under it.
    static func appKitAnchor(fromAccessibilityRect rect: CGRect, primaryMaxY: CGFloat) -> CGPoint {
        let converted = appKitRect(fromAccessibilityRect: rect, primaryMaxY: primaryMaxY)
        return CGPoint(x: converted.midX, y: converted.minY)
    }

    /// Anchor for a field whose caret bounds are unavailable but which is known to be empty: the
    /// caret sits at the start of the first line. Non-empty fields without caret bounds get no
    /// anchor at all — a wrong position is worse than none, and the pointer is never used.
    static func firstLineAnchor(inAppKitRect converted: CGRect) -> CGPoint {
        CGPoint(
            x: converted.minX + min(8, converted.width / 2),
            y: converted.maxY - min(18, converted.height)
        )
    }

    /// `selectedRange` is the element's already-fetched `kAXSelectedTextRangeAttribute`; a
    /// control without one is not a caret host.
    static func isEditableTextElement(_ element: AXUIElement, selectedRange: CFRange?) -> Bool {
        guard selectedRange != nil else { return false }
        guard let role = copiedString(element, attribute: kAXRoleAttribute) else { return false }
        // Web engines expose rich-text editors (contenteditable) as groups/web areas with an
        // editable ancestor rather than a text-field role.
        var editableAncestor: CFTypeRef?
        let hasEditableAncestor = AXUIElementCopyAttributeValue(
            element,
            "AXEditableAncestor" as CFString,
            &editableAncestor
        ) == .success && editableAncestor != nil
        guard editableTextRoles.contains(role) || hasEditableAncestor else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue
        else { return false }
        // Web engines ignore aria-readonly when reporting settability; read-only text areas used
        // as selection overlays (e.g. code viewers) usually say so in their DOM id or classes.
        let domMarkers: [String] = [copiedString(element, attribute: "AXDOMIdentifier")].compactMap { $0 }
            + (copiedStringArray(element, attribute: "AXDOMClassList") ?? [])
        return !domMarkers.contains { marker in
            marker.localizedCaseInsensitiveContains("read-only")
                || marker.localizedCaseInsensitiveContains("readonly")
        }
    }

    private static func copiedStringArray(_ element: AXUIElement, attribute: String) -> [String]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [String]
    }

    private static func copiedString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.08)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success {
            enableManualAccessibility(for: pid)
        }
        return element
    }

    /// Lock-protected because resolution runs on background tasks as well as the main actor.
    private static let manualAccessibilityProcesses = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    /// Chromium-based apps (Chrome, Electron: VS Code, Slack, Teams, Discord…) only build a full
    /// accessibility tree when a client asks for it; without `AXManualAccessibility` they expose
    /// no caret bounds and every anchor degrades to the field frame. Setting it is a no-op for
    /// every other app (attribute unsupported), so it is applied once per process.
    static func enableManualAccessibility(for pid: pid_t) {
        guard pid > 0 else { return }
        let isFirstRequest = manualAccessibilityProcesses.withLock { $0.insert(pid).inserted }
        guard isFirstRequest else { return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.08)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// `selectedRange` is the element's already-fetched `kAXSelectedTextRangeAttribute`.
    private static func caretRect(
        for element: AXUIElement,
        selectedRange: CFRange?,
        deadline: Deadline
    ) -> CGRect? {
        guard let selectedRange, selectedRange.location >= 0 else { return nil }

        let caretLocation = selectedRange.location + selectedRange.length
        guard let candidate = caretRectCandidate(for: element, caretLocation: caretLocation, deadline: deadline)
        else { return nil }
        // Out of budget: a candidate that skipped line alignment may sit on the wrong visual
        // line, and a wrong position is worse than none.
        guard !deadline.isPast else { return nil }
        return alignedToInsertionLine(candidate, element: element)
    }

    /// Tiers: exact insertion rect → text marker (WebKit/Chromium) → next character → previous character.
    /// Each tier is one more round trip, so the deadline is checked before every fallback.
    private static func caretRectCandidate(
        for element: AXUIElement,
        caretLocation: Int,
        deadline: Deadline
    ) -> CGRect? {
        if let exact = bounds(element, range: CFRange(location: caretLocation, length: 0)),
           exact.height > 0 {
            return CGRect(x: exact.minX, y: exact.minY, width: 0, height: exact.height)
        }
        guard !deadline.isPast else { return nil }
        if let marker = textMarkerCaretRect(for: element) {
            return marker
        }
        guard !deadline.isPast else { return nil }
        let characterCount = copiedInt(element, attribute: kAXNumberOfCharactersAttribute)
        if characterCount.map({ caretLocation < $0 }) != false,
           let next = bounds(element, range: CFRange(location: caretLocation, length: 1)),
           next.height > 0 {
            return CGRect(x: next.minX, y: next.minY, width: 0, height: next.height)
        }
        guard !deadline.isPast else { return nil }
        if caretLocation > 0,
           let previous = bounds(element, range: CFRange(location: caretLocation - 1, length: 1)),
           previous.height > 0 {
            return CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        }
        return nil
    }

    /// At a soft line break (and in bidi runs) text views report the insertion rect on the
    /// previous visual line. The insertion-point line number is authoritative, so when the
    /// candidate's vertical centre falls outside that line's bounds, adopt the line's vertical
    /// extent and keep the candidate's horizontal position.
    private static func alignedToInsertionLine(_ candidate: CGRect, element: AXUIElement) -> CGRect {
        guard let line = copiedInt(element, attribute: kAXInsertionPointLineNumberAttribute),
              line >= 0,
              let lineRange = rangeForLine(element, line: line),
              let lineBounds = bounds(element, range: lineRange),
              lineBounds.height > 0
        else { return candidate }
        let centre = candidate.midY
        guard centre < lineBounds.minY || centre > lineBounds.maxY else { return candidate }
        return CGRect(x: candidate.minX, y: lineBounds.minY, width: 0, height: lineBounds.height)
    }

    private static func rangeForLine(_ element: AXUIElement, line: Int) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXRangeForLineParameterizedAttribute as CFString,
            line as CFNumber,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range), range.length > 0 else { return nil }
        return range
    }

    /// WebKit (Safari, Mail, Notes web content) answers caret geometry through text markers when
    /// range-based bounds come back empty: the selected marker range collapses to the caret.
    private static func textMarkerCaretRect(for element: AXUIElement) -> CGRect? {
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextMarkerRange" as CFString,
            &markerRange
        ) == .success, let markerRange else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXBoundsForTextMarkerRange" as CFString,
            markerRange,
            &boundsValue
        ) == .success,
        let boundsValue,
        CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(boundsValue, to: AXValue.self), .cgRect, &rect),
              rect.height > 0
        else { return nil }
        return CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
    }

    private static func bounds(_ element: AXUIElement, range: CFRange) -> CGRect? {
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgRect, &rect) else { return nil }
        return rect
    }

    private static func elementRect(_ element: AXUIElement) -> CGRect? {
        guard let position = copiedPoint(element, attribute: kAXPositionAttribute),
              let size = copiedSize(element, attribute: kAXSizeAttribute),
              size.width > 0,
              size.height > 0
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func copiedRange(_ element: AXUIElement, attribute: String) -> CFRange? {
        guard let value = copiedValue(element, attribute: attribute) else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    private static func copiedPoint(_ element: AXUIElement, attribute: String) -> CGPoint? {
        guard let value = copiedValue(element, attribute: attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func copiedSize(_ element: AXUIElement, attribute: String) -> CGSize? {
        guard let value = copiedValue(element, attribute: attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func copiedInt(_ element: AXUIElement, attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Int
    }

    private static func copiedValue(_ element: AXUIElement, attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }
}
