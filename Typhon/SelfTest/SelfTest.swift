import AppKit
import ApplicationServices
import Carbon.HIToolbox
import TyphonCore

/// Drives real apps end to end: types a sloppy sentence, waits for the suggestion panel, presses
/// Tab, and reads the field back. Launch with `open -a Typhon --args --selftest [--apps a,b]`.
///
/// Only fixed test sentences are typed; results go to
/// `~/Library/Application Support/Typhon/selftest.json` and contain no user text.
enum SelfTest {
    struct Result: Codable {
        var app: String
        var focusedRole: String?
        var suggestionShown = false
        var keyUpToSuggestionMs: Double?
        var modelMs: Double?
        var caretQuality: String?
        var applyMethod: String?
        var applied = false
        var finalTextMatches = false
        var finalText: String? // only ever the fixed test sentence
        var note: String?
    }

    static let sentence = "cna u pikc up some milk on teh way hoem"
    static let expected = "Can you pick up some milk on the way home?"

    static func run(state: AppState) {
        Task { @MainActor in
            var results: [Result] = []
            defer { write(results) }
            guard AXIsProcessTrusted() else {
                results.append(Result(app: "-", note: "Accessibility not granted"))
                NSApp.terminate(nil); return
            }
            state.launch()
            while !state.model.isReady {
                if case .failed = state.model.phase { break }
                if case .missing = state.model.phase { state.model.prepare(download: true) }
                try? await Task.sleep(for: .milliseconds(200))
            }
            state.preferences.isEnabled = true
            state.preferences.pausedUntil = nil

            let arg = CommandLine.arguments.firstIndex(of: "--apps").map { CommandLine.arguments[$0 + 1] }
            let apps = (arg ?? "textedit,notes,safari,chrome,messages,slack,discord,terminal")
                .split(separator: ",").map(String.init)
            for app in apps {
                results.append(await test(app, state: state))
                write(results)
            }
            NSApp.terminate(nil)
        }
    }

