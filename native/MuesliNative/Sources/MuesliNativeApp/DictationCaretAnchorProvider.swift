import AppKit
import ApplicationServices

/// Resolves the insertion caret of the currently focused editable accessibility element.
/// Accessibility uses Quartz's top-left coordinate space, so the result is converted
/// into AppKit's global bottom-left coordinate space before placement.
@MainActor
enum DictationCaretAnchorProvider {
    /// A focused editable text element and its resolved caret anchor.
    struct EditableFocus {
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
    static func currentEditableFocus() -> EditableFocus? {
        guard AXIsProcessTrusted(),
              let primaryMaxY = NSScreen.screens.first?.frame.maxY,
              let focused = focusedElement()
        else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.08)
        // Some hosts focus a container (web area, scroll area, group) while the caret lives in
        // a text input inside it; drill a couple of levels before giving up.
        guard let element = isEditableTextElement(focused) ? focused : drillToTextInput(from: focused) else {
            return nil
        }
        let anchor: CGPoint
        if let accessibilityRect = caretRect(for: element) {
            anchor = appKitAnchor(fromAccessibilityRect: accessibilityRect, primaryMaxY: primaryMaxY)
        } else if let accessibilityRect = elementRect(element) {
            let converted = appKitRect(fromAccessibilityRect: accessibilityRect, primaryMaxY: primaryMaxY)
            anchor = CGPoint(
                x: converted.minX + min(8, converted.width / 2),
                y: converted.maxY - min(10, converted.height / 2)
            )
        } else {
            return nil
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let selection = copiedRange(element, attribute: kAXSelectedTextRangeAttribute)
        return EditableFocus(
            anchor: anchor,
            element: element,
            processIdentifier: pid,
            hasSelection: (selection?.length ?? 0) > 0
        )
    }

    /// The focused window of `pid`, converted to AppKit coordinates.
    static func focusedWindowFrame(for pid: pid_t) -> CGRect? {
        guard let primaryMaxY = NSScreen.screens.first?.frame.maxY else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        guard let rect = elementRect(window) else { return nil }
        return appKitRect(fromAccessibilityRect: rect, primaryMaxY: primaryMaxY)
    }

    static let drillDepthLimit = 2
    static let drillNodeLimit = 16

    /// Breadth-first search for the first editable text input below `root`, bounded so a
    /// huge web page never stalls the main thread.
    static func drillToTextInput(from root: AXUIElement) -> AXUIElement? {
        var frontier: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !frontier.isEmpty, visited < drillNodeLimit {
            let (node, depth) = frontier.removeFirst()
            visited += 1
            guard depth < drillDepthLimit else { continue }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &value) == .success,
                  let children = value as? [AXUIElement]
            else { continue }
            for child in children.prefix(drillNodeLimit) {
                AXUIElementSetMessagingTimeout(child, 0.05)
                // Only a child that reports itself focused can own the caret; otherwise a page's
                // stray search box would steal the anchor.
                if copiedBool(child, attribute: kAXFocusedAttribute) == true, isEditableTextElement(child) {
                    return child
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

    static func currentAnchor() -> CGPoint? {
        guard AXIsProcessTrusted(),
              let primaryMaxY = NSScreen.screens.first?.frame.maxY,
              let element = focusedElement()
        else { return nil }

        AXUIElementSetMessagingTimeout(element, 0.08)
        if let accessibilityRect = caretRect(for: element) {
            return appKitAnchor(fromAccessibilityRect: accessibilityRect, primaryMaxY: primaryMaxY)
        }
        guard let accessibilityRect = elementRect(element) else { return nil }
        let converted = appKitRect(fromAccessibilityRect: accessibilityRect, primaryMaxY: primaryMaxY)
        return CGPoint(
            x: converted.minX + min(12, converted.width / 2),
            y: converted.midY
        )
    }

    static func appKitRect(fromAccessibilityRect rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func appKitAnchor(fromAccessibilityRect rect: CGRect, primaryMaxY: CGFloat) -> CGPoint {
        let converted = appKitRect(fromAccessibilityRect: rect, primaryMaxY: primaryMaxY)
        return CGPoint(x: converted.minX, y: converted.midY)
    }

    static func isEditableTextElement(_ element: AXUIElement) -> Bool {
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
        guard copiedRange(element, attribute: kAXSelectedTextRangeAttribute) != nil else { return false }
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

    private static var manualAccessibilityProcesses = Set<pid_t>()

    /// Chromium-based apps (Chrome, Electron: VS Code, Slack, Teams, Discord…) only build a full
    /// accessibility tree when a client asks for it; without `AXManualAccessibility` they expose
    /// no caret bounds and every anchor degrades to the field frame. Setting it is a no-op for
    /// every other app (attribute unsupported), so it is applied once per process.
    static func enableManualAccessibility(for pid: pid_t) {
        guard pid > 0, !manualAccessibilityProcesses.contains(pid) else { return }
        manualAccessibilityProcesses.insert(pid)
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.08)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func caretRect(for element: AXUIElement) -> CGRect? {
        guard let selectedRange = copiedRange(element, attribute: kAXSelectedTextRangeAttribute),
              selectedRange.location >= 0
        else { return nil }

        let caretLocation = selectedRange.location + selectedRange.length
        if let exact = bounds(element, range: CFRange(location: caretLocation, length: 0)),
           exact.height > 0 {
            return CGRect(x: exact.minX, y: exact.minY, width: 0, height: exact.height)
        }

        let characterCount = copiedInt(element, attribute: kAXNumberOfCharactersAttribute)
        if characterCount.map({ caretLocation < $0 }) != false,
           let next = bounds(element, range: CFRange(location: caretLocation, length: 1)),
           next.height > 0 {
            return CGRect(x: next.minX, y: next.minY, width: 0, height: next.height)
        }
        if caretLocation > 0,
           let previous = bounds(element, range: CFRange(location: caretLocation - 1, length: 1)),
           previous.height > 0 {
            return CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        }
        if let marker = textMarkerCaretRect(for: element) {
            return marker
        }
        return nil
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
