import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// A snapshot of the text field the user is typing in.
struct FocusedField {
    let element: AXElement
    let pid: pid_t
    let bundleID: String
    let appName: String
    let text: String
    let selection: NSRange

    enum Unavailable: Error, Equatable {
        case noFocus, notText, secure, secureInput, ownApp
    }

    /// Reads the focused element system-wide. Returns why nothing can be read, when relevant.
    static func current() -> Result<FocusedField, Unavailable> {
        if IsSecureEventInputEnabled() { return .failure(.secureInput) }
        guard let element = AXElement.systemWide.element(kAXFocusedUIElementAttribute),
              let pid = element.pid,
              let app = NSRunningApplication(processIdentifier: pid)
        else { return .failure(.noFocus) }
        if pid == ProcessInfo.processInfo.processIdentifier { return .failure(.ownApp) }
        AXUIElementSetMessagingTimeout(element.raw, 0.25)

        if isSecure(element) { return .failure(.secure) }
        guard let text = element.value, let selection = element.selectedRange,
              isEditableText(element)
        else { return .failure(.notText) }

        return .success(FocusedField(
            element: element, pid: pid, bundleID: app.bundleIdentifier ?? "",
            appName: app.localizedName ?? "", text: text, selection: selection))
    }

    /// Re-reads the value, to check nothing changed while the model was thinking.
    func currentText() -> String? { element.value }

    private static func isEditableText(_ element: AXElement) -> Bool {
        switch element.role {
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField":
            return true
        default:
            // Web content (contenteditable) and some custom editors report other roles but
            // still expose a settable value or selected text.
            return element.isSettable(kAXValueAttribute) || element.isSettable(kAXSelectedTextAttribute)
        }
    }

    private static let secretHints = ["password", "passcode", "passwort", "contraseña", "mot de passe", "pin code", "one-time code", "2fa", "otp"]

    static func isSecure(_ element: AXElement) -> Bool {
        if element.role == "AXSecureTextField" || element.subrole == "AXSecureTextField" { return true }
        if element.bool("AXProtectedContent") == true { return true }
        let labels = [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute]
            .compactMap { element.string($0)?.lowercased() }
        return labels.contains { label in secretHints.contains { label.contains($0) } }
    }
}

/// Wakes up accessibility trees that browsers and Electron apps keep dormant by default.
enum AccessibilityWaker {
    private static var woken: Set<pid_t> = []

    static func wake(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        let pid = app.processIdentifier
        let electron = AppQuirks.isElectron(app)
        let chromium = AppQuirks.chromiumBrowsers.contains(bundleID)
        guard electron || chromium else { return }
        // VS Code-style apps can fall asleep again, so Electron is re-armed on every activation.
        guard electron || !woken.contains(pid) else { return }
        woken.insert(pid)

        Task.detached(priority: .utility) {
            let element = AXElement.application(pid)
            AXUIElementSetMessagingTimeout(element.raw, 1.5)
            if electron {
                element.set("AXManualAccessibility", kCFBooleanTrue)
            } else {
                // Chrome rejects AXManualAccessibility; enhanced UI turns on full a11y mode.
                // It can report an error and still apply, so we don't check the result.
                element.set("AXEnhancedUserInterface", kCFBooleanTrue)
            }
        }
    }

    static func forget(_ pid: pid_t) { woken.remove(pid) }
}

/// Finds where the caret is on screen, trying the most precise method first.
enum CaretLocator {
    enum Quality { case exact, derived, estimated }

    /// Returns the caret rect in AppKit screen coordinates.
    static func caretRect(in element: AXElement, at location: Int, textLength: Int) -> (CGRect, Quality)? {
        let fieldFrame = element.frame
        func valid(_ rect: CGRect?) -> CGRect? {
            guard let rect, rect.height > 0, rect.height < 500, rect.width < 4000,
                  rect.origin != .zero || rect.width > 0
            else { return nil }
            // Some apps report coordinates that aren't on any display; don't follow them off screen.
            let center = CGPoint(x: rect.midX, y: rect.midY).flippedPointToAppKit
            guard NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(center) }) else { return nil }
            if let fieldFrame, !fieldFrame.insetBy(dx: -24, dy: -24).intersects(rect) { return nil }
            // Some engines return the whole text container instead of a caret.
            if let fieldFrame, rect.height > 80, rect.size == fieldFrame.size { return nil }
            return rect
        }

        if let rect = valid(element.bounds(for: NSRange(location: location, length: 0))), rect.height > 2 {
            return (rect.flippedToAppKit, .exact)
        }
        if location > 0, let rect = valid(element.bounds(for: NSRange(location: location - 1, length: 1))) {
            return (CGRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height).flippedToAppKit, .derived)
        }
        if let rect = valid(element.selectedTextMarkerBounds()) {
            return (CGRect(x: rect.maxX, y: rect.minY, width: 1, height: max(rect.height, 14)).flippedToAppKit, .derived)
        }
        if let fieldFrame, fieldFrame.width > 0, fieldFrame.height > 0 {
            // Anchor under the field's bottom-left edge when we can't do better.
            let line = CGRect(x: fieldFrame.minX + 8, y: fieldFrame.maxY - 20, width: 1, height: 16)
            return (line.flippedToAppKit, .estimated)
        }
        return nil
    }
}
