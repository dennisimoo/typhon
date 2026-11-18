import AppKit
import Observation
import ServiceManagement

/// The app's shared state, created once at launch.
@Observable
final class AppState {
    static let shared = AppState()

    let preferences = Preferences()
    let model: ModelController
    let suggestions: SuggestionController
    let updater = Updater()

    private(set) var isAccessibilityGranted = AXIsProcessTrusted()
    /// Shows the setup flow in the main window again (e.g. to grant Accessibility later).
    var isOnboardingRequested = CommandLine.arguments.contains("--onboarding")
    var showsOnboarding: Bool { !preferences.hasCompletedOnboarding || isOnboardingRequested }
    private var permissionTimer: Timer?

    private init() {
        model = ModelController(preferences: preferences)
        suggestions = SuggestionController(preferences: preferences, model: model)
    }

    func launch() {
        model.prepare(download: preferences.hasCompletedOnboarding)
        refreshPermission()
        // macOS posts this whenever any app's Accessibility permission changes.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated { self?.refreshPermission() }
            }
        }
    }

    /// Checks Accessibility permission, and starts the keyboard tap once it's granted.
    func refreshPermission() {
        isAccessibilityGranted = AXIsProcessTrusted()
        if isAccessibilityGranted {
            permissionTimer?.invalidate()
            permissionTimer = nil
            suggestions.start()
        } else if permissionTimer == nil {
            // Fallback poll (the notification above isn't guaranteed); stops once granted.
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermission() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            permissionTimer = timer
        }
    }

    // MARK: - Menu actions

    func pause(for duration: TimeInterval) { preferences.pausedUntil = .now.addingTimeInterval(duration) }
    func resume() { preferences.pausedUntil = nil }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSSound.beep()
            }
        }
    }
}
