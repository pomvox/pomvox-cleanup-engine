import Foundation

/// How a transcript is cleaned, one turn per request.
public struct TranscriptCleanOptions: Sendable {
    /// Passed on every turn's request, exactly as `CleanupRequest.vocabulary`.
    public var vocabulary: [String]
    /// Applied to each turn's accepted output, exactly as `CleanupRequest.transforms`.
    public var transforms: CleanupTransforms
    /// Sizes each turn's deadline by its length. Nil keeps the request's default
    /// budget. A turn the policy calls hopeless is skipped without inference.
    public var turnBudget: CleanupBudgetPolicy?
    /// The host's per-pass base the policy widens from (`CleanupBudgetPolicy.deadline(for:base:)`).
    public var turnBase: Duration
    /// Ceiling for the whole call. Once spent, remaining turns return their
    /// exact bytes as `.fallback(.timedOut)` without inference. Nil: no ceiling;
    /// the per-turn deadlines still bound each request.
    public var overallDeadline: Duration?
    /// Called after each turn with (completed, total). Runs on the caller's task.
    public var progress: (@Sendable (Int, Int) -> Void)?
    /// Opt-in: split a turn longer than `maxSegmentBytes` into several ordinary
    /// requests and reassemble one `TurnResult`. Nil (the default): a turn is one
    /// request, and a turn over the admission limit is skipped unchanged.
    public var segmentation: TurnSegmentation?

    public init(vocabulary: [String] = [], transforms: CleanupTransforms = [],
                turnBudget: CleanupBudgetPolicy? = nil, turnBase: Duration = .seconds(5),
                overallDeadline: Duration? = nil, progress: (@Sendable (Int, Int) -> Void)? = nil,
                segmentation: TurnSegmentation? = nil) {
        self.vocabulary = vocabulary; self.transforms = transforms
        self.turnBudget = turnBudget; self.turnBase = turnBase
        self.overallDeadline = overallDeadline; self.progress = progress
        self.segmentation = segmentation
    }
}

extension Cleaning {
    /// Clean a speaker-attributed transcript one turn per request, in order,
    /// through this cleaner's ordinary admission, guards and fallback.
    ///
    /// Structure is preserved exactly: the result has one `TurnResult` per input
    /// turn with the same speaker and span. A turn that fails any guard, times
    /// out, or is never sent keeps its exact bytes. Turns the model never sees
    /// carry `Provenance.skipped` and a warning naming why:
    /// `transcript-budget-exhausted`, `turn-exceeds-admission-limit`, or
    /// `turn-budget-hopeless`. Cancellation throws and delivers nothing.
    ///
    /// This is a batch call on the same one-request worker as live dictation;
    /// a host should not run it while a dictation is waiting on the cleaner.
    public func clean(_ transcript: Transcript,
                      options: TranscriptCleanOptions = TranscriptCleanOptions()) async throws -> TranscriptResult {
        let started = ContinuousClock.now
        var results: [TurnResult] = []
        results.reserveCapacity(transcript.turns.count)
        try await cleanTurns(transcript, options: options, from: 0) { _, result in results.append(result) }
        try Task.checkCancellation()
        return TranscriptResult(turns: results, elapsedMS: started.duration(to: .now).milliseconds)
    }

