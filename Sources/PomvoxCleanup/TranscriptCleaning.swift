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

    public init(vocabulary: [String] = [], transforms: CleanupTransforms = [],
                turnBudget: CleanupBudgetPolicy? = nil, turnBase: Duration = .seconds(5),
                overallDeadline: Duration? = nil, progress: (@Sendable (Int, Int) -> Void)? = nil) {
        self.vocabulary = vocabulary; self.transforms = transforms
        self.turnBudget = turnBudget; self.turnBase = turnBase
        self.overallDeadline = overallDeadline; self.progress = progress
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
        let ceiling = options.overallDeadline.map { started.advanced(by: $0) }
        let total = transcript.turns.count
        for index in first..<total {
            try Task.checkCancellation()
            let turn = transcript.turns[index]
            let turnStart = ContinuousClock.now
            func skipped(_ reason: FallbackReason, _ warning: String) -> TurnResult {
                var timings = CleanupTimings()
                timings.totalMS = turnStart.duration(to: .now).milliseconds
                return TurnResult(turn: turn, result: CleanupResult(text: turn.text, edits: [],
                    status: .fallback(reason), provenance: .skipped, timings: timings, warnings: [warning]))
            }
            let remaining = ceiling.map { ContinuousClock.now.duration(to: $0) }
            let result: TurnResult
            if let remaining, remaining <= .zero {
                result = skipped(.timedOut, "transcript-budget-exhausted")
            } else if turn.text.utf8.count > CleanupRequest.maxTextBytes {
                result = skipped(.unavailable, "turn-exceeds-admission-limit")
            } else {
                var deadline: Duration?
                if let policy = options.turnBudget {
                    deadline = policy.deadline(for: turn.text, base: options.turnBase)
                } else {
                    deadline = CleanupRequest(turn.text).budget
                }
                if var deadline {
                    if let remaining { deadline = min(deadline, remaining) }
                    deadline = max(.milliseconds(1), min(deadline, .seconds(60)))
                    let request = CleanupRequest(turn.text, vocabulary: options.vocabulary,
                                                 deadline: deadline, transforms: options.transforms)
                    result = TurnResult(turn: turn, result: try await clean(request))
                } else {
                    result = skipped(.timedOut, "turn-budget-hopeless")
                }
            }
            try await emit(index, result)
            options.progress?(index + 1, total)
        }
    }
}
