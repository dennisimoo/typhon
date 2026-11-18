import AppKit
import PermissionFlow
import SwiftUI
import TyphonCore

struct OnboardingView: View {
    enum Step: Int, CaseIterable { case welcome, demo, permission, download, done }

    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = Self.initialStep
    @State private var forward = true
    let finish: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ZStack {
                    content(for: step)
                        .id(step)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                StepDots(current: step)
                    .padding(.bottom, 24)
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for step: Step) -> some View {
        switch step {
        case .welcome:
            WelcomeStep {
                state.model.prepare(download: true)
                go(to: .demo)
            }
        case .demo:
            DemoStep(back: { go(to: .welcome) }, next: { go(to: .permission) })
        case .permission:
            PermissionStep(back: { go(to: .demo) }, next: { go(to: .download) })
        case .download:
            DownloadStep(back: { go(to: .permission) }, next: { go(to: .done) })
        case .done:
            DoneStep {
                state.preferences.hasCompletedOnboarding = true
                finish()
            }
        }
    }

    /// `--onboarding-step <name>` opens a specific step (used for screenshots).
    private static var initialStep: Step {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--onboarding-step"), i + 1 < args.count else { return .welcome }
        return Step.allCases.first { "\($0)" == args[i + 1] } ?? .welcome
    }

    private func go(to next: Step) {
        forward = next.rawValue > step.rawValue
        withAnimation(.smooth(duration: 0.45)) { step = next }
    }
}

// MARK: - Shared pieces

extension View {
    /// A quiet surface for content that sits *on* the glass window (glass on glass looks muddy).
    func card(cornerRadius: CGFloat = 16) -> some View {
        background(.primary.opacity(0.05), in: .rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.08)))
    }
}

private struct StepDots: View {
    let current: OnboardingView.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingView.Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(step == current ? Color.blue : Color.primary.opacity(0.18))
                    .frame(width: step == current ? 20 : 6, height: 6)
            }
        }
        .animation(.smooth, value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingView.Step.allCases.count)")
    }
}

