import AppKit
import ApplicationServices
import Carbon.HIToolbox
import TyphonCore

/// Replaces a range of text in another app.
///
/// Order of attempts (pattern from Jot and KeyType, see README credits):
/// 1. Select the range via AX and set `kAXSelectedText`, then *verify* by reading the value back,
///    because Electron reports success without inserting anything.
/// 2. Otherwise select the range (AX, or Shift+Arrow keys) and paste, restoring the clipboard after.
enum TextApplier {
    enum Method: String { case accessibility, paste }
    enum Failure: Error { case focusMoved, textChanged, cannotSelect }

    /// Marks events Typhon posts so its own keyboard tap ignores them.
    static let syntheticEventTag: Int64 = 0x7479_7068_6F6E // "typhon"

    /// Applies the smallest word-aligned edit, re-located against the field's current text.
    @discardableResult
    static func apply(_ planned: SmartEdit, in field: FocusedField) async throws -> Method {
        // The user may have moved on while the panel was up; never type into the wrong place.
        guard let focused = AXElement.systemWide.element(kAXFocusedUIElementAttribute), focused == field.element
        else { throw Failure.focusMoved }
        guard let text = field.element.value, let edit = planned.rebased(onto: text)
        else { throw Failure.textChanged }

        let caretBefore = field.element.selectedRange.map { $0.location } ?? NSMaxRange(edit.range)
        let caretAfter = NSRange(location: edit.caret(after: caretBefore), length: 0)
        let expected = (text as NSString).replacingCharacters(in: edit.range, with: edit.new)

        /// True only if the words to replace are really what's selected. Web views happily
        /// report a selection they never made, which turns a replace into an insert.
        func selectionIsExactlyTheOldWords() -> Bool {
            guard field.element.selectedRange == edit.range else { return false }
            if let selected = field.element.string(kAXSelectedTextAttribute) { return selected == edit.old }
            return true
        }

        // 1. Native text views: a direct, verified Accessibility edit.
        if !prefersKeyboard(field), field.element.isSettable(kAXSelectedTextAttribute),
           field.element.setSelectedRange(edit.range), selectionIsExactlyTheOldWords(),
           field.element.set(kAXSelectedTextAttribute, edit.new as CFString) == .success {
            for _ in 0..<5 {
                if field.element.value == expected {
                    field.element.setSelectedRange(caretAfter)
                    return .accessibility
                }
                try await Task.sleep(for: .milliseconds(30))
            }
            // Something other than our exact edit happened: take it back before trying again.
            if field.element.value != text {
                postKey(CGKeyCode(kVK_ANSI_Z), flags: .maskCommand)
                try await Task.sleep(for: .milliseconds(80))
                guard field.element.value == text else { throw Failure.textChanged }
            }
        }

        // 2. Select the words with real keystrokes, confirm, then paste over them.
        let stepsBack = try await selectWithKeyboard(edit: edit, caret: caretBefore, in: text)
        // Web views update their accessibility tree a beat after the keystrokes land.
        var selected = field.element.string(kAXSelectedTextAttribute)
        for _ in 0..<10 where selected != nil && selected != edit.old {
            try await Task.sleep(for: .milliseconds(30))
            selected = field.element.string(kAXSelectedTextAttribute)
        }
        if let selected, selected != edit.old {
            postKey(CGKeyCode(kVK_RightArrow)) // collapse the selection; never paste over the wrong text
            for _ in 0..<stepsBack { postKey(CGKeyCode(kVK_RightArrow)) }
            throw Failure.cannotSelect
        }
        try await Pasteboard.paste(edit.new)
        for _ in 0..<stepsBack { postKey(CGKeyCode(kVK_RightArrow)) }
        return .paste
    }

    /// Web views and Electron apps acknowledge AX edits they don't perform; use the keyboard there.
    private static func prefersKeyboard(_ field: FocusedField) -> Bool {
        if field.bundleID == "com.apple.Safari" || AppQuirks.chromiumBrowsers.contains(field.bundleID) { return true }
        if let app = NSRunningApplication(processIdentifier: field.pid), AppQuirks.isElectron(app) { return true }
        // Any other app showing web content (e.g. a WKWebView) exposes an AXWebArea ancestor.
        var element: AXElement? = field.element
        for _ in 0..<12 {
            guard let current = element else { break }
            if current.role == "AXWebArea" { return true }
            element = current.element(kAXParentAttribute)
        }
        return false
    }

    /// Selects the edit's words with the arrow keys, starting from the caret. Returns how many
    /// characters the caret sits after the edit (to step back afterwards).
    private static func selectWithKeyboard(edit: SmartEdit, caret: Int, in text: String) async throws -> Int {
        let ns = text as NSString
        let end = NSMaxRange(edit.range)
        guard caret >= end, caret <= ns.length else { throw Failure.cannotSelect }
        let between = ns.substring(with: NSRange(location: end, length: caret - end)).count
        for _ in 0..<between { postKey(CGKeyCode(kVK_LeftArrow)) }
        for _ in 0..<edit.old.count { postKey(CGKeyCode(kVK_LeftArrow), flags: .maskShift) }
        try await Task.sleep(for: .milliseconds(30))
        return between
    }

    static func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// The key code that types "v" in the current keyboard layout (Dvorak, AZERTY, ...).
    static var keyCodeForV: CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return CGKeyCode(kVK_ANSI_V) }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> CGKeyCode in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return CGKeyCode(kVK_ANSI_V)
            }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
                if status == noErr, length == 1, chars[0] == UniChar(("v" as Unicode.Scalar).value) {
                    return CGKeyCode(code)
                }
            }
            return CGKeyCode(kVK_ANSI_V)
        }
    }
}

/// Pastes text and puts the user's clipboard back afterwards.
enum Pasteboard {
    static func paste(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Ask clipboard managers to ignore this temporary entry (nspasteboard.org conventions).
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pasteboard.writeObjects([item])
        let ourChange = pasteboard.changeCount

        TextApplier.postKey(TextApplier.keyCodeForV, flags: .maskCommand)

        // Restoring too early makes the target paste the *old* clipboard, so give it a moment.
        try? await Task.sleep(for: .milliseconds(700))
        guard pasteboard.changeCount == ourChange else { return } // the user copied something new
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }
}
