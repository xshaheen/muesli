import AppKit
import ApplicationServices

/// Resolves the insertion caret of the currently focused editable accessibility element.
/// Accessibility uses Quartz's top-left coordinate space, so the result is converted
/// into AppKit's global bottom-left coordinate space before placement.
@MainActor
enum DictationCaretAnchorProvider {
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
        return unsafeBitCast(value, to: AXUIElement.self)
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
        return nil
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
