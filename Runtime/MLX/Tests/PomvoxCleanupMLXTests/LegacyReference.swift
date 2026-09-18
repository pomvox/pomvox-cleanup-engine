// Test-only reference from Pomvox 8d693ad. MIT. Directory-only preparation replaces downloads.
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMTokenizers
@testable import PomvoxCleanupMLX

private enum FrozenPromptError: Error { case unreadable(String) }
enum CleanupDecoding { case library, greedyLoop, speculative }
actor LegacyReference {
    private var container: ModelContainer?
    private var prefixCaches: [String: PrefixEntry] = [:]
    private var prefixKey: PrefixCacheKey?
    private var prefixAttempted: Set<String> = []
    private var pendingCleans = 0
    private var preparing = false
    private var profile: CleanupPromptProfile = .simpleWords
    private var frozenSystem: String?
    private var termsHint = ""
    private var loadedModelID: String?
    private let decoding: CleanupDecoding = .speculative
    private(set) var lastGenStats: CleanupGenStats?

    func prepare(directory: URL, cached: Bool) async throws {
        frozenSystem = try String(contentsOf: directory.appendingPathComponent("system_v2.txt"), encoding: .utf8)
        container = try await LLMModelFactory.shared.loadContainer(from: directory, using: TokenizersLoader())
        if cached { await buildPrefixCaches() }
        else { prefixAttempted = ["*"] }
        _ = try await clean("um hello", style: "polish", timeoutS: 120)
    }
    func unload() { container = nil; prefixCaches = [:]; Memory.clearCache() }
    private final class PrefixEntry: @unchecked Sendable {
        let prefix: [Int]
        let cache: [KVCache]
        init(prefix: [Int], cache: [KVCache]) {
            self.prefix = prefix
            self.cache = cache
        }
    }

    private enum PrefixCacheError: Error {
        /// No layer reached the prefix length, or one overshot it. With a
        /// sampling-free prefill this should be unreachable; it stays as the
        /// assertion that the cache really does hold the prefix and nothing
        /// more, since a silently-wrong cache changes output rather than
        /// failing. (`notTrimmable` retired with the `TokenIterator` prefill —
        /// there is no overshoot left to trim.)
        case unexpectedOffset(got: Int, want: Int)
    }


    private func buildPrefixCaches(
        _ keys: [String]? = nil, yieldToCleans: Bool = false
    ) async {
        // `container.perform`'s closure is @Sendable, so hoist the actor state
        // the renders need into locals before the loop.
        let profile = self.profile
        let frozen = frozenSystem
        let keys = keys ?? profile.prefixKeys
        let hint = termsHint
        for key in keys {
            if yieldToCleans {
                while pendingCleans > 0 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            guard let container = self.container else { return }
            do {
                let entry: PrefixEntry = try await container.perform { context in
                    let a = try await Self.renderTokens(
                        context, text: "placeholder one", style: key, termsHint: hint,
                        profile: profile, frozenSystem: frozen)
                    let b = try await Self.renderTokens(
                        context, text: "a different text entirely", style: key, termsHint: hint,
                        profile: profile, frozenSystem: frozen)
                    let prefix = Array(a.prefix(CleanupLogic.commonPrefixLen(a, b)))
                    // Fill the cache with EXACTLY the prefix, using a plain
                    // forward pass rather than a `TokenIterator`.
                    //
                    // The iterator samples a token as a side effect, which
                    // advances the cache one token PAST the prefix. On a
                    // homogeneous attention model that overshoot is trimmable;
                    // on a hybrid it is not, because a linear-attention layer
                    // holds a running recurrence rather than per-token history —
                    // there is no last entry to drop. Reading without sampling
                    // means there is no overshoot to undo in the first place.
                    //
                    // This is what the model's own prefill does per chunk
                    // (`LLMModel.prepare`); its `withPreparedCache(lengths:)`
                    // wrapper is a no-op for a single unbatched sequence.
                    let cache = context.model.newCache(parameters: nil)
                    let ids = MLXArray(prefix.map(Int32.init)).reshaped([1, prefix.count])
                    _ = context.model(ids, cache: cache)
                    // Hybrid-safe offset check. Full-attention layers advance
                    // `offset`; linear-attention layers never do and report 0
                    // forever, which is correct for them and not a failure. The
                    // old check read `cache.first?.offset` — layer 0 here is
                    // linear, so it always saw 0 against a wanted ~265 and threw
                    // `unexpectedOffset` before caching could ever engage.
                    // Accept only the two legitimate answers, and require that
                    // at least one layer genuinely counted (so a model whose
                    // every layer reported 0 can't pass as "cached").
                    let offsets = cache.map(\.offset)
                    guard offsets.contains(prefix.count),
                        offsets.allSatisfy({ $0 == 0 || $0 == prefix.count })
                    else {
                        throw PrefixCacheError.unexpectedOffset(
                            got: offsets.max() ?? 0, want: prefix.count)
                    }
                    // `perform` requires arrays evaluated before they leave.
                    eval(cache.flatMap { $0.innerState() })
                    return PrefixEntry(prefix: prefix, cache: cache)
                }
                prefixCaches[key] = entry
                NSLog("cleanup: cached %d-token prefix for style=%@", entry.prefix.count, key)
            } catch {
                NSLog(
                    "cleanup: prefix cache failed for style=%@ (%@) — running uncached",
                    key, String(describing: error))
            }
            prefixAttempted.insert(key)
        }
        prefixKey = PrefixCacheKey(modelID: loadedModelID ?? "", hint: hint)
    }

    /// Generate cleaned text, or `nil` on deadline / model not ready.
    func clean(_ text: String, style: String, timeoutS: Double) async throws -> String? {
        pendingCleans += 1
        defer { pendingCleans -= 1 }
        let entered = CFAbsoluteTimeGetCurrent()
        var deadline = entered + timeoutS
        // A post-eviction dictation races the reload its own key-up fired
        // (ensureCleanupLoaded is fire-and-forget): the container is nil for
        // the ~1 s the weights take to come back, and bailing immediately
        // pasted raw after every idle gap. Wait out an in-flight load within
        // this utterance's own deadline (plus a short grace for a load that
        // hasn't reached the actor yet); the actor suspends here, so the
        // loading prepare() makes progress between polls.
        while CleanupResidency.shouldAwaitLoad(
            loaded: container != nil, loading: preparing,
            now: CFAbsoluteTimeGetCurrent(), deadline: deadline, entered: entered)
        {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // Credit the reload back. This utterance did not spend that time
        // generating, and charging it for the weights is what made a post-idle
        // dictation strictly likelier to paste raw than an identical warm one:
        // on-device the two differ ONLY by this ~1.8 s intercept (identical
        // per-character slopes — see `CleanupDeadline`). The credit is capped,
        // so a pathological load still cannot extend the deadline without
        // bound, and `cleanupWithWatchdog` allows for the same cap.
        // (The warm path falls straight through the loop above, so `waited` is
        // microseconds and nothing is credited or logged.)
        let credit = CleanupDeadline.reloadCreditS(waited: CFAbsoluteTimeGetCurrent() - entered)
        if credit > 0.05 {
            deadline += credit
            NSLog("cleanup: waited %.1fs for reload — credited to the deadline", credit)
        }
        guard let container else {
            NSLog(
                "cleanup: model not loaded%@, skipping",
                preparing ? " within the deadline" : " (no load in flight)")
            return nil
        }
        // Cold launch: this style's prefix may still be prefilling on the same
        // serial GPU queue. An uncached generation would queue BEHIND that
        // prefill and then re-prefill the whole prompt itself — rc.1's first
        // dictation burned 12.9s that way and pasted raw. Waiting for the
        // cache (while the deadline still leaves room to generate) turns that
        // into prefill-once-then-cached-gen.
        //
        // Snapshot the prompt recipe HERE, in the same suspension-free stretch
        // as the container guard above. `container` is what makes the pair safe
        // to read, NOT the assignment order: `prepare()` sets `frozenSystem`
        // *before* it awaits `loadContainer`, so for the whole load it is already
        // the incoming model's prompt while `profile` still describes the old
        // one — but `container` is nil across that entire window, so the guard
        // above has already bailed. Only after the load do `container`,
        // `loadedModelID`, `profile` and `loadGeneration` publish together with
        // no await between them, and that is the state this reads. Anything
        // that reorders `prepare()` must preserve that: keep all four
        // assignments in one suspension-free stretch, with no `await` among
        // them, so a `clean()` reading them sees either all-old or all-new —
        // never a mix. (The waits below suspend, so a reload could otherwise
        // split the pair.)
        let profile = self.profile
        let frozen = frozenSystem
        let prefixKeyForStyle = profile.prefixKey(forStyle: style)
        while CleanupResidency.shouldAwaitStylePrefix(
            cached: prefixCaches[prefixKeyForStyle] != nil,
            attempted: prefixAttempted.contains(prefixKeyForStyle),
            loading: preparing,
            now: CFAbsoluteTimeGetCurrent(), deadline: deadline)
        {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // The STT pass that just ran leaves the MLX buffer pool full of
        // Parakeet-shaped buffers, which slowed the first generation by ~0.5s
        // in the Python engine (ARCHITECTURE.md). Dropping the pool is cheaper;
        // the next recording re-allocates off the stop-to-text critical path.
        Memory.clearCache()
        let cached = prefixCaches[prefixKeyForStyle]
        let hint = termsHint
        let decoding = self.decoding

        let (text, stats): (String?, CleanupGenStats?) = try await container.perform { context in
            var tokens = try await Self.renderTokens(
                context, text: text, style: style, termsHint: hint,
                profile: profile, frozenSystem: frozen)
            // Reuse the prefilled static prefix: feed only the suffix tokens
            // with a copy of its KV cache (the deepcopy-per-request from
            // cleanup.py — `copy()` re-materializes, later updates never touch
            // the original). Falls through to the full prompt when unavailable.
            var cache: [KVCache]? = nil
            if let cached, tokens.count > cached.prefix.count,
                Array(tokens.prefix(cached.prefix.count)) == cached.prefix
            {
                tokens = Array(tokens.dropFirst(cached.prefix.count))
                cache = cached.cache.map { $0.copy() }
            }
            let maxTokens = max(64, min(2 * context.tokenizer.encode(text: text).count, 1024))

            if decoding != .library {
                return Self.generateInLoop(
                    context, tokens: tokens, cache: cache, text: text,
                    speculative: decoding == .speculative, maxTokens: maxTokens,
                    deadline: deadline, timeoutS: timeoutS)
            }

            let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.0)

            let stream = try MLXLMCommon.generate(
                input: LMInput(tokens: MLXArray(tokens.map(Int32.init))),
                cache: cache, parameters: params, context: context)
            let tGen = CFAbsoluteTimeGetCurrent()
            var parts: [String] = []
            var stats: CleanupGenStats?
            for await generation in stream {
                switch generation {
                case .chunk(let piece):
                    parts.append(piece)
                    if CFAbsoluteTimeGetCurrent() > deadline {
                        // Returning ends stream consumption; the generation
                        // task is cancelled via the stream's onTermination.
                        NSLog("cleanup: deadline %.1fs hit, falling back to raw", timeoutS)
                        return (nil, nil)
                    }
                case .info(let info):
                    var s = CleanupGenStats()
                    s.promptTokens = info.promptTokenCount
                    s.prefillMs = info.promptTime * 1000
                    s.decodeTokens = info.generationTokenCount
                    s.decodeMs = info.generateTime * 1000
                    s.cached = cache != nil
                    stats = s
                    // A legit cleanup is at most ~input-sized; hitting the
                    // 2x-input cap means a runaway (echo, analysis, invention)
                    // that was truncated — rc.1 pasted one mid-sentence. Raw
                    // is always the better paste.
                    if info.generationTokenCount >= maxTokens {
                        NSLog(
                            "cleanup: hit the %d-token cap — runaway output, falling back to raw",
                            maxTokens)
                        return (nil, stats)
                    }
                    NSLog(
                        "cleanup: gen %.2fs prefill=%dtok@%.0ftps decode=%dtok@%.1ftps cached=%@",
                        CFAbsoluteTimeGetCurrent() - tGen,
                        info.promptTokenCount, info.promptTokensPerSecond,
                        info.generationTokenCount, info.tokensPerSecond,
                        cache == nil ? "no" : "prefix")
                default:
                    break
                }
            }
            return (parts.joined(), stats)
        }
        if let stats { lastGenStats = stats }
        return text
    }

    /// Run one cleanup generation through `SpeculativeDecoder` (with or
    /// without drafts) and turn its stop reason into `clean()`'s contract:
    /// text on a clean EOS, `nil` on the deadline or the runaway cap.
    private static func generateInLoop(
        _ context: ModelContext, tokens: [Int], cache: [KVCache]?, text: String,
        speculative: Bool, maxTokens: Int, deadline: Double, timeoutS: Double
    ) -> (String?, CleanupGenStats?) {
        let tGen = CFAbsoluteTimeGetCurrent()
        let drafter = speculative ? PromptLookupDrafter() : nil
        // The drafter's lookup table: the transcript as the tokenizer sees it
        // on its own (no chat-template neighbours). Boundary tokens can differ
        // from the in-prompt encoding; the n-gram search does not care.
        let lookup = speculative ? context.tokenizer.encode(text: text, addSpecialTokens: false) : []
        let result = SpeculativeDecoder.generate(
            model: context.model, prompt: tokens, cache: cache, lookup: lookup,
            drafter: drafter, maxTokens: maxTokens,
            stopTokens: stopTokenIds(context), deadline: deadline, cached: cache != nil)
        let stats = result.stats
        switch result.stop {
        case .deadline:
            NSLog("cleanup: deadline %.1fs hit, falling back to raw", timeoutS)
            return (nil, stats)
        case .cap:
            // Same rule as the library path: a legit cleanup is at most
            // ~input-sized, so the 2x cap means a runaway that was truncated.
            NSLog(
                "cleanup: hit the %d-token cap — runaway output, falling back to raw",
                maxTokens)
            return (nil, stats)
        case .eos:
            break
        }
        let spec = stats.specDrafted > 0
            ? String(
                format: " spec=%d/%d rounds=%d", stats.specAccepted, stats.specDrafted,
                stats.specRounds)
            : (speculative ? " spec=0/0" : "")
        NSLog(
            "cleanup: gen %.2fs prefill=%dtok@%.0ftps decode=%dtok@%.1ftps cached=%@%@",
            CFAbsoluteTimeGetCurrent() - tGen,
            stats.promptTokens, stats.prefillTokensPerSecond,
            stats.decodeTokens, stats.decodeTokensPerSecond,
            cache == nil ? "no" : "prefix", spec)
        let out = context.tokenizer.decode(tokenIds: result.tokens, skipSpecialTokens: true)
        return (out, stats)
    }

    /// Every id that ends a generation — the same set `MLXLMCommon.generate`
    /// builds (its helper is private): the configuration's EOS ids, the
    /// tokenizer's EOS, any extra EOS strings, and the unknown token.
    private static func stopTokenIds(_ context: ModelContext) -> Set<Int> {
        var ids = context.configuration.eosTokenIds
        if let eos = context.tokenizer.eosTokenId { ids.insert(eos) }
        for token in context.configuration.extraEOSTokens {
            if let id = context.tokenizer.convertTokenToId(token) { ids.insert(id) }
        }
        if let unk = context.tokenizer.unknownTokenId { ids.insert(unk) }
        return ids
    }


    private static func renderTokens(
        _ context: ModelContext, text: String, style: String, termsHint: String,
        profile: CleanupPromptProfile, frozenSystem: String?
    ) async throws -> [Int] {
        let messages: [ChatMessage]
        switch profile {
        case .legacy:
            messages = CleanupLogic.buildMessages(
                text: text, style: style, termsHint: termsHint)
        case .simpleWords:
            // prepare() cannot leave the container loaded without this, but
            // throwing beats silently prompting the fine-tune with bare text:
            // runCleanup turns the throw into a raw paste.
            guard let frozenSystem else {
                throw FrozenPromptError.unreadable("<not loaded>")
            }
            messages = CleanupLogic.buildSimpleWordsMessages(
                text: text, system: frozenSystem, termsHint: termsHint)
        }
        let lmInput = try await context.processor.prepare(
            input: UserInput(
                chat: toChat(messages), additionalContext: ["enable_thinking": false]))
        return lmInput.text.tokens.asArray(Int.self)
    }

    private static func toChat(_ messages: [ChatMessage]) -> [Chat.Message] {
        messages.map { message in
            switch message.role {
            case "system": return .system(message.content)
            case "assistant": return .assistant(message.content)
            default: return .user(message.content)
            }
        }
    }
}
