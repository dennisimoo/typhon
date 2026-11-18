import AppKit
import SwiftUI
import TyphonCore

/// What the floating panel shows.
struct PanelContent: Equatable {
    var segments: [DiffSegment]
    var milliseconds: Double
    var isStale: Bool
    var acceptLabel: String
}

/// A floating panel that never takes focus away from the app you're typing in.
final class SuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A hosting view that reacts to the first click even though Typhon is never the active app.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class SuggestionPanelController {
    var onAccept: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let panel: SuggestionPanel
    private let hosting: FirstMouseHostingView<SuggestionView>
    private var hideWorkItem: DispatchWorkItem?
    private var lastCaret: CGRect = .zero
    private(set) var isVisible = false

    /// True only when the panel is really on screen with a real size.
    var isOnScreen: Bool {
        isVisible && panel.isVisible && panel.frame.width > 20 && panel.frame.height > 20
    }

    init() {
        panel = SuggestionPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the glass draws its own depth
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false

        hosting = FirstMouseHostingView(rootView: SuggestionView(content: nil, onAccept: {}, onDismiss: {}))
        panel.contentView = hosting
    }

    /// Panel frame in CoreGraphics (top-left origin) coordinates, for hit-testing mouse clicks.
    var frameInCGCoordinates: CGRect? {
        guard isVisible else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = panel.frame
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    func show(_ content: PanelContent, caret: CGRect) {
        hideWorkItem?.cancel()
        hosting.rootView = SuggestionView(
            content: content,
            onAccept: { [weak self] in self?.onAccept?() },
            onDismiss: { [weak self] in self?.onDismiss?() })
        lastCaret = caret
        let frame = Self.frame(size: measuredSize(), caret: caret)

        if isVisible {
            panel.setFrame(frame, display: true, animate: false)
            return
        }
        isVisible = true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(reduceMotion ? frame : frame.offsetBy(dx: 0, dy: 4), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Updates the content in place (e.g. dimming while the user keeps typing).
    func update(_ content: PanelContent) {
        guard isVisible else { return }
        hosting.rootView = SuggestionView(
            content: content,
            onAccept: { [weak self] in self?.onAccept?() },
            onDismiss: { [weak self] in self?.onDismiss?() })
        // Re-place from the caret every time: a longer suggestion must still fit on screen.
        panel.setFrame(Self.frame(size: measuredSize(), caret: lastCaret), display: true)
    }

    /// The SwiftUI content's natural size (never zero, or the panel would be invisible).
    private func measuredSize() -> CGSize {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        return size.width > 1 && size.height > 1 ? size : CGSize(width: 320, height: 80)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    /// Below the caret line, or above it when there's no room; always fully on the caret's screen.
    static func frame(size: CGSize, caret: CGRect) -> CGRect {
        let visible = screen(for: caret)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: min(size.width, visible.width - 8), height: min(size.height, visible.height - 8))
        let gap: CGFloat = 6
        var origin = CGPoint(x: caret.minX - 14, y: caret.minY - gap - size.height)
        if origin.y < visible.minY + 4 { origin.y = caret.maxY + gap }   // no room below: go above
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        return CGRect(origin: origin, size: size)
    }

    /// The screen containing the caret, or the nearest one if the caret sits in a gap between displays.
    static func screen(for caret: CGRect) -> NSScreen? {
        let point = CGPoint(x: caret.midX, y: caret.midY)
        if let containing = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }) {
            return containing
        }
        return NSScreen.screens.min { a, b in distance(point, a.frame) < distance(point, b.frame) }
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}
