#if DEBUG
import AppKit
import SwiftUI
import TyphonCore

/// Debug-only windows for screenshots: `--preview-menu`, `--preview-panel`, `--preview-settings`.
enum DebugPreviews {
    private static var windows: [NSWindow] = []
    private static var panel: SuggestionPanelController?

    static func openRequested(state: AppState) {
        let args = CommandLine.arguments
        if args.contains("--preview-menu") {
            let hosting = NSHostingView(rootView: MenuBarView().environment(state))
            let glass = NSGlassEffectView()
            glass.cornerRadius = 18
            glass.contentView = hosting
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = glass
            window.setFrameTopLeftPoint(NSPoint(x: 900, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - 8))
            window.orderFrontRegardless()
            windows.append(window)
        }
        if args.contains("--preview-panel") {
            let controller = SuggestionPanelController()
            controller.show(PanelContent(
                segments: WordDiff.diff("cna u pikc up some milk on teh way hoem", "Can you pick up some milk on the way home?"),
                milliseconds: 58, isStale: false, acceptLabel: "Accept"),
                caret: CGRect(x: 520, y: 520, width: 1, height: 18))
            panel = controller
        }
        if args.contains("--preview-settings") {
            NSApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }
}
#endif