    /// The incremental form of `clean(_:options:)`: each turn's result is yielded,
    /// with its index, as soon as it is final. The same loop runs both forms, so
    /// the yielded results are the ones the batch call would return.
    ///
    /// To resume after an interruption, pass the results already accepted for
    /// turns `0..<n` as a `TranscriptCheckpoint`; only turns `n...` are cleaned
    /// and yielded. The checkpoint is refused (`invalidRequest`, or `incompatible`
    /// for another pack) unless it was made for this exact transcript (UTF-8
    /// bytes, speakers and spans), these output-affecting options, and this
    /// cleaner's pack, and every accepted result is consistent with its turn.
    /// `overallDeadline` and `progress` are per call: a resumed call's ceiling
    /// covers only the turns it cleans, and progress counts the accepted turns
    /// as done. Persisting a checkpoint is the host's job.
    ///
    /// Cancelling the consuming task, or stopping the iteration, cancels the turn
    /// in flight; it is never yielded. Turns already yielded stay final.
    public func cleanIncrementally(_ transcript: Transcript,
                                   options: TranscriptCleanOptions = TranscriptCleanOptions(),
                                   resuming checkpoint: TranscriptCheckpoint? = nil)
        -> AsyncThrowingStream<CleanedTurn, any Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    var first = 0
                    if let checkpoint {
                        first = try await self.acceptedCount(checkpoint, transcript: transcript, options: options)
                    }
                    try await self.cleanTurns(transcript, options: options, from: first) { index, result in
                        continuation.yield(CleanedTurn(index: index, result: result))
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// What a checkpoint for this transcript, these options and this cleaner must
    /// carry. Throws `incompatible` if the cleaner reports no pack identity.
    public func checkpointIdentity(for transcript: Transcript,
                                   options: TranscriptCleanOptions = TranscriptCleanOptions()) async throws -> TranscriptCleanIdentity {
        guard let pack = await packIdentity else {
            throw CleanupError.incompatible("this cleaner reports no pack identity, so its transcript results cannot be checkpointed")
        }
        return TranscriptCleanIdentity(transcriptSHA256: TranscriptDigest.transcript(transcript),
                                       turnCount: transcript.turns.count,
                                       optionsSHA256: TranscriptDigest.options(options), pack: pack)
    }

    /// Validates a checkpoint against this call and returns how many leading turns it covers.
    func acceptedCount(_ checkpoint: TranscriptCheckpoint, transcript: Transcript,
                       options: TranscriptCleanOptions) async throws -> Int {
        let expected = try await checkpointIdentity(for: transcript, options: options)
        let found = checkpoint.identity
        guard found.transcriptSHA256 == expected.transcriptSHA256, found.turnCount == expected.turnCount else {
            throw CleanupError.invalidRequest("checkpoint was made for a different transcript")
        }
        guard found.optionsSHA256 == expected.optionsSHA256 else {
            throw CleanupError.invalidRequest("checkpoint was made with different vocabulary, transforms or turn budget")
        }
        guard found.pack == expected.pack else {
            throw CleanupError.incompatible("checkpoint was made with pack \(found.pack.id) \(found.pack.version), this cleaner runs \(expected.pack.id) \(expected.pack.version)")
        }
        guard checkpoint.accepted.count <= transcript.turns.count else {
            throw CleanupError.invalidRequest("checkpoint has more turns than the transcript")
        }
        for (index, accepted) in checkpoint.accepted.enumerated() {
            guard TranscriptDigest.sameTurn(accepted.turn, transcript.turns[index]),
                  TranscriptDigest.isConsistent(accepted.result, source: transcript.turns[index].text, pack: expected.pack) else {
                throw CleanupError.invalidRequest("checkpoint turn \(index) does not match the transcript or is not a valid result for it")
            }
        }
        return checkpoint.accepted.count
    }

    /// The one loop behind the batch and incremental forms, so they cannot diverge.
    /// Cleans turns `first...` in order and hands each result to `emit`.
    func cleanTurns(_ transcript: Transcript, options: TranscriptCleanOptions, from first: Int,
                    emit: (Int, TurnResult) async throws -> Void) async throws {
        let started = ContinuousClock.now
        try Task.checkCancellation()
        try transcript.validate()
        try CleanupRequest("", vocabulary: options.vocabulary).validate()
        if let overall = options.overallDeadline, overall <= .zero {
            throw CleanupError.invalidRequest("overall deadline must be greater than zero")
        }
        try options.segmentation?.validate()
        let ceiling = options.overallDeadline.map { started.advanced(by: $0) }
        let total = transcript.turns.count
        for index in first..<total {
            try Task.checkCancellation()
            let turn = transcript.turns[index]
            let turnStart = ContinuousClock.now
            let result: TurnResult
            if let segmentation = options.segmentation, turn.text.utf8.count > segmentation.maxSegmentBytes {
                result = try await cleanSegments(of: turn, maxBytes: segmentation.maxSegmentBytes,
                                                 options: options, ceiling: ceiling, started: turnStart)
            } else {
                result = TurnResult(turn: turn, result: try await cleanPiece(turn.text, options: options,
                                                                            ceiling: ceiling, started: turnStart))
            }
            try await emit(index, result)
            options.progress?(index + 1, total)
        }
    }

    /// One request for `text` under the options' budget, clamped to the overall
    /// ceiling; or, without inference, its exact bytes with `Provenance.skipped`
    /// and a warning naming why.
    func cleanPiece(_ text: String, options: TranscriptCleanOptions, ceiling: ContinuousClock.Instant?,
                    started: ContinuousClock.Instant) async throws -> CleanupResult {
        func skipped(_ reason: FallbackReason, _ warning: String) -> CleanupResult {
            var timings = CleanupTimings()
            timings.totalMS = started.duration(to: .now).milliseconds
            return CleanupResult(text: text, edits: [], status: .fallback(reason), provenance: .skipped,
                                 timings: timings, warnings: [warning])
        }
        let remaining = ceiling.map { ContinuousClock.now.duration(to: $0) }
        if let remaining, remaining <= .zero { return skipped(.timedOut, "transcript-budget-exhausted") }
        if text.utf8.count > CleanupRequest.maxTextBytes { return skipped(.unavailable, "turn-exceeds-admission-limit") }
        var deadline: Duration
        if let policy = options.turnBudget {
            guard let sized = policy.deadline(for: text, base: options.turnBase) else {
                return skipped(.timedOut, "turn-budget-hopeless")
            }
            deadline = sized
        } else {
            deadline = CleanupRequest(text).budget
        }
        // A timed-out request leaves the worker quarantined until it returns, and
        // anything sent meanwhile falls back at once. Wait for it instead, within
        // this piece's budget and the overall ceiling; never start a second worker.
        if await availability == .quarantined {
            let waitLimit = ContinuousClock.now.advanced(by: remaining.map { min(deadline, $0) } ?? deadline)
            while await availability == .quarantined {
                guard ContinuousClock.now < waitLimit else { return skipped(.unavailable, "cleaner-quarantined") }
                try await Task.sleep(for: .milliseconds(20))
            }
            if let ceiling, ContinuousClock.now >= ceiling { return skipped(.timedOut, "transcript-budget-exhausted") }
        }
        if let ceiling { deadline = min(deadline, ContinuousClock.now.duration(to: ceiling)) }
        deadline = max(.milliseconds(1), min(deadline, .seconds(60)))
        return try await clean(CleanupRequest(text, vocabulary: options.vocabulary,
                                              deadline: deadline, transforms: options.transforms))
    }

    /// Cleans a long turn as segments (`TurnSegmenter`) and reassembles one result:
    /// separators are copied verbatim, each segment's text and edits are placed at
    /// its byte offset, and the turn's status, provenance, timings and warnings
    /// summarize the segments. If no segment was cleaned the result is the exact
    /// input with no edits.
    func cleanSegments(of turn: SpeakerTurn, maxBytes: Int, options: TranscriptCleanOptions,
                       ceiling: ContinuousClock.Instant?, started: ContinuousClock.Instant) async throws -> TurnResult {
        let input = Array(turn.text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var edits: [TextEdit] = []
        var outcomes: [SegmentOutcome] = []
        var results: [CleanupResult] = []
        for piece in TurnSegmenter.split(turn.text, maxBytes: maxBytes) {
            guard piece.isSegment else { output += input[piece.start..<piece.end]; continue }
            try Task.checkCancellation()
            let source = String(decoding: input[piece.start..<piece.end], as: UTF8.self)
            let result = try await cleanPiece(source, options: options, ceiling: ceiling, started: ContinuousClock.now)
            let outputStart = output.count
            output += result.text.utf8
            edits += result.edits.map { TextEdit(start: $0.start + piece.start, end: $0.end + piece.start, replacement: $0.replacement) }
            outcomes.append(SegmentOutcome(sourceStart: piece.start, sourceEnd: piece.end, outputStart: outputStart,
                                           outputEnd: output.count, status: result.status, warnings: result.warnings))
            results.append(result)
        }
        let cleaned = results.contains { $0.status == .cleaned }
        let fallback = results.lazy.compactMap { result -> FallbackReason? in
            if case .fallback(let reason) = result.status { return reason } else { return nil }
        }.first
        let status: CleanupStatus = cleaned ? .cleaned : fallback.map { .fallback($0) } ?? .unchanged
        var warnings = ["segmented:\(outcomes.count)"]
        for (index, outcome) in outcomes.enumerated() {
            if case .fallback(let reason) = outcome.status { warnings.append("segment-\(index)-fallback:\(reason)") }
            warnings += outcome.warnings.map { "segment-\(index):\($0)" }
        }
        var provenance = Provenance.skipped
        if let ran = results.first(where: { $0.provenance != .skipped })?.provenance {
            provenance = Provenance(packID: ran.packID, packVersion: ran.packVersion, artifactDigest: ran.artifactDigest,
                                    modelRevision: ran.modelRevision, runtime: ran.runtime, route: ran.route,
                                    settings: ran.settings.merging(["segmentation": "maxSegmentBytes=\(maxBytes)"]) { $1 })
        }
        var timings = CleanupTimings()
        for result in results {
            let part = result.timings
            timings.queueMS += part.queueMS; timings.validationMS += part.validationMS
            timings.diffMS += part.diffMS; timings.budgetMS += part.budgetMS
            timings.preparationMS = max(timings.preparationMS, part.preparationMS)
            func add(_ total: inout Double?, _ value: Double?) { if let value { total = (total ?? 0) + value } }
            add(&timings.tokenizationMS, part.tokenizationMS); add(&timings.prefillMS, part.prefillMS)
            add(&timings.inferenceMS, part.inferenceMS); add(&timings.serverInferenceMS, part.serverInferenceMS)
            func count(_ total: inout Int?, _ value: Int?) { if let value { total = (total ?? 0) + value } }
            count(&timings.promptTokens, part.promptTokens); count(&timings.decodeTokens, part.decodeTokens)
            count(&timings.speculativeRounds, part.speculativeRounds)
            count(&timings.speculativeDrafted, part.speculativeDrafted)
            count(&timings.speculativeAccepted, part.speculativeAccepted)
            if let used = part.prefixCacheUsed { timings.prefixCacheUsed = (timings.prefixCacheUsed ?? true) && used }
        }
        timings.totalMS = started.duration(to: .now).milliseconds
        // Without a cleaned segment every segment kept its exact bytes: the turn is its input, unedited.
        let text = cleaned ? String(decoding: output, as: UTF8.self) : turn.text
        return TurnResult(turn: turn, result: CleanupResult(text: text, edits: cleaned ? edits : [], status: status,
                                                            provenance: provenance, timings: timings, warnings: warnings),
                          segments: outcomes)
    }
}
