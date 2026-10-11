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
        try Task.checkCancellation()
        try transcript.validate()
        try CleanupRequest("", vocabulary: options.vocabulary).validate()
        if let overall = options.overallDeadline, overall <= .zero {
            throw CleanupError.invalidRequest("overall deadline must be greater than zero")
        }
        let ceiling = options.overallDeadline.map { started.advanced(by: $0) }
        var results: [TurnResult] = []
        results.reserveCapacity(transcript.turns.count)
        for (index, turn) in transcript.turns.enumerated() {
            try Task.checkCancellation()
            let turnStart = ContinuousClock.now
            func skipped(_ reason: FallbackReason, _ warning: String) -> TurnResult {
                var timings = CleanupTimings()
                timings.totalMS = turnStart.duration(to: .now).milliseconds
                return TurnResult(turn: turn, result: CleanupResult(text: turn.text, edits: [],
                    status: .fallback(reason), provenance: .skipped, timings: timings, warnings: [warning]))
            }
            let remaining = ceiling.map { ContinuousClock.now.duration(to: $0) }
            if let remaining, remaining <= .zero {
                results.append(skipped(.timedOut, "transcript-budget-exhausted"))
            } else if turn.text.utf8.count > CleanupRequest.maxTextBytes {
                results.append(skipped(.unavailable, "turn-exceeds-admission-limit"))
            } else {
                var deadline: Duration
                if let policy = options.turnBudget {
                    guard let sized = policy.deadline(for: turn.text, base: options.turnBase) else {
                        results.append(skipped(.timedOut, "turn-budget-hopeless"))
                        options.progress?(index + 1, transcript.turns.count)
                        continue
                    }
                    deadline = sized
                } else {
                    deadline = CleanupRequest(turn.text).budget
                }
                if let remaining { deadline = min(deadline, remaining) }
                deadline = max(.milliseconds(1), min(deadline, .seconds(60)))
                let request = CleanupRequest(turn.text, vocabulary: options.vocabulary,
                                             deadline: deadline, transforms: options.transforms)
                results.append(TurnResult(turn: turn, result: try await clean(request)))
            }
            options.progress?(index + 1, transcript.turns.count)
        }
        try Task.checkCancellation()
        return TranscriptResult(turns: results, elapsedMS: started.duration(to: .now).milliseconds)
    }
}
