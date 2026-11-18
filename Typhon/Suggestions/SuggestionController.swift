import AppKit
import Carbon.HIToolbox
import Observation
import OSLog
import TyphonCore

/// Watches for typing pauses, asks the model for a fix, shows it, and applies it on Tab/Enter.
@Observable
final class SuggestionController {
    struct RecentFix: Identifiable {
        let id = UUID()
        let original: String
        let fixed: String
        let appName: String
        let date: Date
    }

    /// Timing and outcome of the last suggestion, for the self-test and Settings. Never contains text.
    struct Diagnostics {
        var lastKeyAt: ContinuousClock.Instant?
        var lastShownAt: ContinuousClock.Instant?
        var lastCaretQuality: CaretLocator.Quality?
        var lastApplyMethod: TextApplier.Method?
        var lastApplyError: String?
        var lastSkip: String?
    }
    private(set) var diagnostics = Diagnostics()

    /// Kept in memory only, never written to disk.
    private(set) var recentFixes: [RecentFix] = []

    private struct Suggestion {
        let field: FocusedField
        let range: NSRange
        let original: String
        let fixed: String
        let polished: Polished
    }

    private let preferences: Preferences
    private let model: ModelController
    private let tap = KeyboardTap()
    private let panel = SuggestionPanelController()
    private let log = Logger(subsystem: "dev.typhon.Typhon", category: "suggestions")

    private var suggestion: Suggestion?
    private var dismissedOriginal: String?
    private var isFresh = false
    private var pendingAccept: (sendEnter: Bool, deadline: ContinuousClock.Instant)?
    private var debounce: Task<Void, Never>?
    private var request: Task<Void, Never>?
    private var deferredReveal: Task<Void, Never>?

    /// ⌃⌥F asks for a fix right now, even in apps where Typhon is off.
    static let hotkeyCode = Int64(kVK_ANSI_F)
    static let hotkeyFlags: CGEventFlags = [.maskControl, .maskAlternate]

