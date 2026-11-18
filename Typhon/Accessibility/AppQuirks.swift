import AppKit

/// What Typhon knows about specific apps. See docs/COMPATIBILITY.md for the test results behind this.
enum AppQuirks {
    /// Never touch these: they handle secrets.
    static let passwordManagers: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.apple.Passwords",
        "com.apple.keychainaccess", "com.bitwarden.desktop", "com.dashlane.Dashlane",
        "com.lastpass.LastPass", "com.keepersecurity.passwordmanager", "com.callpod.keepermac.lite",
        "org.keepassxc.keepassxc", "com.sinew.Enpass-Desktop", "in.sinew.Enpass-Desktop",
        "com.nordpass.macos.NordPass", "me.proton.pass.electron",
    ]

    /// Off by default: no editable text through AX, and Tab means shell completion.
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm",
    ]

    /// Off by default for other reasons (Tab is meaningful, or the app is Typhon itself).
    static let offByDefault: Set<String> = terminals.union([
        "com.apple.dt.Xcode", "com.microsoft.Excel", "com.apple.iWork.Numbers", "com.sublimetext.4",
        Bundle.main.bundleIdentifier ?? "dev.typhon.Typhon",
    ])

    /// Chromium-based browsers need `AXEnhancedUserInterface` before they expose text geometry.
    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "org.chromium.Chromium", "ai.perplexity.comet", "company.thebrowser.dia",
    ]

    static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        return electronCache.value(for: url.path) {
            FileManager.default.fileExists(
                atPath: url.appending(path: "Contents/Frameworks/Electron Framework.framework").path)
        }
    }

    private static let electronCache = Cache<String, Bool>()
}

/// A tiny main-actor memo.
final class Cache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    func value(for key: Key, make: () -> Value) -> Value {
        if let value = storage[key] { return value }
        let value = make()
        storage[key] = value
        return value
    }
}
