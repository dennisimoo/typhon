import AppKit
import SwiftUI
import TyphonCore

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Apps", systemImage: "square.grid.2x2") { AppsSettings() }
            Tab("Model", systemImage: "cpu") { ModelSettings() }
            Tab("Privacy", systemImage: "lock.shield") { PrivacySettings() }
            Tab("About", systemImage: "tornado") { AboutSettings() }
        }
        .frame(width: 560, height: 480)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppState.self) private var state
    @State private var launchAtLogin = false

    var body: some View {
        @Bindable var preferences = state.preferences
        Form {
            Section {
                Toggle("Fix typing in other apps", isOn: $preferences.isEnabled)
                Picker("Show suggestions", selection: $preferences.timing) {
                    ForEach(Preferences.Timing.allCases) { Text($0.title).tag($0) }
                }
                Picker(selection: $preferences.returnKey) {
                    ForEach(Preferences.ReturnKey.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Return key")
                    Text("While a suggestion is showing. “Accepts, then sends” makes chat messages go out fixed.")
                }
            }
            Section("Keys") {
                LabeledContent("Accept suggestion") { KeyCaps(keys: ["⇥"]) }
                LabeledContent("Dismiss") { KeyCaps(keys: ["esc"]) }
                LabeledContent("Check the current field now") { KeyCaps(keys: ["⌃", "⌥", "F"]) }
            }
            Section {
                Toggle("Show Typhon in the menu bar", isOn: $preferences.showInMenuBar)
                Toggle("Open Typhon at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in state.launchAtLogin = value }
                Toggle("Keep recent fixes in the menu", isOn: $preferences.keepRecentFixes)
                    .onChange(of: preferences.keepRecentFixes) { _, keep in
                        if !keep { state.suggestions.clearRecentFixes() }
                    }
            } footer: {
                Text("Recent fixes stay in memory and disappear when Typhon quits.")
            }
            if !state.isAccessibilityGranted {
                Section {
                    Button("Grant Accessibility Access…") { state.isOnboardingRequested = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = state.launchAtLogin }
    }
}

struct KeyCaps: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, 4)
                    .glassEffect(.regular, in: .rect(cornerRadius: 5))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Apps

struct AppsSettings: View {
    @Environment(AppState.self) private var state
    @State private var apps: [AppEntry] = []
    @State private var search = ""

    struct AppEntry: Identifiable, Hashable {
        let id: String // bundle identifier
        let name: String
        let icon: NSImage?
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(filtered) { app in
                        HStack(spacing: 10) {
                            if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                if let note = note(for: app.id) {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Toggle(app.name, isOn: binding(for: app.id))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(AppQuirks.passwordManagers.contains(app.id))
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text("Typhon stays out of password fields everywhere, and out of password managers entirely. Terminals are off by default because Tab means completion there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Search apps")
        }
        .onAppear(perform: loadApps)
    }

    private var filtered: [AppEntry] {
        search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func binding(for bundleID: String) -> Binding<Bool> {
        Binding(get: { state.preferences.isEnabled(for: bundleID) },
                set: { state.preferences.setEnabled($0, for: bundleID) })
    }

    private func note(for bundleID: String) -> String? {
        if AppQuirks.passwordManagers.contains(bundleID) { return "Password manager · always off" }
        if AppQuirks.terminals.contains(bundleID) { return "Terminal · off by default" }
        if AppQuirks.offByDefault.contains(bundleID) { return "Off by default" }
        return nil
    }

    /// Running apps plus anything the user has customised, alphabetically.
    private func loadApps() {
        var entries: [String: AppEntry] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
            entries[id] = AppEntry(id: id, name: app.localizedName ?? id, icon: app.icon)
        }
        for id in state.preferences.appOverrides.keys where entries[id] == nil {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            entries[id] = AppEntry(id: id, name: name, icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) })
        }
        apps = entries.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Model

struct ModelSettings: View {
    @Environment(AppState.self) private var state
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var preferences = state.preferences
        Form {
            Section {
                LabeledContent("Model") {
                    Link("Typhon-1.2B (MLX 4-bit)", destination: URL(string: "https://huggingface.co/\(ModelManifest.repo)")!)
                }
                LabeledContent("Status") { ModelStatusLabel(phase: state.model.phase) }
                if let ms = state.model.lastLatency {
                    LabeledContent("Last fix") { Text("\(Int(ms.rounded())) ms").monospacedDigit() }
                }
                LabeledContent("Memory used by Typhon") {
                    TimelineView(.periodic(from: .now, by: 2)) { _ in
                        Text(MemoryReport.formatted()).monospacedDigit()
                    }
                }
            }
            Section {
                Toggle(isOn: $preferences.useDrafter) {
                    Text("Turbo mode")
                    Text("A small drafter guesses several words at once and Typhon checks them, roughly halving the time per fix with identical results. Adds a 0.6 GB download and about 0.2 GB of memory.")
                }
                .onChange(of: preferences.useDrafter) { state.model.drafterPreferenceChanged() }
            }
            Section {
                LabeledContent("Stored in") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([state.model.store.directory])
                    }
                }
                if case .missing = state.model.phase {
                    Button("Download Model (\(ByteCountFormatter.string(fromByteCount: state.model.downloadSize, countStyle: .file)))") {
                        state.model.prepare(download: true)
                    }
                } else if case .failed = state.model.phase {
                    Button("Try Again") { state.model.prepare(download: true) }
                }
                Button("Delete Model…", role: .destructive) { confirmDelete = true }
                    .disabled(state.model.isBusy)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete the downloaded model?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await state.model.deleteModel() } }
        } message: {
            Text("Typhon stops fixing text until you download it again.")
        }
    }
}

struct ModelStatusLabel: View {
    let phase: ModelController.Phase

    var body: some View {
        switch phase {
        case .missing: Label("Not downloaded", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
        case .downloading(let p):
            HStack {
                ProgressView(value: p.fraction).frame(width: 90)
                Text("\(Int(p.fraction * 100))%").monospacedDigit()
            }
        case .loading: Label("Loading…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
        }
    }
}

// MARK: - Privacy

struct PrivacySettings: View {
    var body: some View {
        Form {
            Section {
                PrivacyRow(symbol: "desktopcomputer", title: "Runs on your Mac",
                           detail: "The model runs locally on Apple silicon. Nothing you type is sent anywhere.")
                PrivacyRow(symbol: "eye.slash", title: "Never logged or saved",
                           detail: "Typhon doesn't write what you type to disk or to logs. Recent fixes live in memory only.")
                PrivacyRow(symbol: "lock.shield", title: "Stays out of secrets",
                           detail: "Password fields, secure input and password managers are always skipped.")
                PrivacyRow(symbol: "chart.bar.xaxis", title: "No telemetry",
                           detail: "No analytics, no crash reporting. The only network requests download the model from Hugging Face and, in release builds, check GitHub for updates.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacyRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - About

struct AboutSettings: View {
    @Environment(AppState.self) private var state

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    private var repository: String {
        Bundle.main.object(forInfoDictionaryKey: "TyphonRepository") as? String ?? "dennisimoo/typhon"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            VStack(spacing: 4) {
                Text("Typhon").font(.title.bold())
                Text("Version \(version)").foregroundStyle(.secondary)
            }
            Text("Fixes fast, sloppy typing everywhere on your Mac, with a small model that never leaves it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    if state.updater.isAvailable {
                        Button("Check for Updates…") { state.updater.checkForUpdates() }
                            .buttonStyle(.glass)
                            .disabled(!state.updater.canCheckForUpdates)
                    }
                    Link(destination: URL(string: "https://github.com/\(repository)")!) {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(.glass)
                }
            }

            Spacer()
            VStack(spacing: 3) {
                Text("Made by dennisimoo · model fine-tuned from Liquid AI LFM2.5")
                Text("Built with MLX · PermissionFlow · Sparkle")
                Text("App code: MIT License · Model: LFM Open License v1.0")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
