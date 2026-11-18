import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// One active session event tap, installed once Accessibility is granted.
///
/// It never records what you type. It only notices *that* a key was pressed (to know when you
/// pause), and swallows Tab / Return / Esc while a suggestion is on screen.
final class KeyboardTap {
    enum Key { case tab, enter, escape }
    enum Decision { case pass, consume }

    /// Called for every key press (synchronously, keep it cheap). Return `.consume` to swallow it.
    var onKey: ((_ key: Key?, _ keyCode: Int64, _ flags: CGEventFlags) -> Decision)?
    var onMouseDown: ((_ location: CGPoint) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<KeyboardTap>.fromOpaque(refcon).takeUnretainedValue()
                let pass = MainActor.assumeIsolated { me.shouldPass(type: type, event: event) }
                return pass ? Unmanaged.passUnretained(event) : nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
    }

    /// Returns false to swallow the event.
    private func shouldPass(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .leftMouseDown, .rightMouseDown:
            onMouseDown?(event.location)
            return true
        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == TextApplier.syntheticEventTag {
                return true
            }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            var key: Key?
            if flags.isEmpty {
                switch Int(code) {
                case kVK_Tab: key = .tab
                case kVK_Return, kVK_ANSI_KeypadEnter: key = .enter
                case kVK_Escape: key = .escape
                default: break
                }
            }
            return (onKey?(key, code, flags) ?? .pass) == .pass
        default:
            return true
        }
    }
}