/// Title, subtitle and content, laid out the same way on every step.
private struct StepLayout<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) { actions }
                    .controlSize(.large)
            }
        }
        .padding(.top, 56)
        .padding(.horizontal, 48)
        .padding(.bottom, 18)
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    let next: () -> Void
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        StepLayout(
            title: "Meet Typhon",
            subtitle: "Type as fast and as sloppily as you like. Typhon fixes it in any app, with a small model that runs entirely on your Mac."
        ) {
            VStack(spacing: 26) {
                Image(systemName: "tornado")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.blue)
                    .symbolEffect(.wiggle.byLayer, options: .repeat(.periodic(delay: 2.5)), isActive: !reduceMotion)
                    .frame(width: 120, height: 120)
                    .background(.blue.opacity(0.12), in: .circle)
                    .overlay(Circle().strokeBorder(.blue.opacity(0.25)))

                HStack(spacing: 10) {
                    FeaturePill(symbol: "macwindow.on.rectangle", text: "Works in every app")
                    FeaturePill(symbol: "lock.fill", text: "Stays on your Mac")
                    FeaturePill(symbol: "bolt.fill", text: "~60 ms per fix")
                }
            }
            .padding(.top, 8)
        } actions: {
            VStack(spacing: 10) {
                Button("Get Started", action: next)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                Text("Typhon downloads its \(ByteCountFormatter.string(fromByteCount: state.model.downloadSize, countStyle: .file)) model from Hugging Face while you finish setting up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FeaturePill: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .card(cornerRadius: 20)
    }
}

// MARK: - Live demo

private struct DemoStep: View {
    let back: () -> Void
    let next: () -> Void

    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = ""
    @State private var suggestion: (original: String, fixed: String, ms: Double?)?
    @State private var typing: Task<Void, Never>?
    @State private var polishing: Task<Void, Never>?
    @State private var sampleIndex = 0
    @FocusState private var focused: Bool

    private static let samples: [(String, String)] = [
        ("cna u pikc up some milk on teh way hoem", "Can you pick up some milk on the way home?"),
        ("teh meeting got moved to tmrw at 3pm, can yuo make it", "The meeting got moved to tomorrow at 3pm. Can you make it?"),
        ("thx for teh help yesterday, realy apreciate it", "Thanks for the help yesterday. Really appreciate it."),
        ("lets grab cofee nxt week, im free tues or wed", "Let's grab coffee next week. I'm free Tuesday or Wednesday."),
    ]

    var body: some View {
        StepLayout(
            title: "Type like you're in a hurry",
            subtitle: "Mash out a message below. Typhon suggests a fix as you go; press Tab to take it."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Messages", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    LiveBadge(phase: state.model.phase, ms: suggestion?.ms)
                }

                TextField("Type something sloppy…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .lineLimit(2...4)
                    .focused($focused)
                    .onKeyPress(.tab) {
                        guard let suggestion, suggestion.original == text else { return .ignored }
                        withAnimation(.smooth) { text = suggestion.fixed; self.suggestion = nil }
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        withAnimation { suggestion = nil }
                        return .handled
                    }
                    .onChange(of: text) { _, newValue in
                        if typing == nil || typing?.isCancelled == true { polish(newValue) }
                    }
                    .padding(14)
                    .card(cornerRadius: 14)

                ZStack(alignment: .topLeading) {
                    if let suggestion, suggestion.original == text, suggestion.fixed != text {
                        SuggestionView(
                            content: PanelContent(
                                segments: WordDiff.diff(suggestion.original, suggestion.fixed),
                                milliseconds: suggestion.ms ?? 0, isStale: false, acceptLabel: "Accept"),
                            onAccept: {
                                withAnimation(.smooth) { text = suggestion.fixed; self.suggestion = nil }
                            },
                            onDismiss: { withAnimation { self.suggestion = nil } })
                        .transition(.scale(scale: 0.96, anchor: .topLeading).combined(with: .opacity))
                    }
                }
                .frame(height: 96, alignment: .topLeading)
                .animation(.smooth(duration: 0.25), value: suggestion?.fixed)

                Button("Show me another", systemImage: "arrow.clockwise") { autoType() }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 500)
        } actions: {
            Button("Back", action: back).buttonStyle(.glass)
            Button("Continue", action: next)
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear { autoType() }
        .onDisappear { typing?.cancel(); polishing?.cancel() }
        .onChange(of: state.model.isReady) { _, ready in if ready { polish(text) } }
    }

    /// Types a sample message character by character, then lets the user take over.
    private func autoType() {
        typing?.cancel()
        let (sample, _) = Self.samples[sampleIndex % Self.samples.count]
        sampleIndex += 1
        suggestion = nil
        text = ""
        typing = Task {
            for character in sample {
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 5 : Int.random(in: 28...70)))
                guard !Task.isCancelled else { return }
                text.append(character)
            }
            typing = nil
            polish(text)
            focused = true
        }
    }

    private func polish(_ value: String) {
        polishing?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.split(separator: " ").count >= 2 else { suggestion = nil; return }
        polishing = Task {
            try? await Task.sleep(for: .milliseconds(110))
            guard !Task.isCancelled else { return }
            if state.model.isReady {
                guard let result = try? await state.model.engine.polish(trimmed), !Task.isCancelled else { return }
                if result.output != trimmed { suggestion = (value, result.output, result.milliseconds) }
                else { suggestion = nil }
            } else if let sample = Self.samples.first(where: { $0.0 == trimmed }) {
                // The model is still downloading: show the answer it gives, labelled as a preview.
                suggestion = (value, sample.1, nil)
            }
        }
    }
}

private struct LiveBadge: View {
    let phase: ModelController.Phase
    let ms: Double?

    var body: some View {
        Group {
            switch phase {
            case .ready:
                Label(ms.map { "Live · \(Int($0.rounded())) ms" } ?? "Live", systemImage: "circle.fill")
                    .foregroundStyle(.green)
            case .downloading(let p):
                Label("Preview · model \(Int(p.fraction * 100))% downloaded", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            case .loading:
                Label("Preview · warming up", systemImage: "hourglass").foregroundStyle(.secondary)
            default:
                Label("Preview", systemImage: "eye").foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.medium))
        .labelStyle(BadgeLabelStyle())
        .contentTransition(.numericText())
        .animation(.smooth, value: ms)
    }
}

private struct BadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            configuration.title
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .card(cornerRadius: 12)
    }
}

