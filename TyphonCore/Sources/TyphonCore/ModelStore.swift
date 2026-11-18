import CryptoKit
import Foundation

/// One file in the Hugging Face repo. Large files carry their LFS SHA-256 so we can verify them.
public struct ModelFile: Sendable, Hashable {
    public let path: String
    public let size: Int64
    public let sha256: String?
}

/// Pinned to an exact revision so an upstream change can never silently swap the weights.
public enum ModelManifest {
    public static let repo = "dennny123/Typhon-1.2B-MLX-4bit"
    public static let revision = "6448ff4c2db9c5b697042bc213f444e149c49897"

    public static let core: [ModelFile] = [
        .init(path: "config.json", size: 1647, sha256: nil),
        .init(path: "generation_config.json", size: 132, sha256: nil),
        .init(path: "tokenizer.json", size: 4_733_020, sha256: nil),
        .init(path: "tokenizer_config.json", size: 552, sha256: nil),
        .init(path: "chat_template.jinja", size: 1296, sha256: nil),
        .init(path: "LICENSE", size: 10596, sha256: nil),
        .init(path: "model.safetensors", size: 658_540_250,
              sha256: "38efcf6bd5bda70b3edef1a3e99bb8da5868701fae8aa32336d5c7a8f42b1e7f"),
    ]

    /// The optional DSpark drafter used for speculative decoding.
    public static let drafter: [ModelFile] = [
        .init(path: "dspark/config.json", size: 825, sha256: nil),
        .init(path: "dspark/model.safetensors", size: 591_453_608,
              sha256: "86c74bbaea6e60eb76b25e0bcb3f7c50b5300fb5d410ef0d1c3b0f6b2cc4609f"),
    ]

    static func url(for file: ModelFile) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
    }
}

public struct DownloadProgress: Sendable, Equatable {
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double

    public init(completedBytes: Int64, totalBytes: Int64, bytesPerSecond: Double) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    public var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
}

public enum ModelStoreError: LocalizedError {
    case badStatus(Int, String)
    case checksumMismatch(String)
    case sizeMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code, let file): "Hugging Face returned HTTP \(code) for \(file)."
        case .checksumMismatch(let file): "\(file) didn't match its checksum. It will be downloaded again."
        case .sizeMismatch(let file): "\(file) has an unexpected size. It will be downloaded again."
        }
    }
}

/// Downloads Typhon into `~/Library/Application Support/Typhon/<repo>@<revision>`.
///
/// Files land as `.part` first and are resumed with HTTP range requests if the app quits or the
/// network drops. Large files are SHA-256 verified before they're moved into place.
public final class ModelStore: Sendable {
    public let directory: URL

