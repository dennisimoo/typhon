import Foundation
import Observation

/// User settings, stored in UserDefaults. Nothing you type is ever stored here.
@Observable
final class Preferences {
    enum Timing: String, CaseIterable, Identifiable {
        case live, pause
        var id: String { rawValue }
        var title: String { self == .live ? "Live, as you type" : "When you pause" }
        var debounce: Duration { self == .live ? .milliseconds(110) : .milliseconds(350) }
    }

    /// What Return does while a suggestion is showing. Default: nothing, so Return always sends.
    enum ReturnKey: String, CaseIterable, Identifiable {
        case normal, accept, fixAndSend
        var id: String { rawValue }
        var title: String {
            switch self {
            case .normal: "Works as usual"
            case .accept: "Accepts the suggestion"
            case .fixAndSend: "Accepts, then sends"
            }
        }
    }

    private let defaults = UserDefaults.standard

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "enabled") } }
    var timing: Timing { didSet { defaults.set(timing.rawValue, forKey: "timing") } }
    var returnKey: ReturnKey { didSet { defaults.set(returnKey.rawValue, forKey: "returnKey") } }
    var useDrafter: Bool { didSet { defaults.set(useDrafter, forKey: "useDrafter") } }
    var keepRecentFixes: Bool { didSet { defaults.set(keepRecentFixes, forKey: "keepRecentFixes") } }
    var showInMenuBar: Bool { didSet { defaults.set(showInMenuBar, forKey: "showInMenuBar") } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "onboarded") } }
    var pausedUntil: Date? { didSet { defaults.set(pausedUntil, forKey: "pausedUntil") } }
    /// Per-app overrides by bundle identifier. Apps not listed use ``AppQuirks`` defaults.
    var appOverrides: [String: Bool] { didSet { defaults.set(appOverrides, forKey: "appOverrides") } }

    init() {
        defaults.register(defaults: [
            "enabled": true, "timing": Timing.live.rawValue, "returnKey": ReturnKey.normal.rawValue,
            "useDrafter": true, "keepRecentFixes": true, "onboarded": false, "showInMenuBar": true,
        ])
        isEnabled = defaults.bool(forKey: "enabled")
        timing = Timing(rawValue: defaults.string(forKey: "timing") ?? "") ?? .live
        returnKey = ReturnKey(rawValue: defaults.string(forKey: "returnKey") ?? "") ?? .normal
        useDrafter = defaults.bool(forKey: "useDrafter")
        keepRecentFixes = defaults.bool(forKey: "keepRecentFixes")
        hasCompletedOnboarding = defaults.bool(forKey: "onboarded")
        showInMenuBar = defaults.bool(forKey: "showInMenuBar")
        pausedUntil = defaults.object(forKey: "pausedUntil") as? Date
        appOverrides = defaults.dictionary(forKey: "appOverrides") as? [String: Bool] ?? [:]
    }

    var isPaused: Bool { pausedUntil.map { $0 > .now } ?? false }

    func isEnabled(for bundleID: String) -> Bool {
        if AppQuirks.passwordManagers.contains(bundleID) { return false }
        return appOverrides[bundleID] ?? !AppQuirks.offByDefault.contains(bundleID)
    }

    func setEnabled(_ enabled: Bool, for bundleID: String) {
        let defaultValue = !AppQuirks.offByDefault.contains(bundleID)
        appOverrides[bundleID] = enabled == defaultValue ? nil : enabled
    }
}