// MARK: - Permission

private struct PermissionStep: View {
    let back: () -> Void
    let next: () -> Void

    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flow = PermissionFlow.makeController(
        configuration: .init(requiredAppURLs: [Bundle.main.bundleURL]))
    @State private var buttonFrame: CGRect = .zero
    @State private var askedAt: Date?
    @State private var showHint = false
    @State private var demoToggle = false

    var body: some View {
        StepLayout(
            title: state.isAccessibilityGranted ? "You're in" : "Let Typhon see what you type",
            subtitle: state.isAccessibilityGranted
                ? "Typhon can now read the field you're typing in, and nothing else leaves your Mac."
                : "macOS asks you to allow this under Accessibility. Typhon only reads the text field you're typing in, skips password fields, and never stores or sends what you write."
        ) {
            VStack(spacing: 18) {
                SettingsMock(isOn: state.isAccessibilityGranted || demoToggle, granted: state.isAccessibilityGranted)

                if state.isAccessibilityGranted {
                    Label("Access granted", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: state.isAccessibilityGranted)
                        .transition(.scale.combined(with: .opacity))
                } else if askedAt != nil {
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Drag Typhon into the list, or switch it on. This page continues by itself.")
                                .foregroundStyle(.secondary)
                        }
                        if showHint {
                            Text("Already on? Switch Typhon off and on again, or quit and reopen it.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.callout)
                    .transition(.opacity)
                }
            }
            .animation(.smooth, value: state.isAccessibilityGranted)
        } actions: {
            Button("Back", action: back).buttonStyle(.glass)
            if state.isAccessibilityGranted {
                Button("Continue", action: next)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Later", action: next).buttonStyle(.glass)
                Button("Open System Settings", systemImage: "gearshape") { authorize() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { buttonFrame = $0 }
            }
        }
        .task {
            // Gently animate the mock switch until the real permission arrives.
            while !state.isAccessibilityGranted, !reduceMotion, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.smooth(duration: 0.5)) { demoToggle.toggle() }
            }
        }
        .task(id: askedAt) {
            // Watch closely while System Settings is open, then move on by ourselves.
            guard askedAt != nil else { return }
            while !Task.isCancelled {
                state.refreshPermission()
                if state.isAccessibilityGranted {
                    flow.closePanel()
                    NSApp.activate()
                    try? await Task.sleep(for: .seconds(1.1))
                    next()
                    return
                }
                if let askedAt, Date().timeIntervalSince(askedAt) > 15 { withAnimation { showHint = true } }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        .onDisappear { flow.closePanel() }
    }

    private func authorize() {
        withAnimation { askedAt = .now }
        var source: CGRect?
        if let window = NSApp.keyWindow, let content = window.contentView, buttonFrame != .zero {
            let flipped = CGRect(x: buttonFrame.minX, y: content.bounds.height - buttonFrame.maxY,
                                 width: buttonFrame.width, height: buttonFrame.height)
            source = window.convertToScreen(flipped)
        }
        flow.authorize(pane: .accessibility, suggestedAppURLs: [Bundle.main.bundleURL], sourceFrameInScreen: source)
    }
}

/// A miniature of the System Settings row the user is about to flip.
private struct SettingsMock: View {
    let isOn: Bool
    let granted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "accessibility").foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.blue.gradient, in: .rect(cornerRadius: 6))
                Text("Accessibility").font(.headline)
                Spacer()
            }
            .padding(.bottom, 12)
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                Text("Typhon").font(.body.weight(.medium))
                Spacer()
                Toggle("Typhon", isOn: .constant(isOn))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .allowsHitTesting(false)
                    .tint(granted ? .green : .blue)
            }
            .padding(12)
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 10))
        }
        .padding(16)
        .frame(width: 360)
        .card(cornerRadius: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(granted ? "Typhon is allowed in Accessibility settings" : "Illustration of the Typhon switch in Accessibility settings")
    }
}

// MARK: - Download

