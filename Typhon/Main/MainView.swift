import AppKit
import SwiftUI
import TyphonCore

/// The main window: setup on first launch, then a sidebar of sections.
struct MainView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.showsOnboarding {
                OnboardingView {
                    state.preferences.hasCompletedOnboarding = true
                    withAnimation(.smooth) { state.isOnboardingRequested = false }
                }
                .frame(width: 680, height: 580)
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .containerBackground(.thinMaterial, for: .window)
            } else {
                MainSplitView()
                    .frame(minWidth: 760, minHeight: 520)
            }
        }
        .animation(.smooth, value: state.showsOnboarding)
    }
}

private struct MainSplitView: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview, general, apps, model, privacy, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .general: "General"
            case .apps: "Apps"
            case .model: "Model"
            case .privacy: "Privacy"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .overview: "tornado"
            case .general: "gearshape"
            case .apps: "square.grid.2x2"
            case .model: "cpu"
            case .privacy: "hand.raised"
            case .about: "info.circle"
            }
        }
    }

    @State private var selection: Section? = .overview

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview: OverviewPane()
                case .general: GeneralSettings()
                case .apps: AppsSettings()
                case .model: ModelSettings()
                case .privacy: PrivacySettings()
                case .about: AboutSettings()
                }
            }
            .navigationTitle((selection ?? .overview).title)
        }
    }
}

// MARK: - Overview

private struct OverviewPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var preferences = state.preferences
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preferences.isEnabled ? "Typhon is on" : "Typhon is off")
                            .font(.title2.weight(.semibold))
                        Text(StatusText.line(for: state))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Fix typing in other apps", isOn: $preferences.isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.vertical, 4)
            }

            if !state.isAccessibilityGranted {
                Section {
                    LabeledContent {
                        Button("Grant Access…") { state.isOnboardingRequested = true }
                    } label: {
                        Label("Typhon needs Accessibility access to see text fields.", systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
            }

            Section {
                LabeledContent("Model") { ModelStatusLabel(phase: state.model.phase) }
                if let ms = state.model.lastLatency {
                    LabeledContent("Last fix") { Text("\(Int(ms.rounded())) ms").monospacedDigit() }
                }
                LabeledContent("Pause") {
                    if preferences.isPaused, let until = preferences.pausedUntil {
                        HStack {
                            Text("Until \(until.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                            Button("Resume") { state.resume() }
                        }
                    } else {
                        Button("Pause for 1 Hour") { state.pause(for: 3600) }
                            .disabled(!preferences.isEnabled)
                    }
                }
                LabeledContent("Check the current field") {
                    KeyCaps(keys: ["⌃", "⌥", "F"])
                }
            }

            Section("Try It") {
                TryItField()
            }

            Section {
                if state.suggestions.recentFixes.isEmpty {
                    Text(preferences.keepRecentFixes
                         ? "Fixes you accept appear here. They stay in memory and disappear when Typhon quits."
                         : "Recent fixes are turned off in General.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.suggestions.recentFixes) { fix in
                        RecentFixRow(fix: fix)
                    }
                }
            } header: {
                HStack {
                    Text("Recent Fixes")
                    Spacer()
                    if !state.suggestions.recentFixes.isEmpty {
                        Button("Clear") { state.suggestions.clearRecentFixes() }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A text field that polishes as you type, so you can feel Typhon without leaving the window.
private struct TryItField: View {
    @Environment(AppState.self) private var state
    @State private var text = ""
    @State private var fixed: (original: String, output: String, ms: Double)?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Type something sloppy, like “cna u sned me teh file”", text: $text, axis: .vertical)
                .lineLimit(1...3)
                .onChange(of: text) { _, value in polish(value) }
                .onKeyPress(.tab) {
                    guard let fixed, fixed.original == text else { return .ignored }
                    text = fixed.output
                    self.fixed = nil
                    return .handled
                }
                .disabled(!state.model.isReady)

            if let fixed, fixed.original == text {
                HStack(alignment: .firstTextBaseline) {
                    DiffText(segments: WordDiff.diff(fixed.original, fixed.output))
                    Spacer()
                    Text("⇥ to accept · \(Int(fixed.ms.rounded())) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else if !state.model.isReady {
                Text("Available once the model is ready.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .animation(.smooth(duration: 0.2), value: fixed?.output)
    }

    private func polish(_ value: String) {
        task?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.split(separator: " ").count >= 2 else { fixed = nil; return }
        task = Task {
            try? await Task.sleep(for: .milliseconds(110))
            guard !Task.isCancelled, let result = try? await state.model.engine.polish(trimmed), !Task.isCancelled else { return }
            fixed = result.output == trimmed ? nil : (value, result.output, result.milliseconds)
        }
    }
}

private struct RecentFixRow: View {
    let fix: SuggestionController.RecentFix

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            DiffText(segments: WordDiff.diff(fix.original, fix.fixed))
                .lineLimit(3)
            Text("\(fix.appName) · \(fix.date.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy Fixed Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fix.fixed, forType: .string)
            }
            Button("Copy Original Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fix.original, forType: .string)
            }
        }
    }
}

/// One status line shared by the main window and the menu bar.
enum StatusText {
    static func line(for state: AppState) -> String {
        let preferences = state.preferences
        if !state.isAccessibilityGranted { return "Waiting for Accessibility access" }
        if !preferences.isEnabled { return "Not fixing anything right now" }
        if let until = preferences.pausedUntil, until > .now {
            return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        }
        switch state.model.phase {
        case .missing: return "Model not downloaded"
        case .downloading(let p): return "Downloading the model… \(Int(p.fraction * 100))%"
        case .loading: return "Warming up…"
        case .failed: return "Model unavailable"
        case .ready: return state.model.drafterActive ? "Ready in every app · Turbo" : "Ready in every app"
        }
    }
}