    init(preferences: Preferences, model: ModelController) {
        self.preferences = preferences
        self.model = model
        panel.onAccept = { [weak self] in self?.accept(sendEnter: false) }
        panel.onDismiss = { [weak self] in self?.dismiss() }
        tap.onKey = { [weak self] key, code, flags in
            self?.handleKey(key, code: code, flags: flags) ?? .pass
        }
        tap.onMouseDown = { [weak self] location in self?.handleMouseDown(at: location) }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.hide()
                if let app { AccessibilityWaker.wake(app) }
            }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { AccessibilityWaker.forget(pid) } }
        }
    }

    var isTapRunning: Bool { tap.isRunning }

    /// Starts listening once Accessibility is granted. Safe to call repeatedly.
    func start() {
        guard AXIsProcessTrusted() else { return }
        if tap.start() {
            if let app = NSWorkspace.shared.frontmostApplication { AccessibilityWaker.wake(app) }
        }
    }

    func clearRecentFixes() { recentFixes.removeAll() }

    /// Asks for a fix in the focused field right away (menu item / hotkey).
    func checkNow() {
        debounce?.cancel()
        refresh(manual: true)
    }

    // MARK: - Input

    private func handleKey(_ key: KeyboardTap.Key?, code: Int64, flags: CGEventFlags) -> KeyboardTap.Decision {
        if code == Self.hotkeyCode, flags == Self.hotkeyFlags {
            checkNow()
            return .consume
        }
        // Only ever intercept keys for a suggestion the user can actually see.
        if let key, panel.isOnScreen, suggestion != nil {
            switch key {
            case .escape:
                dismiss()
                return .consume
            case .tab:
                accept(sendEnter: false)
                return .consume
            case .enter:
                switch preferences.returnKey {
                case .normal:
                    hide() // Return does its usual thing (send, new line…)
                case .accept:
                    accept(sendEnter: false)
                    return .consume
                case .fixAndSend:
                    accept(sendEnter: true)
                    return .consume
                }
            }
        }
        userTyped()
        return .pass
    }

    private func handleMouseDown(at location: CGPoint) {
        if let frame = panel.frameInCGCoordinates, frame.contains(location) { return }
        hide()
    }

    private func userTyped() {
        diagnostics.lastKeyAt = .now
        isFresh = false
        engineCancel()
        deferredReveal?.cancel()
        if panel.isVisible {
            if preferences.timing == .pause { hide() } else { updatePanel() }
        }
        debounce?.cancel()
        let delay = preferences.timing.debounce
        debounce = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            refresh(manual: false)
        }
    }

    private func engineCancel() {
        request?.cancel()
        model.engine.cancelAll()
    }

    // MARK: - Suggestions

    private func refresh(manual: Bool) {
        guard model.isReady else { hide(); return }
        guard manual || preferences.isEnabled else { hide(); return }
        guard manual || !preferences.isPaused else { hide(); return }

        let field: FocusedField
        switch FocusedField.current() {
        case .success(let value): field = value
        case .failure(let reason):
            diagnostics.lastSkip = "\(reason)"
            hide()
            return
        }

        guard manual || preferences.isEnabled(for: field.bundleID) else {
            hide()
            return
        }

        diagnostics.lastSkip = nil
        guard field.selection.length == 0,
              let range = TextScope.span(in: field.text, caret: field.selection.location)
        else {
            diagnostics.lastSkip = "no span (len \((field.text as NSString).length), sel \(field.selection))"
            hide()
            return
        }
        let original = (field.text as NSString).substring(with: range)
        if !manual, original == dismissedOriginal { hide(); return }

        // Same text as the suggestion on screen (e.g. the user only moved the caret back and forth).
        if let suggestion, suggestion.original == original, suggestion.field.element == field.element {
            self.suggestion = Suggestion(field: field, range: range, original: original,
                                         fixed: suggestion.fixed, polished: suggestion.polished)
            isFresh = true
            reveal(manual: manual)
            return
        }

        request?.cancel()
        request = Task {
            let polished: Polished
            do { polished = try await model.engine.polish(original) } catch { return } // superseded
            guard !Task.isCancelled else { return }
            guard field.currentText() == field.text else { diagnostics.lastSkip = "text changed"; return }
            model.record(latency: polished.milliseconds)

            let fixed = SmartEdit.tidy(original: original, fixed: polished.output)
            guard TextScope.isPlausibleEdit(original: original, fixed: fixed) else {
                diagnostics.lastSkip = "implausible or unchanged"
                suggestion = nil
                hide()
                resolvePendingAccept(found: false)
                return
            }
            suggestion = Suggestion(field: field, range: range, original: original,
                                    fixed: fixed, polished: polished)
            isFresh = true
            reveal(manual: manual)
        }
    }

    /// Shows the current suggestion, unless (in live mode) the only change is in the word
    /// still being typed; then it waits a little longer for the user to finish that word.
    private func reveal(manual: Bool) {
        guard let suggestion else { return }
        let wordInProgress = suggestion.original.last.map { $0.isLetter || $0.isNumber } ?? false
        let onlyTail = Self.onlyChangesTail(suggestion.original, suggestion.fixed)
        if !manual, preferences.timing == .live, wordInProgress, onlyTail, pendingAccept == nil {
            deferredReveal?.cancel()
            deferredReveal = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, isFresh else { return }
                show(suggestion)
            }
            if panel.isVisible { hide() }
            return
        }
        show(suggestion)
    }

    private func show(_ suggestion: Suggestion) {
        guard let caret = CaretLocator.caretRect(
            in: suggestion.field.element, at: suggestion.field.selection.location,
            textLength: (suggestion.field.text as NSString).length)
        else { hide(); return }
        panel.show(content(for: suggestion), caret: caret.0)
        diagnostics.lastShownAt = .now
        diagnostics.lastCaretQuality = caret.1
        log.debug("suggestion shown in \(suggestion.polished.milliseconds, format: .fixed(precision: 0)) ms")
        resolvePendingAccept(found: true)
    }

    private func content(for suggestion: Suggestion) -> PanelContent {
        PanelContent(
            segments: WordDiff.diff(suggestion.original, suggestion.fixed),
            milliseconds: suggestion.polished.milliseconds,
            isStale: !isFresh,
            acceptLabel: preferences.returnKey == .fixAndSend ? "Accept · ↩ fix & send" : "Accept")
    }

    private func updatePanel() {
        guard let suggestion else { return }
        panel.update(content(for: suggestion))
    }

    /// Whether the edit only touches the last word and/or adds closing punctuation.
    static func onlyChangesTail(_ original: String, _ fixed: String) -> Bool {
        func head(_ s: String) -> Substring {
            let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: ".!?… "))
            return trimmed.lastIndex(where: \.isWhitespace).map { trimmed[..<$0] } ?? ""
        }
        return head(original) == head(fixed)
    }

    // MARK: - Accept / dismiss

    private func accept(sendEnter: Bool) {
        guard let suggestion else { return }
        guard isFresh else {
            // The user is mid-flow: fetch the fix for what's there now and accept it as soon as it lands.
            pendingAccept = (sendEnter, .now + .milliseconds(1500))
            debounce?.cancel()
            refresh(manual: true)
            return
        }
        pendingAccept = nil
        hide()
        self.suggestion = nil
        Task {
            do {
                guard let edit = SmartEdit.make(
                    original: suggestion.original, fixed: suggestion.fixed, spanStart: suggestion.range.location)
                else { return }
                let method = try await TextApplier.apply(edit, in: suggestion.field)
                log.debug("applied via \(method.rawValue, privacy: .public)")
                diagnostics.lastApplyMethod = method
                diagnostics.lastApplyError = nil
                if preferences.keepRecentFixes {
                    recentFixes.insert(RecentFix(
                        original: suggestion.original, fixed: suggestion.fixed,
                        appName: suggestion.field.appName, date: .now), at: 0)
                    recentFixes = Array(recentFixes.prefix(10))
                }
                if sendEnter {
                    try? await Task.sleep(for: .milliseconds(method == .paste ? 120 : 30))
                    TextApplier.postKey(CGKeyCode(kVK_Return))
                } else {
                    // Look again right away, so anything still wrong gets its own suggestion.
                    try? await Task.sleep(for: .milliseconds(method == .paste ? 800 : 120))
                    refresh(manual: false)
                }
            } catch {
                log.error("couldn't apply suggestion: \(String(describing: error), privacy: .public)")
                diagnostics.lastApplyError = String(describing: error)
                NSSound.beep()
            }
        }
    }

    private func resolvePendingAccept(found: Bool) {
        guard let pending = pendingAccept else { return }
        pendingAccept = nil
        if found, ContinuousClock.now < pending.deadline {
            accept(sendEnter: pending.sendEnter)
        } else {
            // Nothing to accept after all: never swallow the user's key.
            TextApplier.postKey(CGKeyCode(pending.sendEnter ? kVK_Return : kVK_Tab))
        }
    }

    private func dismiss() {
        dismissedOriginal = suggestion?.original
        suggestion = nil
        hide()
    }

    private func hide() {
        deferredReveal?.cancel()
        panel.hide()
        resolvePendingAccept(found: false)
    }
}
