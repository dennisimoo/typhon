import AppKit
import SwiftUI

@main
struct TyphonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let state = AppState.shared

    var body: some Scene {
        @Bindable var preferences = state.preferences

        Window("Typhon", id: "main") {
            MainView()
                .environment(state)
        }
        .defaultSize(width: 860, height: 600)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)

        MenuBarExtra(isInserted: $preferences.showInMenuBar) {
            MenuBarView()
                .environment(state)
        } label: {
            let active = state.preferences.isEnabled && !state.preferences.isPaused
            Image(systemName: active ? "tornado" : "tornado.circle")
                .accessibilityLabel(active ? "Typhon" : "Typhon (paused)")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState.shared
        if CommandLine.arguments.contains("--selftest") {
            // Keep our own window out of the way while we drive other apps.
            NSApp.windows.forEach { $0.orderOut(nil) }
            SelfTest.run(state: state)
            return
        }
        state.launch()
        #if DEBUG
        DebugPreviews.openRequested(state: state)
        #endif
    }

    /// Typhon keeps fixing text with its window closed; it's a background helper with a window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
