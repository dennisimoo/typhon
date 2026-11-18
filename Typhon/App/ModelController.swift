import Foundation
import Observation
import TyphonCore

/// Owns the model files and the loaded engine.
@Observable
final class ModelController {
    enum Phase: Equatable {
        case missing
        case downloading(DownloadProgress)
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .missing
    private(set) var drafterActive = false
    private(set) var lastLatency: Double?

    let engine = TyphonEngine()
    let store = ModelStore()
    private let preferences: Preferences
    private var task: Task<Void, Never>?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    var isReady: Bool { phase == .ready }
    var isBusy: Bool {
        switch phase {
        case .downloading, .loading: true
        default: false
        }
    }

    var progress: DownloadProgress? {
        if case .downloading(let progress) = phase { return progress }
        return nil
    }

    private var wantedFiles: [ModelFile] {
        ModelManifest.core + (preferences.useDrafter ? ModelManifest.drafter : [])
    }

    var downloadSize: Int64 { wantedFiles.reduce(0) { $0 + $1.size } }
    var isDownloaded: Bool { store.isInstalled(wantedFiles) }

    /// Loads the model if it's on disk; downloads only when `download` is true.
    func prepare(download: Bool) {
        guard task == nil, phase != .ready else { return }
        let files = wantedFiles
        if !download, !store.isInstalled(files) {
            // Use whatever is on disk (e.g. the model without the optional drafter).
            if store.hasCore { load() } else { phase = .missing }
            return
        }
        task = Task {
            defer { task = nil }
            do {
                if !store.isInstalled(files) {
                    phase = .downloading(.init(
                        completedBytes: store.bytesOnDisk(files), totalBytes: downloadSize, bytesPerSecond: 0))
                    try await store.download(files) { progress in
                        Task { @MainActor [weak self] in
                            guard let self, case .downloading = self.phase else { return }
                            self.phase = .downloading(progress)
                        }
                    }
                }
                try await loadEngine()
            } catch is CancellationError {
                phase = store.hasCore ? .loading : .missing
                if store.hasCore { load() }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        task?.cancel()
    }

    /// Switches speculative decoding on or off, downloading the drafter if needed.
    func drafterPreferenceChanged() {
        if preferences.useDrafter, !store.hasDrafter {
            phase = .missing
            Task { await engine.unload(); prepare(download: true) }
        } else if preferences.useDrafter {
            Task { await reload() }
        } else {
            Task {
                await engine.setDrafterEnabled(false)
                drafterActive = false
            }
        }
    }

    func reload() async {
        await engine.unload()
        phase = .missing
        load()
    }

    func deleteModel() async {
        task?.cancel()
        await engine.unload()
        try? store.remove()
        phase = .missing
        drafterActive = false
    }

    func record(latency: Double) { lastLatency = latency }

    private func load() {
        guard task == nil else { return }
        task = Task {
            defer { task = nil }
            do { try await loadEngine() } catch { phase = .failed(error.localizedDescription) }
        }
    }

    private func loadEngine() async throws {
        phase = .loading
        let drafter = preferences.useDrafter && store.hasDrafter ? store.drafterDirectory : nil
        try await engine.load(modelDirectory: store.directory, drafterDirectory: drafter)
        drafterActive = await engine.hasDrafter
        phase = .ready
    }
}
