@_exported import PomvoxCleanup
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMTokenizers

extension RuntimeFactory {
    public static var mlx: RuntimeFactory {
        RuntimeFactory(name: "mlx-swift-lm-3.31.4/mlx-0.31.4/speculative") { pack in
            try await MLXRuntime.open(pack: pack)
        }
    }
}

/// One resident allocation per process in this preview. A retained worker retains its lease.
private final class DeviceLease: @unchecked Sendable {
    private static let lock = NSLock()
    private static var occupied = false
    static func acquire() throws -> DeviceLease {
        lock.lock(); defer { lock.unlock() }
        guard !occupied else { throw CleanupError.unavailable("MLX device already has an open cleaner; close it first") }
        occupied = true
        return DeviceLease()
    }
    deinit { Self.lock.lock(); Self.occupied = false; Self.lock.unlock() }
}

enum Decoding { case library, greedy, speculative }

actor MLXRuntime: CleanupRuntime {
    private final class Prefix: @unchecked Sendable {
        let tokens: [Int]
        let cache: [KVCache]
        init(tokens: [Int], cache: [KVCache]) { self.tokens = tokens; self.cache = cache }
    }
    private var lease: DeviceLease?
    private var container: ModelContainer?
    private var prefix: Prefix?
    private let frozen: String
    private let mode: Decoding
    private var active = false
    private(set) var lastStats: CleanupGenStats?
    var hasPrefix: Bool { prefix != nil }

    private init(container: ModelContainer, frozen: String, mode: Decoding, lease: DeviceLease) {
        self.container = container; self.frozen = frozen; self.mode = mode; self.lease = lease
    }

    static func open(pack: ValidatedPack, mode: Decoding = .speculative,
                     prefixDisabled: Bool = false) async throws -> MLXRuntime {
        // Optimized decoding is admitted only for the artifact set covered by our differential.
        // A different model/tokenizer/prompt must earn a new compatibility entry.
        let supported = SupportedBaseline.artifacts
        guard pack.manifest.modelRevision == SupportedBaseline.revision,
              pack.manifest.artifacts.allSatisfy({ supported[$0.path] == $0.sha256 }) else {
            throw CleanupError.incompatible("MLX preview supports only the pinned, differential-tested baseline")
        }
        let lease = try DeviceLease.acquire()
        let frozen = try String(contentsOf: pack.directory.appendingPathComponent("system_v2.txt"), encoding: .utf8)
        // Directory overload and directory-only tokenizer loader. No HubClient/downloader is linked.
        let container = try await LLMModelFactory.shared.loadContainer(from: pack.directory, using: TokenizersLoader())
        let runtime = MLXRuntime(container: container, frozen: frozen, mode: mode, lease: lease)
        do {
            if !prefixDisabled { try await runtime.buildPrefix() }
            let warm = try await runtime.generate(CleanupRequest("um hello"), deadline: .now.advanced(by: .seconds(120)))
            guard warm.candidate != nil else { throw CleanupError.unavailable("model warmup did not complete") }
            return runtime
        } catch { await runtime.close(); throw error }
    }

    private func buildPrefix() async throws {
        guard let container else { throw CleanupError.unavailable("closed") }
        let frozen = self.frozen
        prefix = try await container.perform { context in
            let a = try await Self.render(context, text: "placeholder one", frozen: frozen, hint: "")
            let b = try await Self.render(context, text: "a different text entirely", frozen: frozen, hint: "")
            let tokens = Array(a.prefix(CleanupLogic.commonPrefixLen(a, b)))
            guard !tokens.isEmpty else { throw CleanupError.unavailable("empty model prefix") }
            let cache = context.model.newCache(parameters: nil)
            // Sampling-free prefill: recurrent layers cannot trim an overshot token.
            _ = context.model(MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count]), cache: cache)
            let offsets = cache.map(\.offset)
            guard offsets.contains(tokens.count), offsets.allSatisfy({ $0 == 0 || $0 == tokens.count }) else {
                throw CleanupError.unavailable("hybrid prefix offsets failed validation")
            }
            eval(cache.flatMap { $0.innerState() })
            return Prefix(tokens: tokens, cache: cache)
        }
    }

    func generate(_ request: CleanupRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput {
        guard let container else { return RuntimeOutput(candidate: nil, failure: .unavailable) }
        guard !active else { return RuntimeOutput(candidate: nil, failure: .busy) }
        active = true
        defer { active = false }
        try Task.checkCancellation()
        let remaining = ContinuousClock.now.duration(to: deadline).milliseconds / 1_000
        guard remaining > 0 else { return RuntimeOutput(candidate: nil, failure: .timedOut) }
        let wallDeadline = CFAbsoluteTimeGetCurrent() + remaining
        let frozen = self.frozen, prefix = self.prefix, mode = self.mode
        let terms = request.vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let hint = terms.isEmpty ? "" : "- Keep these terms spelled exactly as written when you hear them "
            + "(match phonetically, fix the spelling): " + terms.joined(separator: ", ") + ".\n"
        Memory.clearCache()
        let (output, stats): (RuntimeOutput, CleanupGenStats) = try await container.perform { context in
            let tokenStart = ContinuousClock.now
            var tokens = try await Self.render(context, text: request.text, frozen: frozen, hint: hint)
            var cache: [KVCache]?
            if let prefix, tokens.count > prefix.tokens.count,
               Array(tokens.prefix(prefix.tokens.count)) == prefix.tokens {
                tokens = Array(tokens.dropFirst(prefix.tokens.count))
                cache = prefix.cache.map { $0.copy() }
            }
            let maxTokens = max(64, min(2 * context.tokenizer.encode(text: request.text).count, 1024))
            var timings = CleanupTimings()
            timings.tokenizationMS = tokenStart.duration(to: .now).milliseconds
            var stats = CleanupGenStats()
            let text: String?
            let failure: FallbackReason?
            if mode == .library {
                // Decode complete token sequences. Streaming string chunks can split an
                // extended grapheme and silently drop its later scalars (e.g. 👩🏽‍💻).
                let (stream, generationTask) = try MLXLMCommon.generateTokensTask(input: LMInput(tokens: MLXArray(tokens.map(Int32.init))),
                    cache: cache, parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0), context: context)
                var generated: [Int] = []
                var failed: FallbackReason?
                for await generation in stream {
                    if Task.isCancelled || ContinuousClock.now >= deadline { failed = .timedOut; break }
                    switch generation {
                    case .token(let token): generated.append(token)
                    case .info(let info):
                        stats.promptTokens = info.promptTokenCount; stats.prefillMs = info.promptTime * 1_000
                        stats.decodeTokens = info.generationTokenCount; stats.decodeMs = info.generateTime * 1_000
                        stats.cached = cache != nil
                        if info.generationTokenCount >= maxTokens { failed = .tokenLimit }
                    }
                }
                // Never release the container/caches while the library worker is live.
                if failed != nil || Task.isCancelled { generationTask.cancel() }
                await generationTask.value
                text = failed == nil ? context.tokenizer.decode(tokenIds: generated, skipSpecialTokens: true) : nil
                failure = failed
            } else {
                let speculative = mode == .speculative
                let result = SpeculativeDecoder.generate(model: context.model, prompt: tokens, cache: cache,
                    lookup: speculative ? context.tokenizer.encode(text: request.text, addSpecialTokens: false) : [],
                    drafter: speculative ? PromptLookupDrafter() : nil, maxTokens: maxTokens,
                    stopTokens: Self.stopTokens(context), deadline: wallDeadline, cached: cache != nil)
                stats = result.stats
                switch result.stop {
                case .eos: text = context.tokenizer.decode(tokenIds: result.tokens, skipSpecialTokens: true); failure = nil
                case .cap: text = nil; failure = .tokenLimit
                case .deadline: text = nil; failure = .timedOut
                }
            }
            timings.prefillMS = stats.prefillMs; timings.inferenceMS = stats.decodeMs
            return (RuntimeOutput(candidate: text, failure: failure, timings: timings,
                warnings: cache == nil ? ["prefix-cache-not-used"] : []), stats)
        }
        lastStats = stats
        try Task.checkCancellation()
        return output
    }

    private static func render(_ context: ModelContext, text: String, frozen: String, hint: String) async throws -> [Int] {
        let messages = CleanupLogic.buildSimpleWordsMessages(text: text, system: frozen, termsHint: hint)
        let input = try await context.processor.prepare(input: UserInput(
            chat: messages.map { .user($0.content) }, additionalContext: ["enable_thinking": false]))
        return input.text.tokens.asArray(Int.self)
    }

    private static func stopTokens(_ context: ModelContext) -> Set<Int> {
        var ids = context.configuration.eosTokenIds
        if let eos = context.tokenizer.eosTokenId { ids.insert(eos) }
        for token in context.configuration.extraEOSTokens {
            if let id = context.tokenizer.convertTokenToId(token) { ids.insert(id) }
        }
        if let unknown = context.tokenizer.unknownTokenId { ids.insert(unknown) }
        return ids
    }

    func close() {
        // Session calls close only after its worker returns.
        guard !active else { return }
        prefix = nil; container = nil
        Memory.clearCache()
        lease = nil
    }
}
