import AppKit
import SwiftUI
import TyphonCore

/// A compact menu in the style of the system's own menu bar extras (Wi‑Fi, Bluetooth, Focus).
struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var frontmostApp: NSRunningApplication?

    var body: some View {
        @Bindable var preferences = state.preferences

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Typhon").font(.headline)
                    Text(StatusText.line(for: state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Typhon", isOn: $preferences.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if let progress = state.model.progress {
                ProgressView(value: progress.fraction)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            MenuDivider()

            if !state.isAccessibilityGranted {
                MenuRow("Finish Setup…", symbol: "exclamationmark.triangle") { openMain(onboarding: true) }
            }
            if preferences.isPaused {
                MenuRow("Resume", symbol: "play") { state.resume() }
            } else {
                MenuRow("Pause for 1 Hour", symbol: "pause") { state.pause(for: 3600) }
                    .disabled(!preferences.isEnabled)
            }
            MenuRow("Check Current Field", symbol: "wand.and.sparkles", shortcut: "⌃⌥F") {
                state.suggestions.checkNow()
            }
            .disabled(!state.model.isReady || !state.isAccessibilityGranted)

            if let app = frontmostApp, let bundleID = app.bundleIdentifier {
                MenuDivider()
                let locked = AppQuirks.passwordManagers.contains(bundleID)
                HStack(spacing: 8) {
                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                    Text(locked ? "Always off in \(app.localizedName ?? "this app")" : "Use in \(app.localizedName ?? "this app")")
                        .lineLimit(1)
                    Spacer()
                    Toggle("Use in \(app.localizedName ?? "this app")", isOn: Binding(
                        get: { state.preferences.isEnabled(for: bundleID) },
                        set: { state.preferences.setEnabled($0, for: bundleID) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(locked)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }

            if !state.suggestions.recentFixes.isEmpty {
                MenuDivider()
                Text("Recent Fixes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                ForEach(state.suggestions.recentFixes.prefix(3)) { fix in
                    MenuRow(fix.fixed, symbol: nil, detail: fix.appName) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fix.fixed, forType: .string)
                    }
                    .help("Copy the fixed text")
                }
            }

            MenuDivider()
            MenuRow("Open Typhon", symbol: nil) { openMain(onboarding: false) }
            MenuRow("Settings…", symbol: nil, shortcut: "⌘,") {
                NSApp.activate()
                openSettings()
            }
            MenuRow("Quit Typhon", symbol: nil, shortcut: "⌘Q") { NSApp.terminate(nil) }
        }
        .padding(.vertical, 5)
        .frame(width: 300)
        .onAppear {
            let app = NSWorkspace.shared.frontmostApplication
            frontmostApp = app?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app
        }
    }

    private func openMain(onboarding: Bool) {
        if onboarding { state.isOnboardingRequested = true }
        NSApp.activate()
        openWindow(id: "main")
    }
}

/// A full-width menu item with a hover highlight, like system menus.
private struct MenuRow: View {
    let title: String
    let symbol: String?
    var detail: String?
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, symbol: String?, detail: String? = nil, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .frame(width: 16)
                        .foregroundStyle(hovering ? .white : .secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(hovering ? .white.opacity(0.8) : .secondary)
                    }
                }
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut).foregroundStyle(hovering ? .white.opacity(0.8) : .secondary)
                }
            }
            .foregroundStyle(hovering ? .white : .primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering && isEnabled ? Color.accentColor : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .onHover { hovering = $0 && isEnabled }
        .opacity(isEnabled ? 1 : 0.4)
    }
}

private struct MenuDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 14).padding(.vertical, 5)
    }
}