private struct DownloadStep: View {
    let back: () -> Void
    let next: () -> Void
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var preferences = state.preferences
        StepLayout(title: title, subtitle: subtitle) {
            VStack(spacing: 22) {
                ProgressRing(fraction: fraction, phase: state.model.phase)

                if case .failed = state.model.phase {
                    Button("Try Again", systemImage: "arrow.clockwise") { state.model.prepare(download: true) }
                        .buttonStyle(.glass)
                } else if case .downloading = state.model.phase {
                    // Turbo can't change mid-download; show what's coming instead.
                    Label(preferences.useDrafter ? "Turbo mode included" : "Standard speed",
                          systemImage: preferences.useDrafter ? "bolt.fill" : "tortoise")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if case .missing = state.model.phase {
                    Toggle("Turbo mode: about twice as fast, +0.6 GB", isOn: $preferences.useDrafter)
                        .toggleStyle(.switch)
                }
            }
        } actions: {
            Button("Back", action: back).buttonStyle(.glass)
            if state.model.isReady {
                Button("Continue", action: next)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Finish in Background", action: next).buttonStyle(.glass)
            }
        }
        .onAppear { state.model.prepare(download: true) }
        .onChange(of: state.model.isReady) { _, ready in
            if ready {
                Task {
                    try? await Task.sleep(for: .seconds(0.8))
                    next()
                }
            }
        }
    }

    private var fraction: Double {
        switch state.model.phase {
        case .downloading(let p): p.fraction
        case .loading, .ready: 1
        default: 0
        }
    }

    private var title: String {
        switch state.model.phase {
        case .ready: "Typhon is ready"
        case .loading: "Warming up"
        case .failed: "The download stopped"
        default: "Downloading the model"
        }
    }

    private var subtitle: String {
        switch state.model.phase {
        case .downloading(let p):
            let done = ByteCountFormatter.string(fromByteCount: p.completedBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: p.totalBytes, countStyle: .file)
            var line = "\(done) of \(total)"
            if p.bytesPerSecond > 0 {
                let speed = ByteCountFormatter.string(fromByteCount: Int64(p.bytesPerSecond), countStyle: .file)
                let seconds = Double(p.totalBytes - p.completedBytes) / p.bytesPerSecond
                line += " · \(speed)/s · \(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))) left"
            }
            return line
        case .loading: return "Loading Typhon into memory so the first fix is instant."
        case .ready: return "Everything's downloaded and loaded."
        case .failed(let message): return "\(message) It will resume where it left off."
        case .missing: return "Typhon-1.2B comes from Hugging Face and stays on this Mac."
        }
    }
}

private struct ProgressRing: View {
    let fraction: Double
    let phase: ModelController.Phase

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.18), lineWidth: 10)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(AngularGradient(colors: [.blue.opacity(0.6), .blue, .cyan, .blue.opacity(0.6)], center: .center),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.4), value: fraction)
            Group {
                switch phase {
                case .ready:
                    Image(systemName: "checkmark")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                case .loading:
                    ProgressView().controlSize(.large)
                default:
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(value: fraction))
                }
            }
            .animation(.smooth, value: phase)
        }
        .frame(width: 150, height: 150)
        .padding(18)
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

// MARK: - Done

private struct DoneStep: View {
    let finish: () -> Void
    @Environment(AppState.self) private var state

    var body: some View {
        StepLayout(
            title: "You're all set",
            subtitle: "Typhon lives in your menu bar. Type anywhere, and when it spots a slip, a suggestion appears by your cursor."
        ) {
            VStack(spacing: 10) {
                ShortcutRow(keys: ["⇥"], text: "Accept the suggestion")
                ShortcutRow(keys: ["esc"], text: "Dismiss it")
                ShortcutRow(keys: ["⌃", "⌥", "F"], text: "Check the current field right now")
                if !state.isAccessibilityGranted || !state.model.isReady {
                    Label(state.isAccessibilityGranted
                          ? "The model is still downloading. Typhon starts as soon as it's ready."
                          : "Typhon needs Accessibility access. You can finish this from the menu bar.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: 400)
            .padding(18)
            .card(cornerRadius: 18)
        } actions: {
            Button("Start Typing", action: finish)
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct ShortcutRow: View {
    let keys: [String]
    let text: String

    var body: some View {
        HStack {
            Text(text)
            Spacer()
            KeyCaps(keys: keys)
        }
    }
}