    private static func test(_ name: String, state: AppState) async -> Result {
        var result = Result(app: name)
        guard await prepare(name) else { result.note = "couldn't open"; return result }
        try? await Task.sleep(for: .seconds(1.5))
        // Wait until an editable text field in the target app actually has focus.
        for _ in 0..<40 {
            if case .success(let field) = FocusedField.current(),
               ["AXTextArea", "AXTextField"].contains(field.element.role ?? "") { break }
            if name == "terminal" { break }
            if name == "safari" || name == "chrome" { clickCenterOfFrontWindow() }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if name != "terminal" {
            // Start from an empty field.
            postKey(CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
            postKey(CGKeyCode(kVK_Delete))
            try? await Task.sleep(for: .milliseconds(400))
        }
        if let focused = AXElement.systemWide.element(kAXFocusedUIElementAttribute) {
            result.focusedRole = [focused.role, focused.subrole].compactMap { $0 }.joined(separator: "/")
        }

        let shownBefore = state.suggestions.diagnostics.lastShownAt
        await type(sentence)
        let typedAt = ContinuousClock.now

        // Wait for the panel.
        var shownAt: ContinuousClock.Instant?
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(25))
            let shown = state.suggestions.diagnostics.lastShownAt
            if let shown, shown != shownBefore, shown > typedAt - .milliseconds(5) { shownAt = shown; break }
        }
        if name == "terminal", shownAt == nil {
            // Terminal is off by default; try the manual shortcut too.
            postKey(CGKeyCode(kVK_ANSI_F), flags: [.maskControl, .maskAlternate])
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(25))
                if let shown = state.suggestions.diagnostics.lastShownAt, shown != shownBefore { shownAt = shown; break }
            }
            result.note = "off by default; tried ⌃⌥F"
        }

        if let shownAt {
            result.suggestionShown = true
            let lastKey = state.suggestions.diagnostics.lastKeyAt ?? typedAt
            result.keyUpToSuggestionMs = Double((shownAt - lastKey).components.attoseconds) / 1e15
                + Double((shownAt - lastKey).components.seconds) * 1000
            result.modelMs = state.model.lastLatency
            result.caretQuality = state.suggestions.diagnostics.lastCaretQuality.map { "\($0)" }

            postKey(CGKeyCode(kVK_Tab))
            try? await Task.sleep(for: .seconds(1.2))
            result.applyMethod = state.suggestions.diagnostics.lastApplyMethod?.rawValue
            if let error = state.suggestions.diagnostics.lastApplyError { result.note = error }
            let text = AXElement.systemWide.element(kAXFocusedUIElementAttribute)?.value ?? ""
            result.applied = result.applyMethod != nil
            result.finalTextMatches = text.contains(expected)
            result.finalText = String(text.suffix(120))
        } else {
            result.note = (result.note ?? "") + " no suggestion (skip: \(state.suggestions.diagnostics.lastSkip ?? "-"))"
        }
        await cleanup(name)
        return result
    }

    // MARK: - App setup

    private static func prepare(_ name: String) async -> Bool {
        let dir = FileManager.default.temporaryDirectory.appending(path: "typhon-selftest")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let html = dir.appending(path: "field.html")
        try? """
        <!doctype html><title>Typhon test</title><body style="font:16px -apple-system;padding:40px">
        <textarea autofocus rows=6 cols=60 style="position:absolute;left:20px;top:20px;width:600px;height:300px"></textarea></body>
        """.write(to: html, atomically: true, encoding: .utf8)

        switch name {
        case "textedit":
            let file = dir.appending(path: "note-\(UUID().uuidString.prefix(6)).txt")
            try? "".write(to: file, atomically: true, encoding: .utf8)
            return await open([file], bundleID: "com.apple.TextEdit")
        case "safari": return await open([html], bundleID: "com.apple.Safari")
        case "chrome": return await open([html], bundleID: "com.google.Chrome")
        case "notes":
            guard await open([], bundleID: "com.apple.Notes") else { return false }
            try? await Task.sleep(for: .seconds(1))
            postKey(CGKeyCode(kVK_ANSI_N), flags: .maskCommand)
            return true
        case "messages":
            guard await open([], bundleID: "com.apple.MobileSMS") else { return false }
            try? await Task.sleep(for: .seconds(1))
            postKey(CGKeyCode(kVK_ANSI_N), flags: .maskCommand) // new message; never sent
            try? await Task.sleep(for: .seconds(0.8))
            postKey(CGKeyCode(kVK_Tab)) // move from "To:" to the message body
            return true
        case "slack": return await open([], bundleID: "com.tinyspeck.slackmacgap")
        case "discord": return await open([], bundleID: "com.hnc.Discord")
        case "terminal": return await open([], bundleID: "com.apple.Terminal")
        default: return false
        }
    }

    private static func cleanup(_ name: String) async {
        switch name {
        case "terminal":
            postKey(CGKeyCode(kVK_ANSI_U), flags: .maskControl) // clear the line, never press Return
        case "slack", "discord", "messages", "notes":
            postKey(CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
            postKey(CGKeyCode(kVK_Delete))
        default: break
        }
        try? await Task.sleep(for: .milliseconds(400))
    }

    private static func open(_ urls: [URL], bundleID: String) async -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            if urls.isEmpty {
                try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            } else {
                try await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)
            }
            return true
        } catch { return false }
    }

    // MARK: - Synthetic input (untagged, so Typhon treats it like real typing)

    private static func type(_ text: String) async {
        let source = CGEventSource(stateID: .hidSystemState)
        for character in text {
            var units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                event?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(18))
        }
    }

    /// Clicks the middle of the frontmost window (where the test page's text box is).
    private static func clickCenterOfFrontWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let window = AXElement.application(app.processIdentifier).element(kAXFocusedWindowAttribute),
              let frame = window.frame
        else { return }
        let point = CGPoint(x: frame.minX + 200, y: frame.minY + 260)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func write(_ results: [Result]) {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Typhon/selftest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(results).write(to: url)
    }
}
