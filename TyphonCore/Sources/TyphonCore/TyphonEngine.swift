import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Synchronization
import Tokenizers

/// The exact prompt format Typhon was trained on.
public enum TyphonPrompt {
    public static func make(_ text: String) -> String { "Polish: \(text)\nOut: " }
    public static let eosTokenID = 7
    public static let maxNewTokens = 160
}

public enum EngineError: Error, LocalizedError {
    case notLoaded
    case stale

    public var errorDescription: String? {
        switch self {
        case .notLoaded: "The model isn't loaded yet."
        case .stale: "A newer request replaced this one."
        }
    }
}

public struct Polished: Sendable, Equatable {
    public let input: String
    public let output: String
    public let milliseconds: Double
    public let tokens: Int
    public let usedDrafter: Bool
}

/// Keeps Typhon loaded and warm, and runs one request at a time.
///
/// Every call to ``polish(_:)`` supersedes the previous one: a request that is
/// still queued or generating stops at its next token as soon as a newer one
/// arrives, so the caller always gets the freshest answer quickly.
public final class TyphonEngine: Sendable {
    private final class Generation: Sendable {
        let value = Atomic<UInt64>(0)
    }
    private let latest = Generation()
    private let worker = Worker()

    public init() {}

    /// Loads the model (and the optional DSpark drafter) and runs a warm-up pass.
    public func load(modelDirectory: URL, drafterDirectory: URL?) async throws {
        try await worker.load(modelDirectory: modelDirectory, drafterDirectory: drafterDirectory)
    }

    public func unload() async { await worker.unload() }

    public var isLoaded: Bool { get async { await worker.isLoaded } }
    public var hasDrafter: Bool { get async { await worker.hasDrafter } }

    /// Enables or disables speculative decoding without reloading the target model.
    public func setDrafterEnabled(_ enabled: Bool) async { await worker.setDrafterEnabled(enabled) }

    /// Fixes `text`. Throws ``EngineError/stale`` if a newer request arrived first.
    public func polish(_ text: String, maxNewTokens: Int = TyphonPrompt.maxNewTokens) async throws -> Polished {
        let latest = self.latest
        let id = latest.value.add(1, ordering: .sequentiallyConsistent).newValue
        return try await worker.run(text: text, maxNewTokens: maxNewTokens) {
            latest.value.load(ordering: .relaxed) != id || Task.isCancelled
        }
    }

    /// Marks every in-flight request as stale (e.g. the user kept typing).
    public func cancelAll() {
        latest.value.add(1, ordering: .sequentiallyConsistent)
    }
}

private actor Worker {
    private var context: ModelContext?
    private var drafter: (any MTPDrafterModel)?
    private var drafterEnabled = true

    var isLoaded: Bool { context != nil }
    var hasDrafter: Bool { drafter != nil && drafterEnabled }

    func setDrafterEnabled(_ enabled: Bool) { drafterEnabled = enabled }

    func load(modelDirectory: URL, drafterDirectory: URL?) async throws {
        // Keep MLX's buffer cache small: we run short bursts, and idle memory matters
        // more than shaving an allocation off each request.
        Memory.cacheLimit = 128 * 1024 * 1024

        let context = try await LLMModelFactory.shared.load(
            from: modelDirectory, using: TransformersTokenizerLoader())
        self.context = context

        if let drafterDirectory {
            let model = try Self.loadDrafter(from: drafterDirectory)
            try model.validateCompatibility(with: context.model)
            self.drafter = model
        }

        // Warm up both paths so the first real request doesn't pay for kernel compilation.
        _ = try run(text: "warm up teh model", maxNewTokens: 16) { false }
        if drafter != nil {
            drafterEnabled.toggle()
            _ = try run(text: "warm up teh model", maxNewTokens: 16) { false }
            drafterEnabled.toggle()
        }
    }

    /// Loads Typhon's DSpark drafter. The released checkpoint was fine-tuned without the
    /// confidence head (it is never used while drafting), so we fill that head with zeros
    /// instead of failing strict weight verification, then quantize like the reference
    /// implementation (4-bit, group size 64).
    private static func loadDrafter(from directory: URL) throws -> LFM2DSparkDraftModel {
        let configData = try Data(contentsOf: directory.appending(path: "config.json"))
        let configuration = try JSONDecoder().decode(LFM2DSparkConfiguration.self, from: configData)
        try configuration.validateModelConfiguration()
        let model = LFM2DSparkDraftModel(configuration)

        var weights = try loadArrays(url: directory.appending(path: "model.safetensors"))
        let parameters = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
        for key in ["confidence_head.proj.weight", "confidence_head.proj.bias"] where weights[key] == nil {
            if let shape = parameters[key]?.shape { weights[key] = MLXArray.zeros(shape, dtype: .bfloat16) }
        }
        weights = model.sanitize(weights: weights)
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])

        quantize(model: model, groupSize: 64, bits: 4) { _, layer in
            if let linear = layer as? Linear { return linear.weight.dim(-1) % 64 == 0 }
            if let embedding = layer as? Embedding { return embedding.weight.dim(-1) % 64 == 0 }
            return false
        }
        eval(model.parameters())
        return model
    }

    func unload() {
        context = nil
        drafter = nil
        Memory.clearCache()
    }

    func run(text: String, maxNewTokens: Int, isStale: () -> Bool) throws -> Polished {
        guard let context else { throw EngineError.notLoaded }
        if isStale() { throw EngineError.stale }

        let start = ContinuousClock.now
        let promptTokens = context.tokenizer.encode(text: TyphonPrompt.make(text), addSpecialTokens: true)
        let input = LMInput(tokens: MLXArray(promptTokens))
        let parameters = GenerateParameters(maxTokens: maxNewTokens, temperature: 0)

        var output: [Int] = []
        let useDrafter = drafter != nil && drafterEnabled

        func consume<I: TokenIteratorProtocol>(_ iterator: inout I) throws {
            while let token = iterator.next() {
                if token == TyphonPrompt.eosTokenID { break }
                output.append(token)
                if output.count >= maxNewTokens { break }
                if isStale() { throw EngineError.stale }
            }
        }

        if useDrafter, let drafter {
            var iterator = try MTPSpeculativeTokenIterator(
                input: input, mainModel: context.model, drafter: drafter,
                parameters: parameters, blockSize: 5)
            try consume(&iterator)
        } else {
            var iterator = try TokenIterator(input: input, model: context.model, parameters: parameters)
            try consume(&iterator)
        }

        var decoded = context.tokenizer.decode(tokenIds: output, skipSpecialTokens: false)
        if let end = decoded.range(of: "<|im_end|>") { decoded = String(decoded[..<end.lowerBound]) }
        let elapsed = ContinuousClock.now - start
        return Polished(
            input: text,
            output: decoded.trimmingCharacters(in: .whitespacesAndNewlines),
            milliseconds: Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000,
            tokens: output.count,
            usedDrafter: useDrafter)
    }
}

/// Bridges swift-transformers' tokenizer to MLXLMCommon without macros.
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
