import AppKit
import ApplicationServices

/// A thin, typed wrapper around `AXUIElement`.
nonisolated struct AXElement: Equatable, @unchecked Sendable {
    let raw: AXUIElement

    static let systemWide: AXElement = {
        let element = AXElement(raw: AXUIElementCreateSystemWide())
        // Never let a hung app freeze Typhon's main thread for long.
        AXUIElementSetMessagingTimeout(element.raw, 0.25)
        return element
    }()

    static func application(_ pid: pid_t) -> AXElement {
        AXElement(raw: AXUIElementCreateApplication(pid))
    }

    static func == (lhs: AXElement, rhs: AXElement) -> Bool { CFEqual(lhs.raw, rhs.raw) }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(raw, &pid) == .success ? pid : nil
    }

    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func element(_ name: String) -> AXElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return AXElement(raw: value as! AXUIElement)
    }

    func string(_ name: String) -> String? { attribute(name) }
    func bool(_ name: String) -> Bool? { (attribute(name) as NSNumber?)?.boolValue }

    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }
    var value: String? { string(kAXValueAttribute) }

    var selectedRange: NSRange? {
        guard let value: AXValue = attribute(kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// The element's frame in AX coordinates (top-left origin, primary display).
    var frame: CGRect? {
        guard let position: AXValue = attribute(kAXPositionAttribute),
              let size: AXValue = attribute(kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(raw, name as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    func set(_ name: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(raw, name as CFString, value)
    }

    @discardableResult
    func setSelectedRange(_ range: NSRange) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return set(kAXSelectedTextRangeAttribute, value) == .success
    }

    /// Screen bounds (AX coordinates) of a text range, via `kAXBoundsForRangeParameterizedAttribute`.
    func bounds(for range: NSRange) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            raw, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(result as! AXValue, .cgRect, &rect) ? rect : nil
    }

    /// WebKit and Chromium answer text-marker queries even when range bounds fail.
    func selectedTextMarkerBounds() -> CGRect? {
        var marker: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, "AXSelectedTextMarkerRange" as CFString, &marker) == .success,
              let marker
        else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            raw, "AXBoundsForTextMarkerRange" as CFString, marker, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(result as! AXValue, .cgRect, &rect) ? rect : nil
    }
}

extension CGPoint {
    /// Converts an AX point (top-left origin of the primary display) to AppKit screen coordinates.
    var flippedPointToAppKit: CGPoint {
        CGPoint(x: x, y: (NSScreen.screens.first?.frame.height ?? 0) - y)
    }
}

extension CGRect {
    /// Converts an AX rect (top-left origin of the primary display) to AppKit screen coordinates.
    var flippedToAppKit: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: minX, y: primaryHeight - maxY, width: width, height: height)
    }
}