    public init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Typhon", directoryHint: .isDirectory)
        directory = base.appending(
            path: "\(ModelManifest.repo.replacingOccurrences(of: "/", with: "--"))@\(ModelManifest.revision.prefix(12))",
            directoryHint: .isDirectory)
    }

    public var drafterDirectory: URL { directory.appending(path: "dspark", directoryHint: .isDirectory) }

    public func isInstalled(_ files: [ModelFile]) -> Bool {
        files.allSatisfy { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: localURL(file).path)
            return (attributes?[.size] as? NSNumber)?.int64Value == file.size
        }
    }

    public var hasCore: Bool { isInstalled(ModelManifest.core) }
    public var hasDrafter: Bool { isInstalled(ModelManifest.drafter) }

    /// Bytes already on disk (finished or partial) for the given files.
    public func bytesOnDisk(_ files: [ModelFile]) -> Int64 {
        files.reduce(0) { sum, file in
            let finished = fileSize(localURL(file))
            return sum + (finished == file.size ? finished : fileSize(partURL(file)))
        }
    }

    public func remove() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public func removeDrafter() throws {
        if FileManager.default.fileExists(atPath: drafterDirectory.path) {
            try FileManager.default.removeItem(at: drafterDirectory)
        }
    }

    /// Downloads every missing file. Safe to call again after a failure or cancellation:
    /// it picks up where it stopped.
    public func download(
        _ files: [ModelFile],
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        let total = files.reduce(0) { $0 + $1.size }
        let meter = ThroughputMeter(start: bytesOnDisk(files))
        progress(.init(completedBytes: meter.start, totalBytes: total, bytesPerSecond: 0))

        for file in files where fileSize(localURL(file)) != file.size {
            try Task.checkCancellation()
            let alreadyDone = files.filter { $0 != file }.reduce(Int64(0)) { sum, other in
                fileSize(localURL(other)) == other.size ? sum + other.size : sum + fileSize(partURL(other))
            }
            do {
                try await fetch(file) { fileBytes in
                    let done = alreadyDone + fileBytes
                    progress(.init(completedBytes: done, totalBytes: total, bytesPerSecond: meter.rate(done)))
                }
            } catch let error as ModelStoreError {
                // A corrupt partial file can't be resumed; start that file over next time.
                try? FileManager.default.removeItem(at: partURL(file))
                throw error
            }
        }
        progress(.init(completedBytes: total, totalBytes: total, bytesPerSecond: 0))
    }

    // MARK: - Private

    private func localURL(_ file: ModelFile) -> URL { directory.appending(path: file.path) }
    private func partURL(_ file: ModelFile) -> URL { directory.appending(path: file.path + ".part") }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func fetch(_ file: ModelFile, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let part = partURL(file)
        try FileManager.default.createDirectory(
            at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        var offset = fileSize(part)
        if offset > file.size {
            try FileHandle(forWritingTo: part).truncate(atOffset: 0)
            offset = 0
        }

        if offset < file.size {
            var request = URLRequest(url: ModelManifest.url(for: file))
            request.setValue("Typhon (macOS)", forHTTPHeaderField: "User-Agent")
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            try await ChunkedDownload(request: request, destination: part, offset: offset, name: file.path)
                .run(progress: progress)
        }

        guard fileSize(part) == file.size else { throw ModelStoreError.sizeMismatch(file.path) }
        if let expected = file.sha256 {
            let actual = try Self.sha256(of: part)
            guard actual == expected else { throw ModelStoreError.checksumMismatch(file.path) }
        }
        let destination = localURL(file)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: part, to: destination)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class ThroughputMeter: @unchecked Sendable {
    let start: Int64
    private let lock = NSLock()
    private var samples: [(time: TimeInterval, bytes: Int64)] = []

    init(start: Int64) { self.start = start }

    /// Average speed over the last few seconds.
    func rate(_ bytes: Int64) -> Double {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            samples.append((now, bytes))
            samples.removeAll { now - $0.time > 3 }
            guard let first = samples.first, now - first.time > 0.25 else { return 0 }
            return Double(bytes - first.bytes) / (now - first.time)
        }
    }
}

/// Streams one HTTP response into a file, appending at `offset`.
private final class ChunkedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let destination: URL
    private let name: String
    private var offset: Int64
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var progress: (@Sendable (Int64) -> Void)?
    private var lastReport: TimeInterval = 0

    init(request: URLRequest, destination: URL, offset: Int64, name: String) {
        self.request = request
        self.destination = destination
        self.offset = offset
        self.name = name
    }

    func run(progress: @escaping @Sendable (Int64) -> Void) async throws {
        self.progress = progress
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            let handle = try FileHandle(forWritingTo: destination)
            switch status {
            case 206:
                try handle.seek(toOffset: UInt64(offset))
            case 200:
                // The server ignored our range; start this file from scratch.
                try handle.truncate(atOffset: 0)
                offset = 0
            default:
                throw ModelStoreError.badStatus(status, name)
            }
            self.handle = handle
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            offset += Int64(data.count)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastReport > 0.1 {
                lastReport = now
                progress?(offset)
            }
        } catch {
            dataTask.cancel()
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        progress?(offset)
        if let urlError = error as? URLError, urlError.code == .cancelled {
            finish(CancellationError())
        } else {
            finish(error)
        }
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
